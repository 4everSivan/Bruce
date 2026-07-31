import AppKit
import Foundation
import MdddAppCore
import MdddOnboardingCore

/// 设备码登录的 UI 展示状态 (Codex 共用).
/// userCode 是一次性验证码, 可展示; 不含 token.
struct DeviceLoginPresentation: Equatable {
    enum Stage: Equatable {
        /// 等待用户在浏览器输入验证码完成授权
        case waitingAuthorization
        /// 已授权, 正在换 token 并写入
        case finishing
        case succeeded
        case failed(String)
        case timedOut
    }

    let userCode: String
    let verificationURL: URL
    var stage: Stage
}

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
    /// 自动刷新间隔 (分钟), 与配置持久化同步.
    @Published private(set) var refreshIntervalMinutes: Int
    /// 外观偏好, 与配置持久化同步; 面板和设置窗口据此覆盖 colorScheme.
    @Published private(set) var appearanceMode: AppearancePreference
    /// 液态玻璃风格偏好, 与配置持久化同步; 经环境注入面板与设置页.
    @Published private(set) var glassStyle: GlassStylePreference

    /// Codex 设备码登录展示状态, nil 表示无进行中的流程.
    @Published private(set) var codexDeviceLogin: DeviceLoginPresentation?

    private var codexLoginTask: Task<Void, Never>?

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
        let resolvedInterval = config?.resolvedRefreshIntervalMinutes
            ?? OnboardingConfiguration.defaultRefreshIntervalMinutes
        self.refreshIntervalMinutes = resolvedInterval
        scheduler.updateRefreshInterval(TimeInterval(resolvedInterval * 60))
        self.appearanceMode = config?.resolvedAppearanceMode ?? .system
        self.glassStyle = config?.resolvedGlassStyle ?? .regular
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

    /// Codex: 设备码登录新账号 (用户点击触发, 全程网络只由该点击发起).
    /// UI 展示 user_code 并打开官方验证页; 轮询带过期超时与任务取消;
    /// 成功后复用账号库合并逻辑写入 Keychain 并设为 active, 刷新摘要.
    /// 每步失败都给出可诊断错误, 不写半成品凭证 (fail-closed).
    func loginCodexNewAccount() {
        codexLoginTask?.cancel()
        model.setBusySubscription(true, for: .codex)
        model.setSettingsError(nil)
        codexLoginTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.model.setBusySubscription(false, for: .codex) }
            let flow = CodexDeviceFlow()

            let authorization: DeviceAuthorization
            switch await flow.start() {
            case .failure(let error):
                guard error != .cancelled else { return }
                self.codexDeviceLogin = nil
                self.model.setSettingsError(
                    "Codex 登录发起失败: \(error.description)"
                )
                return
            case .success(let parsed):
                authorization = parsed
            }

            self.codexDeviceLogin = DeviceLoginPresentation(
                userCode: authorization.userCode,
                verificationURL: authorization.verificationURL,
                stage: .waitingAuthorization
            )
            self.openInBrowser(authorization.verificationURL)

            let grant: CodexDeviceFlow.DeviceGrant
            switch await flow.pollUntilAuthorized(authorization) {
            case .failure(let error):
                if error == .cancelled { self.codexDeviceLogin = nil }
                else { self.finishCodexLogin(with: error) }
                return
            case .success(let parsed):
                grant = parsed
            }

            self.codexDeviceLogin?.stage = .finishing
            switch await flow.exchange(grant) {
            case .failure(let error):
                if error == .cancelled { self.codexDeviceLogin = nil }
                else { self.finishCodexLogin(with: error) }
                return
            case .success(let account):
                let existing = try? credentialStore.loadCredential(
                    forAccount: SubscriptionCredentialAccount.codexAccounts
                )
                switch CodexAccountsLibrary.merging(
                    existingJSON: existing, account: account
                ) {
                case .failure(let error):
                    self.codexDeviceLogin = nil
                    self.model.setSettingsError(
                        "Codex 账号库合并失败: \(error.description)"
                    )
                case .success(let merged):
                    saveCodexAccountsLibrary(
                        merged, activeAccountID: account.accountID
                    )
                    guard self.codexDeviceLogin != nil else { return }
                    self.codexDeviceLogin?.stage = .succeeded
                    // 成功状态短暂展示后收起
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.codexDeviceLogin = nil
                }
            }
        }
    }

    /// 取消进行中的 Codex 设备码登录并收起展示.
    func cancelCodexLogin() {
        codexLoginTask?.cancel()
        codexLoginTask = nil
        codexDeviceLogin = nil
        model.setBusySubscription(false, for: .codex)
    }

    /// 重新打开 Codex 验证页 (用户误关浏览器时点击).
    func reopenCodexLoginPage() {
        guard let url = codexDeviceLogin?.verificationURL else { return }
        openInBrowser(url)
    }

    /// Codex 轮询或换码失败的统一收尾, 均 fail-closed.
    private func finishCodexLogin(with error: DeviceAuthError) {
        switch error {
        case .authorizationExpired:
            codexDeviceLogin?.stage = .timedOut
        case .authorizationDenied:
            codexDeviceLogin?.stage = .failed("授权被拒绝")
        default:
            codexDeviceLogin?.stage = .failed(error.description)
        }
        model.setSettingsError("Codex 登录未完成: \(error.description)")
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

    /// 连接成功后把模块加入已选集合并持久化, 使 reconcileScheduler
    /// 能把该模块交给 Scheduler 调度. 保存失败发布错误并返回 false
    /// (fail-closed), 不更新内存选中状态.
    @discardableResult
    private func persistModuleSelection(_ module: CollectorModule) -> Bool {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法启用模块")
            return false
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        guard !config.selectedModules.contains(module.rawValue) else {
            return true
        }
        config.selectedModules.insert(module.rawValue)
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("模块启用保存失败, 自动调度不会生效")
            return false
        }
        selectedModules.insert(module)
        return true
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

    /// 用户变更液态玻璃风格: 先持久化再发布 (先存后生效);
    /// 保存失败不变更运行中风格.
    func setGlassStyle(_ style: GlassStylePreference) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存玻璃风格")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.glassStyle = style
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("玻璃风格保存失败")
            return
        }
        glassStyle = style
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

    /// 撤销单个模块: 停止调度并从已选集合移除.
    func revokeModule(_ module: CollectorModule) {
        scheduler.disableModule(module)
        selectedModules.remove(module)

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

    /// LSUIElement 下打开浏览器: 先激活再 open; 打开失败 fail-closed,
    /// 提示用户手动访问, 验证码已在界面上展示.
    private func openInBrowser(_ url: URL) {
        NSApp.activate()
        if !NSWorkspace.shared.open(url) {
            model.setSettingsError(
                "无法自动打开浏览器, 请手动访问: \(url.absoluteString)"
            )
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
