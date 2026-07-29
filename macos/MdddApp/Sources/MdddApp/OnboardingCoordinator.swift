import Foundation
import MdddOnboardingCore

/// 协调 Onboarding 扫描, 连接验证, 授权确认和 Scheduler 启用.
/// 本机扫描不产生外部请求; 外部验证只在用户主动操作或授权版本有效时触发.
/// 未确认统一授权时所有模块保持禁用; 授权后由 Gate 决定启用哪些模块.
@MainActor
final class OnboardingCoordinator: ObservableObject {
    static let currentConsentVersion = 1

    /// 用户在授权区选择的模块, 与配置持久化同步.
    @Published var selectedModules: Set<CollectorModule>
    /// 当前是否处于授权版本有效状态.
    @Published private(set) var consentConfirmed: Bool

    /// 已配置的 GitLab base URL (非敏感), 供设置页预填.
    var configuredGitLabBaseURL: String? {
        configStore?.load()?.gitlabBaseURL
    }

    private let scheduler: RefreshScheduler
    private let model: AppModel
    private let runtime: AppRuntime
    private let configStore: OnboardingConfigurationStore?
    private let credentialStore: CredentialStore
    private let scanner: LocalDependencyScanner
    private let verifier: ProviderConnectionVerifier
    private let homeURL: URL
    private var gate: CollectorActivationGate

    init(
        scheduler: RefreshScheduler,
        model: AppModel,
        runtime: AppRuntime,
        configStore: OnboardingConfigurationStore? = try? OnboardingConfigurationStore(),
        credentialStore: CredentialStore = KeychainCredentialStore(),
        scanner: LocalDependencyScanner? = nil,
        verifier: ProviderConnectionVerifier = ProviderConnectionVerifier(),
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        consentVersion: Int = OnboardingCoordinator.currentConsentVersion
    ) {
        self.scheduler = scheduler
        self.model = model
        self.runtime = runtime
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.verifier = verifier
        self.homeURL = homeURL
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
        publishTheme(from: config)
    }

    /// 从配置恢复主题并发布到 model; 未知值或低系统的液态玻璃回退 classic.
    private func publishTheme(from config: OnboardingConfiguration?) {
        let stored = config?.theme.flatMap { AppTheme(rawValue: $0) } ?? .classic
        model.theme = GlassTheme.resolved(stored)
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

    private func performScan() async {
        let config = configStore?.load()
        let consentValid = config?.consentVersion == Self.currentConsentVersion
        let persistedStates = config?.connectionStates ?? [:]
        publishTheme(from: config)

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
        let ghProbe = probes.first { $0.kind == .ghCli }
        let sessionProbes = probes.filter { $0.kind == .sessionDirectory }
        let ccSwitchStatus = sqliteResult(
            from: probes, displayName: SQLiteSchemaProfile.ccSwitch.displayName
        )
        let antigravityStatus = sqliteResult(
            from: probes, displayName: SQLiteSchemaProfile.antigravity.displayName
        )

        let evaluator = ReadinessEvaluator()

        // GitHub 登录态: 未授权只用持久化状态; 授权有效且模块已选才复核
        var ghLoggedIn = persistedStates[CollectorModule.github.rawValue]
            == ConnectionStatus.connected.rawValue
        if consentValid, selectedModules.contains(.github),
           let ghPath = GhCliPathResolver.resolve() {
            let status = await verifier.checkGitHubStatus(
                ghPath: ghPath, hasConnectedBefore: ghLoggedIn
            )
            persistConnectionState(status, for: .github)
            ghLoggedIn = status == .connected
        }

        // GitLab 连接态: 同上; 复核前先从 Keychain 取 PAT, 取不到不发起请求
        var gitlabStatus: ConnectionStatus =
            ConnectionStatus(
                rawValue: persistedStates[CollectorModule.gitlab.rawValue] ?? ""
            ) ?? .notChecked
        let gitlabBaseURL = config?.gitlabBaseURL.flatMap {
            ProviderConnectionVerifier.normalizedGitLabBaseURL($0)
        }
        if consentValid, selectedModules.contains(.gitlab),
           let baseURL = gitlabBaseURL, let host = baseURL.host {
            if let pat = try? credentialStore.loadPAT(forHost: host),
               !pat.isEmpty {
                gitlabStatus = await verifier.verifyGitLab(
                    baseURL: baseURL, pat: pat
                )
                persistConnectionState(gitlabStatus, for: .gitlab)
            } else {
                // 取不到 PAT 按待授权处理, 不发起请求
                gitlabStatus = .pendingAuthorization
            }
        }

        model.setModuleResult(evaluator.evaluateAgentUsage(
            pythonStatus: pythonStatus,
            pythonVersion: pythonVersion,
            sessionSources: sessionProbes,
            ccSwitchStatus: ccSwitchStatus,
            antigravityStatus: antigravityStatus
        ))
        model.setModuleResult(evaluator.evaluateGitHub(
            pythonStatus: pythonStatus,
            pythonVersion: pythonVersion,
            ghCliStatus: ghProbe?.status ?? .missing,
            ghVersion: ghProbe?.detail,
            ghLoggedIn: ghLoggedIn
        ))
        model.setModuleResult(evaluator.evaluateGitLab(
            pythonStatus: pythonStatus,
            pythonVersion: pythonVersion,
            baseURL: gitlabBaseURL,
            connectionStatus: gitlabBaseURL == nil ? .pendingAuthorization : gitlabStatus
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

    /// 只持久化非敏感的连接状态和验证时间. 保存失败不阻塞主流程,
    /// 下一轮扫描或验证会重试.
    private func persistConnectionState(
        _ status: ConnectionStatus,
        for module: CollectorModule
    ) {
        guard var config = configStore?.load() else { return }
        config.connectionStates[module.rawValue] = status.rawValue
        config.lastVerifiedAt[module.rawValue] =
            ISO8601DateFormatter().string(from: Date())
        try? configStore?.save(config)
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
    /// 保留模块选择和 GitLab PAT, 用户可分别通过 Toggle 和"断开"处理.
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

    /// 撤销单个模块: 停止调度并从已选集合移除.
    /// GitLab 断开时同时删除 Keychain 中对应 host 的 PAT.
    /// 远端 PAT 撤销由用户在 GitLab 完成.
    func revokeModule(_ module: CollectorModule) {
        scheduler.disableModule(module)
        selectedModules.remove(module)

        if module == .gitlab,
           let host = configStore?.load()?.gitlabBaseURL
            .flatMap({ ProviderConnectionVerifier.normalizedGitLabBaseURL($0) })
            .flatMap({ $0.host }) {
            do {
                try credentialStore.deletePAT(forHost: host)
            } catch {
                model.setSettingsError("GitLab 凭证删除失败, 请在 Keychain 中手动检查")
            }
        }

        guard let configStore else { return }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.selectedModules.remove(module.rawValue)
        config.connectionStates.removeValue(forKey: module.rawValue)
        config.lastVerifiedAt.removeValue(forKey: module.rawValue)
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("模块撤销保存失败, 重启后可能恢复")
        }
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

    /// 用户主动登录 GitHub: 走 gh 官方 web 流程, 完成后复核一次状态.
    /// 只持久化非敏感连接状态. 用户取消或超时保持未连接.
    func loginGitHub() {
        Task { @MainActor in
            guard let ghPath = GhCliPathResolver.resolve() else {
                model.setSettingsError("未找到 GitHub CLI, 请先安装 gh")
                return
            }
            model.setBusy(true, for: .github)
            defer { model.setBusy(false, for: .github) }
            let loginResult = await verifier.loginGitHub(ghPath: ghPath)
            guard loginResult == .connected else { return }
            let status = await verifier.checkGitHubStatus(
                ghPath: ghPath, hasConnectedBefore: false
            )
            persistConnectionState(status, for: .github)
            model.setSettingsError(nil)
            rescan()
        }
    }

    /// 用户保存并验证 GitLab: 校验 HTTPS URL, PAT 写 Keychain,
    /// 调用 /api/v4/user 验证, 只持久化非敏感状态. PAT 永不回显.
    func saveAndVerifyGitLab(baseURL rawURL: String, pat: String) {
        Task { @MainActor in
            guard let baseURL = ProviderConnectionVerifier
                .normalizedGitLabBaseURL(rawURL),
                  let host = baseURL.host else {
                model.setSettingsError("GitLab 地址必须是合法的 HTTPS URL")
                return
            }
            guard !pat.isEmpty else {
                model.setSettingsError("请输入 GitLab PAT")
                return
            }
            model.setBusy(true, for: .gitlab)
            defer { model.setBusy(false, for: .gitlab) }
            do {
                try credentialStore.savePAT(pat, forHost: host)
            } catch {
                model.setSettingsError("GitLab 凭证写入 Keychain 失败")
                return
            }
            let status = await verifier.verifyGitLab(baseURL: baseURL, pat: pat)
            guard let configStore else {
                model.setSettingsError("配置存储不可用, 无法保存 GitLab 地址")
                return
            }
            var config = configStore.load() ?? OnboardingConfiguration()
            config.gitlabBaseURL = baseURL.absoluteString
            do {
                try configStore.save(config)
            } catch {
                model.setSettingsError("GitLab 地址保存失败")
                return
            }
            persistConnectionState(status, for: .gitlab)
            model.setSettingsError(nil)
            rescan()
        }
    }

    /// 用户切换外观主题: 先持久化再发布, 保存失败时不切换 (fail-closed).
    /// 液态玻璃在低系统不可用时回退 classic 展示, 配置仍保留用户选择.
    func setTheme(_ theme: AppTheme) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存外观设置")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.theme = theme.rawValue
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("外观设置保存失败, 主题未切换")
            return
        }
        model.theme = GlassTheme.resolved(theme)
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
