#![deny(unsafe_code)]

//! Bridge v1 validation and stdout envelope boundary.

mod metrics;

use chrono::{SecondsFormat, Utc};
use collector_application::{
    collect_agent_usage, validate_credential_outputs, CollectionMetrics, CollectionOutput,
    CollectionScanStats,
};
use collector_domain::{
    response_status, BridgeRequest, BridgeResponse, Diagnostic, BRIDGE_SCHEMA_VERSION,
};
use std::collections::BTreeSet;
use std::io::{self, Read};
use std::time::Instant;
use uuid::Uuid;

const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_LOCAL_SCAN_SECONDS: f64 = 300.0;
const MAX_EXTERNAL_REQUEST_SECONDS: f64 = 300.0;
const MAX_MODULE_SECONDS: f64 = 600.0;
const CODEX_QUOTA_ACCOUNT_MAX: usize = 64;
const CODEX_QUOTA_ACCOUNT_ID_MAX: usize = 256;
const CODEX_QUOTA_DISPLAY_NAME_MAX: usize = 256;
const CODEX_QUOTA_ACCESS_TOKEN_MAX: usize = 8192;

const ALLOWED_CONTEXT_FIELDS: &[&str] = &[
    "home",
    "now",
    "timezone",
    "days",
    "paths",
    "capabilities",
    "codexQuotaRetryOnly",
    "codexQuotaAccountOrder",
    "subscriptionQuotaOnly",
    "subscriptionProviders",
];

const ALLOWED_CAPABILITIES: &[&str] = &["localSessions", "localPricing", "externalQuotas"];

const ALLOWED_CREDENTIAL_FIELDS: &[&str] = &[
    "kimiWebTokens",
    "kimiQuotaAccounts",
    "deepseekQuotaAccounts",
    "volcengineQuotaAccounts",
    "zhipuQuotaAccounts",
    "antigravityOAuth",
    "antigravityQuotaAccounts",
    "claudeOAuth",
    "claudeQuotaAccounts",
    "grokOAuth",
    "grokQuotaAccounts",
    "opencodeGoQuotaAccounts",
    "codexQuotaAccounts",
    "orcaCodexAuth",
    "providerEnv",
    "providerMeta",
];

pub fn run_bytes(input: &[u8]) -> BridgeResponse {
    let started = Instant::now();
    let physical_disk_read_start = metrics::physical_disk_read_bytes();
    let (response, stats, metrics) = if input.len() > MAX_REQUEST_BYTES {
        (
            error_response(
                new_run_id(),
                "BRIDGE_INPUT_TOO_LARGE",
                "protocol",
                "request",
                "Bridge request exceeds the input limit",
                false,
            ),
            CollectionScanStats::default(),
            CollectionMetrics::default(),
        )
    } else {
        let request: BridgeRequest = match serde_json::from_slice(input) {
            Ok(value) => value,
            Err(_) => {
                let response = error_response(
                    new_run_id(),
                    "BRIDGE_INVALID_JSON",
                    "protocol",
                    "request",
                    "输入不是有效的 JSON 文档",
                    false,
                );
                return finish_metrics(
                    started,
                    response,
                    CollectionScanStats::default(),
                    CollectionMetrics::default(),
                    physical_disk_read_start,
                );
            }
        };
        match validate_request(&request) {
            Ok(()) => match collect_agent_usage(&request) {
                Ok(CollectionOutput {
                    artifact,
                    diagnostics,
                    generated_at,
                    scan_stats,
                    metrics,
                    credential_updates,
                    credential_challenges,
                }) => {
                    let response = BridgeResponse {
                        schema_version: BRIDGE_SCHEMA_VERSION,
                        run_id: request.run_id.clone(),
                        generated_at,
                        status: response_status(true, diagnostics.len()),
                        artifact: Some(artifact),
                        credential_updates,
                        credential_challenges,
                        diagnostics,
                    };
                    match validate_response_credentials(response) {
                        Ok(response) => (response, scan_stats, metrics),
                        Err(diagnostic) => (
                            BridgeResponse::error(
                                request.run_id,
                                crate::generated_at(),
                                diagnostic,
                            ),
                            CollectionScanStats::default(),
                            CollectionMetrics::default(),
                        ),
                    }
                }
                Err(diagnostic) => (
                    BridgeResponse::error(request.run_id, generated_at(), diagnostic),
                    CollectionScanStats::default(),
                    CollectionMetrics::default(),
                ),
            },
            Err(diagnostic) => (
                BridgeResponse::error(request.run_id, generated_at(), diagnostic),
                CollectionScanStats::default(),
                CollectionMetrics::default(),
            ),
        }
    };
    finish_metrics(started, response, stats, metrics, physical_disk_read_start)
}

fn finish_metrics(
    started: Instant,
    response: BridgeResponse,
    stats: CollectionScanStats,
    metrics: CollectionMetrics,
    physical_disk_read_start: Option<u64>,
) -> BridgeResponse {
    metrics::write_if_enabled(
        started,
        &response,
        &stats,
        &metrics,
        physical_disk_read_start,
    );
    response
}

pub fn physical_disk_read_bytes() -> Option<u64> {
    metrics::physical_disk_read_bytes()
}

fn validate_response_credentials(
    mut response: BridgeResponse,
) -> Result<BridgeResponse, Diagnostic> {
    let (updates, challenges) = validate_credential_outputs(
        &response.credential_updates,
        &response.credential_challenges,
    )?;
    response.credential_updates = updates;
    response.credential_challenges = challenges;
    Ok(response)
}

pub fn read_request<R: Read>(mut reader: R) -> io::Result<Vec<u8>> {
    let mut input = Vec::new();
    let mut limited = reader.by_ref().take((MAX_REQUEST_BYTES + 1) as u64);
    limited.read_to_end(&mut input)?;
    Ok(input)
}

pub fn max_request_bytes() -> usize {
    MAX_REQUEST_BYTES
}

fn validate_request(request: &BridgeRequest) -> Result<(), Diagnostic> {
    if request.schema_version != BRIDGE_SCHEMA_VERSION {
        return Err(protocol_error(
            "BRIDGE_UNSUPPORTED_SCHEMA",
            "不支持的 Bridge schema 版本",
        ));
    }
    if request.module != "agent-usage" {
        return Err(protocol_error("BRIDGE_UNKNOWN_MODULE", "不支持的采集模块"));
    }
    if Uuid::parse_str(&request.run_id).is_err() {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "runId 必须是有效 UUID",
        ));
    }
    validate_timeout(request.timeouts.local_scan_seconds, MAX_LOCAL_SCAN_SECONDS)?;
    validate_timeout(
        request.timeouts.external_request_seconds,
        MAX_EXTERNAL_REQUEST_SECONDS,
    )?;
    validate_timeout(request.timeouts.module_seconds, MAX_MODULE_SECONDS)?;
    for key in request.context.keys() {
        if !ALLOWED_CONTEXT_FIELDS.contains(&key.as_str()) {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "context 包含不支持的字段",
            ));
        }
    }
    if let Some(days) = request.context.get("days") {
        let valid = days.as_u64().map(|value| (1..=366).contains(&value));
        if valid != Some(true) {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "days 必须在 1 到 366 之间",
            ));
        }
    }
    if let Some(capabilities) = request.context.get("capabilities") {
        let Some(values) = capabilities.as_array() else {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "capabilities 必须是字符串数组",
            ));
        };
        if values.iter().any(|value| {
            value
                .as_str()
                .map(|item| !ALLOWED_CAPABILITIES.contains(&item))
                .unwrap_or(true)
        }) {
            return Err(protocol_error(
                "BRIDGE_UNKNOWN_CAPABILITY",
                "请求包含未知能力",
            ));
        }
    }
    validate_codex_request(request)?;
    for key in request.credentials.keys() {
        if !ALLOWED_CREDENTIAL_FIELDS.contains(&key.as_str()) {
            return Err(Diagnostic::new(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "request",
                "credentials 包含不允许的字段",
                false,
            ));
        }
    }
    Ok(())
}

fn validate_codex_request(request: &BridgeRequest) -> Result<(), Diagnostic> {
    let accounts = request.credentials.get("codexQuotaAccounts");
    let order = request.context.get("codexQuotaAccountOrder");
    if let Some(retry_only) = request.context.get("codexQuotaRetryOnly") {
        if !retry_only.is_boolean() {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaRetryOnly 必须是布尔值",
            ));
        }
    }
    let Some(accounts) = accounts else {
        if order.is_some() {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccountOrder 必须携带 codexQuotaAccounts",
            ));
        }
        return Ok(());
    };
    let Some(accounts) = accounts.as_object() else {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 必须是 JSON object",
        ));
    };
    if accounts.is_empty() || accounts.len() > CODEX_QUOTA_ACCOUNT_MAX {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 数量无效",
        ));
    }
    for (account_id, payload) in accounts {
        if account_id.is_empty()
            || account_id.len() > CODEX_QUOTA_ACCOUNT_ID_MAX
            || account_id.chars().any(char::is_control)
        {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts 账号 id 无效",
            ));
        }
        let Some(payload) = payload.as_object() else {
            return Err(Diagnostic::new(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "request",
                "codexQuotaAccounts 账号条目无效",
                false,
            ));
        };
        let allowed = BTreeSet::from(["access_token", "display_name"]);
        if payload.keys().any(|key| !allowed.contains(key.as_str())) {
            return Err(Diagnostic::new(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "request",
                "codexQuotaAccounts 账号条目包含不允许的字段",
                false,
            ));
        }
        let access_token = payload
            .get("access_token")
            .and_then(|value| value.as_str())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                protocol_error(
                    "BRIDGE_INVALID_REQUEST",
                    "codexQuotaAccounts 缺少 access_token",
                )
            })?;
        if access_token.len() > CODEX_QUOTA_ACCESS_TOKEN_MAX {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts access_token 超过长度上限",
            ));
        }
        let display_name = payload
            .get("display_name")
            .and_then(|value| value.as_str())
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                protocol_error(
                    "BRIDGE_INVALID_REQUEST",
                    "codexQuotaAccounts 缺少 display_name",
                )
            })?;
        if display_name.len() > CODEX_QUOTA_DISPLAY_NAME_MAX {
            return Err(protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts display_name 超过长度上限",
            ));
        }
    }
    let Some(order) = order.and_then(|value| value.as_array()) else {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 必须携带 codexQuotaAccountOrder",
        ));
    };
    if order.is_empty() || order.len() > CODEX_QUOTA_ACCOUNT_MAX {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccountOrder 数量无效",
        ));
    }
    let order = order
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| {
            protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccountOrder 必须是字符串数组",
            )
        })?;
    let order_set = order.iter().collect::<BTreeSet<_>>();
    let account_set = accounts.keys().collect::<BTreeSet<_>>();
    if order_set.len() != order.len() || order_set != account_set {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccountOrder 与 codexQuotaAccounts 不一致",
        ));
    }
    Ok(())
}

fn validate_timeout(value: f64, maximum: f64) -> Result<(), Diagnostic> {
    if !value.is_finite() || value <= 0.0 || value > maximum {
        return Err(protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "超时值必须为正数且不超过协议上限",
        ));
    }
    Ok(())
}

fn protocol_error(code: &str, message: &str) -> Diagnostic {
    Diagnostic::new(code, "protocol", "request", message, false)
}

fn error_response(
    run_id: String,
    code: &str,
    category: &str,
    stage: &str,
    message: &str,
    retryable: bool,
) -> BridgeResponse {
    BridgeResponse::error(
        run_id,
        generated_at(),
        Diagnostic::new(code, category, stage, message, retryable),
    )
}

fn generated_at() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true)
}

fn new_run_id() -> String {
    Uuid::new_v4().to_string()
}

#[cfg(test)]
mod tests {
    use super::{
        generated_at, max_request_bytes, read_request, run_bytes, validate_response_credentials,
    };
    use collector_domain::{BridgeResponse, ResponseStatus, BRIDGE_SCHEMA_VERSION};
    use serde_json::{json, Value};
    use std::io::Cursor;

    fn request() -> String {
        r#"{"schemaVersion":1,"runId":"12345678-1234-4234-9234-123456789abc","module":"agent-usage","timeouts":{"localScanSeconds":30,"externalRequestSeconds":10,"moduleSeconds":90},"context":{"home":"/tmp","capabilities":["localSessions"]},"credentials":{}}"#.to_owned()
    }

    #[test]
    fn valid_request_returns_one_structured_artifact_response() {
        let response = run_bytes(request().as_bytes());
        assert_eq!(response.run_id, "12345678-1234-4234-9234-123456789abc");
        assert_eq!(response.status, ResponseStatus::Partial);
        assert!(response.artifact.is_some());
    }

    #[test]
    fn malformed_json_fails_closed() {
        let response = run_bytes(b"not-json");
        assert_eq!(response.diagnostics[0].code, "BRIDGE_INVALID_JSON");
        assert!(response.artifact.is_none());
    }

    #[test]
    fn unknown_context_and_credential_fields_are_rejected() {
        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["context"]["unexpected"] = Value::Bool(true);
        let response = run_bytes(serde_json::to_vec(&value).unwrap().as_slice());
        assert_eq!(response.diagnostics[0].code, "BRIDGE_INVALID_REQUEST");

        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["context"] = serde_json::json!({"capabilities": ["localSessions"]});
        value["credentials"]["access_token"] = Value::String("fixture".to_owned());
        let response = run_bytes(serde_json::to_vec(&value).unwrap().as_slice());
        assert_eq!(response.diagnostics[0].code, "BRIDGE_CREDENTIAL_SCOPE");
    }

    #[test]
    fn codex_accounts_require_matching_order_before_collection() {
        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["context"]["codexQuotaAccountOrder"] = json!(["other"]);
        value["credentials"]["codexQuotaAccounts"] = json!({
            "acc-1": {
                "display_name": "Codex · fixture",
                "access_token": "fixture-token"
            }
        });
        let response = run_bytes(serde_json::to_string(&value).unwrap().as_bytes());
        assert_eq!(response.status, ResponseStatus::Error);
        assert_eq!(response.diagnostics[0].code, "BRIDGE_INVALID_REQUEST");
    }

    #[test]
    fn invalid_run_id_is_rejected_without_collecting() {
        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["runId"] = Value::String("not-a-uuid".to_owned());
        let response = run_bytes(serde_json::to_vec(&value).unwrap().as_slice());
        assert_eq!(response.diagnostics[0].code, "BRIDGE_INVALID_REQUEST");
        assert!(response.artifact.is_none());
    }

    #[test]
    fn oversized_input_is_rejected_before_json_parsing() {
        let input = vec![b' '; max_request_bytes() + 1];
        let response = run_bytes(&input);
        assert_eq!(response.diagnostics[0].code, "BRIDGE_INPUT_TOO_LARGE");
    }

    #[test]
    fn reader_is_bounded() {
        let input = vec![b'x'; max_request_bytes() + 1];
        let output = read_request(Cursor::new(input)).unwrap();
        assert_eq!(output.len(), max_request_bytes() + 1);
    }

    #[test]
    fn response_serialization_has_no_embedded_log_lines() {
        let response = run_bytes(request().as_bytes());
        let encoded = serde_json::to_string(&response).unwrap();
        assert!(!encoded.contains('\n'));
        assert!(!encoded.contains("access_token"));
    }

    #[test]
    fn response_credentials_are_validated_and_errors_are_redacted() {
        let response = BridgeResponse {
            schema_version: BRIDGE_SCHEMA_VERSION,
            run_id: "12345678-1234-4234-9234-123456789abc".to_owned(),
            generated_at: generated_at(),
            status: ResponseStatus::Success,
            artifact: Some(json!({"ok": true})),
            credential_updates: vec![json!({
                "provider": "kimi",
                "accountId": "account-a",
                "kind": "oauthTokens",
                "operation": "replace",
                "credentials": {"access_token": "redacted"}
            })],
            credential_challenges: vec![json!({
                "provider": "codex",
                "accountId": "account-a",
                "reason": "accessRejected"
            })],
            diagnostics: Vec::new(),
        };
        let validated = validate_response_credentials(response).unwrap();
        assert_eq!(validated.credential_updates.len(), 1);
        assert_eq!(validated.credential_challenges.len(), 1);

        let invalid = BridgeResponse {
            credential_updates: vec![json!({
                "provider": "kimi",
                "accountId": "account-a",
                "kind": "oauthTokens",
                "operation": "replace",
                "credentials": {"secret": "raw-secret"}
            })],
            ..validated
        };
        let error = validate_response_credentials(invalid).unwrap_err();
        assert_eq!(error.code, "BRIDGE_INVALID_CREDENTIAL_UPDATE");
        assert!(!serde_json::to_string(&error)
            .unwrap()
            .contains("raw-secret"));
    }
}
