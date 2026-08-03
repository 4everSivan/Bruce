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
    private var runInputProvider: (any CollectorRunInputProviding)?

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
    /// 每个运行周期完成 (无论成败) 后触发, 供宿主刷新非敏感状态.
    package var onRunCycleCompleted: (() -> Void)?
    /// 最近一次成功发布的响应诊断 (去重后, 任务 7): 供诊断展示/记录
    /// 边界读取; 合并期诊断 (merger) 与首轮/重试诊断统一经过 finalizer 去重.
    package private(set) var lastPublishedDiagnostics: [BridgeDiagnostic] = []

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

    /// 定向重试所需的 token manager 访问器; App 装配, 测试可注入.
    /// Codex challenge 处理只经它读取记录、刷新令牌与持久化重新授权状态.
    package var codexTokenManager: (any CodexChallengeHandling)?

    /// 本轮 Codex 挑战处理阶段的结果 (任务 5): 三类数据显式表达,
    /// 不用异常或提前 return 隐式表达.
    private struct CodexRetryPhaseResult {
        let retryArtifact: JSONValue?
        let tokenDecisions: [CodexTokenDecision]
        let diagnostics: [BridgeDiagnostic]
    }

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
        if module == .agentUsage {
            let retryPhase = await handleCodexChallenges(
                module: module,
                firstOutput: output,
                firstCredentials: credentials
            )
            guard !stopped else {
                handleCancellation(for: module)
                return
            }
            let finalOutput = finalizeAgentUsage(
                firstOutput: output,
                retryPhase: retryPhase,
                previousArtifact: previousArtifact
            )
            handleResult(.success(finalOutput), for: module)
            onRunCycleCompleted?()
            return
        }

        handleResult(.success(output), for: module)
        onRunCycleCompleted?()
    }

    /// 任务 5 唯一 finalizer: previous + first + retry + decisions 四源合并,
    /// 合并 first/retry/merger 诊断并去重, 生成最终 artifact.
    /// 调用方只发布该输出一次.
    private func finalizeAgentUsage(
        firstOutput: CollectorRunOutput,
        retryPhase: CodexRetryPhaseResult,
        previousArtifact: JSONValue?
    ) -> CollectorRunOutput {
        guard let firstArtifact = firstOutput.response.artifact else {
            // 首轮无 artifact (异常响应): 维持原响应, 不发布半成品
            return firstOutput
        }
        let decisions = retryPhase.tokenDecisions.isEmpty
            ? (runInputProvider?.codexTokenDecisions ?? [])
            : retryPhase.tokenDecisions
        let merged = CodexQuotaSnapshotMerger().merge(
            previous: previousArtifact,
            first: firstArtifact,
            retry: retryPhase.retryArtifact,
            decisions: decisions
        )
        // 合并 first/retry/token 与 merger 诊断, 按稳定 key 去重
        var collected: [BridgeDiagnostic] = []
        var seen = Set<String>()
        func appendDiagnostics(_ diagnostics: [BridgeDiagnostic]) {
            for diagnostic in diagnostics {
                let key = "\(diagnostic.code)|\(diagnostic.stage)|\(diagnostic.message)"
                if seen.insert(key).inserted {
                    collected.append(diagnostic)
                }
            }
        }
        // 首轮与重试诊断: 仅当最终 artifact 有失败条目时保留 (自愈成功不残留)
        if merged.artifact.hasFailedEntries {
            appendDiagnostics(firstOutput.response.diagnostics)
            appendDiagnostics(retryPhase.diagnostics)
        }
        for diagnostic in merged.diagnostics {
            appendDiagnostics([BridgeDiagnostic(
                code: diagnostic.code,
                category: diagnostic.category,
                stage: diagnostic.stage,
                message: diagnostic.message,
                retryable: diagnostic.retryable
            )])
        }
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: firstOutput.response.runId,
                generatedAt: merged.generatedAtValue
                    ?? firstOutput.response.generatedAt,
                status: merged.recomputedStatus,
                artifact: merged.artifact,
                credentialUpdates: firstOutput.response.credentialUpdates,
                diagnostics: collected,
                credentialChallenges: []
            ),
            stderrDiagnostic: firstOutput.stderrDiagnostic
        )
    }

    /// 多账号定向重试 (任务 8 + 任务 5): 全量处理本轮合法 accessRejected
    /// challenge, 返回 CodexRetryPhaseResult. 每轮最多执行一轮 retry-only
    /// Collector, 单账号 OAuth 调用不重复. 任何失败分支都返回空 retry phase
    /// 并携带诊断, 由唯一 finalizer 四源合并 (任务 5).
    private func handleCodexChallenges(
        module: CollectorModule,
        firstOutput: CollectorRunOutput,
        firstCredentials: [String: JSONValue]
    ) async -> CodexRetryPhaseResult {
        let empty = CodexRetryPhaseResult(
            retryArtifact: nil,
            tokenDecisions: [],
            diagnostics: []
        )
        guard !stopped else { return empty }
        guard !firstOutput.response.credentialChallenges.isEmpty else {
            return empty
        }

        // 本轮已注入账号: 只接受属于注入账号的 challenge.
        let injectedAccounts: Set<String>
        if case .object(let codexAccounts)? = firstCredentials["codexQuotaAccounts"] {
            injectedAccounts = Set(codexAccounts.keys)
        } else {
            injectedAccounts = []
        }
        let challenges = firstOutput.response.credentialChallenges
            .compactMap(CodexChallenge.init(json:))
        let accountedChallenges = challenges
            .filter { injectedAccounts.contains($0.accountID) }
        guard !accountedChallenges.isEmpty else {
            // 非法/不属于本轮的 challenge: 不重试, 空 retry phase
            return empty
        }

        // 按账号去重并排序 (本轮 index 顺序; 未出现在决议中的账号按
        // accountID 排序, 保证确定性).
        let orderedAccounts = Self.orderedChallengeAccounts(
            accountedChallenges,
            decisions: runInputProvider?.codexTokenDecisions ?? []
        )
        guard !orderedAccounts.isEmpty, let runInputProvider else {
            return empty
        }

        // 最多 4 账号并行 refreshAfterAccessRejected (OAuth 调用不重复).
        var refreshedAccounts: [String] = []
        let challengeHandler = codexTokenManager
        if let challengeHandler {
            let chunks = stride(
                from: 0,
                to: orderedAccounts.count,
                by: CodexTokenBatchResolver.maxConcurrency
            ).map {
                Array(orderedAccounts[$0..<min($0 + CodexTokenBatchResolver.maxConcurrency, orderedAccounts.count)])
            }
            for chunk in chunks {
                let results = await withTaskGroup(
                    of: (String, TokenResolution).self
                ) { group in
                    for accountID in chunk {
                        group.addTask {
                            let resolution = await challengeHandler
                                .refreshAfterAccessRejected(
                                    for: accountID, now: nil
                                )
                            return (accountID, resolution)
                        }
                    }
                    var collected: [(String, TokenResolution)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }
                for (accountID, resolution) in results {
                    if case .success = resolution {
                        refreshedAccounts.append(accountID)
                    }
                }
            }
        }
        guard !stopped else { return empty }
        var diagnostics: [BridgeDiagnostic] = []
        guard !refreshedAccounts.isEmpty else {
            // 全部刷新失败: 保留 decisions 与诊断, retryArtifact=nil
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_REFRESH_FAILED",
                category: "collector",
                stage: "challenge",
                message: "全部账号令牌刷新失败, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }

        let retryInput: CollectorRunInput?
        do {
            retryInput = try await runInputProvider.retryInput(
                for: module,
                accountIDs: refreshedAccounts
            )
        } catch {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_INPUT_FAILED",
                category: "collector",
                stage: "challenge",
                message: "重试输入组装失败, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        guard let retryInput else {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_INPUT_MISSING",
                category: "collector",
                stage: "challenge",
                message: "重试输入为空, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        let retryResult = await runCollector(
            module: module,
            context: retryInput.context,
            credentials: retryInput.credentials
        )
        guard !stopped else { return empty }
        guard case .success(let retryOutput) = retryResult else {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_COLLECTOR_FAILED",
                category: "collector",
                stage: "retry",
                message: "定向重试采集失败",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        let decisions = runInputProvider.codexTokenDecisions
        let retryArtifact = retryOutput.response.artifact

        // 重试仍 401 (freshness=unavailable + failureKind=auth) 的账号
        // 持久化为 needsReauthorization (任务 8, 只影响对应账号).
        if let challengeHandler, let retryArtifact {
            let services: [JSONValue] = {
                guard case .object(let object) = retryArtifact else {
                    return []
                }
                return object["services"]?.arrayValue ?? []
            }()
            let refreshedSet = Set(refreshedAccounts)
            for service in services {
                guard let account = retryAccountID(
                    service: service,
                    decisions: decisions
                ),
                    refreshedSet.contains(account),
                    isAuthFailure(service: service) else {
                    continue
                }
                await challengeHandler.markNeedsReauthorization(
                    for: account,
                    now: nil
                )
            }
        }
        // 任务 7 (UI-05): 重试输出自身的诊断也进入最终合并 (finalizer 去重),
        // 与首轮/merger 诊断统一呈现, 不单独丢弃.
        return CodexRetryPhaseResult(
            retryArtifact: retryArtifact,
            tokenDecisions: decisions,
            diagnostics: retryOutput.response.diagnostics
        )
    }

    /// challenge 账号去重并按本轮决议 index 排序; 决议中不存在的账号
    /// 按 accountID 字典序排尾 (确定性强).
    private static func orderedChallengeAccounts(
        _ challenges: [CodexChallenge],
        decisions: [CodexTokenDecision]
    ) -> [String] {
        var indexByAccount: [String: Int] = [:]
        for decision in decisions {
            if indexByAccount[decision.accountID] == nil {
                indexByAccount[decision.accountID] = decision.index
            }
        }
        let unique = Array(Set(challenges.map(\.accountID)))
        return unique.sorted {
            let left = indexByAccount[$0] ?? Int.max
            let right = indexByAccount[$1] ?? Int.max
            if left != right { return left < right }
            return $0 < $1
        }
    }

    /// 从合并后 service 反查账号: 优先按 currentID 匹配决议,
    /// 失败时按 legacy ID 唯一匹配 (与合并器同规则).
    private func retryAccountID(
        service: JSONValue,
        decisions: [CodexTokenDecision]
    ) -> String? {
        guard case .object(let object) = service,
              case .string(let id)? = object["id"] else {
            return nil
        }
        for decision in decisions where decision.serviceID == id {
            return decision.accountID
        }
        var matched: String?
        for decision in decisions {
            if CodexAccountIdentity.legacyServiceID(for: decision.accountID) == id {
                if matched != nil { return nil }
                matched = decision.accountID
            }
        }
        return matched
    }

    /// 该 service 是否仍为授权失败 (unavailable + auth, 或 legacy 无
    /// freshness 的 error + auth note). 403/429/网络等不视为授权失效.
    private func isAuthFailure(service: JSONValue) -> Bool {
        guard case .object(let object) = service,
              case .string(let status)? = object["status"],
              status == "error" else {
            return false
        }
        if case .string(let failureKind)? = object["failureKind"] {
            return failureKind == "auth"
        }
        // 旧 artifact 无 failureKind: 按 note 文案判断
        if case .string(let note)? = object["note"] {
            return note.contains("登录态已失效")
        }
        return false
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

    /// Codex challenge 协议字段解析 (provider=codex, reason=accessRejected).
    private struct CodexChallenge: Equatable {
        let accountID: String

        init?(json: JSONValue) {
            guard case .object(let object) = json,
                  case .string(let provider)? = object["provider"],
                  provider == "codex",
                  case .string(let reason)? = object["reason"],
                  reason == "accessRejected",
                  case .string(let accountID)? = object["accountId"],
                  !accountID.isEmpty else {
                return nil
            }
            self.accountID = accountID
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

            // 任务 9: auth diagnostic 只在拿不到 artifact 时整模块 authRequired.
            // 部分结果 (artifact 存在) 按部分成功处理: 保留并发布可用数据,
            // Codex 账号级认证状态只影响该账号 (见 handleCodexChallenge).
            if hasAuthError && response.artifact == nil {
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
                        // 任务 7: 成功发布的响应诊断进入可观察边界
                        // (finalizer 已按 code|stage|message 去重).
                        if module == .agentUsage {
                            lastPublishedDiagnostics = response.diagnostics
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

    /// 测试专用: 替换运行输入提供器 (默认 nil 的旧行为).
    func setRunInputProviderForTesting(
        _ provider: (any CollectorRunInputProviding)?
    ) {
        runInputProvider = provider
    }

    var runningModuleCount: Int {
        states.values.filter { $0.phase == .running }.count
    }

    var isStopped: Bool { stopped }
}
