import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - C062 额度节流

extension RefreshSchedulerHarness {
    private static let quotaBase = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Pure policy

    static func quotaPolicyFreshServiceStaysLocalOnly() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(capturedAt: now.addingTimeInterval(-300), attemptedAt: now.addingTimeInterval(-300))
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous,
            now: now,
            interval: 1800,
            forceRefresh: false,
            bypassCooldown: false
        )
        try refreshExpect(!policy.includeExternalQuotas, "5 分钟前的额度应只做本地 run")
        try refreshExpect(policy.skipProviders == [.claude], "新鲜 Claude 应跳过")
        try refreshExpect(policy.rateLimitedProviders.isEmpty, "正常额度不应进入冷却")
    }

    static func quotaPolicyStaleServiceQueriesAll() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(
                capturedAt: now.addingTimeInterval(-1900),
                attemptedAt: now.addingTimeInterval(-1900)
            )
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous,
            now: now,
            interval: 1800,
            forceRefresh: false,
            bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "超过 30 分钟应查询额度")
        try refreshExpect(policy.skipProviders.isEmpty, "过期 provider 不应跳过")
    }

    static func quotaPolicy429CooldownAndForceSemantics() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(
                status: "error",
                capturedAt: now.addingTimeInterval(-7200),
                note: "查询失败: Provider 请求触发限流 (HTTP 429)",
                attemptedAt: now.addingTimeInterval(-300),
                rateLimitedAt: now.addingTimeInterval(-300)
            )
        ])
        let automatic = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(!automatic.includeExternalQuotas, "429 冷却期内应只做本地 run")
        try refreshExpect(automatic.rateLimitedProviders == [.claude], "429 provider 应进入冷却")

        let boundary = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: true, bypassCooldown: false
        )
        try refreshExpect(boundary.includeExternalQuotas, "边界唤醒强制查询")
        try refreshExpect(boundary.skipProviders == [.claude], "边界唤醒仍尊重 429 冷却")

        let manual = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: true, bypassCooldown: true
        )
        try refreshExpect(manual.includeExternalQuotas, "手动刷新强制查询")
        try refreshExpect(manual.skipProviders.isEmpty, "手动刷新绕过 429 冷却")
    }

    static func quotaPolicyMultiAccountStaleForcesRefresh() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(
                id: "claude_fresh",
                capturedAt: now.addingTimeInterval(-300),
                attemptedAt: now.addingTimeInterval(-300)
            ),
            quotaService(
                id: "claude_stale",
                capturedAt: now.addingTimeInterval(-3600),
                attemptedAt: now.addingTimeInterval(-3600)
            ),
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "任一账号过期即应重查")
        try refreshExpect(!policy.skipProviders.contains(.claude), "多账号不能因单账号新鲜而整体跳过")
    }

    static func quotaPolicyPassedWindowBoundaryForcesRefresh() throws {
        let now = quotaBase
        let captured = now.addingTimeInterval(-300)
        let reset = Int(captured.timeIntervalSince1970) + 60
        let previous = quotaArtifact(services: [
            quotaService(
                capturedAt: captured,
                attemptedAt: captured,
                resetsAt: reset
            )
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "窗口已重置后必须重查额度")
        try refreshExpect(policy.skipProviders.isEmpty, "窗口重置应覆盖 30 分钟门禁")
    }

    static func quotaPolicyCodexIsNeverSkippedOnQuotaRuns() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(capturedAt: now.addingTimeInterval(-300), attemptedAt: now.addingTimeInterval(-300)),
            quotaCodexService(capturedAt: now.addingTimeInterval(-1900), attemptedAt: now.addingTimeInterval(-1900)),
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "Codex 到期应触发额度 run")
        try refreshExpect(policy.skipProviders.contains(.claude), "Claude 新鲜应跳过")
        try refreshExpect(!policy.skipProviders.contains(.codex), "Codex 不得进入 skip 集合")
    }

    static func quotaCarryOverPreservesWindowsAndMarksStale() throws {
        let now = quotaBase
        let previousService = quotaService(
            capturedAt: now.addingTimeInterval(-3600),
            attemptedAt: now.addingTimeInterval(-3600)
        )
        let currentService = quotaService(
            status: "error",
            capturedAt: nil,
            note: "查询失败: Provider 请求触发限流 (HTTP 429)"
        )
        let previous = quotaArtifact(services: [previousService])
        let current = quotaArtifact(
            services: [currentService],
            agents: [.object(["id": .string("claude-code"), "totalTokens": .integer(7)])]
        )
        let merged = QuotaCarryOverMerger.merge(
            previous: previous,
            current: current,
            policy: .includeAll,
            now: now,
            interval: 1800
        )
        let service = merged.objectValue?["services"]?.arrayValue?.first?.objectValue
        try refreshExpect(service?["freshness"]?.stringIdValue == "stale", "429 应保留旧窗口并标 stale")
        try refreshExpect(service?["windows"]?.arrayValue?.isEmpty == false, "旧窗口应保留")
        try refreshExpect(service?["rateLimitedAt"]?.stringIdValue != nil, "应记录 429 时间戳")
        try refreshExpect(service?["quotaAttemptedAt"]?.stringIdValue != nil, "应记录额度尝试时间")
        try refreshExpect(
            merged.objectValue?["agents"]?.arrayValue?.first?.objectValue?["id"]?.stringIdValue
                == "claude-code",
            "本地 agents 应保持本轮数据"
        )
    }

    static func quotaCarryOverLocalOnlyKeepsFreshServices() throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(
                capturedAt: now.addingTimeInterval(-300),
                attemptedAt: now.addingTimeInterval(-300)
            )
        ])
        let current = quotaArtifact(
            services: [],
            agents: [.object(["id": .string("claude-code"), "totalTokens": .integer(9)])]
        )
        let policy = QuotaRunPolicy(
            includeExternalQuotas: false,
            skipProviders: [.claude],
            rateLimitedProviders: []
        )
        let merged = QuotaCarryOverMerger.merge(
            previous: previous,
            current: current,
            policy: policy,
            now: now,
            interval: 1800
        )
        let service = merged.objectValue?["services"]?.arrayValue?.first?.objectValue
        try refreshExpect(service?["freshness"]?.stringIdValue == "fresh", "30 分钟内旧值仍为 fresh")
        try refreshExpect(
            merged.objectValue?["agents"]?.arrayValue?.count == 1,
            "本地 agent 数据应保留"
        )
    }

    // MARK: Scheduler integration

    static func quotaCadenceDecouplesLocalRuns(repository: URL) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                capturedAt: clock.current.addingTimeInterval(-3600),
                attemptedAt: clock.current.addingTimeInterval(-3600)
            )
        ])
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 1800, quotaRefreshInterval: 1800, wakeDedupSeconds: 0
        )
        defer { try? FileManager.default.removeItem(at: root) }
        scheduler.setRunInputProviderForTesting(QuotaPolicyInputProvider())

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            !isLocalOnly(executor.receivedContexts[0]),
            "首次无快照应查询额度"
        )

        clock.advance(by: 300)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(isLocalOnly(executor.receivedContexts[1]), "5 分钟后应只做本地 run")
        try refreshExpect(
            !hasExternalQuotas(executor.receivedContexts[1]),
            "本地 run 不得授予 externalQuotas"
        )

        clock.advance(by: 1500)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(!isLocalOnly(executor.receivedContexts[2]), "30 分钟后应重新查询额度")
        try refreshExpect(
            hasExternalQuotas(executor.receivedContexts[2]),
            "额度 run 应重新授予 externalQuotas"
        )
    }

    static func quota429CooldownSkipsUntilExpiry(repository: URL) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                status: "error",
                capturedAt: nil,
                note: "查询失败: Provider 请求触发限流 (HTTP 429)"
            )
        ])
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 1800, quotaRefreshInterval: 1800, wakeDedupSeconds: 0
        )
        defer { try? FileManager.default.removeItem(at: root) }
        scheduler.setRunInputProviderForTesting(QuotaPolicyInputProvider())

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                capturedAt: clock.current.addingTimeInterval(-3600),
                attemptedAt: clock.current.addingTimeInterval(-3600)
            )
        ])
        clock.advance(by: 300)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(isLocalOnly(executor.receivedContexts[1]), "429 冷却期内应只做本地 run")

        clock.advance(by: 1500)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(!isLocalOnly(executor.receivedContexts[2]), "冷却 30 分钟后恢复查询")
    }

    static func quotaManualRefreshBypassesCooldown(repository: URL) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                status: "error",
                capturedAt: nil,
                note: "查询失败: Provider 请求触发限流 (HTTP 429)"
            )
        ])
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 1800, quotaRefreshInterval: 1800, wakeDedupSeconds: 0
        )
        defer { try? FileManager.default.removeItem(at: root) }
        scheduler.setRunInputProviderForTesting(QuotaPolicyInputProvider())

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        clock.advance(by: 60)
        scheduler.refresh(.agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            !isLocalOnly(executor.receivedContexts[1]),
            "手动刷新应绕过 429 冷却"
        )
    }

    static func quotaBoundaryWakeForcesRefresh(repository: URL) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        let resetAt = Int(clock.current.timeIntervalSince1970) + 60
        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                capturedAt: clock.current.addingTimeInterval(-300),
                attemptedAt: clock.current.addingTimeInterval(-300),
                resetsAt: resetAt
            )
        ])
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 1800, quotaRefreshInterval: 1800, wakeDedupSeconds: 0
        )
        defer { try? FileManager.default.removeItem(at: root) }
        scheduler.setRunInputProviderForTesting(QuotaPolicyInputProvider())

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(timers.lastDelay == 80, "边界唤醒应在 reset+20s, got \(timers.lastDelay ?? -1)")
        clock.advance(by: 60)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            !isLocalOnly(executor.receivedContexts[1]),
            "边界唤醒应强制查询额度, 不能被 30 分钟门禁降级"
        )
    }

    static func wakeDedupSkipsRecentAttempt(repository: URL) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        executor.artifactOverride = quotaArtifact(services: [
            quotaService(
                capturedAt: clock.current.addingTimeInterval(-300),
                attemptedAt: clock.current.addingTimeInterval(-300)
            )
        ])
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 30, quotaRefreshInterval: 1800, wakeDedupSeconds: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        scheduler.setRunInputProviderForTesting(QuotaPolicyInputProvider())

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        clock.advance(by: 31)
        scheduler.handleWakeOrReactivation()
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "距上次尝试 31 秒的 wake 应被去重"
        )

        clock.advance(by: 30)
        scheduler.handleWakeOrReactivation()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "超过 60 秒后 wake 应恢复补偿"
        )
    }

    // MARK: Helpers

    private static func isLocalOnly(_ context: [String: JSONValue]) -> Bool {
        if case .boolean(true)? = context["localUsageOnly"] {
            return true
        }
        return false
    }

    private static func hasExternalQuotas(_ context: [String: JSONValue]) -> Bool {
        context["capabilities"]?.arrayValue?.contains(
            .string(CollectorCapability.externalQuotas.rawValue)
        ) ?? false
    }

    private static func quotaArtifact(
        services: [JSONValue],
        agents: [JSONValue] = [],
        generatedAt: Date = quotaBase
    ) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string(QuotaRefreshPolicy.timestamp(generatedAt)),
            "agents": .array(agents),
            "services": .array(services),
            "totalCostUsd": .double(1.0),
        ])
    }

    private static func quotaService(
        id: String = "claude",
        app: String = "claude",
        status: String = "ok",
        capturedAt: Date?,
        note: String = "",
        freshness: String? = nil,
        attemptedAt: Date? = nil,
        rateLimitedAt: Date? = nil,
        resetsAt: Int? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "app": .string(app),
            "name": .string("Claude"),
            "kind": .string("windows"),
            "status": .string(status),
            "note": .string(note),
            "windows": .array([
                .object([
                    "label": .string("5小时"),
                    "usedPercent": .double(10),
                    "resetsAt": .integer(resetsAt ?? 0),
                ])
            ]),
        ]
        if let capturedAt {
            object["capturedAt"] = .string(QuotaRefreshPolicy.timestamp(capturedAt))
        }
        if let freshness {
            object["freshness"] = .string(freshness)
        }
        if let attemptedAt {
            object["quotaAttemptedAt"] = .string(QuotaRefreshPolicy.timestamp(attemptedAt))
        }
        if let rateLimitedAt {
            object["rateLimitedAt"] = .string(QuotaRefreshPolicy.timestamp(rateLimitedAt))
        }
        return .object(object)
    }

    private static func quotaCodexService(
        capturedAt: Date?,
        attemptedAt: Date? = nil
    ) -> JSONValue {
        quotaService(
            id: "codex_account1",
            app: "codex",
            capturedAt: capturedAt,
            attemptedAt: attemptedAt
        )
    }
}

/// C062 测试桩: 把 QuotaRunPolicy 映射为 Collector context, 供调度用例断言.
@MainActor
private final class QuotaPolicyInputProvider: CollectorRunInputProviding {
    private(set) var policies: [QuotaRunPolicy] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        try await runInput(for: module, quotaPolicy: .includeAll)
    }

    func runInput(
        for module: CollectorModule,
        quotaPolicy: QuotaRunPolicy
    ) async throws -> CollectorRunInput {
        policies.append(quotaPolicy)
        var context: [String: JSONValue] = [:]
        if quotaPolicy.includeExternalQuotas {
            context["capabilities"] = .array([
                .string(CollectorCapability.externalQuotas.rawValue),
            ])
            if !quotaPolicy.skipProviders.isEmpty {
                context["quotaSkipProviders"] = .array(
                    quotaPolicy.skipProviders
                        .map(\.collectorAppID)
                        .sorted()
                        .map { .string($0) }
                )
            }
        } else {
            context["localUsageOnly"] = .boolean(true)
            context["capabilities"] = .array([])
        }
        return CollectorRunInput(context: context, credentials: [:])
    }

    func scopedRunInput(
        for module: CollectorModule,
        providers: Set<SubscriptionProviderID>
    ) async throws -> CollectorRunInput {
        CollectorRunInput(context: [:], credentials: [:])
    }

    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        nil
    }

    var codexTokenDecisions: [CodexTokenDecision] { [] }
}
