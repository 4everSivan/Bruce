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

    // MARK: - Codex 定向路径 (任务 6B / 任务 1.4–1.5: 复用 legacy 四源合并)

    /// 定向 Codex 失败时, 复用 legacy `CodexQuotaSnapshotMerger` 的 legacy ID 迁移:
    /// previous 的 legacy id 额度迁移到本轮 current id 并标 stale, 不丢失旧窗口.
    static func mergerCodexTargetDelegatesLegacyMigrationToStale() throws {
        let previous = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerLegacy1, status: "ok", usedPercent: 48,
                    capturedAt: "2026-08-17T00:00:00Z", freshness: "fresh"
                ),
                scopeService(id: "kimi", status: "ok"),
            ],
            agents: [.object(["id": .string("agent-1"), "status": .string("ok")])],
            totalCostUsd: .null
        )
        // 定向运行的首轮只返回目标 Codex service (不含非目标 kimi).
        let first = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "error", usedPercent: 0,
                    capturedAt: nil, freshness: "unavailable",
                    failureKind: "rateLimit", note: "额度查询暂时失败, 请稍后重试"
                ),
            ],
            agents: [], totalCostUsd: .null
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.codex],
            decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            ))]
        )
        let services = try mergerServices(result.artifact)
        try refreshExpect(services[mergerLegacy1] == nil, "Codex 定向输出不得残留 legacy id")
        try refreshExpect(services["kimi"] != nil, "非目标 kimi 应从 previous 保留")
        let svc = try mergerServiceValue(result.artifact, id: mergerService1)
        try refreshExpect(svc["freshness"] == .string("stale"), "Codex 定向应复用 legacy 合并: 本轮失败+旧数据→stale, got \(String(describing: svc["freshness"]))")
        try refreshExpect(svc["failureKind"] == .string("rateLimit"), "必须保留本轮 failureKind")
        try refreshExpect(svc["capturedAt"] == .string("2026-08-17T00:00:00Z"), "legacy 迁移必须保留旧 capturedAt")
        guard case .array(let windows)? = svc["windows"],
              let w = windows.first?.objectValue,
              let used = JSONNumber.double(w["usedPercent"]) else {
            throw RefreshTestFailure.expectation("legacy 迁移必须保留旧 windows")
        }
        try refreshExpect(used == 48, "必须保留旧窗口 48%, got \(used)")
    }

    /// 定向 Codex: 首轮 401 + retry 成功 → 复用 legacy 一次 forced refresh +
    /// 一次 retry-only, 输出 fresh 且 capturedAt 取 retry 时间.
    static func mergerCodexTargetRetrySuccessFresh() throws {
        let first = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "error", usedPercent: 0,
                    capturedAt: nil, freshness: "unavailable",
                    failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
                ),
            ],
            agents: [], totalCostUsd: .null
        )
        let retry = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "ok", usedPercent: 40,
                    capturedAt: "2026-08-17T00:06:00Z", freshness: "fresh"
                ),
            ],
            agents: [], totalCostUsd: .null
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: nil, first: first, retry: retry,
            targetProviders: [.codex],
            decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            ))]
        )
        let svc = try mergerServiceValue(result.artifact, id: mergerService1)
        try refreshExpect(svc["status"] == .string("ok"), "Codex 定向 retry 成功必须覆盖 status")
        try refreshExpect(svc["freshness"] == .string("fresh"), "Codex 定向 retry 成功必须为 fresh")
        try refreshExpect(svc["capturedAt"] == .string("2026-08-17T00:06:00Z"), "fresh 必须使用 retry 的 capturedAt")
    }

    /// 定向 Codex 首轮即失败且无合格历史 → unavailable, 不伪造 success.
    static func mergerCodexTargetNoPreviousUnavailable() throws {
        let first = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "error", usedPercent: 0,
                    capturedAt: nil, freshness: "unavailable",
                    failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
                ),
            ],
            agents: [], totalCostUsd: .null
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: nil, first: first, retry: nil,
            targetProviders: [.codex],
            decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            ))]
        )
        let svc = try mergerServiceValue(result.artifact, id: mergerService1)
        try refreshExpect(svc["freshness"] == .string("unavailable"), "Codex 定向无旧数据必须为 unavailable")
        try refreshExpect(svc["capturedAt"] == nil, "unavailable 不得写 capturedAt")
        try refreshExpect(svc["failureKind"] == .string("auth"), "必须保留本轮 failureKind=auth")
    }

    /// 定向 [.codex, .deepseek] 混合: Codex 走 legacy 四源合并 (legacy 迁移→stale),
    /// 非 Codex 目标 deepseek 按 service.id 合并为 fresh, 非目标 kimi 原样保留.
    static func mergerCodexTargetMixedWithNonCodex() throws {
        let previous = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerLegacy1, status: "ok", usedPercent: 48,
                    capturedAt: "2026-08-17T00:00:00Z", freshness: "fresh"
                ),
                scopeService(id: "deepseek_aaa", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
                scopeService(id: "kimi", status: "ok"),
            ],
            agents: [.object(["id": .string("agent-1"), "status": .string("ok")])],
            totalCostUsd: .null
        )
        let first = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "error", usedPercent: 0,
                    capturedAt: nil, freshness: "unavailable",
                    failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
                ),
                scopeService(id: "deepseek_aaa", status: "ok", capturedAt: "2026-08-17T00:05:00Z"),
            ],
            agents: [], totalCostUsd: .null
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.codex, .deepseek],
            decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            ))]
        )
        let services = try mergerServices(result.artifact)
        try refreshExpect(services["kimi"] != nil, "非目标 kimi 应原样保留")
        try refreshExpect(services[mergerLegacy1] == nil, "legacy id 不应残留")
        let codex = try mergerServiceValue(result.artifact, id: mergerService1)
        try refreshExpect(codex["freshness"] == .string("stale"), "Codex 目标应复用 legacy 合并→stale")
        try refreshExpect(codex["capturedAt"] == .string("2026-08-17T00:00:00Z"), "Codex 必须保留旧 capturedAt")
        let deepseek = try mergerServiceValue(result.artifact, id: "deepseek_aaa")
        try refreshExpect(deepseek["freshness"] == .string("fresh"), "非 Codex 目标成功应标 fresh")
        try refreshExpect(deepseek["status"] == .string("ok"), "deepseek 状态应保留 ok")
    }

    /// 定向 deepseek (不含 codex) 时, 上一份的 Codex service 作为非目标原样保留,
    /// 既不被重新合并也不被丢弃/伪造 (credential rotation 边界内的快照静止).
    static func mergerCodexNotTargetPreservesPreviousCodex() throws {
        let previous = scopeArtifact(
            services: [
                mergerCodexService(
                    id: mergerService1, status: "ok", usedPercent: 33,
                    capturedAt: "2026-08-17T00:00:00Z", freshness: "fresh"
                ),
                scopeService(id: "deepseek_aaa", status: "ok", freshness: "fresh", capturedAt: "2026-08-17T00:00:00Z"),
            ],
            agents: [.object(["id": .string("agent-1"), "status": .string("ok")])],
            totalCostUsd: .null
        )
        let first = scopeArtifact(
            services: [
                scopeService(id: "deepseek_aaa", status: "ok", capturedAt: "2026-08-17T00:05:00Z"),
            ],
            agents: [], totalCostUsd: .null
        )
        let result = ScopedQuotaSnapshotMerger().merge(
            previous: previous, first: first, retry: nil,
            targetProviders: [.deepseek],
            decisions: []
        )
        let services = try mergerServices(result.artifact)
        let codex = try mergerServiceValue(result.artifact, id: mergerService1)
        try refreshExpect(codex["freshness"] == .string("fresh"), "非目标 Codex 必须原样保留 fresh")
        try refreshExpect(codex["capturedAt"] == .string("2026-08-17T00:00:00Z"), "非目标 Codex 不得被改写 capturedAt")
        try refreshExpect(services["deepseek_aaa"] != nil, "目标 deepseek 应保留")
    }

    // MARK: - 全量路径回归 (任务 6B: 定向分支不得改变 .all 行为)

    /// 全量刷新 (scope=.all) 走标准 finalizer 路径, 不进入定向合并; 发布完整多
    /// Provider artifact (codex/deepseek/kimi 全部保留), 证明定向分支未收窄全量路径.
    /// 基于已校验的 v1 fixture 克隆 service 形状以构造多 Provider 输入, 避免手搓
    /// 触发 schema 校验失败.
    static func mergerFullScopeRegressionPublishesCompleteArtifact(
        repository: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-scop-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(rootURL: root)

        // 以合法 fixture 为蓝本, 克隆其 service 形状追加 deepseek / codex 两个 Provider.
        let fixture = try loadFixture(repository: repository, module: .agentUsage)
        guard case .object(let fObj) = fixture,
              case .array(let fServices)? = fObj["services"] else {
            throw RefreshTestFailure.expectation("fixture 结构不符")
        }
        let template = fServices.first { $0.stringId() == "kimi_coding" } ?? fServices[0]
        func clone(_ base: JSONValue, id: String, app: String?) -> JSONValue {
            guard case .object(var obj) = base else { return base }
            obj["id"] = .string(id)
            if let app {
                obj["app"] = .string(app)
            } else {
                obj.removeValue(forKey: "app")
            }
            obj["capturedAt"] = .string("2026-08-17T01:00:00+08:00")
            return .object(obj)
        }
        var services = fServices
        services.append(clone(template, id: "deepseek_aaa", app: nil))
        services.append(clone(template, id: "codex_full1", app: "codex"))
        var newObj = fObj
        newObj["services"] = .array(services)

        let executor = MockCollectorExecutor()
        executor.repository = repository
        executor.artifactOverride = .object(newObj)
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            store: store,
            runInputProvider: nil,
            credentialUpdates: nil,
            codexTokenManager: nil,
            isStopped: { false }
        )
        let request = RefreshPipelineRequest(
            module: .agentUsage,
            intent: .timer(),
            scope: .all,
            staleAfter: 3600,
            now: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let result = await pipeline.run(request)
        guard case .completed(let completed) = result else {
            throw RefreshTestFailure.expectation(
                "全量 scope 应完成, got \(String(describing: result))"
            )
        }
        guard let artifact = completed.publishedArtifact else {
            throw RefreshTestFailure.expectation("全量 scope 应发布 artifact")
        }
        let publishedServices = try mergerServices(artifact)
        try refreshExpect(publishedServices["kimi_coding"] != nil, "全量路径应保留 kimi service")
        try refreshExpect(publishedServices["deepseek_aaa"] != nil, "全量路径应保留 deepseek service")
        try refreshExpect(publishedServices["codex_full1"] != nil, "全量路径应保留 codex service")
        try refreshExpect(
            publishedServices.count >= fServices.count + 2,
            "全量路径不得被定向合并收窄, got \(publishedServices.count)"
        )
        guard case .object(let obj) = artifact,
              case .array(let agents)? = obj["agents"] else {
            throw RefreshTestFailure.expectation("全量 artifact 应含 agents")
        }
        try refreshExpect(!agents.isEmpty, "全量 artifact 应保留 agents")
    }
}
