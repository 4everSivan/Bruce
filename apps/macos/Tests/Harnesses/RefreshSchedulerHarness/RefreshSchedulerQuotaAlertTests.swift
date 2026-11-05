import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 额度预警

extension RefreshSchedulerHarness {
    // MARK: - 额度预警

    /// 构造 services 含单个 5h 窗口的 artifact.
    static func makeQuotaArtifact(
        usedPercent: Double,
        resetsAt: JSONValue = .null
    ) -> JSONValue {
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
                            "resetsAt": resetsAt,
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
        scheduler.onStatusAlerts = { _, newItems in
            alerts.statusItems.append(contentsOf: newItems)
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

    // C206 缺陷复现: 三档全部触发后窗口被服务端重置, 但两次刷新之间没采到
    // ≤50% 的低点 (重置后用量很快又越过 50%), 新窗口的 50% 跨越必须重新报警.
    static func quotaAlertRefiresAfterUnobservedWindowReset(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 60)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)

        // 1. 依次跨越 50 / 80 / 95 三档
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 96)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            alerts.items.map(\.tier) == [50, 80, 95],
            "三档应依次触发: \(alerts.items.map(\.tier))"
        )

        // 2. 服务端重置该窗口; 下一次采样直接是 60% (没有 ≤50% 的中间观测)
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 60)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 4)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // 3. 新窗口再次越过 50% -> 必须重新弹 50 档气泡
        try refreshExpect(
            alerts.items.count == 4,
            "窗口重置后再次越过 50% 应重新报警, 实际未报警: \(alerts.items.map(\.tier))"
        )
        try refreshExpect(
            alerts.items.last?.tier == 50,
            "重新报警应为 50 档, 实际: \(String(describing: alerts.items.last?.tier))"
        )
    }

    // C206 缺陷复现: 用量未回落但窗口重置时刻前进 (服务器侧换窗),
    // 同一档位也必须重新报警.
    static func quotaAlertRefiresWhenResetTimeAdvances(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeQuotaArtifact(
            usedPercent: 85,
            resetsAt: .integer(1_800_000_000)
        )
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

        // 同一用量 85%, 但重置时刻前进 -> 新窗口
        executor.artifactOverride = makeQuotaArtifact(
            usedPercent: 85,
            resetsAt: .integer(1_800_018_000)
        )
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            alerts.items.count == 2,
            "窗口重置时刻更新后同一档位应重新报警, 实际未报警: \(alerts.items.map(\.tier))"
        )
    }

    // MARK: - 网络出口阻断预警与防频繁打扰契约 (T24)

    /// 构造带 egress 属性的 artifact
    static func makeEgressArtifact(
        serviceID: String = "codex",
        name: String = "Codex",
        status: String = "blocked",
        reason: String = "EGRESS_CN_DIRECT",
        expected: String? = "US",
        observed: String? = "CN",
        maskedIp: String? = "114.114.***.***"
    ) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-11-03T12:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string(serviceID),
                    "name": .string(name),
                    "provider": .string(serviceID),
                    "status": .string("error"),
                    "windows": .array([]),
                    "egress": .object([
                        "status": .string(status),
                        "reason": .string(reason),
                        "expected": expected.map { .string($0) } ?? .null,
                        "observed": observed.map { .string($0) } ?? .null,
                        "maskedIp": maskedIp.map { .string($0) } ?? .null,
                    ])
                ])
            ]),
        ])
    }

    // 首次发生网络出口阻断 -> 边沿跳变单次弹出气泡
    static func egressBlockedAlertFiresOnBackgroundCrossing(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "blocked",
            reason: "EGRESS_CN_DIRECT"
        )
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

        try refreshExpect(alerts.statusItems.count == 1, "首次阻断应产生 1 条预警: \(alerts.statusItems)")
        guard case .egressIssue(let egressAlert)? = alerts.statusItems.first else {
            throw RefreshTestFailure.expectation("预警类型应为 egressIssue, 实际: \(alerts.statusItems)")
        }
        try refreshExpect(egressAlert.serviceName == "Codex", "服务名应为 Codex")
        try refreshExpect(egressAlert.badgeText == "⚠️ 国内直连", "国内直连徽标文本不匹配: \(egressAlert.badgeText)")
        try refreshExpect(egressAlert.explanation.contains("拦截海外查额"), "解释说明不匹配: \(egressAlert.explanation)")
    }

    // 持续阻断 -> 后续定时自动刷新静默更新快照，不再重复弹窗打扰
    static func egressBlockedAlertNotRepeatedWhileStayingBlocked(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "blocked",
            reason: "EGRESS_CN_DIRECT"
        )
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
        try refreshExpect(alerts.statusItems.count == 1, "首次阻断应弹窗: \(alerts.statusItems)")

        // 第二次定时刷新仍阻断 -> 静默刷新，不重复报警
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.statusItems.count == 1, "持续阻断期间不应重复弹窗: \(alerts.statusItems)")
    }

    // 网络恢复后再度异常 -> 重新激活预警
    static func egressBlockedAlertRefiresAfterRecovery(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "blocked",
            reason: "EGRESS_CN_DIRECT"
        )
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
        try refreshExpect(alerts.statusItems.count == 1, "首次阻断应报警: \(alerts.statusItems)")

        // 线路恢复放行 (allowed)
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "allowed",
            reason: "",
            expected: "US",
            observed: "US"
        )
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.statusItems.count == 1, "恢复放行不应产生新报警: \(alerts.statusItems)")

        // 之后再次掉线阻断 (国家不匹配 US != JP) -> 重新激活报警
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "blocked",
            reason: "EGRESS_COUNTRY_MISMATCH",
            expected: "JP",
            observed: "US"
        )
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.statusItems.count == 2, "恢复后再阻断应重新激活预警: \(alerts.statusItems)")
        guard case .egressIssue(let secondAlert)? = alerts.statusItems.last else {
            throw RefreshTestFailure.expectation("第二条预警类型应为 egressIssue")
        }
        try refreshExpect(secondAlert.badgeText == "⚠️ US ≠ JP", "不匹配徽标文本错误: \(secondAlert.badgeText)")
    }

    // 手动重测失败处于阻断态 -> 重新激活预警
    static func egressBlockedAlertRefiresOnManualRefresh(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeEgressArtifact(
            serviceID: "codex",
            name: "Codex",
            status: "blocked",
            reason: "EGRESS_CN_DIRECT"
        )
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
        try refreshExpect(alerts.statusItems.count == 1, "首次阻断应报警: \(alerts.statusItems)")

        // 用户在界面点击手动刷新 (重测)，若仍阻断，重新激活气泡
        scheduler.refresh(.agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(alerts.statusItems.count == 2, "手动重测仍阻断应重新激活弹窗: \(alerts.statusItems)")
    }

    // MARK: - 定向刷新不重弹非目标 Provider 出口告警 (C185)

    /// 双服务 artifact: Claude 放行 + Codex 出口国家不匹配阻断.
    static func makeMultiProviderEgressArtifact() -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-11-03T12:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string("claude"),
                    "name": .string("Claude"),
                    "provider": .string("claude"),
                    "status": .string("ok"),
                    "windows": .array([
                        .object([
                            "label": .string("5小时窗口"),
                            "usedPercent": .double(32),
                            "windowMinutes": .integer(300),
                            "resetsAt": .null,
                        ])
                    ]),
                    "egress": .object([
                        "status": .string("allowed"),
                        "reason": .null,
                        "expected": .string("US"),
                        "observed": .string("US"),
                        "maskedIp": .string("104.28.***.***"),
                    ]),
                ]),
                .object([
                    "id": .string("codex"),
                    "name": .string("Codex"),
                    "provider": .string("codex"),
                    "status": .string("error"),
                    "windows": .array([]),
                    "egress": .object([
                        "status": .string("blocked"),
                        "reason": .string("EGRESS_COUNTRY_MISMATCH"),
                        "expected": .string("JP"),
                        "observed": .string("US"),
                        "maskedIp": .string("104.28.***.***"),
                    ]),
                ]),
            ]),
        ])
    }

    /// C185 核心回归: 定向刷新 Claude 时, 已阻断的 Codex 不得因合并 artifact 原样保留
    /// 而重复弹出出口告警; 全量手动刷新仍保留原有全面重弹语义.
    static func egressBlockedAlertNotRefiredForNonTargetProvider(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.artifactOverride = makeMultiProviderEgressArtifact()
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
        try refreshExpect(alerts.statusItems.count == 1, "首次自动刷新应对 Codex 阻断弹出 1 条告警: \(alerts.statusItems)")
        guard case .egressIssue(let firstAlert)? = alerts.statusItems.first else {
            throw RefreshTestFailure.expectation("首条预警应为 egressIssue")
        }
        try refreshExpect(firstAlert.serviceName == "Codex", "首条预警应点名 Codex")

        // 定向刷新 Claude: Codex 未被请求刷新, 不得重弹其出口告警.
        let beforeTargeted = alerts.statusItems.count
        scheduler.refreshSubscription(.claude)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            alerts.statusItems.count == beforeTargeted,
            "定向刷新 Claude 不应重弹 Codex 的出口告警: \(alerts.statusItems)"
        )

        // 全量手动刷新: 既有语义保持, 仍对当前全部阻断服务重新激活警.
        scheduler.refresh(.agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            alerts.statusItems.count == beforeTargeted + 1,
            "全量手动刷新应重新激活当前阻断告警: \(alerts.statusItems)"
        )
        guard case .egressIssue(let fullRefreshAlert)? = alerts.statusItems.last else {
            throw RefreshTestFailure.expectation("全量刷新重弹项应为 egressIssue")
        }
        try refreshExpect(fullRefreshAlert.serviceName == "Codex", "全量刷新重弹项应点名 Codex")
    }
}
