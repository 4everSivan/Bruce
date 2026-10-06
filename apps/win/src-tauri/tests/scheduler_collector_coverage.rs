//! 刷新调度与采集请求契约覆盖 —— 退避策略、限流分类、请求序列化往返。

use bruce_win_lib::scheduler::{classify_rate_limited, compute_backoff};
use collector_domain::{BridgeRequest, Diagnostic, BRIDGE_SCHEMA_VERSION};
use serde_json::json;

#[test]
fn backoff_is_fixed_for_rate_limit() {
    for retry in [1u32, 3, 7] {
        assert_eq!(compute_backoff(retry, true), 300, "限流固定退避 (对齐 mac)");
    }
}

#[test]
fn backoff_is_exponential_with_jitter_and_cap() {
    // 指数基线 30s×2^(n-1); 抖动 < 基线/10; 上限 1800 (抖动后被 cap 截断)。
    for (retry, base) in [(1u32, 30u64), (2, 60), (3, 120), (4, 240)] {
        let value = compute_backoff(retry, false);
        assert!(
            value >= base && value < base + base / 10,
            "retry={retry} value={value}"
        );
    }
    assert_eq!(compute_backoff(8, false), 1800, "30<<7=3840 -> 截断 1800");
    assert_eq!(compute_backoff(20, false), 1800, "移位饱和后仍为上限");
}

#[test]
fn rate_limit_classification_reads_bridge_diagnostics() {
    let run_id = "00000000-0000-0000-0000-000000000000";
    let rate_limited_response = collector_domain::BridgeResponse::error(
        run_id,
        "2026-07-28T12:00:00+08:00",
        Diagnostic::new("QUOTA_RATE_LIMITED", "rateLimit", "external", "429", true),
    );
    assert!(
        classify_rate_limited(&rate_limited_response),
        "rateLimit 分类为 true"
    );

    let plain = collector_domain::BridgeResponse::error(
        run_id,
        "2026-07-28T12:00:00+08:00",
        Diagnostic::new("NETWORK_DOWN", "network", "external", "down", false),
    );
    assert!(!classify_rate_limited(&plain), "非限流分类为 false");
}

#[test]
fn local_request_serializes_and_round_trips_through_domain_type() {
    let credentials = bruce_win_lib::credentials::CredentialPayloads::new();
    let request = bruce_win_lib::collector::build_local_request(chrono::Local::now(), &credentials);
    // Serialize -> Value -> Deserialize 往返 (deny_unknown_fields 兼容性锁定)。
    let value = serde_json::to_value(&request).unwrap();
    let parsed: BridgeRequest = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(parsed.schema_version, BRIDGE_SCHEMA_VERSION);
    assert_eq!(parsed.module, "agent-usage");
    assert_eq!(parsed.timeouts.local_scan_seconds, 120.0);
    assert_eq!(parsed.timeouts.module_seconds, 150.0);
    // 字段命名契约 (mac Bridge 同一协议)。
    assert!(value.get("schemaVersion").is_some());
    assert!(value.get("runId").is_some());
    assert!(value["timeouts"].get("localScanSeconds").is_some());
    assert!(value.get("credentials").is_some());
}

#[test]
fn request_context_is_valid_for_collection_window() {
    let request = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    // now 可被 RFC3339 解析 (CollectionWindow.parse_now 前置条件)。
    chrono::DateTime::parse_from_rfc3339(request.context["now"].as_str().expect("now 为字符串"))
        .expect("now 为合法 RFC3339");
    assert!(
        !request.context["timezone"].as_str().unwrap().is_empty(),
        "时区非空"
    );
    assert_eq!(request.context["days"].as_u64(), Some(14));
    // runId 是合法 UUID (validate_request 前置条件)。
    uuid::Uuid::parse_str(&request.run_id).expect("runId 为 UUID");
}

#[test]
fn credentials_injection_enables_external_quotas_only_when_present() {
    let empty = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    let capabilities: Vec<&str> = empty.context["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    assert_eq!(capabilities, vec!["localSessions", "localPricing"]);
    assert!(empty.credentials.is_empty());

    let mut credentials = bruce_win_lib::credentials::CredentialPayloads::new();
    credentials.insert(
        "kimiQuotaAccounts".to_owned(),
        json!([{ "accountID": "a1", "apiKey": "sk-test" }]),
    );
    credentials.insert("providerEnv".to_owned(), json!({"batchMode": true}));
    let request = bruce_win_lib::collector::build_local_request(chrono::Local::now(), &credentials);
    let capabilities: Vec<&str> = request.context["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    assert!(
        capabilities.contains(&"externalQuotas"),
        "有凭证即启用出站额度"
    );
    assert_eq!(capabilities.len(), 3, "且不重复注入本地能力");
    assert_eq!(
        request.credentials["kimiQuotaAccounts"],
        credentials["kimiQuotaAccounts"]
    );
    assert_eq!(
        request.credentials["providerEnv"],
        json!({"batchMode": true})
    );
}

#[test]
fn timeout_values_stay_within_bridge_limits() {
    let request = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    assert!(
        request.timeouts.local_scan_seconds > 0.0 && request.timeouts.local_scan_seconds <= 300.0
    );
    assert!(
        request.timeouts.external_request_seconds > 0.0
            && request.timeouts.external_request_seconds <= 300.0
    );
    assert!(request.timeouts.module_seconds > 0.0 && request.timeouts.module_seconds <= 600.0);
}
