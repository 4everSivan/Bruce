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
            artifact: try loadFixture(
                repository: repository,
                module: module
            ),
            credentialUpdates: [],
            diagnostics: []
        )
        return CollectorRunOutput(response: response, stderrDiagnostic: nil)
    }
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
            diagnostics: []
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
            )]
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
        print("Refresh scheduler: capacity")
        try await capacityLimitQueuesRequest(repository: repository)
        print("Refresh scheduler: stop")
        try await stopCancelsRunningTasks(repository: repository)
        print("Refresh scheduler: interval update")
        try await updateRefreshIntervalReschedulesIdleModule(repository: repository)
        print("Refresh scheduler: credential updates")
        try await credentialUpdatesForwardedOnSuccess(repository: repository)
        print("Refresh scheduler tests passed: 11")
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
        scheduler.enableModule(.github)

        // EnableModule schedules a refresh with delay 0 (no lastSuccessAt)
        // Fire the timer
        try refreshExpect(timers.pendingCount == 1, "expected one scheduled timer")
        timers.fireFirst()

        // Wait for the executor to be called
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        try refreshExpect(
            scheduler.moduleState(for: .github)?.phase == .running,
            "module should be running"
        )

        executor.release(module: .github)
        await waitForPhase(scheduler, module: .github, phase: .idle)
        try refreshExpect(
            executor.runCount[.github] == 1,
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
        scheduler.enableModule(.gitlab)
        timers.fireFirst() // trigger initial refresh
        await waitForRunCount({ executor.runCount[.gitlab] ?? 0 }, count: 1)

        // While running, trigger multiple manual refreshes
        scheduler.refresh(.gitlab)
        scheduler.refresh(.gitlab)
        scheduler.refresh(.gitlab)

        try refreshExpect(
            scheduler.moduleState(for: .gitlab)?.pendingRerun == true,
            "pendingRerun should be set"
        )

        // Release first run
        executor.release(module: .gitlab)
        await waitForRunCount({ executor.runCount[.gitlab] ?? 0 }, count: 2)

        // The rerun should be running now
        try refreshExpect(
            scheduler.moduleState(for: .gitlab)?.phase == .running,
            "rerun should be running"
        )
        try refreshExpect(
            scheduler.moduleState(for: .gitlab)?.pendingRerun == false,
            "pendingRerun should be cleared"
        )

        // Release the rerun
        executor.release(module: .gitlab)
        await waitForPhase(scheduler, module: .gitlab, phase: .idle)

        // Should have exactly 2 runs: initial + one rerun
        try refreshExpect(
            executor.runCount[.gitlab] == 2,
            "expected exactly 2 runs (initial + one rerun), got \(executor.runCount[.gitlab] ?? 0)"
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
        scheduler2.enableModule(.github)
        timers.fireFirst() // trigger initial refresh

        // Wait for the first run to complete (fails immediately)
        await waitForRunCount({ errorExecutor.runCount[.github] ?? 0 }, count: 1)

        // Should be in backoff with retry count 1
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.phase == .backoff,
            "should be in backoff after first failure"
        )
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.backoffRetryCount == 1,
            "retry count should be 1"
        )

        // Backoff delay should be 30 (base * 2^0 = 30, no jitter)
        try refreshExpect(
            timers.lastDelay == 30,
            "first backoff should be 30 seconds, got \(timers.lastDelay ?? -1)"
        )

        // Fire backoff timer -> second retry
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.github] ?? 0 }, count: 2)
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.backoffRetryCount == 2,
            "retry count should be 2"
        )
        try refreshExpect(
            timers.lastDelay == 60,
            "second backoff should be 60 seconds, got \(timers.lastDelay ?? -1)"
        )

        // Fire backoff timer -> third retry
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.github] ?? 0 }, count: 3)
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.backoffRetryCount == 3,
            "retry count should be 3"
        )

        // Fire backoff timer -> exceeds max retries (3)
        timers.fireFirst()
        await waitForRunCount({ errorExecutor.runCount[.github] ?? 0 }, count: 4)
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.phase == .idle,
            "should be idle after max retries exceeded"
        )
        try refreshExpect(
            scheduler2.moduleState(for: .github)?.backoffRetryCount == 0,
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
        scheduler.enableModule(.github)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.moduleState(for: .github)?.phase == .authRequired,
            "should be authRequired after auth error"
        )

        // No backoff timer should be scheduled
        try refreshExpect(
            timers.pendingCount == 0,
            "no backoff timer should be scheduled for auth errors"
        )

        // Auto-refresh should not trigger (fire any remaining timers)
        try refreshExpect(
            executor.runCount[.github] == 1,
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
        scheduler.enableModule(.github)

        // Disable the module
        scheduler.disableModule(.github)

        try refreshExpect(
            scheduler.moduleState(for: .github)?.phase == .disabled,
            "module should be disabled"
        )
        try refreshExpect(
            timers.pendingCount == 0,
            "no timers should be scheduled for disabled module"
        )

        // Manual refresh on disabled module should do nothing
        scheduler.refresh(.github)
        try refreshExpect(
            executor.runCount[.github] == nil || executor.runCount[.github] == 0,
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
        scheduler.enableModule(.github)

        // Fire initial refresh and complete it
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        executor.release(module: .github)
        await waitForPhase(scheduler, module: .github, phase: .idle)

        // Advance time past refresh interval (30 min)
        clock.advance(by: 2000)

        // Call wake compensation multiple times
        scheduler.handleWakeOrReactivation()
        scheduler.handleWakeOrReactivation()
        scheduler.handleWakeOrReactivation()

        // Should have started only one refresh (the first call)
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 2)
        try refreshExpect(
            executor.runCount[.github] == 2,
            "wake should trigger at most one compensating refresh"
        )

        // The second and third wake calls should have set pendingRerun (merged)
        // since the module is running
        try refreshExpect(
            scheduler.moduleState(for: .github)?.pendingRerun == true,
            "repeated wake should merge into pendingRerun"
        )

        // Release the compensating refresh
        executor.release(module: .github)
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 3)
        // The rerun from pendingRerun

        try refreshExpect(
            executor.runCount[.github] == 3,
            "pendingRerun should trigger one additional run"
        )

        executor.release(module: .github)
        await waitForPhase(scheduler, module: .github, phase: .idle)
    }

    // 10.5: Partial result publishes artifact
    private static func partialResultPublishesArtifact(
        repository: URL
    ) async throws {
        let artifact = try loadFixture(repository: repository, module: .github)
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
        scheduler.enableModule(.github)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .github, phase: .idle)

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
        let artifact = try loadFixture(repository: repository, module: .github)
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
        scheduler.enableModule(.github)
        timers.fireFirst()

        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        await waitForPhase(scheduler, module: .github, phase: .idle)

        try refreshExpect(
            received == updates,
            "credentialUpdates 必须原样转发, got \(received)"
        )
    }

    // 10.1: Capacity limit queues request
    private static func capacityLimitQueuesRequest(
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
        scheduler.enableModule(.github)
        scheduler.enableModule(.gitlab)
        scheduler.enableModule(.agentUsage)

        // Fire all three timers
        timers.fireAll()

        // Only 2 should start (capacity limit)
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        await waitForRunCount({ executor.runCount[.gitlab] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.runningModuleCount == 2,
            "should have 2 running modules (capacity limit)"
        )

        // The third module should have pendingRerun set
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.pendingRerun == true,
            "third module should be queued"
        )

        // Complete one module
        executor.release(module: .github)
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .running,
            "third module should start after capacity freed"
        )

        // Cleanup
        executor.release(module: .gitlab)
        executor.release(module: .agentUsage)
    }

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
        scheduler.enableModule(.github)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)

        try refreshExpect(
            scheduler.moduleState(for: .github)?.phase == .running,
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
        scheduler.enableModule(.github)
        timers.fireFirst()
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 1)
        executor.release(module: .github)
        await waitForPhase(scheduler, module: .github, phase: .idle)

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
        await waitForRunCount({ executor.runCount[.github] ?? 0 }, count: 2)
        executor.release(module: .github)
        await waitForPhase(scheduler, module: .github, phase: .idle)

        // 延长间隔到 3600s, 距上次成功 100s -> 重排 delay 为 3500s
        clock.advance(by: 100)
        scheduler.updateRefreshInterval(3600)
        try refreshExpect(
            timers.lastDelay == 3500,
            "lengthened interval should reschedule with remaining delay, got \(timers.lastDelay ?? -1)"
        )
        try refreshExpect(timers.pendingCount == 1, "expected one rescheduled timer")
    }
}

// MARK: - Custom executors for specific test scenarios

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
                )]
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
                diagnostics: []
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}
