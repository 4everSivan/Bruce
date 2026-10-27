//! 窗口边界唤醒与刷新退避的共享裁判用例 (T17): tests/fixtures/refresh-policy-parity。
//!
//! mac RefreshSchedulerHarness 与 Windows scheduler_collector_coverage 消费同一份
//! fixture; 本文件验证共享 crate 的纯函数与策略入口。

use std::collections::BTreeSet;

use collector_policy::{
    backoff_seconds, boundary_delay, boundary_ids, handle_request, window_boundaries,
};
use serde_json::{json, Value};

const REFRESH_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/refresh-policy-parity/cases.json");

fn fixture() -> Value {
    serde_json::from_str(REFRESH_FIXTURE).unwrap()
}

fn close(actual: f64, expected: f64, name: &str) {
    assert!(
        (actual - expected).abs() < 1e-6,
        "{name}: actual {actual}, expected {expected}"
    );
}

fn integers(value: &Value) -> Vec<i64> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_i64().unwrap())
        .collect()
}

#[test]
fn boundary_ids_match_fixture() {
    let fixture = fixture();
    let cases = fixture["boundaryIds"].as_array().unwrap();
    assert!(cases.len() >= 3);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let services = case["services"].as_array().unwrap();
        assert_eq!(
            boundary_ids(services),
            integers(&case["expected"]),
            "{name}"
        );
        // artifact 入口与 services 入口同源。
        let artifact = json!({"services": services});
        assert_eq!(
            window_boundaries(&artifact),
            integers(&case["expected"]),
            "{name} (artifact)"
        );
    }
}

#[test]
fn boundary_delay_matches_fixture() {
    let fixture = fixture();
    let cases = fixture["boundaryWake"].as_array().unwrap();
    assert!(cases.len() >= 10);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let mut consumed: BTreeSet<i64> = integers(&case["consumed"]).into_iter().collect();
        let delay = boundary_delay(
            case["interval"].as_f64().unwrap(),
            &integers(&case["boundaries"]),
            case["now"].as_f64().unwrap(),
            case["slack"].as_f64().unwrap(),
            &mut consumed,
        );
        close(delay, case["expectedDelay"].as_f64().unwrap(), name);
        assert_eq!(
            consumed.iter().copied().collect::<Vec<_>>(),
            integers(&case["expectedConsumed"]),
            "{name} (consumed)"
        );
    }
}

#[test]
fn backoff_matches_fixture() {
    let fixture = fixture();
    let cases = fixture["backoff"].as_array().unwrap();
    assert!(cases.len() >= 12);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let seconds = backoff_seconds(
            case["retryCount"].as_u64().unwrap() as u32,
            case["rateLimited"].as_bool().unwrap(),
            case["base"].as_f64().unwrap(),
            case["max"].as_f64().unwrap(),
            case["rateLimit"].as_f64().unwrap(),
            case["jitterFraction"].as_f64().unwrap(),
        );
        close(seconds, case["expectedSeconds"].as_f64().unwrap(), name);
    }
}

#[test]
fn policy_entry_exposes_boundary_and_backoff_operations() {
    let fixture = fixture();
    let wake = &fixture["boundaryWake"][0];
    let request = json!({
        "schemaVersion": 1,
        "operation": "boundaryWake",
        "interval": wake["interval"],
        "boundaries": wake["boundaries"],
        "now": wake["now"],
        "slack": wake["slack"],
        "consumed": wake["consumed"],
    });
    let response = handle_request(request.to_string().as_bytes());
    assert_eq!(response["status"], "success");
    close(
        response["result"]["delay"].as_f64().unwrap(),
        wake["expectedDelay"].as_f64().unwrap(),
        "boundaryWake entry",
    );
    assert_eq!(
        response["result"]["consumed"], wake["expectedConsumed"],
        "boundaryWake consumed"
    );

    let ids = &fixture["boundaryIds"][0];
    let response = handle_request(
        json!({
            "schemaVersion": 1,
            "operation": "boundaryIds",
            "services": ids["services"],
        })
        .to_string()
        .as_bytes(),
    );
    assert_eq!(response["status"], "success");
    assert_eq!(response["result"]["boundaries"], ids["expected"]);

    let backoff = &fixture["backoff"][0];
    let response = handle_request(
        json!({
            "schemaVersion": 1,
            "operation": "backoff",
            "retryCount": backoff["retryCount"],
            "rateLimited": backoff["rateLimited"],
            "base": backoff["base"],
            "max": backoff["max"],
            "rateLimit": backoff["rateLimit"],
            "jitterFraction": backoff["jitterFraction"],
        })
        .to_string()
        .as_bytes(),
    );
    assert_eq!(response["status"], "success");
    close(
        response["result"]["seconds"].as_f64().unwrap(),
        backoff["expectedSeconds"].as_f64().unwrap(),
        "backoff entry",
    );
}

#[test]
fn policy_entry_rejects_unknown_fields_and_credentials_for_refresh_ops() {
    let unknown = json!({
        "schemaVersion": 1,
        "operation": "backoff",
        "retryCount": 1,
        "rateLimited": false,
        "base": 30,
        "max": 1800,
        "rateLimit": 300,
        "unexpected": true,
    });
    let response = handle_request(unknown.to_string().as_bytes());
    assert_eq!(response["status"], "error");
    assert_eq!(response["diagnostics"][0]["code"], "POLICY_INVALID_REQUEST");

    let credential = json!({
        "schemaVersion": 1,
        "operation": "boundaryWake",
        "interval": 1800,
        "boundaries": [],
        "now": 1_000_000,
        "apiKey": "must-not-cross",
    });
    let response = handle_request(credential.to_string().as_bytes());
    assert_eq!(response["status"], "error");
    assert_eq!(
        response["diagnostics"][0]["code"],
        "POLICY_CREDENTIAL_FIELD_REJECTED"
    );
}
