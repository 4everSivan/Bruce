import Foundation
@testable import BruceAppCore

private enum RequestLogHarnessFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw RequestLogHarnessFailure.expectation(message)
    }
}

@MainActor
private final class FakeProcessHandle: CollectorProcessHandling {
    func requestCancellation() {}
    func forceTerminate() {}
}

@MainActor
private final class FakeLauncher: CollectorProcessLaunching {
    var stdout = Data()
    var exitCode: Int32 = 0
    private(set) var lastInput: Data?

    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (Result<CollectorProcessOutput, Error>) -> Void
    ) throws -> CollectorProcessHandling {
        lastInput = input
        let output = CollectorProcessOutput(
            stdout: stdout,
            stderr: Data(),
            exitCode: exitCode
        )
        completion(.success(output))
        return FakeProcessHandle()
    }
}

/// Holds every launch until the test completes it, so queries can finish in any order.
@MainActor
private final class DeferredLauncher: CollectorProcessLaunching {
    struct Pending {
        let context: [String: Any]
        let complete: @MainActor (Result<CollectorProcessOutput, Error>) -> Void
    }

    private(set) var pending: [Pending] = []

    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (Result<CollectorProcessOutput, Error>) -> Void
    ) throws -> CollectorProcessHandling {
        let json = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        pending.append(Pending(context: json?["context"] as? [String: Any] ?? [:], complete: completion))
        return FakeProcessHandle()
    }

    /// Complete launch `index` with a page of `ids` (`total` defaults to the id count).
    func finish(_ index: Int, ids: [String], total: Int? = nil) {
        let entries = ids.map { id in
            """
            {"requestId":"\(id)","agentId":"claude-code","model":"m","rawModel":"m","occurredAt":1,\
            "input":1,"output":1,"cacheRead":0,"cacheCreation":0,"costUsd":null,"statusCode":200,\
            "project":null,"fidelity":"exact","latencyMs":null,"firstTokenMs":null}
            """
        }
        let body = """
            {"schemaVersion":1,"runId":"x","generatedAt":"x","status":"success","artifact":{
            "schemaVersion":1,"module":"request-log","generatedAt":"x","total":\(total ?? ids.count),
            "page":0,"pageSize":50,"summary":{"tokens":0,"costUsd":0,"avgTokens":0},"models":[],
            "entries":[\(entries.joined(separator: ","))]},"credentialUpdates":[],
            "credentialChallenges":[],"diagnostics":[]}
            """
        pending[index].complete(.success(
            CollectorProcessOutput(stdout: Data(body.utf8), stderr: Data(), exitCode: 0)
        ))
    }
}

@MainActor
private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
        await Task.yield()
    }
    try expect(condition(), "async work did not settle")
}

@main
struct RequestLogHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: BruceRequestLogHarness <repository-root>")
            exit(2)
        }
        let repository = URL(fileURLWithPath: CommandLine.arguments[1])
        try await clientDecodesPage()
        try await clientMapsCollectorError()
        try await missingExecutableFailsClosed()
        try modelDecodingIsTolerantToOptionalNotice()
        try agentFilterDefaultsAndSelectAllAreIdempotent()
        try supportedAgentsMatchCollectorScope(repository: repository)
        try displayModelFallsBackToRawLabel()
        try await userQuerySupersedesInFlightBackgroundQuery()
        try await backgroundRefreshSkipsWhileQueryInFlight()
        try await shrunkTotalFallsBackToLastPage()
        print("BruceRequestLogHarness: all checks passed")
    }

    /// C249: mac 支持集与 collector REQUEST_LOG_AGENT_IDS 由同一 fixture 锁定。
    private static func supportedAgentsMatchCollectorScope(repository: URL) throws {
        struct Fixture: Decodable { let agents: [String] }
        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: repository.appendingPathComponent(
                "tests/fixtures/bridge/request-log-agents.json"
            ))
        )
        try expect(
            Set(fixture.agents) == RequestLogAgentFilter.supportedAgentIDs,
            "mac 请求日志支持集应与 collector 范围一致, got \(RequestLogAgentFilter.supportedAgentIDs.sorted())"
        )
    }

    @MainActor
    private static func makeViewModel() -> (RequestLogViewModel, DeferredLauncher) {
        let launcher = DeferredLauncher()
        let client = RequestLogClient(executableURL: URL(fileURLWithPath: "/bin/sh"), launcher: launcher)
        let model = RequestLogViewModel(client: client)
        model.applyDefaultAgents(["claude-code"])
        return (model, launcher)
    }

    /// C249: 后台查询进行中切换筛选, 新查询必须发出; 旧查询晚到的结果不得覆盖新筛选。
    @MainActor
    private static func userQuerySupersedesInFlightBackgroundQuery() async throws {
        let (model, launcher) = makeViewModel()
        Task { await model.refreshInPlace() }
        try await settle { launcher.pending.count == 1 }

        model.setModel("claude-sonnet-5-5")
        try await settle { launcher.pending.count == 2 }
        try expect(
            launcher.pending[1].context["model"] as? String == "claude-sonnet-5-5",
            "filter change must launch its own query while another is in flight"
        )

        launcher.finish(1, ids: ["fresh"])
        try await settle { model.data.entries.map(\.id) == ["fresh"] }
        launcher.finish(0, ids: ["stale"])
        for _ in 0..<20 { await Task.yield() }
        try expect(model.data.entries.map(\.id) == ["fresh"], "stale result must be discarded")
        try expect(!model.isLoading, "loading clears once the latest query lands")
    }

    /// C249: 用户查询进行中时, 30s / artifact 后台刷新直接跳过, 不再多起一个进程。
    @MainActor
    private static func backgroundRefreshSkipsWhileQueryInFlight() async throws {
        let (model, launcher) = makeViewModel()
        Task { await model.loadIfNeeded() }
        try await settle { launcher.pending.count == 1 }
        await model.refreshInPlace()
        try expect(launcher.pending.count == 1, "background refresh must skip while busy")
        launcher.finish(0, ids: ["a"])
        try await settle { !model.isLoading }
    }

    /// C249: 总量收缩使当前页越界时回到最后一页再查一次, 不停在空页。
    @MainActor
    private static func shrunkTotalFallsBackToLastPage() async throws {
        let (model, launcher) = makeViewModel()
        Task { await model.loadIfNeeded() }
        try await settle { launcher.pending.count == 1 }
        launcher.finish(0, ids: ["p0"], total: 120)
        try await settle { model.pageCount == 3 }

        Task { await model.nextPage() }
        try await settle { launcher.pending.count == 2 }
        launcher.finish(1, ids: ["p1"], total: 120)
        try await settle { model.page == 1 && !model.isLoading }
        Task { await model.nextPage() }
        try await settle { launcher.pending.count == 3 }
        try expect(launcher.pending[2].context["page"] as? Int == 2, "third page requested")

        launcher.finish(2, ids: [], total: 60)
        try await settle { launcher.pending.count == 4 }
        try expect(launcher.pending[3].context["page"] as? Int == 1, "falls back to the last page")
        launcher.finish(3, ids: ["last"], total: 60)
        try await settle { model.data.entries.map(\.id) == ["last"] }
        try expect(model.page == 1, "page clamped to the last page")
    }

    /// 客户端必须发送 module=request-log，并解析 summary/models/entries。
    @MainActor
    private static func clientDecodesPage() async throws {
        let launcher = FakeLauncher()
        launcher.stdout = Data(
            """
            {
              "schemaVersion": 1,
              "runId": "ignored",
              "generatedAt": "2026-11-19T00:00:00Z",
              "status": "success",
              "artifact": {
                "schemaVersion": 1,
                "module": "request-log",
                "generatedAt": "2026-11-19T00:00:00Z",
                "total": 1,
                "page": 0,
                "pageSize": 50,
                "summary": {"tokens": 617, "costUsd": 0.01, "avgTokens": 617},
                "models": ["claude-opus-5-5"],
                "entries": [{
                  "requestId": "abc",
                  "agentId": "claude-code",
                  "model": "claude-opus-5-5",
                  "rawModel": "claude-opus-5-5",
                  "occurredAt": 1795057200000,
                  "input": 10,
                  "output": 600,
                  "cacheRead": 3,
                  "cacheCreation": 4,
                  "costUsd": 0.01,
                  "pricingModel": "claude-opus-5-5",
                  "statusCode": 200,
                  "project": "Bruce",
                  "fidelity": "exact",
                  "latencyMs": 2500,
                  "firstTokenMs": 500
                }]
              },
              "credentialUpdates": [],
              "credentialChallenges": [],
              "diagnostics": []
            }
            """.utf8
        )
        let client = RequestLogClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            launcher: launcher
        )
        let page = try await client.query(
            RequestLogQuery(
                start: 0,
                end: 2_000_000_000_000,
                agentIDs: ["claude-code"],
                page: 0,
                pageSize: 50
            )
        )
        try expect(page.total == 1, "total")
        try expect(page.entries.count == 1, "entries")
        try expect(page.entries[0].input == 10, "input")
        try expect(page.entries[0].costUsd == 0.01, "cost")
        try expect(page.entries[0].speedTokensPerSecond == 240, "speed estimated from total latency")
        try expect(page.entries[0].speedText == "≈240/s", "speed text")
        try expect(page.effectiveSummary.tokens == 617, "summary tokens")
        try expect(page.models == ["claude-opus-5-5"], "models")
        try expect(page.entries[0].pricingModelText == "claude-opus-5-5", "matched price key")

        let input = try expectUnwrap(launcher.lastInput, "request input")
        let json = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        try expect(json?["module"] as? String == "request-log", "module")
        let context = json?["context"] as? [String: Any]
        try expect(context?["pageSize"] as? Int == 50, "pageSize")
        try expect(context?["agentIds"] as? [String] == ["claude-code"], "agentIds")
    }

    @MainActor
    private static func clientMapsCollectorError() async throws {
        let launcher = FakeLauncher()
        launcher.stdout = Data(
            """
            {
              "schemaVersion": 1,
              "runId": "ignored",
              "generatedAt": "2026-11-19T00:00:00Z",
              "status": "error",
              "artifact": null,
              "credentialUpdates": [],
              "credentialChallenges": [],
              "diagnostics": [{
                "code": "REQUEST_LOG_UNAVAILABLE",
                "category": "local",
                "stage": "request-log",
                "message": "请求日志库不可用",
                "retryable": true
              }]
            }
            """.utf8
        )
        let client = RequestLogClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            launcher: launcher
        )
        do {
            _ = try await client.query(RequestLogQuery(start: 0, end: 1_000))
            throw RequestLogHarnessFailure.expectation("error envelope should throw")
        } catch let error as RequestLogClientError {
            try expect(error == .collector("请求日志库不可用"), "collector message")
        }
    }

    @MainActor
    private static func missingExecutableFailsClosed() async throws {
        let client = RequestLogClient(executableURL: nil)
        do {
            _ = try await client.query(RequestLogQuery(start: 0, end: 1_000))
            throw RequestLogHarnessFailure.expectation("missing executable should throw")
        } catch let error as RequestLogClientError {
            try expect(error == .missingExecutable, "missing executable")
        }
    }

    /// 旧版/测试 fixture 可能没有 notice 字段；页面仍需可解码。
    private static func modelDecodingIsTolerantToOptionalNotice() throws {
        let json = Data(
            """
            {
              "total": 0,
              "page": 0,
              "pageSize": 50,
              "summary": null,
              "models": null,
              "entries": []
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(RequestLogPageModel.self, from: json)
        try expect(page.total == 0, "total")
        try expect(page.notice == nil, "notice")
        try expect(page.effectiveSummary.tokens == 0, "summary")
    }

    /// 默认只勾选今日有用量的受支持 Agent；用户改选后不再被覆盖；全选幂等。
    private static func agentFilterDefaultsAndSelectAllAreIdempotent() throws {
        var filter = RequestLogAgentFilter()
        let active: Set<String> = ["claude-code", "codex", "opencode"]
        try expect(filter.applyDefault(activeIDs: active), "defaults should change empty selection")
        try expect(filter.selectedIDs == ["claude-code", "codex"], "only supported active agents")
        try expect(filter.applyDefault(activeIDs: ["antigravity"]), "defaults follow today's active set")
        try expect(filter.selectedIDs == ["antigravity"], "defaults switch to the new active set")

        try expect(filter.selectAll(), "first select all changes selection")
        try expect(filter.selectedIDs == ["claude-code", "codex", "antigravity", "zcode"], "select all")
        try expect(!filter.selectAll(), "second select all is a no-op")
        try expect(filter.selectedIDs.count == 4, "select all never clears")

        try expect(filter.set("claude-code", selected: false), "manual uncheck changes selection")
        try expect(!filter.applyDefault(activeIDs: ["claude-code"]), "manual choice wins over defaults")
        try expect(!filter.selectedIDs.contains("claude-code"), "manual uncheck retained")
        try expect(!filter.set("opencode", selected: true), "unsupported agent is ignored")
    }


    /// 归一化模型缺失时展示原始标签（Antigravity Orchestrator 行不再显示 unknown）。
    private static func displayModelFallsBackToRawLabel() throws {
        let orchestrator = try JSONDecoder().decode(
            RequestLogEntryModel.self,
            from: Data(
                """
                {
                  "requestId": "agy-1",
                  "agentId": "antigravity",
                  "model": null,
                  "rawModel": "Orchestrator (Neon)",
                  "occurredAt": 1795057200000,
                  "input": 10,
                  "output": 600,
                  "cacheRead": 0,
                  "cacheCreation": 0,
                  "statusCode": 200,
                  "fidelity": "exact"
                }
                """.utf8
            )
        )
        try expect(orchestrator.displayModel == "Orchestrator (Neon)", "raw label wins over unknown")
        try expect(orchestrator.pricingModelText == "未计价", "unpriced rows say so (C249)")
        try expect(
            RequestLogViewModel.supportedAgentNames == "Claude Code / Codex / Antigravity / ZCode",
            "scope line follows the supported set"
        )

        let bare = try JSONDecoder().decode(
            RequestLogEntryModel.self,
            from: Data(
                """
                {
                  "requestId": "agy-2",
                  "agentId": "antigravity",
                  "model": null,
                  "rawModel": null,
                  "occurredAt": 1795057200000,
                  "input": 10,
                  "output": 600,
                  "cacheRead": 0,
                  "cacheCreation": 0,
                  "statusCode": 200,
                  "fidelity": "exact"
                }
                """.utf8
            )
        )
        try expect(bare.displayModel == "未标注模型", "both missing uses unlabeled placeholder")
    }

    private static func expectUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw RequestLogHarnessFailure.expectation(message)
        }
        return value
    }
}
