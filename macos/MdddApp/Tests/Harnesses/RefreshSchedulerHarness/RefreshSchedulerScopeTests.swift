import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - Provider-directed refresh (TASK-6 / TASK-7 / 任务 1.1–1.6)

extension RefreshSchedulerHarness {

    // MARK: - RefreshScope / intent merge (pure unit)

    /// `all` 优先: 任何作用域与 `all` 合并结果都是 `all`.
    static func scopeMergeAllWins() throws {
        let directed = RefreshIntent(
            reason: .manual, includesManual: true,
            scope: .subscriptionProviders([.kimi])
        )
        let merged1 = RefreshIntentMerge.merge(existing: directed, incoming: RefreshIntent(reason: .manual, includesManual: true, scope: .all))
        try refreshExpect(merged1.scope == .all, "directed ∪ all = all")
        let merged2 = RefreshIntentMerge.merge(existing: RefreshIntent(reason: .manual, includesManual: true, scope: .all), incoming: directed)
        try refreshExpect(merged2.scope == .all, "all ∪ directed = all")
    }

    /// 不同 provider 合并为并集; 同一 provider 重复合并自动去重.
    static func scopeMergeUnionAndDedup() throws {
        let a = RefreshIntent(
            reason: .manual, includesManual: true,
            scope: .subscriptionProviders([.kimi, .deepseek])
        )
        let b = RefreshIntent(
            reason: .manual, includesManual: true,
            scope: .subscriptionProviders([.deepseek, .codex])
        )
        let merged = RefreshIntentMerge.merge(existing: a, incoming: b)
        guard case .subscriptionProviders(let set) = merged.scope else {
            throw RefreshTestFailure.expectation("merge 应为 subscriptionProviders")
        }
        try refreshExpect(
            set == Set([.kimi, .deepseek, .codex]),
            "不同 provider 应合并去重, got \(set)"
        )
        let selfMerged = RefreshIntentMerge.merge(
            existing: RefreshIntent(reason: .manual, includesManual: true, scope: .subscriptionProviders([.kimi])),
            incoming: RefreshIntent(reason: .manual, includesManual: true, scope: .subscriptionProviders([.kimi]))
        )
        guard case .subscriptionProviders(let selfSet) = selfMerged.scope else {
            throw RefreshTestFailure.expectation("self merge 应为 subscriptionProviders")
        }
        try refreshExpect(selfSet == Set([.kimi]), "同 provider 去重, got \(selfSet)")
    }

    /// RefreshIntent 合并沿用作用域优先级: 含 `all` → `all`; 两个定向 → 并集.
    static func intentMergeScopeAllPriority() throws {
        let directed = RefreshIntent(
            reason: .manual, includesManual: true,
            scope: .subscriptionProviders([.kimi])
        )
        let full = RefreshIntent(reason: .manual, includesManual: true, scope: .all)
        let merged = RefreshIntentMerge.merge(existing: directed, incoming: full)
        try refreshExpect(merged.scope == .all, "intent 合并 all 优先, got \(merged.scope)")
        let merged2 = RefreshIntentMerge.merge(existing: full, incoming: directed)
        try refreshExpect(merged2.scope == .all, "intent 合并 all 优先 (反向), got \(merged2.scope)")

        let d2 = RefreshIntent(
            reason: .manual, includesManual: true,
            scope: .subscriptionProviders([.codex])
        )
        let merged3 = RefreshIntentMerge.merge(existing: directed, incoming: d2)
        guard case .subscriptionProviders(let set) = merged3.scope else {
            throw RefreshTestFailure.expectation("定向合并应为 subscriptionProviders")
        }
        try refreshExpect(set == Set([.kimi, .codex]), "两个定向合并为并集, got \(set)")
    }

    // MARK: - Directed refresh lifecycle (scheduler + MockCollectorExecutor)

    /// 成功路径: started → finished, 不触发 failed/cancelled, 仅运行一次.
    static func directedRefreshProviderSuccessCallbacks(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [SubscriptionProviderID] = []
        var finished: [SubscriptionProviderID] = []
        var failed: [SubscriptionProviderID] = []
        var cancelled: [SubscriptionProviderID] = []
        scheduler.onSubscriptionRefreshState = { provider, state in
            switch state {
            case .started: started.append(provider)
            case .finished: finished.append(provider)
            case .failed: failed.append(provider)
            case .cancelled: cancelled.append(provider)
            }
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        scheduler.refreshSubscription(.kimi)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "成功定向刷新应只运行一次, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(started == [.kimi], "成功路径 started 触发 kimi, got \(started)")
        try refreshExpect(finished == [.kimi], "成功路径 finished 触发 kimi, got \(finished)")
        try refreshExpect(failed.isEmpty, "成功路径不应 failed, got \(failed)")
        try refreshExpect(cancelled.isEmpty, "成功路径不应 cancelled, got \(cancelled)")
    }

    /// 运行期间重复点击同一 provider: 合并去重为单个 pending, 释放后只多跑一次.
    static func directedRefreshRepeatedClicksDedupe(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = true
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [SubscriptionProviderID] = []
        var finished: [SubscriptionProviderID] = []
        var failed: [SubscriptionProviderID] = []
        var cancelled: [SubscriptionProviderID] = []
        scheduler.onSubscriptionRefreshState = { provider, state in
            switch state {
            case .started: started.append(provider)
            case .finished: finished.append(provider)
            case .failed: failed.append(provider)
            case .cancelled: cancelled.append(provider)
            }
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 初次全量刷新 (阻塞)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        scheduler.refreshSubscription(.kimi)
        scheduler.refreshSubscription(.kimi)

        let pendingScope = scheduler.moduleState(for: .agentUsage)?.pendingIntent?.scope
        guard case .subscriptionProviders(let set) = pendingScope else {
            throw RefreshTestFailure.expectation(
                "pending 作用域应为 subscriptionProviders, got \(String(describing: pendingScope))"
            )
        }
        try refreshExpect(set == Set([.kimi]), "重复点击同一 provider 应去重, got \(set)")

        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent == nil,
            "pending 应被排空"
        )
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "重复点击只产生一次额外定向运行, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(started == [.kimi], "started 应只触发一次 kimi, got \(started)")
        try refreshExpect(finished == [.kimi], "finished 应只触发一次 kimi, got \(finished)")
        try refreshExpect(failed.isEmpty, "不应有 failed, got \(failed)")
    }

    /// 运行期间定向点击 + 全量手动: 合并为 `all` (全量优先, 定向被吸收), 无 provider 回调.
    static func directedRefreshAllPriorityAbsorbsDirected(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = true
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [SubscriptionProviderID] = []
        var finished: [SubscriptionProviderID] = []
        scheduler.onSubscriptionRefreshState = { provider, state in
            switch state {
            case .started: started.append(provider)
            case .finished: finished.append(provider)
            default: break
            }
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 初次全量刷新 (阻塞)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        scheduler.refreshSubscription(.kimi)
        scheduler.refresh(.agentUsage)

        let pendingScope = scheduler.moduleState(for: .agentUsage)?.pendingIntent?.scope
        try refreshExpect(
            pendingScope == .all,
            "定向 + 全量合并应为 all (全量优先), got \(String(describing: pendingScope))"
        )

        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "全量吸收定向, 仅一次额外运行, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        // 合并结果为 all -> 非定向运行, 不应触发 provider 级回调.
        try refreshExpect(started.isEmpty, "all 合并后不应触发 provider started, got \(started)")
        try refreshExpect(finished.isEmpty, "all 合并后不应触发 provider finished, got \(finished)")
    }

    /// 并发上限下: 模块运行中, 定向请求进入 pending 不丢, 运行后执行 (容量/排队).
    static func directedRefreshQueuedWhileRunning(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = true
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [SubscriptionProviderID] = []
        var finished: [SubscriptionProviderID] = []
        scheduler.onSubscriptionRefreshState = { provider, state in
            switch state {
            case .started: started.append(provider)
            case .finished: finished.append(provider)
            default: break
            }
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 初次全量刷新 (阻塞)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        scheduler.refreshSubscription(.deepseek)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent != nil,
            "运行中的模块应将定向请求排队为 pending"
        )
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "定向请求不应在模块运行时提前执行"
        )

        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "排队的定向请求应在运行后执行, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(started == [.deepseek], "started 应触发 deepseek, got \(started)")
        try refreshExpect(finished == [.deepseek], "finished 应触发 deepseek, got \(finished)")
    }

    /// 运行中的定向刷新被 stop 取消 → 触发 provider cancelled 回调.
    static func directedRefreshCancelFiresProviderCancelled(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = true
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var started: [SubscriptionProviderID] = []
        var finished: [SubscriptionProviderID] = []
        var failed: [SubscriptionProviderID] = []
        var cancelled: [SubscriptionProviderID] = []
        scheduler.onSubscriptionRefreshState = { provider, state in
            switch state {
            case .started: started.append(provider)
            case .finished: finished.append(provider)
            case .failed: failed.append(provider)
            case .cancelled: cancelled.append(provider)
            }
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        scheduler.refreshSubscription(.kimi)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        try refreshExpect(started == [.kimi], "started 应触发 kimi, got \(started)")

        scheduler.stop()
        for _ in 0..<500 {
            if !cancelled.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        try refreshExpect(cancelled == [.kimi], "stop 应触发 provider cancelled, got \(cancelled)")
        try refreshExpect(executor.cancelAllCount >= 1, "stop 应取消运行中的 collector")
        try refreshExpect(finished.isEmpty, "取消不应触发 finished, got \(finished)")
        try refreshExpect(failed.isEmpty, "取消不应触发 failed, got \(failed)")
    }

    // MARK: - ScopedQuotaSnapshotMerger (pure unit, 任务 1.4 / 1.5)

    private static func scopeService(
        id: String, status: String, freshness: String? = nil,
        capturedAt: String? = nil, extra: [String: JSONValue] = [:]
    ) -> JSONValue {
        var obj: [String: JSONValue] = ["id": .string(id), "status": .string(status)]
        if let freshness { obj["freshness"] = .string(freshness) }
        if let capturedAt { obj["capturedAt"] = .string(capturedAt) }
        for (k, v) in extra { obj[k] = v }
        return .object(obj)
    }

    private static func scopeArtifact(
        services: [JSONValue], agents: [JSONValue] = [], totalCostUsd: JSONValue = .null
    ) -> JSONValue {
        .object([
            "generatedAt": .string("2026-08-17T00:00:00Z"),
            "services": .array(services),
            "agents": .array(agents),
            "totalCostUsd": totalCostUsd,
        ])
    }

    private static func scopeServices(in artifact: JSONValue) -> [JSONValue] {
        guard case .object(let obj) = artifact,
              case .array(let svcs)? = obj["services"] else { return [] }
        return svcs
    }

    private static func scopeServiceByID(_ id: String, in artifact: JSONValue) -> [String: JSONValue]? {
        for svc in scopeServices(in: artifact) {
            guard case .object(let o) = svc else { continue }
            guard case .string(let sid)? = o["id"] else { continue }
            if sid == id { return o }
        }
        return nil
    }

    /// 合并保留非目标 Provider 的 services、agents 与 totalCost.
    static func mergerPreservesNonTargetServicesAgentsAndCost() throws {
        let previous = scopeArtifact(
            services: [
                scopeService(id: "deepseek_aaa", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
                scopeService(id: "kimi_coding", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
            ],
            agents: [.object(["id": .string("agent-1"), "status": .string("ok")])],
            totalCostUsd: .null
        )
        let first = scopeArtifact(
            services: [
                scopeService(id: "deepseek_aaa", status: "ok", capturedAt: "2026-08-17T00:05:00Z")
            ]
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.deepseek], decisions: []
        )
        // 目标 deepseek 由 first 提供 (fresh).
        let ds = scopeServiceByID("deepseek_aaa", in: result.artifact)
        try refreshExpect(ds != nil, "目标 deepseek 应保留")
        try refreshExpect(ds?["freshness"] == JSONValue.string("fresh"), "目标成功应标 fresh, got \(String(describing: ds?["freshness"]))")
        // 非目标 kimi 从 previous 保留.
        let kimi = scopeServiceByID("kimi_coding", in: result.artifact)
        try refreshExpect(kimi != nil, "非目标 kimi 应从 previous 保留")
        // agents / totalCost 保留.
        guard case .object(let obj) = result.artifact else {
            throw RefreshTestFailure.expectation("artifact 应为 object")
        }
        try refreshExpect(obj["agents"]?.arrayValue?.count == 1, "agents 应从 previous 保留")
        try refreshExpect(obj["totalCostUsd"] == JSONValue.null, "totalCostUsd 应保留 (null)")
    }

    /// 目标成功: 标 fresh, 不伪造成功.
    static func mergerTargetSuccessMarkedFresh() throws {
        let first = scopeArtifact(
            services: [scopeService(id: "deepseek_aaa", status: "ok", capturedAt: "2026-08-17T00:05:00Z")]
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: nil, first: first, retry: nil,
            targetProviders: [.deepseek], decisions: []
        )
        let ds = scopeServiceByID("deepseek_aaa", in: result.artifact)
        try refreshExpect(ds?["freshness"] == JSONValue.string("fresh"), "目标成功应标 fresh, got \(String(describing: ds?["freshness"]))")
        try refreshExpect(ds?["status"] == JSONValue.string("ok"), "状态应保留 ok")
    }

    /// 目标失败但 previous 具备合格成功窗口: 标 stale 并复制展示字段.
    static func mergerTargetFailurePreservesStale() throws {
        let previous = scopeArtifact(
            services: [
                scopeService(
                    id: "deepseek_aaa", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z",
                    extra: ["windows": .array([.object(["usedPercent": .string("50")])]), "plan": .string("pro")]
                )
            ]
        )
        let first = scopeArtifact(
            services: [scopeService(id: "deepseek_aaa", status: "error")]
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.deepseek], decisions: []
        )
        let ds = scopeServiceByID("deepseek_aaa", in: result.artifact)
        try refreshExpect(ds?["freshness"] == JSONValue.string("stale"), "目标失败有合格历史应标 stale, got \(String(describing: ds?["freshness"]))")
        try refreshExpect(ds?["status"] == JSONValue.string("error"), "状态应保留 error")
        try refreshExpect(ds?["capturedAt"] == JSONValue.string("2026-08-17T00:00:00Z"), "stale 应复制 previous capturedAt")
        try refreshExpect(ds?["windows"] != nil, "stale 应复制 previous windows")
        try refreshExpect(ds?["plan"] == JSONValue.string("pro"), "stale 应复制 previous plan")
    }

    /// 目标失败且无合格 previous: 标 unavailable, 不写 capturedAt.
    static func mergerTargetFailureWithoutPreviousUnavailable() throws {
        let first = scopeArtifact(
            services: [scopeService(id: "deepseek_aaa", status: "error")]
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: nil, first: first, retry: nil,
            targetProviders: [.deepseek], decisions: []
        )
        let ds = scopeServiceByID("deepseek_aaa", in: result.artifact)
        try refreshExpect(ds?["freshness"] == JSONValue.string("unavailable"), "无合格历史应标 unavailable, got \(String(describing: ds?["freshness"]))")
        try refreshExpect(ds?["capturedAt"] == nil, "unavailable 不应写 capturedAt")
    }

    /// 本轮目标 Provider 未返回某账号 service: 不从前一份复活该 service.
    static func mergerDisconnectedServiceNotResurrected() throws {
        let previous = scopeArtifact(
            services: [
                scopeService(id: "deepseek_aaa", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
                scopeService(id: "deepseek_bbb", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
            ]
        )
        // 本轮只返回 aaa, bbb 已断开.
        let first = scopeArtifact(
            services: [scopeService(id: "deepseek_aaa", status: "ok", capturedAt: "2026-08-17T00:05:00Z")]
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.deepseek], decisions: []
        )
        let services = scopeServices(in: result.artifact)
        try refreshExpect(services.count == 1, "断开的 bbb 不应复活, got \(services.count)")
        try refreshExpect(scopeServiceByID("deepseek_bbb", in: result.artifact) == nil, "bbb 不应出现")
        try refreshExpect(scopeServiceByID("deepseek_aaa", in: result.artifact) != nil, "aaa 应保留")
    }
}
