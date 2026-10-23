//! Read-only QuotaProvider implementations for all supported providers (C053).

use crate::protobuf::parse_grok_usage;
use crate::quota_parsers::{
    cline_pass_entitled, parse_claude_usage, parse_cline_usage_limits, parse_codex_usage,
    parse_deepseek_balance, parse_jev_models, parse_kimi_usage, parse_volcengine_usage,
    parse_zhipu_usage,
};
use crate::seroval::parse_opencode_go_body;
use crate::signing::{
    is_stepfun_token_expired, query_stepfun_rate_limit, refresh_stepfun_token,
    volc_credential_field, volc_headers, volc_secret_candidates,
};
use crate::{
    captured_epoch, credential_string, finalize_codex_outcome, invalid_credential, json_credential,
    optional_credential_string, provider_headers, send_body, send_json, HttpClient, ProviderError,
    ProviderOutcome, ProviderRequest, QuotaProvider, CLAUDE_BETA_HEADER, CLAUDE_CLIENT_ID,
    CLAUDE_OAUTH_TOKEN_URL, CLAUDE_USAGE_URL, CLAUDE_USER_AGENT, CLINE_API_BASE, CODEX_USAGE_URL,
    DEEPSEEK_BALANCE_URL, GROK_BILLING_URL, JEV_MODELS_URL, KIMI_USAGE_URL, OPENCODE_SERVER_ID,
    OPENCODE_SERVER_URL, ZHIPU_QUOTA_PATH,
};
use collector_runtime::CancellationToken;
use serde_json::{json, Value};

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
            Some("Z.ai 凭证被拒绝, 请检查 API key"),
        )?;
        parse_zhipu_usage(&payload)
    }
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

pub(crate) fn claude_token(credential: &Value) -> Result<Option<String>, ProviderError> {
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

#[derive(Debug, Clone)]
struct ClaudeOAuthCredentials {
    access_token: String,
    refresh_token: Option<String>,
    expires_at_epoch_ms: Option<i64>,
    scopes: Vec<String>,
}

fn parse_claude_oauth_credentials(
    credential: &Value,
) -> Result<Option<ClaudeOAuthCredentials>, ProviderError> {
    let root = json_credential(credential)?;
    let object = root.as_object().ok_or_else(invalid_credential)?;
    let entry = object
        .get("claudeAiOauth")
        .or_else(|| object.get("claude.ai_oauth"))
        .and_then(Value::as_object);
    let Some(entry) = entry else {
        return Ok(None);
    };
    let Some(access_token) = entry
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return Ok(None);
    };
    let refresh_token = entry
        .get("refreshToken")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned);
    let expires_at_epoch_ms = entry.get("expiresAt").and_then(|val| {
        if let Some(num) = val.as_i64() {
            Some(num)
        } else if let Some(num) = val.as_f64() {
            Some(num as i64)
        } else if let Some(s) = val.as_str() {
            s.parse::<i64>().ok()
        } else {
            None
        }
    });
    let scopes = entry
        .get("scopes")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    Ok(Some(ClaudeOAuthCredentials {
        access_token: access_token.to_owned(),
        refresh_token,
        expires_at_epoch_ms,
        scopes,
    }))
}

pub(crate) fn is_claude_token_expired(
    expires_at_epoch_ms: Option<i64>,
    now_epoch_secs: i64,
) -> bool {
    let Some(exp) = expires_at_epoch_ms else {
        return false;
    };
    let exp_secs = if exp > 100_000_000_000 {
        exp / 1000
    } else {
        exp
    };
    // 距过期不足 60 秒视为过期
    now_epoch_secs >= exp_secs - 60
}

#[derive(Debug, Clone)]
pub(crate) struct RefreshedClaudeToken {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in_secs: i64,
}

pub(crate) fn refresh_claude_token(
    request: &ProviderRequest,
    refresh_token: &str,
    scopes: &[String],
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
) -> Result<RefreshedClaudeToken, ProviderError> {
    let scope_str = if scopes.is_empty() {
        "user:file_upload user:inference user:mcp_servers user:plugins user:profile user:sessions:claude_code".to_owned()
    } else {
        scopes.join(" ")
    };

    let payload = json!({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": CLAUDE_CLIENT_ID,
        "scope": scope_str,
    });

    let payload_bytes = serde_json::to_vec(&payload).map_err(|e| {
        ProviderError::new(
            "PROVIDER_REQUEST_FAILED",
            "request",
            format!("序列化 Claude 刷新请求失败: {e}"),
            false,
        )
    })?;

    let response = send_json(
        request,
        http,
        cancellation,
        "POST",
        CLAUDE_OAUTH_TOKEN_URL.to_owned(),
        provider_headers(&[
            ("Content-Type", "application/json".to_owned()),
            ("User-Agent", CLAUDE_USER_AGENT.to_owned()),
            ("Accept", "application/json".to_owned()),
        ]),
        Some(payload_bytes),
        Some("Claude 凭证刷新失败, 请重新登录 Claude CLI"),
    )?;

    let object = response.as_object().ok_or_else(|| {
        ProviderError::new(
            "PROVIDER_REMOTE_REJECTED",
            "refresh",
            "Claude 刷新响应格式无效",
            false,
        )
    })?;

    let access_token = object
        .get("access_token")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            ProviderError::new(
                "PROVIDER_REMOTE_REJECTED",
                "refresh",
                "Claude 刷新响应缺少有效 access_token",
                false,
            )
        })?;

    let new_refresh_token = object
        .get("refresh_token")
        .and_then(Value::as_str)
        .unwrap_or(refresh_token);

    let expires_in_secs = object
        .get("expires_in")
        .and_then(Value::as_i64)
        .unwrap_or(28800);

    Ok(RefreshedClaudeToken {
        access_token: access_token.to_owned(),
        refresh_token: new_refresh_token.to_owned(),
        expires_in_secs,
    })
}

fn query_claude_usage(
    request: &ProviderRequest,
    token: &str,
    http: &dyn HttpClient,
    cancellation: &CancellationToken,
) -> Result<Option<Value>, ProviderError> {
    let payload = send_json(
        request,
        http,
        cancellation,
        "GET",
        CLAUDE_USAGE_URL.to_owned(),
        provider_headers(&[
            ("Authorization", format!("Bearer {token}")),
            ("anthropic-beta", CLAUDE_BETA_HEADER.to_owned()),
            ("User-Agent", CLAUDE_USER_AGENT.to_owned()),
            ("Accept", "application/json".to_owned()),
        ]),
        None,
        Some("Claude 凭证被拒绝, 请重新登录 Claude CLI"),
    )?;
    parse_claude_usage(&payload)
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
        let mut creds = match parse_claude_oauth_credentials(credential)? {
            Some(parsed) => parsed,
            None => {
                let Some(token) = claude_token(credential)? else {
                    return Ok(None);
                };
                ClaudeOAuthCredentials {
                    access_token: token,
                    refresh_token: None,
                    expires_at_epoch_ms: None,
                    scopes: Vec::new(),
                }
            }
        };

        let now_epoch_secs = captured_epoch(&request.captured_at);
        let mut active_token = creds.access_token.clone();
        let mut active_refresh_token = creds.refresh_token.clone();
        let mut active_expiry_secs =
            creds
                .expires_at_epoch_ms
                .map(|ms| if ms > 100_000_000_000 { ms / 1000 } else { ms });
        let mut refreshed = false;

        // 1. 若 access_token 已过期（或即将过期 <= 60s）且有 refresh_token，主动发起 OAuth 刷新
        if let Some(ref rt) = creds.refresh_token {
            if is_claude_token_expired(creds.expires_at_epoch_ms, now_epoch_secs) {
                if let Ok(new_tokens) =
                    refresh_claude_token(request, rt, &creds.scopes, http, cancellation)
                {
                    active_token = new_tokens.access_token;
                    active_refresh_token = Some(new_tokens.refresh_token.clone());
                    active_expiry_secs = Some(now_epoch_secs + new_tokens.expires_in_secs);
                    creds.refresh_token = Some(new_tokens.refresh_token);
                    refreshed = true;
                }
            }
        }

        // 2. 执行配额查询
        let mut query_result = query_claude_usage(request, &active_token, http, cancellation);

        // 3. 若尚未成功刷新且返回 401 鉴权拒绝，且存在 refresh_token，尝试刷新并重试一次
        if !refreshed {
            if let Some(ref rt) = creds.refresh_token {
                let is_auth_failure = match &query_result {
                    Err(err) => err.diagnostic.code == "PROVIDER_AUTH_REJECTED",
                    _ => false,
                };
                if is_auth_failure {
                    if let Ok(new_tokens) =
                        refresh_claude_token(request, rt, &creds.scopes, http, cancellation)
                    {
                        active_token = new_tokens.access_token;
                        active_refresh_token = Some(new_tokens.refresh_token);
                        active_expiry_secs = Some(now_epoch_secs + new_tokens.expires_in_secs);
                        refreshed = true;
                        query_result =
                            query_claude_usage(request, &active_token, http, cancellation);
                    }
                }
            }
        }

        let mut usage = query_result?;
        if refreshed {
            if let Some(obj) = usage.as_mut().and_then(Value::as_object_mut) {
                let mut update = serde_json::Map::new();
                update.insert("access_token".to_owned(), Value::String(active_token));
                if let Some(rt) = active_refresh_token {
                    update.insert("refresh_token".to_owned(), Value::String(rt));
                }
                if let Some(exp) = active_expiry_secs {
                    update.insert("expiry".to_owned(), Value::String(exp.to_string()));
                }
                obj.insert("credential_update".to_owned(), Value::Object(update));
            }
        }
        Ok(usage)
    }
}

pub(crate) fn opencode_credential(credential: &Value) -> Result<(&str, &str), ProviderError> {
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

pub(crate) fn grok_token(credential: &Value) -> Result<Option<String>, ProviderError> {
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

    fn finalize_outcome(
        &self,
        service: Value,
        account_id: Option<&str>,
        result: Result<Option<Value>, ProviderError>,
    ) -> ProviderOutcome {
        finalize_codex_outcome(service, account_id, result)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct StepFunProvider;

impl QuotaProvider for StepFunProvider {
    fn app(&self) -> &str {
        "stepfun"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(raw_token) =
            optional_credential_string(request, &["token", "oasis_token", "apiKey", "api_key"])?
        else {
            return Ok(None);
        };
        let token = raw_token.trim().trim_matches('"').trim();
        let token = token.strip_prefix("Bearer ").unwrap_or(token).trim();
        let can_refresh = token.contains("...");
        let now_epoch = captured_epoch(&request.captured_at);
        let mut active_token = token.to_owned();
        let mut refreshed = false;

        // 1. 若是两段式 Oasis-Token 且短期 access token 已过期 (或即将过期), 主动尝试刷新
        if can_refresh && is_stepfun_token_expired(&active_token, now_epoch) {
            if let Ok(new_token) = refresh_stepfun_token(request, &active_token, http, cancellation)
            {
                active_token = new_token;
                refreshed = true;
            }
        }

        // 2. 执行配额查询
        let mut query_result = query_stepfun_rate_limit(request, &active_token, http, cancellation);

        // 3. 若尚未刷新且返回鉴权失败，尝试刷新并重试一次
        if !refreshed && can_refresh {
            let is_auth_failure = match &query_result {
                Err(err) => {
                    err.diagnostic.code == "PROVIDER_AUTH_REJECTED"
                        || err.diagnostic.code == "PROVIDER_REMOTE_REJECTED"
                }
                _ => false,
            };
            if is_auth_failure {
                if let Ok(new_token) = refresh_stepfun_token(request, token, http, cancellation) {
                    active_token = new_token;
                    refreshed = true;
                    query_result =
                        query_stepfun_rate_limit(request, &active_token, http, cancellation);
                }
            }
        }

        let mut usage = query_result?;
        if refreshed {
            if let Some(obj) = usage.as_mut().and_then(Value::as_object_mut) {
                obj.insert(
                    "credential_update".to_owned(),
                    json!({
                        "access_token": active_token,
                    }),
                );
            }
        }
        Ok(usage)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct JevProvider;

impl QuotaProvider for JevProvider {
    fn app(&self) -> &str {
        "jev"
    }

    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(raw_key) = optional_credential_string(request, &["api_key", "apiKey", "token"])?
        else {
            return Ok(None);
        };
        let api_key = raw_key.trim().trim_matches('"').trim();
        let api_key = api_key.strip_prefix("Bearer ").unwrap_or(api_key).trim();
        if api_key.is_empty() {
            return Ok(None);
        }
        let base_url = request
            .credential
            .as_ref()
            .and_then(|cred| credential_string(cred, &["base_url", "baseUrl"]))
            .unwrap_or(JEV_MODELS_URL);
        let url = if base_url == JEV_MODELS_URL || base_url.ends_with("/v1/models") {
            base_url.to_owned()
        } else {
            format!("{}/v1/models", base_url.trim_end_matches('/'))
        };
        let payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            url,
            provider_headers(&[
                ("Authorization", format!("Bearer {api_key}")),
                ("Accept", "application/json".to_owned()),
            ]),
            None,
            Some("Jev 凭证被拒绝, 请检查 API key"),
        )?;
        let mut result = parse_jev_models(&payload)?;
        if let Some(res) = result.as_mut().and_then(Value::as_object_mut) {
            if let Some(cred) = request.credential.as_ref() {
                if let Some(balance) = cred.get("balance").and_then(Value::as_f64) {
                    res.insert("balance".to_owned(), json!(balance));
                    res.insert("currency".to_owned(), json!("USD"));
                }
            }
        }
        Ok(result)
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct ClineProvider;

impl QuotaProvider for ClineProvider {
    fn app(&self) -> &str {
        "cline"
    }

    /// C039: 三窗口直读网页控制台同源权威端点 `/users/me/plan/usage-limits`
    /// (百分比与重置时刻由服务端算好返回, 与网页逐字一致), 恒定 2 次 GET;
    /// 台账翻页与本地窗口建模已删除 (无本地状态, 网络故障恢复后下轮刷新即精确)。
    fn query(
        &self,
        request: &ProviderRequest,
        http: &dyn HttpClient,
        cancellation: &CancellationToken,
    ) -> Result<Option<Value>, ProviderError> {
        let Some(raw_key) = optional_credential_string(request, &["api_key", "apiKey", "token"])?
        else {
            return Ok(None);
        };
        let api_key = raw_key.trim().trim_matches('"').trim();
        let api_key = api_key.strip_prefix("Bearer ").unwrap_or(api_key).trim();
        if api_key.is_empty() {
            return Ok(None);
        }
        let auth_header = format!("Bearer {api_key}");
        let headers = || {
            provider_headers(&[
                ("Authorization", auth_header.clone()),
                ("Accept", "application/json".to_owned()),
            ])
        };
        let auth_error = "Cline 凭证被拒绝, 请检查 API key";

        let plan_payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            format!("{CLINE_API_BASE}/users/me/plan"),
            headers(),
            None,
            Some(auth_error),
        )?;
        if cline_pass_entitled(&plan_payload) != Some(true) {
            // 非 ClinePass 订阅账户 (无 entitlements 三窗口): 不查询额度, 直接空态.
            return Ok(None);
        }

        let limits_payload = send_json(
            request,
            http,
            cancellation,
            "GET",
            format!("{CLINE_API_BASE}/users/me/plan/usage-limits"),
            headers(),
            None,
            Some(auth_error),
        )?;

        parse_cline_usage_limits(&plan_payload, &limits_payload)
    }
}
