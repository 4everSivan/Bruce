import Darwin
import Foundation
import BruceOnboardingCore

package enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    package init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [String: JSONValue].self
        ) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

struct CollectorTimeouts: Encodable, Equatable, Sendable {
    let localScanSeconds: Double
    let externalRequestSeconds: Double
    let moduleSeconds: Double
    /// Swift 侧取消子进程的宽限期, 不属于 Bridge 请求协议.
    let cancellationGraceSeconds: Double

    static let `default` = CollectorTimeouts(
        localScanSeconds: 30,
        externalRequestSeconds: 10,
        moduleSeconds: 90,
        cancellationGraceSeconds: 2
    )

    enum CodingKeys: String, CodingKey {
        case localScanSeconds
        case externalRequestSeconds
        case moduleSeconds
    }
}

private struct BridgeRequest: Encodable {
    let schemaVersion: Int
    let runId: String
    let module: CollectorModule
    let timeouts: CollectorTimeouts
    let context: [String: JSONValue]
    let credentials: [String: JSONValue]
}

package enum BridgeStatus: String, Codable, Sendable {
    case success
    case partial
    case error
}

/// 采集响应的脱敏诊断 (任务 7): Scheduler 成功发布后保留在可观察边界,
/// 供诊断展示/记录读取; 内容不包含凭证或账号标识.
package struct BridgeDiagnostic: Codable, Equatable, Sendable {
    let code: String
    let category: String
    let stage: String
    let message: String
    let retryable: Bool
}

package struct BridgeResponse: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let runId: String
    let generatedAt: String
    let status: BridgeStatus
    let artifact: JSONValue?
    let credentialUpdates: [JSONValue]
    let diagnostics: [BridgeDiagnostic]
    let credentialChallenges: [JSONValue]
}

extension BridgeResponse {
    /// 任务 1 冻结契约: 旧 Bridge v1 响应缺失 credentialChallenges 时按空数组解码,
    /// schemaVersion 保持 1, 向后兼容.
    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        runId = try container.decode(String.self, forKey: .runId)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        status = try container.decode(BridgeStatus.self, forKey: .status)
        artifact = try container.decodeIfPresent(JSONValue.self, forKey: .artifact)
        credentialUpdates = try container.decode(
            [JSONValue].self,
            forKey: .credentialUpdates
        )
        diagnostics = try container.decode(
            [BridgeDiagnostic].self,
            forKey: .diagnostics
        )
        credentialChallenges = try container.decodeIfPresent(
            [JSONValue].self,
            forKey: .credentialChallenges
        ) ?? []
    }
}

package struct SanitizedProcessDiagnostic: Equatable, Sendable {
    let byteCount: Int
    let lineCount: Int

    var summary: String {
        "已抑制 \(lineCount) 行子进程诊断, 共 \(byteCount) 字节"
    }
}

package struct CollectorRunOutput: Equatable, Sendable {
    package let response: BridgeResponse
    package let stderrDiagnostic: SanitizedProcessDiagnostic?
}

enum CollectorRunnerError: Error, Equatable {
    case invalidExecutablePath
    case rustNotExecutable
    case alreadyRunning
    case capacityExceeded
    case launchFailed
    case timedOut
    case processFailed(exitCode: Int32, diagnostic: String?)
    case invalidEnvelope
    case unsupportedSchema
    case runIdMismatch
}

struct CollectorProcessOutput: Sendable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

@MainActor
protocol CollectorProcessHandling: AnyObject {
    func requestCancellation()
    func forceTerminate()
}

@MainActor
protocol CollectorProcessLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (
            Result<CollectorProcessOutput, Error>
        ) -> Void
    ) throws -> CollectorProcessHandling
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class SystemCollectorProcessHandle: CollectorProcessHandling {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func requestCancellation() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func forceTerminate() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

@MainActor
struct SystemCollectorProcessLauncher: CollectorProcessLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (
            Result<CollectorProcessOutput, Error>
        ) -> Void
    ) throws -> CollectorProcessHandling {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutData = LockedData()
        let stderrData = LockedData()
        let readers = DispatchGroup()

        process.executableURL = executableURL
        process.arguments = arguments
        // Bridge 凭证只经 stdin 传递. 子进程不继承可能含 token、
        // proxy credentials 或 provider key 的应用环境.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData.set(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData.set(
                stderrPipe.fileHandleForReading.readDataToEndOfFile()
            )
            readers.leave()
        }

        process.terminationHandler = { finishedProcess in
            readers.notify(queue: .global(qos: .utility)) {
                let output = CollectorProcessOutput(
                    stdout: stdoutData.get(),
                    stderr: stderrData.get(),
                    exitCode: finishedProcess.terminationStatus
                )
                Task { @MainActor in
                    completion(.success(output))
                }
            }
        }

        do {
            try process.run()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning {
                process.terminate()
            }
            throw error
        }
        return SystemCollectorProcessHandle(process: process)
    }
}

@MainActor
protocol RunnerTimerToken: AnyObject {
    func cancel()
}

@MainActor
protocol RunnerTimerScheduling {
    func schedule(
        after seconds: Double,
        action: @escaping @MainActor () -> Void
    ) -> RunnerTimerToken
}

@MainActor
private final class DispatchRunnerTimerToken: RunnerTimerToken {
    private let workItem: DispatchWorkItem

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem.cancel()
    }
}

@MainActor
struct DispatchRunnerTimerScheduler: RunnerTimerScheduling {
    func schedule(
        after seconds: Double,
        action: @escaping @MainActor () -> Void
    ) -> RunnerTimerToken {
        let workItem = DispatchWorkItem {
            MainActor.assumeIsolated {
                action()
            }
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + seconds,
            execute: workItem
        )
        return DispatchRunnerTimerToken(workItem: workItem)
    }
}

@MainActor
package final class CollectorRunner {
    private enum RequestedEnd {
        case none
        case cancelled
        case timedOut
    }

    private final class ActiveRun {
        let runId: String
        let handle: CollectorProcessHandling
        var continuation: CheckedContinuation<CollectorRunOutput, Error>?
        var timeoutTimer: RunnerTimerToken?
        var forceTimer: RunnerTimerToken?
        var requestedEnd: RequestedEnd = .none

        init(
            runId: String,
            handle: CollectorProcessHandling,
            continuation: CheckedContinuation<CollectorRunOutput, Error>
        ) {
            self.runId = runId
            self.handle = handle
            self.continuation = continuation
        }
    }

    private let executableURL: URL
    private let executableArguments: [String]
    private let launcher: CollectorProcessLaunching
    private let timerScheduler: RunnerTimerScheduling
    private let timeouts: CollectorTimeouts
    private var activeRuns: [CollectorModule: ActiveRun] = [:]

    package convenience init(rustURL: URL) {
        self.init(
            rustURL: rustURL,
            timeouts: .default
        )
    }

    init(
        rustURL: URL,
        timeouts: CollectorTimeouts
    ) {
        executableURL = rustURL
        executableArguments = []
        launcher = SystemCollectorProcessLauncher()
        timerScheduler = DispatchRunnerTimerScheduler()
        self.timeouts = timeouts
    }

    init(
        rustURL: URL,
        launcher: CollectorProcessLaunching,
        timerScheduler: RunnerTimerScheduling,
        timeouts: CollectorTimeouts = .default
    ) {
        executableURL = rustURL
        executableArguments = []
        self.launcher = launcher
        self.timerScheduler = timerScheduler
        self.timeouts = timeouts
    }

    package var activeModuleCount: Int {
        activeRuns.count
    }

    package func run(
        module: CollectorModule,
        context: [String: JSONValue] = [:],
        credentials: [String: JSONValue] = [:]
    ) async throws -> CollectorRunOutput {
        if Task.isCancelled {
            throw CancellationError()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                beginRun(
                    module: module,
                    context: context,
                    credentials: credentials,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(module: module)
            }
        }
    }

    package func cancel(module: CollectorModule) {
        guard let active = activeRuns[module] else { return }
        guard active.requestedEnd == .none else { return }
        active.requestedEnd = .cancelled
        active.handle.requestCancellation()
        scheduleForceTermination(module: module, active: active)
    }

    package func cancelAll() {
        for module in Array(activeRuns.keys) {
            cancel(module: module)
        }
    }

    package func forceTerminateAll() {
        activeRuns.values.forEach { $0.handle.forceTerminate() }
    }

    private func beginRun(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue],
        continuation: CheckedContinuation<CollectorRunOutput, Error>
    ) {
        do {
            try validatePaths()
            guard activeRuns[module] == nil else {
                throw CollectorRunnerError.alreadyRunning
            }
            guard activeRuns.count < 2 else {
                throw CollectorRunnerError.capacityExceeded
            }
            let runId = UUID().uuidString.lowercased()
            let request = BridgeRequest(
                schemaVersion: 1,
                runId: runId,
                module: module,
                timeouts: timeouts,
                context: context,
                credentials: credentials
            )
            let input = try JSONEncoder().encode(request)
            let handle = try launcher.launch(
                executableURL: executableURL,
                arguments: executableArguments,
                input: input
            ) { [weak self] result in
                self?.complete(module: module, result: result)
            }
            let active = ActiveRun(
                runId: runId,
                handle: handle,
                continuation: continuation
            )
            activeRuns[module] = active
            active.timeoutTimer = timerScheduler.schedule(
                after: timeouts.moduleSeconds
            ) { [weak self, weak active] in
                guard let self, let active else { return }
                self.timeout(module: module, active: active)
            }
        } catch let error as CollectorRunnerError {
            continuation.resume(throwing: error)
        } catch {
            continuation.resume(throwing: CollectorRunnerError.launchFailed)
        }
    }

    private func validatePaths() throws {
        guard executableURL.isFileURL,
              executableURL.path.hasPrefix("/") else {
            throw CollectorRunnerError.invalidExecutablePath
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CollectorRunnerError.rustNotExecutable
        }
    }

    private func timeout(module: CollectorModule, active: ActiveRun) {
        guard activeRuns[module] === active else { return }
        guard active.requestedEnd == .none else { return }
        active.requestedEnd = .timedOut
        active.handle.requestCancellation()
        scheduleForceTermination(module: module, active: active)
    }

    private func scheduleForceTermination(
        module: CollectorModule,
        active: ActiveRun
    ) {
        active.forceTimer = timerScheduler.schedule(
            after: timeouts.cancellationGraceSeconds
        ) { [weak self, weak active] in
            guard let self, let active else { return }
            guard self.activeRuns[module] === active else { return }
            active.handle.forceTerminate()
        }
    }

    private func complete(
        module: CollectorModule,
        result: Result<CollectorProcessOutput, Error>
    ) {
        guard let active = activeRuns.removeValue(forKey: module) else {
            return
        }
        active.timeoutTimer?.cancel()
        active.forceTimer?.cancel()
        guard let continuation = active.continuation else { return }
        active.continuation = nil

        switch active.requestedEnd {
        case .cancelled:
            continuation.resume(throwing: CancellationError())
            return
        case .timedOut:
            continuation.resume(throwing: CollectorRunnerError.timedOut)
            return
        case .none:
            break
        }

        switch result {
        case .failure:
            continuation.resume(
                throwing: CollectorRunnerError.launchFailed
            )
        case .success(let output):
            let stderrDiagnostic = sanitizedDiagnostic(output.stderr)
            guard output.exitCode == 0 else {
                continuation.resume(
                    throwing: CollectorRunnerError.processFailed(
                        exitCode: output.exitCode,
                        diagnostic: stderrDiagnostic?.summary
                    )
                )
                return
            }
            do {
                let response = try JSONDecoder().decode(
                    BridgeResponse.self,
                    from: output.stdout
                )
                guard response.schemaVersion == 1 else {
                    throw CollectorRunnerError.unsupportedSchema
                }
                guard response.runId == active.runId else {
                    throw CollectorRunnerError.runIdMismatch
                }
                if response.status != .error && response.artifact == nil {
                    throw CollectorRunnerError.invalidEnvelope
                }
                continuation.resume(
                    returning: CollectorRunOutput(
                        response: response,
                        stderrDiagnostic: stderrDiagnostic
                    )
                )
            } catch let error as CollectorRunnerError {
                continuation.resume(throwing: error)
            } catch {
                continuation.resume(
                    throwing: CollectorRunnerError.invalidEnvelope
                )
            }
        }
    }

    private func sanitizedDiagnostic(
        _ data: Data
    ) -> SanitizedProcessDiagnostic? {
        guard !data.isEmpty else { return nil }
        let lines = data.reduce(into: 1) { count, byte in
            if byte == 0x0A {
                count += 1
            }
        }
        return SanitizedProcessDiagnostic(
            byteCount: data.count,
            lineCount: lines
        )
    }
}
