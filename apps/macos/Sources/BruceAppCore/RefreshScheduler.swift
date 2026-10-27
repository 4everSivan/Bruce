import AppKit
import BruceOnboardingCore
import Foundation
import os

// MARK: - RefreshClock

@MainActor
package protocol RefreshClock: AnyObject {
    func now() -> Date
}

@MainActor
final class SystemRefreshClock: RefreshClock {
    func now() -> Date { Date() }
}

// MARK: - Scheduler configuration

struct SchedulerConfiguration: Sendable {
    var refreshInterval: TimeInterval
    let staleAfter: TimeInterval
    let maxBackoffRetries: Int
    let baseBackoffSeconds: Double
    let maxBackoffSeconds: Double
    let rateLimitBackoffSeconds: Double
    let capacityLimit: Int
    /// 自动订阅额度查询周期; 与 refreshInterval 联动 (C065).
    var quotaRefreshInterval: TimeInterval
    /// wake/activation 在距上次尝试该秒数内不重复触发 (消除启动双跑).
    let wakeDedupSeconds: TimeInterval

    static let `default` = SchedulerConfiguration(
        refreshInterval: 1800,
        staleAfter: 3600,
        maxBackoffRetries: 5,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2,
        quotaRefreshInterval: 1800,
        wakeDedupSeconds: 60
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
    /// 断网期间自动刷新被抑制; 联网后据此补偿一次刷新.
    var offlinePaused: Bool = false
    /// 本轮刷新是否由手动触发; 手动刷新不弹额度预警.
    var lastTriggerWasManual: Bool = false
    /// 上次刷新后已超预警阈值的 5h 窗口 key 集合; 只有新跨越的窗口才报警.
    var quotaAlertedKeys: Set<String> = []
}

// MARK: - RefreshScheduler

@MainActor
package final class RefreshScheduler {
    private let executor: CollectorExecuting
    /// 额度门禁与回填 (T15): 经共享 collector-policy 计算, 默认取 executor 的策略子命令.
    private let quotaPolicy: any QuotaPolicyComputing
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
    /// 可选网络可达性监视器; nil 时保持旧行为 (始终视为在线).
    private let networkReachability: (any NetworkReachabilityProviding)?
    /// 可选屏幕锁定监视器 (C064); nil 时保持旧行为 (始终视为未锁屏).
    private let screenLockState: (any ScreenLockStateProviding)?
    /// 电脑锁屏后是否禁止订阅刷新 (C064), 与 OnboardingConfiguration 同步.
    package private(set) var pauseSubscriptionRefreshOnScreenLock: Bool = true

    private var states: [CollectorModule: ModuleScheduleState] = [:]
    private var timers: [CollectorModule: RunnerTimerToken] = [:]
    private var runningTasks: [CollectorModule: Task<Void, Never>] = [:]
    private var started = false
    private var stopped = false
    /// C037: 最近一次成功发布的 artifact 中的额度窗口重置时刻 (epoch 秒) 与已消费集合.
    /// 定时唤醒据此提前到窗口边界, 避免槽/窗口边界过后长时间展示上一窗口的数据.
    private var windowBoundaries: [Int64] = []
    private var consumedWindowBoundaries: Set<Int64> = []
    private var wakeObserver: NSObjectProtocol?
    private var reactivationObserver: NSObjectProtocol?
    private let logger = Logger(
        subsystem: "io.bruce.dashboard",
        category: "refresh-scheduler"
    )

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
        executor: CollectorExecutable,
        store: ArtifactStore,
        runInputProvider: OnboardingRunInputProvider? = nil,
        credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil,
        networkReachability: (any NetworkReachabilityProviding)? = nil,
        screenLockState: (any ScreenLockStateProviding)? = nil
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
            credentialUpdateCoordinator: credentialUpdateCoordinator,
            networkReachability: networkReachability,
            screenLockState: screenLockState
        )
    }

    init(
        executor: CollectorExecutable,
        store: ArtifactStore,
        clock: RefreshClock = SystemRefreshClock(),
        timerScheduler: RunnerTimerScheduling = DispatchRunnerTimerScheduler(),
        configuration: SchedulerConfiguration = .default,
        jitterProvider: @escaping (Double) -> Double = { capped in
            capped * Double.random(in: 0...0.1)
        },
        registerWakeNotifications: Bool = true,
        runInputProvider: (any CollectorRunInputProviding)? = nil,
        credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil,
        networkReachability: (any NetworkReachabilityProviding)? = nil,
        screenLockState: (any ScreenLockStateProviding)? = nil,
        quotaPolicy: (any QuotaPolicyComputing)? = nil
    ) {
        self.executor = executor
        if let quotaPolicy {
            self.quotaPolicy = quotaPolicy
        } else if let transport = executor as? CollectorPolicyRunning {
            self.quotaPolicy = CollectorQuotaPolicy { input in
                try await transport.runPolicy(input)
            }
        } else {
            // 无策略入口: 每轮在门禁处失败并按采集失败退避 (design/08 §4.2 降级语义).
            self.quotaPolicy = CollectorQuotaPolicy.unavailable()
        }
        self.store = store
        self.clock = clock
        self.timerScheduler = timerScheduler
        self.configuration = configuration
        self.jitterProvider = jitterProvider
        self.registerWakeNotifications = registerWakeNotifications
        self.runInputProvider = runInputProvider
        self.credentialUpdateCoordinator = credentialUpdateCoordinator
        self.networkReachability = networkReachability
        self.screenLockState = screenLockState

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

        // 断网闸门: 先接通网络监视, 再加载缓存/排程, 保证启动后的
        // 首个定时触发 (delay=0) 也能拿到首轮可达性状态.
        if let networkReachability {
            networkReachability.onReachabilityChange = { [weak self] isAvailable in
                self?.handleNetworkReachabilityChange(isAvailable)
            }
            networkReachability.start()
        }

        // 锁屏闸门 (C064): 接通屏幕锁定监视
        if let screenLockState {
            screenLockState.onScreenLockStateChange = { [weak self] isLocked in
                self?.handleScreenLockStateChange(isLocked)
            }
            screenLockState.start()
        }

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

        networkReachability?.onReachabilityChange = nil
        networkReachability?.stop()

        screenLockState?.onScreenLockStateChange = nil
        screenLockState?.stop()

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
    /// 同时联动更新订阅额度查询周期 quotaRefreshInterval (C065).
    package func updateRefreshInterval(_ interval: TimeInterval) {
        configuration.refreshInterval = interval
        configuration.quotaRefreshInterval = interval
        for module in CollectorModule.allCases {
            guard let state = states[module],
                  state.enabled, state.autoRefreshEnabled,
                  state.phase == .idle else { continue }
            scheduleNextRefresh(for: module)
        }
    }

    /// 当前自动刷新间隔 (秒).
    package var refreshInterval: TimeInterval {
        configuration.refreshInterval
    }

    /// 当前订阅额度刷新周期 (秒) (C065).
    package var quotaRefreshInterval: TimeInterval {
        configuration.quotaRefreshInterval
    }

    /// 当前屏幕是否处于锁定状态 (C064).
    package var isScreenLocked: Bool {
        screenLockState?.isScreenLocked ?? false
    }

    /// 更新锁屏暂停订阅刷新偏好 (C064).
    package func setPauseSubscriptionRefreshOnScreenLock(_ enabled: Bool) {
        self.pauseSubscriptionRefreshOnScreenLock = enabled
    }

    /// 屏幕锁屏/解锁状态变动回调 (C064).
    private func handleScreenLockStateChange(_ isLocked: Bool) {
        guard pauseSubscriptionRefreshOnScreenLock else { return }
        if !isLocked {
            handleScreenUnlocked()
        }
    }

    /// 屏幕解锁时自动补偿订阅额度刷新 (C064).
    package func handleScreenUnlocked() {
        guard pauseSubscriptionRefreshOnScreenLock else { return }
        guard let state = states[.agentUsage], state.enabled, state.autoRefreshEnabled else { return }
        guard state.phase != .authRequired && state.phase != .running else { return }
        let now = clock.now()
        if let lastAttempt = state.lastAttemptAt,
           now.timeIntervalSince(lastAttempt) < configuration.wakeDedupSeconds {
            return
        }
        triggerRefresh(for: .agentUsage, intent: .wake(forceQuotaRefresh: true))
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
            // C062: 运行中或刚尝试过的不再排队补偿 —— 启动时首轮 run 与
            // didBecomeActive 撞车会在 4 秒内产生第二次全量请求.
            guard state.phase != .running else { continue }
            if let lastAttempt = state.lastAttemptAt,
               now.timeIntervalSince(lastAttempt) < configuration.wakeDedupSeconds {
                continue
            }

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
                    .flatMap { ISODate.parse($0) }
                // 用缓存快照回填预警阈值状态, 重启后不对已超的窗口重复报警
                state.quotaAlertedKeys = Set(
                    QuotaAlertEvaluator.overThresholdEntries(artifact: stored.artifact)
                        .map(\.key)
                )
                states[module] = state
            }
        } catch {
            // No cached snapshot is a normal first-run state. Keep the error
            // observable, however: a valid snapshot that fails validation or
            // storage must not silently look like "no today's usage".
            logger.error(
                "cached snapshot load failed; module=\(module.rawValue, privacy: .public), error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Internal: scheduling

    private func scheduleNextRefresh(for module: CollectorModule) {
        guard let state = states[module],
              state.enabled, state.autoRefreshEnabled,
              state.phase == .idle else { return }

        timers[module]?.cancel()

        var delay: TimeInterval
        if let lastSuccess = state.lastSuccessAt {
            let elapsed = clock.now().timeIntervalSince(lastSuccess)
            delay = max(0, configuration.refreshInterval - elapsed)
        } else {
            delay = 0
        }

        // C037: 定时刷新不得跨过额度窗口边界 —— 否则槽/窗口重置后最长一个间隔内
        // 卡片仍展示上一窗口的百分比。首次调度 (delay=0) 不参与, 策略自带防风暴防线。
        // C064: 锁屏且开启抑制时跳过边界提前唤醒, 避免在锁屏期间为了窗口重置多跑。
        var boundaryTriggered = false
        let shouldSkipBoundaryWake = isScreenLocked && pauseSubscriptionRefreshOnScreenLock
        if delay > 0 && !shouldSkipBoundaryWake {
            let intervalRemaining = delay
            delay = SubscriptionBoundaryWakePolicy.delay(
                intervalRemaining: delay,
                boundaries: windowBoundaries,
                now: clock.now(),
                consumed: &consumedWindowBoundaries
            )
            // 边界唤醒必须强制查询额度, 否则 C062 的 30 分钟门禁会把它降级成本地 run.
            boundaryTriggered = delay < intervalRemaining
        }

        timers[module] = timerScheduler.schedule(after: delay) { [weak self] in
            self?.triggerRefresh(
                for: module,
                intent: .timer(forceQuotaRefresh: boundaryTriggered)
            )
        }
    }

    // MARK: - Internal: trigger

    private func triggerRefresh(for module: CollectorModule, intent: RefreshIntent) {
        guard !stopped else { return }
        guard let state = states[module], state.enabled else { return }
        let isManual = intent.reason == .manual || intent.includesManual

        // 断网闸门: 自动触发 (timer / wake / backoff) 在无网络时不启动 Collector,
        // 也不排任何重试; 手动刷新 (含定向刷新) 仍允许执行一次.
        if !isNetworkAvailable && intent.reason != .manual {
            // 运行中的任务自然会收尾; 自动意图不再排队, 防止离线期间积压补偿.
            guard state.phase != .running else { return }
            pauseForOffline(module: module, state: state)
            return
        }

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
        // 兜底: 容量队列 / pending drain 等绕过 triggerRefresh 的直接启动路径
        // 同样受断网闸门约束, 防止离线期间仍发起自动请求.
        if !isNetworkAvailable && intent.reason != .manual {
            guard state.phase != .running else { return }
            pauseForOffline(module: module, state: state)
            return
        }
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
            quotaPolicy: quotaPolicy,
            store: store,
            runInputProvider: runInputProvider,
            credentialUpdates: credentialUpdateCoordinator,
            codexTokenManager: codexTokenManager,
            isStopped: { [weak self] in self?.stopped ?? true },
            // publish 用实时 clock; request.now 仅服务 load-previous 入口快照.
            now: { [clock] in clock.now() }
        )
        let suppressQuotas = isScreenLocked && pauseSubscriptionRefreshOnScreenLock && intent.reason != .manual
        let result = await pipeline.run(RefreshPipelineRequest(
            module: module,
            intent: intent,
            scope: intent.scope,
            staleAfter: configuration.staleAfter,
            now: clock.now(),
            quotaRefreshInterval: configuration.quotaRefreshInterval,
            suppressSubscriptionRefresh: suppressQuotas
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
            state.offlinePaused = false
            state.phase = .idle
            onArtifactChange?(module, artifact)
            // C037: 记录本轮的额度窗口边界, 供下一次定时唤醒提前到边界 (见 scheduleNextRefresh)。
            windowBoundaries = SubscriptionBoundaryWakePolicy.boundaries(in: artifact)

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

    // MARK: - Internal: network reachability

    private var isNetworkAvailable: Bool {
        networkReachability?.isNetworkAvailable ?? true
    }

    private static let offlineDetail = "网络不可用, 已暂停自动刷新"

    /// 自动刷新被断网闸门拦下: 回到 idle, 打上补偿标记, 不留下任何重试定时器.
    private func pauseForOffline(module: CollectorModule, state: ModuleScheduleState) {
        var paused = state
        paused.phase = .idle
        // 自动意图被拦下时不再保留任何积压 (手动 pending 由运行收尾路径 drain).
        paused.pendingIntent = nil
        paused.offlinePaused = true
        paused.lastErrorCategory = .network
        states[module] = paused
        timers[module]?.cancel()
        timers[module] = nil
        onStatusChange?(
            module,
            state.lastSuccessAt != nil ? .stale : .failed,
            Self.offlineDetail
        )
    }

    /// 网络可达性变化 (主线程回调).
    private func handleNetworkReachabilityChange(_ isAvailable: Bool) {
        guard !stopped else { return }
        if isAvailable {
            resumeAfterReconnect()
        } else {
            pauseBackoffForOffline()
        }
    }

    /// 进入断网: 取消在途的退避重试, 避免恢复后旧定时器与补偿刷新叠加.
    private func pauseBackoffForOffline() {
        for module in CollectorModule.allCases {
            guard var state = states[module], state.enabled else { continue }
            guard state.phase == .backoff else { continue }
            timers[module]?.cancel()
            timers[module] = nil
            state.phase = .idle
            state.pendingIntent = nil
            state.offlinePaused = true
            state.lastErrorCategory = .network
            states[module] = state
            onStatusChange?(
                module,
                state.lastSuccessAt != nil ? .stale : .failed,
                Self.offlineDetail
            )
        }
    }

    /// 恢复联网: 离线期间被抑制或本就陈旧的模块补偿一次刷新;
    /// 数据仍新鲜且无积压的模块只恢复排程, 不额外发请求.
    private func resumeAfterReconnect() {
        let now = clock.now()
        for module in CollectorModule.allCases {
            guard var state = states[module],
                  state.enabled, state.autoRefreshEnabled else { continue }
            guard state.phase == .idle || state.phase == .backoff else { continue }

            let isStale: Bool
            if let lastSuccess = state.lastSuccessAt {
                isStale = now.timeIntervalSince(lastSuccess) >= configuration.refreshInterval
            } else {
                isStale = true
            }

            guard state.offlinePaused || isStale else {
                if timers[module] == nil {
                    scheduleNextRefresh(for: module)
                }
                continue
            }

            state.offlinePaused = false
            states[module] = state
            triggerRefresh(for: module, intent: .wake())
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

        // 断网期间不重试: 不排退避定时器, 等待网络恢复后的单次补偿.
        // 手动刷新同样只执行一次 (离线时请求必然失败, 重试只会放大限流风险).
        if !isNetworkAvailable {
            newState.phase = .idle
            newState.backoffRetryCount = 0
            newState.offlinePaused = true
            newState.lastErrorCategory = .network
            // 保留用户手动点击的 pending; 自动积压意图直接丢弃.
            if newState.pendingIntent?.reason != .manual {
                newState.pendingIntent = nil
            }
            timers[module]?.cancel()
            timers[module] = nil
            onStatusChange?(
                module,
                newState.lastSuccessAt != nil ? .stale : .failed,
                Self.offlineDetail
            )
            return (newState, false)
        }

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
            self.triggerRefresh(
                for: module,
                intent: .backoff(includesManual: includesManual)
            )
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
