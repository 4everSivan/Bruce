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
        let envelope: RequestLogEnvelope
        do {
            envelope = try JSONDecoder().decode(RequestLogEnvelope.self, from: output.stdout)
        } catch {
            throw RequestLogClientError.invalidEnvelope
        }
        guard envelope.status == "success", let artifact = envelope.artifact else {
            let message = envelope.diagnostics.first?.message ?? "请求日志查询失败"
            throw RequestLogClientError.collector(message)
        }
        do {
            let data = try JSONEncoder().encode(artifact)
            return try JSONDecoder().decode(RequestLogPageModel.self, from: data)
        } catch {
            throw RequestLogClientError.invalidEnvelope
        }
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
        return try await withCheckedThrowingContinuation { continuation in
            do {
                let handle = try launcher.launch(
                    executableURL: executableURL,
                    arguments: [],
                    input: input
                ) { result in
                    guard !gate.settled else { return }
                    gate.settled = true
                    gate.timeoutTask?.cancel()
                    switch result {
                    case let .success(output):
                        continuation.resume(returning: output)
                    case .failure:
                        continuation.resume(throwing: RequestLogClientError.launchFailed)
                    }
                }
                gate.handle = handle
                gate.timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: Self.queryTimeout)
                    guard !gate.settled else { return }
                    gate.settled = true
                    gate.handle?.forceTerminate()
                    continuation.resume(throwing: RequestLogClientError.timedOut)
                }
            } catch {
                continuation.resume(throwing: RequestLogClientError.launchFailed)
            }
        }
    }
}

@MainActor
private final class QueryGate {
    var settled = false
    var handle: CollectorProcessHandling?
    var timeoutTask: Task<Void, Never>?
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

private struct RequestLogEnvelope: Decodable {
    let status: String
    let artifact: JSONValue?
    let diagnostics: [BridgeDiagnostic]
}
