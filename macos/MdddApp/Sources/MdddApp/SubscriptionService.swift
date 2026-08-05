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


/// 订阅额度 CRUD / 导入 / 验证 / 本机探测工作流.
/// 由 OnboardingCoordinator 持有并以同签名 façade 转发, Settings 调用点零变更.
@MainActor
final class SubscriptionService {
    /// 订阅 provider 展示顺序, 与配置持久化同步.
    private(set) var subscriptionProviderOrder: [SubscriptionProviderID] = [] {
        didSet { noteStateChange() }
    }
    /// Codex 设备码登录展示状态, nil 表示无进行中的流程.
    private(set) var codexDeviceLogin: DeviceLoginPresentation? {
        didSet { noteStateChange() }
    }

    private var codexLoginTask: Task<Void, Never>?

    private let model: AppModel
    private let configStore: OnboardingConfigurationStore?
    private let credentialStore: CredentialStore
    private let codexStore: CodexCredentialStore
    private let codexTokenManager: CodexTokenManager
    private let verifier: any DeepSeekCredentialVerifier
    private let homeURL: URL
    private let localProbe: LocalCredentialProbe
    private let ccSwitchImporter = CCSwitchVolcengineImporter()
    /// 状态变更时通知 Coordinator 转发 objectWillChange (Settings 观察 Coordinator).
    private var onStateChange: () -> Void = {}

    init(
        model: AppModel,
        configStore: OnboardingConfigurationStore?,
        credentialStore: CredentialStore,
        codexStore: CodexCredentialStore,
        codexTokenManager: CodexTokenManager,
        verifier: any DeepSeekCredentialVerifier,
        homeURL: URL,
        localProbe: LocalCredentialProbe
    ) {
        self.model = model
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.codexStore = codexStore
        self.codexTokenManager = codexTokenManager
        self.verifier = verifier
        self.homeURL = homeURL
        self.localProbe = localProbe
        let config = configStore?.load()
        migrateLegacyCredentials()
        publishSubscriptionState(from: config)
    }

    // MARK: - 旧凭证迁移

    /// 检测旧单条 Keychain 凭证, 迁移为 ProviderAccountStore 的 account-index + record.
    /// 迁移只读取不删除旧键; 成功后清理旧键.
    /// 实现位于 MdddOnboardingCore.ProviderAccountStore.migrateLegacyAccountsIfNeeded,
    /// 与 CollectorRunInput 共享, 避免在两处维护凭证格式逻辑.
    private func migrateLegacyCredentials() {
        for provider in SubscriptionProviderID.allCases where provider != .codex {
            let store = ProviderAccountStore(provider: provider, credentialStore: credentialStore)
            let migrated = (try? store.migrateLegacyAccountsIfNeeded(
                legacyKeys: ProviderAccountKeys.legacyKeys(for: provider)
            )) ?? false
            if migrated {
                for key in ProviderAccountKeys.legacyKeys(for: provider) {
                    try? credentialStore.deleteCredential(forAccount: key)
                }
            }
        }
    }

    /// Coordinator 在自身 init 完成后挂载 objectWillChange 转发.
    func bindStateChange(_ handler: @escaping () -> Void) {
        onStateChange = handler
    }

    private func noteStateChange() {
        onStateChange()
    }

    /// 从配置与 Keychain 恢复订阅 provider 展示状态 (全量刷新).
    /// Keychain 只判断凭证是否存在, 凭证值不进入 UI 状态.
    /// 仅在 init / add / remove 等需要全量重建时调用.
    private func publishSubscriptionState(from config: OnboardingConfiguration?) {
        var providers: [SubscriptionProviderID: SubscriptionProviderConfiguration] = [:]
        for (key, value) in config?.subscriptionProviders ?? [:] {
            if let id = SubscriptionProviderID(rawValue: key) {
                providers[id] = value
            }
        }
        model.setSubscriptionProviders(providers)
        subscriptionProviderOrder = reconcileProviderOrder(
        from: config, configured: providers
        )
        model.setSubscriptionProviderOrder(subscriptionProviderOrder)
        for id in SubscriptionProviderID.allCases {
            model.setSubscriptionCredentialConfigured(
            credentialConfigured(id), for: id
            )
        }
        publishCodexSummaryFromIndex()
    }

    /// 轻量刷新: 只更新 providers 字典与顺序, 单个 provider 凭证状态.
    /// persistSubscription 调用, 避免 7 次 Keychain 读取.
    private func publishSubscriptionProviders(from config: OnboardingConfiguration?) {
        var providers: [SubscriptionProviderID: SubscriptionProviderConfiguration] = [:]
        for (key, value) in config?.subscriptionProviders ?? [:] {
            if let id = SubscriptionProviderID(rawValue: key) {
                providers[id] = value
            }
        }
        model.setSubscriptionProviders(providers)
        subscriptionProviderOrder = reconcileProviderOrder(
        from: config, configured: providers
        )
        model.setSubscriptionProviderOrder(subscriptionProviderOrder)
        publishAllProviderAccountSummaries()
        publishCodexSummaryFromIndex()
    }

    /// 发布全部非 Codex provider 的多账号摘要到 AppModel.
    private func publishAllProviderAccountSummaries() {
        for provider in SubscriptionProviderID.allCases where provider != .codex {
            let store = ProviderAccountStore(provider: provider, credentialStore: credentialStore)
            let summaries = (try? store.summaries()) ?? []
            model.setProviderAccountSummaries(summaries, for: provider)
        }
    }

    /// 对齐 provider 顺序与实际配置: 移除已删除的, 追加新增的 (按 allCases 序).
    /// config 顺序为 nil 时全部走 allCases 追加, 语义等同旧版默认顺序.
    private func reconcileProviderOrder(
    from config: OnboardingConfiguration?,
    configured: [SubscriptionProviderID: SubscriptionProviderConfiguration]
    ) -> [SubscriptionProviderID] {
        let configuredIDs = Set(configured.keys)
        let rawOrder = config?.subscriptionProviderOrder ?? []
        var order = rawOrder.compactMap { SubscriptionProviderID(rawValue: $0) }
        .filter { configuredIDs.contains($0) }
        let inOrder = Set(order)
        for id in SubscriptionProviderID.allCases {
            if configuredIDs.contains(id) && !inOrder.contains(id) {
                order.append(id)
            }
        }
        return order
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

    /// 判断 provider 是否完整配置. 按 `ProviderRegistry` 的 `ConfiguredRule` 求值:
    /// Codex 完整 record; Claude/Grok 应用 Keychain 优先否则本机探测;
    /// 其余 provider 全部 credentialAccounts 非空.
    private func credentialConfigured(_ id: SubscriptionProviderID) -> Bool {
        let descriptor = ProviderRegistry.descriptor(for: id)
        var accountValues: [String: String] = [:]
        for account in descriptor.credentialAccounts {
            if let value = try? credentialStore.loadCredential(forAccount: account),
            !value.isEmpty {
                accountValues[account] = value
            }
        }
        let codexConfigured: Bool
        if descriptor.configuredRule == .codexHasConfiguredRecords {
            // metadata-only 不算已配置; 索引状态不作数 (fail-closed).
            codexConfigured = (try? codexStore.hasConfiguredCredentials()) ?? false
        } else {
            codexConfigured = false
        }
        return ConfiguredRuleEvaluator.evaluate(
        descriptor.configuredRule,
        accounts: descriptor.credentialAccounts,
        inputs: ConfiguredRuleEvaluator.Inputs(
            accountValues: accountValues,
            codexHasConfiguredRecords: codexConfigured,
            claudeLocalAvailable: model.claudeLocalAvailable,
            grokLocalAvailable: model.grokLocalAvailable,
            now: Date()
        )
        )
    }

    /// 持久化单个订阅 provider 的非敏感配置并发布.
    /// 保存失败发布错误并返回 false (fail-closed), 不在会话内假装成功.
    /// 只刷新被修改的 provider 凭证状态, 不全量扫描 Keychain.
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
        publishSubscriptionProviders(from: config)
        model.setSubscriptionCredentialConfigured(
        credentialConfigured(id), for: id
        )
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

    // MARK: - Claude / Grok 手动导入 (Phase 2/3)

    /// Claude: 从本机 CLI 凭证文件只读导入.
    func importClaudeFromLocal() {
        let fileURL = ClaudeCLICredentialImporter.defaultFileURL(homeURL)
        switch ClaudeCLICredentialImporter().importCredentials(fileURL: fileURL) {
            case .failure(let error):
            model.setSettingsError("Claude 本机凭证导入失败: \(error.description)")
            case .success(let json):
            saveClaudeOAuthJSON(json)
        }
    }

    /// Claude: 引导粘贴导入 (纯 token 或 claudeAiOauth 同构 JSON).
    func importClaudeFromPaste(_ paste: String) {
        switch ClaudePasteParser.parse(paste) {
            case .failure(let error):
            model.setSettingsError("Claude 凭证解析失败: \(error.description)")
            case .success(let json):
            saveClaudeOAuthJSON(json)
        }
    }

    /// Claude: 统一保存入口 (evaluator 判定 -> Keychain -> 状态迁移).
    private func saveClaudeOAuthJSON(_ json: String) {
        let status = SubscriptionCredentialEvaluator.claudeStatus(
        of: json, now: Date()
        )
        switch status {
            case .missing, .malformed:
            model.setSettingsError("Claude 凭证无效, 请重新粘贴")
            return
            case .valid:
            do {
                try credentialStore.saveCredential(
                json, forAccount: SubscriptionCredentialAccount.claudeOAuth
                )
            } catch {
                model.setSettingsError("Claude 凭证写入 Keychain 失败")
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .claude)
            finishVerification(.claude, status: .ok)
            case .expired:
            // 过期凭证保留粘贴入口, 提示重新登录 (不写入 Keychain)
            model.setSettingsError("Claude 登录已过期, 请粘贴新凭证")
            finishVerification(.claude, status: .needsRelogin)
        }
        refreshOfficialLocalAvailability()
    }

    /// Grok: 从本机 CLI 凭证文件只读导入.
    func importGrokFromLocal() {
        let fileURL = GrokCLICredentialImporter.defaultFileURL(homeURL)
        switch GrokCLICredentialImporter().importCredentials(fileURL: fileURL) {
            case .failure(let error):
            model.setSettingsError("Grok 本机凭证导入失败: \(error.description)")
            case .success(let json):
            saveGrokOAuthJSON(json)
        }
    }

    /// Grok: 引导粘贴导入 (纯 token 或 auth.json 同构 JSON).
    func importGrokFromPaste(_ paste: String) {
        switch GrokPasteParser.parse(paste) {
            case .failure(let error):
            model.setSettingsError("Grok 凭证解析失败: \(error.description)")
            case .success(let json):
            saveGrokOAuthJSON(json)
        }
    }

    /// Grok: 统一保存入口 (evaluator 判定 -> Keychain -> 状态迁移).
    private func saveGrokOAuthJSON(_ json: String) {
        let status = SubscriptionCredentialEvaluator.grokStatus(
        of: json, now: Date()
        )
        switch status {
            case .missing, .malformed:
            model.setSettingsError("Grok 凭证无效, 请重新粘贴")
            return
            case .valid:
            do {
                try credentialStore.saveCredential(
                json, forAccount: SubscriptionCredentialAccount.grokOAuth
                )
            } catch {
                model.setSettingsError("Grok 凭证写入 Keychain 失败")
                return
            }
            model.setSubscriptionCredentialConfigured(true, for: .grok)
            finishVerification(.grok, status: .ok)
            case .expired:
            // 过期凭证保留粘贴入口, 提示重新登录 (不写入 Keychain)
            model.setSettingsError("Grok 登录已过期, 请粘贴新凭证")
            finishVerification(.grok, status: .needsRelogin)
        }
        refreshOfficialLocalAvailability()
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
        if localProbe.antigravityTokenFileExists() {
            guard let text = readCredentialFile(fileURL, usage: "Antigravity 令牌文件") else {
                return
            }
            json = text
        } else {
            switch localProbe.readAgyKeychainCredential() {
                case .notFound:
                model.setSettingsError(
                "未找到 Antigravity 登录态, 请先通过 Antigravity CLI 登录"
                )
                return
                case .decodeFailed:
                model.setSettingsError("Antigravity Keychain 令牌解码失败")
                return
                case .decoded(let text):
                json = text
            }
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

    /// 手动添加 provider (Phase 4): 持久化空配置条目, 使"已添加"跨会话保持.
    /// 幂等; 已存在条目时不覆盖.
    func addSubscriptionProvider(_ id: SubscriptionProviderID) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法添加订阅")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        guard config.subscriptionProviders[id.rawValue] == nil else {
            return // 已添加, 幂等
        }
        config.subscriptionProviders[id.rawValue] = SubscriptionProviderConfiguration()
        if var order = config.subscriptionProviderOrder {
            if !order.contains(id.rawValue) {
                order.append(id.rawValue)
            }
            config.subscriptionProviderOrder = order
        }
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("订阅添加保存失败, 重启后可能恢复")
            return
        }
        publishSubscriptionState(from: config)
    }

    /// 移除 provider: 删除其全部 Keychain 凭证并从配置中移除条目.
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
        // Phase 4: 移除配置条目 (非重置), 使 provider 回到"未添加"状态
        guard removeSubscriptionFromConfig(id) else { return }
        model.setSettingsError(nil)
    }

    // MARK: - 多账号管理 (Phase 2)

    /// 当前 provider 的账号摘要列表 (非 Codex). Codex 走 codexAccountStatuses.
    func accountSummaries(for id: SubscriptionProviderID) -> [ProviderAccountSummary] {
        guard id != .codex else { return [] }
        let store = ProviderAccountStore(provider: id, credentialStore: credentialStore)
        return (try? store.summaries()) ?? []
    }

    /// 移除单个账号: 删除 per-account record + index 条目.
    /// 移除后若 provider 无任何账号, 保留 provider 配置条目 (用户可再添加).
    func removeAccount(accountID: String, from id: SubscriptionProviderID) {
        let store = ProviderAccountStore(provider: id, credentialStore: credentialStore)
        do {
            try store.removeAccount(accountID: accountID)
            publishAllProviderAccountSummaries()
            model.setSubscriptionCredentialConfigured(
                credentialConfigured(id), for: id
            )
            model.setSettingsError(nil)
        } catch {
            model.setSettingsError(
                "\(id.displayName) 账号移除失败, 请在 Keychain 中手动检查"
            )
        }
    }

    /// 更新账号授权状态 (验证失败标记 needsReauthorization, 成功后 connected).
    func updateAccountAuthorizationState(
        accountID: String,
        from id: SubscriptionProviderID,
        state: ProviderAccountAuthorizationState
    ) {
        let store = ProviderAccountStore(provider: id, credentialStore: credentialStore)
        do {
            try store.updateAuthorizationState(state, for: accountID)
            publishAllProviderAccountSummaries()
        } catch {
            model.setSettingsError("\(id.displayName) 账号状态更新失败")
        }
    }

    /// 从配置删除 provider 条目; 失败发布错误并返回 false.
    private func removeSubscriptionFromConfig(_ id: SubscriptionProviderID) -> Bool {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法移除订阅")
            return false
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        guard config.subscriptionProviders.removeValue(forKey: id.rawValue) != nil else {
            return true // 本来就不在配置中, 视为成功
        }
        if var order = config.subscriptionProviderOrder {
            order.removeAll { $0 == id.rawValue }
            config.subscriptionProviderOrder = order
        }
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("订阅移除保存失败, 重启后可能恢复")
            return false
        }
        publishSubscriptionState(from: config)
        return true
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

    /// 用户调整订阅 provider 展示顺序: 持久化并发布.
    /// 顺序同时作用于设置页排列与面板用量卡展示.
    func setSubscriptionProviderOrder(_ order: [SubscriptionProviderID]) {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存订阅顺序")
            return
        }
        var config = configStore.load() ?? OnboardingConfiguration()
        config.subscriptionProviderOrder = order.map(\.rawValue)
        do {
            try configStore.save(config)
        } catch {
            model.setSettingsError("订阅顺序保存失败")
            return
        }
        subscriptionProviderOrder = order
        model.setSubscriptionProviderOrder(order)
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

    // MARK: - 订阅额度本机文件检测 (供设置页条件渲染; 转发 LocalCredentialProbe)

    func kimiLocalTokensFileExists() -> Bool {
        localProbe.kimiLocalTokensFileExists()
    }

    func codexCLIAuthFileExists() -> Bool {
        localProbe.codexCLIAuthFileExists()
    }

    func codexCCAccountsFileExists() -> Bool {
        localProbe.codexCCAccountsFileExists()
    }

    func ccSwitchDatabaseExists() -> Bool {
        localProbe.ccSwitchDatabaseExists()
    }

    /// 刷新 Antigravity 本机登录态可用性, 结果写入 model 供设置页渲染.
    /// 文件检查同步; Keychain 探测放后台队列 — 子进程 waitUntilExit 会泵 runloop,
    /// 在视图 body 内直接执行会与 AttributeGraph 事务重入导致崩溃.
    func refreshAntigravityLocalAvailability() {
        if localProbe.antigravityTokenFileExists() {
            model.setAntigravityLocalAvailable(true)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = self?.localProbe.agyKeychainItemExists() ?? false
            DispatchQueue.main.async {
                self?.model.setAntigravityLocalAvailable(exists)
            }
        }
    }

    // MARK: - Claude / Grok 本机登录态检测 (实时只读, 不导入不回写)

    /// 刷新 Claude / Grok 本机登录态可用性, 结果写入 model 供设置页渲染,
    /// 并经 `credentialConfigured` 重算 configured (应用 Keychain 优先于本机).
    /// Grok auth.json 解析同步; Claude Keychain 探测放后台队列
    /// (子进程 waitUntilExit 会泵 runloop, 同 Antigravity 的重入崩溃规避).
    func refreshOfficialLocalAvailability() {
        let grokAvailable = localProbe.grokLocalAuthAvailable()
        model.setGrokLocalAvailable(grokAvailable)
        model.setSubscriptionCredentialConfigured(
        credentialConfigured(.grok), for: .grok
        )

        if localProbe.claudeCredentialsFileValid() {
            model.setClaudeLocalAvailable(true)
            model.setSubscriptionCredentialConfigured(
            credentialConfigured(.claude), for: .claude
            )
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let exists = self?.localProbe.claudeKeychainItemExists() ?? false
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.setClaudeLocalAvailable(exists)
                self.model.setSubscriptionCredentialConfigured(
                self.credentialConfigured(.claude), for: .claude
                )
            }
        }
    }

    /// 已配置且启用的订阅 provider 列表, 供统一授权摘要展示.
    /// 与 CollectorActivationGate 的 hasConfiguredSubscriptionProvider 语义一致.
    var enabledConfiguredSubscriptionProviders: [SubscriptionProviderID] {
        SubscriptionProviderID.allCases.filter { id in
            (model.subscriptionProviders[id]?.enabled ?? false)
            && (model.subscriptionCredentialConfigured[id] ?? false)
        }
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
}
