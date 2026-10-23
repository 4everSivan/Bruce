//! 本机 Grok CLI 登录态只读跟随 (C085 / 设计规则 20)。
//!
//! 对齐 mac `LocalCredentialProbe.grokLocalAuthAvailable` +
//! `SubscriptionCredentialEvaluator.grokStatus`: 只读 `%USERPROFILE%\.grok\auth.json`,
//! 取带非空 `key` 的 OIDC (`https://auth.x.ai::*`) 或 legacy (`*/sign-in`) 作用域条目,
//! 按条目 `expires_at` 判过期; 命中即注入 `grokQuotaAccounts` 的 `grok-cli` 账号。
//!
//! 红线: 仅只读。文件缺失 / 非 UTF-8 / JSON 非法 / 无可识别作用域一律静默回落,
//! 既不报错也不回写外部文件; 手工粘贴路径始终保留作多账号兜底。

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

use super::claude_local::is_expired;

/// 本机 Grok 登录态探测结论 (设置页状态文案 + 自动跟随判定)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrokLocalStatus {
    /// 读到带 key 且未过期的作用域条目。
    Followed,
    /// 读到条目但 `expires_at` 已过期。
    Expired,
    /// 无文件 / 不可读 / 结构非法 / 无带 key 的作用域条目。
    NotFound,
}

impl GrokLocalStatus {
    /// 前端契约值 (camelCase)。
    pub fn as_str(self) -> &'static str {
        match self {
            GrokLocalStatus::Followed => "followed",
            GrokLocalStatus::Expired => "expired",
            GrokLocalStatus::NotFound => "notFound",
        }
    }
}

/// Grok CLI 认证文件路径。
pub fn candidate_path(home: &Path) -> PathBuf {
    home.join(".grok").join("auth.json")
}

/// 作用域是否为采集端 `grok_oauth_has_token` 认得的两类之一。
fn recognized_scope(scope: &str) -> bool {
    scope.starts_with("https://auth.x.ai::")
        || scope == "https://accounts.x.ai/sign-in"
        || scope.contains("/sign-in")
}

fn non_empty_key(entry: &Value) -> bool {
    entry
        .as_object()
        .and_then(|object| object.get("key"))
        .and_then(Value::as_str)
        .is_some_and(|key| !key.trim().is_empty())
}

/// 规范化 Grok 凭证文本: 只保留带非空 `key` 的可识别作用域条目, 作用域键原样保留
/// (采集端按同一张表解析)。无可用条目 / JSON 非法 / 非对象时返回 None。
pub fn parse_grok_credential(input: &str) -> Option<Value> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let value: Value = serde_json::from_str(trimmed).ok()?;
    let object = value.as_object()?;
    let kept: Map<String, Value> = object
        .iter()
        .filter(|(scope, entry)| recognized_scope(scope) && non_empty_key(entry))
        .map(|(scope, entry)| (scope.clone(), entry.clone()))
        .collect();
    (!kept.is_empty()).then_some(Value::Object(kept))
}

/// 读取本机 Grok 凭证原始文本 (非 UTF-8 视为不可读)。
fn read_local_grok_raw(home: &Path) -> Option<String> {
    std::fs::read_to_string(candidate_path(home)).ok()
}

/// 从本机文件读取并规范化 Grok OAuth 载荷; 无可用登录态返回 None。
pub fn read_local_grok_oauth(home: &Path) -> Option<Value> {
    read_local_grok_raw(home).and_then(|raw| parse_grok_credential(&raw))
}

/// 载荷中最早过期的作用域条目是否已过期 (无 `expires_at` 视为未过期)。
fn oauth_expired(oauth: &Value, now_ms: i64) -> bool {
    oauth.as_object().is_some_and(|object| {
        object
            .values()
            .any(|entry| is_expired(entry.get("expires_at"), now_ms))
    })
}

/// 由规范化载荷判定状态 (未过期 = Followed, 已过期 = Expired)。
pub fn status_of(oauth: &Value, now_ms: i64) -> GrokLocalStatus {
    if oauth_expired(oauth, now_ms) {
        GrokLocalStatus::Expired
    } else {
        GrokLocalStatus::Followed
    }
}

/// 探测本机 Grok 登录态 (只读, 无副作用)。
pub fn local_grok_status(home: &Path, now_ms: i64) -> GrokLocalStatus {
    match read_local_grok_oauth(home) {
        None => GrokLocalStatus::NotFound,
        Some(oauth) => status_of(&oauth, now_ms),
    }
}

/// `grokQuotaAccounts` 的跟随账号载荷 (与手工粘贴同形状: `{display_name, oauth}`)。
pub fn grok_cli_account(oauth: &Value) -> Value {
    json!({"display_name": "Grok CLI", "oauth": oauth})
}

/// 采集前把本机 Grok 登录态注入 `grokQuotaAccounts` (对齐 C075 的 Claude 同范式):
/// 无已存账号时新增 `grok-cli`; 已存 `grok-cli` 时以本机登录态为准刷新 (本机是
/// 登录态的事实源, 与 Claude 的 expiresAt 比较相比更简单可靠 —— 本机文件更新即覆盖)。
/// 用户已存自有账号时不注入 (手工配置优先)。无可用本机登录态时原样返回。
pub fn with_local_grok(
    mut payloads: super::CredentialPayloads,
    home: &Path,
) -> super::CredentialPayloads {
    let Some(oauth) = read_local_grok_oauth(home) else {
        return payloads;
    };
    let mut accounts = payloads
        .get("grokQuotaAccounts")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if accounts.is_empty() || accounts.contains_key("grok-cli") {
        // 无已存账号: 零配置注入; 已跟随过: 以本机文件为准刷新。
        accounts.insert("grok-cli".to_owned(), grok_cli_account(&oauth));
    } else {
        // 用户已存自有账号: 不注入 CLI 跟随 (对齐 mac), 手工配置优先。
        return payloads;
    }
    payloads.insert("grokQuotaAccounts".to_owned(), Value::Object(accounts));
    payloads
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_home(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("bruce-c085-{name}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join(".grok")).unwrap();
        root
    }

    #[test]
    fn parse_keeps_only_recognized_scopes_with_key() {
        let raw = r#"{
            "https://auth.x.ai::injected": {"key":"oidc-key","expires_at": 4102444800},
            "https://accounts.x.ai/sign-in": {"key":"legacy-key"},
            "https://other.example::x": {"key":"ignored"},
            "https://auth.x.ai::empty": {"key":"  "}
        }"#;
        let parsed = parse_grok_credential(raw).unwrap();
        let object = parsed.as_object().unwrap();
        assert_eq!(object.len(), 2, "只保留可识别且带非空 key 的作用域");
        assert_eq!(
            object["https://auth.x.ai::injected"]["key"],
            json!("oidc-key")
        );
        assert_eq!(
            object["https://accounts.x.ai/sign-in"]["key"],
            json!("legacy-key")
        );
        // 无可识别条目 / 非法输入一律 None
        assert!(parse_grok_credential(r#"{"https://other::x":{"key":"k"}}"#).is_none());
        assert!(parse_grok_credential("not json").is_none());
        assert!(parse_grok_credential("[]").is_none());
        assert!(parse_grok_credential("").is_none());
    }

    #[test]
    fn status_distinguishes_followed_expired_and_missing() {
        let home = temp_home("status");
        assert_eq!(local_grok_status(&home, 0), GrokLocalStatus::NotFound);

        std::fs::write(
            candidate_path(&home),
            r#"{"https://auth.x.ai::injected":{"key":"k","expires_at":4102444800}}"#,
        )
        .unwrap();
        assert_eq!(
            local_grok_status(&home, 1_700_000_000_000),
            GrokLocalStatus::Followed
        );
        // 恰在过期时刻不算过期 (与 `is_expired` 的严格小于同口径), 过一秒才算。
        assert_eq!(
            local_grok_status(&home, 4_102_444_800_000),
            GrokLocalStatus::Followed
        );
        assert_eq!(
            local_grok_status(&home, 4_102_444_800_001),
            GrokLocalStatus::Expired
        );

        std::fs::write(candidate_path(&home), "{ broken").unwrap();
        assert_eq!(local_grok_status(&home, 0), GrokLocalStatus::NotFound);
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn injection_adds_cli_account_and_respects_user_accounts() {
        let home = temp_home("inject");
        std::fs::write(
            candidate_path(&home),
            r#"{"https://auth.x.ai::injected":{"key":"k","expires_at":4102444800}}"#,
        )
        .unwrap();
        // 无已存账号: 零配置注入 grok-cli
        let injected = with_local_grok(super::super::CredentialPayloads::new(), &home);
        assert_eq!(
            injected["grokQuotaAccounts"]["grok-cli"]["oauth"]["https://auth.x.ai::injected"]
                ["key"],
            json!("k")
        );
        // 用户自有账号: 不注入
        let mut payloads = super::super::CredentialPayloads::new();
        payloads.insert(
            "grokQuotaAccounts".to_owned(),
            json!({"mine": {"display_name":"mine","oauth":{"https://auth.x.ai::injected":{"key":"user"}}}}),
        );
        let kept = with_local_grok(payloads.clone(), &home);
        assert_eq!(kept, payloads, "用户自有账号优先, 不注入 CLI 跟随");
        // 无本机登录态: 原样返回
        let empty_home =
            std::env::temp_dir().join(format!("bruce-c085-none-{}", uuid::Uuid::new_v4()));
        assert_eq!(
            with_local_grok(super::super::CredentialPayloads::new(), &empty_home),
            super::super::CredentialPayloads::new()
        );
        let _ = std::fs::remove_dir_all(&home);
    }
}
