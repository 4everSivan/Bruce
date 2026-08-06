import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - Intent / pipeline / core lifecycle

extension RefreshSchedulerHarness {
    // MARK: - RefreshIntent merge (pure unit tests)

    static func intentMergeManualWinsOverTimer() throws {
        let existing = RefreshIntent(reason: .timer, includesManual: false)
        let incoming = RefreshIntent(reason: .manual, includesManual: true)
        let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
        try refreshExpect(merged.reason == .manual, "manual reason")
        try refreshExpect(merged.includesManual, "includesManual")
    }

    static func intentMergeTimerIntoManualKeepsManual() throws {
        let existing = RefreshIntent(reason: .manual, includesManual: true)
        let incoming = RefreshIntent(reason: .timer, includesManual: false)
        let merged = RefreshIntentMerge.merge(existing: existing, incoming: incoming)
        try refreshExpect(merged.reason == .manual, "stay manual")
        try refreshExpect(merged.includesManual, "stay includesManual")
    }

    static func intentMergeNilExistingUsesIncoming() throws {
        let incoming = RefreshIntent(reason: .wake, includesManual: false)
        let merged = RefreshIntentMerge.merge(existing: nil, incoming: incoming)
        try refreshExpect(merged == incoming, "nil existing")
    }

    /// Manual coalesce while running + non-manual merge after: drained run keeps
    /// includesManual and must not fire quota alerts; run count +1 only.
    static func manualCoalescedRerunSuppressesQuotaAlerts(
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

    // MARK: - RefreshExecutionPipeline (Task 6)

    /// Stopped pipeline short-circuits to `.cancelled` without collector side effects.
    static func pipelineReturnsCancelledWhenStopped(
        repository: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(rootURL: root)
        let executor = MockCollectorExecutor()
        executor.repository = repository
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            store: store,
            runInputProvider: nil,
            credentialUpdates: nil,
            codexTokenManager: nil,
            isStopped: { true }
        )
        let request = RefreshPipelineRequest(
            module: .agentUsage,
            intent: .timer(),
            staleAfter: 3600,
            now: Date(timeIntervalSince1970: 1_786_000_000)
        )
        let result = await pipeline.run(request)
        guard case .cancelled = result else {
            throw RefreshTestFailure.expectation(
                "stopped pipeline must return .cancelled, got \(result)"
            )
        }
        try refreshExpect(
            executor.runCount[.agentUsage] == nil || executor.runCount[.agentUsage] == 0,
            "stopped pipeline must not invoke collector"
        )
    }

    /// Live pipeline: one collect + publish; includesManual preserved on CompletedRun.
    static func pipelineCompletesAndPublishesWhenNotStopped(
        repository: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(rootURL: root)
        let executor = MockCollectorExecutor()
        executor.repository = repository
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            store: store,
            runInputProvider: nil,
            credentialUpdates: nil,
            codexTokenManager: nil,
            isStopped: { false }
        )
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let request = RefreshPipelineRequest(
            module: .agentUsage,
            intent: .manual(),
            staleAfter: 3600,
            now: now
        )
        let result = await pipeline.run(request)
        guard case .completed(let run) = result else {
            throw RefreshTestFailure.expectation(
                "live pipeline must return .completed, got \(result)"
            )
        }
        try refreshExpect(
            executor.runCount[.agentUsage] == 1,
            "pipeline first collect must run once, got \(executor.runCount[.agentUsage] ?? 0)"
        )
        try refreshExpect(
            run.includesManual,
            "CompletedRun must preserve request intent.includesManual"
        )
        try refreshExpect(
            run.publishedArtifact != nil,
            "fixture success path must publish artifact"
        )
        try refreshExpect(
            run.output.response.status == .success,
            "fixture path status should remain success"
        )
        // Store must hold the published artifact (publish once).
        guard let published = run.publishedArtifact else {
            throw RefreshTestFailure.expectation("expected publishedArtifact")
        }
        let loaded = try store.load(
            .agentUsage,
            now: now,
            staleAfter: 3600
        )
        try refreshExpect(
            loaded.artifact == published,
            "loaded store artifact must match pipeline publishedArtifact"
        )
    }

    /// store.publish attemptedAt must use publish-time clock, not request.now
    /// captured at executeRefresh entry (collect/recovery duration must not freeze metadata).
    static func pipelinePublishUsesEndOfRunClock(
        repository: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try ArtifactStore(rootURL: root)
        let executor = MockCollectorExecutor()
        executor.repository = repository
        let entryNow = Date(timeIntervalSince1970: 1_786_000_000)
        let publishNow = entryNow.addingTimeInterval(120)
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            store: store,
            runInputProvider: nil,
            credentialUpdates: nil,
            codexTokenManager: nil,
            isStopped: { false },
            now: { publishNow }
        )
        let request = RefreshPipelineRequest(
            module: .agentUsage,
            intent: .timer(),
            staleAfter: 3600,
            now: entryNow
        )
        let result = await pipeline.run(request)
        guard case .completed(let run) = result else {
            throw RefreshTestFailure.expectation(
                "publish-clock pipeline must return .completed, got \(result)"
            )
        }
        try refreshExpect(
            run.publishedArtifact != nil,
            "publish-clock path must publish artifact"
        )
        let loaded = try store.load(
            .agentUsage,
            now: publishNow,
            staleAfter: 3600
        )
        let expected = ISO8601DateFormatter().string(from: publishNow)
        let frozen = ISO8601DateFormatter().string(from: entryNow)
        try refreshExpect(
            loaded.metadata.lastSuccessAt == expected,
            "store lastSuccessAt must be publish-time \(expected), got \(loaded.metadata.lastSuccessAt ?? "nil")"
        )
        try refreshExpect(
            loaded.metadata.lastAttemptAt == expected,
            "store lastAttemptAt must be publish-time \(expected), got \(loaded.metadata.lastAttemptAt ?? "nil")"
        )
        try refreshExpect(
            loaded.metadata.lastSuccessAt != frozen,
            "store lastSuccessAt must not freeze at request.now entry time \(frozen)"
        )
    }

    // 10.1: Timer fires -> module refreshes
    static func timerFiresTriggersRefresh(
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
    static func manualRefreshWhileRunningMergesToRerun(
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
    static func failureBackoffRetriesExponentially(
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
    static func authErrorStopsRetrying(
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
    static func moduleDisabledStopsAutoRefresh(
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
    static func wakeCompensationAtMostOnce(
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
    static func partialResultPublishesArtifact(
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
    static func credentialPersistFailureDemotesToPartial(
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
    static func stopCancelsRunningTasks(
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

    // 回归: 调度器 stop 后 (退出流程被触发但应用未退出), 手动刷新
    // 必须自愈恢复调度, 否则刷新按钮点击无效.
    static func manualRefreshAfterStopRecoversScheduler(
        repository: URL
    ) async throws {
        let executor = MockCollectorExecutor()
        executor.blocksUntilReleased = false
        let clock = ManualClock()
        let timers = FakeTimerScheduler()
        let (scheduler, _, root) = try makeScheduler(
            repository: repository, executor: executor, clock: clock, timers: timers
        )
        defer { try? FileManager.default.removeItem(at: root) }

        scheduler.start()
        scheduler.enableModule(.agentUsage)

        // 模拟退出流程: stop 后调度器进入停止态
        scheduler.stop()
        try refreshExpect(scheduler.isStopped, "scheduler should be stopped after stop()")

        // 手动刷新应自愈: 恢复 started 状态并触发一次刷新
        scheduler.refresh(.agentUsage)
        try refreshExpect(!scheduler.isStopped, "manual refresh should recover from stopped")
        await waitForRunCount({ executor.runCount[.agentUsage] ?? 0 }, count: 1)
        try refreshExpect(
            scheduler.moduleState(for: .agentUsage)?.phase == .idle,
            "module should return to idle after recovered refresh"
        )
    }

    // 配置变更后新间隔立即生效: 缩短时按重启计时立即补刷,
    // 延长时按新间隔重排 idle 模块计时器.
    static func updateRefreshIntervalReschedulesIdleModule(
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

}
