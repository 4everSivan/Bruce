//! 策略入口的 JSON 契约 (`schemas/policy-request-v1` / `policy-response-v1`, T14)。
//!
//! collector `policy` 子命令与 mac 进程内调用共用: 字节进、JSON 信封出。入口只收
//! artifact 的 `services` 与时间、间隔等纯数据: 顶层与操作字段按白名单拒绝未知字段,
//! 任意层级出现凭据形态的键 (token / secret / password / apiKey / cookie / authorization /
//! credential / oauth / *QuotaAccounts) 一律拒绝; 错误以结构化诊断返回, panic 也被收敛
//! 为诊断, 不越过入口。

use std::collections::BTreeSet;

use serde::Deserialize;
use serde_json::{json, Map, Value};

use crate::quota::{annotate_services, merge, plan, PlanInput, QuotaRunPolicy};

pub const POLICY_SCHEMA_VERSION: u64 = 1;
/// 请求上限: 与采集请求同为 4 MiB (正常请求只含 services, 约数 KB)。
pub const MAX_POLICY_REQUEST_BYTES: usize = 4 * 1024 * 1024;

const OPERATIONS: [&str; 3] = ["quotaPlan", "quotaMerge", "quotaAnnotate"];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PlanRequest {
    now: String,
    #[serde(default)]
    previous_services: Option<Vec<Value>>,
    #[serde(default)]
    enabled_providers: Option<Vec<String>>,
    interval_seconds: i64,
    force_refresh: bool,
    bypass_cooldown: bool,
    suppress_external_quotas: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MergeRequest {
    now: String,
    #[serde(default)]
    previous_services: Option<Vec<Value>>,
    current_services: Vec<Value>,
    policy: QuotaRunPolicy,
    interval_seconds: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AnnotateRequest {
    now: String,
    services: Vec<Value>,
    service_ids: BTreeSet<String>,
}

struct Failure {
    code: &'static str,
    message: String,
}

impl Failure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

/// 处理一次策略请求, 总是返回 policy-response-v1 信封 (不 panic)。
pub fn handle_request(input: &[u8]) -> Value {
    let (operation, outcome) = match validate_envelope(input) {
        Err(failure) => (None, Err(failure)),
        Ok((operation, fields)) => {
            let outcome =
                std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| run(&operation, fields)))
                    .unwrap_or_else(|_| {
                        Err(Failure::new(
                            "POLICY_INTERNAL_PANIC",
                            "策略计算内部错误 (已捕获 panic)",
                        ))
                    });
            (Some(operation), outcome)
        }
    };
    match outcome {
        Ok(result) => json!({
            "schemaVersion": POLICY_SCHEMA_VERSION,
            "status": "success",
            "operation": operation,
            "result": result,
            "diagnostics": [],
        }),
        Err(failure) => json!({
            "schemaVersion": POLICY_SCHEMA_VERSION,
            "status": "error",
            "operation": operation,
            "result": null,
            "diagnostics": [{"code": failure.code, "message": failure.message}],
        }),
    }
}

/// 信封校验: 大小、JSON、凭据键、schema 版本与操作名; 返回操作名与其余字段。
fn validate_envelope(input: &[u8]) -> Result<(String, Value), Failure> {
    if input.len() > MAX_POLICY_REQUEST_BYTES {
        return Err(Failure::new(
            "POLICY_INPUT_TOO_LARGE",
            "策略请求超过 4 MiB 上限",
        ));
    }
    let request: Value = serde_json::from_slice(input)
        .map_err(|_| Failure::new("POLICY_INVALID_JSON", "策略请求不是有效 JSON"))?;
    let Value::Object(mut fields) = request else {
        return Err(Failure::new(
            "POLICY_INVALID_REQUEST",
            "策略请求必须是 JSON 对象",
        ));
    };
    if let Some(key) = credential_key_in_object(&fields) {
        return Err(Failure::new(
            "POLICY_CREDENTIAL_FIELD_REJECTED",
            format!("策略入口不接收凭据: 拒绝字段 {key}"),
        ));
    }
    if fields
        .remove("schemaVersion")
        .as_ref()
        .and_then(Value::as_u64)
        != Some(POLICY_SCHEMA_VERSION)
    {
        return Err(Failure::new(
            "POLICY_UNSUPPORTED_SCHEMA",
            "不支持的策略请求 schema 版本",
        ));
    }
    match fields.remove("operation") {
        Some(Value::String(name)) if OPERATIONS.contains(&name.as_str()) => {
            Ok((name, Value::Object(fields)))
        }
        _ => Err(Failure::new(
            "POLICY_UNKNOWN_OPERATION",
            "operation 必须是 quotaPlan / quotaMerge / quotaAnnotate",
        )),
    }
}

fn run(operation: &str, fields: Value) -> Result<Value, Failure> {
    match operation {
        "quotaPlan" => {
            let request: PlanRequest = parse(fields)?;
            let previous = request
                .previous_services
                .map(|services| json!({"services": services}));
            let policy = plan(&PlanInput {
                previous: previous.as_ref(),
                enabled_providers: request.enabled_providers.as_deref(),
                now_ms: now_ms(&request.now)?,
                interval_secs: request.interval_seconds,
                force_refresh: request.force_refresh,
                bypass_cooldown: request.bypass_cooldown,
                suppress_external_quotas: request.suppress_external_quotas,
            });
            Ok(json!({"policy": policy}))
        }
        "quotaMerge" => {
            let request: MergeRequest = parse(fields)?;
            let previous = request
                .previous_services
                .map(|services| json!({"services": services}));
            let merged = merge(
                previous.as_ref(),
                &json!({"services": request.current_services}),
                &request.policy,
                now_ms(&request.now)?,
                request.interval_seconds,
            );
            Ok(json!({"services": merged["services"]}))
        }
        _ => {
            let request: AnnotateRequest = parse(fields)?;
            let mut artifact = json!({"services": request.services});
            annotate_services(&mut artifact, &request.service_ids, now_ms(&request.now)?);
            Ok(json!({"services": artifact["services"]}))
        }
    }
}

fn parse<T: for<'de> Deserialize<'de>>(fields: Value) -> Result<T, Failure> {
    serde_json::from_value(fields).map_err(|error| {
        Failure::new(
            "POLICY_INVALID_REQUEST",
            format!("策略请求字段无效: {error}"),
        )
    })
}

fn now_ms(text: &str) -> Result<i64, Failure> {
    chrono::DateTime::parse_from_rfc3339(text)
        .map(|time| time.timestamp_millis())
        .map_err(|_| Failure::new("POLICY_INVALID_TIME", "now 必须是 RFC 3339 时间"))
}

/// 凭据形态的键: 去掉非字母数字并小写后含凭据标记, 或为 `*QuotaAccounts` 凭据白名单键。
fn is_credential_key(key: &str) -> bool {
    const MARKERS: [&str; 8] = [
        "token",
        "secret",
        "password",
        "apikey",
        "cookie",
        "authorization",
        "credential",
        "oauth",
    ];
    let normalized: String = key
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .collect();
    MARKERS.iter().any(|marker| normalized.contains(marker))
        || normalized.ends_with("quotaaccounts")
}

fn credential_key_in_object(object: &Map<String, Value>) -> Option<String> {
    object.iter().find_map(|(key, value)| {
        if is_credential_key(key) {
            Some(key.clone())
        } else {
            credential_key(value)
        }
    })
}

fn credential_key(value: &Value) -> Option<String> {
    match value {
        Value::Object(object) => credential_key_in_object(object),
        Value::Array(items) => items.iter().find_map(credential_key),
        _ => None,
    }
}
