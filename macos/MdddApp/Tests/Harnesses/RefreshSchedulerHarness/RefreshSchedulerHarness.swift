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
        print("Refresh scheduler: credential updates")
        try await credentialUpdatesForwardedOnSuccess(repository: repository)
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
        print("Refresh scheduler: codex retry gate closed")
        try await codexRetryInputNilWhenGatedKeepsFirstArtifact(repository: repository)
        print("Refresh scheduler: codex merger multi account")
        try await codexMergerMultiAccountAndNewEntries()
        print("Refresh scheduler tests passed: 21")
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
            scheduler.moduleState(for: .agentUsage)?.pendingRerun == true,
            "pendingRerun should be set"
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
            scheduler.moduleState(for: .agentUsage)?.pendingRerun == false,
            "pendingRerun should be cleared"
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

        // The second and third wake calls should have set pendingRerun (merged)
        // since the module is running
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingRerun == true,
            "repeated wake should merge into pendingRerun"
        )

        // Release the compensating refresh
        executor.release(module: .agentUsage)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 3)
        // The rerun from pendingRerun

        try refreshExpect(
            executor.runCount[.agentUsage] == 3,
            "pendingRerun should trigger one additional run"
        )

        executor.release(module: .agentUsage)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
    }

    // 10.5: Partial result publishes artifact
    private static func partialResultPublishesArtifact(
        repository: URL
    ) async throws {
        let artifact = try loadFixture(repository: repository, module: .agentUsage)
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

    // 10.6: credentialUpdates forwarded on success
    private static func credentialUpdatesForwardedOnSuccess(
        repository: URL
    ) async throws {
        let artifact = try loadFixture(repository: repository, module: .agentUsage)
        let updates: [JSONValue] = [
            .object([
                "provider": .string("codex"),
                "accountId": .string("acc-1"),
                "kind": .string("oauthTokens"),
                "operation": .string("replace"),
                "credentials": .object([
                    "access_token": .string("na"),
                    "refresh_token": .string("nr"),
                ]),
            ]),
        ]
        let executor = CredentialUpdateExecutor(artifact: artifact, updates: updates)
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeSchedulerWithError(
            repository: repository,
            executor: executor,
            clock: clock,
            timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var received: [JSONValue] = []
        scheduler.onCredentialUpdates = { _, value in received = value }

        scheduler.start()
        scheduler.enableModule(.agentUsage)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

        try refreshExpect(
            received == updates,
            "credentialUpdates 必须原样转发, got \(received)"
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

/// 记录刷新调用但默认拒绝的 token manager fake (任务 9).
@MainActor
private final class StubCodexTokenManager: CodexTokenManaging {
    var resolutions: [String: TokenResolution] = [:]
    private(set) var invalidated: [String] = []
    private(set) var forcedRefreshCount: [String: Int] = [:]

    func invalidateAccessToken(for accountID: String) async {
        invalidated.append(accountID)
    }

    func forceRefresh(
        for accountID: String,
        now: Date?
    ) async -> TokenResolution {
        forcedRefreshCount[accountID, default: 0] += 1
        return resolutions[accountID]
            ?? .failure(.notFound(accountID: accountID))
    }
}

/// 定向重试输入提供器 (任务 9): 记录首轮与重试调用.
@MainActor
private final class RetryInputProvider: CollectorRunInputProviding {
    var codexRetryInput: CollectorRunInput?
    var firstInput = CollectorRunInput(context: [:], credentials: [:])
    private(set) var retriedAccounts: [String] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        firstInput
    }

    func retryInput(
        for module: CollectorModule,
        accountID: String
    ) async throws -> CollectorRunInput? {
        retriedAccounts.append(accountID)
        return codexRetryInput
    }
}

/// 构造带 codex token manager 的调度器.
@MainActor
private static func makeSchedulerWithCodex(
    repository: URL,
    executor: CollectorExecuting,
    tokenManager: StubCodexTokenManager,
    retryProvider: RetryInputProvider? = nil
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
@MainActor
private static func makeCodexQuotaArtifact(
    status: String,
    usedPercent: Double,
    generatedAt: String,
    note: String? = nil
) -> JSONValue {
    var serviceObject: [String: JSONValue] = [
        "id": .string("codex_acc-1"),
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
        retryProvider.retriedAccounts == ["acc-1"],
        "只应重试被挑战账号, got \(retryProvider.retriedAccounts)"
    )
    try refreshExpect(
        tokenManager.invalidated == ["acc-1"],
        "必须失效被挑战账号的 access token"
    )
    try refreshExpect(
        tokenManager.forcedRefreshCount["acc-1"] == 1,
        "每轮最多一次强制刷新"
    )
    // 全轮只发布一次 (合并后)
    try refreshExpect(publishedCount == 1, "全轮只能发布一次 artifact, got \(publishedCount)")
    // 重试成功: 发布的是新额度与新 capturedAt, 非 Codex 部分保留
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"] else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    let codexService = services.first { $0.stringId() == "codex_acc-1" }
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
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
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
        tokenManager.forcedRefreshCount["acc-1"] == 1,
        "每轮最多一次强制刷新"
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
        retryProvider.retriedAccounts.isEmpty,
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
private static func codexRetryErrorPreservesLastGoodQuota(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 45,
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let retry = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:01:00Z",
        note: "额度查询暂时失败, 请稍后重试"
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
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
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

    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"],
          case .object(let codexObject)? = services.first(where: {
              $0.stringId() == "codex_acc-1"
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
        tokenManager.invalidated.isEmpty,
        "无 challenge 不得失效 token"
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
        tokenManager.invalidated == ["acc-1"],
        "challenge 仍应先失效 access token"
    )
    try refreshExpect(
        retryProvider.retriedAccounts == ["acc-1"],
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

/// 直接触发一次刷新运行 (start 后 enableModule 会排 0 延迟计时器).
@MainActor
private static func triggerFirstRefresh(
    scheduler: RefreshScheduler,
    repository: URL
) async throws {
    scheduler.refresh(.agentUsage)
}

/// 12.1.10/12.1.2 补充: merger 纯逻辑 — 多账号只合并被覆盖项,
/// 重试新增的账号条目并入, 非 codex service 与 agents 不动.
private static func codexMergerMultiAccountAndNewEntries() throws {
    func codexService(
        _ id: String,
        status: String,
        used: Int,
        capturedAt: String
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "name": .string("Codex · user"),
            "app": .string("codex"),
            "status": .string(status),
            "kind": .string("windows"),
            "plan": .string("team"),
            "capturedAt": .string(capturedAt),
            "windows": .array([
                .object([
                    "label": .string("5小时窗口"),
                    "usedPercent": .integer(used),
                    "windowMinutes": .integer(300),
                    "resetsAt": .null,
                ]),
            ]),
        ])
    }
    func kimiService() -> JSONValue {
        .object([
            "id": .string("kimi"),
            "name": .string("Kimi"),
            "status": .string("ok"),
            "kind": .string("windows"),
            "windows": .array([]),
        ])
    }
    func makeArtifact(codex: [JSONValue]) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-28T12:00:00Z"),
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
            "services": .array(codex + [kimiService()]),
            "totalCostUsd": .null,
        ])
    }

    let first = makeArtifact(codex: [
        codexService("codex_acc-1", status: "ok", used: 20, capturedAt: "2026-07-28T10:00:00Z"),
    ])
    let retry = makeArtifact(codex: [
        codexService("codex_acc-1", status: "error", used: 0, capturedAt: "2026-07-28T12:01:00Z"),
        codexService("codex_acc-2", status: "ok", used: 55, capturedAt: "2026-07-28T12:01:00Z"),
    ])
    let result = CodexQuotaSnapshotMerger().merge(first: first, retry: retry)
    guard case .object(let mergedObject) = result.artifact,
          case .array(let services)? = mergedObject["services"] else {
        throw RefreshTestFailure.expectation("合并结果结构不符")
    }
    let byID = Dictionary(
        uniqueKeysWithValues: services.compactMap { service -> (String, JSONValue)? in
            guard let id = service.stringId() else { return nil }
            return (id, service)
        }
    )
    // acc-1: retry error 保留旧 windows (20%) 与旧 capturedAt
    guard case .object(let acc1)? = byID["codex_acc-1"],
          case .array(let acc1Windows)? = acc1["windows"],
          case .object(let window)? = acc1Windows.first,
          case .integer(let used)? = window["usedPercent"] else {
        throw RefreshTestFailure.expectation("acc-1 合并结果结构不符")
    }
    try refreshExpect(used == 20, "error 重试必须保留旧窗口, got \(used)")
    try refreshExpect(
        acc1["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "error 重试必须保留旧 capturedAt"
    )
    // acc-2: 重试新增条目并入
    try refreshExpect(
        byID["codex_acc-2"] != nil,
        "重试新增账号条目必须并入"
    )
    // kimi 非 codex service 保留, agents 保留
    try refreshExpect(byID["kimi"] != nil, "非 codex service 必须保留")
    guard case .array(let agents)? = mergedObject["agents"],
          !agents.isEmpty else {
        throw RefreshTestFailure.expectation("agents 必须保留")
    }
    try refreshExpect(result.mergedCount == 1, "只应合并 1 个已存在条目, got \(result.mergedCount)")
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
    timers: FakeTimerScheduler
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
        registerWakeNotifications: false
    )
    return (scheduler, store, root)
}


/// 成功响应携带 credentialUpdates 的执行器, 用于验证 Scheduler 转发.
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
