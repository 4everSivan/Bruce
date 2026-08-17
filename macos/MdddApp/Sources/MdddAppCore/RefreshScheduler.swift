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

    /// 单个订阅 Provider 的定向刷新状态回调. 定向刷新 (`refreshSubscription`)
    /// 触发 `.started`, 完成后按本轮结果发 `.finished`/`.failed`/`.cancelled`.
    /// 全量刷新不触发此回调 (只走模块级 `onStatusChange`).
    package var onSubscriptionRefreshState: ((SubscriptionProviderID, SubscriptionRefreshState) -> Void)?

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
        // started 表示已初始化过一次; stopped 表示当前处于停止态.
        // 取消退出后再次 start 必须恢复 stopped 标志, 否则所有刷新
        // (含手动) 会被 triggerRefresh 的 guard !stopped 永久拒绝.
        if started && !stopped { return }
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
        // 自愈: 若调度器处于停止态 (退出流程被触发但应用未退出,
        // 或取消退出后未恢复), 手动刷新先恢复调度再触发.
        if stopped {
            start()
        }
        triggerRefresh(for: module, intent: .manual())
    }

    /// 定向刷新单个订阅 Provider: 进入显式 scope, 与其他定时/手动刷新
    /// 遵守同样的容量、pending 合并与取消规则; 任一全量意图优先于定向集合.
    /// 目标 Provider 刷新状态经 `onSubscriptionRefreshState` 单独回调,
    /// 与设置页凭证操作 busy 状态 (`busySubscriptionProviders`) 解耦.
    package func refreshSubscription(_ provider: SubscriptionProviderID) {
        guard let state = states[.agentUsage], state.enabled else { return }
        if stopped {
            start()
        }
        triggerRefresh(for: .agentUsage, intent: .subscription(provider))
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

        // 定向刷新: 目标 Provider 进入 started (按钮 loading/disabled).
        if intent.scope.isTargeted {
            for provider in intent.scope.targetProviders {
                onSubscriptionRefreshState?(provider, .started)
            }
        }

        runningTasks[module] = Task { [weak self] in
            await self?.executeRefresh(for: module, intent: intent)
        }
    }

    // MARK: - Internal: execution

    /// 定向重试所需的 token manager 访问器; App 装配, 测试可注入.
    /// Codex challenge 处理只经它读取记录、刷新令牌与持久化重新授权状态.
    package var codexTokenManager: (any CodexChallengeHandling)?

    /// 一次刷新 = Pipeline 一次调用; 本方法只组装请求并映射结果到 phase/timer.
    /// 无内联 recovery / finalizer / publish (S2 / Task 6).
    private func executeRefresh(
        for module: CollectorModule,
        intent: RefreshIntent
    ) async {
        let pipeline = RefreshExecutionPipeline(
            executor: executor,
            store: store,
            runInputProvider: runInputProvider,
            credentialUpdates: credentialUpdateCoordinator,
            codexTokenManager: codexTokenManager,
            isStopped: { [weak self] in self?.stopped ?? true },
            // publish 用实时 clock; request.now 仅服务 load-previous 入口快照.
            now: { [clock] in clock.now() }
        )
        let result = await pipeline.run(RefreshPipelineRequest(
            module: module,
            intent: intent,
            scope: intent.scope,
            staleAfter: configuration.staleAfter,
            now: clock.now()
        ))
        // 定向刷新: 在模块级结果映射之外, 单独向目标 Provider 发状态回调.
        emitSubscriptionState(for: intent.scope, result: result)
        apply(result, for: module)
        // 取消路径不触发 onRunCycleCompleted (与迁出前一致).
        if case .cancelled = result {
            return
        }
        onRunCycleCompleted?()
    }

    /// 定向刷新: 对 scope 内每个目标 Provider 发状态回调.
    /// - `.started` 在 `startRefresh` (running 相位) 已发; 此处映射收尾状态.
    /// - cancelled → `.cancelled`; 运行输入/Collector 失败 → `.failed`;
    ///   completed (含 partial) → `.finished`. 全量刷新不触发.
    private func emitSubscriptionState(
        for scope: RefreshScope,
        result: RefreshPipelineResult
    ) {
        guard scope.isTargeted else { return }
        let providers = scope.targetProviders
        let state: SubscriptionRefreshState
        switch result {
        case .cancelled:
            state = .cancelled
        case .runInputFailed, .collectorFailed, .publishFailed:
            state = .failed
        case .completed:
            state = .finished
        }
        for provider in providers {
            onSubscriptionRefreshState?(provider, state)
        }
    }

    /// 将 Pipeline 结果映射到 phase / 状态回调 / timer / 额度预警 / pending 排空.
    /// 不重复 apply 凭证或 publish (已在 Pipeline 落地).
    private func apply(_ result: RefreshPipelineResult, for module: CollectorModule) {
        switch result {
        case .cancelled:
            handleCancellation(for: module)

        case .runInputFailed(let error):
            handleRunInputFailure(error, for: module)

        case .collectorFailed(let error):
            applyCollectorFailure(error, for: module)

        case .publishFailed:
            applyStorageFailure(for: module)

        case .completed(let run):
            applyCompleted(run, for: module)
        }
    }

    /// 运行输入获取失败: 不启动进程.
    /// 授权缺失进入 authRequired 等待用户处理; 依赖缺失走标准 backoff.
    /// 注意: 与 completed 路径不同, 此处一律丢弃 pendingIntent (不 drain 重跑).
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

    /// Collector 进程/执行失败 (无 bridge 响应).
    private func applyCollectorFailure(_ error: Error, for module: CollectorModule) {
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard var state = states[module] else { return }
        let now = clock.now()
        var shouldScheduleNext = false

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

        finishCycle(
            state: state,
            module: module,
            shouldScheduleNext: shouldScheduleNext
        )
    }

    /// store.publish 失败 (凭证可能已在 Pipeline 写回).
    private func applyStorageFailure(for module: CollectorModule) {
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard var state = states[module] else { return }
        let now = clock.now()
        let (newState, scheduleNext) = handleBackoff(
            state: state, module: module, now: now, category: .storage
        )
        state = newState
        finishCycle(
            state: state,
            module: module,
            shouldScheduleNext: scheduleNext
        )
    }

    /// Pipeline 已完成 credential apply / 可选 publish / quota 候选计算.
    /// 此处只做 phase 映射, 状态回调与额度预警决策.
    private func applyCompleted(_ run: CompletedRun, for module: CollectorModule) {
        guard !stopped else {
            handleCancellation(for: module)
            return
        }
        guard var state = states[module] else { return }
        let now = clock.now()
        var shouldScheduleNext = false
        let response = run.output.response

        if let artifact = run.publishedArtifact {
            // Pipeline 已 publish; 同步成功态与可观察诊断.
            if module == .agentUsage {
                lastPublishedDiagnostics = response.diagnostics
            }
            state.lastSuccessAt = now
            state.backoffRetryCount = 0
            state.lastErrorCategory = nil
            state.phase = .idle
            onArtifactChange?(module, artifact)

            // 额度预警: 阈值状态每次都同步 (回落后再次跨越会重新报警),
            // 但只有非 manual 且窗口新跨越 80% 才弹通知.
            // includesManual 来自本轮 intent (与 lastTriggerWasManual 一致).
            let entries = run.quotaAlertEntries
            let newAlerts = run.includesManual
                ? []
                : entries.filter { !state.quotaAlertedKeys.contains($0.key) }
            state.quotaAlertedKeys = Set(entries.map(\.key))
            if !newAlerts.isEmpty {
                onQuotaAlerts?(module, newAlerts.map(\.alert))
            }

            if response.status == .partial {
                let detail = response.diagnostics.first?.message
                onStatusChange?(module, .partial, detail)
            } else {
                onStatusChange?(module, .fresh, nil)
            }
            shouldScheduleNext = true
        } else {
            // 未 publish: auth / bridge error / 无 artifact (schema)
            let hasAuthError = response.diagnostics.contains {
                $0.category == "auth"
            }
            // 任务 9: auth diagnostic 只在拿不到 artifact 时整模块 authRequired.
            // 部分结果 (artifact 存在) 已在 Pipeline 发布路径处理.
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
                // 无 artifact 且非 error → schema backoff (凭证可能已写回)
                let (newState, scheduleNext) = handleBackoff(
                    state: state, module: module, now: now, category: .schema
                )
                state = newState
                shouldScheduleNext = scheduleNext
            }
        }

        finishCycle(
            state: state,
            module: module,
            shouldScheduleNext: shouldScheduleNext
        )
    }

    /// 周期收尾: idle 时 drain 同模块 pendingIntent; 否则丢弃 pending;
    /// 再按需排程与启动容量队列.
    private func finishCycle(
        state: ModuleScheduleState,
        module: CollectorModule,
        shouldScheduleNext: Bool
    ) {
        var state = state

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
                includesManual: includesManual,
                scope: .all
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
