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

    /// C237: 定向刷新用本轮新对象替换目标 service (不带 egressRetryCount), 退避计数须经
    /// quotaAnnotate 的 previousServices 从上一份继承, 不能每次手动刷新都回到第 1 档.
    static func scopedRefreshCarriesEgressRetryCount(repository: URL) async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-egress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(rootURL: root)

        var previous = makeEgressRetryArtifact(
            reason: "EGRESS_PROBE_TIMEOUT",
            retryAt: base.addingTimeInterval(-10)
        )
        if case .object(var object) = previous,
           case .array(var services)? = object["services"],
           case .object(var service)? = services.first {
            service["egressRetryCount"] = .integer(2)
            services[0] = .object(service)
            object["services"] = .array(services)
            previous = .object(object)
        }
        try store.publish(previous, for: .agentUsage, attemptedAt: base.addingTimeInterval(-60))

        let executor = MockCollectorExecutor()
        executor.repository = repository
        executor.artifactOverride = makeEgressRetryArtifact(reason: "EGRESS_PROBE_TIMEOUT", retryAt: nil)
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            quotaPolicy: CollectorQuotaPolicy(transport: HarnessQuotaPolicy.transport),
            store: store,
            runInputProvider: nil,
            credentialUpdates: nil,
            codexTokenManager: nil,
            isStopped: { false },
            now: { base }
        )
        let result = await pipeline.run(RefreshPipelineRequest(
            module: .agentUsage,
            intent: .timer(),
            scope: .subscriptionProviders([.claude]),
            staleAfter: 3600,
            now: base,
            quotaRefreshInterval: 1800
        ))
        guard case .completed(let run) = result,
              let service = run.publishedArtifact?.objectValue?["services"]?.arrayValue?.first?.objectValue else {
            throw RefreshTestFailure.expectation("定向刷新应发布 artifact, got \(result)")
        }
        try refreshExpect(
            service["egressRetryCount"]?.intValue == 3,
            "定向刷新应继承上一份计数 2 并递增为 3, 实际: \(String(describing: service["egressRetryCount"]))"
        )
        try refreshExpect(
            service["egressRetryAt"]?.stringIdValue == ISODate.string(from: base.addingTimeInterval(300)),
            "第 3 次瞬态失败应排定 300 秒后重试, 实际: \(String(describing: service["egressRetryAt"]))"
        )
    }

    /// C238: 第 4 次瞬态失败耗尽退避档位后不再写 egressRetryAt, 调度器回到正常刷新间隔.
    /// 经真实进程内策略: 上一份已失败 3 次, 本轮再失败即耗尽.
    static func exhaustedEgressRetryKeepsNormalInterval(repository: URL) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        executor.artifactOverride = makeEgressRetryArtifact(reason: "EGRESS_PROBE_TIMEOUT", retryAt: nil)
        let timers = FakeTimerScheduler()
        let (scheduler, store, root) = try makeScheduler(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }
        var previous = makeEgressRetryArtifact(
            reason: "EGRESS_PROBE_TIMEOUT",
            retryAt: clock.now().addingTimeInterval(-1)
        )
        if case .object(var object) = previous,
           case .array(var services)? = object["services"],
           case .object(var service)? = services.first {
            service["egressRetryCount"] = .integer(3)
            services[0] = .object(service)
            object["services"] = .array(services)
            previous = .object(object)
        }
        try store.publish(previous, for: .agentUsage, attemptedAt: clock.now().addingTimeInterval(-300))

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        let stored = try store.load(.agentUsage, now: clock.now(), staleAfter: 3600)
        let service = stored.artifact.objectValue?["services"]?.arrayValue?.first?.objectValue
        try refreshExpect(
            service?["egressRetryCount"]?.intValue == 4 && service?["egressRetryAt"] == nil,
            "第 4 次瞬态失败应耗尽退避且不再排定重试, 实际: \(String(describing: service))"
        )
        try refreshExpect(
            service?["quotaAttemptedAt"]?.stringIdValue != nil,
            "耗尽后应写尝试时间戳, 回到正常新鲜度门禁"
        )
        guard let delay = timers.tokens.last(where: { !$0.isCancelled })?.delay else {
            throw RefreshTestFailure.expectation("应排定下一次刷新")
        }
        try refreshExpect(delay > 900, "耗尽后不得再提前唤醒, 实际: \(delay)")
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
