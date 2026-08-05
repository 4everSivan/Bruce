import Foundation

// MARK: - InjectionKind

/// Bridge 凭证注入形状. `assembleSubscriptionCredentials` 只按本枚举派发,
/// 输出 JSON 键与嵌套必须与现有 harness / Bridge 白名单一致.
public enum InjectionKind: Sendable, Equatable {
    /// 顶层 `kimiWebTokens` = Keychain JSON 对象
    case kimiWebTokensJSON
    /// `providerEnv.deepseek.ANTHROPIC_AUTH_TOKEN` = API key 字符串
    case deepseekAPIKeyEnv
    /// `providerMeta.volcengine.usage_script.{accessKeyId,secretAccessKey}`
    case volcengineUsageScriptKeys
    /// 顶层 `codexQuotaAccounts` = token manager 决议的短期 access token 映射
    case codexQuotaAccounts
    /// 顶层 `antigravityOAuth` = Keychain JSON 对象
    case antigravityOAuthJSON
    /// `providerMeta.claude.enabled` + 可选顶层 `claudeOAuth` JSON
    case claudeMetaEnabledPlusOptionalOAuth
    /// `providerMeta.grok.enabled` + 可选顶层 `grokOAuth` JSON
    case grokMetaEnabledPlusOptionalOAuth
}

// MARK: - ConfiguredRule

/// Provider "已配置" 判定规则. 纯求值见 `ConfiguredRuleEvaluator`;
/// 本机文件/Keychain I/O 由 App 层 `LocalCredentialProbe` 负责.
public enum ConfiguredRule: Sendable, Equatable {
    /// 全部 `credentialAccounts` 在 Keychain 非空
    case allCredentialAccountsNonEmpty
    /// Codex: 至少一个 v2 完整凭证 record (非 metadata-only)
    case codexHasConfiguredRecords
    /// Claude: 应用 Keychain 凭证优先, 否则本机 CLI 登录态探测
    case claudeAppOrLocalProbe
    /// Grok: 应用 Keychain 凭证优先, 否则本机 CLI 登录态探测
    case grokAppOrLocalProbe
}

// MARK: - ConfiguredRuleEvaluator

/// 纯规则求值: 无 I/O, 输入由调用方预加载 (Keychain 值 / Codex 探测 / 本机可用性).
public enum ConfiguredRuleEvaluator {
    /// 求值输入. `accountValues` 只收录非空字符串; 缺失键视为未配置.
    public struct Inputs: Sendable, Equatable {
        public var accountValues: [String: String]
        public var codexHasConfiguredRecords: Bool
        public var claudeLocalAvailable: Bool
        public var grokLocalAvailable: Bool
        public var now: Date

        public init(
            accountValues: [String: String] = [:],
            codexHasConfiguredRecords: Bool = false,
            claudeLocalAvailable: Bool = false,
            grokLocalAvailable: Bool = false,
            now: Date = Date()
        ) {
            self.accountValues = accountValues
            self.codexHasConfiguredRecords = codexHasConfiguredRecords
            self.claudeLocalAvailable = claudeLocalAvailable
            self.grokLocalAvailable = grokLocalAvailable
            self.now = now
        }
    }

    /// 按 `ConfiguredRule` 判定 provider 是否已配置.
    ///
    /// - `allCredentialAccountsNonEmpty`: 每个 account 均有非空值
    /// - `codexHasConfiguredRecords`: 透传 Codex store 结果 (fail-closed 由调用方保证)
    /// - `claudeAppOrLocalProbe` / `grokAppOrLocalProbe`: 应用 Keychain 有效凭证优先,
    ///   否则回退本机 CLI 登录态标志
    public static func evaluate(
        _ rule: ConfiguredRule,
        accounts: [String],
        inputs: Inputs
    ) -> Bool {
        switch rule {
        case .allCredentialAccountsNonEmpty:
            // 空 accounts 视为 true (与历史 for-loop 空迭代语义一致; Codex 不用本规则).
            for account in accounts {
                guard let value = inputs.accountValues[account], !value.isEmpty else {
                    return false
                }
            }
            return true

        case .codexHasConfiguredRecords:
            return inputs.codexHasConfiguredRecords

        case .claudeAppOrLocalProbe:
            if let raw = inputs.accountValues[SubscriptionCredentialAccount.claudeOAuth],
               !raw.isEmpty {
                return SubscriptionCredentialEvaluator.claudeStatus(
                    of: raw, now: inputs.now
                ) == .valid
            }
            return inputs.claudeLocalAvailable

        case .grokAppOrLocalProbe:
            if let raw = inputs.accountValues[SubscriptionCredentialAccount.grokOAuth],
               !raw.isEmpty {
                return SubscriptionCredentialEvaluator.grokStatus(
                    of: raw, now: inputs.now
                ) == .valid
            }
            return inputs.grokLocalAvailable
        }
    }
}

// MARK: - ProviderDescriptor

/// 单一 provider 的注册描述: 凭证账户, 注入形状, configured 规则.
public struct ProviderDescriptor: Sendable, Equatable {
    public let id: SubscriptionProviderID
    /// Keychain account 键列表; Codex 为空 (v2 分账号键由 CodexCredentialStore 管理).
    public let credentialAccounts: [String]
    public let injectionKind: InjectionKind
    public let configuredRule: ConfiguredRule

    public init(
        id: SubscriptionProviderID,
        credentialAccounts: [String],
        injectionKind: InjectionKind,
        configuredRule: ConfiguredRule
    ) {
        self.id = id
        self.credentialAccounts = credentialAccounts
        self.injectionKind = injectionKind
        self.configuredRule = configuredRule
    }
}

// MARK: - ProviderRegistry

/// 订阅 provider 注册表. 新增 provider 时优先在此登记, 再补注入/探测实现.
public enum ProviderRegistry {
    /// 全部 provider 描述, 顺序与 `SubscriptionProviderID.allCases` 一致.
    public static var all: [ProviderDescriptor] {
        SubscriptionProviderID.allCases.map(descriptor(for:))
    }

    /// 按 id 取描述; 每个 `SubscriptionProviderID` 必须有登记.
    public static func descriptor(for id: SubscriptionProviderID) -> ProviderDescriptor {
        switch id {
        case .kimi:
            return ProviderDescriptor(
                id: .kimi,
                credentialAccounts: [SubscriptionCredentialAccount.kimiWebTokens],
                injectionKind: .kimiWebTokensJSON,
                configuredRule: .allCredentialAccountsNonEmpty
            )
        case .deepseek:
            return ProviderDescriptor(
                id: .deepseek,
                credentialAccounts: [SubscriptionCredentialAccount.deepseekAPIKey],
                injectionKind: .deepseekAPIKeyEnv,
                configuredRule: .allCredentialAccountsNonEmpty
            )
        case .volcengine:
            return ProviderDescriptor(
                id: .volcengine,
                credentialAccounts: [
                    SubscriptionCredentialAccount.volcengineAccessKey,
                    SubscriptionCredentialAccount.volcengineSecretKey,
                ],
                injectionKind: .volcengineUsageScriptKeys,
                configuredRule: .allCredentialAccountsNonEmpty
            )
        case .codex:
            return ProviderDescriptor(
                id: .codex,
                // v2 分账号键不在此枚举; 旧整体库键只供迁移, 不得作为运行时目标.
                credentialAccounts: [],
                injectionKind: .codexQuotaAccounts,
                configuredRule: .codexHasConfiguredRecords
            )
        case .antigravity:
            return ProviderDescriptor(
                id: .antigravity,
                credentialAccounts: [SubscriptionCredentialAccount.antigravityOAuth],
                injectionKind: .antigravityOAuthJSON,
                configuredRule: .allCredentialAccountsNonEmpty
            )
        case .claude:
            return ProviderDescriptor(
                id: .claude,
                credentialAccounts: [SubscriptionCredentialAccount.claudeOAuth],
                injectionKind: .claudeMetaEnabledPlusOptionalOAuth,
                configuredRule: .claudeAppOrLocalProbe
            )
        case .grok:
            return ProviderDescriptor(
                id: .grok,
                credentialAccounts: [SubscriptionCredentialAccount.grokOAuth],
                injectionKind: .grokMetaEnabledPlusOptionalOAuth,
                configuredRule: .grokAppOrLocalProbe
            )
        }
    }
}
