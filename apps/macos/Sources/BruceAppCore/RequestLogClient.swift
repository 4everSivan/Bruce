import Foundation

/// Read-only request-log query client.
///
/// Spawns the bundled Rust collector with `module=request-log`; it deliberately
/// bypasses `RefreshScheduler` because opening the settings page must not start
/// a full usage refresh (design/14 §4.2.8).
@MainActor
package final class RequestLogClient {
    private static let queryTimeout: Duration = .seconds(12)

    private let executableURL: URL?
    private let launcher: CollectorProcessLaunching

    package convenience init(executableURL: URL?) {
        self.init(
            executableURL: executableURL,
            launcher: SystemCollectorProcessLauncher()
        )
    }

    init(executableURL: URL?, launcher: CollectorProcessLaunching) {
        self.executableURL = executableURL
        self.launcher = launcher
    }

    package func query(_ query: RequestLogQuery) async throws -> RequestLogPageModel {
        guard let executableURL else {
            throw RequestLogClientError.missingExecutable
        }
        let request = RequestLogBridgeRequest(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            module: "request-log",
            timeouts: .init(externalRequestSeconds: 1, moduleSeconds: 10),
            context: context(for: query),
            credentials: [:]
        )
        let input = try JSONEncoder().encode(request)
        let output = try await run(executableURL: executableURL, input: input)
        guard output.exitCode == 0 else {
            throw RequestLogClientError.processFailed(exitCode: output.exitCode)
        }
        let envelope: RequestLogEnvelope<RequestLogPageModel>
        do {
            // C261: 直接泛型解码目标模型, 不再先解成 JSONValue 再重编码解码。
            envelope = try JSONDecoder().decode(
                RequestLogEnvelope<RequestLogPageModel>.self,
                from: output.stdout
            )
        } catch {
            throw RequestLogClientError.invalidEnvelope
        }
        guard envelope.status == "success", let page = envelope.artifact else {
            let message = envelope.diagnostics.first?.message ?? "请求日志查询失败"
            throw RequestLogClientError.collector(message)
        }
        return page
    }

    private func context(for query: RequestLogQuery) -> [String: JSONValue] {
        var context: [String: JSONValue] = [
            "home": .string(FileManager.default.homeDirectoryForCurrentUser.path),
            "start": .integer(Int(query.start)),
            "end": .integer(Int(query.end)),
            "page": .integer(query.page),
            "pageSize": .integer(query.pageSize)
        ]
        if !query.agentIDs.isEmpty {
            context["agentIds"] = .array(query.agentIDs.map(JSONValue.string))
        }
        if let model = query.model, !model.isEmpty {
            context["model"] = .string(model)
        }
        return context
    }

    private func run(executableURL: URL, input: Data) async throws -> CollectorProcessOutput {
        let gate = QueryGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
                do {
                    let handle = try launcher.launch(
                        executableURL: executableURL,
                        arguments: [],
                        input: input
                    ) { result in
                        guard !gate.settled else { return }
                        gate.settled = true
                        gate.timeoutTask?.cancel()
                        let continuation = gate.continuation
                        gate.continuation = nil
                        switch result {
                        case let .success(output):
                            continuation?.resume(returning: output)
                        case .failure:
                            continuation?.resume(throwing: RequestLogClientError.launchFailed)
                        }
                    }
                    gate.handle = handle
                    gate.timeoutTask = Task { @MainActor in
                        try? await Task.sleep(for: Self.queryTimeout)
                        guard !gate.settled else { return }
                        gate.settled = true
                        gate.handle?.forceTerminate()
                        let continuation = gate.continuation
                        gate.continuation = nil
                        continuation?.resume(throwing: RequestLogClientError.timedOut)
                    }
                } catch {
                    gate.settled = true
                    let continuation = gate.continuation
                    gate.continuation = nil
                    continuation?.resume(throwing: RequestLogClientError.launchFailed)
                }
            }
        } onCancel: {
            // C256: 快速切换筛选/翻页会取消前一次查询；必须终止已启动的采集子进程，
            // 否则并行残留多个 `Bruce-collector` 进程。
            Task { @MainActor in
                gate.cancel()
            }
        }
    }
}

@MainActor
private final class QueryGate {
    var settled = false
    var handle: CollectorProcessHandling?
    var timeoutTask: Task<Void, Never>?
    var continuation: CheckedContinuation<CollectorProcessOutput, Error>?

    func cancel() {
        guard !settled else { return }
        settled = true
        timeoutTask?.cancel()
        timeoutTask = nil
        handle?.forceTerminate()
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(throwing: CancellationError())
    }
}

private struct RequestLogBridgeRequest: Encodable {
    let schemaVersion: Int
    let runId: String
    let module: String
    let timeouts: Timeouts
    let context: [String: JSONValue]
    let credentials: [String: JSONValue]

    struct Timeouts: Encodable {
        let externalRequestSeconds: Double
        let moduleSeconds: Double
    }
}

private struct RequestLogEnvelope<Artifact: Decodable>: Decodable {
    let status: String
    let artifact: Artifact?
    let diagnostics: [BridgeDiagnostic]
}
