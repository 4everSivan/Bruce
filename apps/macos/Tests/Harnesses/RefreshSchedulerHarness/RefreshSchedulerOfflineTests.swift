import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 断网闸门 (C061)

extension RefreshSchedulerHarness {
    /// 断网时自动触发不启动 Collector、不留重试; 联网后只补偿一次.
    static func offlineSuppressesAutoRefreshUntilReconnect(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let reachability = StubNetworkReachability(isAvailable: false)
        let (scheduler, _, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            reachability: reachability
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var lastDetail: String?
        scheduler.onStatusChange = { _, _, detail in
            if let detail { lastDetail = detail }
        }

        scheduler.start()
        try refreshExpect(
            reachability.startCount == 1,
            "调度器启动应接通网络监视"
        )
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 首次定时触发 (delay=0)

        try refreshExpect(
            executor.runCount[.agentUsage] == nil,
            "断网时自动刷新不得启动 Collector"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .idle,
            "断网抑制后应回到 idle"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.offlinePaused == true,
            "断网抑制后应打上离线补偿标记"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.lastErrorCategory == .network,
            "断网抑制应记录 network 分类"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "断网抑制不得留下任何定时器, got \(timers.pendingCount)"
        )
        try refreshExpect(
            lastDetail == "网络不可用, 已暂停自动刷新",
            "状态详情应提示断网, got \(lastDetail ?? "nil")"
        )

        // 联网: 仅补偿一次, 成功后恢复常规间隔排程.
        reachability.setAvailable(true)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "联网后应只补偿一次, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.offlinePaused == false,
            "补偿成功后应清除离线标记"
        )
        try refreshExpect(
            timers.pendingCount == 1,
            "补偿成功后应恢复常规间隔排程, got \(timers.pendingCount)"
        )

        // 常规间隔恢复: 下一次定时触发照常运行.
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "恢复联网后定时刷新应正常工作, got \(executor.runCount[.agentUsage] ?? 0)"
        )

        scheduler.stop()
        try refreshExpect(reachability.stopCount == 1, "调度器停止时应关闭网络监视")
    }

    /// 离线手动刷新只执行一次; 失败不进入退避, 联网后才恢复重试语义.
    static func offlineManualRefreshFailsWithoutBackoffRetry(
        repository: URL
    ) async throws {
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let reachability = StubNetworkReachability(isAvailable: false)
        let executor = FailingExecutor(error: CollectorRunnerError.timedOut)
        let (scheduler, _, root) = try makeSchedulerWithError(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            reachability: reachability
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // 先消费初始自动触发 (被断网闸门挡下)
        try refreshExpect(
            executor.runCount[.agentUsage] == nil,
            "断网时初始自动刷新不得启动"
        )

        // 手动刷新是用户直接动作: 离线仍执行一次.
        scheduler.refresh(.agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.backoffRetryCount == 0,
            "离线失败不得累计退避次数"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "离线失败不得排退避重试, got \(timers.pendingCount)"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.offlinePaused == true,
            "离线失败应进入等待联网状态"
        )

        // 联网后的补偿仍失败: 此时在线, 允许正常指数退避.
        reachability.setAvailable(true)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .backoff)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.backoffRetryCount == 1,
            "联网失败应恢复退避计数"
        )
        try refreshExpect(
            timers.pendingCount == 1,
            "联网失败应排一次退避重试, got \(timers.pendingCount)"
        )

        // 退避等待期间再次断网: 取消在途重试, 不留下会叠加的火种.
        reachability.setAvailable(false)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .idle,
            "退避期间断网应转回 idle"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "退避期间断网应取消重试定时器, got \(timers.pendingCount)"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.offlinePaused == true,
            "退避期间断网应打上离线补偿标记"
        )

        // 再次联网: 再补偿一次, 不会因旧定时器叠加多次请求.
        reachability.setAvailable(true)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        try refreshExpect(
            executor.runCount[.agentUsage] == 3,
            "每次恢复联网只补偿一次, got \(executor.runCount[.agentUsage] ?? 0)"
        )
    }
}
