//! 本机 Claude CLI 登录态只读跟随 (C075)。
//!
//! 对齐 mac `SystemExternalCredentialReader` (Claude 分支) + `ClaudePasteParser`:
//! Windows 无 Keychain, 读取序为 `%USERPROFILE%\.claude\.credentials.json` →
//! `%USERPROFILE%\.claude.json` (mac 读取序去掉 Keychain 段), 命中内容规范化为
//! `{"claudeAiOauth":{…}}` 载荷后注入 `claudeQuotaAccounts`。
//!
//! 红线: 仅只读。文件缺失 / 非 UTF-8 / JSON 非法 / 无 accessToken 一律静默回落,
//! 既不报错也不回写外部文件; 手工粘贴路径始终保留作多账号兜底。

use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// 本机 Claude 登录态探测结论 (设置页状态文案 + 自动跟随判定)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ClaudeLocalStatus {
    /// 读到结构完整且未过期的 accessToken。
    Followed,
    /// 读到登录态但 accessToken 已过期 (与 cc-switch 同口径: 过期也照常试一把查询)。
    Expired,
    /// 无文件 / 不可读 / 结构非法 / 无 accessToken。
    NotFound,
}

impl ClaudeLocalStatus {
    /// 前端契约值 (camelCase)。
    pub fn as_str(self) -> &'static str {
        match self {
            ClaudeLocalStatus::Followed => "followed",
            ClaudeLocalStatus::Expired => "expired",
            ClaudeLocalStatus::NotFound => "notFound",
        }
    }
}

/// 候选凭证文件, 按读取序 (先 `.claude/.credentials.json`, 再 `.claude.json`)。
pub fn candidate_paths(home: &Path) -> [PathBuf; 2] {
    [
        home.join(".claude").join(".credentials.json"),
        home.join(".claude.json"),
    ]
}

/// 规范化 Claude 凭证文本 (对齐 mac `ClaudePasteParser`): 接受包装键
/// `claudeAiOauth` / `claude.ai_oauth`, 或 OAuth 条目本体, 或纯 token (仅取首段
/// accessToken, 第二段作 refreshToken)。返回 `{"claudeAiOauth":{…}}` 对象;
/// 无 accessToken / JSON 非法 / 非对象时返回 None。
pub fn parse_claude_credential(input: &str) -> Option<Value> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let mut wrapper = "claudeAiOauth";
    let mut entry: Map<String, Value> = Map::new();
    let access_token;
    if trimmed.starts_with('{') {
        let value: Value = serde_json::from_str(trimmed).ok()?;
        let object = value.as_object()?;
        if let Some(oauth) = object.get("claudeAiOauth").and_then(Value::as_object) {
            entry = oauth.clone();
        } else if let Some(oauth) = object.get("claude.ai_oauth").and_then(Value::as_object) {
            wrapper = "claude.ai_oauth";
            entry = oauth.clone();
        } else {
            // 直接粘贴 OAuth 条目本体 (无包装键)。
            entry = object.clone();
        }
        access_token = entry
            .get("accessToken")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_owned();
    } else {
        // 纯 token: 单段或空白分隔 (token [refreshToken])。
        let mut tokens = trimmed.split_whitespace();
        access_token = tokens.next().unwrap_or("").to_owned();
        if let Some(refresh) = tokens.next() {
            entry.insert("refreshToken".to_owned(), Value::String(refresh.to_owned()));
        }
    }
    if access_token.is_empty() {
        return None;
    }
    entry.insert("accessToken".to_owned(), Value::String(access_token));
    let mut payload = Map::new();
    payload.insert(wrapper.to_owned(), Value::Object(entry));
    Some(Value::Object(payload))
}

/// 读取本机 Claude 凭证原始文本 (首个存在且可读的候选文件; 非 UTF-8 视为不可读并继续回退)。
/// 与 mac `readFile` 同序: 命中即返回原文, 不在此层判定结构合法性。
fn read_local_claude_raw(home: &Path) -> Option<String> {
    for path in candidate_paths(home) {
        if let Ok(text) = std::fs::read_to_string(&path) {
            return Some(text);
        }
    }
    None
}

/// 从本机文件读取并规范化 Claude OAuth 载荷; 无可用登录态返回 None。
pub fn read_local_claude_oauth(home: &Path) -> Option<Value> {
    read_local_claude_raw(home).and_then(|raw| parse_claude_credential(&raw))
}

/// 规范化载荷的包装条目。
fn oauth_entry(oauth: &Value) -> Option<&Map<String, Value>> {
    oauth
        .as_object()
        .and_then(|object| {
            object
                .get("claudeAiOauth")
                .or_else(|| object.get("claude.ai_oauth"))
        })
        .and_then(Value::as_object)
}

/// 过期判定 (对齐 mac `SubscriptionCredentialEvaluator.isExpired`): nil / 无法解析
/// 一律视为未过期; 数值 > 1e12 视为毫秒, 否则视为秒; 字符串按 RFC 3339 解析。
/// `pub(super)`: Grok 本机跟随 (C085) 复用同一张判定表, 避免两处口径漂移。
pub(super) fn is_expired(value: Option<&Value>, now_ms: i64) -> bool {
    let Some(value) = value else {
        return false;
    };
    let seconds = match value {
        Value::Number(number) => {
            let ts = number.as_f64().unwrap_or(0.0);
            if ts > 1e12 {
                ts / 1000.0
            } else {
                ts
            }
        }
        Value::String(text) => match chrono::DateTime::parse_from_rfc3339(text) {
            Ok(parsed) => parsed.timestamp_millis() as f64 / 1000.0,
            Err(_) => return false,
        },
        _ => return false,
    };
    (seconds * 1000.0) < now_ms as f64
}

/// 载荷的 accessToken 是否已过期。
fn oauth_expired(oauth: &Value, now_ms: i64) -> bool {
    is_expired(
        oauth_entry(oauth).and_then(|entry| entry.get("expiresAt")),
        now_ms,
    )
}

/// 载荷的 `expiresAt` 数值 (用于「本机比已存更新」判定); 缺失返回 0。
fn oauth_expires_at(oauth: &Value) -> i64 {
    oauth_entry(oauth)
        .and_then(|entry| entry.get("expiresAt"))
        .and_then(|value| match value {
            Value::Number(number) => number
                .as_i64()
                .or_else(|| number.as_f64().map(|f| f as i64)),
            Value::String(text) => text.parse().ok(),
            _ => None,
        })
        .unwrap_or(0)
}

/// 由规范化载荷判定状态 (未过期 = Followed, 已过期 = Expired)。
pub fn status_of(oauth: &Value, now_ms: i64) -> ClaudeLocalStatus {
    if oauth_expired(oauth, now_ms) {
        ClaudeLocalStatus::Expired
    } else {
        ClaudeLocalStatus::Followed
    }
}

/// 探测本机 Claude 登录态 (只读, 无副作用)。
pub fn local_claude_status(home: &Path, now_ms: i64) -> ClaudeLocalStatus {
    match read_local_claude_oauth(home) {
        None => ClaudeLocalStatus::NotFound,
        Some(oauth) => status_of(&oauth, now_ms),
    }
}

/// `claudeQuotaAccounts` 的跟随账号载荷 (与 mac externalOAuthAccount 同形状)。
pub fn claude_cli_account(oauth: &Value) -> Value {
    json!({"display_name": "Claude CLI", "oauth": oauth})
}

/// 采集前把本机 Claude 登录态注入 `claudeQuotaAccounts` (对齐 mac CollectorRunInput):
/// 无已存账号时新增 `claude-cli`; 已存 `claude-cli` 且本机 expiresAt 更大时替换。
/// 无可用本机登录态时原样返回 (不新增空字段)。
pub fn with_local_claude(
    mut payloads: super::CredentialPayloads,
    home: &Path,
) -> super::CredentialPayloads {
    let Some(oauth) = read_local_claude_oauth(home) else {
        return payloads;
    };
    let mut accounts = payloads
        .get("claudeQuotaAccounts")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if accounts.is_empty() {
        // 无任何已存账号: 直接跟随本机登录态 (零配置路径)。
        accounts.insert("claude-cli".to_owned(), claude_cli_account(&oauth));
    } else if let Some(stored) = accounts.get("claude-cli") {
        // 已跟随过: 仅当本机登录态更新 (expiresAt 更大) 时替换。
        let stored_exp = stored.get("oauth").map(oauth_expires_at).unwrap_or(0);
        if oauth_expires_at(&oauth) > stored_exp {
            accounts.insert("claude-cli".to_owned(), claude_cli_account(&oauth));
        } else {
            return payloads;
        }
    } else {
        // 用户已存自有账号: 不注入 CLI 跟随 (对齐 mac), 手工配置优先。
        return payloads;
    }
    payloads.insert("claudeQuotaAccounts".to_owned(), Value::Object(accounts));
    payloads
}
