import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 锁屏订阅抑制 (C064)

extension RefreshSchedulerHarness {
    /// 锁屏状态下自动刷新抑制外部额度查询 (降级为 localOnly), 解锁后自动补偿全量刷新.
    static func screenLockSuppressesQuotaQueryAndWakesOnUnlock(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let lockState = StubScreenLockState(isLocked: true)
        let (scheduler, _, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            screenLock: lockState
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        try refreshExpect(lockState.startCount == 1, "调度器启动应接通锁屏监视")
        try refreshExpect(scheduler.isScreenLocked, "调度器应感知初始锁屏状态")

        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 触发定时刷新 (锁屏状态下)

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // 验证执行了本地采集 (无外部额度请求)
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "锁屏时允许本地采集运行, got \(executor.runCount[.agentUsage] ?? 0)"
        )

        // 屏幕解锁: 自动触发 handleScreenUnlocked 补偿全量刷新
        lockState.setLocked(false)
        try refreshExpect(!scheduler.isScreenLocked, "屏幕解锁后 isScreenLocked 应为 false")

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "解锁后应触发补偿刷新, got \(executor.runCount[.agentUsage] ?? 0)"
        )

        scheduler.stop()
        try refreshExpect(lockState.stopCount == 1, "调度器停止时应注销锁屏监视")
    }

    /// 开关关闭时不抑制锁屏刷新.
    static func screenLockSuppressionDisabledAllowsQuotaQuery(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let lockState = StubScreenLockState(isLocked: true)
        let (scheduler, _, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            screenLock: lockState
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.setPauseSubscriptionRefreshOnScreenLock(false)
        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "开关关闭时锁屏状态下刷新照常执行"
        )
        scheduler.stop()
    }

    /// 纯策略: 锁屏抑制强制本地专用 run, 且 skipProviders 覆盖上一份全部
    /// provider (含 codex), 供 QuotaCarryOverMerger 回填 (C071).
    static func quotaPolicySuppressedOnScreenLock() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let captured = ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))
        let previous = JSONValue.object([
            "services": .array([
                .object([
                    "id": .string("claude"),
                    "app": .string("claude"),
                    "capturedAt": .string(captured),
                    "attemptedAt": .string(captured)
                ]),
                .object([
                    "id": .string("codex"),
                    "app": .string("codex"),
                    "capturedAt": .string(captured),
                    "attemptedAt": .string(captured)
                ])
            ])
        ])
        let policy = QuotaRefreshPolicy.plan(
            previous: previous,
            now: now,
            interval: 1800,
            forceRefresh: true,
            bypassCooldown: true,
            suppressExternalQuotas: true
        )
        try refreshExpect(!policy.includeExternalQuotas, "锁屏抑制时必须返回本地专用 run，即使为 forceRefresh")
        try refreshExpect(
            policy.skipProviders == [.claude, .codex],
            "锁屏抑制等价于全部 provider 跳过, 上一份 services 必须可被回填 (C071)"
        )
    }

    /// C071: 锁屏抑制运行发布的 artifact 必须原样保留上一份订阅 services,
    /// 否则仪表盘订阅卡在解锁后被清空 (曾为线上缺陷).
    static func screenLockSuppressedRunCarriesOverServices(
        repository: URL
    ) async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let executor = MockCollectorExecutor()
        let clock = ManualClock(start: base)
        let timers = FakeTimerScheduler()
        let lockState = StubScreenLockState(isLocked: false)
        let (scheduler, store, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            screenLock: lockState,
            refreshInterval: 1800,
            quotaRefreshInterval: 1800,
            wakeDedupSeconds: 0
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let inputProvider = QuotaPolicyInputProvider()
        scheduler.setRunInputProviderForTesting(inputProvider)

        // 预置上一份成功 artifact (claude + codex, 60 秒前捕获): 等价于
        // 锁屏前最后一次全量刷新的落盘结果.
        let fresh = base.addingTimeInterval(-60)
        let seeded = JSONValue.object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string(QuotaRefreshPolicy.timestamp(fresh)),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string("claude_a"),
                    "app": .string("claude"),
                    "name": .string("Claude"),
                    "kind": .string("windows"),
                    "status": .string("ok"),
                    "note": .string(""),
                    "windows": .array([
                        .object([
                            "label": .string("5小时"),
                            "usedPercent": .double(10),
                            "resetsAt": .integer(0),
                        ])
                    ]),
                    "capturedAt": .string(QuotaRefreshPolicy.timestamp(fresh)),
                ]),
                .object([
                    "id": .string("codex_b"),
                    "app": .string("codex"),
                    "name": .string("Codex"),
                    "kind": .string("windows"),
                    "status": .string("ok"),
                    "note": .string(""),
                    "windows": .array([
                        .object([
                            "label": .string("周"),
                            "usedPercent": .double(20),
                            "resetsAt": .integer(0),
                        ])
                    ]),
                    "capturedAt": .string(QuotaRefreshPolicy.timestamp(fresh)),
                ]),
            ]),
            "totalCostUsd": .double(1.0),
        ])
        try store.publish(seeded, for: .agentUsage, attemptedAt: fresh)

        lockState.setLocked(true)
        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 锁屏状态下的定时刷新 → 抑制运行

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            inputProvider.policies.last?.includeExternalQuotas == false,
            "锁屏抑制运行不得发起外部额度查询"
        )

        let stored = try store.load(.agentUsage, now: clock.now(), staleAfter: 3600)
        let services = stored.artifact.objectValue?["services"]?.arrayValue ?? []
        try refreshExpect(
            services.count == 2,
            "锁屏抑制运行后上一份订阅服务应被原样回填 (C071), got \(services.count)"
        )
        scheduler.stop()
    }
}
