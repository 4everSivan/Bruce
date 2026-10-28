//! Codex 设备码登录 (C084 / 设计规则 23)。
//!
//! 移植 mac `CodexDeviceFlow` (`BruceOnboardingCore/DeviceAuthLogin.swift`):
//! 1. `POST {usercode}` JSON `{client_id}` → `device_auth_id` + `user_code`;
//! 2. 用户在 <https://auth.openai.com/codex/device> 输入 `user_code`;
//! 3. `POST {token}` JSON `{device_auth_id, user_code}` → 403/404 待授权, 200 得
//!    `authorization_code` (+ 可选 `code_verifier`);
//! 4. `POST {oauth/token}` form 换 `id/access/refresh` 三令牌;
//! 5. 只解析不验签 `id_token`, 取 `chatgpt_account_id` 与 `email`。
//!
//! 红线: 网络请求只由用户在设置页点击发起; 任何一步失败都 fail-closed, 不写半成品
//! 账号; 令牌值绝不进入错误文案或诊断。重定向一律关闭 (ureq 2.12 无按 host 过滤的
//! 重定向钩子), 确保 `authorization_code` / 令牌不随重定向外泄。

use base64::Engine;
use serde_json::{json, Value};
use std::io::Read;
use std::time::Duration;

/// 与 mac 同一个公开客户端 id。
pub const CLIENT_ID: &str = "app_EMoamEEZ73f0CkXaXp7hrann";
/// 用户手动访问的验证页。
pub const VERIFICATION_URL: &str = "https://auth.openai.com/codex/device";
const USER_CODE_URL: &str = "https://auth.openai.com/api/accounts/deviceauth/usercode";
const DEVICE_TOKEN_URL: &str = "https://auth.openai.com/api/accounts/deviceauth/token";
const OAUTH_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const REDIRECT_URI: &str = "https://auth.openai.com/deviceauth/callback";
/// 服务端缺省 `interval` 时的回落值 (秒)。
pub const DEFAULT_INTERVAL_SECS: u64 = 5;
/// 服务端缺省 `expires_in` 时的回落值 (秒)。
pub const DEFAULT_EXPIRES_IN_SECS: u64 = 900;
const MAX_BODY_BYTES: u64 = 64 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// 设备码流程错误。文案只含状态码 / 固定说明, 不含任何令牌或授权码值。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceAuthError {
    NetworkUnreachable,
    HttpError(u16),
    InvalidResponse(&'static str),
    Expired,
}

impl DeviceAuthError {
    pub fn message(&self) -> String {
        match self {
            DeviceAuthError::NetworkUnreachable => "网络不可达".to_owned(),
            DeviceAuthError::HttpError(code) => format!("服务返回 HTTP {code}"),
            DeviceAuthError::InvalidResponse(detail) => format!("响应不合法: {detail}"),
            DeviceAuthError::Expired => "设备码已过期, 请重新发起登录".to_owned(),
        }
    }
}

/// 设备码申请结果 (展示给用户的验证码与轮询参数)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAuthorization {
    pub device_auth_id: String,
    pub user_code: String,
    pub interval_secs: u64,
    pub expires_in_secs: u64,
}

/// 轮询结果: 仍在等待用户输入, 或已拿到授权码与 PKCE verifier。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PollOutcome {
    Pending,
    Authorized(DeviceGrant),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceGrant {
    pub authorization_code: String,
    pub code_verifier: String,
}

/// 换码得到的令牌与生命周期数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenSet {
    pub id_token: String,
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
}

/// 一次成功登录的产物 (可直接合并进 `codexQuotaAccounts`)。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexLoginAccount {
    pub account_id: String,
    pub email: Option<String>,
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    pub expires_at: i64,
}

impl CodexLoginAccount {
    /// 采集端可消费的账号载荷 (与 `import_codex_auth` 同形)。
    pub fn to_payload(&self) -> Value {
        let mut account = serde_json::Map::new();
        // T18: 邮箱可用时优先作为默认名; 无邮箱时写原始 accountId,
        // 由 save_credential_account 统一替换为 «Codex · 账号 N»。
        let display_name = self
            .email
            .as_deref()
            .and_then(|email| email.split('@').next())
            .filter(|local| !local.trim().is_empty())
            .map(|local| format!("Codex · {local}"))
            .unwrap_or_else(|| self.account_id.clone());
        account.insert("display_name".to_owned(), json!(display_name));
        if let Some(email) = self.email.as_deref() {
            account.insert("email".to_owned(), json!(email));
        }
        account.insert("access_token".to_owned(), json!(self.access_token));
        account.insert("refresh_token".to_owned(), json!(self.refresh_token));
        account.insert("id_token".to_owned(), json!(self.id_token));
        account.insert("expiry".to_owned(), json!(self.expires_at));
        account.insert("authorization_state".to_owned(), json!("connected"));
        Value::Object(account)
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(REQUEST_TIMEOUT)
        .redirects(0)
        .build()
}

fn read_body(response: ureq::Response) -> Vec<u8> {
    let mut body = Vec::new();
    let _ = response
        .into_reader()
        .take(MAX_BODY_BYTES)
        .read_to_end(&mut body);
    body
}

fn json_object(body: &[u8]) -> Option<serde_json::Map<String, Value>> {
    serde_json::from_slice::<Value>(body)
        .ok()?
        .as_object()
        .cloned()
}

fn trimmed_string(object: &serde_json::Map<String, Value>, key: &str) -> String {
    object
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_owned()
}

/// 解析设备码申请响应: 200 且含 `device_auth_id` / `user_code` 才成功。
pub fn parse_start_response(
    body: &[u8],
    status: u16,
) -> Result<DeviceAuthorization, DeviceAuthError> {
    if status != 200 {
        return Err(DeviceAuthError::HttpError(status));
    }
    let object =
        json_object(body).ok_or(DeviceAuthError::InvalidResponse("设备码响应不是 JSON 对象"))?;
    let device_auth_id = trimmed_string(&object, "device_auth_id");
    let user_code = trimmed_string(&object, "user_code");
    if device_auth_id.is_empty() || user_code.is_empty() {
        return Err(DeviceAuthError::InvalidResponse(
            "缺少 device_auth_id 或 user_code",
        ));
    }
    let interval_secs = object
        .get("interval")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_INTERVAL_SECS);
    let expires_in_secs = object
        .get("expires_in")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_EXPIRES_IN_SECS);
    Ok(DeviceAuthorization {
        device_auth_id,
        user_code,
        interval_secs,
        expires_in_secs,
    })
}

/// 解析轮询响应: 403/404 表示仍在等待用户输入; 200 得授权码; 其余 fail-closed。
/// 服务端缺省 `code_verifier` 时回落本地 PKCE 生成。
pub fn parse_poll_response(body: &[u8], status: u16) -> Result<PollOutcome, DeviceAuthError> {
    if status == 403 || status == 404 {
        return Ok(PollOutcome::Pending);
    }
    if status != 200 {
        return Err(DeviceAuthError::HttpError(status));
    }
    let object =
        json_object(body).ok_or(DeviceAuthError::InvalidResponse("轮询响应不是 JSON 对象"))?;
    let authorization_code = trimmed_string(&object, "authorization_code");
    if authorization_code.is_empty() {
        return Err(DeviceAuthError::InvalidResponse("缺少 authorization_code"));
    }
    let verifier = trimmed_string(&object, "code_verifier");
    Ok(PollOutcome::Authorized(DeviceGrant {
        authorization_code,
        code_verifier: if verifier.is_empty() {
            code_verifier()
        } else {
            verifier
        },
    }))
}

/// 解析换码响应: 200 且 `id` / `access` / `refresh` 三令牌齐备才成功。
/// `expires_at` 优先取 `expires_in`, 其次 JWT `exp`, 最后 1 小时回落。
pub fn parse_token_response(
    body: &[u8],
    status: u16,
    now: i64,
) -> Result<TokenSet, DeviceAuthError> {
    if status != 200 {
        return Err(DeviceAuthError::HttpError(status));
    }
    let object =
        json_object(body).ok_or(DeviceAuthError::InvalidResponse("换码响应不是 JSON 对象"))?;
    let id_token = trimmed_string(&object, "id_token");
    let access_token = trimmed_string(&object, "access_token");
    let refresh_token = trimmed_string(&object, "refresh_token");
    if id_token.is_empty() || access_token.is_empty() || refresh_token.is_empty() {
        return Err(DeviceAuthError::InvalidResponse(
            "缺少 id/access/refresh token",
        ));
    }
    let expires_at = object
        .get("expires_in")
        .and_then(Value::as_i64)
        .map(|seconds| now + seconds)
        .or_else(|| jwt_expiry(&id_token))
        .unwrap_or(now + 3600);
    Ok(TokenSet {
        id_token,
        access_token,
        refresh_token,
        expires_at,
    })
}

/// PKCE `code_verifier` 本地回落: 32 随机字节做 base64url (43 字符, 无填充)。
/// 用两枚 v4 UUID 的 16 字节拼出 32 字节, 不额外引入随机数依赖。
pub fn code_verifier() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn base64url_decode(input: &str) -> Option<Vec<u8>> {
    let trimmed = input.trim_end_matches('=');
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(trimmed)
        .ok()
}

fn jwt_payload(jwt: &str) -> Option<serde_json::Map<String, Value>> {
    let payload = jwt.split('.').nth(1)?;
    let bytes = base64url_decode(payload)?;
    serde_json::from_slice::<Value>(&bytes)
        .ok()?
        .as_object()
        .cloned()
}

fn non_empty(value: Option<&Value>) -> Option<String> {
    let text = value.and_then(Value::as_str)?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// `chatgpt_account_id`: 优先 namespaced claim, 其次顶层, 最后 organizations 首项。
/// 全部缺失返回 None (调用方按 fail-closed 处理, 不产生半成品账号)。
pub fn account_id_of(id_token: &str) -> Option<String> {
    let payload = jwt_payload(id_token)?;
    if let Some(id) = payload
        .get("https://api.openai.com/auth")
        .and_then(Value::as_object)
        .and_then(|auth| non_empty(auth.get("chatgpt_account_id")))
    {
        return Some(id);
    }
    if let Some(id) = non_empty(payload.get("chatgpt_account_id")) {
        return Some(id);
    }
    payload
        .get("organizations")
        .and_then(Value::as_array)
        .and_then(|organizations| organizations.first())
        .and_then(Value::as_object)
        .and_then(|first| non_empty(first.get("id")))
}

/// 顶层 `email` claim, 允许缺省。
pub fn email_of(id_token: &str) -> Option<String> {
    non_empty(jwt_payload(id_token)?.get("email"))
}

fn jwt_expiry(id_token: &str) -> Option<i64> {
    jwt_payload(id_token)?.get("exp").and_then(Value::as_i64)
}

/// 设备码申请 (只由用户点击触发)。
pub fn start() -> Result<DeviceAuthorization, DeviceAuthError> {
    let response = agent()
        .post(USER_CODE_URL)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_json(json!({ "client_id": CLIENT_ID }));
    match response {
        Ok(response) => {
            let status = response.status();
            parse_start_response(&read_body(response), status)
        }
        Err(ureq::Error::Status(code, response)) => {
            let _ = response;
            Err(DeviceAuthError::HttpError(code))
        }
        Err(_) => Err(DeviceAuthError::NetworkUnreachable),
    }
}

/// 单次轮询 (前端按 `interval` 驱动, 便于 UI 呈现等待 / 完成阶段)。
pub fn poll_once(authorization: &DeviceAuthorization) -> Result<PollOutcome, DeviceAuthError> {
    let response = agent()
        .post(DEVICE_TOKEN_URL)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_json(json!({
            "device_auth_id": authorization.device_auth_id,
            "user_code": authorization.user_code,
        }));
    match response {
        Ok(response) => {
            let status = response.status();
            parse_poll_response(&read_body(response), status)
        }
        Err(ureq::Error::Status(code, response)) => {
            let _ = response;
            // 403/404 由 parse 归为 pending; 其余 fail-closed。
            parse_poll_response(&[], code)
        }
        Err(_) => Err(DeviceAuthError::NetworkUnreachable),
    }
}

/// 换码并从 `id_token` 取账号标识; 缺 `chatgpt_account_id` 时 fail-closed。
pub fn exchange(grant: &DeviceGrant, now: i64) -> Result<CodexLoginAccount, DeviceAuthError> {
    let response = agent()
        .post(OAUTH_TOKEN_URL)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .set("Accept", "application/json")
        .send_form(&[
            ("grant_type", "authorization_code"),
            ("client_id", CLIENT_ID),
            ("code", grant.authorization_code.as_str()),
            ("redirect_uri", REDIRECT_URI),
            ("code_verifier", grant.code_verifier.as_str()),
        ]);
    let tokens = match response {
        Ok(response) => {
            let status = response.status();
            parse_token_response(&read_body(response), status, now)?
        }
        Err(ureq::Error::Status(code, response)) => {
            let _ = response;
            return Err(DeviceAuthError::HttpError(code));
        }
        Err(_) => return Err(DeviceAuthError::NetworkUnreachable),
    };
    let account_id = account_id_of(&tokens.id_token).ok_or(DeviceAuthError::InvalidResponse(
        "id_token 缺少 chatgpt_account_id",
    ))?;
    Ok(CodexLoginAccount {
        account_id,
        email: email_of(&tokens.id_token),
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        id_token: tokens.id_token,
        expires_at: tokens.expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jwt(payload: Value) -> String {
        let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(serde_json::to_vec(&payload).unwrap());
        format!("header.{encoded}.signature")
    }

    #[test]
    fn start_response_requires_both_identifiers_and_reads_interval() {
        let body =
            br#"{"device_auth_id":"dev-1","user_code":"ABCD-1234","interval":7,"expires_in":600}"#;
        let parsed = parse_start_response(body, 200).unwrap();
        assert_eq!(parsed.device_auth_id, "dev-1");
        assert_eq!(parsed.user_code, "ABCD-1234");
        assert_eq!(parsed.interval_secs, 7);
        assert_eq!(parsed.expires_in_secs, 600);
        // 缺 user_code fail-closed
        assert_eq!(
            parse_start_response(br#"{"device_auth_id":"dev-1"}"#, 200),
            Err(DeviceAuthError::InvalidResponse(
                "缺少 device_auth_id 或 user_code"
            ))
        );
        // 非 200 fail-closed
        assert_eq!(
            parse_start_response(b"", 500),
            Err(DeviceAuthError::HttpError(500))
        );
        // 缺省 interval/expires_in 回落
        let fallback =
            parse_start_response(br#"{"device_auth_id":"d","user_code":"u"}"#, 200).unwrap();
        assert_eq!(fallback.interval_secs, DEFAULT_INTERVAL_SECS);
        assert_eq!(fallback.expires_in_secs, DEFAULT_EXPIRES_IN_SECS);
    }

    #[test]
    fn poll_response_maps_pending_and_authorized_and_keeps_server_verifier() {
        assert_eq!(parse_poll_response(b"", 403), Ok(PollOutcome::Pending));
        assert_eq!(parse_poll_response(b"", 404), Ok(PollOutcome::Pending));
        let body = br#"{"authorization_code":"code-1","code_verifier":"server-verifier"}"#;
        match parse_poll_response(body, 200).unwrap() {
            PollOutcome::Authorized(grant) => {
                assert_eq!(grant.authorization_code, "code-1");
                assert_eq!(grant.code_verifier, "server-verifier");
            }
            other => panic!("unexpected {other:?}"),
        }
        // 服务端未给 verifier 时本地生成 (43 字符 base64url, 无填充)
        match parse_poll_response(br#"{"authorization_code":"c"}"#, 200).unwrap() {
            PollOutcome::Authorized(grant) => {
                assert_eq!(grant.code_verifier.len(), 43);
                assert!(!grant.code_verifier.contains('='));
            }
            other => panic!("unexpected {other:?}"),
        }
        // 缺 authorization_code fail-closed
        assert!(parse_poll_response(b"{}", 200).is_err());
        // 其余非 200 fail-closed
        assert_eq!(
            parse_poll_response(b"", 500),
            Err(DeviceAuthError::HttpError(500))
        );
    }

    #[test]
    fn token_response_requires_three_tokens_and_derives_expiry() {
        let body =
            br#"{"id_token":"a.b.c","access_token":"at","refresh_token":"rt","expires_in":1200}"#;
        let parsed = parse_token_response(body, 200, 1_000).unwrap();
        assert_eq!(parsed.expires_at, 2_200);
        // 缺 refresh_token fail-closed
        assert!(parse_token_response(br#"{"id_token":"a","access_token":"b"}"#, 200, 0).is_err());
        // 无 expires_in 时按 JWT exp
        let token = jwt(json!({"exp": 9_999}));
        let body = serde_json::to_vec(
            &json!({"id_token": token, "access_token":"a", "refresh_token":"r"}),
        )
        .unwrap();
        assert_eq!(
            parse_token_response(&body, 200, 1_000).unwrap().expires_at,
            9_999
        );
        // 无 expires_in 也无 exp 时按 1 小时回落
        let body = serde_json::to_vec(
            &json!({"id_token": "a.b", "access_token":"a", "refresh_token":"r"}),
        )
        .unwrap();
        assert_eq!(
            parse_token_response(&body, 200, 1_000).unwrap().expires_at,
            4_600
        );
        assert_eq!(
            parse_token_response(b"", 401, 0),
            Err(DeviceAuthError::HttpError(401))
        );
    }

    #[test]
    fn id_token_identity_follows_namespaced_then_top_level_then_organizations() {
        let namespaced = jwt(json!({
            "https://api.openai.com/auth": {"chatgpt_account_id": "acct-ns"},
            "chatgpt_account_id": "acct-top",
            "email": "user@example.com",
        }));
        assert_eq!(account_id_of(&namespaced).as_deref(), Some("acct-ns"));
        assert_eq!(email_of(&namespaced).as_deref(), Some("user@example.com"));
        let top = jwt(json!({"chatgpt_account_id": "acct-top"}));
        assert_eq!(account_id_of(&top).as_deref(), Some("acct-top"));
        let organizations = jwt(json!({"organizations": [{"id": "org-1"}]}));
        assert_eq!(account_id_of(&organizations).as_deref(), Some("org-1"));
        // 无任何账号标识 → None (调用方 fail-closed)
        assert_eq!(account_id_of(&jwt(json!({"email": "e"}))), None);
        assert_eq!(email_of(&jwt(json!({}))), None);
        // 非法 JWT 不 panic
        assert_eq!(account_id_of("not-a-jwt"), None);
        assert_eq!(account_id_of(""), None);
    }

    #[test]
    fn login_account_payload_is_collector_native_and_never_marks_discovery() {
        let account = CodexLoginAccount {
            account_id: "acct-1".to_owned(),
            email: Some("a@b.c".to_owned()),
            access_token: "at".to_owned(),
            refresh_token: "rt".to_owned(),
            id_token: "id".to_owned(),
            expires_at: 42,
        };
        let payload = account.to_payload();
        assert_eq!(payload["access_token"], json!("at"));
        assert_eq!(payload["authorization_state"], json!("connected"));
        assert_eq!(payload["expiry"], json!(42));
    }

    #[test]
    fn code_verifier_is_43_chars_base64url_without_padding() {
        let verifier = code_verifier();
        assert_eq!(verifier.len(), 43);
        assert!(verifier
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
        assert_ne!(verifier, code_verifier());
    }
}
