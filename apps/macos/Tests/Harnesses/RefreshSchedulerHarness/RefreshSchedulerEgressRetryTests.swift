import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 出口探测瞬态失败提前唤醒 (C236)

extension RefreshSchedulerHarness {
    static func makeEgressRetryArtifact(
        reason: String,
        retryAt: Date?
    ) -> JSONValue {
        var service: [String: JSONValue] = [
            "id": .string("claude_1"),
            "name": .string("Claude"),
            "provider": .string("claude"),
            "status": .string("error"),
            "failureKind": .string("network"),
            "windows": .array([]),
            "egress": .object([
                "status": .string("blocked"),
                "reason": .string(reason),
                "expected": .string("US"),
                "observed": .null,
                "maskedIp": .null,
            ]),
        ]
        if let retryAt {
            service["egressRetryAt"] = .string(ISODate.string(from: retryAt))
        }
        return .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string(ISODate.string(from: Date(timeIntervalSince1970: 1_786_000_000))),
            "agents": .array([]),
            "services": .array([.object(service)]),
        ])
    }

    /// 瞬态探测失败写入 egressRetryAt 后, 下一次定时唤醒应提前到 90 秒量级.
    static func egressRetryAtShortensNextTimer(repository: URL) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        executor.artifactOverride = makeEgressRetryArtifact(
            reason: "EGRESS_PROBE_TIMEOUT",
            retryAt: clock.now().addingTimeInterval(90)
        )
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        guard let delay = timers.tokens.last(where: { !$0.isCancelled })?.delay else {
            throw RefreshTestFailure.expectation("应排定下一次刷新")
        }
        try refreshExpect(
            delay >= 30 && delay <= 95,
            "瞬态出口失败应提前唤醒 (约 90 秒), 实际: \(delay)"
        )
    }

    /// 真实国家决策不写 egressRetryAt, 即使 artifact 作弊带上也不能缩短周期.
    static func nonTransientEgressKeepsNormalInterval(repository: URL) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        executor.artifactOverride = makeEgressRetryArtifact(
            reason: "EGRESS_COUNTRY_MISMATCH",
            retryAt: clock.now().addingTimeInterval(90)
        )
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        guard let delay = timers.tokens.last(where: { !$0.isCancelled })?.delay else {
            throw RefreshTestFailure.expectation("应排定下一次刷新")
        }
        try refreshExpect(
            delay > 900,
            "非瞬态阻断不得缩短刷新周期, 实际: \(delay)"
        )
    }

    /// 提取最早重试时刻 + 新错误码的徽标映射.
    static func egressRetryHintAndBadges() throws {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let artifact = makeEgressRetryArtifact(
            reason: "EGRESS_PROXY_UNREACHABLE",
            retryAt: base.addingTimeInterval(90)
        )
        try refreshExpect(
            EgressAlertEvaluator.earliestTransientRetryAt(artifact: artifact)
                == base.addingTimeInterval(90),
            "应提取瞬态失败的最早重试时刻"
        )

        let mismatch = makeEgressRetryArtifact(
            reason: "EGRESS_COUNTRY_MISMATCH",
            retryAt: base
        )
        try refreshExpect(
            EgressAlertEvaluator.earliestTransientRetryAt(artifact: mismatch) == nil,
            "非瞬态阻断不得产生提前唤醒"
        )

        for (reason, badge) in [
            ("EGRESS_PROXY_UNREACHABLE", "代理不可达"),
            ("EGRESS_PROXY_AUTH", "代理需认证"),
            ("EGRESS_BAD_STATUS", "信标异常"),
            ("EGRESS_PROBE_TIMEOUT", "探测失败"),
        ] {
            let info = EgressPresentationInfo(
                status: .blocked,
                reason: reason,
                expected: "US",
                observed: nil,
                maskedIp: nil
            )
            try refreshExpect(info.badgeText == badge, "\(reason) 徽标应为 \(badge), 实际: \(info.badgeText)")
        }
    }
}
