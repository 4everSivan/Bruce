import Foundation
import LocalAuthentication
import Security

/// 外部 CLI 凭证读取错误. 不携带凭证值或原始错误文本.
public enum ExternalCredentialError: Error, Equatable, Sendable {
    case notAllowed(KeychainExternalSource)
    case accessBlocked(KeychainExternalSource, OSStatus)
    case readFailed(KeychainExternalSource, OSStatus)
}

/// 外部 CLI 凭证读取边界.
/// 调用方必须先通过 `KeychainAccessController` 的来源策略.
public protocol ExternalCredentialReader: Sendable {
    func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String?
}

/// 生产外部凭证读取器.
/// Claude 优先读取 CLI Keychain, 再回退到 CLI 凭证文件; Grok 读取其 CLI 文件.
/// 两条路径都受 `externalSources` 白名单控制.
public struct SystemExternalCredentialReader: ExternalCredentialReader, Sendable {
    public static let claudeKeychainService = "Claude Code-credentials"

    private let homeURL: URL
    private let accessController: KeychainAccessController
    private let securityExecutablePath: String

    public init(
        homeURL: URL,
        accessController: KeychainAccessController,
        securityExecutablePath: String = "/usr/bin/security"
    ) {
        self.homeURL = homeURL
        self.accessController = accessController
        self.securityExecutablePath = securityExecutablePath
    }

    public func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String? {
        switch source {
        case .claudeCLI:
            // 对齐 cc-switch: 每次读取无条件尝试 /usr/bin/security 外部进程静默读取,
            // 避免进程内 SecItemCopyMatching 在 Ad-hoc/非官方签名 App 触碰外部 Keychain 项时
            // 引发 macOS SecurityAgent 侵入式密码授权弹窗 (项目红线);
            // 失败时静默回退至 ~/.claude/.credentials.json 与 ~/.claude.json.
            if let keychain = readClaudeKeychain() {
                return keychain
            }
            if let file1 = try readFile(
                source: source,
                url: homeURL.appendingPathComponent(
                    ".claude/.credentials.json"
                )
            ) {
                return file1
            }
            return try readFile(
                source: source,
                url: homeURL.appendingPathComponent(".claude.json")
            )
        case .grokCLI:
            guard accessController.allows(
                source: .external(source),
                intent: intent
            ) else {
                throw ExternalCredentialError.notAllowed(source)
            }
            return try readFile(
                source: source,
                url: homeURL.appendingPathComponent(".grok/auth.json")
            )
        }
    }

    /// Claude CLI 外部 Keychain 项的无条件静默读取 (对照 cc-switch
    /// `security find-generic-password -s "Claude Code-credentials" -w`).
    /// - 通过 /usr/bin/security 执行读取, 绝不唤起 SecurityAgent 系统密码弹窗;
    /// - 条目不存在 / 被系统拦截 (非 0 退出码): 静默返回 nil 走文件回退;
    /// - 拦截时不 markBlocked — 外部条目是可选来源, 不得污染 Bruce 自有存储策略。
    ///
    /// C255: stdout 在后台并发排空、stderr 直接丢弃，避免输出超过管道缓冲时永久
    /// 死锁；等待退出有界（超时后 terminate → SIGKILL），不再无条件 `waitUntilExit`。
    private func readClaudeKeychain() -> String? {
        let securityURL = URL(fileURLWithPath: securityExecutablePath)
        guard FileManager.default.isExecutableFile(atPath: securityURL.path) else {
            return nil
        }
        let process = Process()
        process.executableURL = securityURL
        process.arguments = [
            "find-generic-password",
            "-s", Self.claudeKeychainService,
            "-w",
        ]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let output = PipeBuffer()
        let drained = DispatchSemaphore(value: 0)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            output.store(stdoutHandle.readDataToEndOfFile())
            drained.signal()
        }

        waitForExit(process, timeout: 3)
        if process.isRunning {
            process.terminate()
            waitForExit(process, timeout: 1)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(pid, SIGKILL)
            }
            waitForExit(process, timeout: 1)
        }
        _ = drained.wait(timeout: .now() + 1)
        try? stdoutHandle.close()

        guard !process.isRunning, process.terminationStatus == 0 else {
            return nil
        }
        guard let text = String(data: output.snapshot(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }
        return text
    }

    /// 轮询等待子进程退出（同步 API 内的有界等待）。
    private func waitForExit(_ process: Process, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func readFile(
        source: KeychainExternalSource,
        url: URL
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

/// Harness 用确定性外部读取器. 只记录来源和意图, 不打印值.
public final class InMemoryExternalCredentialReader: ExternalCredentialReader,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [KeychainExternalSource: String]
    private var requests: [(KeychainExternalSource, KeychainAccessIntent)] = []

    public init(
        values: [KeychainExternalSource: String] = [:]
    ) {
        self.storage = values
    }

    public func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String? {
        lock.lock()
        requests.append((source, intent))
        let value = storage[source]
        lock.unlock()
        return value
    }

    public func requestedSources() -> [KeychainExternalSource] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.0 }
    }
}

/// 子进程 stdout 的线程安全缓冲 (C255): 排空线程写入、调用方读取。
private final class PipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func store(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
