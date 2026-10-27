//! `Bruce-collector policy` 进程级用例 (T14): 共享 fixture 经 stdin / stdout 跑构建出的
//! 二进制, 结果与 collector-policy 进程内入口逐字节一致且符合 fixture 期望。

use std::io::Write;
use std::process::{Command, Stdio};

use serde_json::{json, Value};

const PLAN_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-policy-parity/cases.json");
const CARRY_OVER_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-carry-over-parity/cases.json");

fn run_binary(args: &[&str], input: &[u8]) -> (Option<i32>, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_Bruce-collector"))
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn Bruce-collector");
    child.stdin.take().unwrap().write_all(input).unwrap();
    let output = child.wait_with_output().unwrap();
    let response = serde_json::from_slice(&output.stdout).expect("stdout 为单个 JSON 信封");
    (output.status.code(), response)
}

/// 经子命令调用, 并断言与进程内入口完全一致。
fn policy(request: &Value) -> Value {
    let bytes = serde_json::to_vec(request).unwrap();
    let (code, response) = run_binary(&["policy"], &bytes);
    assert_eq!(code, Some(0));
    assert_eq!(response, collector_policy::handle_request(&bytes));
    assert_eq!(response["status"], "success", "{response}");
    response["result"].clone()
}

#[test]
fn plan_fixture_through_subcommand() {
    let fixture: Value = serde_json::from_str(PLAN_FIXTURE).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let result = policy(&json!({
            "schemaVersion": 1,
            "operation": "quotaPlan",
            "now": case["now"],
            "previousServices": case["services"],
            "enabledProviders": case["enabledProviders"],
            "intervalSeconds": case["intervalSeconds"],
            "forceRefresh": case["forceRefresh"],
            "bypassCooldown": case["bypassCooldown"],
            "suppressExternalQuotas": false,
        }));
        assert_eq!(result["policy"], case["expected"], "{}", case["name"]);
    }
}

#[test]
fn carry_over_fixture_through_subcommand() {
    let fixture: Value = serde_json::from_str(CARRY_OVER_FIXTURE).unwrap();
    for case in fixture["cases"].as_array().unwrap() {
        let result = policy(&json!({
            "schemaVersion": 1,
            "operation": "quotaMerge",
            "now": case["now"],
            "previousServices": case["previous"],
            "currentServices": case["current"],
            "policy": case["policy"],
            "intervalSeconds": case["intervalSeconds"],
        }));
        assert_eq!(result["services"], case["expected"], "{}", case["name"]);
    }
}

#[test]
fn rejected_requests_still_exit_zero_with_envelope() {
    let (code, response) = run_binary(
        &["policy"],
        br#"{"schemaVersion":1,"operation":"quotaPlan","accessToken":"x"}"#,
    );
    assert_eq!(code, Some(0));
    assert_eq!(response["status"], "error");
    assert_eq!(
        response["diagnostics"][0]["code"],
        "POLICY_CREDENTIAL_FIELD_REJECTED"
    );
}

#[test]
fn without_subcommand_the_bridge_contract_is_unchanged() {
    // 无参数仍是采集 Bridge: 策略请求不是合法 request-v1, 返回 Bridge 错误信封。
    let (code, response) = run_binary(&[], br#"{"schemaVersion":1,"operation":"quotaPlan"}"#);
    assert_eq!(code, Some(0));
    assert_eq!(response["status"], "error");
    assert!(response.get("runId").is_some());
    assert!(response.get("operation").is_none());
}
