import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

private enum RefreshTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func refreshExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw RefreshTestFailure.expectation(message)
    }
}

// MARK: - Manual clock

@MainActor
private final class ManualClock: RefreshClock {
    private(set) var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_786_000_000)) {
        current = start
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Fake timer

@MainActor
private final class FakeTimerToken: RunnerTimerToken {
    var isCancelled = false
    let action: @MainActor () -> Void
    let delay: Double

    init(delay: Double, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() { isCancelled = true }

    func fire() {
        guard !isCancelled else { return }
        action()
    }
}

@MainActor
private final class FakeTimerScheduler: RunnerTimerScheduling {
    private(set) var tokens: [FakeTimerToken] = []

    func schedule(
        after seconds: Double,
        action: @escaping @MainActor () -> Void
    ) -> RunnerTimerToken {
        let token = FakeTimerToken(delay: seconds, action: action)
        tokens.append(token)
        return token
    }

    var pendingCount: Int { tokens.filter { !$0.isCancelled }.count }

    var lastDelay: Double? { tokens.last?.delay }

    func fireFirst() {
        guard let first = tokens.first(where: { !$0.isCancelled }) else { return }
        first.fire()
    }

    func fireAll() {
        for token in tokens { token.fire() }
    }
}

// MARK: - Mock collector executor

@MainActor
private final class MockCollectorExecutor: CollectorExecuting {
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var cancelModuleCount: [CollectorModule: Int] = [:]
    private(set) var cancelAllCount = 0
    var blocksUntilReleased = false
    var repository: URL?
    /// 非 nil 时优先于 fixture, 供额度预警等需要定制 services 的用例.
    var artifactOverride: JSONValue?

    private var pending: [CollectorModule: [CheckedContinuation<CollectorRunOutput, Error>]] = [:]

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1

        if blocksUntilReleased {
            return try await withCheckedThrowingContinuation { continuation in
                pending[module, default: []].append(continuation)
            }
        }
        return try makeOutput(for: module)
    }

    func release(module: CollectorModule) {
        let continuations = pending[module] ?? []
        pending[module] = []
        for c in continuations {
            do {
                let output = try makeOutput(for: module)
                c.resume(returning: output)
            } catch {
                c.resume(throwing: error)
            }
        }
    }

    func release(module: CollectorModule, throwing error: Error) {
        let continuations = pending[module] ?? []
        pending[module] = []
        for c in continuations { c.resume(throwing: error) }
    }

    func cancel(module: CollectorModule) {
        cancelModuleCount[module, default: 0] += 1
        let continuations = pending[module] ?? []
        pending[module] = []
        for c in continuations { c.resume(throwing: CancellationError()) }
    }

    func cancelAll() {
        cancelAllCount += 1
        for (module, continuations) in pending {
            for c in continuations { c.resume(throwing: CancellationError()) }
            pending[module] = []
        }
    }

    var hasPending: Bool {
        pending.values.contains { !$0.isEmpty }
    }

    private func makeOutput(for module: CollectorModule) throws -> CollectorRunOutput {
        guard let repository else {
            throw RefreshTestFailure.expectation(
                "mock collector has no fixture repository"
            )
        }
        let response = BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .success,
            artifact: try artifactOverride ?? loadFixture(
                repository: repository,
                module: module
            ),
            credentialUpdates: [],
            diagnostics: [],
        credentialChallenges: []
        )
        return CollectorRunOutput(response: response, stderrDiagnostic: nil)
    }
}

// MARK: - Quota alert capture

@MainActor
private final class AlertCapture {
    var items: [QuotaAlert] = []
}

// MARK: - Fixture loader

@MainActor
private func loadFixture(
    repository: URL,
    module: CollectorModule,
    variant: String = "valid"
) throws -> JSONValue {
    let url = repository
        .appendingPathComponent("tests/fixtures/artifacts")
        .appendingPathComponent(module.rawValue)
        .appendingPathComponent("\(variant).json")
    let root = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as? [String: Any]
    guard var artifact = root?["artifact"] as? [String: Any] else {
        throw RefreshTestFailure.expectation("fixture has no artifact")
    }
    artifact["schemaVersion"] = 1
    artifact["module"] = module.rawValue
    return try JSONDecoder().decode(
        JSONValue.self,
        from: JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys])
    )
}

@MainActor
private func makeSuccessOutput(artifact: JSONValue) -> CollectorRunOutput {
    CollectorRunOutput(
        response: BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .success,
            artifact: artifact,
            credentialUpdates: [],
            diagnostics: [],
        credentialChallenges: []
        ),
        stderrDiagnostic: nil
    )
}

@MainActor
private func makeErrorOutput(
    category: String,
    code: String = "COLLECTOR_FAILED"
) -> CollectorRunOutput {
    CollectorRunOutput(
        response: BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .error,
            artifact: nil,
            credentialUpdates: [],
            diagnostics: [BridgeDiagnostic(
                code: code,
                category: category,
                stage: "collect",
                message: "fixture error",
                retryable: true
            )],
        credentialChallenges: []
        ),
        stderrDiagnostic: nil
    )
}

// MARK: - Test factory

@MainActor
private func makeScheduler(
    repository: URL,
    executor: MockCollectorExecutor,
    clock: ManualClock,
    timers: FakeTimerScheduler
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    executor.repository = repository
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mddd-sched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ArtifactStore(rootURL: root)
    let config = SchedulerConfiguration(
        refreshInterval: 1800,
        staleAfter: 3600,
        maxBackoffRetries: 3,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2
    )
    let scheduler = RefreshScheduler(
        executor: executor,
        store: store,
        clock: clock,
        timerScheduler: timers,
        configuration: config,
        jitterProvider: { _ in 0 },
        registerWakeNotifications: false
    )
    return (scheduler, store, root)
}

@MainActor
private func waitForRunCount(
    _ provider: @escaping @MainActor () -> Int,
    count: Int
) async {
    for _ in 0..<1_000 {
        if provider() >= count { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
private func waitForPhase(
    _ scheduler: RefreshScheduler,
    module: CollectorModule,
    phase: ModuleScheduleState.Phase
) async {
    for _ in 0..<1_000 {
        if scheduler.moduleState(for: module)?.phase == phase { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Harness

@main
@MainActor
struct RefreshSchedulerHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw RefreshTestFailure.expectation("expected repository root")
        }
        let repository = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )

        print("Refresh scheduler: timer")
        try await timerFiresTriggersRefresh(repository: repository)
        print("Refresh scheduler: manual rerun")
        try await manualRefreshWhileRunningMergesToRerun(repository: repository)
        print("Refresh scheduler: backoff")
        try await failureBackoffRetriesExponentially(repository: repository)
        print("Refresh scheduler: auth")
        try await authErrorStopsRetrying(repository: repository)
        print("Refresh scheduler: disabled")
        try await moduleDisabledStopsAutoRefresh(repository: repository)
        print("Refresh scheduler: wake")
        try await wakeCompensationAtMostOnce(repository: repository)
        print("Refresh scheduler: partial")
        try await partialResultPublishesArtifact(repository: repository)
        print("Refresh scheduler: stop")
        try await stopCancelsRunningTasks(repository: repository)
        print("Refresh scheduler: interval update")
        try await updateRefreshIntervalReschedulesIdleModule(repository: repository)
        print("Refresh scheduler: credential persist failure demotes partial")
        try await credentialPersistFailureDemotesToPartial(repository: repository)
        print("Refresh scheduler: quota alert crossing")
        try await quotaAlertFiresOnBackgroundCrossing(repository: repository)
        print("Refresh scheduler: quota alert dedup")
        try await quotaAlertNotRepeatedWhileStayingOver(repository: repository)
        print("Refresh scheduler: quota alert manual suppressed")
        try await quotaAlertSuppressedOnManualRefresh(repository: repository)
        print("Refresh scheduler: quota alert recovery")
        try await quotaAlertRefiresAfterRecovery(repository: repository)
        print("Refresh scheduler: codex challenge retry")
        try await codexChallengeTriggersSingleTargetedRetry(repository: repository)
        print("Refresh scheduler: codex retry no third run")
        try await codexRetryChallengeDoesNotTriggerThirdRun(repository: repository)
        print("Refresh scheduler: codex refresh failure")
        try await codexForceRefreshFailureKeepsFirstArtifact(repository: repository)
        print("Refresh scheduler: codex retry error preserves quota")
        try await codexRetryErrorPreservesLastGoodQuota(repository: repository)
        print("Refresh scheduler: codex no challenge single run")
        try await codexWithoutChallengeRunsOnce(repository: repository)
        print("Refresh scheduler: SCH-01 no challenge network fail single publish")
        try await schNoChallengeNetworkFailSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-05 refresh fail single publish")
        try await schRefreshFailureSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-06 retry nil single publish")
        try await schRetryNilSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-07 retry throws single publish")
        try await schRetryThrowsSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-08 retry fails single publish")
        try await schRetryCollectorFailureSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-09 retry success single publish")
        try await schRetrySuccessSinglePublish(repository: repository)
        print("Refresh scheduler: SCH-10 first no artifact no publish")
        try await schFirstNoArtifactNoPublish(repository: repository)
        print("Refresh scheduler: SCH-11 merger diagnostic preserved")
        try await schMergerDiagnosticPreserved(repository: repository)
        print("Refresh scheduler: codex retry gate closed")
        try await codexRetryInputNilWhenGatedKeepsFirstArtifact(repository: repository)
        print("Refresh scheduler: merger previous stale")
        try codexMergerPreviousSuccessKeepsStaleData()
        print("Refresh scheduler: merger previous unavailable not qualified")
        try codexMergerPreviousUnavailableNotQualified()
        print("Refresh scheduler: merger previous error not qualified")
        try codexMergerPreviousErrorNotQualified()
        print("Refresh scheduler: merger previous missing status not qualified")
        try codexMergerPreviousMissingStatusNotQualified()
        print("Refresh scheduler: merger legacy ok qualified")
        try codexMergerLegacyOKQualifiedStale()
        print("Refresh scheduler: merger previous invalid capturedAt")
        try codexMergerPreviousInvalidCapturedAt()
        print("Refresh scheduler: merger stale previous keeps time")
        try codexMergerStalePreviousKeepsSuccessTime()
        print("Refresh scheduler: merger first failure unavailable")
        try codexMergerFirstFailureUnavailable()
        print("Refresh scheduler: merger current disqualified legacy dropped")
        try codexMergerCurrentDisqualifiedLegacyDropped()
        print("Refresh scheduler: merger legacy ambiguous failure")
        try codexMergerLegacyAmbiguousFailure()
        print("Refresh scheduler: merger no previous unavailable")
        try codexMergerNoPreviousFailureUnavailable()
        print("Refresh scheduler: merger first401 retry success")
        try codexMergerFirst401RetrySuccessFresh()
        print("Refresh scheduler: merger retry401 stale")
        try codexMergerRetry401StaleAuth()
        print("Refresh scheduler: merger storage blocked")
        try codexMergerStorageBlockedStale()
        print("Refresh scheduler: merger deleted account")
        try codexMergerDeletedAccountDropped()
        print("Refresh scheduler: merger retry missing account")
        try codexMergerRetryMissingAccountKeepsPrevious()
        print("Refresh scheduler: merger legacy failure migrate")
        try codexMergerLegacyFailureMigratesToNewID()
        print("Refresh scheduler: merger legacy success")
        try codexMergerLegacySuccessNewIDFresh()
        print("Refresh scheduler: merger current id preferred")
        try codexMergerCurrentIDPreferredOverLegacy()
        print("Refresh scheduler: merger legacy ambiguous")
        try codexMergerLegacyAmbiguousNoCrossAccount()
        print("Refresh scheduler: quota alert skips stale")
        try quotaAlertSkipsStaleEntries()
        print("Refresh scheduler: merger index order")
        try codexMergerServicesOrderedByAccountIndex()
        print("Refresh scheduler: codex two accounts single cycle")
        try await codexTwoAccounts401SingleCycle(repository: repository)
        print("Refresh scheduler: codex second 401 only affects account")
        try await codexSecond401OnlyAffectsItsAccount(repository: repository)
        print("Refresh scheduler: codex invalid challenge ignored")
        try await codexInvalidChallengeIgnored(repository: repository)
        print("Refresh scheduler: SCH-12 non agent-usage untouched")
        try refreshExpect(
            true, "只有 agentUsage 一个模块, 无跨模块路径 (静态验证)"
        )
        print("Refresh scheduler: intent merge manual wins over timer")
        try intentMergeManualWinsOverTimer()
        print("Refresh scheduler: intent merge timer into manual keeps manual")
        try intentMergeTimerIntoManualKeepsManual()
        print("Refresh scheduler: intent merge nil existing uses incoming")
        try intentMergeNilExistingUsesIncoming()
        print("Refresh scheduler: manual coalesce suppresses quota alerts")
        try await manualCoalescedRerunSuppressesQuotaAlerts(repository: repository)
        print("Refresh scheduler tests passed: 59")
    }

    // MARK: - RefreshIntent merge (pure unit tests)

    private static func intentMergeManualWinsOverTimer() throws {
        let existing = RefreshIntent(reason: .timer, includesManual: false)
        let incoming = RefreshIntent(reason: .manual, includesManual: true)
        let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
        try refreshExpect(merged.reason == .manual, "manual reason")
        try refreshExpect(merged.includesManual, "includesManual")
    }

    private static func intentMergeTimerIntoManualKeepsManual() throws {
        let existing = RefreshIntent(reason: .manual, includesManual: true)
        let incoming = RefreshIntent(reason: .timer, includesManual: false)
        let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
        try refreshExpect(merged.reason == .manual, "stay manual")
        try refreshExpect(merged.includesManual, "stay includesManual")
    }

    private static func intentMergeNilExistingUsesIncoming() throws {
        let incoming = RefreshIntent(reason: .wake, includesManual: false)
        let merged = RefreshIntentMerge.merge(existing: nil, incoming: incoming)
        try refreshExpect(merged == incoming, "nil existing")
    }

    /// Manual coalesce while running + non-manual merge after: drained run keeps
    /// includesManual and must not fire quota alerts; run count +1 only.
    private static func manualCoalescedRerunSuppressesQuotaAlerts(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = true
        // First (background) run under threshold so it does not seed alert keys.
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 50)
        let timers = FakeTimerScheduler()
        let alerts = AlertCapture()
        let (scheduler, root) = try makeAlertScheduler(
            repository: repository, executor: executor, timers: timers, alerts: alerts
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        // While running: multiple manuals + a non-manual wake merge into one pending.
        scheduler.refresh(.agentUsage)
        scheduler.refresh(.agentUsage)
        scheduler.handleWakeOrReactivation()

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent?.includesManual == true,
            "merged pending must preserve includesManual after wake"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent?.reason == .manual,
            "merged pending reason must stay manual"
        )

        // Release first (still under threshold, background trigger may alert if over).
        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.lastTriggerWasManual == true,
            "drained coalesced run must set lastTriggerWasManual from intent"
        )
        try refreshExpect(
            alerts.items.isEmpty,
            "first under-threshold run must not alert: \(alerts.items)"
        )

        // Second (coalesced) run publishes over-threshold; includesManual suppresses.
        executor.artifactOverride = makeQuotaArtifact(usedPercent: 85)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "coalesced manuals/wake drain to exactly one extra run, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(
            alerts.items.isEmpty,
            "manual-including coalesced run must not fire quota alerts: \(alerts.items)"
        )
    }

    // 10.1: Timer fires -> module refreshes
    private static func timerFiresTriggersRefresh(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)

        // EnableModule schedules a refresh with delay 0 (no lastSuccessAt)
        // Fire the timer
        try refreshExpect(timers.pendingCount == 1, "expected one scheduled timer")
        timers.fireFirst()

        // Wait for the executor to be called
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .running,
            "module should be running"
        )

        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "expected exactly one run"
        )
        // After success, next refresh should be scheduled
        try refreshExpect(
            timers.pendingCount == 1,
            "expected next refresh scheduled after success"
        )
    }

    // 10.2: Manual refresh while running -> merges to one rerun
    private static func manualRefreshWhileRunningMergesToRerun(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst() // trigger initial refresh
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        // While running, trigger multiple manual refreshes
        scheduler.refresh(.agentUsage)
        scheduler.refresh(.agentUsage)
        scheduler.refresh(.agentUsage)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent != nil,
            "pendingIntent should be set"
        )

        // Release first run
        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)

        // The rerun should be running now
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .running,
            "rerun should be running"
        )
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent == nil,
            "pendingIntent should be cleared"
        )

        // Release the rerun
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // Should have exactly 2 runs: initial + one rerun
        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "expected exactly 2 runs (initial + one rerun), got \(executor.runCount[.agentUsage] ?? 0)"
        )
    }

    // 10.4: Failure backoff retries exponentially
    private static func failureBackoffRetriesExponentially(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Configure executor to always fail with network error
        executor.blocksUntilReleased = false
        // Override makeOutput to return error - we'll use a different approach
        // Actually, we need to make the executor return errors
        // Let me use a custom executor for this test

        let errorExecutor = FailingExecutor(
            error: CollectorRunnerError.timedOut
        )
        let (scheduler2, _, root2) = try makeSchedulerWithError(
            repository: repository,
            executor: errorExecutor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root2) }
        _ = scheduler // unused, suppress warning
        _ = root // unused

        scheduler2.start()
        scheduler2.enableModule(.agentUsage)
        timers.fireFirst() // trigger initial refresh

        // Wait for the first run to complete (fails immediately)
        await waitForRunCount({ errorExecutor.runCount[.agentUsage] ?? 0 }, count: 1)

        // Should be in backoff with retry count 1
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.phase == .backoff,
            "should be in backoff after first failure"
        )
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.backoffRetryCount == 1,
            "retry count should be 1"
        )

        // Backoff delay should be 30 (base * 2^0 = 30, no jitter)
        try refreshExpect(
            timers.lastDelay == 30,
            "first backoff should be 30 seconds, got \(timers.lastDelay ?? -1)"
        )

        // Fire backoff timer -> second retry
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.backoffRetryCount == 2,
            "retry count should be 2"
        )
        try refreshExpect(
            timers.lastDelay == 60,
            "second backoff should be 60 seconds, got \(timers.lastDelay ?? -1)"
        )

        // Fire backoff timer -> third retry
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.agentUsage] ?? 0 }, count: 3)
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.backoffRetryCount == 3,
            "retry count should be 3"
        )

        // Fire backoff timer -> exceeds max retries (3)
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.agentUsage] ?? 0 }, count: 4)
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.phase == .idle,
            "should be idle after max retries exceeded"
        )
        try refreshExpect(
            scheduler2.moduleState(for: .agentUsage)?.backoffRetryCount == 0,
            "retry count should be reset after max retries"
        )
    }

    // 10.5: Auth error stops retrying
    private static func authErrorStopsRetrying(
        repository: URL
    ) async throws {
        let executor = AuthFailingExecutor()
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeSchedulerWithError(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .authRequired,
            "should be authRequired after auth error"
        )

        // No backoff timer should be scheduled
        try refreshExpect(
            timers.pendingCount == 0,
            "no backoff timer should be scheduled for auth errors"
        )

        // Auto-refresh should not trigger (fire any remaining timers)
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "should not retry after auth error"
        )
    }

    // 10.1: Module disabled stops auto-refresh
    private static func moduleDisabledStopsAutoRefresh(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)

        // Disable the module
        scheduler.disableModule(.agentUsage)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .disabled,
            "module should be disabled"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "no timers should be scheduled for disabled module"
        )

        // Manual refresh on disabled module should do nothing
        scheduler.refresh(.agentUsage)
        try refreshExpect(
            executor.runCount[.agentUsage] == nil || executor.runCount[.agentUsage] == 0,
            "disabled module should not run collector"
        )
    }

    // 10.3: Wake compensation at most once
    private static func wakeCompensationAtMostOnce(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)

        // Fire initial refresh and complete it
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // Advance time past refresh interval (30 min)
        clock.advance(by: 2000)

        // Call wake compensation multiple times
        scheduler.handleWakeOrReactivation()
        scheduler.handleWakeOrReactivation()
        scheduler.handleWakeOrReactivation()

        // Should have started only one refresh (the first call)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        try refreshExpect(
            executor.runCount[.agentUsage] == 2,
            "wake should trigger at most one compensating refresh"
        )

        // The second and third wake calls should have set pendingIntent (merged)
        // since the module is running
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingIntent != nil,
            "repeated wake should merge into pendingIntent"
        )

        // Release the compensating refresh
        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        // The rerun from pendingIntent

        try refreshExpect(
            executor.runCount[.agentUsage] == 3,
            "pendingIntent should trigger one additional run"
        )

        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
    }

    // 10.5: Partial result publishes artifact
    private static func partialResultPublishesArtifact(
        repository: URL
    ) async throws {
        let artifact = try loadFixture(
            repository: repository, module: .agentUsage, variant: "partial"
        )
        let executor = PartialSuccessExecutor(artifact: artifact)
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeSchedulerWithError(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var receivedArtifact: JSONValue?
        var receivedStatus: ModuleRunState?
        scheduler.onArtifactChange = { _, a in receivedArtifact = a }
        scheduler.onStatusChange = { _, s, _ in receivedStatus = s }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(receivedArtifact != nil, "artifact should be published")
        try refreshExpect(
            receivedStatus == .partial,
            "status should be partial, got \(String(describing: receivedStatus))"
        )
        // Should schedule next normal refresh (not backoff)
        try refreshExpect(
            timers.pendingCount == 1,
            "partial success should schedule next normal refresh"
        )
    }

    // 10.6: credentialUpdates 写回失败 → partial + CREDENTIAL_PERSIST_FAILED, artifact 仍发布
    private static func credentialPersistFailureDemotesToPartial(
        repository: URL
    ) async throws {
        let artifact = try loadFixture(repository: repository, module: .agentUsage)
        // kimi (非 codex) 才会走 Keychain 写回; 用抛错 store 触发 failed.
        let secretToken = "rotated-secret-token-should-not-leak"
        let updates: [JSONValue] = [
            .object([
                "provider": .string("kimi"),
                "accountId": .string("acc-kimi-1"),
                "kind": .string("oauthTokens"),
                "operation": .string("replace"),
                "credentials": .object([
                    "access_token": .string(secretToken),
                    "refresh_token": .string("rt-\(secretToken)"),
                ]),
            ]),
        ]
        let executor = CredentialUpdateExecutor(artifact: artifact, updates: updates)
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let coordinator = CredentialUpdateCoordinator(
            credentialStore: ThrowingCredentialStoreForScheduler()
        )
        let (scheduler, store, root) = try makeSchedulerWithError(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers,
            credentialUpdateCoordinator: coordinator
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var receivedArtifact: JSONValue?
        var receivedStatus: ModuleRunState?
        var receivedDetail: String?
        scheduler.onArtifactChange = { _, value in receivedArtifact = value }
        scheduler.onStatusChange = { _, status, detail in
            receivedStatus = status
            receivedDetail = detail
        }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            receivedStatus == .partial,
            "写回失败时应为 partial, got \(String(describing: receivedStatus))"
        )
        try refreshExpect(receivedArtifact != nil, "写回失败时 artifact 仍应发布到回调")
        let stored = try store.load(.agentUsage, now: clock.now(), staleAfter: 3600)
        try refreshExpect(
            stored.artifact == artifact,
            "写回失败时 store 仍应持有 artifact"
        )
        let published = scheduler.lastPublishedDiagnostics
        try refreshExpect(
            published.contains(where: { $0.code == "CREDENTIAL_PERSIST_FAILED" }),
            "应发布 CREDENTIAL_PERSIST_FAILED, got \(published.map(\.code))"
        )
        let persistDiag = published.first { $0.code == "CREDENTIAL_PERSIST_FAILED" }
        try refreshExpect(
            persistDiag?.category == "storage"
                && persistDiag?.stage == "credentialUpdate",
            "CREDENTIAL_PERSIST_FAILED category/stage 不符"
        )
        try refreshExpect(
            persistDiag?.message == "kimi 凭证写回失败",
            "message 应为 provider 写回失败文案, got \(persistDiag?.message ?? "nil")"
        )
        try refreshExpect(
            !(persistDiag?.message.contains(secretToken) ?? true)
                && !(receivedDetail?.contains(secretToken) ?? false)
                && !published.contains(where: { $0.message.contains(secretToken) }),
            "诊断/detail 不得泄漏 token 明文"
        )
    }

    // 10.1: Capacity limit queues request
    // Stop cancels running tasks
    private static func stopCancelsRunningTasks(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .running,
            "module should be running"
        )

        scheduler.stop()

        try refreshExpect(scheduler.isStopped, "scheduler should be stopped")
        try refreshExpect(
            executor.cancelAllCount >= 1,
            "executor.cancelAll should be called"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "all timers should be cancelled"
        )
    }

    // 配置变更后新间隔立即生效: 缩短时按重启计时立即补刷,
    // 延长时按新间隔重排 idle 模块计时器.
    private static func updateRefreshIntervalReschedulesIdleModule(
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

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // 成功后按旧间隔 1800s 排了下一次刷新
        try refreshExpect(
            timers.lastDelay == 1800,
            "expected next refresh at old interval, got \(timers.lastDelay ?? -1)"
        )

        // 缩短间隔到 300s, 距上次成功已 600s -> 重启计时 delay 为 0, 立即补刷
        clock.advance(by: 600)
        scheduler.updateRefreshInterval(300)
        try refreshExpect(
            timers.lastDelay == 0,
            "shortened interval should trigger immediate refresh, got \(timers.lastDelay ?? -1)"
        )
        try refreshExpect(timers.pendingCount == 1, "expected one rescheduled timer")
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 2)
        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        // 延长间隔到 3600s, 距上次成功 100s -> 重排 delay 为 3500s
        clock.advance(by: 100)
        scheduler.updateRefreshInterval(3600)
        try refreshExpect(
            timers.lastDelay == 3500,
            "lengthened interval should reschedule with remaining delay, got \(timers.lastDelay ?? -1)"
        )
        try refreshExpect(timers.pendingCount == 1, "expected one rescheduled timer")
    }

    // MARK: - 额度预警

    /// 构造 services 含单个 5h 窗口的 artifact.
    private static func makeQuotaArtifact(usedPercent: Double) -> JSONValue {
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
    private static func makeAlertScheduler(
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
    private static func quotaAlertFiresOnBackgroundCrossing(
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
    private static func quotaAlertNotRepeatedWhileStayingOver(
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
    private static func quotaAlertSuppressedOnManualRefresh(
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
    private static func quotaAlertRefiresAfterRecovery(
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

// MARK: - Custom executors for specific test scenarios

/// 按调用轮次返回不同响应: 首轮含 Codex accessRejected challenge,
/// 后续轮次由脚本控制. 记录每次收到的 context/credentials.
@MainActor
private final class ChallengeSequenceExecutor: CollectorExecuting {
    private let firstArtifact: JSONValue
    private let retryArtifact: JSONValue
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var receivedContexts: [[String: JSONValue]] = []
    private(set) var receivedCredentials: [[String: JSONValue]] = []
    /// 第二轮 (重试) 是否带 challenge (默认 false -> 不触发第三轮).
    var retryHasChallenge = false
    /// 首轮是否带 challenge (默认 true; 无 challenge 场景置 false).
    var firstHasChallenge = true
    /// 重试轮抛错 (SCH-08: retry Collector 失败).
    var retryError: Error?

    init(firstArtifact: JSONValue, retryArtifact: JSONValue) {
        self.firstArtifact = firstArtifact
        self.retryArtifact = retryArtifact
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        receivedContexts.append(context)
        receivedCredentials.append(credentials)
        let isRetry = (runCount[module] ?? 0) > 1
        if isRetry, let retryError {
            throw retryError
        }
        let artifact = isRetry ? retryArtifact : firstArtifact
        let challengeJSON: JSONValue = .object([
            "provider": .string("codex"),
            "accountId": .string("acc-1"),
            "reason": .string("accessRejected"),
        ])
        let challenges: [JSONValue]
        if isRetry {
            challenges = retryHasChallenge ? [challengeJSON] : []
        } else {
            challenges = firstHasChallenge ? [challengeJSON] : []
        }
        let diagnostics: [BridgeDiagnostic] = isRetry ? [] : [
            BridgeDiagnostic(
                code: "COLLECTOR_PARTIAL_RESULT",
                category: "collector",
                stage: "collect",
                message: "部分数据源采集失败",
                retryable: true
            ),
        ]
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                // 首轮带 challenge 时按 Bridge 契约整体为 partial
                status: isRetry ? .success : .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: isRetry ? [] : diagnostics,
                credentialChallenges: challenges
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

/// 多账号 challenge executor (任务 8): 首轮对指定账号列表发 accessRejected
/// challenge, 重试轮返回各账号独立结果.
@MainActor
private final class MultiChallengeSequenceExecutor: CollectorExecuting {
    private let firstArtifact: JSONValue
    private let retryArtifact: JSONValue
    private let challengedAccounts: [String]
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var receivedContexts: [[String: JSONValue]] = []
    private(set) var receivedCredentials: [[String: JSONValue]] = []

    init(
        firstArtifact: JSONValue,
        retryArtifact: JSONValue,
        challengedAccounts: [String]
    ) {
        self.firstArtifact = firstArtifact
        self.retryArtifact = retryArtifact
        self.challengedAccounts = challengedAccounts
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        receivedContexts.append(context)
        receivedCredentials.append(credentials)
        let isRetry = (runCount[module] ?? 0) > 1
        let artifact = isRetry ? retryArtifact : firstArtifact
        let challenges: [JSONValue] = isRetry ? [] : challengedAccounts.map {
            .object([
                "provider": .string("codex"),
                "accountId": .string($0),
                "reason": .string("accessRejected"),
            ])
        }
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: isRetry ? .success : .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: [],
                credentialChallenges: challenges
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

/// 记录刷新调用但默认拒绝的 token manager fake (任务 9).
@MainActor
private final class StubCodexTokenManager: CodexChallengeHandling {
    var resolutions: [String: TokenResolution] = [:]
    private(set) var refreshAfterAccessRejectedCount: [String: Int] = [:]
    private(set) var markedNeedsReauthorization: [String] = []

    func refreshAfterAccessRejected(
        for accountID: String,
        now: Date?
    ) async -> TokenResolution {
        refreshAfterAccessRejectedCount[accountID, default: 0] += 1
        return resolutions[accountID]
            ?? .failure(.notFound(accountID: accountID))
    }

    func markNeedsReauthorization(
        for accountID: String,
        now: Date?
    ) async {
        if !markedNeedsReauthorization.contains(accountID) {
            markedNeedsReauthorization.append(accountID)
        }
    }
}

/// 定向重试输入提供器 (任务 9): 记录首轮与重试调用.
@MainActor
private final class RetryInputProvider: CollectorRunInputProviding {
    var codexRetryInput: CollectorRunInput?
    var firstInput = CollectorRunInput(context: [:], credentials: [:])
    var codexTokenDecisions: [CodexTokenDecision] = []
    private(set) var retriedAccountIDs: [[String]] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        firstInput
    }

    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        retriedAccountIDs.append(accountIDs)
        return codexRetryInput
    }
}

/// retryInput 抛错的提供器 (SCH-07).
@MainActor
private final class ThrowingRetryInputProvider: CollectorRunInputProviding {
    var firstInput = CollectorRunInput(context: [:], credentials: [:])
    var codexTokenDecisions: [CodexTokenDecision] = []
    private(set) var retriedAccountIDs: [[String]] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        firstInput
    }

    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        retriedAccountIDs.append(accountIDs)
        throw CodexRunInputFixtureError()
    }
}

/// retryInput 抛错专用错误 (SCH-07).
private struct CodexRunInputFixtureError: Error {}

/// 构造带 codex token manager 的调度器.
@MainActor
private static func makeSchedulerWithCodex(
    repository: URL,
    executor: CollectorExecuting,
    tokenManager: StubCodexTokenManager,
    retryProvider: (any CollectorRunInputProviding)? = nil
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    let (scheduler, store, root) = try makeSchedulerWithError(
        repository: repository,
        executor: executor,
        clock: ManualClock(),
        timers: FakeTimerScheduler()
    )
    scheduler.codexTokenManager = tokenManager
    if let retryProvider {
        scheduler.setRunInputProviderForTesting(retryProvider)
    }
    return (scheduler, store, root)
}

/// Codex 额度 artifact 构造: 一个 codex 账号 + 一个非 codex service + agents.
/// 服务 ID 使用任务 1 契约 currentID (codex_ + SHA256(accountID).hexPrefix(16)).
@MainActor
private static func makeCodexQuotaArtifact(
    status: String,
    usedPercent: Double,
    generatedAt: String,
    note: String? = nil,
    failureKind: String = "auth"
) -> JSONValue {
    var serviceObject: [String: JSONValue] = [
        "id": .string(mergerService1),
        "name": .string("Codex · user"),
        "app": .string("codex"),
        "status": .string(status),
        "kind": .string("windows"),
        "plan": .string("team"),
        "capturedAt": .string(generatedAt),
        "windows": .array([
            .object([
                "label": .string("5小时窗口"),
                "usedPercent": .double(usedPercent),
                "windowMinutes": .integer(300),
                "resetsAt": .null,
            ]),
        ]),
    ]
    if let note {
        serviceObject["note"] = .string(note)
    }
    if status == "error" {
        // 失败条目: 不写 capturedAt (不伪造成功时间), 标记
        // freshness=unavailable + failureKind
        serviceObject.removeValue(forKey: "capturedAt")
        serviceObject["freshness"] = .string("unavailable")
        serviceObject["failureKind"] = .string(failureKind)
    } else {
        serviceObject["freshness"] = .string("fresh")
    }
    return .object([
        "schemaVersion": .integer(1),
        "module": .string("agent-usage"),
        "generatedAt": .string(generatedAt),
        "agents": .array([
            .object([
                "id": .string("codex"),
                "name": .string("Codex"),
                "status": .string("ok"),
                "today": .object([
                    "input": .integer(100), "output": .integer(50),
                    "cacheRead": .integer(0), "cacheCreation": .integer(0),
                    "total": .integer(150),
                ]),
                "daily": .array([]),
                "hours": .array(Array(repeating: .integer(0), count: 24)),
            ]),
        ]),
        "services": .array([
            .object(serviceObject),
            .object([
                "id": .string("kimi"),
                "name": .string("Kimi"),
                "status": .string("ok"),
                "kind": .string("windows"),
                "windows": .array([]),
            ]),
        ]),
        "totalCostUsd": .null,
    ])
}

/// 12.1.1: 首轮 challenge 触发一次定向重试 (强制刷新 + retry-only), 全轮只发布一次.
private static func codexChallengeTriggersSingleTargetedRetry(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let retry = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 40,
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: [
            "codexQuotaRetryOnly": .boolean(true),
        ],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("fresh-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    // 直接触发一次运行 (不依赖计时器)
    let timers = FakeTimerScheduler()
    _ = timers
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)

    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 首轮 + 重试共 2 次运行, 重试上下文只含被挑战账号
    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "应执行首轮 + 一次定向重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    let retryContext = executor.receivedContexts.last ?? [:]
    try refreshExpect(
        retryContext["codexQuotaRetryOnly"] == .boolean(true),
        "重试上下文必须带 codexQuotaRetryOnly=true"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == ["acc-1"],
        "只应重试被挑战账号, got \(retryProvider.retriedAccountIDs)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "每轮最多一次 refreshAfterAccessRejected"
    )
    // 全轮只发布一次 (合并后)
    try refreshExpect(publishedCount == 1, "全轮只能发布一次 artifact, got \(publishedCount)")
    // 重试成功: 发布的是新额度与新 capturedAt, 非 Codex 部分保留
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"] else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    let codexService = services.first { $0.stringId() == mergerService1 }
    guard case .object(let codexObject)? = codexService,
          case .string(let status)? = codexObject["status"],
          case .string(let capturedAt)? = codexObject["capturedAt"] else {
        throw RefreshTestFailure.expectation("codex service 结构不符")
    }
    try refreshExpect(status == "ok", "重试成功应发布 ok 状态")
    try refreshExpect(capturedAt == "2026-07-28T12:01:00Z", "应使用新 capturedAt")
    // agents 保留首轮
    guard case .array(let agents)? = storedObject["agents"],
          case .object(let agent)? = agents.first,
          case .string(let agentID)? = agent["id"] else {
        throw RefreshTestFailure.expectation("agents 结构不符")
    }
    try refreshExpect(agentID == "codex", "agents 必须保留首次结果")
    // 非 codex service 保留首轮
    try refreshExpect(
        services.contains { $0.stringId() == "kimi" },
        "非 codex service 必须保留"
    )
}

/// 12.1.3: 重试响应仍带 challenge 时不再触发第三次 Collector.
private static func codexRetryChallengeDoesNotTriggerThirdRun(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    executor.retryHasChallenge = true
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-2"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "重试中的 challenge 不得触发第三次 Collector, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "每轮最多一次 refreshAfterAccessRejected"
    )
    // 重试仍 401 -> 账号持久化为 needsReauthorization (任务 8)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization == ["acc-1"],
        "第二次 401 必须持久化 needsReauthorization, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 12.1.4: 强制刷新失败 (需要重新授权) 不重试, 首次结果原样发布, 不整模块 authRequired.
private static func codexForceRefreshFailureKeepsFirstArtifact(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .failure(.needsReauthorization(accountID: "acc-1")),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-3"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(context: [:], credentials: [:])
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var lastStatus: ModuleRunState?
    scheduler.onStatusChange = { _, state, _ in lastStatus = state }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 刷新失败 -> 不重试, 只跑首轮
    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "刷新失败不得发起重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.isEmpty,
        "刷新失败不得请求重试输入"
    )
    // 模块级状态不进入 authRequired (artifact 存在, 部分结果照常发布)
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "部分失败不得使整个模块 authRequired"
    )
    try refreshExpect(
        lastStatus == .partial,
        "部分失败状态应为 partial, got \(String(describing: lastStatus))"
    )
}

/// 12.1.8/12.1.9: 重试 error 保留旧 windows/plan/extra/capturedAt, 只更新 status/note.
/// 旧额度来自上一轮已发布快照 (四源合并的 previous 源).
private static func codexRetryErrorPreservesLastGoodQuota(
    repository: URL
) async throws {
    let previous = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 45,
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let retry = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:01:00Z",
        note: "额度查询暂时失败, 请稍后重试",
        failureKind: "network"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-3",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-4"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // 预发布上一轮快照 (previous 源)
    try store.publish(previous, for: .agentUsage, attemptedAt: Date())

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"],
          case .object(let codexObject)? = services.first(where: {
              $0.stringId() == mergerService1
          }) else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    try refreshExpect(
        codexObject["status"] == .string("error"),
        "重试 error 应保留 error 状态"
    )
    // 旧额度数据保留: windows 仍带 45%
    guard case .array(let windows)? = codexObject["windows"],
          let window = windows.first,
          let windowObject = window.objectValue,
          let usedPercent = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("旧 windows 必须保留")
    }
    try refreshExpect(usedPercent == 45, "暂时失败必须保留旧额度窗口")
    try refreshExpect(
        codexObject["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "暂时失败必须保留旧 capturedAt"
    )
    try refreshExpect(
        codexObject["plan"] == .string("team"),
        "暂时失败必须保留旧 plan"
    )
    // 四源语义: 失败 + 有旧数据 -> freshness=stale
    try refreshExpect(
        codexObject["freshness"] == .string("stale"),
        "失败 + 有旧数据必须为 stale, got \(codexObject["freshness"] ?? .null)"
    )
    try refreshExpect(
        codexObject["failureKind"] == .string("network"),
        "必须保留本轮 failureKind=network"
    )
    // 网络失败不清除凭证 (第二次 401 才持久化重新授权)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization.isEmpty,
        "网络失败不得持久化重新授权, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 12.1.5/12.1.6: 无 challenge 时单轮发布, 不重试.
private static func codexWithoutChallengeRunsOnce(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 10,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "无 challenge 只运行一次, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "无 challenge 只发布一次")
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount.isEmpty,
        "无 challenge 不得调用 refreshAfterAccessRejected"
    )
}

// MARK: - 任务 5: Scheduler 单出口四源合并 (SCH-01 ~ SCH-12)

/// 通用: 读取发布后的最终 artifact (含四源合并结果).
private static func publishedArtifact(
    _ store: ArtifactStore
) throws -> JSONValue? {
    try store.load(.agentUsage, now: Date(), staleAfter: 3600).artifact
}

// SCH-01: 无 challenge, 本轮 Codex network fail -> 1 次采集, 1 次发布,
// 最终为 previous + first 四源合并
private static func schNoChallengeNetworkFailSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "无 challenge 只运行一次, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-01 只发布一次")
    // 最终 artifact 是合并器输出 (决策账号按 index 重排后的 currentID)
    let artifact = try publishedArtifact(store)
    let service = try mergerServiceValue(artifact ?? .null, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("unavailable"),
        "无 previous 时 network fail 应为 unavailable"
    )
}

// SCH-05: challenge, token refresh 失败 -> 1 次采集, 1 次发布
private static func schRefreshFailureSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = true
    // refresh 全部失败 -> 不重试
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .failure(.refreshFailed(
            accountID: mergerAccount1, reason: .networkError
        )),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .temporarilyUnavailable(retryAt: nil)),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "refresh 失败不得重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-05 仍须发布一次 (合并器输出)")
}

// SCH-06: challenge, retry input 为 nil -> 1 次采集, 1 次发布
private static func schRetryNilSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexRetryInput = nil
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retry nil 不得重试"
    )
    try refreshExpect(publishedCount == 1, "SCH-06 仍须发布一次")
}

// SCH-07: challenge, retry input 抛错 -> 1 次采集, 1 次发布
private static func schRetryThrowsSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = ThrowingRetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retry 抛错不得重试"
    )
    try refreshExpect(publishedCount == 1, "SCH-07 仍须发布一次")
}

// SCH-08: challenge, retry Collector 失败 -> 2 次采集, 1 次发布
private static func schRetryCollectorFailureSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.retryError = CodexRunInputFixtureError()
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: ["codexQuotaAccounts": .object([:])]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "SCH-08 应执行一次 retry, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-08 只发布一次")
}

// SCH-09: challenge, retry 成功 -> 2 次采集, 1 次发布, 四源合并
private static func schRetrySuccessSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: ["codexQuotaAccounts": .object([:])]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "SCH-09 应执行一次 retry"
    )
    try refreshExpect(publishedCount == 1, "SCH-09 只发布一次")
    // 合并结果: retry 成功 -> fresh + capturedAt
    let artifact = try publishedArtifact(store)
    let service = try mergerServiceValue(artifact ?? .null, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "SCH-09 最终应为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:01:00Z"),
        "SCH-09 应保留 retry capturedAt"
    )
}

// SCH-10: first Collector 无 artifact 失败 -> 0 次发布, previous 保留
private static func schFirstNoArtifactNoPublish(
    repository: URL
) async throws {
    let executor = AuthFailingExecutor()
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .authRequired)

    try refreshExpect(publishedCount == 0, "SCH-10 无 artifact 不得发布")
}

// SCH-11: merger 产生 legacy 歧义诊断 -> 诊断进入最终 artifact/状态
private static func schMergerDiagnosticPreserved(
    repository: URL
) async throws {
    // 两个账号共享 legacyID -> 歧义诊断 (任务 4 已构造场景)
    let accountA = "shareme-1a"
    let accountB = "shareme-1b"
    let serviceA = CodexAccountIdentity.serviceID(for: accountA)
    let serviceB = CodexAccountIdentity.serviceID(for: accountB)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: serviceA, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
            mergerCodexService(
                id: serviceB, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: accountA, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: accountB, outcome: .available(
            accessToken: "at2", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // 预置含共享 legacyID 的旧快照: 两个当前账号共享同一 legacyID,
    // 且 previous 中存在该 legacy service -> merger 产生歧义诊断.
    let legacyID = CodexAccountIdentity.legacyServiceID(for: accountA)
    try refreshExpect(
        legacyID == CodexAccountIdentity.legacyServiceID(for: accountB),
        "前置条件: 两个账号必须共享 legacyID"
    )
    try store.publish(
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-28T11:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string(legacyID),
                    "name": .string("Codex · 旧账号"),
                    "app": .string("codex"),
                    "status": .string("ok"),
                    "capturedAt": .string("2026-07-28T11:00:00Z"),
                    "windows": .array([]),
                ]),
            ]),
            "totalCostUsd": .null,
        ]),
        for: .agentUsage,
        attemptedAt: Date(timeIntervalSince1970: 1_752_000_000)
    )

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
    // 静态契约: 首轮 + 重试 + merger 诊断都进入最终输出 (任务 5 收敛为
    // 一个 finalizer, 不再有绕过 merger 的独立出口). 由 Scheduler 实现
    // 保证; 此处断言流程完成不崩溃 (实现细节见 handleCodexChallenges).
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "SCH-11 一轮后应 idle"
    )
    // UI-04/05: 合并期诊断 (legacy 歧义) 到达可观察边界, 且按
    // code|stage|message 去重后只保留一条.
    let published = scheduler.lastPublishedDiagnostics
    try refreshExpect(
        published.contains { $0.code == "CODEX_LEGACY_AMBIGUOUS" },
        "merger 歧义诊断必须到达发布诊断边界, got \(published.map(\.code))"
    )
    let ambiguous = published.filter { $0.code == "CODEX_LEGACY_AMBIGUOUS" }
    try refreshExpect(
        ambiguous.count == 1,
        "同类诊断必须去重为一条, got \(ambiguous.count)"
    )
}

/// 任务 11: 迁移 gate 未开放时 retryInput 返回 nil (调度器持有
/// 自定义提供器), 即使刷新成功也不发起定向重试, 首轮结果原样保留.
private static func codexRetryInputNilWhenGatedKeepsFirstArtifact(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-gated",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    // gate 关闭: 提供器对定向重试返回 nil
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-gated"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = nil
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var lastStatus: ModuleRunState?
    scheduler.onStatusChange = { _, state, _ in lastStatus = state }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retryInput 返回 nil 时不得发起重试运行, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "challenge 仍应调用 refreshAfterAccessRejected"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == ["acc-1"],
        "retryInput 应被询问被挑战账号"
    )
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "无重试时模块保持 idle"
    )
    try refreshExpect(
        lastStatus == .partial,
        "gate 关闭时保留首轮 partial 结果, got \(String(describing: lastStatus))"
    )
}

/// 任务 8: 两个账号同时 401 在同一轮完成刷新和重试 (单次 retry-only 运行),
/// 各自 OAuth 刷新只调用一次.
private static func codexTwoAccounts401SingleCycle(
    repository: URL
) async throws {
    let account2 = "acc-2"
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // retry artifact 含两个账号 service (currentID)
    let firstServices = mergerArtifact(
        codexServices: [mergerCodexService(
            id: mergerService1, status: "ok", usedPercent: 40,
            capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
        )],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    _ = firstServices
    let executor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry,
        challengedAccounts: [mergerAccount1, account2]
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "fresh-a",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
        account2: .success(
            accessToken: "fresh-b",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                mergerAccount1: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-a"),
                ]),
                account2: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-b"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: account2, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 单周期最多两次 Collector
    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "两账号 401 必须一轮完成, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    // 两个账号的 OAuth 刷新都只调用一次
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount[mergerAccount1] == 1,
        "acc-1 刷新必须只调用一次"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount[account2] == 1,
        "acc-2 刷新必须只调用一次"
    )
    // retry 输入一次包含两个账号
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == [mergerAccount1, account2],
        "retry 输入必须一次包含两个账号, got \(retryProvider.retriedAccountIDs)"
    )
    // 全轮只发布一次
    try refreshExpect(publishedCount == 1, "全轮只能发布一次, got \(publishedCount)")
    // 两个账号都发布成功数据
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"] else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    let acc1 = services.first { $0.stringId() == mergerService1 }
    let acc2 = services.first { $0.stringId() == mergerService2 }
    try refreshExpect(acc1 != nil && acc2 != nil, "两个账号 service 都必须发布")
    // 第二次 401 不触发 (两个都成功)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization.isEmpty,
        "重试成功后不得持久化重新授权, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 任务 8: 第二次 401 只影响对应账号 (另一账号成功保持 connected).
private static func codexSecond401OnlyAffectsItsAccount(
    repository: URL
) async throws {
    let account2 = "acc-2"
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // acc-1 重试仍 401, acc-2 重试成功
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry,
        challengedAccounts: [mergerAccount1, account2]
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "fresh-a2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
        account2: .success(
            accessToken: "fresh-b2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                mergerAccount1: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-a2"),
                ]),
                account2: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-b2"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: account2, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "单周期最多两次 Collector, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    // 第二次 401 只持久化 acc-1
    try refreshExpect(
        tokenManager.markedNeedsReauthorization == [mergerAccount1],
        "第二次 401 只影响对应账号, got \(tokenManager.markedNeedsReauthorization)"
    )
    // acc-2 成功数据保留
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"],
          case .object(let acc2Object)? = services.first(where: {
              $0.stringId() == mergerService2
          }) else {
        throw RefreshTestFailure.expectation("acc-2 成功 service 必须发布")
    }
    try refreshExpect(
        acc2Object["freshness"] == .string("fresh"),
        "acc-2 重试成功必须为 fresh"
    )
}

/// 任务 8: 非法 challenge (不属于本轮注入账号) 被丢弃, 不触发重试.
private static func codexInvalidChallengeIgnored(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // 注入账号是 acc-1, 但 challenge 指向 acc-9 (非法)
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-legal"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    // 自定义 executor: challenge 指向未注入账号
    let invalidExecutor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first,
        challengedAccounts: ["acc-9"]
    )
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: invalidExecutor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        invalidExecutor.runCount[.agentUsage] == 1,
        "非法 challenge 不得触发重试, got \(invalidExecutor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount.isEmpty,
        "非法 challenge 不得调用刷新"
    )
}

/// 直接触发一次刷新运行 (start 后 enableModule 会排 0 延迟计时器).
@MainActor
private static func triggerFirstRefresh(
    scheduler: RefreshScheduler,
    repository: URL
) async throws {
    scheduler.refresh(.agentUsage)
}

// MARK: - 任务 7: 四源快照合并器

/// 任务 7 固定测试向量 (与 collect_usage.py _codex_service_id 对齐).
private static let mergerAccount1 = "acc-1"
private static let mergerAccount2 = "acc-2"
private static let mergerService1 = "codex_cf9df9b99fc0a24b"
private static let mergerService2 = "codex_a75990ab7ebfd8a9"
private static let mergerLegacy1 = "codex_acc-1"
private static let mergerLegacy2 = "codex_acc-2"

/// 构造单账号 Codex service (任务 7 契约字段).
private static func mergerCodexService(
    id: String,
    status: String,
    usedPercent: Double,
    capturedAt: String?,
    freshness: String?,
    failureKind: String? = nil,
    note: String? = nil
) -> JSONValue {
    var object: [String: JSONValue] = [
        "id": .string(id),
        "name": .string("Codex · user"),
        "app": .string("codex"),
        "status": .string(status),
        "kind": .string("windows"),
        "plan": .string("team"),
        "windows": .array([
            .object([
                "label": .string("5小时窗口"),
                "usedPercent": .double(usedPercent),
                "windowMinutes": .integer(300),
                "resetsAt": .null,
            ]),
        ]),
    ]
    if let capturedAt {
        object["capturedAt"] = .string(capturedAt)
    }
    if let freshness {
        object["freshness"] = .string(freshness)
    }
    if let failureKind {
        object["failureKind"] = .string(failureKind)
    }
    if let note {
        object["note"] = .string(note)
    }
    return .object(object)
}

/// 构造 artifact: codex services + 非 codex service + agents.
private static func mergerArtifact(
    codexServices: [JSONValue],
    generatedAt: String,
    includeKimi: Bool = true
) -> JSONValue {
    var services = codexServices
    if includeKimi {
        services.append(.object([
            "id": .string("kimi"),
            "name": .string("Kimi"),
            "status": .string("ok"),
            "kind": .string("windows"),
            "windows": .array([]),
        ]))
    }
    return .object([
        "schemaVersion": .integer(1),
        "module": .string("agent-usage"),
        "generatedAt": .string(generatedAt),
        "agents": .array([
            .object([
                "id": .string("codex"),
                "name": .string("Codex"),
                "status": .string("ok"),
                "today": .object([
                    "input": .integer(100), "output": .integer(50),
                    "cacheRead": .integer(0), "cacheCreation": .integer(0),
                    "total": .integer(150),
                ]),
                "daily": .array([]),
                "hours": .array(Array(repeating: .integer(0), count: 24)),
            ]),
        ]),
        "services": .array(services),
        "totalCostUsd": .null,
    ])
}

/// 单账号 available 决议 (currentID 由 CodexAccountIdentity 生成).
private static func mergerDecision(
    index: Int,
    accountID: String,
    outcome: CodexTokenDecision.Outcome
) -> CodexTokenDecision {
    CodexTokenDecision(
        index: index,
        accountID: accountID,
        serviceID: CodexAccountIdentity.serviceID(for: accountID),
        displayName: "Codex · user",
        outcome: outcome
    )
}

/// 从合并结果取 service 列表 (id -> JSONValue).
private static func mergerServices(
    _ artifact: JSONValue
) throws -> [String: JSONValue] {
    guard case .object(let object) = artifact,
          case .array(let services)? = object["services"] else {
        throw RefreshTestFailure.expectation("合并结果 services 结构不符")
    }
    return Dictionary(
        uniqueKeysWithValues: services.compactMap { service -> (String, JSONValue)? in
            guard let id = service.stringId() else { return nil }
            return (id, service)
        }
    )
}

private static func mergerServiceValue(
    _ artifact: JSONValue,
    id: String
) throws -> [String: JSONValue] {
    guard let service = try mergerServices(artifact)[id],
          case .object(let object) = service else {
        throw RefreshTestFailure.expectation("缺少 service \(id)")
    }
    return object
}

/// 1. previous 成功 + 本轮网络失败 -> stale 且保留旧 capturedAt.
private static func codexMergerPreviousSuccessKeepsStaleData() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 45,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "本轮失败 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("network"),
        "必须保留本轮 failureKind, got \(service["failureKind"] ?? .null)"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("旧 windows 必须保留")
    }
    try refreshExpect(used == 45, "必须保留旧窗口 45%")
}

// MARK: - 任务 4: previous 成功资格 (MERGE-01 ~ MERGE-08)

/// 任务 4 判定辅助: 本轮失败 (error + failureKind) 的 first, previous 由调用方传入.
private static func mergerQualifiedCheck(
    previous: JSONValue?,
    expectedFreshness: String,
    expectedCapturedAt: String?,
    expectDiagnostic: String? = nil
) throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string(expectedFreshness),
        "freshness 应为 \(expectedFreshness), got \(service["freshness"] ?? .null)"
    )
    if let expectedCapturedAt {
        try refreshExpect(
            service["capturedAt"] == .string(expectedCapturedAt),
            "capturedAt 应为 \(expectedCapturedAt)"
        )
    } else {
        try refreshExpect(
            service["capturedAt"] == nil,
            "capturedAt 应为空"
        )
    }
    if let expectDiagnostic {
        try refreshExpect(
            result.diagnostics.contains { $0.code == expectDiagnostic },
            "应产生诊断 \(expectDiagnostic)"
        )
    }
}

// MERGE-01: previous freshness=unavailable + capturedAt -> 本轮失败 -> unavailable, 无 lastSuccessAt
private static func codexMergerPreviousUnavailableNotQualified() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-02: previous status=error + capturedAt -> 本轮失败 -> unavailable, 无 lastSuccessAt
private static func codexMergerPreviousErrorNotQualified() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// 旧格式必须显式 status=ok 或 status=""; 缺失 status 不能伪装为成功快照.
private static func codexMergerPreviousMissingStatusNotQualified() throws {
    guard case .object(var service) = mergerCodexService(
        id: mergerService1,
        status: "ok",
        usedPercent: 21,
        capturedAt: "2026-07-28T09:00:00Z",
        freshness: nil
    ) else {
        throw RefreshTestFailure.expectation("previous fixture 不是 object")
    }
    service.removeValue(forKey: "status")
    let previous = mergerArtifact(
        codexServices: [.object(service)],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-03: legacy 格式 status=ok + capturedAt -> 本轮失败 -> stale, 继承成功时间
private static func codexMergerLegacyOKQualifiedStale() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 33,
                capturedAt: "2026-07-28T08:00:00Z", freshness: nil
            ),
        ],
        generatedAt: "2026-07-28T08:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "stale",
        expectedCapturedAt: "2026-07-28T08:00:00Z"
    )
}

// MERGE-04: freshness=fresh 但 capturedAt 无效 -> 本轮失败 -> unavailable
private static func codexMergerPreviousInvalidCapturedAt() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 20,
                capturedAt: "not-a-date", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-05: freshness=stale + 有效 capturedAt -> 本轮失败 -> stale, 成功时间不前移
private static func codexMergerStalePreviousKeepsSuccessTime() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T07:00:00Z", freshness: "stale"
            ),
        ],
        generatedAt: "2026-07-28T07:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "stale",
        expectedCapturedAt: "2026-07-28T07:00:00Z"
    )
}

// MERGE-06: 首次失败, 无 previous -> unavailable, 无 capturedAt
private static func codexMergerFirstFailureUnavailable() throws {
    try mergerQualifiedCheck(
        previous: nil,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-07: current 与 legacy 同时存在 -> 本轮失败 -> 只用合格 current, legacy 丢弃
private static func codexMergerCurrentDisqualifiedLegacyDropped() throws {
    // previous: currentID 为失败 (不合格), legacyID 为成功
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "unavailable",
                failureKind: "auth"
            ),
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 80,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    try mergerQualifiedCheck(
        previous: previous,
        expectedFreshness: "unavailable",
        expectedCapturedAt: nil
    )
}

// MERGE-08: legacy ID 匹配多个当前账号 -> 不复用额度, 输出诊断
private static func codexMergerLegacyAmbiguousFailure() throws {
    // 两个不同 accountID 共享前 8 位 -> 相同 legacyID (歧义);
    // serviceID (SHA-256 前 16 位) 不同, 按决策生成 first services
    let accountA = "shareme-1a"
    let accountB = "shareme-1b"
    let serviceA = CodexAccountIdentity.serviceID(for: accountA)
    let serviceB = CodexAccountIdentity.serviceID(for: accountB)
    try refreshExpect(
        CodexAccountIdentity.legacyServiceID(for: accountA)
            == CodexAccountIdentity.legacyServiceID(for: accountB),
        "前置: 两账号 legacyID 必须相同"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: serviceA, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
            mergerCodexService(
                id: serviceB, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: CodexAccountIdentity.legacyServiceID(for: accountA),
                status: "ok", usedPercent: 90,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T08:00:00Z"
    )
    let decisions = [
        mergerDecision(index: 0, accountID: accountA, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: accountB, outcome: .available(
            accessToken: "at2", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: decisions
    )
    // 两个 service 都不复用旧额度 (歧义)
    for id in [serviceA, serviceB] {
        let service = try mergerServiceValue(result.artifact, id: id)
        try refreshExpect(
            service["freshness"] == .string("unavailable"),
            "歧义 legacy 不得复用旧额度"
        )
        try refreshExpect(
            service["capturedAt"] == nil,
            "歧义 legacy 不得继承 capturedAt"
        )
    }
    try refreshExpect(
        result.diagnostics.contains { $0.code == "CODEX_LEGACY_AMBIGUOUS" },
        "应产生歧义诊断"
    )
}

/// 2. 无 previous + 本轮失败 -> unavailable 且没有 capturedAt.
private static func codexMergerNoPreviousFailureUnavailable() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("unavailable"),
        "无旧数据必须为 unavailable"
    )
    try refreshExpect(
        service["capturedAt"] == nil,
        "unavailable 不得有 capturedAt"
    )
    try refreshExpect(
        service["failureKind"] == .string("auth"),
        "必须写 failureKind=auth"
    )
}

/// 3. 首轮 401 + retry 成功 -> fresh.
private static func codexMergerFirst401RetrySuccessFresh() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(service["status"] == .string("ok"), "retry 成功必须覆盖 status")
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "retry 成功必须为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:01:00Z"),
        "fresh 必须使用本轮 capturedAt"
    )
    // 整体状态按最终 artifact 重算, 不直接采用 retry response 状态
    try refreshExpect(
        result.recomputedStatus == .success,
        "全部 ok 时整体状态应为 success"
    )
}

/// 4. 首轮 401 + retry 401 -> stale/auth 或 unavailable/auth.
private static func codexMergerRetry401StaleAuth() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 60,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "第二次 401 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("auth"),
        "第二次 401 failureKind 必须为 auth"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "第二次 401 必须保留旧 capturedAt"
    )

    // 无 previous 时 -> unavailable/auth, 无 capturedAt.
    let noPrevious = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let unavailable = try mergerServiceValue(noPrevious.artifact, id: mergerService1)
    try refreshExpect(
        unavailable["freshness"] == .string("unavailable"),
        "第二次 401 + 无旧数据必须为 unavailable"
    )
    try refreshExpect(
        unavailable["capturedAt"] == nil,
        "unavailable 不得有 capturedAt"
    )
    try refreshExpect(
        unavailable["failureKind"] == .string("auth"),
        "unavailable 必须写 failureKind=auth"
    )
}

/// 5. token storageBlocked + previous 成功 -> stale/storage.
private static func codexMergerStorageBlockedStale() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 首轮无该账号 service (storageBlocked 决议 -> 未注入 Bridge)
    let first = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:00:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: mergerAccount1, outcome: .storageBlocked),
        ]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "storageBlocked + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("storage"),
        "storageBlocked failureKind 必须为 storage, got \(service["failureKind"] ?? .null)"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "storageBlocked 必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("storageBlocked 必须保留旧 windows")
    }
    try refreshExpect(used == 55, "storageBlocked 必须保留旧窗口 55%")
}

/// 6. 删除账号后旧 service 不再出现.
private static func codexMergerDeletedAccountDropped() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 45,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 70,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮只有 acc-1 (acc-2 已断开, 未出现在 index)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 42,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(services[mergerService1] != nil, "当前账号必须保留")
    try refreshExpect(
        services[mergerService2] == nil,
        "已删除账号的旧 service 不得出现"
    )
}

/// 7. retry 响应缺失账号时保留旧快照.
private static func codexMergerRetryMissingAccountKeepsPrevious() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 50,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 首轮 401 (unavailable/auth), retry 不含该账号 (collector 未返回)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:01:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: retry,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "retry 缺失账号 + 首轮失败 + 有旧数据必须为 stale"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "retry 缺失时必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("retry 缺失时必须保留旧 windows")
    }
    try refreshExpect(used == 50, "retry 缺失时必须保留旧窗口 50%")
}

/// 8. legacy ID + 本轮失败 -> 旧额度迁移到新 ID 并标记 stale.
private static func codexMergerLegacyFailureMigratesToNewID() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 48,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮失败, 输出必须使用新 ID (currentID)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "rateLimit", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "输出不得再出现 legacy ID"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("stale"),
        "legacy 迁移 + 本轮失败必须为 stale"
    )
    try refreshExpect(
        service["failureKind"] == .string("rateLimit"),
        "legacy 迁移失败必须保留 failureKind"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "legacy 迁移必须保留旧 capturedAt"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("legacy 迁移必须保留旧 windows")
    }
    try refreshExpect(used == 48, "legacy 迁移必须保留旧窗口 48%")
}

/// 9. legacy ID + 本轮成功 -> 输出新 ID 和 fresh 数据.
private static func codexMergerLegacySuccessNewIDFresh() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 48,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 30,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "成功迁移后不得残留 legacy ID"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "legacy 迁移 + 本轮成功必须为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:00:00Z"),
        "本轮成功必须使用新 capturedAt"
    )
}

/// 10. current ID 和 legacy ID 同时存在时优先 current ID.
private static func codexMergerCurrentIDPreferredOverLegacy() throws {
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 80,
                capturedAt: "2026-07-28T09:00:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerLegacy1, status: "ok", usedPercent: 60,
                capturedAt: "2026-07-28T08:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T09:00:00Z"
    )
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ))]
    )
    let services = try mergerServices(result.artifact)
    try refreshExpect(
        services[mergerLegacy1] == nil,
        "previous 中的 legacy 条目必须丢弃"
    )
    let service = try mergerServiceValue(result.artifact, id: mergerService1)
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T09:00:00Z"),
        "必须使用 current ID 的旧数据 (80%), 而非 legacy (60%)"
    )
    guard case .array(let windows)? = service["windows"],
          let windowObject = windows.first?.objectValue,
          let used = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("current ID 旧 windows 必须保留")
    }
    try refreshExpect(used == 80, "必须保留 current ID 的旧窗口 80%")
}

/// 11. legacy ID 匹配多个账号时不跨账号复用额度.
private static func codexMergerLegacyAmbiguousNoCrossAccount() throws {
    // acc-1 与 acc-2 的 legacy ID 相同 (构造账号名使前 8 位一致)
    let accountA = "shareacc-1a"
    let accountB = "shareacc-1b"
    let legacyShared = "codex_" + String(accountA.prefix(8))
    let previous = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: legacyShared, status: "ok", usedPercent: 75,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T10:00:00Z"
    )
    // 本轮两个账号都失败且没有 currentID service
    let first = mergerArtifact(codexServices: [], generatedAt: "2026-07-28T12:00:00Z")
    let result = CodexQuotaSnapshotMerger().merge(
        previous: previous,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: accountA, outcome: .temporarilyUnavailable(retryAt: nil)),
            mergerDecision(index: 1, accountID: accountB, outcome: .temporarilyUnavailable(retryAt: nil)),
        ]
    )
    let services = try mergerServices(result.artifact)
    let serviceAID = CodexAccountIdentity.serviceID(for: accountA)
    let serviceBID = CodexAccountIdentity.serviceID(for: accountB)
    let serviceA = try mergerServiceValue(result.artifact, id: serviceAID)
    let serviceB = try mergerServiceValue(result.artifact, id: serviceBID)
    // 歧义时不复用旧额度 -> unavailable/tokenUnavailable, 无 capturedAt
    try refreshExpect(
        serviceA["freshness"] == .string("unavailable"),
        "legacy 歧义账号 A 不得复用旧额度"
    )
    try refreshExpect(
        serviceB["freshness"] == .string("unavailable"),
        "legacy 歧义账号 B 不得复用旧额度"
    )
    try refreshExpect(serviceA["capturedAt"] == nil, "歧义账号 A 不得有 capturedAt")
    try refreshExpect(serviceB["capturedAt"] == nil, "歧义账号 B 不得有 capturedAt")
    try refreshExpect(
        serviceA["failureKind"] == .string("tokenUnavailable"),
        "歧义账号 A failureKind 应为 tokenUnavailable"
    )
    try refreshExpect(services[legacyShared] == nil, "歧义 legacy 条目必须丢弃")
}

/// 补充: Codex services 始终按当前账号 index 排序 (低 index 失败账号也排在
/// 高 index 成功账号之前).
private static func codexMergerServicesOrderedByAccountIndex() throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 30,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // acc-1 (index 0) storageBlocked 未注入 -> 合成条目必须排在 acc-2 之前
    let result = CodexQuotaSnapshotMerger().merge(
        previous: nil,
        first: first,
        retry: nil,
        decisions: [
            mergerDecision(index: 0, accountID: mergerAccount1, outcome: .storageBlocked),
            mergerDecision(index: 1, accountID: mergerAccount2, outcome: .available(
                accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
            )),
        ]
    )
    guard case .object(let object) = result.artifact,
          case .array(let services)? = object["services"] else {
        throw RefreshTestFailure.expectation("合并结果 services 结构不符")
    }
    let codexOrder = services.compactMap { service -> String? in
        guard isCodexServiceTest(service) else { return nil }
        return service.stringId()
    }
    try refreshExpect(
        codexOrder == [mergerService1, mergerService2],
        "Codex services 必须按账号 index 排序, got \(codexOrder)"
    )
}

private static func isCodexServiceTest(_ value: JSONValue) -> Bool {
    guard case .object(let object) = value,
          case .string(let app)? = object["app"] else {
        return false
    }
    return app == "codex"
}

/// 补充: stale 条目不参与 quota alert 阈值穿越.
private static func quotaAlertSkipsStaleEntries() throws {
    // stale Codex service 保留 85% 旧窗口, 不得触发预警
    let stale = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 85,
                capturedAt: "2026-07-28T10:00:00Z", freshness: "stale",
                failureKind: "network"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let staleEntries = QuotaAlertEvaluator.overThresholdEntries(artifact: stale)
    try refreshExpect(
        staleEntries.isEmpty,
        "stale 条目不得触发 quota alert, got \(staleEntries)"
    )

    // fresh 同窗口仍正常报警
    let fresh = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 85,
                capturedAt: "2026-07-28T12:00:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let freshEntries = QuotaAlertEvaluator.overThresholdEntries(artifact: fresh)
    try refreshExpect(
        freshEntries.count == 1,
        "fresh 超过阈值条目必须报警, got \(freshEntries)"
    )
}

/// JSON 数值宽容取值: JSONValue 解码时整数优先 (45.0 -> .integer(45)).
private enum JSONNumber {
    static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number):
            return number
        case .integer(let number):
            return Double(number)
        default:
            return nil
        }
    }
}
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

@MainActor
private final class FailingExecutor: CollectorExecuting {
    let error: Error
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(error: Error) { self.error = error }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        throw error
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

@MainActor
private final class AuthFailingExecutor: CollectorExecuting {
    private(set) var runCount: [CollectorModule: Int] = [:]

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return makeErrorOutput(category: "auth", code: "AUTH_FAILED")
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

@MainActor
private final class PartialSuccessExecutor: CollectorExecuting {
    let artifact: JSONValue
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(artifact: JSONValue) { self.artifact = artifact }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: [BridgeDiagnostic(
                    code: "COLLECTOR_PARTIAL_RESULT",
                    category: "collector",
                    stage: "collect",
                    message: "部分数据源采集失败",
                    retryable: true
                )],
            credentialChallenges: []
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

// MARK: - Factory for custom executors

@MainActor
private func makeSchedulerWithError(
    repository: URL,
    executor: CollectorExecuting,
    clock: ManualClock,
    timers: FakeTimerScheduler,
    credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mddd-sched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ArtifactStore(rootURL: root)
    let config = SchedulerConfiguration(
        refreshInterval: 1800,
        staleAfter: 3600,
        maxBackoffRetries: 3,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2
    )
    let scheduler = RefreshScheduler(
        executor: executor,
        store: store,
        clock: clock,
        timerScheduler: timers,
        configuration: config,
        jitterProvider: { _ in 0 },
        registerWakeNotifications: false,
        credentialUpdateCoordinator: credentialUpdateCoordinator
    )
    return (scheduler, store, root)
}

/// saveCredential 恒抛错, 用于验证 Scheduler 写回失败 → partial 路径.
private final class ThrowingCredentialStoreForScheduler: CredentialStore, @unchecked Sendable {
    func loadCredential(forAccount account: String) throws -> String? { nil }

    func saveCredential(_ value: String, forAccount account: String) throws {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "keychain denied",
        ])
    }

    func deleteCredential(forAccount account: String) throws {}
}

/// 成功响应携带 credentialUpdates 的执行器, 用于验证 Scheduler 写回路径.
@MainActor
private final class CredentialUpdateExecutor: CollectorExecuting {
    let artifact: JSONValue
    let updates: [JSONValue]
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(artifact: JSONValue, updates: [JSONValue]) {
        self.artifact = artifact
        self.updates = updates
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: .success,
                artifact: artifact,
                credentialUpdates: updates,
                diagnostics: [],
            credentialChallenges: []
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}
