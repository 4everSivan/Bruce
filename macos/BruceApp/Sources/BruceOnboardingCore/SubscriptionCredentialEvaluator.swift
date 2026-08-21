import Foundation

// MARK: - SubscriptionCredentialStatus

/// 订阅凭证健康状态 (统一过期检测入口, Phase 1).
/// 与 Rust provider credential contract 的过期语义保持一致: 无过期字段或无法解析
/// 一律视为未过期 (由查询失败自然暴露), 防止两层判定分叉.
public enum SubscriptionCredentialStatus: Equatable, Sendable {
    /// 凭证缺失或不可用.
    case missing
    /// 凭证结构完整且未过期.
    case valid
    /// 凭证存在但已过期.
    case expired
    /// 凭证结构损坏或缺少关键字段.
    case malformed
}

// MARK: - SubscriptionCredentialEvaluator

/// 统一的订阅凭证健康判定器 (Phase 1).
///
/// 纯静态函数, 无 I/O, 无外部依赖; 输入凭证 JSON 字符串 + 可注入时钟.
/// 判定规则与 Rust provider credential evaluator 的
/// expiry / Grok entry / Claude credential 规则逐条对齐,
/// 从机制上消除 Swift 显示层与 Collector 查询层的语义分叉.
public enum SubscriptionCredentialEvaluator {
    // MARK: - 过期判定

    /// 与 Rust Collector expiry 规则同语义的过期判定:
    /// - nil 或无法解析 -> 未过期 (false)
    /// - 数字: > 1e12 视为毫秒, 否则视为秒
    /// - 字符串: ISO 8601, 解析失败 -> 未过期
    public static func isExpired(_ value: Any?, now: Date) -> Bool {
        guard let value else { return false }
        let nowTS = now.timeIntervalSince1970
        if let number = value as? NSNumber {
            let ts = number.doubleValue
            let seconds = ts > 1_000_000_000_000 ? ts / 1000 : ts
            return seconds < nowTS
        }
        if let number = value as? Double {
            let seconds = number > 1_000_000_000_000 ? number / 1000 : number
            return seconds < nowTS
        }
        if let string = value as? String {
            let parsed = Self.parseISO(string)
            return parsed.map { $0 < nowTS } ?? false
        }
        return false
    }

    /// 解析 ISO 8601 时间戳; 失败返回 nil.
    private static func parseISO(_ string: String) -> Double? {
        let normalized = string.replacingOccurrences(of: "Z", with: "+00:00")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date.timeIntervalSince1970
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) {
            return date.timeIntervalSince1970
        }
        // 兼容无时区的本地时间.
        let noZoneFormatter = DateFormatter()
        noZoneFormatter.locale = Locale(identifier: "en_US_POSIX")
        noZoneFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if let date = noZoneFormatter.date(from: normalized) {
            return date.timeIntervalSince1970
        }
        return nil
    }

    // MARK: - Grok

    /// Grok auth.json 健康判定: OIDC scope (`https://auth.x.ai::` 前缀) 优先,
    /// legacy `/sign-in` scope 兜底, key 非空; 再查 expires_at.
    /// 与 Rust Collector 的 Grok entry / expiry 规则同语义.
    public static func grokStatus(of json: String, now: Date) -> SubscriptionCredentialStatus {
        guard let dict = jsonObject(from: json) else {
            return .malformed
        }
        var oidc: [String: Any]?
        var legacy: [String: Any]?
        for (scope, value) in dict {
            guard let entry = value as? [String: Any] else { continue }
            guard let key = entry["key"] as? String, !key.isEmpty else { continue }
            if scope.hasPrefix("https://auth.x.ai::") {
                oidc = entry
            } else if scope == "https://accounts.x.ai/sign-in" || scope.contains("/sign-in") {
                legacy = entry
            }
        }
        guard let entry = oidc ?? legacy else {
            return .missing
        }
        if isExpired(entry["expires_at"], now: now) {
            return .expired
        }
        return .valid
    }

    // MARK: - Claude

    /// Claude 凭证 JSON 健康判定: `claudeAiOauth` / `claude.ai_oauth` 节点,
    /// accessToken 非空, 再查 expiresAt. 与 Rust Collector 规则同语义.
    public static func claudeStatus(of json: String, now: Date) -> SubscriptionCredentialStatus {
        guard let dict = jsonObject(from: json) else {
            return .malformed
        }
        let entry = (dict["claudeAiOauth"] as? [String: Any])
            ?? (dict["claude.ai_oauth"] as? [String: Any])
        guard let entry else {
            return .missing
        }
        let token = (entry["accessToken"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .missing
        }
        if isExpired(entry["expiresAt"], now: now) {
            return .expired
        }
        return .valid
    }

    // MARK: - Kimi / Antigravity

    /// Kimi For Coding API key: 非空且不含空白.
    public static func kimiStatus(of apiKey: String) -> SubscriptionCredentialStatus {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            return .missing
        }
        if key.contains(where: { $0.isWhitespace }) {
            return .malformed
        }
        return .valid
    }

    /// Antigravity 令牌 JSON: token.refresh_token 非空 (collector 刷新恢复).
    public static func antigravityStatus(of json: String) -> SubscriptionCredentialStatus {
        guard let dict = jsonObject(from: json),
              let token = dict["token"] as? [String: Any] else {
            return .malformed
        }
        let refresh = (token["refresh_token"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty else {
            return .missing
        }
        return .valid
    }

    /// OpenCode GO 凭证 JSON: {"auth": <Fe26 cookie>, "workspaceId": "wrk_..."}
    /// 两者均非空才 valid (collector 凭此调网页 server function).
    public static func opencodeGoStatus(of json: String) -> SubscriptionCredentialStatus {
        guard let dict = jsonObject(from: json) else {
            return .malformed
        }
        let auth = (dict["auth"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = (dict["workspaceId"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if auth.isEmpty && workspace.isEmpty {
            return .missing
        }
        if auth.isEmpty || workspace.isEmpty {
            return .malformed
        }
        return .valid
    }

    // MARK: - 辅助

    /// 解析 JSON 字符串为对象; 非对象或解析失败返回 nil.
    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }
}
