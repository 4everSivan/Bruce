#![deny(unsafe_code)]

//! Read-only quota and Provider adapters.

use chrono::{DateTime, NaiveDateTime, Utc};
use collector_domain::Diagnostic;
use collector_runtime::{CancellationToken, RuntimeError, RuntimeLimits};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{self, Display, Formatter, Write as _};
use std::io::Read;
use std::time::Duration;

pub const PROVIDER_ROLE: &str = "quota-adapter";
pub const MAX_PROVIDER_ACCOUNT_ID_BYTES: usize = 256;
pub const MAX_PROVIDER_DISPLAY_NAME_BYTES: usize = 256;

const CATALOG_SPECS: &[CatalogSpec] = &[
    CatalogSpec {
        provider: "opencode-go",
        prefix: "opencode_go_",
        display_prefix: "OpenCode GO",
        app: "opencode-go",
    },
    CatalogSpec {
        provider: "kimi",
        prefix: "kimi_coding_",
        display_prefix: "Kimi",
        app: "kimi",
    },
    CatalogSpec {
        provider: "deepseek",
        prefix: "deepseek_",
        display_prefix: "DeepSeek",
        app: "deepseek",
    },
    CatalogSpec {
        provider: "zhipu",
        prefix: "zhipu_",
        display_prefix: "智谱",
        app: "zhipu",
    },
    CatalogSpec {
        provider: "volcengine",
        prefix: "volcengine_",
        display_prefix: "火山引擎",
        app: "volcengine",
    },
    CatalogSpec {
        provider: "claude",
        prefix: "claude_",
        display_prefix: "Claude",
        app: "claude",
    },
    CatalogSpec {
        provider: "grok",
        prefix: "grok_",
        display_prefix: "Grok",
        app: "grok",
    },
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct CatalogSpec {
    provider: &'static str,
    prefix: &'static str,
    display_prefix: &'static str,
    app: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDescriptor {
    pub account_id: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogInput {
    /// Keys use stable app/provider IDs: `opencode-go`, `kimi`, `deepseek`,
    /// `zhipu`, `volcengine`, `claude`, or `grok`.
    pub accounts: BTreeMap<String, Vec<AccountDescriptor>>,
    pub enabled_official: BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServiceDescriptor {
    pub id: String,
    pub name: String,
    pub app: String,
    pub is_current: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogError {
    InvalidAccountID,
    InvalidDisplayName,
}

impl Display for CatalogError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidAccountID => "Provider account ID 无效",
            Self::InvalidDisplayName => "Provider display name 无效",
        })
    }
}

impl std::error::Error for CatalogError {}

/// Resolve injected account descriptors into Python-compatible stable service
/// order. Account IDs are sorted within each provider and duplicate IDs are
/// rejected instead of producing duplicate service rows.
pub fn resolve_service_catalog(
    input: &CatalogInput,
    target_apps: Option<&BTreeSet<String>>,
) -> Result<Vec<ServiceDescriptor>, CatalogError> {
    let mut services = Vec::new();
    for spec in CATALOG_SPECS {
        if !target_apps.is_none_or(|targets| targets.contains(spec.app)) {
            continue;
        }
        let mut accounts = input
            .accounts
            .get(spec.provider)
            .cloned()
            .unwrap_or_default();
        accounts.sort_by(|left, right| left.account_id.cmp(&right.account_id));
        let mut seen = BTreeSet::new();
        for account in accounts {
            validate_account(&account)?;
            if !seen.insert(account.account_id.clone()) {
                return Err(CatalogError::InvalidAccountID);
            }
            let short_id = account.account_id.chars().take(8).collect::<String>();
            let name = account
                .display_name
                .filter(|value| !value.is_empty())
                .unwrap_or_else(|| format!("{} · {}", spec.display_prefix, short_id));
            services.push(ServiceDescriptor {
                id: format!("{}{}", spec.prefix, account.account_id),
                name,
                app: spec.app.to_owned(),
                is_current: false,
            });
        }
        if services.iter().all(|service| service.app != spec.app)
            && input.enabled_official.contains(spec.app)
            && matches!(spec.provider, "claude" | "grok")
        {
            services.push(ServiceDescriptor {
                id: spec.app.to_owned(),
                name: spec.display_prefix.to_owned(),
                app: spec.app.to_owned(),
                is_current: false,
            });
        }
    }
    Ok(services)
}

fn validate_account(account: &AccountDescriptor) -> Result<(), CatalogError> {
    if account.account_id.is_empty()
        || account.account_id.len() > MAX_PROVIDER_ACCOUNT_ID_BYTES
        || account.account_id.chars().any(char::is_control)
    {
        return Err(CatalogError::InvalidAccountID);
    }
    if account
        .display_name
        .as_deref()
        .is_some_and(|value| value.len() > MAX_PROVIDER_DISPLAY_NAME_BYTES)
    {
        return Err(CatalogError::InvalidDisplayName);
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderRequest {
    pub service: ServiceDescriptor,
    /// Original provider account ID. Codex uses this value for the
    /// `chatgpt-account-id` request header because its service ID is hashed.
    pub account_id: Option<String>,
    pub captured_at: String,
    pub timeout: Duration,
    pub max_response_body_bytes: usize,
    pub credential: Option<Value>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: String,
    pub url: String,
    pub headers: BTreeMap<String, String>,
    pub body: Option<Vec<u8>>,
    pub timeout: Duration,
    pub max_response_body_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub body: Vec<u8>,
}

pub trait HttpClient: Send + Sync {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError>;
}

/// Production HTTPS transport. Tests use the `HttpClient` trait with an
/// isolated fixture implementation instead of making network requests.
pub struct UreqHttpClient {
    agent: ureq::Agent,
}

impl Default for UreqHttpClient {
    fn default() -> Self {
        Self {
            agent: ureq::AgentBuilder::new().https_only(true).build(),
        }
    }
}

impl UreqHttpClient {
    fn read_body(
        response: ureq::Response,
        max_response_body_bytes: usize,
    ) -> Result<Vec<u8>, ProviderError> {
        let mut body = Vec::new();
        response
            .into_reader()
            .take(max_response_body_bytes.saturating_add(1) as u64)
            .read_to_end(&mut body)
            .map_err(|_| {
                ProviderError::new(
                    "PROVIDER_RESPONSE_READ_FAILED",
                    "response",
                    "Provider 响应读取失败",
                    true,
                )
            })?;
        Ok(body)
    }
}

impl HttpClient for UreqHttpClient {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        let mut builder = self
            .agent
            .request(&request.method, &request.url)
            .timeout(request.timeout);
        for (name, value) in &request.headers {
            builder = builder.set(name, value);
        }
        let response = match request.body.as_deref() {
            Some(body) => builder.send_bytes(body),
            None => builder.call(),
        };
        match response {
            Ok(response) => Ok(HttpResponse {
                status: response.status(),
                body: Self::read_body(response, request.max_response_body_bytes)?,
            }),
            Err(ureq::Error::Status(status, response)) => Ok(HttpResponse {
                status,
                body: Self::read_body(response, request.max_response_body_bytes)?,
            }),
            Err(_) => Err(ProviderError::new(
                "PROVIDER_TRANSPORT_ERROR",
                "request",
                "Provider 网络请求失败",
                true,
            )),
        }
    }
}

pub trait QuotaProvider: Send + Sync {
    fn app(&self) -> &str;

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderError {
    pub diagnostic: Diagnostic,
}

impl ProviderError {
    pub fn new(
        code: impl Into<String>,
        stage: impl Into<String>,
        message: impl Into<String>,
        retryable: bool,
    ) -> Self {
        Self {
            diagnostic: Diagnostic::new(code, "provider", stage, message, retryable),
        }
    }

    pub fn from_runtime(error: RuntimeError) -> Self {
        let (code, message, retryable) = match error {
            RuntimeError::Cancelled => ("PROVIDER_CANCELLED", "Provider 查询已取消", true),
            RuntimeError::DeadlineExceeded => {
                ("PROVIDER_TIMEOUT", "Provider 查询超过截止时间", true)
            }
            RuntimeError::Closed => ("PROVIDER_QUEUE_CLOSED", "Provider 队列已关闭", true),
            RuntimeError::InvalidLimits => {
                ("PROVIDER_INVALID_LIMIT", "Provider 运行限额无效", false)
            }
        };
        Self::new(code, "request", message, retryable)
    }
}

impl Display for ProviderError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.diagnostic.message)
    }
}

impl std::error::Error for ProviderError {}

pub fn runtime_limits_request(
    request: &ProviderRequest,
    limits: RuntimeLimits,
) -> Result<ProviderRequest, ProviderError> {
    let limits = limits.validate().map_err(ProviderError::from_runtime)?;
    Ok(ProviderRequest {
        max_response_body_bytes: request
            .max_response_body_bytes
            .min(limits.response_body_bytes),
        ..request.clone()
    })
}

pub fn bounded_http_body(
    response: HttpResponse,
    max_bytes: usize,
) -> Result<Vec<u8>, ProviderError> {
    if response.body.len() > max_bytes {
        return Err(ProviderError::new(
            "PROVIDER_RESPONSE_TOO_LARGE",
            "response",
            "Provider 响应体超过大小上限",
            false,
        ));
    }
    if response.status == 429 {
        return Err(ProviderError::new(
            "PROVIDER_RATE_LIMIT",
            "response",
            "Provider 请求触发限流",
            true,
        ));
    }
    if (500..=599).contains(&response.status) {
        return Err(ProviderError::new(
            "PROVIDER_SERVER_ERROR",
            "response",
            "Provider 服务暂时不可用",
            true,
        ));
    }
    if !(200..=299).contains(&response.status) {
        return Err(ProviderError::new(
            "PROVIDER_HTTP_STATUS",
            "response",
            "Provider 返回非成功 HTTP 状态",
            response.status >= 500,
        ));
    }
    Ok(response.body)
}

pub fn parse_json_body(response: HttpResponse, max_bytes: usize) -> Result<Value, ProviderError> {
    let body = bounded_http_body(response, max_bytes)?;
    serde_json::from_slice(&body).map_err(|_| {
        ProviderError::new(
            "PROVIDER_INVALID_JSON",
            "parse",
            "Provider 响应不是有效 JSON",
            false,
        )
    })
}

pub fn service_template(service: &ServiceDescriptor, captured_at: &str) -> Value {
    json!({
        "id": service.id,
        "name": service.name,
        "app": service.app,
        "isCurrent": service.is_current,
        "status": "ok",
        "kind": null,
        "plan": null,
        "windows": [],
        "balance": null,
        "currency": null,
        "capturedAt": captured_at,
        "note": "",
    })
}

pub fn finalize_service(mut service: Value, result: Result<Option<Value>, ProviderError>) -> Value {
    let Some(object) = service.as_object_mut() else {
        return service;
    };
    match result {
        Ok(Some(Value::Object(values))) => {
            for (key, value) in values {
                object.insert(key, value);
            }
            let kind = object.get("kind").and_then(Value::as_str);
            let windows_empty = object
                .get("windows")
                .and_then(Value::as_array)
                .is_some_and(Vec::is_empty);
            if kind == Some("windows") && windows_empty {
                object.insert("status".to_owned(), Value::String("empty".to_owned()));
                object.insert(
                    "note".to_owned(),
                    Value::String("接口已通但未返回额度窗口".to_owned()),
                );
            }
        }
        Ok(Some(_)) => {
            object.insert("status".to_owned(), Value::String("error".to_owned()));
            object.insert(
                "note".to_owned(),
                Value::String("查询失败: Provider 返回格式无效".to_owned()),
            );
        }
        Ok(None) => {
            object.insert("status".to_owned(), Value::String("empty".to_owned()));
            object.insert(
                "note".to_owned(),
                Value::String("未取到额度数据".to_owned()),
            );
        }
        Err(error) => {
            object.insert("status".to_owned(), Value::String("error".to_owned()));
            let mut message = error
                .diagnostic
                .message
                .chars()
                .take(60)
                .collect::<String>();
            if message.is_empty() {
                message = "查询失败".to_owned();
            } else {
                message = format!("查询失败: {message}");
            }
            object.insert("note".to_owned(), Value::String(message));
        }
    }
    service
}

pub const KIMI_USAGE_URL: &str = "https://api.kimi.com/coding/v1/usages";
pub const DEEPSEEK_BALANCE_URL: &str = "https://api.deepseek.com/user/balance";
pub const ZHIPU_QUOTA_PATH: &str = "/api/monitor/usage/quota/limit";
pub const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const CLAUDE_BETA_HEADER: &str = "oauth-2025-04-20";
pub const GROK_BILLING_URL: &str =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
pub const OPENCODE_SERVER_URL: &str = "https://opencode.ai/_server";
pub const OPENCODE_SERVER_ID: &str =
    "c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd";

fn invalid_payload() -> ProviderError {
    ProviderError::new(
        "PROVIDER_INVALID_PAYLOAD",
        "parse",
        "Provider 响应格式无效",
        false,
    )
}

fn invalid_credential() -> ProviderError {
    ProviderError::new(
        "PROVIDER_INVALID_CREDENTIAL",
        "credential",
        "Provider 凭证格式无效",
        false,
    )
}

fn credential_string<'a>(credential: &'a Value, keys: &[&str]) -> Option<&'a str> {
    if let Some(value) = credential.as_str() {
        return (!value.is_empty()).then_some(value);
    }
    let object = credential.as_object()?;
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
    })
}

fn number(value: Option<&Value>) -> Option<f64> {
    let parsed = match value? {
        Value::Number(value) => value.as_f64(),
        Value::String(value) => value.trim().parse::<f64>().ok(),
        _ => None,
    }?;
    parsed.is_finite().then_some(parsed)
}

fn number_with_default(
    value: Option<&Value>,
    default: f64,
    zero_is_default: bool,
) -> Result<f64, ()> {
    let Some(value) = value else {
        return Ok(default);
    };
    if value.is_null() {
        return Ok(default);
    }
    let parsed = number(Some(value)).ok_or(())?;
    if zero_is_default && parsed == 0.0 {
        Ok(default)
    } else {
        Ok(parsed)
    }
}

fn clamp_percent(value: f64) -> f64 {
    value.clamp(0.0, 100.0)
}

fn reset_epoch(value: Option<&Value>) -> Option<i64> {
    let value = value?;
    if let Some(number) = number(Some(value)) {
        if number <= 0.0 {
            return None;
        }
        let seconds = if number > 1_000_000_000_000.0 {
            number / 1_000.0
        } else {
            number
        };
        return (seconds.is_finite() && seconds > 0.0).then_some(seconds as i64);
    }
    let text = value.as_str()?.trim();
    if text.is_empty() {
        return None;
    }
    if let Ok(parsed) = text.parse::<f64>() {
        return reset_epoch(Some(&Value::from(parsed)));
    }
    if let Ok(parsed) = DateTime::parse_from_rfc3339(text) {
        return Some(parsed.timestamp());
    }
    NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S%.f")
        .ok()
        .map(|parsed| parsed.and_utc().timestamp())
}

fn captured_epoch(captured_at: &str) -> i64 {
    DateTime::parse_from_rfc3339(captured_at)
        .map(|value| value.timestamp())
        .or_else(|_| {
            NaiveDateTime::parse_from_str(captured_at, "%Y-%m-%dT%H:%M:%S%.f")
                .map(|value| value.and_utc().timestamp())
        })
        .unwrap_or_else(|_| Utc::now().timestamp())
}

fn parse_window_percentage(
    limit: Option<&Value>,
    used: Option<&Value>,
    remaining: Option<&Value>,
) -> Option<f64> {
    let limit = number(limit)?;
    if limit <= 0.0 {
        return None;
    }
    let used = if let Some(value) = number(used) {
        value
    } else {
        let remaining = number(remaining)?;
        limit - remaining
    };
    Some(clamp_percent((used / limit) * 100.0))
}

#[allow(clippy::too_many_arguments)]
fn send_json(
    request: &ProviderRequest,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
    method: &str,
    url: String,
    headers: BTreeMap<String, String>,
    body: Option<Vec<u8>>,
    auth_error: Option<&str>,
) -> Result<Value, ProviderError> {
    let response_body = send_body(
        request,
        http,
        cancellation,
        method,
        url,
        headers,
        body,
        auth_error,
    )?;
    serde_json::from_slice(&response_body).map_err(|_| {
        ProviderError::new(
            "PROVIDER_INVALID_JSON",
            "parse",
            "Provider 响应不是有效 JSON",
            false,
        )
    })
}

#[allow(clippy::too_many_arguments)]
fn send_body(
    request: &ProviderRequest,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
    method: &str,
    url: String,
    headers: BTreeMap<String, String>,
    body: Option<Vec<u8>>,
    auth_error: Option<&str>,
) -> Result<Vec<u8>, ProviderError> {
    cancellation.check().map_err(ProviderError::from_runtime)?;
    let response = http.send(
        HttpRequest {
            method: method.to_owned(),
            url,
            headers,
            body,
            timeout: request.timeout,
            max_response_body_bytes: request.max_response_body_bytes,
        },
        cancellation,
    )?;
    if response.status == 401 {
        if let Some(message) = auth_error {
            return Err(ProviderError::new(
                "PROVIDER_AUTH_REJECTED",
                "response",
                message,
                false,
            ));
        }
    }
    if response.status == 403 {
        if let Some(message) = auth_error {
            return Err(ProviderError::new(
                "PROVIDER_PERMISSION_DENIED",
                "response",
                message,
                false,
            ));
        }
    }
    bounded_http_body(response, request.max_response_body_bytes)
}

fn service_result(kind: &str, plan: Option<Value>, windows: Vec<Value>) -> Value {
    json!({
        "kind": kind,
        "plan": plan,
        "windows": windows,
    })
}

fn window(
    label: &str,
    used_percent: f64,
    window_minutes: Option<u64>,
    resets_at: Option<i64>,
) -> Value {
    json!({
        "label": label,
        "usedPercent": used_percent,
        "windowMinutes": window_minutes,
        "resetsAt": resets_at,
    })
}

/// Return the stable Codex service ID shared by Python, Swift and Rust.
pub fn codex_service_id(account_id: &str) -> String {
    let digest = Sha256::digest(account_id.as_bytes());
    format!("codex_{:x}", digest)[..22].to_owned()
}

fn codex_window_label(seconds: Option<i64>) -> &'static str {
    match seconds {
        Some(seconds) if seconds <= 6 * 60 * 60 => "5小时窗口",
        Some(seconds) if seconds <= 8 * 24 * 60 * 60 => "每周窗口",
        Some(_) => "每月窗口",
        None => "窗口",
    }
}

fn codex_window_seconds(value: Option<&Value>) -> Option<i64> {
    number(value).map(|value| value as i64)
}

fn codex_value_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Number(value)) => value.to_string(),
        Some(Value::Bool(value)) => value.to_string(),
        Some(Value::Null) | None => "None".to_owned(),
        Some(value) => value.to_string(),
    }
}

/// Parse the Codex `wham/usage` response without retaining the access token.
/// The shape intentionally follows the legacy Python adapter because Swift's
/// panel and Codex snapshot merger already consume these fields.
pub fn parse_codex_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let rate_limit = object
        .get("rate_limit")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut windows = Vec::new();
    for key in ["primary_window", "secondary_window"] {
        let Some(window) = rate_limit.get(key).and_then(Value::as_object) else {
            continue;
        };
        let seconds = codex_window_seconds(window.get("limit_window_seconds"));
        let used_percent = match window.get("used_percent") {
            None | Some(Value::Null) => 0.0,
            Some(value) => number(Some(value)).ok_or_else(invalid_payload)?,
        };
        windows.push(json!({
            "label": codex_window_label(seconds),
            "usedPercent": clamp_percent(used_percent),
            "windowMinutes": seconds.map(|value| value / 60),
            "resetsAt": window.get("reset_at").cloned().unwrap_or(Value::Null),
        }));
    }
    let plan = object
        .get("plan_type")
        .filter(|value| !value.is_null())
        .cloned();
    let mut result = service_result("windows", plan, windows);
    if let Some(credits) = object.get("credits").and_then(Value::as_object) {
        let extra = if credits.get("unlimited").and_then(Value::as_bool) == Some(true) {
            Some("Credits 不限量".to_owned())
        } else if credits.get("has_credits").and_then(Value::as_bool) == Some(true) {
            Some(format!(
                "Credits 余额 {}",
                codex_value_text(credits.get("balance"))
            ))
        } else {
            None
        };
        if let Some(extra) = extra {
            result["extra"] = Value::String(extra);
        }
    }
    result["freshness"] = Value::String("fresh".to_owned());
    result["failureKind"] = Value::Null;
    Ok(Some(result))
}

/// Parse the Kimi For Coding usage response without retaining the API key.
pub fn parse_kimi_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    if let Some(limits) = object.get("limits").and_then(Value::as_array) {
        for item in limits {
            let Some(detail) = item.get("detail").and_then(Value::as_object) else {
                continue;
            };
            let Ok(limit) = number_with_default(detail.get("limit"), 1.0, true) else {
                continue;
            };
            let Ok(remaining) = number_with_default(detail.get("remaining"), 0.0, true) else {
                continue;
            };
            let used = (limit - remaining).max(0.0);
            let percent = if limit > 0.0 {
                used / limit * 100.0
            } else {
                0.0
            };
            windows.push(window(
                "5小时窗口",
                percent,
                Some(300),
                reset_epoch(detail.get("resetTime")),
            ));
        }
    }
    if let Some(usage) = object.get("usage").and_then(Value::as_object) {
        let limit = number_with_default(usage.get("limit"), 1.0, true).unwrap_or(1.0);
        let remaining = number_with_default(usage.get("remaining"), 0.0, true).unwrap_or(0.0);
        let used = (limit - remaining).max(0.0);
        let percent = if limit > 0.0 {
            used / limit * 100.0
        } else {
            0.0
        };
        windows.push(window(
            "7天窗口",
            percent,
            Some(7 * 24 * 60),
            reset_epoch(usage.get("resetTime")),
        ));
    }
    Ok(Some(json!({
        "kind": "windows",
        "plan": null,
        "windows": windows,
        "extra": null,
    })))
}

/// Parse the DeepSeek balance response. An absent balance list is a valid empty result.
pub fn parse_deepseek_balance(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let Some(info) = object
        .get("balance_infos")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };
    let balance = number(info.get("total_balance")).unwrap_or(0.0);
    let currency = info
        .get("currency")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("CNY");
    Ok(Some(json!({
        "kind": "balance",
        "plan": null,
        "windows": [],
        "balance": balance,
        "currency": currency,
    })))
}

fn zhipu_reset(value: Option<&Value>) -> Option<i64> {
    let number = number(value)?;
    if number <= 0.0 {
        return None;
    }
    Some(if number > 1_000_000_000_000.0 {
        (number / 1_000.0) as i64
    } else {
        number as i64
    })
}

fn zhipu_windows(limits: Option<&Value>) -> Vec<Value> {
    let mut five_hour: Option<(Option<i64>, f64)> = None;
    let mut weekly: Option<(Option<i64>, f64)> = None;
    let mut unclassified = Vec::new();
    if let Some(items) = limits.and_then(Value::as_array) {
        for item in items {
            let Some(object) = item.as_object() else {
                continue;
            };
            let kind = object
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_uppercase();
            if kind != "TOKENS_LIMIT" && kind != "CREDIT_LIMIT" {
                continue;
            }
            let percentage = number(object.get("percentage")).unwrap_or(0.0);
            let entry = (zhipu_reset(object.get("nextResetTime")), percentage);
            match object.get("unit").and_then(Value::as_i64) {
                Some(3) if five_hour.is_none() => five_hour = Some(entry),
                Some(6) if weekly.is_none() => weekly = Some(entry),
                _ => unclassified.push(entry),
            }
        }
    }
    unclassified.sort_by_key(|(reset, _)| (*reset).unwrap_or(-1));
    for entry in unclassified {
        if five_hour.is_none() {
            five_hour = Some(entry);
        } else if weekly.is_none() {
            weekly = Some(entry);
        }
    }
    let mut windows = Vec::new();
    if let Some((reset, percent)) = five_hour {
        windows.push(window("每 5 小时", percent, Some(300), reset));
    }
    if let Some((reset, percent)) = weekly {
        windows.push(window("每周", percent, Some(10080), reset));
    }
    windows
}

/// Parse the Zhipu Coding Plan quota response.
pub fn parse_zhipu_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    if object.get("success").and_then(Value::as_bool) == Some(false) {
        return Err(ProviderError::new(
            "PROVIDER_REMOTE_REJECTED",
            "parse",
            "智谱额度查询被服务端拒绝",
            false,
        ));
    }
    let data = object
        .get("data")
        .and_then(Value::as_object)
        .ok_or_else(invalid_payload)?;
    let plan = data.get("level").cloned().unwrap_or(Value::Null);
    Ok(Some(service_result(
        "windows",
        Some(plan),
        zhipu_windows(data.get("limits")),
    )))
}

fn object_value<'a>(
    object: &'a serde_json::Map<String, Value>,
    names: &[&str],
) -> Option<&'a Value> {
    names.iter().find_map(|name| {
        object
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value)
    })
}

fn volc_window(node: Option<&Value>, label: &str) -> Option<Value> {
    let object = node?.as_object()?;
    let limit = object_value(object, &["Limit", "Total", "Quota", "TotalQuota"]);
    let used = object_value(object, &["Used", "Usage", "UsedQuota"]);
    let remaining = object_value(object, &["Remaining", "Remain"]);
    let percent = parse_window_percentage(limit, used, remaining)?;
    let reset = object_value(object, &["ResetTime", "QuotaResetTime"])
        .and_then(|value| reset_epoch(Some(value)));
    Some(window(label, percent, None, reset))
}

/// Parse both known Volcengine quota response shapes.
pub fn parse_volcengine_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    if let Some(items) = object.get("QuotaUsage").and_then(Value::as_array) {
        for item in items {
            let Some(item) = item.as_object() else {
                continue;
            };
            let level = item
                .get("Level")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let label = match level.as_str() {
                "session" => "5小时窗口",
                "weekly" => "每周窗口",
                "monthly" => "每月窗口",
                _ if !level.is_empty() => level.as_str(),
                _ => "窗口",
            };
            let Some(percent) = number(item.get("Percent")) else {
                continue;
            };
            let reset = reset_epoch(item.get("ResetTimestamp"));
            windows.push(window(label, clamp_percent(percent), None, reset));
        }
    } else {
        for (key, label) in [
            ("AFPFiveHour", "5小时窗口"),
            ("FiveHour", "5小时窗口"),
            ("AFPWeekly", "每周窗口"),
            ("Weekly", "每周窗口"),
            ("AFPMonthly", "每月窗口"),
            ("Monthly", "每月窗口"),
        ] {
            if windows.is_empty() || !windows.iter().any(|value| value["label"] == label) {
                if let Some(value) = volc_window(object.get(key), label) {
                    windows.push(value);
                }
            }
        }
        if windows.is_empty() {
            for (key, value) in object {
                let lower = key.to_ascii_lowercase();
                let label = if lower.contains("fivehour") || lower.contains("5hour") {
                    Some("5小时窗口")
                } else if lower.contains("weekly") || lower.contains("week") {
                    Some("每周窗口")
                } else if lower.contains("monthly") || lower.contains("month") {
                    Some("每月窗口")
                } else {
                    None
                };
                if let Some(label) = label {
                    if let Some(parsed) = volc_window(Some(value), label) {
                        windows.push(parsed);
                    }
                }
            }
        }
    }
    let plan = ["PlanType", "Plan", "PlanName"]
        .iter()
        .find_map(|key| object.get(*key).and_then(Value::as_str))
        .map(|value| Value::String(value.to_owned()));
    Ok(Some(service_result("windows", plan, windows)))
}

const CLAUDE_TIERS: &[(&str, &str, Option<u64>)] = &[
    ("five_hour", "每 5 小时", Some(300)),
    ("seven_day", "每周", Some(10080)),
    ("seven_day_opus", "每周 Opus", Some(10080)),
    ("seven_day_sonnet", "每周 Sonnet", Some(10080)),
];

fn claude_tier(key: &str) -> (&str, Option<u64>) {
    CLAUDE_TIERS
        .iter()
        .find(|(known, _, _)| *known == key)
        .map(|(_, label, minutes)| (*label, *minutes))
        .unwrap_or((key, None))
}

/// Parse Claude OAuth usage, omitting windows that are not active.
pub fn parse_claude_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    for (key, value) in object {
        if key == "extra_usage" {
            continue;
        }
        let Some(value) = value.as_object() else {
            continue;
        };
        let Some(utilization) = value.get("utilization") else {
            continue;
        };
        let percent = number(Some(utilization)).ok_or_else(invalid_payload)?;
        let (label, minutes) = claude_tier(key);
        windows.push(window(
            label,
            clamp_percent(percent),
            minutes,
            reset_epoch(value.get("resets_at")),
        ));
    }
    if let Some(extra) = object.get("extra_usage").and_then(Value::as_object) {
        if extra.get("is_enabled").and_then(Value::as_bool) == Some(true) {
            if let Some(utilization) = extra.get("utilization") {
                let percent = number(Some(utilization)).ok_or_else(invalid_payload)?;
                let mut value = window("额外用量", clamp_percent(percent), None, None);
                if let Some(value) = value.as_object_mut() {
                    value.insert("ownRow".to_owned(), Value::Bool(true));
                }
                windows.push(value);
            }
        }
    }
    Ok(Some(service_result("windows", None, windows)))
}

fn seroval_object(body: &str) -> Option<&str> {
    let marker = "$R[0]={";
    let start = body.find(marker)? + marker.len() - 1;
    let bytes = body.as_bytes();
    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    for (index, byte) in bytes.iter().enumerate().skip(start) {
        let character = *byte as char;
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return body.get(start..=index);
                }
            }
            _ => {}
        }
    }
    None
}

fn rewrite_seroval_tokens(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(input.len());
    let mut index = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while index < bytes.len() {
        let character = bytes[index] as char;
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            output.push(character);
            index += 1;
            continue;
        }
        if bytes[index..].starts_with(b"$R[") {
            if let Some(end) = input[index + 3..].find(']') {
                let end = index + 3 + end + 1;
                let mut cursor = end;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                if cursor < bytes.len() && bytes[cursor] == b'=' {
                    index = cursor + 1;
                    continue;
                }
                output.push_str("null");
                index = end;
                continue;
            }
        }
        if bytes[index..].starts_with(b"!0") {
            output.push_str("false");
            index += 2;
            continue;
        }
        if bytes[index..].starts_with(b"!1") {
            output.push_str("true");
            index += 2;
            continue;
        }
        if input[index..].starts_with("undefined") {
            output.push_str("null");
            index += "undefined".len();
            continue;
        }
        output.push(character);
        index += 1;
    }
    quote_seroval_keys(&output)
}

fn quote_seroval_keys(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(input.len() + 32);
    let mut index = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    while index < bytes.len() {
        let character = bytes[index] as char;
        if in_string {
            output.push(character);
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        if character == '"' {
            in_string = true;
            output.push(character);
            index += 1;
            continue;
        }
        if character == '{' || character == ',' {
            output.push(character);
            index += 1;
            while index < bytes.len() && bytes[index].is_ascii_whitespace() {
                output.push(bytes[index] as char);
                index += 1;
            }
            let start = index;
            while index < bytes.len()
                && (bytes[index].is_ascii_alphanumeric() || bytes[index] == b'_')
            {
                index += 1;
            }
            if index > start {
                let mut cursor = index;
                while cursor < bytes.len() && bytes[cursor].is_ascii_whitespace() {
                    cursor += 1;
                }
                if cursor < bytes.len() && bytes[cursor] == b':' {
                    output.push('"');
                    output.push_str(&input[start..index]);
                    output.push('"');
                    output.push_str(&input[index..cursor]);
                    index = cursor;
                    continue;
                }
                output.push_str(&input[start..index]);
            }
            continue;
        }
        output.push(character);
        index += 1;
    }
    output
}

/// Parse the private OpenCode GO seroval response into the stable quota shape.
pub fn parse_opencode_go_body(body: &[u8], now_epoch: i64) -> Result<Option<Value>, ProviderError> {
    let text = std::str::from_utf8(body).map_err(|_| invalid_payload())?;
    let object = seroval_object(text).ok_or_else(invalid_payload)?;
    let normalized = rewrite_seroval_tokens(object);
    let payload: Value = serde_json::from_str(&normalized).map_err(|_| invalid_payload())?;
    parse_opencode_go_usage(&payload, now_epoch)
}

/// Parse normalized OpenCode GO usage. Missing/non-active windows are omitted.
pub fn parse_opencode_go_usage(
    payload: &Value,
    now_epoch: i64,
) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    for (key, label, minutes) in [
        ("rollingUsage", "每 5 小时", 300u64),
        ("weeklyUsage", "每周", 10080u64),
        ("monthlyUsage", "每月", 43200u64),
    ] {
        let Some(usage) = object.get(key).and_then(Value::as_object) else {
            continue;
        };
        if usage.get("status").and_then(Value::as_str) != Some("ok") {
            continue;
        }
        let percent = number(usage.get("usagePercent")).unwrap_or(0.0);
        let reset = number(usage.get("resetInSec"))
            .filter(|value| value.is_finite())
            .map(|value| now_epoch.saturating_add(value as i64));
        windows.push(window(label, clamp_percent(percent), Some(minutes), reset));
    }
    Ok(Some(service_result("windows", None, windows)))
}

#[derive(Default)]
struct ProtoScan {
    varint: Vec<(Vec<u32>, u64)>,
    fixed32: Vec<(Vec<u32>, f32, usize)>,
}

fn read_varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *index < data.len() && shift < 64 {
        let byte = data[*index];
        *index += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn scan_protobuf(data: &[u8], depth: u8, path: &[u32], order: &mut usize, scan: &mut ProtoScan) {
    let mut index = 0usize;
    while index < data.len() {
        let field_start = index;
        let Some(key) = read_varint(data, &mut index) else {
            index = field_start.saturating_add(1);
            continue;
        };
        if key == 0 {
            index = field_start.saturating_add(1);
            continue;
        }
        let field_number = (key >> 3) as u32;
        let wire_type = key & 7;
        if field_number == 0 {
            index = field_start.saturating_add(1);
            continue;
        }
        let mut field_path = path.to_vec();
        field_path.push(field_number);
        match wire_type {
            0 => {
                if let Some(value) = read_varint(data, &mut index) {
                    scan.varint.push((field_path, value));
                } else {
                    index = field_start.saturating_add(1);
                }
            }
            1 => {
                if index + 8 > data.len() {
                    return;
                }
                index += 8;
            }
            2 => {
                let Some(length) =
                    read_varint(data, &mut index).and_then(|value| usize::try_from(value).ok())
                else {
                    index = field_start.saturating_add(1);
                    continue;
                };
                let Some(end) = index.checked_add(length) else {
                    index = field_start.saturating_add(1);
                    continue;
                };
                if end > data.len() {
                    index = field_start.saturating_add(1);
                    continue;
                }
                if depth < 4 {
                    scan_protobuf(&data[index..end], depth + 1, &field_path, order, scan);
                }
                index = end;
            }
            5 => {
                if index + 4 > data.len() {
                    return;
                }
                let value = f32::from_le_bytes(data[index..index + 4].try_into().unwrap());
                scan.fixed32.push((field_path, value, *order));
                *order += 1;
                index += 4;
            }
            _ => index = field_start.saturating_add(1),
        }
    }
}

fn grpc_data_frames(data: &[u8]) -> Option<Vec<&[u8]>> {
    let mut frames = Vec::new();
    let mut index = 0usize;
    while index < data.len() {
        if index + 5 > data.len() {
            return None;
        }
        let flags = data[index];
        let length = u32::from_be_bytes(data[index + 1..index + 5].try_into().ok()?) as usize;
        let start = index + 5;
        let end = start.checked_add(length)?;
        if end > data.len() {
            return None;
        }
        if flags & 0x80 == 0 {
            frames.push(&data[start..end]);
        }
        index = end;
    }
    Some(frames)
}

fn looks_like_protobuf(data: &[u8]) -> bool {
    data.first()
        .is_some_and(|byte| byte >> 3 > 0 && matches!(byte & 7, 0 | 1 | 2 | 5))
}

fn grok_window(resets_at: Option<i64>, now_epoch: i64) -> (&'static str, Option<u64>) {
    let Some(reset) = resets_at else {
        return ("额度", None);
    };
    let days = (((reset - now_epoch) as f64) / 86_400.0).round() as i64;
    if days < 1 {
        ("每 5 小时", Some(300))
    } else if (4..=12).contains(&days) {
        ("每周", Some(10080))
    } else if (20..=45).contains(&days) {
        ("每月", Some(43200))
    } else {
        ("额度", None)
    }
}

/// Parse Grok's gRPC-web/protobuf billing response using the same bounded heuristic as Python.
pub fn parse_grok_usage(body: &[u8], now_epoch: i64) -> Result<Option<Value>, ProviderError> {
    let frames = grpc_data_frames(body).filter(|frames| !frames.is_empty());
    let payloads: Vec<&[u8]> = match frames {
        Some(frames) => frames,
        None if looks_like_protobuf(body) => vec![body],
        None => return Err(invalid_payload()),
    };
    let mut scan = ProtoScan::default();
    let mut order = 0usize;
    for payload in payloads {
        scan_protobuf(payload, 0, &[], &mut order, &mut scan);
    }
    let mut percent = scan
        .fixed32
        .iter()
        .filter(|(path, value, _)| {
            !path.is_empty()
                && *path.last().unwrap_or(&0) == 1
                && value.is_finite()
                && (0.0..=100.0).contains(value)
        })
        .min_by_key(|(path, _, order)| (path.len(), *order))
        .map(|(_, value, _)| f64::from(*value));
    let mut resets = scan
        .varint
        .iter()
        .filter(|(_, value)| {
            (1_700_000_000..=2_100_000_000).contains(value) && (*value as i64) > now_epoch
        })
        .map(|(path, value)| (path, *value as i64))
        .collect::<Vec<_>>();
    let reset = resets
        .iter()
        .filter(|(path, _)| *path == &[1, 5, 1])
        .map(|(_, value)| *value)
        .min()
        .or_else(|| {
            resets.sort_by_key(|(_, value)| *value);
            resets.first().map(|(_, value)| *value)
        });
    let has_period = scan.varint.iter().any(|(path, value)| {
        path.starts_with(&[1, 6]) || (path == &[1, 8, 1] && matches!(value, 1 | 2))
    });
    if percent.is_none() && scan.fixed32.is_empty() && reset.is_some() && has_period {
        percent = Some(0.0);
    }
    let percent = percent.ok_or_else(invalid_payload)?;
    let (label, minutes) = grok_window(reset, now_epoch);
    Ok(Some(service_result(
        "windows",
        None,
        vec![window(label, clamp_percent(percent), minutes, reset)],
    )))
}

fn optional_credential_string<'a>(
    request: &'a ProviderRequest,
    keys: &[&str],
) -> Result<Option<&'a str>, ProviderError> {
    let Some(credential) = request.credential.as_ref() else {
        return Ok(None);
    };
    if credential.is_null() {
        return Ok(None);
    }
    credential_string(credential, keys)
        .map(Some)
        .ok_or_else(invalid_credential)
}

fn json_credential(credential: &Value) -> Result<Value, ProviderError> {
    match credential {
        Value::String(value) => serde_json::from_str(value).map_err(|_| invalid_credential()),
        Value::Object(_) => Ok(credential.clone()),
        _ => Err(invalid_credential()),
    }
}

fn provider_headers(entries: &[(&str, String)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

#[derive(Debug, Clone, Copy, Default)]
pub struct KimiProvider;

impl QuotaProvider for KimiProvider {
    fn app(&self) -> &str {
        "kimi"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(api_key) = optional_credential_string(request, &["api_key", "apiKey", "token"])?
        else {
            return Ok(None);
        };
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            KIMI_USAGE_URL.to_owned(),
            provider_headers(&[
                ("Authorization", format!("Bearer {api_key}")),
                ("Accept", "application/json".to_owned()),
            ]),
            None,
            Some("Kimi 凭证被拒绝, 请检查 API key"),
        )?;
        parse_kimi_usage(&payload)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct DeepSeekProvider;

impl QuotaProvider for DeepSeekProvider {
    fn app(&self) -> &str {
        "deepseek"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(api_key) = optional_credential_string(request, &["api_key", "apiKey", "token"])?
        else {
            return Ok(None);
        };
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            DEEPSEEK_BALANCE_URL.to_owned(),
            provider_headers(&[
                ("Authorization", format!("Bearer {api_key}")),
                ("Accept", "application/json".to_owned()),
            ]),
            None,
            Some("DeepSeek 凭证被拒绝, 请检查 API key"),
        )?;
        parse_deepseek_balance(&payload)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ZhipuProvider;

impl QuotaProvider for ZhipuProvider {
    fn app(&self) -> &str {
        "zhipu"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let object = credential.as_object().ok_or_else(invalid_credential)?;
        let Some(api_key) = object
            .get("api_key")
            .or_else(|| object.get("apiKey"))
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            return Err(invalid_credential());
        };
        let Some(base_url) = object.get("base_url").and_then(Value::as_str) else {
            return Err(invalid_credential());
        };
        let host = if base_url.to_ascii_lowercase().contains("bigmodel.cn") {
            "open.bigmodel.cn"
        } else {
            "api.z.ai"
        };
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            format!("https://{host}{ZHIPU_QUOTA_PATH}"),
            provider_headers(&[
                ("Authorization", api_key.to_owned()),
                ("Content-Type", "application/json".to_owned()),
                ("Accept-Language", "en-US,en".to_owned()),
            ]),
            None,
            Some("智谱凭证被拒绝, 请检查 API key"),
        )?;
        parse_zhipu_usage(&payload)
    }
}

fn sha256_hex(value: &[u8]) -> String {
    let digest = Sha256::digest(value);
    hex_bytes(&digest)
}

fn hex_bytes(value: &[u8]) -> String {
    let mut output = String::with_capacity(value.len() * 2);
    for byte in value {
        let _ = write!(&mut output, "{byte:02x}");
    }
    output
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut normalized = [0u8; 64];
    if key.len() > 64 {
        normalized[..32].copy_from_slice(&Sha256::digest(key));
    } else {
        normalized[..key.len()].copy_from_slice(key);
    }
    let mut inner_key = [0u8; 64];
    let mut outer_key = [0u8; 64];
    for index in 0..64 {
        inner_key[index] = normalized[index] ^ 0x36;
        outer_key[index] = normalized[index] ^ 0x5c;
    }
    let mut inner = Sha256::new();
    inner.update(inner_key);
    inner.update(message);
    let inner_digest = inner.finalize();
    let mut outer = Sha256::new();
    outer.update(outer_key);
    outer.update(inner_digest);
    outer.finalize().into()
}

fn hmac_hex(key: &[u8], message: &[u8]) -> String {
    hex_bytes(&hmac_sha256(key, message))
}

fn base64_decode_text(value: &str) -> Option<String> {
    let mut output = Vec::new();
    let mut accumulator = 0u32;
    let mut bits = 0u8;
    for byte in value.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        if byte == b'=' {
            break;
        }
        let digit = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        accumulator = (accumulator << 6) | u32::from(digit);
        bits += 6;
        while bits >= 8 {
            bits -= 8;
            output.push((accumulator >> bits) as u8);
            if bits > 0 {
                accumulator &= (1 << bits) - 1;
            } else {
                accumulator = 0;
            }
        }
    }
    String::from_utf8(output)
        .ok()
        .filter(|value| !value.is_empty())
}

fn volc_secret_candidates(raw: &str) -> Vec<String> {
    let mut candidates = vec![raw.to_owned()];
    let mut current = raw.to_owned();
    for _ in 0..2 {
        let Some(decoded) = base64_decode_text(&current) else {
            break;
        };
        if candidates.contains(&decoded) {
            break;
        }
        current = decoded.clone();
        candidates.push(decoded);
    }
    candidates
}

fn volc_credential_field<'a>(credential: &'a Value, key: &str) -> Option<&'a str> {
    let object = credential.as_object()?;
    let nested = object.get("usage_script").and_then(Value::as_object);
    nested
        .and_then(|value| value.get(key))
        .or_else(|| object.get(key))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
}

fn volc_headers(
    secret: &str,
    access_key: &str,
    captured_at: &str,
    query: &str,
) -> BTreeMap<String, String> {
    let epoch = captured_epoch(captured_at);
    let date = DateTime::<Utc>::from_timestamp(epoch, 0).unwrap_or_else(Utc::now);
    let x_date = date.format("%Y%m%dT%H%M%SZ").to_string();
    let short_date = date.format("%Y%m%d").to_string();
    let payload_hash = sha256_hex(b"");
    let signed_headers = "host;x-date;x-content-sha256;content-type";
    let canonical_headers = format!(
        "host:open.volcengineapi.com\nx-date:{x_date}\nx-content-sha256:{payload_hash}\ncontent-type:application/json; charset=utf-8\n"
    );
    let canonical = format!("GET\n/\n{query}\n{canonical_headers}{signed_headers}\n{payload_hash}");
    let scope = format!("{short_date}/cn-beijing/ark/request");
    let string_to_sign = format!(
        "HMAC-SHA256\n{x_date}\n{scope}\n{}",
        sha256_hex(canonical.as_bytes())
    );
    let date_key = hmac_sha256(secret.as_bytes(), short_date.as_bytes());
    let region_key = hmac_sha256(&date_key, b"cn-beijing");
    let service_key = hmac_sha256(&region_key, b"ark");
    let signing_key = hmac_sha256(&service_key, b"request");
    let signature = hmac_hex(&signing_key, string_to_sign.as_bytes());
    provider_headers(&[
        (
            "Authorization",
            format!(
                "HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"
            ),
        ),
        ("x-date", x_date),
        ("x-content-sha256", payload_hash),
        (
            "content-type",
            "application/json; charset=utf-8".to_owned(),
        ),
    ])
}

#[derive(Debug, Clone, Copy, Default)]
pub struct VolcEngineProvider;

impl QuotaProvider for VolcEngineProvider {
    fn app(&self) -> &str {
        "volcengine"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let Some(access_key) = volc_credential_field(credential, "accessKeyId") else {
            return Err(invalid_credential());
        };
        let Some(secret) = volc_credential_field(credential, "secretAccessKey") else {
            return Err(invalid_credential());
        };
        let mut last_error = None;
        for candidate in volc_secret_candidates(secret) {
            for action in ["GetCodingPlanUsage", "GetAFPUsage"] {
                let query = format!("Action={action}&Version=2024-01-01");
                let result = send_json(
                    request,
                    http,
                    cancellation,
                    "GET",
                    format!("https://open.volcengineapi.com/?{query}"),
                    volc_headers(&candidate, access_key, &request.captured_at, &query),
                    None,
                    Some("火山引擎额度请求被拒绝, 请检查访问凭证"),
                )
                .and_then(|payload| {
                    let result = payload
                        .get("Result")
                        .or_else(|| payload.get("result"))
                        .unwrap_or(&payload);
                    parse_volcengine_usage(result).map(|value| value.unwrap_or(Value::Null))
                });
                match result {
                    Ok(Value::Null) => return Ok(None),
                    Ok(value) => return Ok(Some(value)),
                    Err(error) => last_error = Some(error),
                }
            }
        }
        Err(last_error.unwrap_or_else(|| {
            ProviderError::new(
                "PROVIDER_REQUEST_FAILED",
                "request",
                "火山引擎额度查询失败",
                true,
            )
        }))
    }
}

fn claude_token(credential: &Value) -> Result<Option<String>, ProviderError> {
    let root = json_credential(credential)?;
    let object = root.as_object().ok_or_else(invalid_credential)?;
    let entry = object
        .get("claudeAiOauth")
        .or_else(|| object.get("claude.ai_oauth"))
        .and_then(Value::as_object);
    Ok(entry
        .and_then(|value| value.get("accessToken"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned))
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ClaudeProvider;

impl QuotaProvider for ClaudeProvider {
    fn app(&self) -> &str {
        "claude"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let Some(token) = claude_token(credential)? else {
            return Ok(None);
        };
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            CLAUDE_USAGE_URL.to_owned(),
            provider_headers(&[
                ("Authorization", format!("Bearer {token}")),
                ("anthropic-beta", CLAUDE_BETA_HEADER.to_owned()),
                ("Accept", "application/json".to_owned()),
            ]),
            None,
            Some("Claude 凭证被拒绝, 请重新登录 Claude CLI"),
        )?;
        parse_claude_usage(&payload)
    }
}

fn opencode_credential(credential: &Value) -> Result<(&str, &str), ProviderError> {
    let object = credential.as_object().ok_or_else(invalid_credential)?;
    let auth = object
        .get("auth")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(invalid_credential)?;
    let workspace = object
        .get("workspaceId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(invalid_credential)?;
    Ok((auth, workspace))
}

fn percent_encode(value: &str) -> String {
    let mut output = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            output.push(byte as char);
        } else {
            output.push('%');
            output.push_str(&format!("{byte:02X}"));
        }
    }
    output
}

#[derive(Debug, Clone, Copy, Default)]
pub struct OpenCodeGoProvider;

impl QuotaProvider for OpenCodeGoProvider {
    fn app(&self) -> &str {
        "opencode-go"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let (auth, workspace) = opencode_credential(credential)?;
        let url = format!(
            "{OPENCODE_SERVER_URL}?id={}&args=%5B%22{}%22%5D",
            OPENCODE_SERVER_ID,
            percent_encode(workspace)
        );
        let mut last_error = None;
        for _ in 0..2 {
            let body = send_body(
                request,
                http,
                cancellation,
                "GET",
                url.clone(),
                provider_headers(&[
                    ("Cookie", format!("auth={auth}")),
                    ("Accept", "*/*".to_owned()),
                    ("X-Server-Id", OPENCODE_SERVER_ID.to_owned()),
                    ("X-Server-Instance", "server-fn:bruce".to_owned()),
                ]),
                None,
                Some("OpenCode GO 会话已失效, 请重新登录 opencode.ai"),
            );
            match body.and_then(|body| {
                parse_opencode_go_body(&body, captured_epoch(&request.captured_at))
            }) {
                Ok(result) => return Ok(result),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.unwrap_or_else(|| {
            ProviderError::new(
                "PROVIDER_REQUEST_FAILED",
                "request",
                "OpenCode GO 查询失败",
                true,
            )
        }))
    }
}

fn grok_token(credential: &Value) -> Result<Option<String>, ProviderError> {
    let root = json_credential(credential)?;
    let object = root.as_object().ok_or_else(invalid_credential)?;
    if let Some(token) = object.get("key").and_then(Value::as_str) {
        return Ok((!token.is_empty()).then_some(token.to_owned()));
    }
    let mut legacy = None;
    for (scope, value) in object {
        let Some(value) = value.as_object() else {
            continue;
        };
        let Some(token) = value
            .get("key")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        if scope.starts_with("https://auth.x.ai::") {
            return Ok(Some(token.to_owned()));
        }
        if scope == "https://accounts.x.ai/sign-in" || scope.contains("/sign-in") {
            legacy = Some(token.to_owned());
        }
    }
    Ok(legacy)
}

#[derive(Debug, Clone, Copy, Default)]
pub struct GrokProvider;

impl QuotaProvider for GrokProvider {
    fn app(&self) -> &str {
        "grok"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let Some(token) = grok_token(credential)? else {
            return Ok(None);
        };
        let body = send_body(
            request,
            http,
            cancellation,
            "POST",
            GROK_BILLING_URL.to_owned(),
            provider_headers(&[
                ("Authorization", format!("Bearer {token}")),
                ("Origin", "https://grok.com".to_owned()),
                ("Referer", "https://grok.com/?_s=usage".to_owned()),
                ("Accept", "*/*".to_owned()),
                ("Content-Type", "application/grpc-web+proto".to_owned()),
                ("x-grpc-web", "1".to_owned()),
                ("x-user-agent", "connect-es/2.1.1".to_owned()),
                ("User-Agent", "Bruce-collector".to_owned()),
            ]),
            Some(vec![0; 5]),
            Some("Grok 凭证被拒绝, 请重新 grok login"),
        )?;
        parse_grok_usage(&body, captured_epoch(&request.captured_at))
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct CodexProvider;

impl QuotaProvider for CodexProvider {
    fn app(&self) -> &str {
        "codex"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(credential) = request.credential.as_ref() else {
            return Ok(None);
        };
        let token =
            credential_string(credential, &["access_token"]).ok_or_else(invalid_credential)?;
        let account_id = request
            .account_id
            .as_deref()
            .filter(|value| !value.is_empty())
            .ok_or_else(invalid_credential)?;
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            CODEX_USAGE_URL.to_owned(),
            provider_headers(&[
                ("Authorization", format!("Bearer {token}")),
                ("chatgpt-account-id", account_id.to_owned()),
                ("User-Agent", "codex-cli/1.0".to_owned()),
                ("Accept", "application/json".to_owned()),
            ]),
            None,
            Some("Codex 登录态已失效, 请重新登录该账号"),
        )?;
        parse_codex_usage(&payload)
    }
}

pub const SUPPORTED_PROVIDER_APPS: &[&str] = &[
    "opencode-go",
    "kimi",
    "deepseek",
    "zhipu",
    "volcengine",
    "claude",
    "grok",
    "codex",
];

/// Return the read-only quota adapter for a stable provider app ID.
pub fn provider_for_app(app: &str) -> Option<Box<dyn QuotaProvider>> {
    match app {
        "opencode-go" => Some(Box::new(OpenCodeGoProvider)),
        "kimi" => Some(Box::new(KimiProvider)),
        "deepseek" => Some(Box::new(DeepSeekProvider)),
        "zhipu" => Some(Box::new(ZhipuProvider)),
        "volcengine" => Some(Box::new(VolcEngineProvider)),
        "claude" => Some(Box::new(ClaudeProvider)),
        "grok" => Some(Box::new(GrokProvider)),
        "codex" => Some(Box::new(CodexProvider)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        bounded_http_body, codex_service_id, parse_claude_usage, parse_codex_usage,
        parse_deepseek_balance, parse_grok_usage, parse_json_body, parse_kimi_usage,
        parse_opencode_go_body, parse_volcengine_usage, parse_zhipu_usage, resolve_service_catalog,
        service_template, AccountDescriptor, CancellationToken, CatalogInput, CodexProvider,
        DeepSeekProvider, HttpClient, HttpRequest, HttpResponse, KimiProvider, OpenCodeGoProvider,
        ProviderError, ProviderRequest, QuotaProvider, ServiceDescriptor, UreqHttpClient,
        VolcEngineProvider,
    };
    use collector_runtime::RuntimeLimits;
    use serde_json::{json, Value};
    use sha2::Digest;
    use std::collections::{BTreeMap, BTreeSet};
    use std::sync::Mutex;
    use std::time::Duration;

    struct FixtureHttp {
        responses: Mutex<std::collections::VecDeque<Result<HttpResponse, ProviderError>>>,
        requests: Mutex<Vec<HttpRequest>>,
    }

    impl FixtureHttp {
        fn new(responses: Vec<Result<HttpResponse, ProviderError>>) -> Self {
            Self {
                responses: Mutex::new(responses.into()),
                requests: Mutex::new(Vec::new()),
            }
        }

        fn requests(&self) -> Vec<HttpRequest> {
            self.requests.lock().unwrap().clone()
        }
    }

    impl HttpClient for FixtureHttp {
        fn send(
            &self,
            request: HttpRequest,
            cancellation: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            cancellation.check().map_err(ProviderError::from_runtime)?;
            self.requests.lock().unwrap().push(request);
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| {
                    Err(ProviderError::new(
                        "FIXTURE_EXHAUSTED",
                        "test",
                        "fixture response 不足",
                        false,
                    ))
                })
        }
    }

    fn provider_request(app: &str, credential: Value) -> ProviderRequest {
        ProviderRequest {
            service: ServiceDescriptor {
                id: format!("{app}_fixture"),
                name: app.to_owned(),
                app: app.to_owned(),
                is_current: false,
            },
            account_id: None,
            captured_at: "2026-08-21T00:00:00Z".to_owned(),
            timeout: Duration::from_secs(8),
            max_response_body_bytes: RuntimeLimits::default().response_body_bytes,
            credential: Some(credential),
        }
    }

    fn response(body: &str) -> Result<HttpResponse, ProviderError> {
        Ok(HttpResponse {
            status: 200,
            body: body.as_bytes().to_vec(),
        })
    }

    #[test]
    fn catalog_is_stable_and_rejects_duplicate_accounts() {
        let mut input = CatalogInput::default();
        input.accounts.insert(
            "kimi".to_owned(),
            vec![
                AccountDescriptor {
                    account_id: "z-account".to_owned(),
                    display_name: None,
                },
                AccountDescriptor {
                    account_id: "a-account".to_owned(),
                    display_name: Some("Kimi · A".to_owned()),
                },
            ],
        );
        input.enabled_official.insert("claude".to_owned());
        let services = resolve_service_catalog(&input, None).unwrap();
        assert_eq!(services[0].id, "kimi_coding_a-account");
        assert_eq!(services[1].id, "kimi_coding_z-account");
        assert_eq!(services[2].id, "claude");
        let target = BTreeSet::from(["kimi".to_owned()]);
        assert_eq!(
            resolve_service_catalog(&input, Some(&target))
                .unwrap()
                .len(),
            2
        );
        let mut duplicate = input;
        duplicate
            .accounts
            .get_mut("kimi")
            .unwrap()
            .push(AccountDescriptor {
                account_id: "a-account".to_owned(),
                display_name: None,
            });
        assert!(resolve_service_catalog(&duplicate, None).is_err());
    }

    #[test]
    fn response_body_and_service_template_are_bounded() {
        assert_eq!(
            bounded_http_body(
                HttpResponse {
                    status: 200,
                    body: br#"{"ok":true}"#.to_vec(),
                },
                128,
            )
            .unwrap(),
            br#"{"ok":true}"#.to_vec()
        );
        assert!(bounded_http_body(
            HttpResponse {
                status: 200,
                body: vec![b'x'; 129],
            },
            128,
        )
        .is_err());
        let parsed = parse_json_body(
            HttpResponse {
                status: 200,
                body: br#"{"windows":[]}"#.to_vec(),
            },
            128,
        )
        .unwrap();
        assert!(parsed.is_object());
        let service = super::ServiceDescriptor {
            id: "kimi_coding_a".to_owned(),
            name: "Kimi · A".to_owned(),
            app: "kimi".to_owned(),
            is_current: false,
        };
        let value = service_template(&service, "2026-08-21T00:00:00+00:00");
        assert_eq!(value["status"], "ok");
    }

    #[test]
    fn catalog_input_uses_ordered_maps_without_hash_iteration() {
        let input = CatalogInput {
            accounts: BTreeMap::new(),
            enabled_official: BTreeSet::new(),
        };
        assert!(resolve_service_catalog(&input, None).unwrap().is_empty());
    }

    #[test]
    fn provider_registry_resolves_only_supported_stable_app_ids() {
        for app in super::SUPPORTED_PROVIDER_APPS {
            assert_eq!(super::provider_for_app(app).unwrap().app(), *app);
        }
        assert_eq!(super::provider_for_app("codex").unwrap().app(), "codex");
        let _ = UreqHttpClient::default();
    }

    #[test]
    fn codex_parser_and_provider_preserve_account_quota_contract() {
        let parsed = parse_codex_usage(&json!({
            "plan_type": "fixture-plan",
            "rate_limit": {
                "primary_window": {
                    "limit_window_seconds": 18000,
                    "used_percent": 42,
                    "reset_at": "2026-08-21T17:00:00+08:00"
                },
                "secondary_window": {
                    "limit_window_seconds": 604800,
                    "used_percent": 12.5,
                    "reset_at": 1785000000
                }
            },
            "credits": {"unlimited": true}
        }))
        .unwrap()
        .unwrap();
        assert_eq!(parsed["kind"], "windows");
        assert_eq!(parsed["plan"], "fixture-plan");
        assert_eq!(parsed["windows"][0]["label"], "5小时窗口");
        assert_eq!(parsed["windows"][0]["windowMinutes"], 300);
        assert_eq!(parsed["windows"][0]["usedPercent"], 42.0);
        assert_eq!(parsed["extra"], "Credits 不限量");
        assert_eq!(
            codex_service_id("acc-1"),
            "codex_".to_owned() + &sha256_prefix("acc-1")
        );

        let http = FixtureHttp::new(vec![response(
            r#"{"plan_type":"fixture-plan","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42,"reset_at":"2026-08-21T17:00:00+08:00"}}}"#,
        )]);
        let mut request = provider_request(
            "codex",
            json!({"display_name": "Codex · user", "access_token": "fixture-token"}),
        );
        request.account_id = Some("acc-1".to_owned());
        let result = CodexProvider
            .query(&request, &http, &CancellationToken::new())
            .unwrap()
            .unwrap();
        assert_eq!(result["windows"][0]["usedPercent"], 42.0);
        let sent = &http.requests()[0];
        assert_eq!(sent.url, super::CODEX_USAGE_URL);
        assert_eq!(sent.headers["Authorization"], "Bearer fixture-token");
        assert_eq!(sent.headers["chatgpt-account-id"], "acc-1");
        assert!(!sent.url.contains("fixture-token"));
    }

    fn sha256_prefix(value: &str) -> String {
        let digest = sha2::Sha256::digest(value.as_bytes());
        format!("{:x}", digest)[..16].to_owned()
    }

    #[test]
    fn codex_401_is_auth_error_without_secret_in_diagnostic() {
        let secret = "fixture-codex-token";
        let http = FixtureHttp::new(vec![Ok(HttpResponse {
            status: 401,
            body: br#"{"error":"unauthorized"}"#.to_vec(),
        })]);
        let mut request = provider_request("codex", json!({"access_token": secret}));
        request.account_id = Some("acc-1".to_owned());
        let error = CodexProvider
            .query(&request, &http, &CancellationToken::new())
            .unwrap_err();
        assert_eq!(error.diagnostic.code, "PROVIDER_AUTH_REJECTED");
        assert!(!error.diagnostic.message.contains(secret));
    }

    #[test]
    fn provider_parsers_preserve_quota_shapes_and_reset_units() {
        let kimi = parse_kimi_usage(&json!({
            "limits": [{"detail": {"limit": 100, "remaining": 25, "resetTime": "2026-08-21T01:00:00Z"}}],
            "usage": {"limit": 200, "remaining": 100, "resetTime": "2026-08-22T00:00:00Z"}
        }))
        .unwrap()
        .unwrap();
        assert_eq!(kimi["windows"][0]["usedPercent"], 75.0);
        assert_eq!(kimi["windows"][0]["windowMinutes"], 300);
        assert_eq!(kimi["windows"][1]["windowMinutes"], 10080);

        let deepseek = parse_deepseek_balance(&json!({
            "balance_infos": [{"total_balance": "12.5", "currency": "USD"}]
        }))
        .unwrap()
        .unwrap();
        assert_eq!(deepseek["balance"], 12.5);
        assert_eq!(deepseek["currency"], "USD");

        let zhipu = parse_zhipu_usage(&json!({
            "success": true,
            "data": {
                "level": "pro",
                "limits": [
                    {"type": "CREDIT_LIMIT", "unit": 3, "percentage": 18.0, "nextResetTime": 1_800_000_000_000i64},
                    {"type": "TOKENS_LIMIT", "unit": 6, "percentage": 42.0, "nextResetTime": 1_800_100_000i64},
                    {"type": "TIME_LIMIT", "unit": 3, "percentage": 99.0}
                ]
            }
        }))
        .unwrap()
        .unwrap();
        assert_eq!(zhipu["plan"], "pro");
        assert_eq!(zhipu["windows"].as_array().unwrap().len(), 2);
        assert_eq!(zhipu["windows"][0]["resetsAt"], 1_800_000_000);

        let volc = parse_volcengine_usage(&json!({
            "QuotaUsage": [
                {"Level": "session", "Percent": 101.0, "ResetTimestamp": -1},
                {"Level": "weekly", "Percent": 33.0, "ResetTimestamp": 1_800_000_000}
            ]
        }))
        .unwrap()
        .unwrap();
        assert_eq!(volc["windows"][0]["usedPercent"], 100.0);
        assert_eq!(volc["windows"][0]["resetsAt"], Value::Null);
        assert_eq!(volc["windows"][1]["resetsAt"], 1_800_000_000);

        let claude = parse_claude_usage(&json!({
            "five_hour": {"utilization": 7.0, "resets_at": "2026-08-21T02:00:00Z"},
            "extra_usage": {"is_enabled": true, "utilization": 3.0},
            "inactive": {"status": "not_subscribed", "utilization": 99.0}
        }))
        .unwrap()
        .unwrap();
        assert_eq!(claude["windows"].as_array().unwrap().len(), 3);
        assert!(claude["windows"]
            .as_array()
            .unwrap()
            .iter()
            .any(|window| window["ownRow"] == true));
    }

    #[test]
    fn opencode_seroval_parser_omits_unsubscribed_windows() {
        let body = br#";((self.$R=self.$R||{})["server-fn:x"]=[],($R=>$R[0]={mine:!0,rollingUsage:{status:"ok",usagePercent:12.5,resetInSec:60},weeklyUsage:{status:"ok",usagePercent:20,resetInSec:3600},monthlyUsage:{status:"not_subscribed",usagePercent:99}})($R["server-fn:x"]))"#;
        let parsed = parse_opencode_go_body(body, 1_800_000_000)
            .unwrap()
            .unwrap();
        assert_eq!(parsed["windows"].as_array().unwrap().len(), 2);
        assert_eq!(parsed["windows"][0]["usedPercent"], 12.5);
        assert_eq!(parsed["windows"][0]["resetsAt"], 1_800_000_060i64);
    }

    #[test]
    fn grok_parser_handles_bounded_grpc_web_heuristic() {
        let reset = 1_800_000_100u64;
        let nested_reset = {
            let mut value = vec![0x08];
            value.extend(encode_varint(reset));
            value
        };
        let mut nested = vec![0x2a, nested_reset.len() as u8];
        nested.extend(nested_reset);
        nested.extend([0x30, 0x01]);
        let mut body = vec![0x0d];
        body.extend(20.0f32.to_le_bytes());
        body.extend([0x0a, nested.len() as u8]);
        body.extend(nested);
        let parsed = parse_grok_usage(&body, 1_800_000_000).unwrap().unwrap();
        assert_eq!(parsed["windows"][0]["usedPercent"], 20.0);
        assert_eq!(parsed["windows"][0]["label"], "每 5 小时");
    }

    fn encode_varint(mut value: u64) -> Vec<u8> {
        let mut output = Vec::new();
        loop {
            let mut byte = (value & 0x7f) as u8;
            value >>= 7;
            if value != 0 {
                byte |= 0x80;
            }
            output.push(byte);
            if value == 0 {
                return output;
            }
        }
    }

    #[test]
    fn fixture_http_client_checks_request_headers_and_retry_count() {
        let http = FixtureHttp::new(vec![
            response("not seroval"),
            response("$R[0]={rollingUsage:{status:\"ok\",usagePercent:10,resetInSec:5}}"),
        ]);
        let request = provider_request(
            "opencode-go",
            json!({"auth": "fixture-cookie", "workspaceId": "wrk_fixture"}),
        );
        let result = OpenCodeGoProvider
            .query(&request, &http, &CancellationToken::new())
            .unwrap()
            .unwrap();
        assert_eq!(result["windows"][0]["usedPercent"], 10.0);
        let requests = http.requests();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0].timeout, Duration::from_secs(8));
        assert_eq!(requests[0].headers["Cookie"], "auth=fixture-cookie");
        assert!(!requests[0].url.contains("fixture-cookie"));
    }

    #[test]
    fn fixture_provider_clients_never_put_credential_in_diagnostic() {
        let secret = "fixture-provider-secret";
        let http = FixtureHttp::new(vec![response("[]")]);
        let request = provider_request("kimi", json!({"api_key": secret}));
        let error = KimiProvider
            .query(&request, &http, &CancellationToken::new())
            .unwrap_err();
        assert!(!error.diagnostic.message.contains(secret));

        let bad_status = FixtureHttp::new(vec![Ok(HttpResponse {
            status: 401,
            body: Vec::new(),
        })]);
        let error = DeepSeekProvider
            .query(
                &provider_request("deepseek", json!({"api_key": secret})),
                &bad_status,
                &CancellationToken::new(),
            )
            .unwrap_err();
        assert_eq!(error.diagnostic.code, "PROVIDER_AUTH_REJECTED");
        assert!(!error.diagnostic.message.contains(secret));
    }

    #[test]
    fn provider_request_uses_bounded_body_and_volc_signature_path() {
        let http = FixtureHttp::new(vec![response(
            r#"{"QuotaUsage":[{"Level":"session","Percent":12.0,"ResetTimestamp":-1}]}"#,
        )]);
        let result = VolcEngineProvider
            .query(
                &provider_request(
                    "volcengine",
                    json!({"accessKeyId":"fixture-ak","secretAccessKey":"fixture-sk"}),
                ),
                &http,
                &CancellationToken::new(),
            )
            .unwrap()
            .unwrap();
        assert_eq!(result["windows"][0]["usedPercent"], 12.0);
        let request = &http.requests()[0];
        assert!(request.headers.contains_key("Authorization"));
        assert!(!request.headers["Authorization"].contains("fixture-sk"));
    }
}
