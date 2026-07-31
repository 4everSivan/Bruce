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

/// 每次运行前向 Scheduler 提供受控 context 和 credentials.
@MainActor
protocol CollectorRunInputProviding {
    func runInput(for module: CollectorModule) throws -> CollectorRunInput
}

/// 基于 Onboarding 配置和 Keychain 的运行输入提供器.
/// Agent: 授予 localSessions/localPricing; 统一授权已确认且至少一个订阅
/// provider enabled 且 Keychain 凭证完整时追加 externalQuotas, 并把凭证
/// 装配进 Bridge 注入键 (对照 bridge/security.py 白名单).
/// GitHub: 不传 token, 由 gh 官方登录态承载.
/// GitLab: 从配置读规范化 base URL, 从 Keychain 读 PAT; 两者缺失都阻止启动.
@MainActor
package final class OnboardingRunInputProvider: CollectorRunInputProviding {
    private let configStore: OnboardingConfigurationStore?
    private let credentialStore: CredentialStore

    package init(
        configStore: OnboardingConfigurationStore?,
        credentialStore: CredentialStore
    ) {
        self.configStore = configStore
        self.credentialStore = credentialStore
    }

    func runInput(for module: CollectorModule) throws -> CollectorRunInput {
        switch module {
        case .agentUsage:
            return agentUsageInput()
        case .github:
            return CollectorRunInput(context: [:], credentials: [:])
        case .gitlab:
            return try gitLabInput()
        }
    }

    private func agentUsageInput() -> CollectorRunInput {
        var capabilities: [JSONValue] = [
            .string(CollectorCapability.localSessions.rawValue),
            .string(CollectorCapability.localPricing.rawValue),
        ]
        var credentials: [String: JSONValue] = [:]

        let config = configStore?.load()
        // 统一授权未确认时永远不授予 externalQuotas;
        // 一个 provider 都没配齐时也不授予, collector 会返回未授权占位
        if config?.consentVersion != nil {
            let assembled = assembleSubscriptionCredentials(
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
    private func assembleSubscriptionCredentials(
        providers: [String: SubscriptionProviderConfiguration]
    ) -> [String: JSONValue] {
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
           let raw = load(SubscriptionCredentialAccount.codexAccounts),
           let accounts = jsonObjectValue(from: raw) {
            credentials["codexOAuthAccounts"] = accounts
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
    package func apply(credentialUpdates: [JSONValue]) {
        for value in credentialUpdates {
            guard let update = Self.rotationUpdate(from: value),
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

    private func gitLabInput() throws -> CollectorRunInput {
        guard let rawBaseURL = configStore?.load()?.gitlabBaseURL,
              let baseURL = ProviderConnectionVerifier.normalizedGitLabBaseURL(rawBaseURL),
              let host = baseURL.host else {
            throw CollectorRunInputError.missingDependency(
                module: .gitlab,
                reason: "未配置私有 GitLab HTTPS 地址"
            )
        }
        guard let pat = try credentialStore.loadPAT(forHost: host),
              !pat.isEmpty else {
            throw CollectorRunInputError.missingAuthorization(
                module: .gitlab,
                reason: "GitLab 凭证缺失, 请在设置中重新配置 PAT"
            )
        }
        return CollectorRunInput(
            context: ["baseUrl": .string(baseURL.absoluteString)],
            credentials: ["gitlabToken": .string(pat)]
        )
    }
}
