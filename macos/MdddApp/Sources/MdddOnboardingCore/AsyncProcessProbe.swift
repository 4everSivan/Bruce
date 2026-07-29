import Foundation

// MARK: - ProcessProbeResult

/// 进程探测的结构化结果. 原始 stdout/stderr 不进入日志或 Artifact;
/// stderr 摘要仅供调用方内部分类 (例如判断 SQLite locked), 不做对外展示.
public enum ProcessProbeResult: Equatable, Sendable {
    case success(output: String)
    /// 非零退出. stderrSummary 为有上限的 stderr 摘要, 可能为 nil.
    case nonZeroExit(code: Int32, stderrSummary: String?)
    case timedOut
    case cancelled
    case launchFailed

    /// 从输出中提取的首行, 用于版本解析. 失败时为 nil.
    public var firstLine: String? {
        switch self {
        case .success(let output):
            return output.split(separator: "\n").first.map(String.init)
        default:
            return nil
        }
    }
}

// MARK: - BoundedOutputCollector

/// 有字节上限的输出收集器. 超过上限的部分丢弃, 但调用方必须继续排空管道,
/// 防止子进程因管道写满而阻塞.
private final class BoundedOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let remaining = limit - data.count
        if remaining > 0 {
            data.append(chunk.prefix(remaining))
        }
        lock.unlock()
    }

    var snapshot: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

// MARK: - AsyncProcessProbe

/// 封装所有外部进程调用, 提供超时, 取消和输出长度限制.
/// stdout 和 stderr 启动后立即并发排空, 读取期间强制字节上限.
/// 超时或取消时先 terminate, 宽限后仍未退出则 SIGKILL, 并 waitUntilExit 回收,
/// 不遗留直接子进程 (子进程自行 fork 的孙进程不在回收范围). 不使用 @MainActor, 可在后台执行.
public struct AsyncProcessProbe: Sendable {
    public static let defaultTimeout: TimeInterval = 8
    public static let defaultGracePeriod: TimeInterval = 2
    public static let maxOutputBytes = 16_384
    /// stderr 摘要上限, 只用于错误分类.
    public static let maxStderrSummaryBytes = 1_024

    private let timeout: TimeInterval
    private let gracePeriod: TimeInterval
    private let maxOutputBytes: Int

    public init(
        timeout: TimeInterval = AsyncProcessProbe.defaultTimeout,
        gracePeriod: TimeInterval = AsyncProcessProbe.defaultGracePeriod,
        maxOutputBytes: Int = AsyncProcessProbe.maxOutputBytes
    ) {
        self.timeout = timeout
        self.gracePeriod = gracePeriod
        self.maxOutputBytes = maxOutputBytes
    }

    /// 运行指定可执行文件并返回结构化结果.
    public func run(
        executablePath: String,
        arguments: [String]
    ) async -> ProcessProbeResult {
        return await withTaskGroup(of: ProcessProbeResult.self) { group in
            group.addTask { [self] in
                return await self.runProcess(
                    executablePath: executablePath,
                    arguments: arguments
                )
            }

            group.addTask { [self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    return .timedOut
                } catch {
                    // 调用方取消或超时分支已落败
                    return .cancelled
                }
            }

            let result = await group.next() ?? .launchFailed
            // 取消执行分支; 执行分支内的清理逻辑负责 terminate/kill/回收
            group.cancelAll()
            return result
        }
    }

    private func runProcess(
        executablePath: String,
        arguments: [String]
    ) async -> ProcessProbeResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .launchFailed
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = BoundedOutputCollector(limit: maxOutputBytes)
        let stderrCollector = BoundedOutputCollector(
            limit: AsyncProcessProbe.maxStderrSummaryBytes
        )

        // 启动后立即并发排空两个管道, 读取期间强制上限
        let drainGroup = DispatchGroup()
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drainPipe(
                handle: stdoutPipe.fileHandleForReading,
                into: stdoutCollector
            )
            drainGroup.leave()
        }
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            drainPipe(
                handle: stderrPipe.fileHandleForReading,
                into: stderrCollector
            )
            drainGroup.leave()
        }

        do {
            try process.run()
        } catch {
            // 启动失败: 关闭写端让排空循环退出, 避免悬挂
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            await waitForDrain(drainGroup, timeout: 5)
            return .launchFailed
        }

        // 关闭父进程持有的写端, 子进程退出后排空循环才能收到 EOF
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // 等待进程退出, 同时响应调用方取消和超时分支的 cancelAll.
        // 注意: 不混用 isRunning 轮询和 waitUntilExit, 两者并用在
        // Foundation 的终止观察机制下存在竞态, waitUntilExit 可能永久阻塞.
        while process.isRunning {
            if Task.isCancelled {
                await terminateAndReap(process)
                return .cancelled
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // isRunning 转为 false 时 Foundation 已回收子进程, terminationStatus 可读
        await waitForDrain(drainGroup, timeout: 5)

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            let truncated = stdoutCollector.snapshot
            let output = String(data: truncated, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .success(output: output)
        }

        let stderrData = stderrCollector.snapshot
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = (stderrText?.isEmpty == false) ? stderrText : nil
        return .nonZeroExit(code: exitCode, stderrSummary: summary)
    }

    /// 先 terminate, 宽限期内未退出则 SIGKILL, 最后轮询等待回收.
    private func terminateAndReap(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(gracePeriod)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        // 有界等待回收, 不用 waitUntilExit (见 runProcess 中的竞态说明)
        let reapDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < reapDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// 同步排空单个管道直到 EOF, 数据写入有界收集器.
    private func drainPipe(
        handle: FileHandle,
        into collector: BoundedOutputCollector
    ) {
        while true {
            let chunk = autoreleasepool { handle.availableData }
            if chunk.isEmpty { break }
            collector.append(chunk)
        }
    }

    /// 在后台线程等待排空完成; DispatchGroup.wait 不能直接在 async 上下文调用.
    private func waitForDrain(
        _ group: DispatchGroup,
        timeout: TimeInterval
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = group.wait(timeout: .now() + timeout)
                continuation.resume()
            }
        }
    }
}

// MARK: - PythonVersionParser

/// 解析 Python 标准版本输出.
public enum PythonVersionParser {
    /// 解析 "Python 3.9.6" 形式, 允许前后空白和 patch 缺失.
    /// 返回 (major, minor) 或 nil.
    public static func parse(_ output: String?) -> (major: Int, minor: Int)? {
        guard let output else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 匹配 "Python X.Y" 或 "Python X.Y.Z"
        let pattern = #"^Python\s+(\d+)\.(\d+)(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
              match.numberOfRanges >= 3 else {
            return nil
        }
        guard let majorRange = Range(match.range(at: 1), in: trimmed),
              let minorRange = Range(match.range(at: 2), in: trimmed),
              let major = Int(trimmed[majorRange]),
              let minor = Int(trimmed[minorRange]) else {
            return nil
        }
        return (major, minor)
    }

    /// 判断版本是否兼容 (Python 3.9+).
    public static func isCompatible(_ version: (major: Int, minor: Int)?) -> Bool {
        guard let (major, minor) = version else { return false }
        return major >= 3 && !(major == 3 && minor < 9)
    }
}

// MARK: - PythonPathResolver

/// 按固定优先级解析 Python 绝对路径, 不依赖 GUI PATH.
public enum PythonPathResolver {
    public static let defaultCandidates = [
        "/usr/bin/python3",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3"
    ]

    /// 返回第一个存在且可执行的路径, 或 nil.
    public static func resolve(
        userPreferred: String? = nil,
        candidates: [String] = PythonPathResolver.defaultCandidates,
        fileManager: FileManager = .default
    ) -> String? {
        if let preferred = userPreferred,
           fileManager.isExecutableFile(atPath: preferred) {
            return preferred
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

// MARK: - GhCliPathResolver

/// 按固定优先级解析 gh CLI 绝对路径.
public enum GhCliPathResolver {
    public static let defaultCandidates = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    public static func resolve(
        userPreferred: String? = nil,
        candidates: [String] = GhCliPathResolver.defaultCandidates,
        fileManager: FileManager = .default
    ) -> String? {
        if let preferred = userPreferred,
           fileManager.isExecutableFile(atPath: preferred) {
            return preferred
        }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
