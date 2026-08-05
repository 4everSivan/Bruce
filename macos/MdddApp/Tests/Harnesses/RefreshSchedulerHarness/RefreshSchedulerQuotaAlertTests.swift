import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - 额度预警

extension RefreshSchedulerHarness {
    // MARK: - 额度预警

    /// 构造 services 含单个 5h 窗口的 artifact.
    static func makeQuotaArtifact(usedPercent: Double) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-28T12:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string("kimi"),
                    "name": .string("Kimi"),
                    "status": .string("ok"),
                    "windows": .array([
                        .object([
                            "label": .string("5小时窗口"),
                            "usedPercent": .double(usedPercent),
                            "windowMinutes": .integer(300),
                            "resetsAt": .null,
                        ])
                    ]),
                ])
            ]),
        ])
    }

    /// 装好一个带 onQuotaAlerts 捕获的调度器; 返回捕获数组.
    static func makeAlertScheduler(
        repository: URL,
        executor: MockCollectorExecutor,
        timers: FakeTimerScheduler,
        alerts: AlertCapture
    ) throws -> (RefreshScheduler, URL) {
        let clock = ManualClock()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        scheduler.onQuotaAlerts = { _, newAlerts in
            alerts.items.append(contentsOf: newAlerts)
        }
        return (scheduler, root)
    }

    // 后台刷新 5h 窗口新跨越 80% -> 弹一条预警.
    static func quotaAlertFiresOnBackgroundCrossing(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(alerts.items.count == 1, "跨越阈值应产生 1 条预警: \(alerts.items)")
        try refreshExpect(
            alerts.items.first?.serviceName == "Kimi"
                && alerts.items.first?.windowLabel == "5小时窗口"
                && alerts.items.first?.usedPercent == 85,
            "预警内容错误: \(alerts.items)"
        )
    }

    // 持续超阈值 -> 后续后台刷新不重复报警.
    static func quotaAlertNotRepeatedWhileStayingOver(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.count == 1, "首次跨越应报警: \(alerts.items)")

        // 第二次后台刷新仍 85% -> 不重复
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 88)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.count == 1, "持续超阈值不应重复报警: \(alerts.items)")
    }

    // 手动刷新不报警, 且阈值状态已同步 -> 后续后台刷新也不对同一窗口报警.
    static func quotaAlertSuppressedOnManualRefresh(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        // enableModule 排的自动计时器先不触发, 改用手动刷新
        scheduler.refresh(.agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.isEmpty, "手动刷新不应报警: \(alerts.items)")

        // 后续后台刷新仍 85% -> 已同步阈值状态, 不报警
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.isEmpty, "手动刷新后已超阈值的窗口不应再报: \(alerts.items)")
    }

    // 回落到阈值以下后再次跨越 -> 重新报警.
    static func quotaAlertRefiresAfterRecovery(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.count == 1, "首次跨越应报警: \(alerts.items)")

        // 回落到 50% -> 阈值状态复位
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 50)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.count == 1, "回落不应报警: \(alerts.items)")

        // 再次跨越 -> 重新报警
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 91)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.items.count == 2, "回落后再次跨越应重新报警: \(alerts.items)")
        try refreshExpect(
            alerts.items.last?.usedPercent == 91,
            "第二次预警内容错误: \(alerts.items)"
        )
    }

}
