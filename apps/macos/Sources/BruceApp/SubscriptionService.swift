import AppKit
import Foundation
import BruceAppCore
import BruceOnboardingCore

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

/// 启动阶段的 Bruce Keychain 准备结果. 不携带账号、路径或凭证内容.
enum KeychainPreparationResult: Equatable {
    case ready
    case notConfigured
    case blocked
    case failed
}


/// 订阅额度 CRUD / 导入 / 验证 / 本机探测工作流.
/// 由 OnboardingCoordinator 持有并以同签名 façade 转发, Settings 调用点零变更.
@MainActor
final class SubscriptionService {
    /// 订阅 provider 展示顺序, 与配置持久化同步.
    var subscriptionProviderOrder: [SubscriptionProviderID] = [] {
        didSet { noteStateChange() }
    }
    /// Codex 设备码登录展示状态, nil 表示无进行中的流程.
    var codexDeviceLogin: DeviceLoginPresentation? {
        didSet { noteStateChange() }
    }

    var codexLoginTask: Task<Void, Never>?

    let model: AppModel
    let configStore: OnboardingConfigurationStore?
    let credentialStore: CredentialStore
    let codexStore: CodexCredentialStore
    let codexTokenManager: CodexTokenManager
    let keychainAccessController: KeychainAccessController
    let verifier: ProviderConnectionVerifier
    let homeURL: URL
    let localProbe: LocalCredentialProbe
    /// 启动阶段是否允许读取 Bruce 自有 Keychain.
    /// 未配置时只发布配置文件中的非敏感状态, 禁止任何凭证迁移/摘要读取.
    var keychainAccessConfigured: Bool
    let ccSwitchImporter = CCSwitchVolcengineImporter()
    /// ProviderAccountStore 实例缓存, 避免 11 处重复创建和 Keychain 读取.
    var accountStoreCache: [SubscriptionProviderID: ProviderAccountStore] = [:]
    /// 状态变更时通知 Coordinator 转发 objectWillChange (Settings 观察 Coordinator).
    var onStateChange: () -> Void = {}
    /// 验证通过 (status ok) 后的回调, 由 Coordinator 绑定为定向刷新 (C020):
    /// 使新添加/重新配置的订阅无需等待定时刷新即出现在仪表盘.
    var onProviderVerified: ((SubscriptionProviderID) -> Void)?
    /// 账号重命名后的回调, 由 Coordinator 绑定为定向刷新 (T18):
    /// 让 collector 重新注入 display_name, 仪表盘账号子卡即时显示新名称.
    var onAccountRenamed: ((SubscriptionProviderID) -> Void)?

    /// 按 provider 获取缓存的 ProviderAccountStore, 不存在时创建并缓存.
    func accountStore(for id: SubscriptionProviderID) -> ProviderAccountStore {
        if let cached = accountStoreCache[id] { return cached }
        let store = ProviderAccountStore(provider: id, credentialStore: credentialStore)
        accountStoreCache[id] = store
        return store
    }

    init(
        model: AppModel,
        configStore: OnboardingConfigurationStore?,
        credentialStore: CredentialStore,
        codexStore: CodexCredentialStore,
        codexTokenManager: CodexTokenManager,
        keychainAccessController: KeychainAccessController,
        verifier: ProviderConnectionVerifier,
        homeURL: URL,
        localProbe: LocalCredentialProbe
    ) {
        self.model = model
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.codexStore = codexStore
        self.codexTokenManager = codexTokenManager
        self.keychainAccessController = keychainAccessController
        self.verifier = verifier
        self.homeURL = homeURL
        self.localProbe = localProbe
        let config = configStore?.load()
        self.keychainAccessConfigured = config?.keychainAccessConfigured ?? false
        // 初始化阶段只发布配置文件中的非敏感状态, 不迁移、不读取 Keychain.
        publishSubscriptionState(from: config, readKeychain: false)
    }

    // MARK: - 旧凭证迁移

    /// 检测旧单条 Keychain 凭证, 迁移为 ProviderAccountStore 的 account-index + record.
    /// 迁移只读取不删除旧键; 成功后清理旧键.
    /// 实现位于 BruceOnboardingCore.ProviderAccountStore.migrateLegacyAccountsIfNeeded,
    /// 与 CollectorRunInput 共享, 避免在两处维护凭证格式逻辑.
    func migrateLegacyCredentials(
        enabledProviders: Set<SubscriptionProviderID>
    ) throws {
        for provider in enabledProviders where provider != .codex {
            let store = accountStore(for: provider)
            let migrated = try store.migrateLegacyAccountsIfNeeded(
                legacyKeys: ProviderAccountKeys.legacyKeys(for: provider)
            )
            if migrated {
                for key in ProviderAccountKeys.legacyKeys(for: provider) {
                    try credentialStore.deleteCredential(
                        forAccount: key,
                        intent: .automatic
                    )
                }
            }
        }
    }

    /// Coordinator 在自身 init 完成后挂载 objectWillChange 转发.
    func bindStateChange(_ handler: @escaping () -> Void) {
        onStateChange = handler
    }

    /// 主动配置 Bruce 自有 Keychain 项目的访问 ACL.
    /// 不返回或保存任何密码, 只返回本次处理的项目数.
    func configureKeychainAccess() throws -> Int {
        try credentialStore.configureKeychainAccess()
    }

    /// 配置完成后才打开 Keychain 读取边界, 并补做一次迁移与状态发布.
    /// 关闭时只清空内存中的凭证摘要, 不触碰 Keychain.
    func setKeychainAccessConfigured(_ configured: Bool) {
        guard keychainAccessConfigured != configured else { return }
        keychainAccessConfigured = configured
        publishSubscriptionState(
            from: configStore?.load(),
            readKeychain: false
        )
    }

    /// 在 Scheduler 启动前执行一次受控的 Keychain 准备.
    /// 只处理配置中 enabled 的 Provider; 任何自动访问错误都 fail-closed.
    func prepareKeychainBackedStartup() -> KeychainPreparationResult {
        guard keychainAccessConfigured else { return .notConfigured }
        guard keychainAccessController.allows(
            source: .bruceStore,
            intent: .automatic
        ) else {
            return keychainAccessController.policy.state == .blocked
                ? .blocked : .notConfigured
        }

        let config = configStore?.load() ?? OnboardingConfiguration()
        let enabledProviders: Set<SubscriptionProviderID> = Set(
            config.subscriptionProviders.compactMap { rawID, entry in
                guard entry.enabled else { return nil }
                return SubscriptionProviderID(rawValue: rawID)
            }
        )

        do {
            try migrateLegacyCredentials(enabledProviders: enabledProviders)
            try readProviderAccountSummaries(
                enabledProviders: enabledProviders
            )
            for provider in SubscriptionProviderID.allCases {
                if enabledProviders.contains(provider) {
                    model.setSubscriptionCredentialConfigured(
                        credentialConfigured(provider),
                        for: provider
                    )
                } else {
                    model.setSubscriptionCredentialConfigured(false, for: provider)
                    if provider != .codex {
                        model.setProviderAccountSummaries([], for: provider)
                    }
                }
            }
            if enabledProviders.contains(.codex) {
                publishCodexSummaryFromIndex()
            } else {
                model.setCodexAccountSummary(nil)
            }
            return .ready
        } catch let error as KeychainError {
            switch error {
            case .notConfigured:
                return .notConfigured
            case .accessBlocked:
                keychainAccessController.markBlocked()
                return .blocked
            case .saveFailed, .loadFailed, .deleteFailed:
                keychainAccessController.markBlocked()
                return .failed
            }
        } catch {
            keychainAccessController.markBlocked()
            return .failed
        }
    }

    func noteStateChange() {
        onStateChange()
    }

    /// 从配置与 Keychain 恢复订阅 provider 展示状态 (全量刷新).
    /// Keychain 只判断凭证是否存在, 凭证值不进入 UI 状态.
    /// 仅在 init / add / remove 等需要全量重建时调用.
    func publishSubscriptionState(
        from config: OnboardingConfiguration?,
        readKeychain: Bool = true
    ) {
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
        guard keychainAccessConfigured, readKeychain else {
            clearKeychainBackedState()
            return
        }
        // 先发布全部非 Codex summaries (每个 provider 一次 loadIndex),
        // 再从已发布 summaries 推导 credentialConfigured, 避免逐个实时读 Keychain.
        let enabledProviders = enabledProviderIDs(from: config)
        publishAllProviderAccountSummaries(enabledProviders: enabledProviders)
        publishKeychainCredentialStates(enabledProviders: enabledProviders)
    }

    /// 轻量刷新: 只更新 providers 字典与顺序, 单个 provider 凭证状态.
    /// persistSubscription 调用, 避免 7 次 Keychain 读取.
    func publishSubscriptionProviders(from config: OnboardingConfiguration?) {
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
        guard keychainAccessConfigured else {
            clearKeychainBackedState()
            return
        }
        let enabledProviders = enabledProviderIDs(from: config)
        publishAllProviderAccountSummaries(enabledProviders: enabledProviders)
        publishKeychainCredentialStates(enabledProviders: enabledProviders)
    }

    /// 未完成 Keychain 配置时的 fail-closed 内存状态.
    func clearKeychainBackedState() {
        for provider in SubscriptionProviderID.allCases where provider != .codex {
            model.setProviderAccountSummaries([], for: provider)
        }
        for provider in SubscriptionProviderID.allCases {
            model.setSubscriptionCredentialConfigured(false, for: provider)
        }
        model.setCodexAccountSummary(nil)
    }

    /// 发布全部非 Codex provider 的多账号摘要到 AppModel.
    /// 同时校正存量账号: 凭证存在但状态为 needsReauthorization 的账号
    /// 标记为 connected (修复历史版本 upsert 未置 connected 的问题).
    func publishAllProviderAccountSummaries(
        enabledProviders: Set<SubscriptionProviderID>
    ) {
        guard keychainAccessConfigured,
              keychainAccessController.allows(
                  source: .bruceStore,
                  intent: .automatic
              ) else {
            clearKeychainBackedState()
            return
        }
        do {
            try readProviderAccountSummaries(enabledProviders: enabledProviders)
        } catch {
            keychainAccessController.markBlocked()
            clearKeychainBackedState()
        }
    }

    /// 只为启用的 Provider 计算凭证状态, 禁止对停用 Provider 做回退读取.
    func publishKeychainCredentialStates(
        enabledProviders: Set<SubscriptionProviderID>
    ) {
        guard keychainAccessConfigured,
              keychainAccessController.allows(
                  source: .bruceStore,
                  intent: .automatic
              ) else {
            clearKeychainBackedState()
            return
        }

        for provider in SubscriptionProviderID.allCases {
            if enabledProviders.contains(provider) {
                model.setSubscriptionCredentialConfigured(
                    credentialConfigured(provider),
                    for: provider
                )
            } else {
                model.setSubscriptionCredentialConfigured(false, for: provider)
                if provider != .codex {
                    model.setProviderAccountSummaries([], for: provider)
                }
            }
        }

        if enabledProviders.contains(.codex) {
            publishCodexSummaryFromIndex()
        } else {
            model.setCodexAccountSummary(nil)
        }
    }

    func readProviderAccountSummaries(
        enabledProviders: Set<SubscriptionProviderID>
    ) throws {
        guard keychainAccessConfigured else {
            clearKeychainBackedState()
            return
        }
        for provider in enabledProviders where provider != .codex {
            let store = accountStore(for: provider)
            let index = try store.loadIndex()
            // 校正存量状态: 凭证存在但状态为 needsReauthorization 的账号标记为 connected
            // (修复历史版本 upsert 未置 connected 的问题). 校正后直接从内存 index 构造
            // summaries, 不二次读 Keychain.
            var correctedSummaries = store.summaries(from: index)
            for i in correctedSummaries.indices {
                if correctedSummaries[i].authorizationState == .needsReauthorization {
                    if let record = try store.loadRecord(for: correctedSummaries[i].accountID),
                       !record.credentialJSON.isEmpty {
                        try store.updateAuthorizationState(
                            .connected,
                            for: correctedSummaries[i].accountID
                        )
                        correctedSummaries[i] = ProviderAccountSummary(
                            accountID: correctedSummaries[i].accountID,
                            displayName: correctedSummaries[i].displayName,
                            authorizationState: .connected
                        )
                    }
                }
            }
            model.setProviderAccountSummaries(correctedSummaries, for: provider)
        }
    }

    func enabledProviderIDs(
        from config: OnboardingConfiguration?
    ) -> Set<SubscriptionProviderID> {
        Set(
            config?.subscriptionProviders.compactMap { rawID, entry in
                guard entry.enabled else { return nil }
                return SubscriptionProviderID(rawValue: rawID)
            } ?? []
        )
    }

    /// 对齐 provider 顺序与实际配置: 移除已删除的, 追加新增的 (按 allCases 序).
    /// config 顺序为 nil 时全部走 allCases 追加, 语义等同旧版默认顺序.
    func reconcileProviderOrder(
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
    func publishCodexSummaryFromIndex() {
        guard keychainAccessConfigured else {
            model.setCodexAccountSummary(nil)
            return
        }
        guard let index = try? codexStore.loadIndex() else {
            model.setCodexAccountSummary(nil)
            return
        }
        let entries = index.accounts.sorted { $0.accountID < $1.accountID }
        let prefixes = entries.map { entry -> String in
            if let customName = entry.customName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !customName.isEmpty {
                return customName
            }
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
    func credentialConfigured(_ id: SubscriptionProviderID) -> Bool {
        guard keychainAccessConfigured else { return false }
        if id == .codex {
            return legacyCredentialConfigured(id)
        }
        // 优先用已发布的 summaries 判断 (publishAllProviderAccountSummaries 已发布);
        // 有 connected 账号即 true, 避免逐个实时读 Keychain.
        if let summaries = model.providerAccountSummaries[id], !summaries.isEmpty {
            return summaries.contains { $0.authorizationState == .connected }
        }
        // summaries 为空: 回退到 Keychain 检查 (迁移前或尚未发布).
        let store = accountStore(for: id)
        if let index = try? store.loadIndex(), !index.accounts.isEmpty {
            return (try? store.hasConnectedAccount()) ?? false
        }
        return legacyCredentialConfigured(id)
    }

    /// 旧单条 Keychain 键判定 (迁移前兼容).
    func legacyCredentialConfigured(_ id: SubscriptionProviderID) -> Bool {
        let descriptor = ProviderRegistry.descriptor(for: id)
        var accountValues: [String: String] = [:]
        for account in descriptor.credentialAccounts {
            if let value = try? credentialStore.loadCredential(
                forAccount: account,
                intent: .automatic
            ),
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
    func persistSubscription(
    _ id: SubscriptionProviderID,
    mutate: (inout SubscriptionProviderConfiguration) -> Void
    ) -> Bool {
        guard let configStore else {
            model.setSettingsError("配置存储不可用, 无法保存订阅配置", for: id)
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
            model.setSettingsError("\(id.displayName) 订阅配置保存失败", for: id)
            return false
        }
        publishSubscriptionProviders(from: config)
        return true
    }

    // MARK: - 多账号凭证写入 (统一路径)

    /// 把单个账号的凭证写入 ProviderAccountStore (upsert) 并标记 connected.
    /// 所有非 Codex provider 的保存/导入都走这里, 确保账号列表可见且状态正确.
    /// T18: 新建账号的默认名由 `ProviderAccountNaming` 统一生成 («账号 N»);
    /// 已存在账号由 `upsertAccount` 保留自定义名称, 重复粘贴不会覆盖用户命名.
    /// 返回是否写入成功 (调用方报错).
    @discardableResult
    func saveProviderAccountCredential(
        for provider: SubscriptionProviderID,
        accountID: String,
        credentialJSON: String,
        stepFunGlobal: Bool = false
    ) -> Bool {
        let store = accountStore(for: provider)
        do {
            let displayName = try store.makeDefaultDisplayName(
                stepFunGlobal: stepFunGlobal
            )
            try store.upsertAccount(
                accountID: accountID,
                displayName: displayName,
                credentialJSON: credentialJSON
            )
            // 写入成功后标记 connected, 否则账号列表会一直显示"需要重新登录"
            // (upsert 新增默认 needsReauthorization, 更新保留原状态).
            try store.updateAuthorizationState(.connected, for: accountID)
            return true
        } catch {
            model.setSettingsError(
                "\(provider.displayName) 凭证写入本机凭据文件失败", for: provider
            )
            return false
        }
    }

    /// 验证完成后统一收尾: 写状态迁移, 失败原因进入设置错误提示.
    func finishVerification(
    _ id: SubscriptionProviderID,
    status: SubscriptionVerificationStatus
    ) {
        let now = ISO8601DateFormatter().string(from: Date())
        guard persistSubscription(id, mutate: {
            $0 = $0.applyingVerification(status, verifiedAt: now)
        }) else { return }
        switch status {
            case .ok:
            model.setSettingsError(nil, for: id)
            // C020: 验证通过即请求该 Provider 定向刷新, 新配置订阅无需
            // 等待下一次定时刷新即可出现在仪表盘; 失败/需重登不触发.
            onProviderVerified?(id)
            case .failed(let reason):
            model.setSettingsError("\(id.displayName) 验证失败: \(reason)", for: id)
            case .needsRelogin:
            model.setSettingsError("\(id.displayName) 需要重新登录", for: id)
            case .none:
            break
        }
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
                try credentialStore.deleteCredential(
                    forAccount: account,
                    intent: .userInitiated
                )
            }
            let store = accountStore(for: id)
            try? store.removeAllAccounts()
            model.setProviderAccountSummaries([], for: id)
        } catch {
            model.setSettingsError(
                "\(id.displayName) 凭证删除失败, 请检查本机凭据文件 (~/Library/Application Support/Bruce/credentials.json)", for: id
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
        guard keychainAccessConfigured, id != .codex else { return [] }
        let store = accountStore(for: id)
        return (try? store.summaries()) ?? []
    }

    /// 移除单个账号: 删除 per-account record + index 条目.
    /// 移除后若 provider 无任何账号, 保留 provider 配置条目 (用户可再添加).
    func removeAccount(accountID: String, from id: SubscriptionProviderID) {
        if id == .codex {
            model.setBusySubscription(true, for: .codex)
            Task { @MainActor in
                await self.removeCodexAccount(accountID: accountID)
            }
            return
        }
        let store = accountStore(for: id)
        do {
            try store.removeAccount(accountID: accountID)
            let remaining = (try? store.summaries()) ?? []
            model.setProviderAccountSummaries(remaining, for: id)
            publishAllProviderAccountSummaries(
                enabledProviders: enabledProviderIDs(from: configStore?.load())
            )
            model.setSubscriptionCredentialConfigured(
                credentialConfigured(id), for: id
            )
            model.setSettingsError(nil)
        } catch {
            model.setSettingsError(
                "\(id.displayName) 账号移除失败, 请检查本机凭据文件 (~/Library/Application Support/Bruce/credentials.json)", for: id
            )
        }
    }

    /// 重命名账号 (T18). 只编辑标签; Provider 前缀、accountID 与凭证保持不变.
    /// 空标签表示恢复默认名 («账号 N», Codex 回落到邮箱前缀).
    func renameAccount(
        accountID: String,
        from id: SubscriptionProviderID,
        label rawLabel: String
    ) {
        if id == .codex {
            renameCodexAccount(accountID: accountID, label: rawLabel)
            return
        }
        let store = accountStore(for: id)
        do {
            let index = try store.loadIndex()
            guard let entry = index.entry(for: accountID) else {
                model.setSettingsError(
                    "\(id.displayName) 账号不存在, 未执行重命名", for: id
                )
                return
            }
            let stepFunGlobal = id == .stepfun
                && Self.isStepFunGlobal(
                    displayName: entry.displayName,
                    credentialJSON: (try? store.loadRecord(for: accountID))?.credentialJSON
                )
            let newDisplayName: String
            let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                newDisplayName = ProviderAccountNaming.defaultDisplayName(
                    for: id,
                    existingDisplayNames: index.accounts.map(\.displayName),
                    stepFunGlobal: stepFunGlobal,
                    excludingDisplayName: entry.displayName
                )
            } else {
                let label = try ProviderAccountNaming.validateLabel(trimmed)
                let candidate = ProviderAccountNaming.compose(
                    provider: id,
                    label: label,
                    stepFunGlobal: stepFunGlobal
                )
                guard ProviderAccountNaming.fitsCollectorLimit(candidate) else {
                    throw ProviderAccountNamingError.tooLong
                }
                guard !ProviderAccountNaming.isDuplicate(
                    candidate,
                    provider: id,
                    existingDisplayNames: index.accounts.map(\.displayName),
                    excludingDisplayName: entry.displayName
                ) else {
                    throw ProviderAccountNamingError.duplicate
                }
                newDisplayName = candidate
            }
            try store.renameAccount(
                accountID: accountID,
                displayName: newDisplayName
            )
            model.setProviderAccountSummaries(try store.summaries(), for: id)
            model.setSettingsError(nil, for: id)
            onAccountRenamed?(id)
        } catch let error as ProviderAccountNamingError {
            model.setSettingsError(error.message, for: id)
        } catch {
            model.setSettingsError(
                "\(id.displayName) 账号重命名失败, 请检查本机凭据文件", for: id
            )
        }
    }

    /// Codex 重命名: customName 为 nil 时恢复默认 (邮箱前缀 / accountID 前缀).
    func renameCodexAccount(accountID: String, label rawLabel: String) {
        let statuses = model.codexAccountStatuses
        guard let status = statuses.first(where: { $0.accountID == accountID }) else {
            model.setSettingsError("Codex 账号不存在, 未执行重命名", for: .codex)
            return
        }
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let customName: String?
        if trimmed.isEmpty {
            customName = nil
        } else {
            do {
                let label = try ProviderAccountNaming.validateLabel(trimmed)
                let candidate = ProviderAccountNaming.compose(
                    provider: .codex,
                    label: label
                )
                guard ProviderAccountNaming.fitsCollectorLimit(candidate) else {
                    throw ProviderAccountNamingError.tooLong
                }
                guard !ProviderAccountNaming.isDuplicate(
                    candidate,
                    provider: .codex,
                    existingDisplayNames: statuses.map(\.displayName),
                    excludingDisplayName: status.displayName
                ) else {
                    throw ProviderAccountNamingError.duplicate
                }
                customName = label
            } catch let error as ProviderAccountNamingError {
                model.setSettingsError(error.message, for: .codex)
                return
            } catch {
                model.setSettingsError("Codex 账号重命名失败", for: .codex)
                return
            }
        }
        model.setBusySubscription(true, for: .codex)
        Task { @MainActor in
            defer { self.model.setBusySubscription(false, for: .codex) }
            do {
                try await self.codexTokenManager.renameAccount(
                    accountID: accountID,
                    customName: customName
                )
                await self.publishCodexAccountStatuses()
                self.publishCodexSummaryFromIndex()
                self.model.setSettingsError(nil, for: .codex)
                self.onAccountRenamed?(.codex)
            } catch {
                self.model.setSettingsError(
                    "Codex 账号重命名失败, 请检查本机凭据文件", for: .codex
                )
            }
        }
    }

    /// StepFun 站点判定: 优先精确站点前缀, 其次令牌推导.
    /// 不使用 contains("国际"), 避免自定义标签把国内账号误判成国际站 (T18).
    private static func isStepFunGlobal(
        displayName: String,
        credentialJSON: String?
    ) -> Bool {
        if ProviderAccountNaming.isStepFunGlobalDisplayName(displayName) {
            return true
        }
        guard let credentialJSON else { return false }
        return ProviderConnectionVerifier.isStepFunGlobalToken(credentialJSON)
    }

    /// Codex 单账号移除: 通过 token manager 取消该账号的刷新与存储重试,
    /// 再删除对应 v2 record/index 条目, 不影响其他账号.
    func removeCodexAccount(accountID: String) async {
        defer { model.setBusySubscription(false, for: .codex) }
        do {
            let index = try codexStore.loadIndex()
            guard index.entry(for: accountID) != nil else {
                model.setSettingsError("Codex 账号不存在, 未执行移除", for: .codex)
                return
            }
            try await codexTokenManager.disconnect(accountID: accountID)
        } catch {
            model.setSettingsError(
                "Codex 账号移除失败, 请检查本机凭据文件 (~/Library/Application Support/Bruce/credentials.json)", for: .codex
            )
            return
        }
        publishCodexSummaryFromIndex()
        publishCodexCredentialConfigured()
        await publishCodexAccountStatuses()
        model.setSettingsError(nil)
    }

    /// 发布 token manager 的非敏感 Codex 账号状态, 与启动时保持同一映射.
    func publishCodexAccountStatuses() async {
        let state = await codexTokenManager.statusSnapshot()
        model.setCodexAccountStatuses(
            state.accounts.map { account in
                CodexAccountStatus(
                    accountID: account.accountID,
                    displayName: account.displayName,
                    authorizationState: account.authorizationState,
                    credentialOrigin: account.credentialOrigin,
                    storageBlocked: account.storageBlocked,
                    updatedAt: account.updatedAt
                )
            }
        )
    }

    /// 更新账号授权状态 (验证失败标记 needsReauthorization, 成功后 connected).
    func updateAccountAuthorizationState(
        accountID: String,
        from id: SubscriptionProviderID,
        state: ProviderAccountAuthorizationState
    ) {
        let store = accountStore(for: id)
        do {
            try store.updateAuthorizationState(state, for: accountID)
            publishAllProviderAccountSummaries(
                enabledProviders: enabledProviderIDs(from: configStore?.load())
            )
        } catch {
            model.setSettingsError("\(id.displayName) 账号状态更新失败", for: id)
        }
    }

    /// 从配置删除 provider 条目; 失败发布错误并返回 false.
    func removeSubscriptionFromConfig(_ id: SubscriptionProviderID) -> Bool {
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
    func removeCodexProvider() async {
        do {
            let index = try codexStore.loadIndex()
            for entry in index.accounts {
                try await codexTokenManager.disconnect(accountID: entry.accountID)
            }
        } catch {
            model.setSettingsError(
            "Codex 凭证删除失败, 请检查本机凭据文件 (~/Library/Application Support/Bruce/credentials.json)", for: .codex
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
                model.setSettingsError("请先配置 \(id.displayName) 凭证再启用", for: id)
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
    func readCredentialFile(_ fileURL: URL, usage: String) -> String? {
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

    /// Claude 凭证 JSON -> accessToken (用于生成 accountID).
    static func claudeAccessToken(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        let entry = (dict["claudeAiOauth"] as? [String: Any])
            ?? (dict["claude.ai_oauth"] as? [String: Any])
            ?? dict
        let token = (entry["accessToken"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Grok 凭证 JSON -> key (用于生成 accountID).
    static func grokKey(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        for (_, value) in dict {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty else { continue }
            return key
        }
        return nil
    }

    // MARK: - 订阅额度本机文件检测 (供设置页条件渲染; 转发 LocalCredentialProbe)

    func codexCLIAuthFileExists() -> Bool {
        localProbe.codexCLIAuthFileExists()
    }

    func codexCCAccountsFileExists() -> Bool {
        localProbe.codexCCAccountsFileExists()
    }

    func ccSwitchDatabaseExists() -> Bool {
        localProbe.ccSwitchDatabaseExists()
    }

    // MARK: - Claude / Grok 本机登录态检测 (实时只读, 不导入不回写)

    /// 刷新 Claude / Grok 本机登录态可用性, 结果写入 model 供设置页渲染,
    /// 并经 `credentialConfigured` 重算 configured (应用 Keychain 优先于本机).
    /// C059: Claude 走统一读取序 (Keychain 静默 → 凭证文件), refreshPending/expired
    /// 均计为「检测到登录态」(过期也照常试一把, 与 cc-switch 一致);
    /// 读取含 Keychain 尝试, 统一放后台队列 (子进程 waitUntilExit 会泵 runloop,
    /// 避免视图事务重入)。
    func refreshOfficialLocalAvailability() {
        let grokAvailable = localProbe.grokLocalAuthAvailable()
        model.setGrokLocalAvailable(grokAvailable)
        model.setSubscriptionCredentialConfigured(
        credentialConfigured(.grok), for: .grok
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = self?.localProbe.claudeLocalCredentialStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.model.setClaudeLocalAvailable(status != nil)
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
    func openInBrowser(_ url: URL) {
        NSApp.activate()
        if !NSWorkspace.shared.open(url) {
            model.setSettingsError(
                "无法自动打开浏览器, 请手动访问: \(url.absoluteString)"
            )
        }
    }
}
