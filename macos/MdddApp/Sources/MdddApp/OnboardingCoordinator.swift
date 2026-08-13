import Foundation
import MdddAppCore
import MdddOnboardingCore

/// 协调 Onboarding 扫描, 连接验证, 授权确认和 Scheduler 启用.
/// 本机扫描不产生外部请求; 外部验证只在用户主动操作或授权版本有效时触发.
/// 未确认统一授权时所有模块保持禁用; 授权后由 Gate 决定启用哪些模块.
/// 订阅 CRUD 由 SubscriptionService 承担, 本类保留同签名 thin façade (Settings 零变更).
@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let currentConsentVersion = 1

    /// 用户在授权区选择的模块, 与配置持久化同步.
    @Published var selectedModules: Set<CollectorModule>
    /// 当前是否处于授权版本有效状态.
    @Published private(set) var consentConfirmed: Bool
    /// 自动刷新间隔 (分钟), 与配置持久化同步.
    @Published private(set) var refreshIntervalMinutes: Int
    /// 外观偏好, 与配置持久化同步; 面板和设置窗口据此覆盖 colorScheme.
    @Published private(set) var appearanceMode: AppearancePreference
    /// 界面风格 (经典 / 液态玻璃), 与配置持久化同步; 低系统强制经典.
    @Published private(set) var interfaceStyle: InterfaceStylePreference
    /// 模糊风格偏好, 与配置持久化同步; 仅液态玻璃模式下驱动渲染.
    @Published private(set) var glassStyle: GlassStylePreference
    /// 全局快捷键 (打开/关闭仪表盘), 与配置持久化同步; nil 表示未设置.
    @Published private(set) var dashboardHotkey: GlobalHotkey?
    /// 可注入的能力探测 (测试); 默认读系统.
    var liquidGlassSupported: () -> Bool = { LiquidGlassCapability.isSupported }

    /// 当前解析主题 (界面 + 模糊 + 是否用玻璃 API); 始终按能力回落.
    var resolvedTheme: ResolvedTheme {
        ThemeResolution.resolve(
            interfaceStyle: interfaceStyle,
            glassStyle: glassStyle,
            isSupported: liquidGlassSupported()
        )
    }

    /// 订阅 provider 展示顺序 (转发 SubscriptionService, 保持 Settings 观察入口).
    var subscriptionProviderOrder: [SubscriptionProviderID] {
        subscriptions.subscriptionProviderOrder
    }

    /// Codex 设备码登录展示状态 (转发 SubscriptionService).
    var codexDeviceLogin: DeviceLoginPresentation? {
        subscriptions.codexDeviceLogin
    }

    private let scheduler: RefreshScheduler
    private let model: AppModel
    private let runtime: AppRuntime
    private let configStore: OnboardingConfigurationStore?
    private let scanner: LocalDependencyScanner
    private let homeURL: URL
    private var gate: CollectorActivationGate
    private let subscriptions: SubscriptionService
    private var hotkeyMonitor: GlobalHotkeyMonitor?

    init(
        scheduler: RefreshScheduler,
        model: AppModel,
        runtime: AppRuntime,
        configStore: OnboardingConfigurationStore? = try? OnboardingConfigurationStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        codexStore: CodexCredentialStore? = nil,
        codexTokenManager: CodexTokenManager? = nil,
        scanner: LocalDependencyScanner? = nil,
        verifier: any DeepSeekCredentialVerifier = ProviderConnectionVerifier(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        localProbe: LocalCredentialProbe? = nil,
        consentVersion: Int = OnboardingCoordinator.currentConsentVersion
    ) {
        self.scheduler = scheduler
        self.model = model
        self.runtime = runtime
        self.configStore = configStore
        self.homeURL = homeURL
        let resolvedStore = codexStore
            ?? CodexCredentialStore(store: credentialStore)
        let resolvedTokenManager = codexTokenManager ?? CodexTokenManager(
            store: resolvedStore,
            client: CodexOAuthClient.defaultClient()
        )
        let resolvedProbe = localProbe ?? LocalCredentialProbe(homeURL: homeURL)
        let config = configStore?.load()
        self.scanner = scanner ?? LocalDependencyScanner(
            paths: .standard(home: homeURL)
        )
        let confirmedVersion = config?.consentVersion
        self.gate = CollectorActivationGate(
            consentVersion: consentVersion,
            confirmedConsentVersion: confirmedVersion
        )
        self.selectedModules = Set(
            (config?.selectedModules ?? []).compactMap {
                CollectorModule(rawValue: $0)
            }
        )
        self.consentConfirmed = confirmedVersion == consentVersion
        let resolvedInterval = config?.resolvedRefreshIntervalMinutes
            ?? OnboardingConfiguration.defaultRefreshIntervalMinutes
        self.refreshIntervalMinutes = resolvedInterval
        scheduler.updateRefreshInterval(TimeInterval(resolvedInterval * 60))
        self.appearanceMode = config?.resolvedAppearanceMode ?? .system
        let supported = LiquidGlassCapability.isSupported
        let theme = ThemeResolution.resolve(
            interfaceStyle: config?.interfaceStyle,
            glassStyle: config?.glassStyle,
            isSupported: supported
        )
        // UI 绑定使用解析后的界面风格 (不支持时为 classic); 模糊风格保留磁盘/默认.
        self.interfaceStyle = theme.interfaceStyle
        self.glassStyle = theme.glassStyle
        self.dashboardHotkey = config?.resolvedDashboardHotkey

        // SubscriptionService 在 self 部分初始化后创建; objectWillChange 经回调转发.
        // 使用临时无回调初始化, 随后在下方挂载 (init 内无法弱引用 self 前完成全量).
        let service = SubscriptionService(
            model: model,
            configStore: configStore,
            credentialStore: credentialStore,
            codexStore: resolvedStore,
            codexTokenManager: resolvedTokenManager,
            verifier: verifier,
            homeURL: homeURL,
            localProbe: resolvedProbe
        )
        self.subscriptions = service
        publishMenuBarMetrics(from: config)

        // 挂载状态变更转发: Settings 仍观察 Coordinator.
        service.bindStateChange { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - 订阅额度 (SubscriptionService façade)

    func saveAndVerifyDeepSeek(apiKey: String) {
        subscriptions.saveAndVerifyDeepSeek(apiKey: apiKey)
    }

    func saveAndVerifyVolcengine(accessKey: String, secretKey: String) {
        subscriptions.saveAndVerifyVolcengine(accessKey: accessKey, secretKey: secretKey)
    }

    func importVolcengineFromCCSwitch() {
        subscriptions.importVolcengineFromCCSwitch()
    }

    func importKimiFromLocalFile() {
        subscriptions.importKimiFromLocalFile()
    }

    func importKimiFromPaste(_ paste: String) {
        subscriptions.importKimiFromPaste(paste)
    }

    func importClaudeFromLocal() {
        subscriptions.importClaudeFromLocal()
    }

    func importClaudeFromPaste(_ paste: String) {
        subscriptions.importClaudeFromPaste(paste)
    }

    func importGrokFromLocal() {
        subscriptions.importGrokFromLocal()
    }

    func importGrokFromPaste(_ paste: String) {
        subscriptions.importGrokFromPaste(paste)
    }

    func importOpenCodeGoFromPaste(_ paste: String) {
        subscriptions.importOpenCodeGoFromPaste(paste)
    }

    func reverifyOpenCodeGo() {
        subscriptions.reverifyOpenCodeGo()
    }

    func importCodexFromLocalCLI() {
        subscriptions.importCodexFromLocalCLI()
    }

    func importCodexFromCCSwitch() {
        subscriptions.importCodexFromCCSwitch()
    }

    func loginCodexNewAccount() {
        subscriptions.loginCodexNewAccount()
    }

    func cancelCodexLogin() {
        subscriptions.cancelCodexLogin()
    }

    func reopenCodexLoginPage() {
        subscriptions.reopenCodexLoginPage()
    }

    func importAntigravityFromLocalFile() {
        subscriptions.importAntigravityFromLocalFile()
    }

    func addSubscriptionProvider(_ id: SubscriptionProviderID) {
        subscriptions.addSubscriptionProvider(id)
    }

    func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        subscriptions.removeSubscriptionProvider(id)
    }

    func setSubscriptionProviderEnabled(_ id: SubscriptionProviderID, _ enabled: Bool) {
        subscriptions.setSubscriptionProviderEnabled(id, enabled)
    }

    func setSubscriptionProviderOrder(_ order: [SubscriptionProviderID]) {
        subscriptions.setSubscriptionProviderOrder(order)
    }

    // MARK: - 多账号管理 (Phase 2)

    func accountSummaries(for id: SubscriptionProviderID) -> [ProviderAccountSummary] {
        subscriptions.accountSummaries(for: id)
    }

    func removeAccount(accountID: String, from id: SubscriptionProviderID) {
        subscriptions.removeAccount(accountID: accountID, from: id)
    }

    func updateAccountAuthorizationState(
        accountID: String,
        from id: SubscriptionProviderID,
        state: ProviderAccountAuthorizationState
    ) {
        subscriptions.updateAccountAuthorizationState(
            accountID: accountID, from: id, state: state
        )
    }

    func kimiLocalTokensFileExists() -> Bool {
        subscriptions.kimiLocalTokensFileExists()
    }

    func codexCLIAuthFileExists() -> Bool {
        subscriptions.codexCLIAuthFileExists()
    }

    func codexCCAccountsFileExists() -> Bool {
        subscriptions.codexCCAccountsFileExists()
    }

    func ccSwitchDatabaseExists() -> Bool {
        subscriptions.ccSwitchDatabaseExists()
    }

    func refreshAntigravityLocalAvailability() {
        subscriptions.refreshAntigravityLocalAvailability()
    }

    func refreshOfficialLocalAvailability() {
        subscriptions.refreshOfficialLocalAvailability()
    }

    /// 已配置且启用的订阅 provider 列表, 供统一授权摘要展示.
    var enabledConfiguredSubscriptionProviders: [SubscriptionProviderID] {
        subscriptions.enabledConfiguredSubscriptionProviders
    }

    private func publishMenuBarMetrics(
        from config: OnboardingConfiguration?
    ) {
        model.setMenuBarMetrics(
            MenuBarMetricConfiguration(
                rawValues: config?.menuBarMetrics
            ).metrics
        )
    }

    // MARK: - 扫描

    /// 执行本机扫描, 计算三模块就绪度并发布到 AppModel, 最后协调 Scheduler.
    /// 未确认授权时连接状态只取配置中持久化的非敏感状态, 不发外部请求;
    /// 授权版本有效时才对已选模块自动复核连接状态 (设计 6.5).
    func scanAndReconcile() {
        Task { @MainActor in
            await performScan()
        }
    }

    /// 用户主动触发的重新检查.
    func rescan() {
        scanAndReconcile()
    }

    /// 用户从模块页主动刷新. Scheduler 负责同模块合并与容量排队.
    func refresh(_ module: CollectorModule) {
        scheduler.refresh(module)
    }

    /// 设置页数据管理: 清理可再生快照缓存 (不影响配置, 凭证与账本).
    func clearSnapshotCaches() throws {
        try scheduler.clearSnapshotCaches()
    }

    private func performScan() async {
        let config = configStore?.load()
        publishMenuBarMetrics(from: config)

        for module in CollectorModule.allCases {
            model.setBusy(true, for: module)
        }
        defer {
            for module in CollectorModule.allCases {
                model.setBusy(false, for: module)
            }
        }

        // 本机只读扫描, 不产生外部请求
        let activeScanner = makeScanner(config: config)
        let probes = await activeScanner.scan()

        let pythonProbe = probes.first { $0.kind == .python }
        let pythonStatus = pythonProbe?.status ?? .missing
        let pythonVersion = pythonProbe?.detail
        let sessionProbes = probes.filter { $0.kind == .sessionDirectory }
        let ccSwitchStatus = sqliteResult(
            from: probes, displayName: SQLiteSchemaProfile.ccSwitch.displayName
        )
        let antigravityStatus = sqliteResult(
            from: probes, displayName: SQLiteSchemaProfile.antigravity.displayName
        )

        let evaluator = ReadinessEvaluator()

        model.setModuleResult(evaluator.evaluateAgentUsage(
            pythonStatus: pythonStatus,
            pythonVersion: pythonVersion,
            sessionSources: sessionProbes,
            ccSwitchStatus: ccSwitchStatus,
            antigravityStatus: antigravityStatus
        ))

        reconcileScheduler()
    }

    /// 用户选择的 Python 路径属于非敏感配置, 需要反映到扫描路径.
    private func makeScanner(
        config: OnboardingConfiguration?
    ) -> LocalDependencyScanner {
        guard let pythonPath = config?.pythonPath else { return scanner }
        var paths = LocalDependencyScanPaths.standard(home: homeURL)
        paths.userPreferredPythonPath = pythonPath
        return LocalDependencyScanner(paths: paths)
    }

    /// 扫描得到的 SQLite 状态与 evaluator 的入参类型互转 (rawValue 一致).
    private func sqliteResult(
        from probes: [DependencyProbe],
        displayName: String
    ) -> SQLiteSchemaProbeResult {
        let probe = probes.first {
            $0.kind == .sqliteDatabase && $0.detail == displayName
        }
        guard let status = probe?.status else { return .missing }
        return SQLiteSchemaProbeResult(rawValue: status.rawValue) ?? .missing
    }

    /// 用户变更自动刷新间隔: 先持久化再通知 Scheduler 重启计时
    /// (先存后生效); 非法值回落默认 30 分钟, 保存失败不变更运行中间隔.
    func setRefreshIntervalMinutes(_ minutes: Int) {
        let normalized = OnboardingConfiguration
            .allowedRefreshIntervalMinutes.contains(minutes)
            ? minutes : OnboardingConfiguration.defaultRefreshIntervalMinutes
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存刷新间隔")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.refreshIntervalMinutes = normalized
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("刷新间隔保存失败")
            return
        }
        refreshIntervalMinutes = normalized
        scheduler.updateRefreshInterval(TimeInterval(normalized * 60))
        model.setSettingsError(nil)
    }

    /// 用户变更外观偏好: 先持久化再发布 (先存后生效);
    /// 保存失败不变更运行中外观.
    func setAppearanceMode(_ mode: AppearancePreference) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存外观偏好")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.appearanceMode = mode
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("外观偏好保存失败")
            return
        }
        appearanceMode = mode
        model.setSettingsError(nil)
    }

    /// 用户变更界面风格: 不支持液态玻璃时拒绝 liquidGlass (fail-closed).
    func setInterfaceStyle(_ style: InterfaceStylePreference) {
        if style == .liquidGlass, !liquidGlassSupported() {
            model.setSettingsError("液态玻璃需要 macOS 26 或更高版本")
            return
        }
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存界面风格")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.interfaceStyle = style
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("界面风格保存失败")
            return
        }
        interfaceStyle = style
        model.setSettingsError(nil)
    }

    /// 用户变更模糊风格 (仅液态玻璃模式下有意义): 先持久化再发布.
    func setGlassStyle(_ style: GlassStylePreference) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存模糊风格")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.glassStyle = style
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("模糊风格保存失败")
            return
        }
        glassStyle = style
        model.setSettingsError(nil)
    }

    /// 注入全局快捷键监视器, 并注册已持久化的快捷键 (启动时装配).
    func setHotkeyMonitor(_ monitor: GlobalHotkeyMonitor) {
        hotkeyMonitor = monitor
        monitor.register(dashboardHotkey)
    }

    /// 用户变更全局快捷键: 先持久化再注册 (先存后生效);
    /// 保存失败不变更运行中快捷键.
    func setDashboardHotkey(_ hotkey: GlobalHotkey?) {
        if let hotkey {
            switch hotkey.validation {
            case .valid: break
            case .requiresModifier:
                model.setSettingsError("快捷键需至少一个修饰键, 请重试")
                return
            case .unsupportedKey:
                model.setSettingsError("该键不支持, 请换一个")
                return
            case .systemReserved:
                model.setSettingsError("该组合被系统保留, 请换一个")
                return
            }
        }
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存全局快捷键")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.dashboardHotkey = hotkey
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("全局快捷键保存失败")
            return
        }
        dashboardHotkey = hotkey
        hotkeyMonitor?.register(hotkey)
        model.setSettingsError(nil)
    }

    // MARK: - 授权

    /// 用户确认统一授权后调用.
    /// 保存失败时发布错误并直接返回 (fail-closed), 不启用任何模块.
    func confirmConsent(selectedModules: Set<CollectorModule>) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存授权")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.consentVersion = Self.currentConsentVersion
        config.selectedModules = Set(selectedModules.map(\.rawValue))
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("授权保存失败, 未启用任何模块")
            return
        }

        self.selectedModules = selectedModules
        consentConfirmed = true
        gate = CollectorActivationGate(
            consentVersion: Self.currentConsentVersion,
            confirmedConsentVersion: Self.currentConsentVersion
        )
        reconcileScheduler()
    }

    /// 撤销全部授权: 清除已确认版本, 所有模块停止调度.
    /// 保留模块选择, 用户可稍后重新确认授权.
    func revokeAllConsent() {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法撤销授权")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.consentVersion = nil
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("撤销授权保存失败")
            return
        }
        consentConfirmed = false
        gate = CollectorActivationGate(
            consentVersion: Self.currentConsentVersion,
            confirmedConsentVersion: nil
        )
        reconcileScheduler()
    }

    // MARK: - 用户操作

    /// 用户选择 Python 可执行文件: 验证可执行性, 保存后重扫.
    func choosePython(path: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            model.setSettingsError("所选文件不是可执行的 Python")
            return
        }
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存 Python 路径")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.pythonPath = path
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("Python 路径保存失败")
            return
        }
        model.setSettingsError(nil)
        rescan()
    }


    /// 保存有序菜单栏指标. 先持久化再发布, 避免 UI 与磁盘配置分叉.
    func setMenuBarMetrics(_ metrics: [MenuBarMetric]) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存菜单栏设置")
            return
        }
        let normalized = MenuBarMetricConfiguration(metrics: metrics).metrics
        var config = configStore.load() ?? OnboardingConfiguration()
        config.menuBarMetrics = normalized.map(\.rawValue)
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("菜单栏设置保存失败")
            return
        }
        model.setMenuBarMetrics(normalized)
        model.setSettingsError(nil)
    }

    // MARK: - Scheduler 协调

    /// 根据当前 Gate 结果统一 enable 或 disable 模块.
    /// 未确认授权时所有模块保持禁用.
    func reconcileScheduler() {
        let config = configStore?.load()
        let selected = Set(
            (config?.selectedModules ?? []).compactMap {
                CollectorModule(rawValue: $0)
            }
        )

        for module in CollectorModule.allCases {
            let readiness = model.readinessValue(for: module)
            let allowed = gate.canActivate(
                module: module,
                readiness: readiness,
                isModuleSelected: selected.contains(module),
                appIsAcceptingNewTasks: runtime.acceptsNewTasks
            )
            if allowed {
                scheduler.enableModule(module)
            } else {
                scheduler.disableModule(module)
            }
        }
    }
}
