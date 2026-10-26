#![deny(unsafe_code)]

//! Read-only quota and Provider adapters.
//! Submodules split protocol decoders, signing helpers, quota parsers, and
//! provider implementations by single responsibility (C053).

mod protobuf;
mod providers;
mod quota_parsers;
mod seroval;
mod signing;
#[cfg(test)]
mod tests_parsers;
#[cfg(test)]
mod tests_providers;

pub use protobuf::parse_grok_usage;
pub use providers::{
    ClaudeProvider, ClineProvider, CodexProvider, DeepSeekProvider, GrokProvider, JevProvider,
    KimiProvider, OpenCodeGoProvider, StepFunProvider, VolcEngineProvider, ZhipuProvider,
};
pub use quota_parsers::{
    codex_service_id, parse_claude_usage, parse_cline_usage_limits, parse_codex_usage,
    parse_deepseek_balance, parse_jev_models, parse_kimi_usage, parse_stepfun_usage,
    parse_volcengine_usage, parse_zhipu_usage,
};
pub use seroval::{parse_opencode_go_body, parse_opencode_go_usage};

use chrono::{DateTime, NaiveDateTime, Utc};
use collector_domain::Diagnostic;
use collector_runtime::{CancellationToken, RuntimeError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt::{self, Display, Formatter};
use std::io::Read;
use std::time::Duration;

pub const MAX_PROVIDER_ACCOUNT_ID_BYTES: usize = 256;
pub const MAX_PROVIDER_DISPLAY_NAME_BYTES: usize = 256;

const CATALOG_SPECS: &[CatalogSpec] = &[
    CatalogSpec {
        provider: "opencode-go",
        prefix: "opencode_go_",
        display_prefix: "OpenCode GO",
        app: "opencode-go",
        credential_field: "opencodeGoQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: true,
    },
    CatalogSpec {
        provider: "kimi",
        prefix: "kimi_coding_",
        display_prefix: "Kimi",
        app: "kimi",
        credential_field: "kimiQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "deepseek",
        prefix: "deepseek_",
        display_prefix: "DeepSeek",
        app: "deepseek",
        credential_field: "deepseekQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "zhipu",
        prefix: "zhipu_",
        display_prefix: "Z.ai",
        app: "zhipu",
        credential_field: "zhipuQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "volcengine",
        prefix: "volcengine_",
        display_prefix: "火山引擎",
        app: "volcengine",
        credential_field: "volcengineQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "claude",
        prefix: "claude_",
        display_prefix: "Claude",
        app: "claude",
        credential_field: "claudeQuotaAccounts",
        direct_credential_field: Some("claudeOAuth"),
        missing_credential_source: Some("Swift 注入"),
        unwraps_oauth_payload: true,
    },
    CatalogSpec {
        provider: "grok",
        prefix: "grok_",
        display_prefix: "Grok",
        app: "grok",
        credential_field: "grokQuotaAccounts",
        direct_credential_field: Some("grokOAuth"),
        missing_credential_source: Some("Swift 注入"),
        unwraps_oauth_payload: true,
    },
    CatalogSpec {
        provider: "stepfun",
        prefix: "stepfun_",
        display_prefix: "StepFun",
        app: "stepfun",
        credential_field: "stepfunQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "jev",
        prefix: "jev_",
        display_prefix: "Jev",
        app: "jev",
        credential_field: "jevQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
    CatalogSpec {
        provider: "cline",
        prefix: "cline_",
        display_prefix: "Cline",
        app: "cline",
        credential_field: "clineQuotaAccounts",
        direct_credential_field: None,
        missing_credential_source: None,
        unwraps_oauth_payload: false,
    },
];

#[derive(Debug, Clone, PartialEq, Eq)]
struct CatalogSpec {
    provider: &'static str,
    prefix: &'static str,
    display_prefix: &'static str,
    app: &'static str,
    /// 凭据字段名 (C049): 与 prefix/app 同源定义, 供 collector-application
    /// 派生而不复写字符串 —— 三处手工映射表曾各自维护且无编译期约束。
    credential_field: &'static str,
    /// 官方直通凭据字段 (C048): 当启用了官方本地凭证但无账号条目时读取的字段。
    direct_credential_field: Option<&'static str>,
    /// 缺失凭据来源提示 (C048): 声明式判定 CREDENTIAL_MISSING, 消除编排层按 app 名分支。
    missing_credential_source: Option<&'static str>,
    /// 账号条目是否内嵌 `oauth` 子对象需解包 (C048)。
    unwraps_oauth_payload: bool,
}

/// 目录表对外只读投影 (C049 / C048): 前缀 / app / 凭据字段与凭据需求的唯一事实源。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CatalogEntry {
    pub provider: &'static str,
    pub prefix: &'static str,
    pub display_prefix: &'static str,
    pub app: &'static str,
    pub credential_field: &'static str,
    pub direct_credential_field: Option<&'static str>,
    pub missing_credential_source: Option<&'static str>,
    pub unwraps_oauth_payload: bool,
}

/// 返回目录表全部条目 (顺序即定义顺序)。
pub fn catalog_entries() -> Vec<CatalogEntry> {
    CATALOG_SPECS
        .iter()
        .map(|spec| CatalogEntry {
            provider: spec.provider,
            prefix: spec.prefix,
            display_prefix: spec.display_prefix,
            app: spec.app,
            credential_field: spec.credential_field,
            direct_credential_field: spec.direct_credential_field,
            missing_credential_source: spec.missing_credential_source,
            unwraps_oauth_payload: spec.unwraps_oauth_payload,
        })
        .collect()
}

/// 按 app ID 查询目录表条目 (C048)。
pub fn catalog_entry_for_app(app: &str) -> Option<CatalogEntry> {
    catalog_entries().into_iter().find(|entry| entry.app == app)
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AccountDescriptor {
    pub account_id: String,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct CatalogInput {
    /// Keys use stable app/provider IDs: `opencode-go`, `kimi`, `deepseek`,
    /// `zhipu`, `volcengine`, `claude`, `grok`, `stepfun`, `jev`, or `cline`.
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

/// Resolve injected account descriptors into stable service
/// order. Account IDs are sorted within each provider and duplicate IDs are
/// rejected instead of producing duplicate service rows.
pub fn resolve_service_catalog(
    input: &CatalogInput,
) -> Result<Vec<ServiceDescriptor>, CatalogError> {
    let mut services = Vec::new();
    for spec in CATALOG_SPECS {
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
            && spec.direct_credential_field.is_some()
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

/// Standardized provider execution outcome (C048): encapsulates the finalized
/// service JSON alongside any credential updates or challenges produced by the
/// provider, eliminating provider-name branching in `collector-application`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderOutcome {
    pub service: Value,
    pub credential_updates: Vec<Value>,
    pub credential_challenges: Vec<Value>,
}

pub trait QuotaProvider: Send + Sync {
    fn app(&self) -> &str;

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError>;

    /// Finalize raw provider query output into a standardized `ProviderOutcome` (C048).
    /// Providers with custom freshness, failure taxonomy, or challenge semantics
    /// (such as `CodexProvider`) override this method so `collector-application`
    /// never branches on `app` name.
    fn finalize_outcome(
        &self,
        service: Value,
        account_id: Option<&str>,
        result: Result<Option<Value>, ProviderError>,
    ) -> ProviderOutcome {
        finalize_provider_outcome(self.app(), service, account_id, result)
    }
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
            format!("Provider 请求触发限流 (HTTP {})", response.status),
            true,
        ));
    }
    if (500..=599).contains(&response.status) {
        return Err(ProviderError::new(
            "PROVIDER_SERVER_ERROR",
            "response",
            format!("Provider 服务暂时不可用 (HTTP {})", response.status),
            true,
        ));
    }
    if !(200..=299).contains(&response.status) {
        return Err(ProviderError::new(
            "PROVIDER_HTTP_STATUS",
            "response",
            format!("Provider 返回非成功 HTTP 状态 (HTTP {})", response.status),
            response.status >= 500,
        ));
    }
    Ok(response.body)
}

/// 服务所属订阅 Provider 的稳定标识 (C118), 与两端 `SubscriptionProviderID` rawValue 同值:
/// 应用侧据此归属服务, 不再从 service id 前缀或 app 名推断。
pub fn subscription_provider_id(app: &str) -> &str {
    match app {
        "opencode-go" => "opencodeGo",
        other => other,
    }
}

/// 失败分类 (C118, 原仅 Codex 输出): 应用侧据此判定限流冷却等, 不再匹配 note 文案。
pub fn failure_kind_for_code(code: &str) -> &'static str {
    match code {
        "PROVIDER_AUTH_REJECTED" => "auth",
        "PROVIDER_PERMISSION_DENIED" => "permission",
        "PROVIDER_RATE_LIMIT" => "rateLimit",
        "PROVIDER_SERVER_ERROR" => "server",
        "PROVIDER_INVALID_JSON" | "PROVIDER_INVALID_PAYLOAD" | "PROVIDER_RESPONSE_TOO_LARGE" => {
            "invalidResponse"
        }
        code if code.starts_with("CREDENTIAL_") => "credential",
        _ => "network",
    }
}

pub fn service_template(service: &ServiceDescriptor, captured_at: &str) -> Value {
    json!({
        "id": service.id,
        "name": service.name,
        "app": service.app,
        "provider": subscription_provider_id(&service.app),
        "failureKind": null,
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
                "failureKind".to_owned(),
                Value::String("invalidResponse".to_owned()),
            );
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
            object.insert(
                "failureKind".to_owned(),
                Value::String(failure_kind_for_code(&error.diagnostic.code).to_owned()),
            );
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

/// Default provider outcome finalization (C048): extracts optional `credential_update`
/// from the provider result and delegates service status/note population to `finalize_service`.
pub fn finalize_provider_outcome(
    app: &str,
    service: Value,
    account_id: Option<&str>,
    result: Result<Option<Value>, ProviderError>,
) -> ProviderOutcome {
    let mut credential_updates = Vec::new();
    let mut clean_result = result;
    if let Ok(Some(Value::Object(map))) = &mut clean_result {
        if let Some(update_val) = map.remove("credential_update") {
            if let Some(account_id) = account_id.filter(|s| !s.is_empty()) {
                credential_updates.push(json!({
                    "provider": app,
                    "accountId": account_id,
                    "kind": "oauthTokens",
                    "operation": "replace",
                    "credentials": update_val,
                }));
            }
        }
    }
    let service = finalize_service(service, clean_result);
    ProviderOutcome {
        service,
        credential_updates,
        credential_challenges: Vec::new(),
    }
}

/// Codex-specific outcome finalization (C048): populates `freshness`, `failureKind`,
/// failure `note`, and emits `accessRejected` credential challenges when an account's
/// access token is rejected.
pub fn finalize_codex_outcome(
    service: Value,
    account_id: Option<&str>,
    result: Result<Option<Value>, ProviderError>,
) -> ProviderOutcome {
    let credential_challenges = if account_id.is_some()
        && result
            .as_ref()
            .err()
            .is_some_and(|error| error.diagnostic.code == "PROVIDER_AUTH_REJECTED")
    {
        vec![json!({
            "provider": "codex",
            "accountId": account_id.unwrap_or_default(),
            "reason": "accessRejected",
        })]
    } else {
        Vec::new()
    };
    let mut outcome = finalize_provider_outcome("codex", service, account_id, result.clone());
    if let Some(object) = outcome.service.as_object_mut() {
        match &result {
            Ok(_) => {
                object.insert("freshness".to_owned(), Value::String("fresh".to_owned()));
                object.insert("failureKind".to_owned(), Value::Null);
            }
            Err(error) => {
                object.remove("capturedAt");
                object.insert(
                    "freshness".to_owned(),
                    Value::String("unavailable".to_owned()),
                );
                object.insert(
                    "failureKind".to_owned(),
                    Value::String(failure_kind_for_code(&error.diagnostic.code).to_owned()),
                );
                object.insert(
                    "note".to_owned(),
                    Value::String(codex_failure_note(error).to_owned()),
                );
            }
        }
    }
    outcome.credential_challenges = credential_challenges;
    outcome
}

fn codex_failure_note(error: &ProviderError) -> &'static str {
    match error.diagnostic.code.as_str() {
        "PROVIDER_AUTH_REJECTED" => "登录态已失效, 请重新登录该账号",
        "PROVIDER_PERMISSION_DENIED" => "当前账号无权访问该额度接口",
        _ => "额度查询暂时失败, 请稍后重试",
    }
}

pub const CLINE_API_BASE: &str = "https://api.cline.bot/api/v1";

pub const KIMI_USAGE_URL: &str = "https://api.kimi.com/coding/v1/usages";
pub const DEEPSEEK_BALANCE_URL: &str = "https://api.deepseek.com/user/balance";
pub const ZHIPU_QUOTA_PATH: &str = "/api/monitor/usage/quota/limit";
pub const CODEX_USAGE_URL: &str = "https://chatgpt.com/backend-api/wham/usage";
pub const CLAUDE_USAGE_URL: &str = "https://api.anthropic.com/api/oauth/usage";
pub const CLAUDE_BETA_HEADER: &str = "oauth-2025-04-20";
pub const CLAUDE_OAUTH_TOKEN_URL: &str = "https://api.anthropic.com/v1/oauth/token";
pub const CLAUDE_CLIENT_ID: &str = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
pub const CLAUDE_USER_AGENT: &str = "claude-code/2.1.302";
pub const GROK_BILLING_URL: &str =
    "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
pub const OPENCODE_SERVER_URL: &str = "https://opencode.ai/_server";
pub const OPENCODE_SERVER_ID: &str =
    "c7389bd0e731f80f49593e5ee53835475f4e28594dd6bd83eb229bab753498cd";
pub const STEPFUN_STEP_PLAN_RATE_LIMIT_URL: &str =
    "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit";
pub const STEPFUN_REFRESH_TOKEN_URL: &str =
    "https://platform.stepfun.com/passport/proto.api.passport.v1.PassportService/RefreshToken";
pub const STEPFUN_GLOBAL_STEP_PLAN_RATE_LIMIT_URL: &str =
    "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit";
pub const STEPFUN_GLOBAL_REFRESH_TOKEN_URL: &str =
    "https://platform.stepfun.ai/passport/proto.api.passport.v1.PassportService/RefreshToken";
pub const JEV_MODELS_URL: &str = "https://api.typesafe.ai/v1/models";

pub(crate) fn invalid_payload() -> ProviderError {
    ProviderError::new(
        "PROVIDER_INVALID_PAYLOAD",
        "parse",
        "Provider 响应格式无效",
        false,
    )
}

pub(crate) fn invalid_credential() -> ProviderError {
    ProviderError::new(
        "PROVIDER_INVALID_CREDENTIAL",
        "credential",
        "Provider 凭证格式无效",
        false,
    )
}

pub(crate) fn credential_string<'a>(credential: &'a Value, keys: &[&str]) -> Option<&'a str> {
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

pub(crate) fn number(value: Option<&Value>) -> Option<f64> {
    let parsed = match value? {
        Value::Number(value) => value.as_f64(),
        Value::String(value) => value.trim().parse::<f64>().ok(),
        _ => None,
    }?;
    parsed.is_finite().then_some(parsed)
}

pub(crate) fn number_with_default(
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

pub(crate) fn clamp_percent(value: f64) -> f64 {
    value.clamp(0.0, 100.0)
}

pub(crate) fn reset_epoch(value: Option<&Value>) -> Option<i64> {
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

pub(crate) fn captured_epoch(captured_at: &str) -> i64 {
    DateTime::parse_from_rfc3339(captured_at)
        .map(|value| value.timestamp())
        .or_else(|_| {
            NaiveDateTime::parse_from_str(captured_at, "%Y-%m-%dT%H:%M:%S%.f")
                .map(|value| value.and_utc().timestamp())
        })
        .unwrap_or_else(|_| Utc::now().timestamp())
}

pub(crate) fn parse_window_percentage(
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
pub(crate) fn send_json(
    request: &ProviderRequest,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
    method: &str,
    url: String,
    headers: BTreeMap<String, String>,
    body: Option<Vec<u8>>,
    auth_error: Option<&str>,
) -> Result<Value, ProviderError> {
    let response = send_response(
        request,
        http,
        cancellation,
        method,
        url,
        headers,
        body,
        auth_error,
    )?;
    let status = response.status;
    let response_body = bounded_http_body(response, request.max_response_body_bytes)?;
    serde_json::from_slice(&response_body).map_err(|_| {
        ProviderError::new(
            "PROVIDER_INVALID_JSON",
            "parse",
            format!("Provider 响应不是有效 JSON (HTTP {status})"),
            false,
        )
    })
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn send_body(
    request: &ProviderRequest,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
    method: &str,
    url: String,
    headers: BTreeMap<String, String>,
    body: Option<Vec<u8>>,
    auth_error: Option<&str>,
) -> Result<Vec<u8>, ProviderError> {
    let response = send_response(
        request,
        http,
        cancellation,
        method,
        url,
        headers,
        body,
        auth_error,
    )?;
    bounded_http_body(response, request.max_response_body_bytes)
}

#[allow(clippy::too_many_arguments)]
fn send_response(
    request: &ProviderRequest,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
    method: &str,
    url: String,
    headers: BTreeMap<String, String>,
    body: Option<Vec<u8>>,
    auth_error: Option<&str>,
) -> Result<HttpResponse, ProviderError> {
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
                format!("{message} (HTTP {})", response.status),
                false,
            ));
        }
    }
    if response.status == 403 {
        if let Some(message) = auth_error {
            return Err(ProviderError::new(
                "PROVIDER_PERMISSION_DENIED",
                "response",
                format!("{message} (HTTP {})", response.status),
                false,
            ));
        }
    }
    Ok(response)
}

pub(crate) fn service_result(kind: &str, plan: Option<Value>, windows: Vec<Value>) -> Value {
    json!({
        "kind": kind,
        "plan": plan,
        "windows": windows,
    })
}

pub(crate) fn window(
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

pub(crate) fn optional_credential_string<'a>(
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

pub(crate) fn json_credential(credential: &Value) -> Result<Value, ProviderError> {
    match credential {
        Value::String(value) => serde_json::from_str(value).map_err(|_| invalid_credential()),
        Value::Object(_) => Ok(credential.clone()),
        _ => Err(invalid_credential()),
    }
}

pub(crate) fn provider_headers(entries: &[(&str, String)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_owned(), value.clone()))
        .collect()
}

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
        "stepfun" => Some(Box::new(StepFunProvider)),
        "jev" => Some(Box::new(JevProvider)),
        "cline" => Some(Box::new(ClineProvider)),
        _ => None,
    }
}
