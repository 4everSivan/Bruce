import AppKit
import MdddOnboardingCore
import Foundation

// MARK: - RefreshClock

@MainActor
package protocol RefreshClock: AnyObject {
    func now() -> Date
}

@MainActor
final class SystemRefreshClock: RefreshClock {
    func now() -> Date { Date() }
}

// MARK: - CollectorExecuting

@MainActor
protocol CollectorExecuting: AnyObject {
    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput
    func cancel(module: CollectorModule)
    func cancelAll()
}

extension CollectorRunner: CollectorExecuting {}

// MARK: - Scheduler configuration

struct SchedulerConfiguration: Sendable {
    var refreshInterval: TimeInterval
    let staleAfter: TimeInterval
    let maxBackoffRetries: Int
    let baseBackoffSeconds: Double
    let maxBackoffSeconds: Double
    let rateLimitBackoffSeconds: Double
    let capacityLimit: Int

    static let `default` = SchedulerConfiguration(
        refreshInterval: 1800,
        staleAfter: 3600,
        maxBackoffRetries: 5,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2
    )
}

// MARK: - Module schedule state

struct ModuleScheduleState: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case disabled
        case idle
        case running
        case backoff
        case authRequired
    }

    var enabled: Bool = false
    var autoRefreshEnabled: Bool = true
    var phase: Phase = .disabled
    var lastSuccessAt: Date? = nil
    var lastAttemptAt: Date? = nil
    var backoffRetryCount: Int = 0
    var pendingIntent: RefreshIntent? = nil
    var lastErrorCategory: SnapshotErrorCategory? = nil
    /// 本轮刷新是否由手动触发; 手动刷新不弹额度预警.
    var lastTriggerWasManual: Bool = false
    /// 上次刷新后已超预警阈值的 5h 窗口 key 集合; 只有新跨越的窗口才报警.
    var quotaAlertedKeys: Set<String> = []
}

// MARK: - RefreshScheduler

@MainActor
package final class RefreshScheduler {
    private let executor: CollectorExecuting
    private let store: ArtifactStore
    private let clock: RefreshClock
    private let timerScheduler: RunnerTimerScheduling
    private var configuration: SchedulerConfiguration
    private let jitterProvider: (Double) -> Double
    private let registerWakeNotifications: Bool
    /// 可选运行输入提供器; nil 时保持空 context/credentials 的旧行为.
    private var runInputProvider: (any CollectorRunInputProviding)?
    /// 可选凭证写回协调器; nil 时跳过 credentialUpdates 应用 (测试/无凭证场景).
    private let credentialUpdateCoordinator: CredentialUpdateCoordinator?

    private var states: [CollectorModule: ModuleScheduleState] = [:]
    private var timers: [CollectorModule: RunnerTimerToken] = [:]
    private var runningTasks: [CollectorModule: Task<Void, Never>] = [:]
    private var started = false
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?
    private var reactivationObserver: NSObjectProtocol?

    package var onStatusChange: ((CollectorModule, ModuleRunState, String?) -> Void)?
    package var onArtifactChange: ((CollectorModule, JSONValue?) -> Void)?
    /// 后台刷新发现 5h 窗口用量新跨越 80% 阈值; 手动刷新不触发.
    package var onQuotaAlerts: ((CollectorModule, [QuotaAlert]) -> Void)?
    /// 每个运行周期完成 (无论成败) 后触发, 供宿主刷新非敏感状态.
    package var onRunCycleCompleted: (() -> Void)?
    /// 最近一次成功发布的响应诊断 (去重后, 任务 7): 供诊断展示/记录
    /// 边界读取; 合并期诊断 (merger) 与首轮/重试诊断统一经过 finalizer 去重.
    /// 含 credential 写回失败时追加的 CREDENTIAL_PERSIST_FAILED (无令牌明文).
    package private(set) var lastPublishedDiagnostics: [BridgeDiagnostic] = []

    package convenience init(
        executor: CollectorRunner,
        store: ArtifactStore,
        runInputProvider: OnboardingRunInputProvider? = nil,
        credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil
    ) {
        self.init(
            executor: executor,
            store: store,
            clock: SystemRefreshClock(),
            timerScheduler: DispatchRunnerTimerScheduler(),
            configuration: .default,
            jitterProvider: { capped in
                capped * Double.random(in: 0...0.1)
            },
            registerWakeNotifications: true,
            runInputProvider: runInputProvider,
            credentialUpdateCoordinator: credentialUpdateCoordinator
        )
    }

    init(
        executor: CollectorExecuting,
        store: ArtifactStore,
        clock: RefreshClock = SystemRefreshClock(),
        timerScheduler: RunnerTimerScheduling = DispatchRunnerTimerScheduler(),
        configuration: SchedulerConfiguration = .default,
        jitterProvider: @escaping (Double) -> Double = { capped in
            capped * Double.random(in: 0...0.1)
        },
        registerWakeNotifications: Bool = true,
        runInputProvider: (any CollectorRunInputProviding)? = nil,
        credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil
    ) {
        self.executor = executor
        self.store = store
        self.clock = clock
        self.timerScheduler = timerScheduler
        self.configuration = configuration
        self.jitterProvider = jitterProvider
        self.registerWakeNotifications = registerWakeNotifications
        self.runInputProvider = runInputProvider
        self.credentialUpdateCoordinator = credentialUpdateCoordinator

        for module in CollectorModule.allCases {
            states[module] = ModuleScheduleState()
        }
    }

    /// 清理可再生快照缓存 (设置页数据管理入口); 下次刷新自动重建,
    /// 内存中的面板数据不受影响.
    package func clearSnapshotCaches() throws {
        try store.clearSnapshotCaches()
    }

    // MARK: - Lifecycle

    package func start() {
        guard !started else { return }
        started = true
        stopped = false

        for module in CollectorModule.allCases {
            loadCachedSnapshot(for: module)
        }

        guard registerWakeNotifications else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWakeOrReactivation() }
        }
        reactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWakeOrReactivation() }
        }
    }

    package func stop() {
        stopped = true
        for (_, timer) in timers { timer.cancel() }
        timers.removeAll()
        executor.cancelAll()

        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        if let observer = reactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            reactivationObserver = nil
        }
    }

    // MARK: - Module control

    package func enableModule(_ module: CollectorModule) {
        guard var state = states[module] else { return }
        state.enabled = true
        if state.phase == .disabled { state.phase = .idle }
        states[module] = state

        if started && !stopped && state.autoRefreshEnabled {
            scheduleNextRefresh(for: module)
        }
        updateStatus(for: module)
    }

    package func disableModule(_ module: CollectorModule) {
        guard var state = states[module] else { return }
        state.enabled = false
        state.phase = .disabled
        state.pendingIntent = nil
        states[module] = state
        timers[module]?.cancel()
        timers[module] = nil
        updateStatus(for: module)
    }

    package func setAutoRefresh(_ enabled: Bool, for module: CollectorModule) {
        guard var state = states[module] else { return }
        state.autoRefreshEnabled = enabled
        states[module] = state
        if enabled && state.enabled && state.phase == .idle {
            scheduleNextRefresh(for: module)
        } else if !enabled {
            timers[module]?.cancel()
            timers[module] = nil
        }
    }

    /// 更新自动刷新间隔 (用户配置变更后调用).
    /// 沿用 setAutoRefresh 的更新模式: 按新间隔重排已启用 idle 模块的
    /// 计时器 (重启计时); 距上次成功已超过新间隔的模块 delay 为 0,
    /// 立即触发一次刷新.
    package func updateRefreshInterval(_ interval: TimeInterval) {
        configuration.refreshInterval = interval
        for module in CollectorModule.allCases {
            guard let state = states[module],
                  state.enabled, state.autoRefreshEnabled,
                  state.phase == .idle else { continue }
            scheduleNextRefresh(for: module)
        }
    }

    // MARK: - Manual refresh

    package func refresh(_ module: CollectorModule) {
        guard let state = states[module], state.enabled else { return }
        triggerRefresh(for: module, intent: .manual())
    }

    // MARK: - Sleep / wake

    package func handleWakeOrReactivation() {
        let now = clock.now()
        for (module, state) in states {
            guard state.enabled, state.autoRefreshEnabled else { continue }
            guard state.phase != .authRequired else { continue }

            let isStale: Bool
            if let lastSuccess = state.lastSuccessAt {
                isStale = now.timeIntervalSince(lastSuccess) >= configuration.refreshInterval
            } else {
                isStale = true
            }
            if isStale { triggerRefresh(for: module, intent: .wake()) }
        }
    }

    // MARK: - Internal: cached snapshot loading

    private func loadCachedSnapshot(for module: CollectorModule) {
        do {
            let stored = try store.load(
                module,
                now: clock.now(),
                staleAfter: configuration.staleAfter
            )
            onArtifactChange?(module, stored.artifact)
            let runState: ModuleRunState = stored.metadata.isStale ? .stale : .fresh
            onStatusChange?(module, runState, nil)

            if var state = states[module] {
                state.lastSuccessAt = stored.metadata.lastSuccessAt
                    .flatMap { ISO8601DateFormatter().date(from: $0) }
                // 用缓存快照回填预警阈值状态, 重启后不对已超的窗口重复报警
                state.quotaAlertedKeys = Set(
                    QuotaAlertEvaluator.overThresholdEntries(artifact: stored.artifact)
                        .map(\.key)
                )
                states[module] = state
            }
        } catch {
            // No cached snapshot — OK
        }
    }

    // MARK: - Internal: scheduling

    private func scheduleNextRefresh(for module: CollectorModule) {
        guard let state = states[module],
              state.enabled, state.autoRefreshEnabled,
              state.phase == .idle else { return }

        timers[module]?.cancel()

        let delay: TimeInterval
        if let lastSuccess = state.lastSuccessAt {
            let elapsed = clock.now().timeIntervalSince(lastSuccess)
            delay = max(0, configuration.refreshInterval - elapsed)
        } else {
            delay = 0
        }

        timers[module] = timerScheduler.schedule(after: delay) { [weak self] in
            self?.triggerRefresh(for: module, intent: .timer())
        }
    }

    // MARK: - Internal: trigger

    private func triggerRefresh(for module: CollectorModule, intent: RefreshIntent) {
        guard !stopped else { return }
        guard let state = states[module], state.enabled else { return }
        let isManual = intent.reason == .manual || intent.includesManual

        if state.phase == .running {
            // Intent-aware coalesce: merge preserves includesManual across sources.
            states[module]?.pendingIntent = RefreshIntentMerge.merge(
                existing: state.pendingIntent,
                incoming: intent
            )
            return
        }

        if state.phase == .authRequired && !isManual { return }

        if state.phase == .backoff {
            timers[module]?.cancel()
            timers[module] = nil
        }

        let runningCount = states.values.filter { $0.phase == .running }.count
        if runningCount >= configuration.capacityLimit {
            // Capacity queue also merges so a later timer cannot drop manual.
            states[module]?.pendingIntent = RefreshIntentMerge.merge(
                existing: state.pendingIntent,
                incoming: intent
            )
            return
        }

        startRefresh(for: module, intent: intent)
    }

    private func startRefresh(for module: CollectorModule, intent: RefreshIntent) {
        guard var state = states[module], state.enabled else { return }
        state.phase = .running
        state.lastAttemptAt = clock.now()
        state.lastTriggerWasManual = intent.includesManual
        state.pendingIntent = nil
        states[module] = state

        timers[module]?.cancel()
        timers[module] = nil

        onStatusChange?(module, .refreshing, nil)

        runningTasks[module] = Task { [weak self] in
            await self?.executeRefresh(for: module)
        }
    }

    // MARK: - Internal: execution

    /// 定向重试所需的 token manager 访问器; App 装配, 测试可注入.
    /// Codex challenge 处理只经它读取记录、刷新令牌与持久化重新授权状态.
    package var codexTokenManager: (any CodexChallengeHandling)?

    // CodexRetryPhaseResult 和 CodexChallenge 已移至 CodexQuotaRecovery.swift (阶段 B).


    private func executeRefresh(for module: CollectorModule) async {
        // 启动进程前取受控输入; 取不到时不启动进程, 按分类进入
        // authRequired 或 backoff, 避免空 context/空凭证运行 Collector.
        var context: [String: JSONValue] = [:]
        var credentials: [String: JSONValue] = [:]
        if let runInputProvider {
            do {
                let input = try await runInputProvider.runInput(for: module)
                context = input.context
                credentials = input.credentials
            } catch let inputError as CollectorRunInputError {
                handleRunInputFailure(inputError, for: module)
                onRunCycleCompleted?()
                return
            } catch {
                // 凭证存储读取等未知错误按依赖缺失走 backoff
                handleRunInputFailure(
                    .missingDependency(module: module, reason: "读取运行输入失败"),
                    for: module
                )
                onRunCycleCompleted?()
                return
            }
        }

        // 任务 5: 刷新开始时读取并保存 previousArtifact (同一轮内不得二次
        // 读取已被覆盖的 artifact).
        let previousArtifact: JSONValue?
        do {
            previousArtifact = try store.load(
                module,
                now: clock.now(),
                staleAfter: configuration.staleAfter
            ).artifact
        } catch {
            previousArtifact = nil
        }

        let result = await runCollector(
            module: module,
            context: context,
            credentials: credentials
        )
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard case .success(let output) = result else {
            // 首轮 Collector 自身失败且无 artifact: 不发布半成品, previous 保持
            handleResult(result, for: module)
            onRunCycleCompleted?()
            return
        }

        // Codex 定向重试: 首次响应携带 accessRejected challenge 时,
        // 全量处理本轮合法 challenge, 最多执行一轮 retry-only Collector.
        // 任务 5: 无论 challenge/决议/retry 结果如何, first artifact 存在时
        // 都从唯一 finalizer 四源合并后发布一次.
        // 阶段 B: 恢复逻辑已移至 CodexQuotaRecovery.
        if module == .agentUsage {
            let recovery = CodexQuotaRecovery()
            let retryPhase = await recovery.handle(
                firstOutput: output,
                firstCredentials: credentials,
                module: module,
                runInputProvider: runInputProvider,
                challengeHandler: codexTokenManager,
                isStopped: { [weak self] in self?.stopped ?? true },
                runCollector: { [weak self] module, context, credentials in
                    await self?.runCollector(
                        module: module,
                        context: context,
                        credentials: credentials
                    ) ?? .failure(CancellationError())
                }
            )
            guard !stopped else {
                handleCancellation(for: module)
                return
            }
            let finalOutput = ArtifactFinalizer().finalize(
                firstOutput: output,
                retryPhase: retryPhase,
                previousArtifact: previousArtifact,
                fallbackDecisions: runInputProvider?.codexTokenDecisions ?? []
            )
            handleResult(.success(finalOutput), for: module)
            onRunCycleCompleted?()
            return
        }

        handleResult(.success(output), for: module)
        onRunCycleCompleted?()
    }

    private func runCollector(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async -> Result<CollectorRunOutput, Error> {
        do {
            let output = try await executor.run(
                module: module,
                context: context,
                credentials: credentials
            )
            return .success(output)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(error)
        }
    }

    /// 运行输入获取失败: 不启动进程.
    /// 授权缺失进入 authRequired 等待用户处理; 依赖缺失走标准 backoff.
    private func handleRunInputFailure(
        _ error: CollectorRunInputError,
        for module: CollectorModule
    ) {
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard var state = states[module] else { return }
        let now = clock.now()
        var shouldScheduleNext = false

        switch error {
        case .missingAuthorization(_, let reason):
            state.phase = .authRequired
            state.lastErrorCategory = .auth
            onStatusChange?(module, .authRequired, reason)
        case .missingDependency:
            let (newState, scheduleNext) = handleBackoff(
                state: state, module: module, now: now, category: .dependency
            )
            state = newState
            shouldScheduleNext = scheduleNext
        }

        state.pendingIntent = nil
        states[module] = state
        runningTasks[module] = nil

        if shouldScheduleNext && state.autoRefreshEnabled && !stopped {
            scheduleNextRefresh(for: module)
        }
        startQueuedModulesIfCapacityAvailable()
    }

    private func handleResult(
        _ result: Result<CollectorRunOutput, Error>,
        for module: CollectorModule
    ) {
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard var state = states[module] else { return }
        let now = clock.now()
        var shouldScheduleNext = false

        switch result {
        case .success(let output):
            let response = output.response
            let hasAuthError = response.diagnostics.contains {
                $0.category == "auth"
            }

            // 任务 9: auth diagnostic 只在拿不到 artifact 时整模块 authRequired.
            // 部分结果 (artifact 存在) 按部分成功处理: 保留并发布可用数据,
            // Codex 账号级认证状态只影响该账号 (见 handleCodexChallenge).
            if hasAuthError && response.artifact == nil {
                state.phase = .authRequired
                state.lastErrorCategory = .auth
                onStatusChange?(module, .authRequired, "请前往设置重新登录")
            } else if response.status == .error {
                let category = RefreshErrorClassifier().classifyBridgeError(response)
                if category == .auth {
                    state.phase = .authRequired
                    state.lastErrorCategory = .auth
                    onStatusChange?(module, .authRequired, "请前往设置重新登录")
                } else {
                    let (newState, scheduleNext) = handleBackoff(
                        state: state, module: module, now: now, category: category
                    )
                    state = newState
                    shouldScheduleNext = scheduleNext
                }
            } else {
                // 轮换令牌先于 artifact 发布写回, 即使本次发布失败也不丢失新令牌.
                // 写回失败进入可观察诊断, 并在有 artifact 时将 success 降级为 partial.
                var publishedDiagnostics = response.diagnostics
                var effectiveStatus = response.status
                if !response.credentialUpdates.isEmpty {
                    let applyResult = credentialUpdateCoordinator?.apply(
                        credentialUpdates: response.credentialUpdates
                    ) ?? CredentialUpdateApplyResult()
                    if !applyResult.failed.isEmpty {
                        for failure in applyResult.failed {
                            publishedDiagnostics.append(BridgeDiagnostic(
                                code: "CREDENTIAL_PERSIST_FAILED",
                                category: "storage",
                                stage: "credentialUpdate",
                                message: "\(failure.provider) 凭证写回失败",
                                retryable: true
                            ))
                        }
                        if effectiveStatus == .success, response.artifact != nil {
                            effectiveStatus = .partial
                        }
                    }
                }
                if let artifact = response.artifact {
                    do {
                        try store.publish(artifact, for: module, attemptedAt: now)
                        // 任务 7: 成功发布的响应诊断进入可观察边界
                        // (finalizer 已按 code|stage|message 去重).
                        if module == .agentUsage {
                            lastPublishedDiagnostics = publishedDiagnostics
                        }
                        state.lastSuccessAt = now
                        state.backoffRetryCount = 0
                        state.lastErrorCategory = nil
                        state.phase = .idle
                        onArtifactChange?(module, artifact)

                        // 额度预警: 阈值状态每次都同步 (回落后再次跨越会重新报警),
                        // 但只有后台刷新且窗口新跨越 80% 才弹通知.
                        let entries = QuotaAlertEvaluator.overThresholdEntries(
                            artifact: artifact
                        )
                        let newAlerts = state.lastTriggerWasManual
                            ? []
                            : entries.filter { !state.quotaAlertedKeys.contains($0.key) }
                        state.quotaAlertedKeys = Set(entries.map(\.key))
                        if !newAlerts.isEmpty {
                            onQuotaAlerts?(module, newAlerts.map(\.alert))
                        }

                        if effectiveStatus == .partial {
                            let detail = publishedDiagnostics.first?.message
                            onStatusChange?(module, .partial, detail)
                        } else {
                            onStatusChange?(module, .fresh, nil)
                        }
                        shouldScheduleNext = true
                    } catch {
                        let (newState, scheduleNext) = handleBackoff(
                            state: state, module: module, now: now, category: .storage
                        )
                        state = newState
                        shouldScheduleNext = scheduleNext
                    }
                } else {
                    let (newState, scheduleNext) = handleBackoff(
                        state: state, module: module, now: now, category: .schema
                    )
                    state = newState
                    shouldScheduleNext = scheduleNext
                }
            }

        case .failure(let error):
            let (category, isAuth) = RefreshErrorClassifier().classifyRunnerError(error)
            if isAuth {
                state.phase = .authRequired
                state.lastErrorCategory = .auth
                onStatusChange?(module, .authRequired, "请前往设置重新登录")
            } else {
                let (newState, scheduleNext) = handleBackoff(
                    state: state, module: module, now: now, category: category
                )
                state = newState
                shouldScheduleNext = scheduleNext
            }
        }

        // Drain same-module pending with the stored intent (manual-preserving merge).
        if let pending = state.pendingIntent, state.phase == .idle {
            state.pendingIntent = nil
            states[module] = state
            runningTasks[module] = nil
            if !stopped {
                startRefresh(for: module, intent: pending)
            }
            startQueuedModulesIfCapacityAvailable()
            return
        }

        // Non-idle completion drops any pending that cannot run yet (prior clear).
        if state.pendingIntent != nil {
            state.pendingIntent = nil
        }

        states[module] = state
        runningTasks[module] = nil

        if shouldScheduleNext && state.autoRefreshEnabled && !stopped {
            scheduleNextRefresh(for: module)
        }
        startQueuedModulesIfCapacityAvailable()
    }

    private func handleCancellation(for module: CollectorModule) {
        guard var state = states[module] else { return }
        state.phase = state.lastSuccessAt != nil ? .idle : .disabled
        state.pendingIntent = nil
        states[module] = state
        runningTasks[module] = nil

        let hasCache = state.lastSuccessAt != nil
        onStatusChange?(
            module,
            hasCache ? .stale : .notConfigured,
            nil
        )
        startQueuedModulesIfCapacityAvailable()
    }

    /// 某个模块释放并发槽位后启动等待中的模块. pendingIntent 同时承载
    /// 同模块合并请求和跨模块容量排队, 这里只消费 idle 模块.
    private func startQueuedModulesIfCapacityAvailable() {
        guard !stopped else { return }
        while states.values.filter({ $0.phase == .running }).count
            < configuration.capacityLimit {
            guard let module = CollectorModule.allCases.first(where: {
                guard let state = states[$0] else { return false }
                return state.enabled
                    && state.phase == .idle
                    && state.pendingIntent != nil
            }) else {
                return
            }
            guard let intent = states[module]?.pendingIntent else { return }
            states[module]?.pendingIntent = nil
            startRefresh(for: module, intent: intent)
        }
    }

    // MARK: - Internal: backoff

    private func handleBackoff(
        state: ModuleScheduleState,
        module: CollectorModule,
        now: Date,
        category: SnapshotErrorCategory
    ) -> (ModuleScheduleState, Bool) {
        var newState = state
        newState.lastErrorCategory = category
        newState.backoffRetryCount += 1

        if newState.backoffRetryCount > configuration.maxBackoffRetries {
            newState.phase = .idle
            newState.backoffRetryCount = 0
            let hasCache = newState.lastSuccessAt != nil
            onStatusChange?(
                module,
                hasCache ? .stale : .failed,
                "刷新失败, 等待下次周期"
            )
            return (newState, true)
        }

        newState.phase = .backoff
        let backoff = RefreshBackoffPolicy(
            configuration: configuration,
            jitterProvider: jitterProvider
        ).computeBackoff(
            retryCount: newState.backoffRetryCount,
            category: category
        )
        let hasCache = newState.lastSuccessAt != nil
        onStatusChange?(
            module,
            hasCache ? .stale : .failed,
            "刷新失败, \(Int(backoff)) 秒后重试"
        )

        timers[module]?.cancel()
        timers[module] = timerScheduler.schedule(after: backoff) { [weak self] in
            guard let self else { return }
            // Preserve prior lastTriggerWasManual across automatic backoff retries.
            let includesManual = self.states[module]?.lastTriggerWasManual ?? false
            let intent = RefreshIntent(
                reason: includesManual ? .manual : .timer,
                includesManual: includesManual
            )
            self.startRefresh(for: module, intent: intent)
        }
        return (newState, false)
    }

    // MARK: - Internal: status

    private func updateStatus(for module: CollectorModule) {
        guard let state = states[module] else { return }
        let runState: ModuleRunState
        let detail: String?

        switch state.phase {
        case .disabled:
            runState = .notConfigured
            detail = nil
        case .idle:
            if let lastSuccess = state.lastSuccessAt {
                let age = clock.now().timeIntervalSince(lastSuccess)
                runState = age > configuration.staleAfter ? .stale : .fresh
            } else {
                runState = .ready
            }
            detail = nil
        case .running:
            runState = .refreshing
            detail = nil
        case .backoff:
            runState = state.lastSuccessAt != nil ? .stale : .failed
            detail = "刷新失败, 等待重试"
        case .authRequired:
            runState = .authRequired
            detail = "请前往设置重新登录"
        }

        onStatusChange?(module, runState, detail)
    }

    // MARK: - Testing helpers

    func moduleState(for module: CollectorModule) -> ModuleScheduleState? {
        states[module]
    }

    /// 测试专用: 替换运行输入提供器 (默认 nil 的旧行为).
    func setRunInputProviderForTesting(
        _ provider: (any CollectorRunInputProviding)?
    ) {
        runInputProvider = provider
    }

    var isStopped: Bool { stopped }
}
