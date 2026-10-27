import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - C062 额度节流

extension RefreshSchedulerHarness {
    private static let quotaBase = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Policy via collector subcommand (T15)

    static func quotaPolicyFreshServiceStaysLocalOnly() async throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(capturedAt: now.addingTimeInterval(-300), attemptedAt: now.addingTimeInterval(-300))
        ])
        let policy = try await HarnessQuotaPolicy.plan(
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

    static func quotaPolicyStaleServiceQueriesAll() async throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(
                capturedAt: now.addingTimeInterval(-1900),
                attemptedAt: now.addingTimeInterval(-1900)
            )
        ])
        let policy = try await HarnessQuotaPolicy.plan(
            previous: previous,
            now: now,
            interval: 1800,
            forceRefresh: false,
            bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "超过 30 分钟应查询额度")
        try refreshExpect(policy.skipProviders.isEmpty, "过期 provider 不应跳过")
    }

    /// C118: collector 显式下发的 provider / failureKind 优先; 旧 artifact 回退 id 前缀与 note 文案。
    /// T15 起判定只在共享 collector-policy 中, 经策略子命令的回填结果回归.
    static func quotaPolicyPrefersExplicitProviderAndFailureKind() async throws {
        func service(_ fields: [String: JSONValue]) -> JSONValue {
            var object: [String: JSONValue] = [
                "id": .string("custom_account"), "name": .string("x"), "status": .string("error"),
                "windows": .array([]), "note": .string(""),
            ]
            for (key, value) in fields { object[key] = value }
            return .object(object)
        }
        func servicesByID(_ artifact: JSONValue) -> [String: [String: JSONValue]] {
            var result: [String: [String: JSONValue]] = [:]
            for service in artifact.objectValue?["services"]?.arrayValue ?? [] {
                if let object = service.objectValue, let id = object["id"]?.stringIdValue {
                    result[id] = object
                }
            }
            return result
        }
        let now = quotaBase
        // failureKind 优先于 note: Codex 限流 note 不含 429, 显式字段仍能识别;
        // 显式非限流时 note 偶然含 429 (如余额数字) 不得误判; 旧 artifact (无 failureKind 键) 仍按 note 识别
        let attempted = servicesByID(try await HarnessQuotaPolicy.merge(
            previous: nil,
            current: quotaArtifact(services: [
                service([
                    "id": .string("codex_a"), "provider": .string("codex"),
                    "failureKind": .string("rateLimit"), "note": .string("额度查询暂时失败, 请稍后重试"),
                ]),
                service([
                    "id": .string("deepseek_a"), "provider": .string("deepseek"),
                    "failureKind": .string("server"), "note": .string("查询失败: 余额 429 元以下"),
                ]),
                service(["id": .string("kimi_coding"), "note": .string("查询失败: Provider 请求触发限流 (HTTP 429)")]),
            ]),
            policy: .includeAll,
            now: now,
            interval: 1800
        ))
        try refreshExpect(attempted["codex_a"]?["rateLimitedAt"] != nil, "failureKind=rateLimit 必须识别为限流")
        try refreshExpect(attempted["deepseek_a"]?["rateLimitedAt"] == nil, "failureKind 存在时不得再匹配 note 文案")
        try refreshExpect(attempted["kimi_coding"]?["rateLimitedAt"] != nil, "旧 artifact 回退 note 文案")

        // provider 字段优先于 id 前缀; 旧 artifact 回退 id 前缀 —— 两者都随所属 provider 被跳过而回填
        let captured = JSONValue.string(ISODate.string(from: now.addingTimeInterval(-60)))
        let carried = servicesByID(try await HarnessQuotaPolicy.merge(
            previous: quotaArtifact(services: [
                service(["provider": .string("deepseek"), "status": .string("ok"), "capturedAt": captured]),
                service(["id": .string("zhipu_abc"), "status": .string("ok"), "capturedAt": captured]),
            ]),
            current: quotaArtifact(services: []),
            policy: QuotaRunPolicy(includeExternalQuotas: false, skipProviders: [.deepseek, .zhipu]),
            now: now,
            interval: 1800
        ))
        try refreshExpect(carried["custom_account"] != nil, "显式 provider 应优先于 id 推断")
        try refreshExpect(carried["zhipu_abc"] != nil, "旧 artifact 回退 id 前缀")
    }

    static func quotaPolicy429CooldownAndForceSemantics() async throws {
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
        let automatic = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(!automatic.includeExternalQuotas, "429 冷却期内应只做本地 run")
        try refreshExpect(automatic.rateLimitedProviders == [.claude], "429 provider 应进入冷却")

        let boundary = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: true, bypassCooldown: false
        )
        try refreshExpect(boundary.includeExternalQuotas, "边界唤醒强制查询")
        try refreshExpect(boundary.skipProviders == [.claude], "边界唤醒仍尊重 429 冷却")

        let manual = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: true, bypassCooldown: true
        )
        try refreshExpect(manual.includeExternalQuotas, "手动刷新强制查询")
        try refreshExpect(manual.skipProviders.isEmpty, "手动刷新绕过 429 冷却")
    }

    static func quotaPolicyMultiAccountStaleForcesRefresh() async throws {
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
        let policy = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "任一账号过期即应重查")
        try refreshExpect(!policy.skipProviders.contains(.claude), "多账号不能因单账号新鲜而整体跳过")
    }

    static func quotaPolicyPassedWindowBoundaryForcesRefresh() async throws {
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
        let policy = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "窗口已重置后必须重查额度")
        try refreshExpect(policy.skipProviders.isEmpty, "窗口重置应覆盖 30 分钟门禁")
    }

    static func quotaPolicyCodexIsNeverSkippedOnQuotaRuns() async throws {
        let now = quotaBase
        let previous = quotaArtifact(services: [
            quotaService(capturedAt: now.addingTimeInterval(-300), attemptedAt: now.addingTimeInterval(-300)),
            quotaCodexService(capturedAt: now.addingTimeInterval(-1900), attemptedAt: now.addingTimeInterval(-1900)),
        ])
        let policy = try await HarnessQuotaPolicy.plan(
            previous: previous, now: now, interval: 1800,
            forceRefresh: false, bypassCooldown: false
        )
        try refreshExpect(policy.includeExternalQuotas, "Codex 到期应触发额度 run")
        try refreshExpect(policy.skipProviders.contains(.claude), "Claude 新鲜应跳过")
        try refreshExpect(!policy.skipProviders.contains(.codex), "Codex 不得进入 skip 集合")
    }

    static func quotaCarryOverPreservesWindowsAndMarksStale() async throws {
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
        let merged = try await HarnessQuotaPolicy.merge(
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

    static func quotaCarryOverLocalOnlyKeepsFreshServices() async throws {
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
        let merged = try await HarnessQuotaPolicy.merge(
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

    // MARK: - C065 额度周期联动与锁屏双检

    static func quotaRefreshIntervalUpdatesWithSchedulerRefreshInterval(
        repository: URL
    ) async throws {
        let clock = ManualClock(start: quotaBase)
        let timers = FakeTimerScheduler()
        let executor = MockCollectorExecutor()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers,
            refreshInterval: 1800, quotaRefreshInterval: 1800
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. 切换为 5 分钟 (300s): 调度器同时联动更新 refreshInterval 与 quotaRefreshInterval
        scheduler.updateRefreshInterval(300)
        try refreshExpect(
            scheduler.refreshInterval == 300,
            "刷新间隔应更新为 300 秒"
        )
        try refreshExpect(
            scheduler.quotaRefreshInterval == 300,
            "额度刷新周期应联动更新为 300 秒 (C065)"
        )

        // 2. 5 分钟周期下, 超过 5 分钟 (如 350 秒) 的订阅额度被判定为过期需查询
        let now = quotaBase
        let expired5m = quotaArtifact(services: [
            quotaService(
                capturedAt: now.addingTimeInterval(-350),
                attemptedAt: now.addingTimeInterval(-350)
            )
        ])
        let policy5m = try await HarnessQuotaPolicy.plan(
            previous: expired5m,
            now: now,
            interval: scheduler.quotaRefreshInterval,
            forceRefresh: false,
            bypassCooldown: false
        )
        try refreshExpect(
            policy5m.includeExternalQuotas,
            "5 分钟周期下, 距今 350 秒的额度应执行云端查询而不是降级为本地 run"
        )
        try refreshExpect(
            policy5m.skipProviders.isEmpty,
            "5 分钟周期下已过期 provider 不应被跳过"
        )

        // 3. 5 分钟周期下, 距今不足 5 分钟 (如 100 秒) 的额度在定时轮询中仍保持新鲜度跳过
        let fresh5m = quotaArtifact(services: [
            quotaService(
                capturedAt: now.addingTimeInterval(-100),
                attemptedAt: now.addingTimeInterval(-100)
            )
        ])
        let policyFresh = try await HarnessQuotaPolicy.plan(
            previous: fresh5m,
            now: now,
            interval: scheduler.quotaRefreshInterval,
            forceRefresh: false,
            bypassCooldown: false
        )
        try refreshExpect(
            policyFresh.skipProviders.contains(.claude),
            "5 分钟周期下, 距今仅 100 秒的额度应避免重复查询"
        )

        // 4. 切换为 10 分钟 (600s): 同样联动更新
        scheduler.updateRefreshInterval(600)
        try refreshExpect(
            scheduler.refreshInterval == 600,
            "刷新间隔应更新为 600 秒"
        )
        try refreshExpect(
            scheduler.quotaRefreshInterval == 600,
            "额度刷新周期应联动更新为 600 秒 (C065)"
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

    /// C120: 与 Windows `quota_policy::plan` 共享的门禁对拍用例; T15 起经 mac 路径 (策略子命令).
    static func quotaPolicyMatchesSharedParityFixture(repository: URL) async throws {
        let url = repository.appendingPathComponent("tests/fixtures/quota-policy-parity/cases.json")
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard let cases = fixture.objectValue?["cases"]?.arrayValue, cases.count >= 18 else {
            throw RefreshTestFailure.expectation("quota parity fixture 缺少用例")
        }
        func strings(_ value: JSONValue?) -> [String] {
            (value?.arrayValue ?? []).compactMap(\.stringIdValue)
        }
        for item in cases {
            guard let object = item.objectValue,
                  let name = object["name"]?.stringIdValue,
                  let now = object["now"]?.stringIdValue.flatMap(ISODate.parseAllowingFractionalSeconds),
                  let interval = object["intervalSeconds"]?.intValue,
                  let force = object["forceRefresh"]?.boolValue,
                  let bypass = object["bypassCooldown"]?.boolValue,
                  let expected = object["expected"]?.objectValue else {
                throw RefreshTestFailure.expectation("quota parity fixture 用例格式无效")
            }
            let enabledRaw = strings(object["enabledProviders"])
            let enabled = Set(enabledRaw.compactMap(SubscriptionProviderID.init(rawValue:)))
            guard enabled.count == enabledRaw.count else {
                throw RefreshTestFailure.expectation("\(name): 未知 provider")
            }
            let policy = try await HarnessQuotaPolicy.plan(
                previous: .object(["services": object["services"] ?? .array([])]),
                now: now,
                interval: TimeInterval(interval),
                forceRefresh: force,
                bypassCooldown: bypass,
                enabledProviders: enabled
            )
            try refreshExpect(
                policy.includeExternalQuotas == expected["includeExternalQuotas"]?.boolValue,
                "\(name): includeExternalQuotas"
            )
            try refreshExpect(
                policy.skipProviders.map(\.rawValue).sorted() == strings(expected["skipProviders"]),
                "\(name): skipProviders \(policy.skipProviders.map(\.rawValue).sorted())"
            )
            try refreshExpect(
                policy.rateLimitedProviders.map(\.rawValue).sorted()
                    == strings(expected["rateLimitedProviders"]),
                "\(name): rateLimitedProviders"
            )
        }
    }

    /// T13: 与 Windows / 共享 collector-policy 回填共用的对拍用例
    /// (tests/fixtures/quota-carry-over-parity), 经 mac 路径 (策略子命令) 逐字段比较
    /// 合并后的有序 services (T15).
    static func quotaCarryOverMatchesSharedParityFixture(repository: URL) async throws {
        let url = repository.appendingPathComponent("tests/fixtures/quota-carry-over-parity/cases.json")
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        guard let cases = fixture.objectValue?["cases"]?.arrayValue, cases.count >= 14 else {
            throw RefreshTestFailure.expectation("carry-over parity fixture 缺少用例")
        }
        func providers(_ value: JSONValue?) throws -> Set<SubscriptionProviderID> {
            let raw = (value?.arrayValue ?? []).compactMap(\.stringIdValue)
            let parsed = Set(raw.compactMap(SubscriptionProviderID.init(rawValue:)))
            guard parsed.count == raw.count else {
                throw RefreshTestFailure.expectation("carry-over parity fixture 含未知 provider")
            }
            return parsed
        }
        var failures: [String] = []
        for item in cases {
            guard let object = item.objectValue,
                  let name = object["name"]?.stringIdValue,
                  let now = object["now"]?.stringIdValue.flatMap(ISODate.parseAllowingFractionalSeconds),
                  let interval = object["intervalSeconds"]?.intValue,
                  let policyObject = object["policy"]?.objectValue,
                  let include = policyObject["includeExternalQuotas"]?.boolValue,
                  let current = object["current"]?.arrayValue,
                  let expected = object["expected"]?.arrayValue else {
                throw RefreshTestFailure.expectation("carry-over parity fixture 用例格式无效")
            }
            let previous: JSONValue? = object["previous"]?.arrayValue.map {
                .object(["services": .array($0)])
            }
            let policy = QuotaRunPolicy(
                includeExternalQuotas: include,
                skipProviders: try providers(policyObject["skipProviders"]),
                rateLimitedProviders: try providers(policyObject["rateLimitedProviders"])
            )
            let merged = try await HarnessQuotaPolicy.merge(
                previous: previous,
                current: .object(["services": .array(current)]),
                policy: policy,
                now: now,
                interval: TimeInterval(interval)
            )
            if merged.objectValue?["services"]?.arrayValue != expected {
                failures.append(name)
            }
        }
        try refreshExpect(failures.isEmpty, "carry-over parity 不一致: \(failures)")
    }

    private static func quotaArtifact(
        services: [JSONValue],
        agents: [JSONValue] = [],
        generatedAt: Date = quotaBase
    ) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string(ISODate.string(from: generatedAt)),
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
            object["capturedAt"] = .string(ISODate.string(from: capturedAt))
        }
        if let freshness {
            object["freshness"] = .string(freshness)
        }
        if let attemptedAt {
            object["quotaAttemptedAt"] = .string(ISODate.string(from: attemptedAt))
        }
        if let rateLimitedAt {
            object["rateLimitedAt"] = .string(ISODate.string(from: rateLimitedAt))
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
/// (C071 起供锁屏抑制回填用例共用, 故放开为模块内可见.)
@MainActor
final class QuotaPolicyInputProvider: CollectorRunInputProviding {
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
