import Foundation
import MdddOnboardingCore

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
package protocol CodexAccessTokenInjecting: AnyObject, Sendable {
    /// 返回该账号当前有效 access token; 失败或不存在返回 nil.
    func validAccessToken(
        for accountID: String
    ) async -> String?
}

/// CodexTokenManager 作为注入源: 把分类结果折叠为可选的短期 access token.
extension CodexTokenManager: CodexAccessTokenInjecting {
    package func validAccessToken(for accountID: String) async -> String? {
        switch await validAccessToken(for: accountID, now: nil) {
        case .success(let resolution):
            return resolution.accessToken
        case .failure:
            return nil
        }
    }
}

/// CodexCredentialStore 作为 App 启动迁移执行器 (任务 11):
/// 幂等迁移旧整体账号库 -> metadata-only v2 记录.
/// 迁移失败保留旧键 (可重试), 返回 false 供启动流程暂停 Codex 外部额度.
extension CodexCredentialStore: CodexMigrationExecuting {
    package func executeCodexMigration() async -> Bool {
        do {
            _ = try migrateLegacyAccounts(now: Date())
            return true
        } catch {
            return false
        }
    }
}

/// 无 store 的提供器按迁移已完成处理 (兼容未装配 codexStore 的旧路径,
/// 此时本就没有 Codex 输入可开放).
extension OnboardingRunInputProvider: CodexMigrationExecuting {
    package func executeCodexMigration() async -> Bool {
        true
    }
}

/// 每次运行前向 Scheduler 提供受控 context 和 credentials.
/// async: Codex 账号需等待 token manager 决议.
@MainActor
protocol CollectorRunInputProviding {
    func runInput(for module: CollectorModule) async throws -> CollectorRunInput

    /// Codex 定向重试输入 (任务 9): 只针对被 challenge 的账号.
    /// 返回 nil 表示该账号没有可注入凭证, 不执行重试.
    /// 实现方默认只支持 agentUsage; 其他模块返回 nil.
    func retryInput(
        for module: CollectorModule,
        accountID: String
    ) async throws -> CollectorRunInput?
}

/// App 启动前的 Codex v2 迁移入口 (任务 11).
/// 由 ApplicationBootstrap 在启动 Scheduler 前调用; 测试注入内存实现.
@MainActor
package protocol CodexMigrationExecuting: AnyObject {
    /// 幂等迁移旧整体账号库 -> metadata-only v2 记录.
    /// 成功或确认无旧数据返回 true; 失败返回 false (旧键保留, 可重试).
    func executeCodexMigration() async -> Bool
}

/// 基于 Onboarding 配置和 Keychain 的运行输入提供器.
/// Agent: 授予 localSessions/localPricing; 统一授权已确认且至少一个订阅
/// provider enabled 且 Keychain 凭证完整时追加 externalQuotas, 并把凭证
/// 装配进 Bridge 注入键 (对照 bridge/security.py 白名单).
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
    /// v2 账号索引读取 (Codex v2 store; 由 App 装配, 测试可注入).
    private var codexStore: CodexCredentialStore?
    /// 旧库迁移完成前不开放 v2 Codex quota 输入 (任务 11).
    /// 默认 true 兼容未装配 store 的旧测试; App 启动时按迁移结果设置.
    private var codexMigrationCompleted = true

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

    /// 设置旧库迁移完成状态 (任务 11). App 启动时按幂等迁移结果调用;
    /// 迁移失败只暂停 Codex 外部额度, 不阻断本地统计和其他 provider.
    package func setCodexMigrationCompleted(_ completed: Bool) {
        codexMigrationCompleted = completed
    }

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        switch module {
        case .agentUsage:
            return try await agentUsageInput()
        }
    }

    /// 定向重试: 只含被 challenge 账号的短期 access token, 上下文标记
    /// codexQuotaRetryOnly. 账号未连接或 token 决议失败返回 nil, 不重试.
    /// 旧库迁移完成前不开放 (与首轮输入 gate 一致, 任务 11).
    func retryInput(
        for module: CollectorModule,
        accountID: String
    ) async throws -> CollectorRunInput? {
        guard module == .agentUsage,
              codexMigrationCompleted,
              let injector = codexTokenInjector,
              let accessToken = await injector.validAccessToken(
                  for: accountID
              ) else {
            return nil
        }
        let displayName: String
        if let record = try? codexStore?.loadRecord(for: accountID) {
            displayName = record.displayName
        } else {
            displayName = "Codex · " + String(accountID.prefix(8))
        }
        return CollectorRunInput(
            context: [
                "capabilities": .array([
                    .string(CollectorCapability.externalQuotas.rawValue),
                ]),
                "codexQuotaRetryOnly": .boolean(true),
            ],
            credentials: [
                "codexQuotaAccounts": .object([
                    accountID: .object([
                        "display_name": .string(displayName),
                        "access_token": .string(accessToken),
                    ]),
                ]),
            ]
        )
    }

    private func agentUsageInput() async throws -> CollectorRunInput {
        var capabilities: [JSONValue] = [
            .string(CollectorCapability.localSessions.rawValue),
            .string(CollectorCapability.localPricing.rawValue),
        ]
        var credentials: [String: JSONValue] = [:]

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
            }
        }
        return CollectorRunInput(
            context: ["capabilities": .array(capabilities)],
            credentials: credentials
        )
    }

    /// 从 Keychain 装配订阅 provider 的 Bridge 注入凭证.
    /// 只装配 enabled 且凭证完整的 provider; 凭证 JSON 损坏按缺失处理
    /// (fail-closed, 不授予 externalQuotas).
    /// Codex: 调用 token manager 决议全部索引账号, 只注入成功账号的
    /// 短期 access token; 单账号失败不阻断其他账号和本地会话采集.
    private func assembleSubscriptionCredentials(
        providers: [String: SubscriptionProviderConfiguration]
    ) async -> [String: JSONValue] {
        var credentials: [String: JSONValue] = [:]
        var providerEnv: [String: JSONValue] = [:]
        var providerMeta: [String: JSONValue] = [:]

        func isEnabled(_ id: SubscriptionProviderID) -> Bool {
            providers[id.rawValue]?.enabled == true
        }
        func load(_ account: String) -> String? {
            guard let value = try? credentialStore.loadCredential(forAccount: account),
                  !value.isEmpty else {
                return nil
            }
            return value
        }

        if isEnabled(.kimi),
           let raw = load(SubscriptionCredentialAccount.kimiWebTokens),
           let tokens = jsonObjectValue(from: raw) {
            credentials["kimiWebTokens"] = tokens
        }
        if isEnabled(.deepseek),
           let key = load(SubscriptionCredentialAccount.deepseekAPIKey) {
            // collect_usage.py service_deepseek 消费 env.ANTHROPIC_AUTH_TOKEN
            providerEnv["deepseek"] = .object([
                "ANTHROPIC_AUTH_TOKEN": .string(key),
            ])
        }
        if isEnabled(.volcengine),
           let ak = load(SubscriptionCredentialAccount.volcengineAccessKey),
           let sk = load(SubscriptionCredentialAccount.volcengineSecretKey) {
            // collect_usage.py service_volcengine 消费 meta.usage_script.accessKeyId/secretAccessKey
            providerMeta["volcengine"] = .object([
                "usage_script": .object([
                    "accessKeyId": .string(ak),
                    "secretAccessKey": .string(sk),
                ]),
            ])
        }
        if isEnabled(.codex),
           codexMigrationCompleted,
           let codexAccounts = await resolveCodexQuotaAccounts() {
            credentials["codexQuotaAccounts"] = codexAccounts
        }
        if isEnabled(.antigravity),
           let raw = load(SubscriptionCredentialAccount.antigravityOAuth),
           let oauth = jsonObjectValue(from: raw) {
            credentials["antigravityOAuth"] = oauth
        }
        if !providerEnv.isEmpty {
            credentials["providerEnv"] = .object(providerEnv)
        }
        if !providerMeta.isEmpty {
            credentials["providerMeta"] = .object(providerMeta)
        }
        return credentials
    }

    /// 从 v2 索引取全部账号, 交给 token manager 决议短期 access token.
    /// 注入结构: {accountID: {"display_name": ..., "access_token": ...}},
    /// 与 bridge/security.py 白名单 (codex_quota_accounts) 对齐.
    /// 账号无 token 时只影响该账号, 不阻断其他账号.
    private func resolveCodexQuotaAccounts() async -> JSONValue? {
        guard let injector = codexTokenInjector else { return nil }
        let accountIDs: [String]
        if let index = try? codexStore?.loadIndex() {
            accountIDs = index.accounts.map(\.accountID)
        } else {
            return nil
        }
        guard !accountIDs.isEmpty else { return nil }

        var resolved: [String: JSONValue] = [:]
        var succeeded: [String] = []
        for accountID in accountIDs {
            guard let accessToken = await injector.validAccessToken(
                for: accountID
            ) else {
                continue
            }
            let displayName: String
            if let record = try? codexStore?.loadRecord(for: accountID) {
                displayName = record.displayName
            } else {
                displayName = "Codex · " + String(accountID.prefix(8))
            }
            resolved[accountID] = .object([
                "display_name": .string(displayName),
                "access_token": .string(accessToken),
            ])
            succeeded.append(accountID)
        }
        guard !resolved.isEmpty else { return nil }
        codexQuotaAccountIDs = succeeded
        return .object(resolved)
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

    /// 把 Collector 轮换的新令牌写回 Keychain. 只处理已知 provider 的
    /// oauthTokens/replace 条目; 单条解析或写入失败跳过该条, 不影响其他条目,
    /// 也不阻断 artifact 发布 (下次刷新会重试轮换).
    /// Codex 轮换条目被明确拒绝: 任务 6 起 App 不再接受 Codex rotation,
    /// 令牌链由 token manager 独占持有 (refresh 响应自带轮换).
    package func apply(credentialUpdates: [JSONValue]) {
        for value in credentialUpdates {
            guard let update = Self.rotationUpdate(from: value),
                  update.provider != "codex",
                  let account = CredentialRotationMerge.keychainAccount(
                      forProvider: update.provider
                  ) else { continue }
            let existing = try? credentialStore.loadCredential(forAccount: account)
            guard let merged = CredentialRotationMerge.mergedJSON(
                existingJSON: existing ?? nil,
                update: update
            ) else { continue }
            try? credentialStore.saveCredential(merged, forAccount: account)
        }
    }

    /// Bridge credentialUpdates JSON -> 纯更新结构; 只接受
    /// kind=oauthTokens, operation=replace 且含有效令牌的条目.
    private static func rotationUpdate(from value: JSONValue) -> CredentialRotationUpdate? {
        guard case .object(let dict) = value,
              case .string(let provider)? = dict["provider"],
              case .string(let kind)? = dict["kind"], kind == "oauthTokens",
              case .string(let operation)? = dict["operation"], operation == "replace",
              case .object(let credentials)? = dict["credentials"] else {
            return nil
        }
        var tokens: [String: String] = [:]
        for (key, child) in credentials {
            if case .string(let string) = child {
                tokens[key] = string
            }
        }
        guard !tokens.isEmpty else { return nil }
        var accountId = "default"
        if case .string(let raw)? = dict["accountId"], !raw.isEmpty {
            accountId = raw
        }
        return CredentialRotationUpdate(
            provider: provider,
            accountId: accountId,
            tokens: tokens
        )
    }
}
