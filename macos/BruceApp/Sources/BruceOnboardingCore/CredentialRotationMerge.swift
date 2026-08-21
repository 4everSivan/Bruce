import Foundation

// MARK: - CredentialRotationUpdate

/// Collector credentialUpdates 条目 (对照 Rust Bridge credential update contract).
/// 只构造自 kind=oauthTokens 且 operation=replace 的条目;
/// tokens 已按 collector 白名单过滤为字符串键值.
public struct CredentialRotationUpdate: Equatable, Sendable {
    public let provider: String
    public let accountId: String
    public let tokens: [String: String]

    public init(provider: String, accountId: String, tokens: [String: String]) {
        self.provider = provider
        self.accountId = accountId
        self.tokens = tokens
    }
}

// MARK: - CredentialRotationMerge

/// Collector 轮换令牌写回 Keychain 的纯合并逻辑.
    /// 结构对齐 Rust Collector 的消费方式:
/// kimi 顶层平铺 access/refresh; antigravity 合并 token 子对象.
/// 输出 JSON 使用 sortedKeys 保证稳定.
/// Codex 不在此写回: 令牌链由 CodexTokenManager 独占持有并持久化,
/// 不消费 Collector 的 rotation 条目 (任务 6 起).
public enum CredentialRotationMerge {
    /// 允许写回的令牌键, 与 Rust Bridge 的白名单一致.
    private static let allowedKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "expiry",
    ]

    /// provider -> Keychain account 映射; 未知 provider 返回 nil (不写回).
    /// Codex 明确排除: App 不向旧 `codex:accounts` 整体库写回轮换令牌
    /// (任务 11, 旧键只供迁移读取).
    public static func keychainAccount(forProvider provider: String) -> String? {
        switch provider {
        case "antigravity":
            return SubscriptionCredentialAccount.antigravityOAuth
        default:
            return nil
        }
    }

    /// 是否支持按账号 (accountId) 写回轮换令牌.
    /// 多账号 provider 均返回 true; 未知 provider 返回 false.
    public static func supportsAccountScopedRotation(forProvider provider: String) -> Bool {
        switch provider {
        case "deepseek", "volcengine", "antigravity", "claude", "grok":
            return true
        default:
            return false
        }
    }

    /// 把轮换令牌合并进 provider 的多账号 per-account record 的 credentialJSON.
    /// accountId 在 index 中必须存在; 更新后保存 record, 返回新 credentialJSON.
    /// 凭证格式按 provider 组装: Kimi/Antigravity/Claude/Grok 为 JSON,
    /// DeepSeek 为纯字符串, 火山为 {"accessKey","secretKey"}.
    public static func mergedAccountJSON(
        existingCredentialJSON: String?,
        update: CredentialRotationUpdate,
        providerID: SubscriptionProviderID
    ) -> String? {
        let tokens = update.tokens.filter { key, value in
            allowedKeys.contains(key) && !value.isEmpty
        }
        guard !tokens.isEmpty else { return nil }

        switch providerID {
        case .kimi:
            // Kimi For Coding API key 不参与 OAuth 轮换, 无令牌写回.
            return nil

        case .antigravity:
            var root: [String: Any] = [:]
            if let existingCredentialJSON,
               let data = existingCredentialJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                root = dict
            }
            var token = root["token"] as? [String: Any] ?? [:]
            for (key, value) in tokens { token[key] = value }
            root["token"] = token
            return Self.jsonString(from: root)

        case .claude, .grok, .opencodeGo:
            // claudeAiOauth / scope 映射同构 JSON, 直接合并顶层
            var root: [String: Any] = [:]
            if let existingCredentialJSON,
               let data = existingCredentialJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                root = dict
            }
            for (key, value) in tokens { root[key] = value }
            return Self.jsonString(from: root)

        case .deepseek:
            // 纯字符串 API key: 轮换令牌取 access_token 或 refresh_token
            let key = tokens["access_token"] ?? tokens["refresh_token"]
            return key

        case .volcengine:
            var root: [String: Any] = [:]
            if let existingCredentialJSON,
               let data = existingCredentialJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dict = object as? [String: Any] {
                root = dict
            }
            if let ak = tokens["access_token"] { root["accessKey"] = ak }
            if let sk = tokens["refresh_token"] { root["secretKey"] = sk }
            return Self.jsonString(from: root)

        case .codex:
            return nil
        case .zhipu:
            // 智谱 API key 不参与 OAuth 轮换, 无令牌写回.
            return nil
        }
    }

    private static func jsonString(from dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// 把轮换令牌合并进既有 Keychain JSON, 返回新 JSON.
    /// 既有 JSON 缺失或损坏时以空结构起步 (更新来自一次成功的刷新,
    /// 令牌本身完整可用); 未知 provider 或无有效令牌返回 nil.
    public static func mergedJSON(
        existingJSON: String?,
        update: CredentialRotationUpdate
    ) -> String? {
        guard keychainAccount(forProvider: update.provider) != nil else {
            return nil
        }
        let tokens = update.tokens.filter { key, value in
            allowedKeys.contains(key) && !value.isEmpty
        }
        guard !tokens.isEmpty else { return nil }

        var root: [String: Any] = [:]
        if let existingJSON,
           let data = existingJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            root = dict
        }

        switch update.provider {
        case "antigravity":
            var token = root["token"] as? [String: Any] ?? [:]
            for (key, value) in tokens { token[key] = value }
            root["token"] = token
        default:
            return nil
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
