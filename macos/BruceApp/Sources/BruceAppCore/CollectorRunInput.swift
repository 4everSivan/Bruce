import Foundation
import BruceOnboardingCore

/// 单次 Collector 运行的受控输入. 凭证只经 Bridge stdin JSON 传递,
/// 不进入命令行参数或日志.
package struct CollectorRunInput: Sendable {
    let context: [String: JSONValue]
    let credentials: [String: JSONValue]
}

/// 运行输入缺失的分类错误. 区分依赖缺失和授权缺失,
/// Scheduler 据此决定走 backoff 还是 authRequired.
enum CollectorRunInputError: Error, Equatable {
    case missingDependency(module: CollectorModule, reason: String)
    case missingAuthorization(module: CollectorModule, reason: String)
}

/// Codex 短期 access token 的注入源 (任务 5 起由 token manager 承载).
/// 批量决议协议: 返回单账号的 Outcome, 由 CodexTokenBatchResolver 并行调度.
package protocol CodexAccessTokenInjecting: AnyObject, Sendable {
    /// 返回该账号的 token 决议结果; 失败返回对应 Outcome.
    func resolveToken(
        for accountID: String
    ) async -> CodexTokenDecision.Outcome
}

/// CodexTokenManager 作为注入源: 把 TokenResolution 映射为 Outcome.
extension CodexTokenManager: CodexAccessTokenInjecting {
    package func resolveToken(
        for accountID: String
    ) async -> CodexTokenDecision.Outcome {
        switch await validAccessToken(for: accountID, now: nil) {
        case .success(let accessToken, let expiresAt):
            return .available(
                accessToken: accessToken,
                expiresAt: expiresAt
            )
        case .failure(let error):
            switch error {
            case .needsReauthorization:
                return .needsReauthorization
            case .storageBlocked:
                return .storageBlocked
            case .refreshFailed:
                return .temporarilyUnavailable(retryAt: nil)
            case .notFound:
                return .credentialNotFound
            }
        }
    }
}

/// CodexCredentialStore 作为 App 启动迁移执行器:
/// 幂等迁移旧整体账号库 -> metadata-only v2 记录.
/// 迁移结果控制 Codex quota gate (失败/损坏只暂停 Codex 外部额度).
extension CodexCredentialStore: CodexMigrationExecuting {
    package func executeCodexMigration() async -> CodexMigrationResult {
        migrateLegacyAccounts(now: Date())
    }
}

/// 每次运行前向 Scheduler 提供受控 context 和 credentials.
/// async: Codex 账号需等待 token manager 决议.
@MainActor
protocol CollectorRunInputProviding {
    func runInput(for module: CollectorModule) async throws -> CollectorRunInput

    /// 定向刷新运行输入: 只注入目标 Provider 的 `*QuotaAccounts` / `providerMeta`
    /// 与对应 Bridge 注入键, 并标记 `subscriptionQuotaOnly` / `subscriptionProviders`.
    /// 不携带 localSessions / localPricing, 不请求 days; 目标集合非法或凭证未装配
    /// 时抛 `missingAuthorization` (不启动 Collector, 不伪造成功).
    func scopedRunInput(
        for module: CollectorModule,
        providers: Set<SubscriptionProviderID>
    ) async throws -> CollectorRunInput

    /// Codex 定向重试输入 (任务 8): 一次组装全部被挑战账号的短期
    /// access token, 上下文标记 codexQuotaRetryOnly.
    /// 只包含本轮刷新成功的账号; 决议失败或未连接账号不进入重试.
    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput?

    /// 本轮全部 Codex 账号 token 决议 (含成功与失败), 供四源合并器
    /// 为未出现在 collector 结果中的账号合成失败状态. 无 Codex 时为空.
    var codexTokenDecisions: [CodexTokenDecision] { get }
}

extension CollectorRunInputProviding {
    /// 默认定向输入实现: 退回全量输入 (保持非定向测试兼容).
    /// 生产路径由 `OnboardingRunInputProvider` 重写为只注入目标 Provider 凭证.
    func scopedRunInput(
        for module: CollectorModule,
        providers: Set<SubscriptionProviderID>
    ) async throws -> CollectorRunInput {
        try await runInput(for: module)
    }
}

/// App 启动前的 Codex v2 迁移入口.
/// 由 ApplicationBootstrap 在启动 Scheduler 前调用; 测试注入内存实现.
/// 生产组合根必须注入真实 CodexCredentialStore, 禁止使用返回成功的空迁移器.
@MainActor
package protocol CodexMigrationExecuting: AnyObject {
    /// 幂等迁移旧整体账号库 -> metadata-only v2 记录.
    /// 结果控制 Codex quota gate: noLegacyData/migrated/cleanupPending 开放,
    /// corruptedJSON/failed 关闭.
    func executeCodexMigration() async -> CodexMigrationResult
}

/// 基于 Onboarding 配置和 Keychain 的运行输入提供器.
/// Agent: 授予 localSessions/localPricing; 统一授权已确认且至少一个订阅
/// provider enabled 且 Keychain 凭证完整时追加 externalQuotas, 并把凭证
/// 装配进 Rust Bridge 注入键 (对照 Rust Bridge allowlist).
/// Codex: 只注入 token manager 决议出的短期 access token
/// (`codexQuotaAccounts` 结构: 账号键 + display_name + access_token);
/// refresh token 与 id token 不离开 Swift/Keychain.
@MainActor
package final class OnboardingRunInputProvider: CollectorRunInputProviding {
    private let configStore: OnboardingConfigurationStore?
    private let credentialStore: CredentialStore
    /// Codex access token 注入器; nil 表示尚未装配 (App 启动时注入).
    private weak var codexTokenInjector: (any CodexAccessTokenInjecting)?
    /// 已决议的 Codex 账号列表 (accountID + displayName), 只供 Swift 内使用,
    /// 不编码到 Bridge 请求.
    private var codexQuotaAccountIDs: [String] = []
    /// 本轮全部账号的 token 决议 (任务 5). 含成功和失败, 供 Scheduler/
    /// 合并器按账号生成 stale/unavailable 状态. 全失败时清空旧值.
    private(set) var codexTokenDecisions: [CodexTokenDecision] = []
    /// v2 账号索引读取 (Codex v2 store; 由 App 装配, 测试可注入).
    private var codexStore: CodexCredentialStore?
    /// 旧库迁移完成前不开放 v2 Codex quota 输入 (任务 11).
    /// 默认 true 兼容未装配 store 的旧测试; App 启动时按迁移结果设置.
    private var codexMigrationCompleted = true
    /// 通用多账号 store 缓存 (按 provider).
    private lazy var accountStores: [SubscriptionProviderID: ProviderAccountStore] = {
        var stores: [SubscriptionProviderID: ProviderAccountStore] = [:]
        for id in SubscriptionProviderID.allCases where id != .codex {
            stores[id] = ProviderAccountStore(provider: id, credentialStore: credentialStore)
        }
        // 复用已创建的 store 实例迁移旧凭证, 不额外创建 store.
        for (_, store) in stores {
            _ = try? store.migrateLegacyAccountsIfNeeded(
                legacyKeys: ProviderAccountKeys.legacyKeys(for: store.provider)
            )
        }
        return stores
    }()

    package init(
        configStore: OnboardingConfigurationStore?,
        credentialStore: CredentialStore,
        codexTokenInjector: (any CodexAccessTokenInjecting)? = nil,
        codexStore: CodexCredentialStore? = nil
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
        self.codexTokenInjector = codexTokenInjector
        self.codexStore = codexStore
    }

    /// 装配 Codex access token 注入器 (App 启动时调用一次).
    package func attachCodexTokenInjector(_ injector: any CodexAccessTokenInjecting) {
        codexTokenInjector = injector
    }

    /// 已决议的 Codex 账号 id (非敏感, 仅 Swift 内使用).
    package func resolvedCodexAccountIDs() -> [String] {
        codexQuotaAccountIDs
    }

    /// 设置旧库迁移结果. App 启动时按幂等迁移结果调用;
    /// noLegacyData/migrated/cleanupPending 开放 Codex 外部额度,
    /// corruptedJSON/failed 关闭 (不阻断本地统计和其他 provider).
    package func setCodexMigrationResult(_ result: CodexMigrationResult) {
        switch result {
        case .noLegacyData, .migrated, .cleanupPending:
            codexMigrationCompleted = true
        case .corruptedJSON, .incompatibleSchema, .failed:
            codexMigrationCompleted = false
        }
    }

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        switch module {
        case .agentUsage:
            return try await agentUsageInput()
        }
    }

    /// 定向刷新运行输入 (任务 1.3): 只装配目标 Provider 的凭证/ProviderMeta,
    /// 标记 `subscriptionQuotaOnly` / `subscriptionProviders`; 不携带 localSessions
    /// / localPricing / days. 目标非法或凭证未装配抛 missingAuthorization (fail-closed).
    func scopedRunInput(
        for module: CollectorModule,
        providers: Set<SubscriptionProviderID>
    ) async throws -> CollectorRunInput {
        guard module == .agentUsage else {
            throw CollectorRunInputError.missingDependency(
                module: module,
                reason: "定向刷新仅支持 agentUsage 模块"
            )
        }
        // 每个定向输入都是新的决议边界.
        codexTokenDecisions = []
        codexQuotaAccountIDs = []

        guard let config = configStore?.load(),
              config.consentVersion != nil else {
            throw CollectorRunInputError.missingAuthorization(
                module: module,
                reason: "未确认统一授权, 无法定向刷新订阅额度"
            )
        }

        // 只把目标 Provider 的配置交给装配器: codex token 解析仅在 codex 目标时发生.
        let targetRaw = Set(providers.map { $0.rawValue })
        var scopedProviders: [String: SubscriptionProviderConfiguration] = [:]
        for (key, value) in config.subscriptionProviders
        where targetRaw.contains(key) {
            scopedProviders[key] = value
        }

        let assembled = await assembleSubscriptionCredentials(providers: scopedProviders)
        // fail-closed: 无目标凭证 (未启用/凭证缺失) 不启动 Collector, 不伪造成功.
        guard !assembled.isEmpty else {
            throw CollectorRunInputError.missingAuthorization(
                module: module,
                reason: "目标 Provider 未启用或凭证未装配"
            )
        }

        var context: [String: JSONValue] = [
            "capabilities": .array([
                .string(CollectorCapability.externalQuotas.rawValue),
            ]),
            "subscriptionQuotaOnly": .boolean(true),
            "subscriptionProviders": .array(
                providers.sorted { $0.rawValue < $1.rawValue }
                    .map { .string($0.rawValue) }
            ),
        ]
        // codex 目标: 携带与 codexQuotaAccounts 键一致的 account order.
        if let codex = assembled["codexQuotaAccounts"],
           case .object(let accounts) = codex {
            context["codexQuotaAccountOrder"] = .array(
                codexQuotaAccountIDs
                    .filter { accounts[$0] != nil }
                    .map { .string($0) }
            )
        }
        return CollectorRunInput(context: context, credentials: assembled)
    }

    /// 定向重试 (任务 8): 一次组装全部被 challenge 账号的短期 access token,
    /// 上下文标记 codexQuotaRetryOnly. 账号未连接或 token 决议失败不进入
    /// 重试; 全部失败时返回 nil, 不执行 retry-only Collector.
    /// 旧库迁移完成前不开放 (与首轮输入 gate 一致, 任务 11).
    /// 任务 6: 账号按 v2 index 重新排序 (不采用 challenge 到达顺序),
    /// 并携带与 codexQuotaAccounts 集合一致的 codexQuotaAccountOrder.
    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        guard module == .agentUsage,
              codexMigrationCompleted,
              let injector = codexTokenInjector,
              !accountIDs.isEmpty else {
            return nil
        }
        // 按本轮决议 index 重新排序; 未出现在决议中的账号按 accountID
        // 排尾 (确定性).
        let decisionIndexByAccount: [String: Int] = {
            var result: [String: Int] = [:]
            for decision in codexTokenDecisions {
                if result[decision.accountID] == nil {
                    result[decision.accountID] = decision.index
                }
            }
            return result
        }()
        let orderedAccountIDs = accountIDs.sorted {
            let left = decisionIndexByAccount[$0] ?? Int.max
            let right = decisionIndexByAccount[$1] ?? Int.max
            if left != right { return left < right }
            return $0 < $1
        }
        var credentials: [String: JSONValue] = [:]
        for accountID in orderedAccountIDs {
            let outcome = await injector.resolveToken(for: accountID)
            guard case .available(let accessToken, _) = outcome else {
                continue
            }
            let displayName: String
            if let record = try? codexStore?.loadRecord(for: accountID) {
                displayName = record.displayName
            } else {
                displayName = "Codex · " + String(accountID.prefix(8))
            }
            credentials[accountID] = .object([
                "display_name": .string(displayName),
                "access_token": .string(accessToken),
            ])
        }
        guard !credentials.isEmpty else {
            return nil
        }
        // 任务 6: 重试输入携带与 codexQuotaAccounts 集合一致的 order,
        // 顺序保留 index 排序后的账号顺序, 不采用 challenge 到达顺序.
        let order = orderedAccountIDs.filter { credentials[$0] != nil }
        var context: [String: JSONValue] = [
            "capabilities": .array([
                .string(CollectorCapability.externalQuotas.rawValue),
            ]),
            "codexQuotaRetryOnly": .boolean(true),
        ]
        context["codexQuotaAccountOrder"] = .array(
            order.map { .string($0) }
        )
        return CollectorRunInput(
            context: context,
            credentials: [
                "codexQuotaAccounts": .object(credentials),
            ]
        )
    }

    private func agentUsageInput() async throws -> CollectorRunInput {
        // 每个首轮输入都是新的决议边界. 无授权、provider 被禁用、v2 index
        // 读取失败或账号为空时都不能沿用上一轮 decisions/order.
        codexTokenDecisions = []
        codexQuotaAccountIDs = []
        var capabilities: [JSONValue] = [
            .string(CollectorCapability.localSessions.rawValue),
            .string(CollectorCapability.localPricing.rawValue),
        ]
        var credentials: [String: JSONValue] = [:]
        // 182 天聚合窗口: 柱状图仍取末 14 天 (映射层 suffix), 全量 daily
        // 供用量热力图渲染; Bridge 协议上限 366.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nowFormatter = ISO8601DateFormatter()
        nowFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        nowFormatter.timeZone = TimeZone.current
        var context: [String: JSONValue] = [
            "home": .string(home),
            "now": .string(nowFormatter.string(from: Date())),
            "timezone": .string(TimeZone.current.identifier),
            "days": .integer(182),
        ]

        let config = configStore?.load()
        // 统一授权未确认时永远不授予 externalQuotas;
        // 一个 provider 都没配齐时也不授予, collector 会返回未授权占位
        if config?.consentVersion != nil {
            let assembled = await assembleSubscriptionCredentials(
                providers: config?.subscriptionProviders ?? [:]
            )
            if !assembled.isEmpty {
                capabilities.append(
                    .string(CollectorCapability.externalQuotas.rawValue)
                )
                credentials = assembled
                // codexQuotaAccountOrder: 按 v2 index 排序的账号 ID 列表,
                // Rust Collector 按此调度并恢复输出顺序; 集合必须与 codexQuotaAccounts
                // 键完全一致, 顺序即 Swift 决议的 index 顺序 (任务 6).
                if let codexAccounts = credentials["codexQuotaAccounts"],
                   case .object(let accountsObject) = codexAccounts {
                    context["codexQuotaAccountOrder"] = .array(
                        codexQuotaAccountIDs
                            .filter { accountsObject[$0] != nil }
                            .map { .string($0) }
                    )
                }
            }
        }
        context["capabilities"] = .array(capabilities)
        return CollectorRunInput(
            context: context,
            credentials: credentials
        )
    }

    /// 从 Keychain 装配订阅 provider 的 Bridge 注入凭证.
    /// 只装配 enabled 且凭证完整的 provider; 凭证 JSON 损坏按缺失处理
    /// (fail-closed, 不授予 externalQuotas).
    /// 按 `ProviderRegistry` 的 `InjectionKind` 派发, 输出 JSON 键/嵌套与
    /// 既有 harness 期望逐字段一致. Codex 仍委托 token manager 决议短期
    /// access token; 单账号失败不阻断其他账号和本地会话采集.
    private func assembleSubscriptionCredentials(
        providers: [String: SubscriptionProviderConfiguration]
    ) async -> [String: JSONValue] {
        var credentials: [String: JSONValue] = [:]
        var providerMeta: [String: JSONValue] = [:]

        func isEnabled(_ id: SubscriptionProviderID) -> Bool {
            providers[id.rawValue]?.enabled == true
        }

        // 从 ProviderAccountStore 按账号加载凭证, 注入为多账号结构.
        // Codex 仍走独立的 token manager 决议路径.
        for descriptor in ProviderRegistry.all {
            guard isEnabled(descriptor.id) else { continue }

            switch descriptor.injectionKind {
            case .kimiAPIKeyEnv:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID) else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "api_key": .string(record.credentialJSON),
                    ])
                }
                if !accounts.isEmpty {
                    credentials["kimiQuotaAccounts"] = .object(accounts)
                }

            case .deepseekAPIKeyEnv:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID) else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "api_key": .string(record.credentialJSON),
                    ])
                }
                if !accounts.isEmpty {
                    credentials["deepseekQuotaAccounts"] = .object(accounts)
                }

            case .volcengineUsageScriptKeys:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID) else { continue }
                    // credentialJSON 是 {"accessKey":..., "secretKey":...}
                    guard let data = record.credentialJSON.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ak = dict["accessKey"] as? String,
                          let sk = dict["secretKey"] as? String else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "access_key": .string(ak),
                        "secret_key": .string(sk),
                    ])
                }
                if !accounts.isEmpty {
                    credentials["volcengineQuotaAccounts"] = .object(accounts)
                }

            case .zhipuAPIKeyEnv:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID) else { continue }
                    // credentialJSON 是 {"api_key":..., "base_url":...}
                    guard let data = record.credentialJSON.data(using: .utf8),
                          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let key = dict["api_key"] as? String,
                          let baseURL = dict["base_url"] as? String else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "api_key": .string(key),
                        "base_url": .string(baseURL),
                    ])
                }
                if !accounts.isEmpty {
                    credentials["zhipuQuotaAccounts"] = .object(accounts)
                }

            case .codexQuotaAccounts:
                guard codexMigrationCompleted,
                      let codexAccounts = await resolveCodexQuotaAccounts() else {
                    continue
                }
                credentials["codexQuotaAccounts"] = codexAccounts

            case .antigravityOAuthJSON:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID),
                          let oauth = jsonObjectValue(from: record.credentialJSON) else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "oauth": oauth,
                    ])
                }
                if !accounts.isEmpty {
                    credentials["antigravityQuotaAccounts"] = .object(accounts)
                }

            case .claudeMetaEnabledPlusOptionalOAuth:
                providerMeta["claude"] = .object(["enabled": .boolean(true)])
                if let store = accountStores[descriptor.id],
                   let index = try? store.loadIndex(),
                   !index.accounts.isEmpty {
                    var accounts: [String: JSONValue] = [:]
                    for entry in index.accounts {
                        guard let record = try? store.loadRecord(for: entry.accountID),
                              let oauth = jsonObjectValue(from: record.credentialJSON) else { continue }
                        accounts[entry.accountID] = .object([
                            "display_name": .string(entry.displayName),
                            "oauth": oauth,
                        ])
                    }
                    if !accounts.isEmpty {
                        credentials["claudeQuotaAccounts"] = .object(accounts)
                    }
                }

            case .grokMetaEnabledPlusOptionalOAuth:
                providerMeta["grok"] = .object(["enabled": .boolean(true)])
                if let store = accountStores[descriptor.id],
                   let index = try? store.loadIndex(),
                   !index.accounts.isEmpty {
                    var accounts: [String: JSONValue] = [:]
                    for entry in index.accounts {
                        guard let record = try? store.loadRecord(for: entry.accountID),
                              let oauth = jsonObjectValue(from: record.credentialJSON) else { continue }
                        accounts[entry.accountID] = .object([
                            "display_name": .string(entry.displayName),
                            "oauth": oauth,
                        ])
                    }
                    if !accounts.isEmpty {
                        credentials["grokQuotaAccounts"] = .object(accounts)
                    }
                }

            case .opencodeGoQuotaAccounts:
                guard let store = accountStores[descriptor.id],
                      let index = try? store.loadIndex(),
                      !index.accounts.isEmpty else { continue }
                var accounts: [String: JSONValue] = [:]
                for entry in index.accounts {
                    guard let record = try? store.loadRecord(for: entry.accountID),
                          let oauth = jsonObjectValue(from: record.credentialJSON) else { continue }
                    accounts[entry.accountID] = .object([
                        "display_name": .string(entry.displayName),
                        "oauth": oauth,
                    ])
                }
                if !accounts.isEmpty {
                    credentials["opencodeGoQuotaAccounts"] = .object(accounts)
                }
            }
        }

        if !providerMeta.isEmpty {
            credentials["providerMeta"] = .object(providerMeta)
        }
        return credentials
    }

    /// 从 v2 索引取全部账号, 交给批量决议器最多 4 并行决议.
    /// 注入结构: {accountID: {"display_name": ..., "access_token": ...}},
    /// 与 Rust Bridge allowlist (codex_quota_accounts) 对齐.
    /// 只有 .available 账号写入 Bridge credentials; 全部失败时清空旧值,
    /// 但决议结果仍保留供 Scheduler/合并器生成失败状态.
    private func resolveCodexQuotaAccounts() async -> JSONValue? {
        guard let injector = codexTokenInjector else { return nil }
        let index: CodexAccountIndex
        do {
            guard let codexStore else {
                return nil
            }
            index = try codexStore.loadIndex()
        } catch {
            // agentUsageInput 已在本轮开始清空状态. 读取失败保持空决议,
            // 不把上一轮账号合并进当前 artifact.
            return nil
        }
        guard !index.accounts.isEmpty else {
            codexTokenDecisions = []
            codexQuotaAccountIDs = []
            return nil
        }

        // 从 v2 index 生成带 index 的有序 descriptor
        let descriptors: [CodexTokenBatchResolver.Descriptor] = index.accounts
            .sorted { $0.accountID < $1.accountID }
            .enumerated()
            .map { offset, entry in
                let displayName: String
                if let record = try? codexStore?.loadRecord(for: entry.accountID) {
                    displayName = record.displayName
                } else {
                    displayName = "Codex · " + String(entry.accountID.prefix(8))
                }
                return CodexTokenBatchResolver.Descriptor(
                    index: offset,
                    accountID: entry.accountID,
                    displayName: displayName
                )
            }

        let resolver = CodexTokenBatchResolver()
        let decisions = await resolver.resolve(
            accounts: descriptors,
            using: { accountID in
                await injector.resolveToken(for: accountID)
            }
        )
        // 每轮无条件刷新决议; 全失败时清空旧值
        codexTokenDecisions = decisions
        codexQuotaAccountIDs = decisions
            .filter {
                if case .available = $0.outcome { return true }
                return false
            }
            .map(\.accountID)

        // 只有 .available 账号写入 Bridge credentials
        var resolved: [String: JSONValue] = [:]
        for decision in decisions {
            guard case .available(let accessToken, _) = decision.outcome else {
                continue
            }
            resolved[decision.accountID] = .object([
                "display_name": .string(decision.displayName),
                "access_token": .string(accessToken),
            ])
        }
        return resolved.isEmpty ? nil : .object(resolved)
    }

    /// 把 Keychain 读出的 JSON 字符串解析为 JSONValue 对象;
    /// 非对象, 解析失败或含不支持的值类型一律返回 nil.
    private func jsonObjectValue(from raw: String) -> JSONValue? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        var result: [String: JSONValue] = [:]
        for (key, value) in dict {
            guard let converted = jsonValue(from: value) else {
                return nil
            }
            result[key] = converted
        }
        return .object(result)
    }

    private func jsonValue(from value: Any) -> JSONValue? {
        switch value {
        case is NSNull:
            return .null
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            // JSONSerialization 的布尔与数字都是 NSNumber, 先按 CFBoolean 判定
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            if let int = Int(exactly: number) {
                return .integer(int)
            }
            return .double(number.doubleValue)
        case let dict as [String: Any]:
            var result: [String: JSONValue] = [:]
            for (key, child) in dict {
                guard let converted = jsonValue(from: child) else {
                    return nil
                }
                result[key] = converted
            }
            return .object(result)
        case let array as [Any]:
            var result: [JSONValue] = []
            for child in array {
                guard let converted = jsonValue(from: child) else {
                    return nil
                }
                result.append(converted)
            }
            return .array(result)
        default:
            return nil
        }
    }

    /// 把 Collector 轮换的新令牌写回 Keychain (薄封装, 委托 CredentialUpdateCoordinator).
    /// 返回 applied/skipped/failed; 单条失败不阻断其他条目与 artifact 发布.
    /// Codex 轮换条目被明确跳过: 令牌链由 token manager 独占持有.
    @discardableResult
    package func apply(credentialUpdates: [JSONValue]) -> CredentialUpdateApplyResult {
        CredentialUpdateCoordinator(credentialStore: credentialStore)
            .apply(credentialUpdates: credentialUpdates)
    }
}
