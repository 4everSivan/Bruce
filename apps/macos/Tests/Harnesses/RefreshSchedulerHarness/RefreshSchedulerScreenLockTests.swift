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

    /// 纯策略: 锁屏抑制参数为 true 时 QuotaRefreshPolicy.plan 强制返回 localOnly.
    static func quotaPolicySuppressedOnScreenLock() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = JSONValue.object([
            "services": .array([
                .object([
                    "id": .string("claude"),
                    "app": .string("claude"),
                    "capturedAt": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200))),
                    "attemptedAt": .string(ISO8601DateFormatter().string(from: now.addingTimeInterval(-7200)))
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
        try refreshExpect(!policy.includeExternalQuotas, "锁屏抑制时必须返回 localOnly，即使为 forceRefresh")
        try refreshExpect(policy == .localOnly, "锁屏抑制返回的策略必须与 .localOnly 等价")
    }
}
