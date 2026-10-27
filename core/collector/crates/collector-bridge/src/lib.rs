#![deny(unsafe_code)]

//! Bridge v1 validation and stdout envelope boundary.

mod metrics;

use chrono::{SecondsFormat, Utc};
use collector_application::{
    collect_agent_usage, validate_credential_outputs, CollectionMetrics, CollectionOutput,
    CollectionScanStats, SourcePerformanceMetric,
};
use collector_domain::{
    response_status, BridgeRequest, BridgeResponse, Diagnostic, BRIDGE_SCHEMA_VERSION,
};
use std::io::{self, Read};
use std::time::Instant;
use uuid::Uuid;

const MAX_REQUEST_BYTES: usize = 4 * 1024 * 1024;
const MAX_LOCAL_SCAN_SECONDS: f64 = 300.0;
const MAX_EXTERNAL_REQUEST_SECONDS: f64 = 300.0;
const MAX_MODULE_SECONDS: f64 = 600.0;

const ALLOWED_CONTEXT_FIELDS: &[&str] = &[
    "home",
    "now",
    "timezone",
    "days",
    "paths",
    "capabilities",
    "codexQuotaRetryOnly",
    "codexQuotaAccountOrder",
    "localUsageOnly",
    "quotaSkipProviders",
    "pricingOverrides",
];

/// C123: `localPricing` 已移除 —— 计价恒随本机统计执行, 该能力从未被 collector 读取。
const ALLOWED_CAPABILITIES: &[&str] = &["localSessions", "externalQuotas"];

/// 凭证字段白名单; Windows/mac 壳注入 BridgeRequest.credentials 时共用,
/// 暴露为公共常量避免各端复制漂移。
pub const ALLOWED_CREDENTIAL_FIELDS: &[&str] = &[
    "kimiQuotaAccounts",
    "deepseekQuotaAccounts",
    "volcengineQuotaAccounts",
    "zhipuQuotaAccounts",
    "claudeOAuth",
    "claudeQuotaAccounts",
    "grokOAuth",
    "grokQuotaAccounts",
    "opencodeGoQuotaAccounts",
    "codexQuotaAccounts",
    "stepfunQuotaAccounts",
    "jevQuotaAccounts",
    "clineQuotaAccounts",
    "providerMeta",
];

/// 解析请求以获得可用于错误的 runId (尽力而为)。
pub fn run_id_of(input: &[u8]) -> String {
    serde_json::from_slice::<BridgeRequest>(input)
        .map(|request| request.run_id)
        .unwrap_or_else(|_| new_run_id())
}

/// 进程级 panic 兜底: 采集链路出现未预期 panic 时仍产出可解释的 error envelope,
/// 而不是 stdout 为空 + 非零退出码 (调用方无法区分「哪个源坏了」)。
///
/// 已预期/已降级的错误不经过此路径 —— 只有真正的 bug 才会落到这里 (C043)。
pub fn run_bytes_panic_safe(input: &[u8]) -> BridgeResponse {
    let fallback_run_id = run_id_of(input);
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run_bytes(input))).unwrap_or_else(
        |_| {
            error_response(
                fallback_run_id,
                "BRIDGE_INTERNAL_PANIC",
                "runtime",
                "internal",
                "采集进程内部错误 (已捕获 panic), 本轮未产出 artifact",
                true,
            )
        },
    )
}

pub fn run_bytes(input: &[u8]) -> BridgeResponse {
    let started = Instant::now();
    let resource_start = metrics::process_resource_snapshot();
    let (response, stats, metrics, source_metrics) = if input.len() > MAX_REQUEST_BYTES {
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
            Vec::new(),
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
                    Vec::new(),
                    resource_start,
                    metrics::process_resource_snapshot(),
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
                    source_metrics,
                    credential_updates,
                    credential_challenges,
                }) => {
                    let response = BridgeResponse {
                        schema_version: BRIDGE_SCHEMA_VERSION,
                        run_id: request.run_id.clone(),
                        generated_at,
                        status: response_status(true, &diagnostics),
                        artifact: Some(artifact),
                        credential_updates,
                        credential_challenges,
                        diagnostics,
                    };
                    match validate_response_credentials(response) {
                        Ok(response) => (response, scan_stats, metrics, source_metrics),
                        Err(diagnostic) => (
                            BridgeResponse::error(
                                request.run_id,
                                crate::generated_at(),
                                diagnostic,
                            ),
                            CollectionScanStats::default(),
                            CollectionMetrics::default(),
                            Vec::new(),
                        ),
                    }
                }
                Err(diagnostic) => (
                    BridgeResponse::error(request.run_id, generated_at(), diagnostic),
                    CollectionScanStats::default(),
                    CollectionMetrics::default(),
                    Vec::new(),
                ),
            },
            Err(diagnostic) => (
                BridgeResponse::error(request.run_id, generated_at(), diagnostic),
                CollectionScanStats::default(),
                CollectionMetrics::default(),
                Vec::new(),
            ),
        }
    };
    let resource_end = metrics::process_resource_snapshot();
    finish_metrics(
        started,
        response,
        stats,
        metrics,
        source_metrics,
        resource_start,
        resource_end,
    )
}

fn finish_metrics(
    started: Instant,
    response: BridgeResponse,
    stats: CollectionScanStats,
    metrics: CollectionMetrics,
    source_metrics: Vec<SourcePerformanceMetric>,
    resource_start: Option<metrics::ProcessResourceSnapshot>,
    resource_end: Option<metrics::ProcessResourceSnapshot>,
) -> BridgeResponse {
    metrics::write_if_enabled(
        started,
        &response,
        &stats,
        &metrics,
        &source_metrics,
        resource_start,
        resource_end,
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
    if let Some(raw) = request.context.get("pricingOverrides") {
        let invalid = || protocol_error("BRIDGE_INVALID_REQUEST", "价格覆盖配置无效");
        let entries = raw.as_object().ok_or_else(invalid)?;
        if entries.len() > 512 {
            return Err(invalid());
        }
        for (name, price) in entries {
            if name.trim().is_empty() || name.len() > 256 {
                return Err(invalid());
            }
            let fields = price.as_object().ok_or_else(invalid)?;
            for (key, value) in fields {
                if ![
                    "inputPricePerMillion",
                    "outputPricePerMillion",
                    "cacheReadPricePerMillion",
                    "currency",
                    "note",
                ]
                .contains(&key.as_str())
                {
                    return Err(invalid());
                }
                if value.is_null() {
                    continue;
                }
                let valid = match key.as_str() {
                    "inputPricePerMillion"
                    | "outputPricePerMillion"
                    | "cacheReadPricePerMillion" => {
                        value.as_f64().is_some_and(|n| n.is_finite() && n >= 0.0)
                    }
                    "currency" => value
                        .as_str()
                        .is_some_and(|s| ["USD", "CNY", "EUR", "GBP"].contains(&s)),
                    "note" => value.as_str().is_some_and(|s| s.len() <= 1024),
                    _ => false,
                };
                if !valid {
                    return Err(invalid());
                }
            }
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
        generated_at, max_request_bytes, read_request, run_bytes, run_bytes_panic_safe, run_id_of,
        validate_response_credentials,
    };
    use collector_domain::{BridgeResponse, ResponseStatus, BRIDGE_SCHEMA_VERSION};
    use serde_json::{json, Value};
    use std::io::Cursor;

    fn request() -> String {
        r#"{"schemaVersion":1,"runId":"12345678-1234-4234-9234-123456789abc","module":"agent-usage","timeouts":{"localScanSeconds":30,"externalRequestSeconds":10,"moduleSeconds":90},"context":{"home":"/tmp","capabilities":["localSessions"]},"credentials":{}}"#.to_owned()
    }

    /// C043: panic 兜底必须产出可解析的 envelope (含 runId 与诊断码),
    /// 而不是空 stdout / 非零退出码。这里用类型相同的注入闭包验证兜底语义。
    #[test]
    fn panic_safe_wrapper_preserves_envelope_semantics() {
        let input = request().into_bytes();

        // 正常路径: 兜底包装不得改变既有行为
        let normal = run_bytes_panic_safe(&input);
        assert_eq!(normal.run_id, "12345678-1234-4234-9234-123456789abc");

        // panic 路径: 模拟采集链路内部 panic, 断言 error envelope 语义
        let fallback_run_id = run_id_of(&input);
        assert_eq!(fallback_run_id, "12345678-1234-4234-9234-123456789abc");
        let panicking = || -> BridgeResponse {
            panic!("simulated internal failure");
        };
        let recovered = std::panic::catch_unwind(std::panic::AssertUnwindSafe(panicking))
            .unwrap_or_else(|_| {
                super::error_response(
                    fallback_run_id,
                    "BRIDGE_INTERNAL_PANIC",
                    "runtime",
                    "internal",
                    "采集进程内部错误 (已捕获 panic), 本轮未产出 artifact",
                    true,
                )
            });
        assert_eq!(recovered.status, ResponseStatus::Error);
        assert_eq!(recovered.diagnostics.len(), 1);
        assert_eq!(recovered.diagnostics[0].code, "BRIDGE_INTERNAL_PANIC");
        assert!(recovered.artifact.is_none());
        assert_eq!(recovered.run_id, "12345678-1234-4234-9234-123456789abc");
        // 可序列化 = 宿主可解析
        let encoded = serde_json::to_string(&recovered).unwrap();
        let decoded: BridgeResponse = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.diagnostics[0].code, "BRIDGE_INTERNAL_PANIC");
    }

    /// C043: run_id_of 对非法输入回退为新 runId (不 panic, 仍可用于错误信封)。
    #[test]
    fn run_id_of_falls_back_on_invalid_input() {
        let id = run_id_of(b"not json");
        assert!(!id.is_empty());
        let again = run_id_of(b"not json");
        assert_ne!(id, again, "非法输入应回退为新的随机 runId");
    }

    /// C124: 只授予 localSessions 的请求 (无订阅 / 未授权云端额度) 是完整成功的本机统计,
    /// 不再输出 partial 占位 service, 也就不再被判为部分失败。
    #[test]
    fn valid_request_returns_one_structured_artifact_response() {
        let response = run_bytes(request().as_bytes());
        assert_eq!(response.run_id, "12345678-1234-4234-9234-123456789abc");
        assert_eq!(response.status, ResponseStatus::Success);
        assert!(response
            .diagnostics
            .iter()
            .all(|diagnostic| diagnostic.code != "COLLECTOR_PARTIAL_RESULT"));
        let artifact = response.artifact.expect("artifact");
        assert_eq!(artifact["services"], json!([]));
    }

    #[test]
    fn configured_pricing_reaches_collection_and_invalid_rates_fail_closed() {
        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["context"]["capabilities"] = json!([]);
        value["context"]["pricingOverrides"] = json!({"k3": {"inputPricePerMillion": 0.5}});
        let response = run_bytes(&serde_json::to_vec(&value).unwrap());
        assert!(
            response.artifact.is_some(),
            "valid UI price overrides must cross Bridge validation: {:?}",
            response.diagnostics
        );
        for bad in [
            json!({"k3":{"inputPricePerMillion":-1}}),
            json!({"k3":{"access_token":"fixture"}}),
            json!([]),
        ] {
            value["context"]["pricingOverrides"] = bad;
            let response = run_bytes(&serde_json::to_vec(&value).unwrap());
            assert!(response.artifact.is_none());
            assert_eq!(response.diagnostics[0].code, "BRIDGE_INVALID_REQUEST");
        }
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

    /// C123: 从未被 collector 读取的契约字段已退役; 两端停止发送, Bridge 显式拒绝,
    /// 防止再被当作有效开关 (定向刷新只靠「不带 localSessions + 只装配目标凭证」)。
    #[test]
    fn retired_contract_fields_are_rejected() {
        let base: Value = serde_json::from_str(&request()).unwrap();
        for (key, value) in [
            ("subscriptionQuotaOnly", json!(true)),
            ("subscriptionProviders", json!(["kimi"])),
        ] {
            let mut request = base.clone();
            request["context"][key] = value;
            let response = run_bytes(&serde_json::to_vec(&request).unwrap());
            assert_eq!(
                response.diagnostics[0].code, "BRIDGE_INVALID_REQUEST",
                "{key}"
            );
        }
        let mut request = base.clone();
        request["context"]["capabilities"] = json!(["localSessions", "localPricing"]);
        let response = run_bytes(&serde_json::to_vec(&request).unwrap());
        assert_eq!(response.diagnostics[0].code, "BRIDGE_UNKNOWN_CAPABILITY");
        let mut request = base;
        request["credentials"]["providerEnv"] = json!({"deepseek": "fixture"});
        let response = run_bytes(&serde_json::to_vec(&request).unwrap());
        assert_eq!(response.diagnostics[0].code, "BRIDGE_CREDENTIAL_SCOPE");
    }

    #[test]
    fn cline_quota_accounts_pass_credential_scope_validation() {
        let mut value: Value = serde_json::from_str(&request()).unwrap();
        value["credentials"]["clineQuotaAccounts"] = json!({
            "acc-cline-fixture": {
                "display_name": "Cline · fixture",
                "api_key": "cline-fixture-key"
            }
        });
        let response = run_bytes(serde_json::to_vec(&value).unwrap().as_slice());
        assert!(
            response
                .diagnostics
                .iter()
                .all(|diagnostic| diagnostic.code != "BRIDGE_CREDENTIAL_SCOPE"),
            "clineQuotaAccounts 应通过凭据白名单: {:?}",
            response.diagnostics
        );
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
