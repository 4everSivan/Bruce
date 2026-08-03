import Foundation

// MARK: - CredentialRotationUpdate

/// Collector credentialUpdates 条目 (对照 collect_usage.py _record_credential_update).
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
/// 结构对齐 collect_usage.py 的消费方式:
/// kimi 顶层平铺 access/refresh; antigravity 合并 token 子对象.
/// 输出 JSON 使用 sortedKeys 保证稳定.
/// Codex 不在此写回: 令牌链由 CodexTokenManager 独占持有并持久化,
/// 不消费 Collector 的 rotation 条目 (任务 6 起).
public enum CredentialRotationMerge {
    /// 允许写回的令牌键, 与 collect_usage.py 的白名单一致.
    private static let allowedKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "expiry",
    ]

    /// provider -> Keychain account 映射; 未知 provider 返回 nil (不写回).
    /// Codex 明确排除: App 不向旧 `codex:accounts` 整体库写回轮换令牌
    /// (任务 11, 旧键只供迁移读取).
    public static func keychainAccount(forProvider provider: String) -> String? {
        switch provider {
        case "kimi":
            return SubscriptionCredentialAccount.kimiWebTokens
        case "antigravity":
            return SubscriptionCredentialAccount.antigravityOAuth
        default:
            return nil
        }
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
        case "kimi":
            for (key, value) in tokens { root[key] = value }
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
