import Foundation
import MdddAppCore
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
        publishMenuBarMetrics(from: config)
        publishSubscriptionState(from: config)
    }

    // MARK: - 订阅额度

    private let ccSwitchImporter = CCSwitchVolcengineImporter()

    /// 从配置与 Keychain 恢复订阅 provider 展示状态.
    /// Keychain 只判断凭证是否存在, 凭证值不进入 UI 状态.
    private func publishSubscriptionState(from config: OnboardingConfiguration?) {
        var providers: [SubscriptionProviderID: SubscriptionProviderConfiguration] = [:]
        for (key, value) in config?.subscriptionProviders ?? [:] {
            if let id = SubscriptionProviderID(rawValue: key) {
                providers[id] = value
            }
        }
        model.setSubscriptionProviders(providers)
        for id in SubscriptionProviderID.allCases {
            model.setSubscriptionCredentialConfigured(
                credentialConfigured(id), for: id
            )
        }
        if let json = try? credentialStore.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        ) {
            model.setCodexAccountSummary(CodexAccountsLibrary.summary(of: json))
        } else {
            model.setCodexAccountSummary(nil)
        }
    }

    /// 判断 provider 的 Keychain 凭证是否完整配置.
    private func credentialConfigured(_ id: SubscriptionProviderID) -> Bool {
        for account in id.credentialAccounts {
            guard let value = try? credentialStore.loadCredential(
                forAccount: account
            ), !value.isEmpty else {
                return false
            }
        }
        return true
    }

    /// 持久化单个订阅 provider 的非敏感配置并发布.
    /// 保存失败发布错误并返回 false (fail-closed), 不在会话内假装成功.
    private func persistSubscription(
        _ id: SubscriptionProviderID,
        mutate: (inout SubscriptionProviderConfiguration) -> Void
    ) -> Bool {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存订阅配置")
            return false
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        var entry = config.subscriptionProviders[id.rawValue]
            ?? SubscriptionProviderConfiguration()
        mutate(&entry)
        config.subscriptionProviders[id.rawValue] = entry
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("\(id.displayName) 订阅配置保存失败")
            return false
        }
        publishSubscriptionState(from: config)
        return true
    }

    /// 验证完成后统一收尾: 写状态迁移, 失败原因进入设置错误提示.
    private func finishVerification(
        _ id: SubscriptionProviderID,
        status: SubscriptionVerificationStatus
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        guard persistSubscription(id, mutate: {
            $0 = $0.applyingVerification(status, verifiedAt: now)
        }) else { return }
        switch status {
        case .ok:
            model.setSettingsError(nil)
        case .failed(let reason):
            model.setSettingsError("\(id.displayName) 验证失败: \(reason)")
        case .needsRelogin:
            model.setSettingsError("\(id.displayName) 需要重新登录")
        case .none:
            break
        }
    }

    /// DeepSeek: API key 写 Keychain 后做真实网络试查 (用户点击触发).
    func saveAndVerifyDeepSeek(apiKey: String) {
        Task { @MainActor in
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                model.setSettingsError("请输入 DeepSeek API key")
                return
            }
            model.setBusySubscription(true, for: .deepseek)
            defer { model.setBusySubscription(false, for: .deepseek) }
            do {
                try credentialStore.saveCredential(
                    key, forAccount: SubscriptionCredentialAccount.deepseekAPIKey
                )
            } catch {
                model.setSettingsError("DeepSeek 凭证写入 Keychain 失败")
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .deepseek)
            let status = await verifier.verifyDeepSeek(apiKey: key)
            finishVerification(.deepseek, status: status)
        }
    }

    /// 火山引擎手动录入: 仅结构校验, 完整额度试查由 Collector 运行时承担.
    func saveAndVerifyVolcengine(accessKey: String, secretKey: String) {
        let status = ProviderConnectionVerifier.verifyVolcengineCredentials(
            accessKey: accessKey, secretKey: secretKey
        )
        guard status == .ok else {
            finishVerification(.volcengine, status: status)
            return
        }
        do {
            try credentialStore.saveCredential(
                accessKey.trimmingCharacters(in: .whitespacesAndNewlines),
                forAccount: SubscriptionCredentialAccount.volcengineAccessKey
            )
            try credentialStore.saveCredential(
                secretKey.trimmingCharacters(in: .whitespacesAndNewlines),
                forAccount: SubscriptionCredentialAccount.volcengineSecretKey
            )
        } catch {
            model.setSettingsError("火山引擎凭证写入 Keychain 失败")
            return
        }
        model.setSubscriptionCredentialConfigured(true, for: .volcengine)
        finishVerification(.volcengine, status: status)
    }

    /// 火山引擎从 CC Switch 导入 (用户在确认对话框同意后调用).
    /// 只读 CC 数据库, 禁止任何写入.
    func importVolcengineFromCCSwitch() {
        Task { @MainActor in
            model.setBusySubscription(true, for: .volcengine)
            defer { model.setBusySubscription(false, for: .volcengine) }
            let databaseURL = homeURL
                .appendingPathComponent(".cc-switch/cc-switch.db")
            let result = await ccSwitchImporter.importCredentials(
                databaseURL: databaseURL
            )
            switch result {
            case .failure(let error):
                model.setSettingsError("从 CC Switch 导入火山引擎失败: \(error.description)")
            case .success(let credentials):
                saveAndVerifyVolcengine(
                    accessKey: credentials.accessKey,
                    secretKey: credentials.secretKey
                )
            }
        }
    }

    /// Kimi: 从本机 kimi-dashboard 令牌文件一键导入 (用户点击触发).
    func importKimiFromLocalFile() {
        let fileURL = homeURL.appendingPathComponent(
            ".config/kimi-dashboard/kimi-web-tokens.json"
        )
        guard let json = readCredentialFile(fileURL, usage: "Kimi 本机令牌文件") else {
            return
        }
        saveKimiTokensJSON(json)
    }

    /// Kimi: 引导粘贴导入 (整段 JSON 或两段 token).
    func importKimiFromPaste(_ paste: String) {
        switch KimiPasteParser.parse(paste) {
        case .failure(let error):
            model.setSettingsError("Kimi 凭证解析失败: \(error.description)")
        case .success(let json):
            saveKimiTokensJSON(json)
        }
    }

    private func saveKimiTokensJSON(_ json: String) {
        let status = ProviderConnectionVerifier.verifyKimiWebTokensJSON(json)
        if status == .ok || status == .needsRelogin {
            do {
                try credentialStore.saveCredential(
                    json, forAccount: SubscriptionCredentialAccount.kimiWebTokens
                )
            } catch {
                model.setSettingsError("Kimi 凭证写入 Keychain 失败")
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .kimi)
        }
        finishVerification(.kimi, status: status)
    }

    /// Codex: 从 CLI `~/.codex/auth.json` 导入当前账号, 合并进账号库
    /// 并设为 active (用户点击触发).
    func importCodexFromLocalCLI() {
        let fileURL = homeURL.appendingPathComponent(".codex/auth.json")
        guard let json = readCredentialFile(fileURL, usage: "Codex CLI 认证文件") else {
            return
        }
        switch CodexAuthFileParser.parse(json) {
        case .failure(let error):
            model.setSettingsError("Codex 认证文件解析失败: \(error.description)")
        case .success(let account):
            let existing = try? credentialStore.loadCredential(
                forAccount: SubscriptionCredentialAccount.codexAccounts
            )
            switch CodexAccountsLibrary.merging(
                existingJSON: existing, account: account
            ) {
            case .failure(let error):
                model.setSettingsError("Codex 账号库合并失败: \(error.description)")
            case .success(let merged):
                saveCodexAccountsLibrary(merged, activeAccountID: account.accountID)
            }
        }
    }

    /// Codex: 从 CC Switch 账号库一次性导入 (用户在确认对话框同意后调用).
    /// 只读 `~/.cc-switch/codex_oauth_auth.json`, 不回写 CC.
    /// active 账号优先取 CLI 当前账号, 其次保留既有 active.
    func importCodexFromCCSwitch() {
        let fileURL = homeURL.appendingPathComponent(
            ".cc-switch/codex_oauth_auth.json"
        )
        guard let json = readCredentialFile(fileURL, usage: "CC Switch Codex 账号库") else {
            return
        }
        let status = ProviderConnectionVerifier.verifyCodexAccountsJSON(json)
        guard status == .ok else {
            finishVerification(.codex, status: status)
            return
        }
        let accountIDs = CodexAccountsLibrary.accountIDs(of: json)
        let cliAccountID = readCodexCLIActiveAccountID()
        let existingActive = try? credentialStore.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexActiveAccount
        )
        let active = CodexAccountsLibrary.chooseActiveAccount(
            cliAccountID: cliAccountID,
            existingActive: existingActive,
            accountIDs: accountIDs
        )
        saveCodexAccountsLibrary(json, activeAccountID: active)
    }

    private func saveCodexAccountsLibrary(
        _ json: String, activeAccountID: String?
    ) {
        do {
            try credentialStore.saveCredential(
                json, forAccount: SubscriptionCredentialAccount.codexAccounts
            )
            if let activeAccountID {
                try credentialStore.saveCredential(
                    activeAccountID,
                    forAccount: SubscriptionCredentialAccount.codexActiveAccount
                )
            }
        } catch {
            model.setSettingsError("Codex 凭证写入 Keychain 失败")
            return
        }
        model.setSubscriptionCredentialConfigured(true, for: .codex)
        model.setCodexAccountSummary(CodexAccountsLibrary.summary(of: json))
        finishVerification(
            .codex,
            status: ProviderConnectionVerifier.verifyCodexAccountsJSON(json)
        )
    }

    /// 读取 CLI `~/.codex/auth.json` 的当前账号 id; 读不到返回 nil (非致命).
    private func readCodexCLIActiveAccountID() -> String? {
        let fileURL = homeURL.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any] else {
            return nil
        }
        let accountID = (tokens["account_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return accountID.isEmpty ? nil : accountID
    }

    /// Antigravity: 从本机令牌文件导入 (用户点击触发).
    func importAntigravityFromLocalFile() {
        let fileURL = homeURL.appendingPathComponent(
            ".gemini/antigravity-cli/antigravity-oauth-token"
        )
        guard let json = readCredentialFile(fileURL, usage: "Antigravity 令牌文件") else {
            return
        }
        let status = ProviderConnectionVerifier.verifyAntigravityOAuthJSON(json)
        guard status == .ok else {
            finishVerification(.antigravity, status: status)
            return
        }
        do {
            try credentialStore.saveCredential(
                json, forAccount: SubscriptionCredentialAccount.antigravityOAuth
            )
        } catch {
            model.setSettingsError("Antigravity 凭证写入 Keychain 失败")
            return
        }
        model.setSubscriptionCredentialConfigured(true, for: .antigravity)
        finishVerification(.antigravity, status: status)
    }

    /// 移除 provider: 删除其全部 Keychain 凭证并重置非敏感配置.
    /// Keychain 删除失败时报错且不重置配置 (fail-closed).
    func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        do {
            for account in id.credentialAccounts {
                try credentialStore.deleteCredential(forAccount: account)
            }
        } catch {
            model.setSettingsError(
                "\(id.displayName) 凭证删除失败, 请在 Keychain 中手动检查"
            )
            return
        }
        guard persistSubscription(id, mutate: {
            $0 = SubscriptionProviderConfiguration()
        }) else { return }
        if id == .codex {
            model.setCodexAccountSummary(nil)
        }
        model.setSettingsError(nil)
    }

    /// enabled 开关: 只有凭证已配置才允许开启; 保存失败不变更 (fail-closed).
    func setSubscriptionProviderEnabled(
        _ id: SubscriptionProviderID, _ enabled: Bool
    ) {
        if enabled {
            guard credentialConfigured(id) else {
                model.setSettingsError("请先配置 \(id.displayName) 凭证再启用")
                return
            }
        }
        guard persistSubscription(id, mutate: { $0.enabled = enabled }) else {
            return
        }
        model.setSettingsError(nil)
    }

    /// 读取用户主目录下的凭证文件 (仅由用户点击触发), 失败给出可诊断错误.
    private func readCredentialFile(_ fileURL: URL, usage: String) -> String? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            model.setSettingsError("未找到\(usage): \(fileURL.path)")
            return nil
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                model.setSettingsError("\(usage)内容为空或不是 UTF-8 文本")
                return nil
            }
            return text
        } catch {
            model.setSettingsError("\(usage)读取失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - 订阅额度本机文件检测 (供设置页条件渲染)

    func kimiLocalTokensFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(".config/kimi-dashboard/kimi-web-tokens.json")
                .path
        )
    }

    func codexCLIAuthFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".codex/auth.json").path
        )
    }

    func codexCCAccountsFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(".cc-switch/codex_oauth_auth.json").path
        )
    }

    func antigravityTokenFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(
                    ".gemini/antigravity-cli/antigravity-oauth-token"
                ).path
        )
    }

    func ccSwitchDatabaseExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".cc-switch/cc-switch.db").path
        )
    }

    /// 已配置且启用的订阅 provider 列表, 供统一授权摘要展示.
    /// 与 CollectorActivationGate 的 hasConfiguredSubscriptionProvider 语义一致.
    var enabledConfiguredSubscriptionProviders: [SubscriptionProviderID] {
        SubscriptionProviderID.allCases.filter { id in
            (model.subscriptionProviders[id]?.enabled ?? false)
                && (model.subscriptionCredentialConfigured[id] ?? false)
        }
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

    private func performScan() async {
        let config = configStore?.load()
        let consentValid = config?.consentVersion == Self.currentConsentVersion
        let persistedStates = config?.connectionStates ?? [:]
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
