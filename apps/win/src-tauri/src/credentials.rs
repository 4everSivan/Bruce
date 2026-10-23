//! App-owned credential storage. Secrets never cross the metadata IPC boundary.
//! Windows uses a protected DACL for the process token SID before secret writes.

mod ccswitch;
mod claude_local;
mod lifecycle;
#[cfg(windows)]
mod windows_security;
pub use ccswitch::{
    database_path as ccswitch_database_path, import_credentials as ccswitch_volcengine_credentials,
};
pub use claude_local::{local_claude_status, with_local_claude, ClaudeLocalStatus};
pub use lifecycle::{collect_with_recovery, collect_with_recovery_using, CodexRefreshError};

use collector_bridge::ALLOWED_CREDENTIAL_FIELDS;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub type CredentialPayloads = BTreeMap<String, Value>;
static STORE_LOCK: Mutex<()> = Mutex::new(());
const MAX_CREDENTIAL_BYTES: u64 = 4 * 1024 * 1024;

pub fn app_data_root(home: &Path) -> PathBuf {
    app_data_root_with(home, std::env::var_os("APPDATA").as_deref())
}
pub fn app_data_root_with(home: &Path, app_data: Option<&std::ffi::OsStr>) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(value) = app_data.filter(|value| !value.to_string_lossy().trim().is_empty()) {
            return value
                .to_str()
                .map(|s| PathBuf::from(s.trim()))
                .unwrap_or_else(|| PathBuf::from(value))
                .join("Bruce");
        }
        home.join("AppData").join("Roaming").join("Bruce")
    }
    #[cfg(not(windows))]
    {
        let _ = app_data;
        home.join("Library/Application Support/Bruce-Windows-Dev")
    }
}
fn credentials_path(root: &Path) -> PathBuf {
    root.join("credentials.json")
}
fn is_allowed_field(key: &str) -> bool {
    ALLOWED_CREDENTIAL_FIELDS.contains(&key)
}
fn valid_id(id: &str) -> bool {
    !id.trim().is_empty() && id.len() <= 256 && !id.chars().any(char::is_control)
}
fn nonempty_string(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty() && s.len() <= 32_768)
}
/// Validate the collector account-map contract, including required provider keys.
/// Error messages never interpolate credential values or arbitrary input keys.
pub fn validate_credential_payload(field: &str, payload: &Value) -> Result<(), String> {
    if !is_allowed_field(field) {
        return Err("未知凭证字段".to_owned());
    }
    let object = payload.as_object().ok_or("凭证必须是 JSON 对象")?;
    if object.len() > 64 {
        return Err("凭证账号数量超过上限".to_owned());
    }
    if field == "providerEnv" {
        return if object.values().all(Value::is_string) {
            Ok(())
        } else {
            Err("Provider 环境值必须为字符串".to_owned())
        };
    }
    if matches!(field, "providerMeta" | "claudeOAuth" | "grokOAuth") {
        return Ok(());
    }
    for (id, account) in object {
        if !valid_id(id) {
            return Err("凭证账号 ID 无效".to_owned());
        }
        let account = account.as_object().ok_or("凭证账号必须是 JSON 对象")?;
        let (allowed, required): (&[&str], &[&str]) = match field {
            "kimiQuotaAccounts"
            | "deepseekQuotaAccounts"
            | "jevQuotaAccounts"
            | "clineQuotaAccounts" => (&["display_name", "api_key"], &["api_key"]),
            "zhipuQuotaAccounts" => (
                &["display_name", "api_key", "base_url"],
                &["api_key", "base_url"],
            ),
            "volcengineQuotaAccounts" => (
                &["display_name", "accessKeyId", "secretAccessKey"],
                &["accessKeyId", "secretAccessKey"],
            ),
            "stepfunQuotaAccounts" => (&["display_name", "token", "site", "is_global"], &["token"]),
            "codexQuotaAccounts" => (
                &[
                    "display_name",
                    "access_token",
                    "refresh_token",
                    "id_token",
                    "expiry",
                    "authorization_state",
                ],
                &["display_name", "access_token"],
            ),
            "claudeQuotaAccounts" | "grokQuotaAccounts" | "opencodeGoQuotaAccounts" => {
                (&["display_name", "oauth"], &[])
            }
            _ => return Err("凭证字段不受支持".to_owned()),
        };
        if account.keys().any(|key| !allowed.contains(&key.as_str()))
            || required
                .iter()
                .any(|key| !nonempty_string(account.get(*key)))
            || account.get("display_name").is_some_and(|value| {
                !nonempty_string(Some(value)) || value.as_str().is_some_and(|s| s.len() > 256)
            })
        {
            return Err("凭证账号字段无效或缺少必填值".to_owned());
        }
        if matches!(
            field,
            "claudeQuotaAccounts" | "grokQuotaAccounts" | "opencodeGoQuotaAccounts"
        ) {
            let oauth = account.get("oauth").ok_or("OAuth 凭证必须是 JSON 对象")?;
            validate_oauth_shape(field, oauth)?;
        }
        for key in ["refresh_token", "id_token", "expiry", "authorization_state"] {
            if account.get(key).is_some_and(|value| !value.is_string()) {
                return Err("令牌字段必须为字符串".to_owned());
            }
        }
        if account
            .get("site")
            .is_some_and(|value| !matches!(value.as_str(), Some("domestic" | "global")))
            || account
                .get("is_global")
                .is_some_and(|value| !value.is_boolean())
        {
            return Err("StepFun 站点字段无效".to_owned());
        }
        validate_credential_format(field, account)?;
    }
    Ok(())
}
/// Provider 专属格式校验 (C092 / 设计规则 27)。
///
/// 逐条对应 mac `ProviderConnectionVerifier` 的本地结构校验: Kimi / Jev 非空且无空白;
/// 火山 AK/SK 非空、无空白且长度 ≥8; Z.ai 非空、无空白且含 `.`, base URL 主机为
/// bigmodel.cn / api.z.ai; StepFun 非空且无空白; Cline 非空、无空白且长度 ≥16。
/// 只拦「形状明显不合规」的密钥 —— 真实额度试查由采集端承担, 此处不发网络请求。
fn validate_credential_format(
    field: &str,
    account: &serde_json::Map<String, Value>,
) -> Result<(), String> {
    let text = |key: &str| account.get(key).and_then(Value::as_str).unwrap_or("");
    for key in ["api_key", "accessKeyId", "secretAccessKey", "token"] {
        if text(key).chars().any(char::is_whitespace) {
            return Err(format!("{key} 含空白字符, 格式不合理"));
        }
    }
    match field {
        "volcengineQuotaAccounts" => {
            for key in ["accessKeyId", "secretAccessKey"] {
                if text(key).chars().count() < 8 {
                    return Err(format!("{key} 长度不足 8 位, 格式不合理"));
                }
            }
        }
        "clineQuotaAccounts" if text("api_key").chars().count() < 16 => {
            return Err("api_key 长度不足 16 位, 格式不合理".to_owned());
        }
        "zhipuQuotaAccounts" if !text("api_key").contains('.') => {
            return Err("API key 格式不合理 (应为 id.secret 形式)".to_owned());
        }
        "zhipuQuotaAccounts" if !zhipu_host_allowed(text("base_url")) => {
            return Err("Base URL 必须是 Z.ai 个人版站点".to_owned());
        }
        "stepfunQuotaAccounts" if text("token").trim().is_empty() => {
            return Err("Oasis-Token 为空".to_owned());
        }
        "kimiQuotaAccounts" | "jevQuotaAccounts" if text("api_key").trim().is_empty() => {
            return Err("API key 为空".to_owned());
        }
        _ => {}
    }
    Ok(())
}
/// Z.ai 个人版站点主机白名单 (对齐 mac: host 含 bigmodel.cn 或 api.z.ai)。
fn zhipu_host_allowed(base_url: &str) -> bool {
    let host = base_url_host(base_url);
    host.contains("bigmodel.cn") || host.contains("api.z.ai")
}
/// 取 base URL 主机 (小写, 去端口与用户信息); 无法解析时返回空串。
fn base_url_host(base_url: &str) -> String {
    let rest = base_url.trim();
    let rest = rest.split_once("://").map_or(rest, |(_, tail)| tail);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let host = host.split(':').next().unwrap_or(host);
    host.trim_end_matches('.').to_ascii_lowercase()
}
/// OAuth 形状契约 (C081 / 设计规则 21)。
///
/// 三家 OAuth Provider 的 `oauth` 必须是采集端解析器认得的原生形状 —— 形状不对时
/// 采集端既不报错也查不出额度 (静默失效), 故在写入前拦下。逐条对应
/// `collector-provider` 的 `claude_token` / `parse_claude_oauth_credentials`、
/// `grok_token`、`opencode_credential`。
fn validate_oauth_shape(field: &str, oauth: &Value) -> Result<(), String> {
    let object = oauth.as_object().ok_or("OAuth 凭证必须是 JSON 对象")?;
    match field {
        "claudeQuotaAccounts" => claude_oauth_ready(object),
        "grokQuotaAccounts" => grok_oauth_ready(object),
        "opencodeGoQuotaAccounts" => opencode_go_oauth_ready(object),
        _ => Ok(()),
    }
}
fn claude_oauth_ready(object: &serde_json::Map<String, Value>) -> Result<(), String> {
    let entry = object
        .get("claudeAiOauth")
        .or_else(|| object.get("claude.ai_oauth"))
        .and_then(Value::as_object)
        .ok_or("Claude 凭证需 claudeAiOauth 包装")?;
    nonempty_string(entry.get("accessToken"))
        .then_some(())
        .ok_or_else(|| "Claude 凭证缺少 accessToken".to_owned())
}
fn grok_oauth_ready(object: &serde_json::Map<String, Value>) -> Result<(), String> {
    grok_oauth_has_token(object)
        .then_some(())
        .ok_or_else(|| "Grok 凭证需 key 或 https://auth.x.ai:: 作用域条目".to_owned())
}
fn opencode_go_oauth_ready(object: &serde_json::Map<String, Value>) -> Result<(), String> {
    (nonempty_string(object.get("auth")) && nonempty_string(object.get("workspaceId")))
        .then_some(())
        .ok_or_else(|| "OpenCode GO 凭证需 auth 与 workspaceId".to_owned())
}
/// 对齐 `collector-provider::grok_token`: 顶层 `key`, 或作用域条目
/// (`https://auth.x.ai::*` / `*/sign-in`) 内的 `key`。
fn grok_oauth_has_token(object: &serde_json::Map<String, Value>) -> bool {
    if nonempty_string(object.get("key")) {
        return true;
    }
    object.iter().any(|(scope, value)| {
        let Some(entry) = value.as_object() else {
            return false;
        };
        let scoped = scope.starts_with("https://auth.x.ai::")
            || scope == "https://accounts.x.ai/sign-in"
            || scope.contains("/sign-in");
        scoped && nonempty_string(entry.get("key"))
    })
}
/// 逐账号容错 (C081): 单个账号形状不合法时只丢弃该账号, 不牵连同字段的其它可用记录;
/// 全部账号都不合法时该字段整体消失 (fail-closed)。磁盘文件不被改写。
fn retain_valid_accounts(field: &str, value: &Value) -> Option<Value> {
    let accounts = value.as_object()?;
    let kept: serde_json::Map<String, Value> = accounts
        .iter()
        .filter(|(id, account)| {
            valid_id(id)
                && validate_credential_payload(field, &json!({ id.as_str(): (*account).clone() }))
                    .is_ok()
        })
        .map(|(id, account)| (id.clone(), account.clone()))
        .collect();
    (!kept.is_empty()).then_some(Value::Object(kept))
}
pub fn merge_credentials(
    existing: &CredentialPayloads,
    patch: &BTreeMap<String, Option<Value>>,
) -> Result<CredentialPayloads, String> {
    let mut merged = existing.clone();
    for (key, value) in patch {
        if !is_allowed_field(key) {
            return Err("未知凭证字段".to_owned());
        }
        match value {
            Some(value) => {
                validate_credential_payload(key, value)?;
                merged.insert(key.clone(), value.clone());
            }
            None => {
                merged.remove(key);
            }
        }
    }
    Ok(merged)
}
/// 原始读取: 只做字段白名单, **不做**形状过滤 (C092)。
///
/// 变更路径 (保存 / 移除) 与元数据上报必须看到文件真实内容 —— 否则任何一次写入都会
/// 顺手抹掉形状不合规的账号, 用户既看不到原因也无从处置; 采集消费路径走
/// `load_credentials` 的 fail-closed 过滤, 不把坏形状送进采集。
pub fn read_raw_credentials(root: &Path) -> CredentialPayloads {
    let path = credentials_path(root);
    if reject_link(&path).is_err() {
        return CredentialPayloads::new();
    }
    if !fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() <= MAX_CREDENTIAL_BYTES) {
        return CredentialPayloads::new();
    }
    let Ok(raw) = fs::read(&path) else {
        return CredentialPayloads::new();
    };
    let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&raw) else {
        return CredentialPayloads::new();
    };
    map.into_iter()
        .filter(|(key, _)| is_allowed_field(key.as_str()))
        .collect()
}
/// 采集 / 展示消费路径: 逐字段与逐账号 fail-closed 过滤 (规则 21)。
pub fn load_credentials(root: &Path) -> CredentialPayloads {
    read_raw_credentials(root)
        .into_iter()
        .filter_map(|(key, value)| {
            if validate_credential_payload(&key, &value).is_ok() {
                return Some((key, value));
            }
            retain_valid_accounts(&key, &value).map(|value| (key, value))
        })
        .collect()
}
pub fn save_credentials(root: &Path, payloads: &CredentialPayloads) -> Result<(), String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    save_unlocked(root, payloads)
}
/// UI mutation and token write-back read the latest file inside the same lock.
/// 读原始内容 (C092): 写入不得顺手抹掉形状不合规的账号, 它们只由「移除服务」显式删除。
pub fn save_credentials_patch(
    root: &Path,
    patch: &BTreeMap<String, Option<Value>>,
) -> Result<(), String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let merged = merge_credentials(&read_raw_credentials(root), patch)?;
    save_unlocked(root, &merged)
}
pub fn save_credential_account(
    root: &Path,
    field: &str,
    account_id: &str,
    payload: &Value,
) -> Result<(), String> {
    if !field.ends_with("QuotaAccounts") || !is_allowed_field(field) || !valid_id(account_id) {
        return Err("凭证账号目标无效".to_owned());
    }
    let mut payload = payload
        .as_object()
        .cloned()
        .ok_or("凭证账号必须是 JSON 对象")?;
    payload
        .entry("display_name")
        .or_insert_with(|| json!(account_id));
    validate_credential_payload(field, &json!({account_id: payload}))?;
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let mut latest = read_raw_credentials(root);
    latest
        .entry(field.to_owned())
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("凭证账号映射损坏")?
        .insert(account_id.to_owned(), json!(payload));
    save_unlocked(root, &latest)
}
pub fn remove_credential_account(root: &Path, field: &str, account_id: &str) -> Result<(), String> {
    if !field.ends_with("QuotaAccounts") || !is_allowed_field(field) || !valid_id(account_id) {
        return Err("凭证账号目标无效".to_owned());
    }
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let mut latest = load_credentials(root);
    if let Some(accounts) = latest.get_mut(field).and_then(Value::as_object_mut) {
        accounts.remove(account_id);
        if accounts.is_empty() {
            latest.remove(field);
        }
    }
    save_unlocked(root, &latest)
}
/// 移除服务 (C089 / 设计规则 25): 同一把锁内一次性删除该 Provider 的全部凭据 ——
/// 账号映射整字段 (含读取侧已丢弃、界面不可见的不合规账号) 与 Claude / Grok 的遗留
/// 整体 OAuth 字段。单次原子写 (临时文件 + rename): 要么全部删除、要么一个都不删,
/// 不产生「删了一半」的半删状态。凭据文件不存在时无需写入。
pub fn remove_provider_credentials(root: &Path, provider: &str) -> Result<(), String> {
    let field = crate::collector::quota_credential_field(provider).ok_or("未知服务")?;
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    if !credentials_path(root).exists() {
        return Ok(());
    }
    // 读原始内容 (C092): 形状不合规的账号在读取侧已被丢弃、界面上不可见, 但移除必须
    // 把它们一并带走, 否则残留凭据会在重新添加后复活。
    let mut latest = read_raw_credentials(root);
    latest.remove(field);
    match provider {
        "claude" => latest.remove("claudeOAuth"),
        "grok" => latest.remove("grokOAuth"),
        _ => None,
    };
    save_unlocked(root, &latest)
}
/// Only these explicit metadata fields are allowed over IPC.
pub fn credential_accounts(root: &Path) -> Vec<Value> {
    let mut result = Vec::new();
    for (field, payload) in load_credentials(root) {
        if !field.ends_with("QuotaAccounts") {
            continue;
        }
        if let Some(accounts) = payload.as_object() {
            for (id, value) in accounts {
                result.push(json!({"field":field,"accountId":id,"displayName":value.get("display_name").and_then(Value::as_str).unwrap_or(id),"authorizationState":value.get("authorization_state").and_then(Value::as_str)}));
            }
        }
    }
    result
}
/// 被读取侧丢弃的账号 (C092): 只回**字段 / 账号 ID / 原因文案**, 不含任何凭据值。
///
/// 这些账号按规则 21 不计入「已配置」、也不进账号清单 (保持 fail-closed), 但必须让用户
/// 看到原因 —— 格式校验收紧后, 旧账号只会静默变成「未配置」, 用户既不知为何、也不知该
/// 删除哪一条 (处置入口是「移除服务」, 它会连这些隐藏账号一并带走, 见规则 25)。
pub fn credential_rejections(root: &Path) -> Vec<Value> {
    let mut result = Vec::new();
    for (field, payload) in read_raw_credentials(root) {
        if !field.ends_with("QuotaAccounts") {
            continue;
        }
        let Some(accounts) = payload.as_object() else {
            continue;
        };
        for (id, value) in accounts {
            if let Err(reason) =
                validate_credential_payload(&field, &json!({id.as_str(): value.clone()}))
            {
                result.push(json!({"field":field,"accountId":id,"reason":reason}));
            }
        }
    }
    result
}
/// Explicit pasted CLI auth.json import; never opens or changes external files.
pub fn import_codex_auth(root: &Path, document: &Value) -> Result<(), String> {
    let tokens = document
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or("Codex auth.json 缺少 tokens 对象")?;
    let id = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .filter(|id| valid_id(id))
        .ok_or("Codex auth.json 缺少有效账号 ID")?;
    let mut account = serde_json::Map::new();
    account.insert("display_name".to_owned(), json!(id));
    for key in ["access_token", "refresh_token", "id_token"] {
        if let Some(value) = tokens.get(key).filter(|value| nonempty_string(Some(value))) {
            account.insert(key.to_owned(), value.clone());
        }
    }
    save_credential_account(root, "codexQuotaAccounts", id, &Value::Object(account))
}
/// 读取本机 Claude 登录态并保存为 `claude-cli` 账号 (C075 设置页「读取本机登录态」)。
/// 仅只读外部文件; 无可用登录态时返回 `NotFound` 且不写入任何凭证。
pub fn follow_local_claude(root: &Path, home: &Path) -> Result<ClaudeLocalStatus, String> {
    let now_ms = chrono::Utc::now().timestamp_millis();
    let Some(oauth) = claude_local::read_local_claude_oauth(home) else {
        return Ok(ClaudeLocalStatus::NotFound);
    };
    save_credential_account(
        root,
        "claudeQuotaAccounts",
        "claude-cli",
        &claude_local::claude_cli_account(&oauth),
    )?;
    Ok(claude_local::status_of(&oauth, now_ms))
}

/// 订阅 Provider 的验证结果 (C082)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SubscriptionVerification {
    /// none | ok | failed | needsRelogin。
    pub status: &'static str,
    /// 失败原因 (仅 status=failed; 不回显凭据值)。
    pub reason: Option<String>,
}

impl SubscriptionVerification {
    fn none() -> Self {
        Self {
            status: "none",
            reason: None,
        }
    }
    fn failed(reason: impl Into<String>) -> Self {
        Self {
            status: "failed",
            reason: Some(reason.into()),
        }
    }
}

/// DeepSeek 真实试查边界 (可注入, 使验证逻辑的测试不触网)。
pub trait DeepSeekProbe: Send + Sync {
    fn verify(&self, api_key: &str) -> SubscriptionVerification;
}

/// 默认实现: GET `api.deepseek.com/user/balance` (对齐 mac `verifyDeepSeek`):
/// 200 → ok; 401/403 → 凭据无效; 其余一律 fail-closed。响应正文不读入诊断。
///
/// 与 mac 的差异 (登记项): mac 允许同 host 重定向, 此处关闭全部重定向 ——
/// ureq 2.12 无按 host 过滤的重定向钩子, 关闭可确保 Bearer 密钥不随重定向外泄
/// (与本仓 Codex 刷新同一取舍); 代价是服务端若真的重定向, 验证按 fail-closed 报失败。
pub struct HttpDeepSeekProbe;

impl DeepSeekProbe for HttpDeepSeekProbe {
    fn verify(&self, api_key: &str) -> SubscriptionVerification {
        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(8))
            .redirects(0)
            .build();
        match agent
            .get("https://api.deepseek.com/user/balance")
            .set("Authorization", &format!("Bearer {api_key}"))
            .set("Accept", "application/json")
            .call()
        {
            Ok(_) => SubscriptionVerification {
                status: "ok",
                reason: None,
            },
            Err(ureq::Error::Status(401 | 403, _)) => {
                SubscriptionVerification::failed("API key 无效或已过期")
            }
            Err(ureq::Error::Status(code, _)) => {
                SubscriptionVerification::failed(format!("服务返回 HTTP {code}"))
            }
            Err(_) => SubscriptionVerification::failed("网络不可达"),
        }
    }
}

/// 订阅 Provider 验证 (C082 / C083 / 设计规则 22)。
///
/// 直接读磁盘原始凭据 (不做读取侧过滤), 逐个账号跑写入路径同一套
/// `validate_credential_payload` —— 这样遗留的坏形状账号会显式报 `failed` 并给出
/// 可诊断原因, 而不是静默消失成「未配置」。判定口径:
/// 至少一条可用记录且无 `reauthRequired` → ok; 存在 `reauthRequired` → needsRelogin;
/// 无任何可用记录 → failed(原因); 无该 Provider 凭据 → none。
/// DeepSeek 在结构校验通过后追加一次真实试查 (对齐 mac 的保存即试查语义)。
pub fn verify_subscription(root: &Path, provider: &str) -> SubscriptionVerification {
    verify_subscription_with(root, provider, &HttpDeepSeekProbe)
}

pub fn verify_subscription_with(
    root: &Path,
    provider: &str,
    probe: &dyn DeepSeekProbe,
) -> SubscriptionVerification {
    let Some(field) = crate::collector::quota_credential_field(provider) else {
        return SubscriptionVerification::failed("未知服务");
    };
    let path = credentials_path(root);
    if reject_link(&path).is_err()
        || !fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() <= MAX_CREDENTIAL_BYTES)
    {
        return SubscriptionVerification::none();
    }
    let Ok(raw) = fs::read(&path) else {
        return SubscriptionVerification::none();
    };
    let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&raw) else {
        return SubscriptionVerification::none();
    };
    let Some(accounts) = map.get(field).and_then(Value::as_object) else {
        return SubscriptionVerification::none();
    };
    if accounts.is_empty() {
        return SubscriptionVerification::none();
    }
    let mut usable = 0usize;
    let mut needs_relogin = false;
    let mut first_error: Option<String> = None;
    let mut first_api_key: Option<String> = None;
    for (id, account) in accounts {
        match validate_credential_payload(field, &json!({ id.as_str(): account.clone() })) {
            Ok(()) => {
                usable += 1;
                if first_api_key.is_none() {
                    first_api_key = account
                        .get("api_key")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                }
                if account.get("authorization_state").and_then(Value::as_str)
                    == Some("reauthRequired")
                {
                    needs_relogin = true;
                }
            }
            Err(error) => {
                first_error.get_or_insert(error);
            }
        }
    }
    if usable == 0 {
        return SubscriptionVerification::failed(
            first_error.unwrap_or_else(|| "凭证形状无效".to_owned()),
        );
    }
    if needs_relogin {
        return SubscriptionVerification {
            status: "needsRelogin",
            reason: None,
        };
    }
    if provider == "deepseek" {
        let Some(api_key) = first_api_key else {
            return SubscriptionVerification::failed("DeepSeek 凭证缺少 api_key");
        };
        return probe.verify(&api_key);
    }
    SubscriptionVerification {
        status: "ok",
        reason: None,
    }
}

/// 订阅 Provider 验证, 计入本机 CLI 只读跟随 (C091 / 设计规则 26)。
///
/// Claude 的零配置跟随 (C075) 不落盘, 仅凭已存凭据验证会恒为 `none` —— 而验证结果
/// 驱动启用 (C090), 跟随中的 Claude 将永远无法经验证启用。故无已存凭据时按本机登录态
/// 判定: 跟随中 → ok; 已过期 → needsRelogin (与已存凭据过期同口径); 未发现 → none。
/// 已存凭据 (含形状无效) 时以其结果为准, 不被本机登录态覆盖 (手工配置优先, 对齐
/// `with_local_claude`)。
pub fn verify_subscription_following_local(
    root: &Path,
    home: &Path,
    provider: &str,
    now_ms: i64,
) -> SubscriptionVerification {
    let stored = verify_subscription(root, provider);
    if provider != "claude" || stored.status != "none" {
        return stored;
    }
    match local_claude_status(home, now_ms) {
        ClaudeLocalStatus::Followed => SubscriptionVerification {
            status: "ok",
            reason: None,
        },
        ClaudeLocalStatus::Expired => SubscriptionVerification {
            status: "needsRelogin",
            reason: None,
        },
        ClaudeLocalStatus::NotFound => stored,
    }
}

/// 从 CC Switch 只读导入火山引擎 AK/SK 并落盘 (C083, 对齐 mac
/// `importVolcengineFromCCSwitch`: 导入成功后立即保存并验证)。
/// 只读外部库; 未找到库或行时返回可诊断错误, 不写入任何凭证。
pub fn import_volcengine_from_cc_switch(
    root: &Path,
    home: &Path,
) -> Result<SubscriptionVerification, String> {
    let database = ccswitch::database_path(home).ok_or("未找到 CC Switch 数据库")?;
    let credentials = ccswitch::import_credentials(&database)?;
    let account_id = volcengine_account_id(&credentials.access_key);
    let payload = json!({
        "display_name": format!("火山引擎 · {account_id}"),
        "accessKeyId": credentials.access_key,
        "secretAccessKey": credentials.secret_key,
    });
    save_credential_account(root, "volcengineQuotaAccounts", &account_id, &payload)?;
    Ok(verify_subscription(root, "volcengine"))
}

/// 账号 ID: AK 的稳定散列 (同一 AK 重复导入即 upsert)。
fn volcengine_account_id(access_key: &str) -> String {
    let mut hash: u32 = 5381;
    for byte in access_key.as_bytes() {
        hash = hash.wrapping_mul(33) ^ u32::from(*byte);
    }
    format!("{hash:08x}")
}

fn save_unlocked(root: &Path, payloads: &CredentialPayloads) -> Result<(), String> {
    for (field, payload) in payloads {
        validate_credential_payload(field, payload)?;
    }
    let body = serde_json::to_vec_pretty(payloads).map_err(|_| "凭证编码失败")?;
    if body.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err("凭证文件超过大小上限".to_owned());
    }
    if load_credentials(root).get("deepseekQuotaAccounts") != payloads.get("deepseekQuotaAccounts")
    {
        atomic_private_write(
            &root.join("deepseek-tracking-id"),
            uuid::Uuid::new_v4().to_string().as_bytes(),
        )?;
    }
    write_with_permissions(root, &body, restrict_permissions)
}
fn reject_link(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("凭证路径不得为链接或重解析点".to_owned());
                }
            }
            if metadata.file_type().is_symlink() {
                return Err("凭证路径不得为链接".to_owned());
            }
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("无法检查凭证路径".to_owned()),
    }
}
fn restrict_permissions(path: &Path, directory: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        windows_security::restrict(path, directory)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
        )
        .map_err(|_| "无法设置凭证专属权限".to_owned())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, directory);
        Err("不支持此平台的凭证权限保证".to_owned())
    }
}
/// A failed parent or file ACL prevents publication. File ACL is installed while
/// the new file is still empty; the old credential file remains untouched.
fn write_with_permissions(
    root: &Path,
    body: &[u8],
    mut secure: impl FnMut(&Path, bool) -> Result<(), String>,
) -> Result<(), String> {
    write_path_with_permissions(&credentials_path(root), body, &mut secure)
}

/// Reused by nonsecret snapshots to retain ACL and atomic-replace semantics on Windows.
pub(crate) fn atomic_private_write(path: &Path, body: &[u8]) -> Result<(), String> {
    write_path_with_permissions(path, body, restrict_permissions)
}

fn write_path_with_permissions(
    path: &Path,
    body: &[u8],
    mut secure: impl FnMut(&Path, bool) -> Result<(), String>,
) -> Result<(), String> {
    let root = path.parent().ok_or("存储路径无效")?;
    reject_link(root)?;
    reject_link(path)?;
    fs::create_dir_all(root).map_err(|_| "无法创建凭证目录")?;
    secure(root, true)?;
    let temporary = root.join(format!(".credentials-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|_| "无法创建凭证临时文件")?;
        secure(&temporary, false)?;
        file.write_all(body).map_err(|_| "凭证写入失败")?;
        file.sync_all().map_err(|_| "凭证同步失败")?;
        drop(file);
        #[cfg(windows)]
        windows_security::replace(&temporary, path)?;
        #[cfg(not(windows))]
        fs::rename(&temporary, path).map_err(|_| "凭证原子替换失败")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!("bruce-credentials-{}", uuid::Uuid::new_v4()))
    }
    #[test]
    fn parent_permission_failure_does_not_create_a_secret_file() {
        let root = temp_root();
        assert!(write_with_permissions(&root, b"fixture-secret", |_, _| Err(
            "acl denied".to_owned()
        ))
        .is_err());
        assert!(fs::read_dir(root).unwrap().next().is_none());
    }
    #[test]
    fn file_permission_failure_is_before_plaintext_and_preserves_original() {
        let root = temp_root();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        let original = fs::read(credentials_path(&root)).unwrap();
        let result = write_with_permissions(&root, b"fixture-secret", |path, directory| {
            if directory {
                Ok(())
            } else {
                assert!(fs::read(path).unwrap().is_empty());
                Err("acl denied".to_owned())
            }
        });
        assert!(result.is_err());
        assert_eq!(fs::read(credentials_path(&root)).unwrap(), original);
        assert_eq!(fs::read_dir(root).unwrap().count(), 1);
    }
    #[cfg(windows)]
    #[test]
    fn windows_parent_and_replaced_file_have_current_sid_only() {
        let root = temp_root();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        windows_security::assert_current_sid_only(&root).unwrap();
        windows_security::assert_current_sid_only(&credentials_path(&root)).unwrap();
    }
}
