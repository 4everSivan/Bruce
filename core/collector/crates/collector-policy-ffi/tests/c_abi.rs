//! C ABI 边界 (T16): 共享 fixture 经 `bruce_policy_call` 与进程内入口逐字节一致;
//! 空请求 / 空 out_len / 非法输入均安全返回, 缓冲区可释放。

use bruce_policy::{bruce_policy_call, bruce_policy_free};
use serde_json::{json, Value};

const PLAN_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-policy-parity/cases.json");
const CARRY_OVER_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-carry-over-parity/cases.json");

fn call_bytes(input: &[u8]) -> Vec<u8> {
    let mut len = 0usize;
    // SAFETY: input 在调用期间有效, len 可写。
    let buffer = unsafe { bruce_policy_call(input.as_ptr(), input.len(), &mut len) };
    assert!(!buffer.is_null());
    // SAFETY: buffer 指向 len 字节, 读取后按同一长度释放一次。
    let output = unsafe { std::slice::from_raw_parts(buffer, len) }.to_vec();
    unsafe { bruce_policy_free(buffer, len) };
    output
}

fn call(request: &Value) -> Value {
    let input = serde_json::to_vec(request).unwrap();
    let output = call_bytes(&input);
    assert_eq!(
        output,
        serde_json::to_vec(&collector_policy::handle_request(&input)).unwrap(),
        "C ABI 与进程内入口逐字节一致"
    );
    serde_json::from_slice(&output).unwrap()
}

#[test]
fn shared_fixtures_through_c_abi() {
    let plan: Value = serde_json::from_str(PLAN_FIXTURE).unwrap();
    for case in plan["cases"].as_array().unwrap() {
        let response = call(&json!({
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
        assert_eq!(
            response["result"]["policy"], case["expected"],
            "{}",
            case["name"]
        );
    }
    let carry: Value = serde_json::from_str(CARRY_OVER_FIXTURE).unwrap();
    for case in carry["cases"].as_array().unwrap() {
        let response = call(&json!({
            "schemaVersion": 1,
            "operation": "quotaMerge",
            "now": case["now"],
            "previousServices": case["previous"],
            "currentServices": case["current"],
            "policy": case["policy"],
            "intervalSeconds": case["intervalSeconds"],
        }));
        assert_eq!(
            response["result"]["services"], case["expected"],
            "{}",
            case["name"]
        );
    }
}

#[test]
fn malformed_and_empty_input_return_envelopes() {
    for input in [&b""[..], b"\xff\xfe", b"{\"schemaVersion\":1,"] {
        let response: Value = serde_json::from_slice(&call_bytes(input)).unwrap();
        assert_eq!(response["status"], "error");
        assert_eq!(response["diagnostics"][0]["code"], "POLICY_INVALID_JSON");
    }
    // 空指针 + 0 长度视为空请求。
    let mut len = 0usize;
    // SAFETY: 空请求不读内存; len 可写。
    let buffer = unsafe { bruce_policy_call(std::ptr::null(), 0, &mut len) };
    assert!(!buffer.is_null() && len > 0);
    unsafe { bruce_policy_free(buffer, len) };
}

#[test]
fn null_out_len_allocates_nothing_and_free_accepts_null() {
    let input = b"{}";
    // SAFETY: input 有效; out_len 为空时函数不写入。
    let buffer = unsafe { bruce_policy_call(input.as_ptr(), input.len(), std::ptr::null_mut()) };
    assert!(buffer.is_null());
    // SAFETY: 空指针释放为无操作。
    unsafe { bruce_policy_free(std::ptr::null_mut(), 0) };
}

#[test]
fn repeated_calls_release_every_buffer() {
    let request = serde_json::to_vec(&json!({
        "schemaVersion": 1, "operation": "quotaAnnotate", "now": "2026-10-26T12:00:00Z",
        "services": [{"id": "kimi_coding", "status": "ok", "windows": []}],
        "serviceIds": ["kimi_coding"],
    }))
    .unwrap();
    for _ in 0..10_000 {
        let response: Value = serde_json::from_slice(&call_bytes(&request)).unwrap();
        assert_eq!(response["status"], "success");
    }
}
