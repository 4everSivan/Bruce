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
    var pendingRerun: Bool = false
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
    private let runInputProvider: (any CollectorRunInputProviding)?

    private var states: [CollectorModule: ModuleScheduleState] = [:]
    private var timers: [CollectorModule: RunnerTimerToken] = [:]
    private var runningTasks: [CollectorModule: Task<Void, Never>] = [:]
    private var started = false
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?
    private var reactivationObserver: NSObjectProtocol?

    package var onStatusChange: ((CollectorModule, ModuleRunState, String?) -> Void)?
    package var onArtifactChange: ((CollectorModule, JSONValue?) -> Void)?
    /// Collector 轮换令牌候选 (仅 App 模式非空); 由宿主写回 Keychain.
    package var onCredentialUpdates: ((CollectorModule, [JSONValue]) -> Void)?
    /// 后台刷新发现 5h 窗口用量新跨越 80% 阈值; 手动刷新不触发.
    package var onQuotaAlerts: ((CollectorModule, [QuotaAlert]) -> Void)?

    package convenience init(
        executor: CollectorRunner,
        store: ArtifactStore,
        runInputProvider: OnboardingRunInputProvider? = nil
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
            runInputProvider: runInputProvider
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
        runInputProvider: (any CollectorRunInputProviding)? = nil
    ) {
        self.executor = executor
        self.store = store
        self.clock = clock
        self.timerScheduler = timerScheduler
        self.configuration = configuration
        self.jitterProvider = jitterProvider
        self.registerWakeNotifications = registerWakeNotifications
        self.runInputProvider = runInputProvider

        for module in CollectorModule.allCases {
            states[module] = ModuleScheduleState()
        }
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
        state.pendingRerun = false
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
        triggerRefresh(for: module, isManual: true)
    }

    package func refreshAll() {
        for module in CollectorModule.allCases { refresh(module) }
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
            if isStale { triggerRefresh(for: module, isManual: false) }
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
            self?.triggerRefresh(for: module, isManual: false)
        }
    }

    // MARK: - Internal: trigger

    private func triggerRefresh(for module: CollectorModule, isManual: Bool) {
        guard !stopped else { return }
        guard let state = states[module], state.enabled else { return }

        if state.phase == .running {
            if isManual || !state.pendingRerun {
                states[module]?.pendingRerun = true
            }
            return
        }

        if state.phase == .authRequired && !isManual { return }

        if state.phase == .backoff {
            timers[module]?.cancel()
            timers[module] = nil
        }

        let runningCount = states.values.filter { $0.phase == .running }.count
        if runningCount >= configuration.capacityLimit {
            states[module]?.pendingRerun = true
            return
        }

        states[module]?.lastTriggerWasManual = isManual
        startRefresh(for: module)
    }

    private func startRefresh(for module: CollectorModule) {
        guard var state = states[module], state.enabled else { return }
        state.phase = .running
        state.lastAttemptAt = clock.now()
        states[module] = state

        timers[module]?.cancel()
        timers[module] = nil

        onStatusChange?(module, .refreshing, nil)

        runningTasks[module] = Task { [weak self] in
            await self?.executeRefresh(for: module)
        }
    }

    // MARK: - Internal: execution

    private func executeRefresh(for module: CollectorModule) async {
        // 启动进程前取受控输入; 取不到时不启动进程, 按分类进入
        // authRequired 或 backoff, 避免空 context/空凭证运行 Collector.
        var context: [String: JSONValue] = [:]
        var credentials: [String: JSONValue] = [:]
        if let runInputProvider {
            do {
                let input = try runInputProvider.runInput(for: module)
                context = input.context
                credentials = input.credentials
            } catch let inputError as CollectorRunInputError {
                handleRunInputFailure(inputError, for: module)
                return
            } catch {
                // 凭证存储读取等未知错误按依赖缺失走 backoff
                handleRunInputFailure(
                    .missingDependency(module: module, reason: "读取运行输入失败"),
                    for: module
                )
                return
            }
        }

        let result: Result<CollectorRunOutput, Error>
        do {
            let output = try await executor.run(
                module: module,
                context: context,
                credentials: credentials
            )
            result = .success(output)
        } catch is CancellationError {
            handleCancellation(for: module)
            return
        } catch {
            result = .failure(error)
        }

        guard !stopped else {
            handleCancellation(for: module)
            return
        }

        handleResult(result, for: module)
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

        state.pendingRerun = false
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
        var shouldRerun = false

        switch result {
        case .success(let output):
            let response = output.response
            let hasAuthError = response.diagnostics.contains {
                $0.category == "auth"
            }

            if hasAuthError {
                state.phase = .authRequired
                state.lastErrorCategory = .auth
                onStatusChange?(module, .authRequired, "请前往设置重新登录")
            } else if response.status == .error {
                let category = classifyBridgeError(response)
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
                if !response.credentialUpdates.isEmpty {
                    onCredentialUpdates?(module, response.credentialUpdates)
                }
                if let artifact = response.artifact {
                    do {
                        try store.publish(artifact, for: module, attemptedAt: now)
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

                        if response.status == .partial {
                            let detail = response.diagnostics.first?.message
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
            let (category, isAuth) = classifyRunnerError(error)
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

        if state.pendingRerun {
            state.pendingRerun = false
            if state.phase == .idle { shouldRerun = true }
        }

        states[module] = state
        runningTasks[module] = nil

        if shouldRerun && !stopped {
            triggerRefresh(for: module, isManual: true)
        } else if shouldScheduleNext && state.autoRefreshEnabled && !stopped {
            scheduleNextRefresh(for: module)
        }
        startQueuedModulesIfCapacityAvailable()
    }

    private func handleCancellation(for module: CollectorModule) {
        guard var state = states[module] else { return }
        state.phase = state.lastSuccessAt != nil ? .idle : .disabled
        state.pendingRerun = false
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

    /// 某个模块释放并发槽位后启动等待中的模块. pendingRerun 同时承载
    /// 同模块合并请求和跨模块容量排队, 这里只消费 idle 模块.
    private func startQueuedModulesIfCapacityAvailable() {
        guard !stopped else { return }
        while states.values.filter({ $0.phase == .running }).count
            < configuration.capacityLimit {
            guard let module = CollectorModule.allCases.first(where: {
                guard let state = states[$0] else { return false }
                return state.enabled
                    && state.phase == .idle
                    && state.pendingRerun
            }) else {
                return
            }
            states[module]?.pendingRerun = false
            startRefresh(for: module)
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
        let backoff = computeBackoff(
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
            self?.startRefresh(for: module)
        }
        return (newState, false)
    }

    private func computeBackoff(
        retryCount: Int,
        category: SnapshotErrorCategory?
    ) -> Double {
        if category == .rateLimit {
            return configuration.rateLimitBackoffSeconds
        }

        let exponential = configuration.baseBackoffSeconds
            * pow(2.0, Double(retryCount - 1))
        let capped = min(exponential, configuration.maxBackoffSeconds)
        let jitter = jitterProvider(capped)
        return min(capped + jitter, configuration.maxBackoffSeconds)
    }

    // MARK: - Internal: error classification

    private func classifyRunnerError(_ error: Error) -> (SnapshotErrorCategory, Bool) {
        guard let runnerError = error as? CollectorRunnerError else {
            return (.collector, false)
        }
        switch runnerError {
        case .timedOut: return (.collector, false)
        case .processFailed: return (.collector, false)
        case .invalidEnvelope: return (.schema, false)
        case .launchFailed: return (.dependency, false)
        case .pythonNotExecutable: return (.dependency, false)
        case .bridgeNotReadable: return (.dependency, false)
        case .alreadyRunning: return (.collector, false)
        case .capacityExceeded: return (.collector, false)
        case .invalidExecutablePath: return (.dependency, false)
        case .unsupportedSchema: return (.schema, false)
        case .runIdMismatch: return (.schema, false)
        }
    }

    private func classifyBridgeError(_ response: BridgeResponse) -> SnapshotErrorCategory {
        for diagnostic in response.diagnostics {
            switch diagnostic.category {
            case "auth": return .auth
            case "network": return .network
            case "rateLimit": return .rateLimit
            case "schema": return .schema
            case "collector": return .collector
            case "dependency": return .dependency
            case "storage": return .storage
            case "cancelled": return .cancelled
            case "protocol", "security", "internal": return .schema
            default: break
            }
        }
        return .collector
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

    var runningModuleCount: Int {
        states.values.filter { $0.phase == .running }.count
    }

    var isStopped: Bool { stopped }
}
