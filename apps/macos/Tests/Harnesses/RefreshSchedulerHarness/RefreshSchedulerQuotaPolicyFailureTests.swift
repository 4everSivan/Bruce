import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - T15 策略入口降级语义

/// 按操作名脚本化策略入口: 未脚本化的操作经真实 collector 策略子命令计算.
@MainActor
final class ScriptedQuotaPolicyTransport {
    enum Behavior {
        case fail(Error)
        case respond(Data)
    }

    var behaviors: [String: Behavior] = [:]
    private(set) var operations: [String] = []

    func engine() -> CollectorQuotaPolicy {
        CollectorQuotaPolicy { [self] input in try await self.call(input) }
    }

    private func call(_ input: Data) async throws -> Data {
        let request = try JSONDecoder().decode(JSONValue.self, from: input)
        let operation = request.objectValue?["operation"]?.stringIdValue ?? ""
        operations.append(operation)
        switch behaviors[operation] {
        case .fail(let error)?:
            throw error
        case .respond(let data)?:
            return data
        case nil:
            return try await HarnessQuotaPolicy.transport(input)
        }
    }
}

extension RefreshSchedulerHarness {
    private static let failureBase = Date(timeIntervalSince1970: 1_800_000_000)

    private static func failureArtifact(capturedAt: Date, usedPercent: Int) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string(ISODate.string(from: capturedAt)),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string("claude_a"),
                    "provider": .string("claude"),
                    "name": .string("Claude"),
                    "kind": .string("windows"),
                    "status": .string("ok"),
                    "windows": .array([
                        .object(["label": .string("5小时"), "usedPercent": .integer(usedPercent)])
                    ]),
                    "capturedAt": .string(ISODate.string(from: capturedAt)),
                    "quotaAttemptedAt": .string(ISODate.string(from: capturedAt)),
                ])
            ]),
            "totalCostUsd": .double(1.0),
        ])
    }

    private static func failurePipeline(
        executor: any CollectorExecuting,
        transport: ScriptedQuotaPolicyTransport,
        store: ArtifactStore,
        credentialUpdates: CredentialUpdateCoordinator? = nil
    ) -> RefreshExecutionPipeline {
        RefreshExecutionPipeline(
            executor: executor,
            quotaPolicy: transport.engine(),
            store: store,
            runInputProvider: nil,
            credentialUpdates: credentialUpdates,
            codexTokenManager: nil,
            isStopped: { false },
            now: { failureBase }
        )
    }

    private static func failureRequest(scope: RefreshScope = .all) -> RefreshPipelineRequest {
        RefreshPipelineRequest(
            module: .agentUsage,
            intent: .timer(),
            scope: scope,
            staleAfter: 3600,
            now: failureBase,
            quotaRefreshInterval: 1800
        )
    }

    private static func temporaryStore() throws -> (ArtifactStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-policy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try ArtifactStore(rootURL: root), root)
    }

    /// 门禁失败: 不猜测策略、不启动采集, 按采集失败返回, 不写 store.
    static func quotaPolicyPlanFailureSkipsCollection(repository: URL) async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = failureArtifact(capturedAt: failureBase.addingTimeInterval(-3600), usedPercent: 10)
        try store.publish(previous, for: .agentUsage, attemptedAt: failureBase.addingTimeInterval(-3600))
        let executor = MockCollectorExecutor()
        executor.repository = repository
        let transport = ScriptedQuotaPolicyTransport()
        transport.behaviors["quotaPlan"] = .fail(CollectorRunnerError.launchFailed)

        let result = await failurePipeline(executor: executor, transport: transport, store: store)
            .run(failureRequest())

        guard case .collectorFailed(let error) = result else {
            throw RefreshTestFailure.expectation("门禁失败应按采集失败返回, got \(result)")
        }
        try refreshExpect(
            (error as? CollectorRunnerError) == .launchFailed,
            "应透传策略入口的失败原因, got \(error)"
        )
        try refreshExpect((executor.runCount[.agentUsage] ?? 0) == 0, "门禁失败不得启动采集")
        try refreshExpect(transport.operations == ["quotaPlan"], "门禁失败后不得再调用回填")
        let stored = try store.load(.agentUsage, now: failureBase, staleAfter: 3600)
        try refreshExpect(stored.artifact == previous, "上一份 artifact 保持不变")
    }

    /// 回填被拒绝 (error 信封): 不发布本轮结果, 上一份 artifact 保持展示;
    /// 本轮轮换的令牌仍写回凭证存储 (一次性 refresh token 不随本轮丢失).
    static func quotaPolicyMergeRejectionKeepsPreviousArtifact() async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = failureArtifact(capturedAt: failureBase.addingTimeInterval(-3600), usedPercent: 10)
        try store.publish(previous, for: .agentUsage, attemptedAt: failureBase.addingTimeInterval(-3600))

        let credentials = InMemoryCredentialStore()
        let accounts = ProviderAccountStore(provider: .claude, credentialStore: credentials)
        _ = try accounts.addAccount(
            accountID: "acc-claude-1",
            displayName: "Claude · fixture",
            credentialJSON: #"{"claudeAiOauth":{"accessToken":"old"}}"#
        )
        let executor = CredentialUpdateExecutor(
            artifact: failureArtifact(capturedAt: failureBase, usedPercent: 55),
            updates: [
                .object([
                    "provider": .string("claude"),
                    "accountId": .string("acc-claude-1"),
                    "kind": .string("oauthTokens"),
                    "operation": .string("replace"),
                    "credentials": .object([
                        "access_token": .string("rotated-access"),
                        "refresh_token": .string("rotated-refresh"),
                    ]),
                ])
            ]
        )
        let transport = ScriptedQuotaPolicyTransport()
        transport.behaviors["quotaMerge"] = .respond(Data(
            #"{"schemaVersion":1,"status":"error","operation":"quotaMerge","result":null,"diagnostics":[{"code":"POLICY_INVALID_REQUEST","message":"x"}]}"#.utf8
        ))

        let result = await failurePipeline(
            executor: executor,
            transport: transport,
            store: store,
            credentialUpdates: CredentialUpdateCoordinator(credentialStore: credentials)
        ).run(failureRequest())

        guard case .collectorFailed(let error) = result else {
            throw RefreshTestFailure.expectation("回填失败应按采集失败返回, got \(result)")
        }
        try refreshExpect(
            (error as? QuotaPolicyError) == .rejected(code: "POLICY_INVALID_REQUEST"),
            "应携带入口诊断码, got \(error)"
        )
        try refreshExpect(transport.operations == ["quotaPlan", "quotaMerge"], "门禁照常经子命令计算")
        try refreshExpect((executor.runCount[.agentUsage] ?? 0) == 1, "采集已执行一次")
        let stored = try store.load(.agentUsage, now: failureBase, staleAfter: 3600)
        try refreshExpect(stored.artifact == previous, "未回填的本轮结果不得发布")
        let record = try accounts.loadRecord(for: "acc-claude-1")
        try refreshExpect(
            record?.credentialJSON.contains("rotated-access") == true,
            "回填失败时轮换令牌仍须写回"
        )
    }

    /// 输出不是合法信封 (如被截断): 同样不发布, 错误为 invalidResponse.
    static func quotaPolicyInvalidResponseFailsRound(repository: URL) async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = MockCollectorExecutor()
        executor.repository = repository
        executor.artifactOverride = failureArtifact(capturedAt: failureBase, usedPercent: 55)
        let transport = ScriptedQuotaPolicyTransport()
        transport.behaviors["quotaMerge"] = .respond(Data("{\"schemaVersion\":1,".utf8))

        let result = await failurePipeline(executor: executor, transport: transport, store: store)
            .run(failureRequest())

        guard case .collectorFailed(let error) = result else {
            throw RefreshTestFailure.expectation("非法输出应按采集失败返回, got \(result)")
        }
        try refreshExpect((error as? QuotaPolicyError) == .invalidResponse, "错误应为 invalidResponse, got \(error)")
        try refreshExpect(
            (try? store.load(.agentUsage, now: failureBase, staleAfter: 3600)) == nil,
            "首轮失败不得写出任何 artifact"
        )
    }

    /// 定向刷新的时间戳标注失败: 同样不发布 (与全量回填同一降级口径).
    static func quotaPolicyScopedAnnotateFailureFailsRound(repository: URL) async throws {
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = failureArtifact(capturedAt: failureBase.addingTimeInterval(-3600), usedPercent: 10)
        try store.publish(previous, for: .agentUsage, attemptedAt: failureBase.addingTimeInterval(-3600))
        let executor = MockCollectorExecutor()
        executor.repository = repository
        executor.artifactOverride = failureArtifact(capturedAt: failureBase, usedPercent: 55)
        let transport = ScriptedQuotaPolicyTransport()
        transport.behaviors["quotaAnnotate"] = .fail(CollectorRunnerError.timedOut)

        let result = await failurePipeline(executor: executor, transport: transport, store: store)
            .run(failureRequest(scope: .subscriptionProviders([.claude])))

        guard case .collectorFailed(let error) = result else {
            throw RefreshTestFailure.expectation("定向标注失败应按采集失败返回, got \(result)")
        }
        try refreshExpect((error as? CollectorRunnerError) == .timedOut, "应透传超时, got \(error)")
        try refreshExpect(transport.operations == ["quotaAnnotate"], "定向刷新不经门禁")
        let stored = try store.load(.agentUsage, now: failureBase, staleAfter: 3600)
        try refreshExpect(stored.artifact == previous, "上一份 artifact 保持不变")
    }

    /// 调度层: 策略入口不可用时整轮按采集失败退避, 不发布、不清空已展示的数据.
    static func quotaPolicyUnavailableBacksOffScheduler(repository: URL) async throws {
        let executor = MockCollectorExecutor()
        executor.repository = repository
        let clock = ManualClock(start: failureBase)
        let timers = FakeTimerScheduler()
        let (store, root) = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = failureArtifact(capturedAt: failureBase.addingTimeInterval(-60), usedPercent: 10)
        try store.publish(previous, for: .agentUsage, attemptedAt: failureBase.addingTimeInterval(-60))
        // 不注入策略: Mock executor 不提供 policy 子命令, 调度器取「不可用」入口.
        let unavailable = RefreshScheduler(
            executor: executor,
            store: store,
            clock: clock,
            timerScheduler: timers,
            configuration: SchedulerConfiguration(
                refreshInterval: 1800,
                staleAfter: 3600,
                maxBackoffRetries: 3,
                baseBackoffSeconds: 30,
                maxBackoffSeconds: 1800,
                rateLimitBackoffSeconds: 300,
                capacityLimit: 2,
                quotaRefreshInterval: 1800,
                wakeDedupSeconds: 0
            ),
            jitterProvider: { _ in 0 },
            registerWakeNotifications: false
        )
        var published: [JSONValue?] = []
        unavailable.onArtifactChange = { _, artifact in published.append(artifact) }

        unavailable.start()
        unavailable.enableModule(.agentUsage)
        timers.fireFirst()
        for _ in 0..<1_000 {
            if unavailable.moduleState(for: .agentUsage)?.backoffRetryCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(1))
        }

        try refreshExpect(
            unavailable.moduleState(for: .agentUsage)?.backoffRetryCount == 1,
            "策略入口不可用应进入退避重试"
        )
        try refreshExpect(
            unavailable.moduleState(for: .agentUsage)?.lastErrorCategory == .collector,
            "失败分类应为 collector"
        )
        try refreshExpect((executor.runCount[.agentUsage] ?? 0) == 0, "Mock executor 无策略入口: 不得启动采集")
        try refreshExpect(
            published.allSatisfy { $0 == nil || $0 == previous },
            "不得发布新的 artifact"
        )
        let stored = try store.load(.agentUsage, now: failureBase, staleAfter: 3600)
        try refreshExpect(stored.artifact == previous, "已展示的上一份 artifact 不被清空")
        unavailable.stop()
    }
}
