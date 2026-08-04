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
    /// Codex v2 凭证存储与 token manager (App 装配时注入, 与运行输入提供器共享).
    private let codexStore: CodexCredentialStore
    private let codexTokenManager: CodexTokenManager
    private let scanner: LocalDependencyScanner
    private let verifier: any DeepSeekCredentialVerifier
    private let homeURL: URL
    private var gate: CollectorActivationGate

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
        consentVersion: Int = OnboardingCoordinator.currentConsentVersion
    ) {
        self.scheduler = scheduler
        self.model = model
        self.runtime = runtime
        self.configStore = configStore
        self.credentialStore = credentialStore
        let resolvedStore = codexStore
            ?? CodexCredentialStore(store: credentialStore)
        self.codexStore = resolvedStore
        self.codexTokenManager = codexTokenManager ?? CodexTokenManager(
            store: resolvedStore,
            client: CodexOAuthClient.defaultClient()
        )
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
    /// Codex 摘要改读 v2 账号索引 (元数据), 不再读旧整体账号库.
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
        publishCodexSummaryFromIndex()
    }

    /// 从 v2 账号索引发布 Codex 账号摘要 (数量与邮箱前缀, 与旧摘要格式一致).
    private func publishCodexSummaryFromIndex() {
        guard let index = try? codexStore.loadIndex() else {
            model.setCodexAccountSummary(nil)
            return
        }
        let entries = index.accounts.sorted { $0.accountID < $1.accountID }
        let prefixes = entries.map { entry -> String in
            if let email = entry.email, !email.isEmpty {
                return email.split(separator: "@").first.map(String.init) ?? email
            }
            return String(entry.accountID.prefix(8))
        }
        model.setCodexAccountSummary(
            entries.isEmpty ? nil : (entries.count, prefixes)
        )
    }

    /// 判断 provider 的 Keychain 凭证是否完整配置.
    /// Codex: 至少一个账号处于 connected 且有完整凭证 (access token +
    /// refresh token + 过期时间); metadata-only 发现账号不算已配置.
    private func credentialConfigured(_ id: SubscriptionProviderID) -> Bool {
        if id == .codex {
            // 只发现账号元数据 (metadata-only) 不算已配置;
            // 按真实完整 record 判定, 索引状态不作数 (fail-closed).
            return (try? codexStore.hasConfiguredCredentials()) ?? false
        }
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
    ///
    /// 保存事务 (避免新旧凭证混算, 见 deepseek-monthly-consumption 设计):
    /// 1. 预写携带新 usageTrackingID 的禁用配置 (fail-closed: 阻止并发刷新
    ///    用旧追踪 ID 记账). 预写失败不写 Keychain.
    /// 2. 写 Keychain. 失败时恢复完整旧配置 (含旧 usageTrackingID);
    ///    恢复失败则保留预写的禁用配置并报错.
    /// 3. 用户触发的网络验证. 验证成功才重新启用外部额度查询.
    ///    验证失败保留新 ID 且维持禁用/失败状态, 不回滚到旧 ID.
    func saveAndVerifyDeepSeek(apiKey: String) {
        Task { @MainActor in
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                model.setSettingsError("请输入 DeepSeek API key")
                return
            }
            model.setBusySubscription(true, for: .deepseek)
            defer { model.setBusySubscription(false, for: .deepseek) }

            // 1. 预写禁用配置 + 新追踪 ID
            guard let oldEntry = prewriteDisabledDeepSeek() else {
                model.setSettingsError("DeepSeek 订阅配置保存失败")
                return
            }

            // 2. 写 Keychain; 失败恢复旧配置
            do {
                try credentialStore.saveCredential(
                    key, forAccount: SubscriptionCredentialAccount.deepseekAPIKey
                )
            } catch {
                restoreDeepSeekConfig(oldEntry)
                model.setSettingsError("DeepSeek 凭证写入 Keychain 失败")
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .deepseek)

            // 3. 验证; 成功才重新启用 (finishVerification 内部走 persistSubscription)
            let status = await verifier.verifyDeepSeek(apiKey: key, session: nil)
            finishVerification(.deepseek, status: status)
        }
    }

    /// 预写 DeepSeek 禁用配置并携带新 usageTrackingID. 返回旧配置快照供回滚;
    /// 保存失败返回 nil (fail-closed, 调用方不得继续写 Keychain).
    private func prewriteDisabledDeepSeek() -> SubscriptionProviderConfiguration?? {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存订阅配置")
            return nil
        }
        let result: DeepSeekSaveTransaction.PrewriteResult
        do {
            result = try DeepSeekSaveTransaction.prewriteDisabled(in: configStore)
        } catch {
            return nil
        }
        publishSubscriptionState(from: configStore.load())
        return result.oldEntry
    }

    /// Keychain 写入失败时恢复旧 DeepSeek 配置 (含旧 usageTrackingID).
    /// 旧配置为 nil 表示原本不存在该 provider, 恢复为移除该键.
    /// 恢复失败时保留预写的禁用配置 (fail-closed, 不混算).
    private func restoreDeepSeekConfig(
        _ oldEntry: SubscriptionProviderConfiguration?
    ) {
        guard let configStore else { return }
        do {
            try DeepSeekSaveTransaction.restore(
                oldEntry: oldEntry, in: configStore
            )
            publishSubscriptionState(from: configStore.load())
        } catch {
            // 恢复失败: 保留预写的新 ID + 禁用配置, 不发布旧状态.
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

    /// Codex: 从 CLI `~/.codex/auth.json` 发现账号 (用户点击触发).
    /// 只保存账号元数据 (needsReauthorization), 不导入 token.
    func importCodexFromLocalCLI() {
        let fileURL = homeURL.appendingPathComponent(".codex/auth.json")
        guard let json = readCredentialFile(fileURL, usage: "Codex CLI 认证文件") else {
            return
        }
        do {
            let accounts = try CodexDiscovery.fromCLIAuthJSON(json)
            try codexStore.saveDiscoveredAccounts(
                accounts, now: Date()
            )
        } catch {
            model.setSettingsError("Codex 认证文件解析失败, 仅发现账号元数据")
            return
        }
        finishCodexDiscoveryImport()
    }

    /// Codex: 从 CC Switch 账号库发现账号 (用户在确认对话框同意后调用).
    /// 只读 `~/.cc-switch/codex_oauth_auth.json`, 不回写 CC.
    /// 只保存账号元数据 (needsReauthorization), 不导入 token.
    func importCodexFromCCSwitch() {
        let fileURL = homeURL.appendingPathComponent(
            ".cc-switch/codex_oauth_auth.json"
        )
        guard let json = readCredentialFile(fileURL, usage: "CC Switch Codex 账号库") else {
            return
        }
        do {
            let accounts = try CodexDiscovery.fromCCSwitchAccountsJSON(json)
            try codexStore.saveDiscoveredAccounts(
                accounts, now: Date()
            )
        } catch {
            model.setSettingsError("CC Switch Codex 账号库解析失败, 仅发现账号元数据")
            return
        }
        finishCodexDiscoveryImport()
    }

    /// 发现导入的公共收尾: 发布摘要与验证状态.
    /// 发现的账号是 metadata-only (无 token), 不标记"已配置";
    /// "已配置"只在存在真实完整 record 时成立 (fail-closed).
    private func finishCodexDiscoveryImport() {
        publishCodexSummaryFromIndex()
        publishCodexCredentialConfigured()
        finishVerification(.codex, status: .none)
    }

    /// 按真实完整 record 发布 Codex"已配置"状态, 索引状态不作数.
    private func publishCodexCredentialConfigured() {
        let configured = (try? codexStore.hasConfiguredCredentials()) ?? false
        model.setSubscriptionCredentialConfigured(configured, for: .codex)
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
                do {
                    // 交由 token manager 保存完整 v2 记录 (credentialOrigin=mddd),
                    // 独立 token 链, 不再合并进旧整体账号库.
                    // 保留服务端 expires_in 和收到时刻, 按
                    // expires_in > JWT exp > 1 小时 计算过期时间.
                    try await self.codexTokenManager.storeLoginResult(
                        accountID: account.accountID,
                        email: account.email,
                        accessToken: account.accessToken,
                        refreshToken: account.refreshToken,
                        idToken: account.idToken,
                        expiresAt: CodexTokenExpiry.expiresAt(
                            from: CodexTokenResponse(
                                accessToken: account.accessToken,
                                refreshToken: account.refreshToken,
                                idToken: account.idToken,
                                expiresIn: account.expiresIn,
                                receivedAt: account.receivedAt
                            ),
                            jwtExp: CodexTokenExpiry.jwtExp(of: account.idToken)
                        )
                    )
                } catch {
                    self.codexDeviceLogin = nil
                    self.model.setSettingsError(
                        "Codex 凭证写入 Keychain 失败, 登录未完成"
                    )
                    return
                }
                self.publishCodexCredentialConfigured()
                self.publishCodexSummaryFromIndex()
                self.finishVerification(.codex, status: .ok)
                guard self.codexDeviceLogin != nil else { return }
                self.codexDeviceLogin?.stage = .succeeded
                // 成功状态短暂展示后收起
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.codexDeviceLogin = nil
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

    /// Antigravity: 从本机导入 (用户点击触发); 优先令牌文件,
    /// 其次 agy >= 1.1.8 的登录 Keychain 条目.
    func importAntigravityFromLocalFile() {
        let fileURL = homeURL.appendingPathComponent(
            ".gemini/antigravity-cli/antigravity-oauth-token"
        )
        let json: String
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let text = readCredentialFile(fileURL, usage: "Antigravity 令牌文件") else {
                return
            }
            json = text
        } else {
            guard let text = readAgyKeychainCredential() else {
                model.setSettingsError("未找到 Antigravity 登录态, 请先通过 Antigravity CLI 登录")
                return
            }
            json = text
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
    /// Codex 经 token manager 断开: 取消任务、删除全部 v2 记录, 不写第三方文件.
    func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        if id == .codex {
            Task { @MainActor in
                await self.removeCodexProvider()
            }
            return
        }
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
        model.setSettingsError(nil)
    }

    /// Codex 移除: 经 token manager 断开全部账号, 不写第三方文件.
    private func removeCodexProvider() async {
        do {
            let index = try codexStore.loadIndex()
            for entry in index.accounts {
                try await codexTokenManager.disconnect(accountID: entry.accountID)
            }
        } catch {
            model.setSettingsError(
                "Codex 凭证删除失败, 请在 Keychain 中手动检查"
            )
            return
        }
        publishCodexSummaryFromIndex()
        guard persistSubscription(.codex, mutate: {
            $0 = SubscriptionProviderConfiguration()
        }) else { return }
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

    /// 刷新 Antigravity 本机登录态可用性, 结果写入 model 供设置页渲染.
    /// 文件检查同步; Keychain 探测放后台队列 — 子进程 waitUntilExit 会泵 runloop,
    /// 在视图 body 内直接执行会与 AttributeGraph 事务重入导致崩溃.
    func refreshAntigravityLocalAvailability() {
        let fileExists = FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(
                    ".gemini/antigravity-cli/antigravity-oauth-token"
                ).path
        )
        if fileExists {
            model.setAntigravityLocalAvailable(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = self?.agyKeychainItemExists() ?? false
            DispatchQueue.main.async {
                self?.model.setAntigravityLocalAvailable(exists)
            }
        }
    }

    // MARK: - Antigravity Keychain 来源 (agy >= 1.1.8)

    /// agy >= 1.1.8 把 OAuth 令牌存进登录 Keychain (go-keyring), 不再写令牌文件.
    private static let agyKeychainService = "gemini"
    private static let agyKeychainAccount = "antigravity"

    /// 探测登录 Keychain 是否存在 agy 令牌条目 (不读密码数据, 不触发授权弹窗).
    private func agyKeychainItemExists() -> Bool {
        runSecurity(arguments: [
            "find-generic-password",
            "-s", Self.agyKeychainService,
            "-a", Self.agyKeychainAccount,
        ]) != nil
    }

    /// 读取并解码 agy Keychain 令牌 ("go-keyring-base64:" 前缀 + base64 JSON);
    /// 读取密码数据会触发系统钥匙串授权弹窗, 仅在用户点击导入时调用.
    private func readAgyKeychainCredential() -> String? {
        guard var raw = runSecurity(arguments: [
            "find-generic-password",
            "-s", Self.agyKeychainService,
            "-a", Self.agyKeychainAccount,
            "-w",
        ]) else {
            return nil
        }
        let prefix = "go-keyring-base64:"
        guard raw.hasPrefix(prefix) else {
            return raw
        }
        raw = String(raw.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: raw),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            model.setSettingsError("Antigravity Keychain 令牌解码失败")
            return nil
        }
        return text
    }

    /// 执行 /usr/bin/security, 退出码 0 返回 stdout (去首尾空白), 否则 nil.
    private func runSecurity(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
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
