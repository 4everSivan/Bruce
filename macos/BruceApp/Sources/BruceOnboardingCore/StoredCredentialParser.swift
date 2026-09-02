import Foundation

// MARK: - StoredCredentialParser

/// 解析 `ProviderAccountStore` 中持久化的 `credentialJSON`, 供「重新验证」复用
/// 已存凭证. 不同 provider 的凭证形态各异, 本解析器只覆盖可本地重跑的结构化形态:
/// Kimi / DeepSeek 裸 key 字符串, 火山引擎 `{"accessKey","secretKey"}`,
/// 智谱 `{"api_key","base_url"}`. Claude / Grok / OpenCode GO 为 OAuth JSON,
/// 重新验证走对应 Evaluator, 本法返回 nil.
public enum StoredCredentialParser {
    /// 解析出的结构化凭证形态.
    public enum Parsed: Equatable {
        case apiKey(String)
        case akSk(accessKey: String, secretKey: String)
        case zhipu(apiKey: String, baseURL: String)
    }

    /// 按 provider 解析 `credentialJSON`.
    /// 裸字符串按 kimi/deepseek 处理; 非法 JSON / 缺字段 / OAuth 形态返回 nil.
    public static func parse(
        provider: SubscriptionProviderID,
        credentialJSON: String
    ) -> Parsed? {
        let trimmed = credentialJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        switch provider {
        case .kimi, .deepseek:
            return trimmed.isEmpty ? nil : .apiKey(trimmed)
        case .volcengine:
            guard let dict = jsonObject(from: trimmed),
                  let ak = dict["accessKey"] as? String,
                  let sk = dict["secretKey"] as? String,
                  !ak.isEmpty, !sk.isEmpty else {
                return nil
            }
            return .akSk(accessKey: ak, secretKey: sk)
        case .zhipu:
            guard let dict = jsonObject(from: trimmed),
                  let key = dict["api_key"] as? String,
                  let base = dict["base_url"] as? String,
                  !key.isEmpty, !base.isEmpty else {
                return nil
            }
            return .zhipu(apiKey: key, baseURL: base)
        case .claude, .grok, .opencodeGo, .codex, .antigravity:
            // OAuth / token manager 形态: 重新验证由对应 Evaluator 承担, 此处不解析.
            return nil
        }
    }

    /// 解析 JSON 字符串为字典; 非对象或解析失败返回 nil.
    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }
}
