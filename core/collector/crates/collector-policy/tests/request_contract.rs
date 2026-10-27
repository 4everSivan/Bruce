//! policy-request-v1 / policy-response-v1 契约 (T14): 白名单、凭据拒绝与结构化诊断。

use collector_policy::{handle_request, MAX_POLICY_REQUEST_BYTES};
use serde_json::{json, Value};

const NOW: &str = "2026-10-26T12:00:00Z";

fn call(request: &Value) -> Value {
    handle_request(&serde_json::to_vec(request).unwrap())
}

fn error_code(response: &Value) -> &str {
    assert_eq!(response["status"], "error", "{response}");
    assert!(response["result"].is_null());
    response["diagnostics"][0]["code"].as_str().unwrap()
}

fn plan_request() -> Value {
    json!({
        "schemaVersion": 1,
        "operation": "quotaPlan",
        "now": NOW,
        "previousServices": [{"id": "kimi_coding", "provider": "kimi", "status": "ok",
            "windows": [], "capturedAt": "2026-10-26T11:55:00Z"}],
        "enabledProviders": ["kimi"],
        "intervalSeconds": 1800,
        "forceRefresh": false,
        "bypassCooldown": false,
        "suppressExternalQuotas": false,
    })
}

#[test]
fn plan_success_envelope() {
    let response = call(&plan_request());
    assert_eq!(
        response,
        json!({
            "schemaVersion": 1,
            "status": "success",
            "operation": "quotaPlan",
            "result": {"policy": {
                "includeExternalQuotas": false,
                "skipProviders": ["kimi"],
                "rateLimitedProviders": [],
            }},
            "diagnostics": [],
        })
    );
}

#[test]
fn optional_previous_and_enabled_may_be_null_or_absent() {
    let mut request = plan_request();
    request["previousServices"] = Value::Null;
    request.as_object_mut().unwrap().remove("enabledProviders");
    let response = call(&request);
    assert_eq!(response["status"], "success");
    assert_eq!(response["result"]["policy"]["includeExternalQuotas"], true);
}

#[test]
fn merge_and_annotate_return_services() {
    let merged = call(&json!({
        "schemaVersion": 1,
        "operation": "quotaMerge",
        "now": NOW,
        "previousServices": null,
        "currentServices": [{"id": "kimi_coding", "provider": "kimi", "status": "ok", "windows": []}],
        "policy": {"includeExternalQuotas": true, "skipProviders": [], "rateLimitedProviders": []},
        "intervalSeconds": 1800,
    }));
    assert_eq!(merged["status"], "success");
    assert_eq!(merged["result"]["services"][0]["quotaAttemptedAt"], NOW);
    assert_eq!(merged["result"]["services"][0]["freshness"], "fresh");

    let annotated = call(&json!({
        "schemaVersion": 1,
        "operation": "quotaAnnotate",
        "now": NOW,
        "services": [
            {"id": "kimi_coding", "status": "ok", "windows": []},
            {"id": "zhipu_a", "status": "ok", "windows": []},
        ],
        "serviceIds": ["zhipu_a"],
    }));
    assert_eq!(annotated["operation"], "quotaAnnotate");
    let services = annotated["result"]["services"].as_array().unwrap();
    assert!(services[0].get("quotaAttemptedAt").is_none());
    assert_eq!(services[1]["quotaAttemptedAt"], NOW);
}

#[test]
fn unknown_fields_are_rejected_at_every_level() {
    let mut top = plan_request();
    top["extra"] = json!(1);
    assert_eq!(error_code(&call(&top)), "POLICY_INVALID_REQUEST");
    assert_eq!(call(&top)["operation"], "quotaPlan");

    let policy_extra = json!({
        "schemaVersion": 1,
        "operation": "quotaMerge",
        "now": NOW,
        "currentServices": [],
        "policy": {"includeExternalQuotas": true, "skipProviders": [],
            "rateLimitedProviders": [], "force": true},
        "intervalSeconds": 1800,
    });
    assert_eq!(error_code(&call(&policy_extra)), "POLICY_INVALID_REQUEST");

    // 其他操作的字段同样不被接受 (按操作白名单)。
    let mut crossed = plan_request();
    crossed["currentServices"] = json!([]);
    assert_eq!(error_code(&call(&crossed)), "POLICY_INVALID_REQUEST");
}

#[test]
fn missing_or_mistyped_fields_are_rejected() {
    let mut missing = plan_request();
    missing.as_object_mut().unwrap().remove("intervalSeconds");
    assert_eq!(error_code(&call(&missing)), "POLICY_INVALID_REQUEST");

    let mut mistyped = plan_request();
    mistyped["forceRefresh"] = json!("yes");
    assert_eq!(error_code(&call(&mistyped)), "POLICY_INVALID_REQUEST");
}

#[test]
fn credential_shaped_keys_are_rejected_anywhere() {
    for key in [
        "accessToken",
        "refresh_token",
        "apiKey",
        "Authorization",
        "cookie",
        "clientSecret",
        "password",
        "claudeOAuth",
        "credentials",
        "kimiQuotaAccounts",
    ] {
        let mut top = plan_request();
        top[key] = json!("x");
        let response = call(&top);
        assert_eq!(
            error_code(&response),
            "POLICY_CREDENTIAL_FIELD_REJECTED",
            "{key}"
        );
        assert!(!response.to_string().contains("\"x\""), "诊断不回显凭据值");

        let mut nested = plan_request();
        let mut window = serde_json::Map::new();
        window.insert(key.to_owned(), json!("x"));
        nested["previousServices"][0]["windows"] = json!([window]);
        assert_eq!(
            error_code(&call(&nested)),
            "POLICY_CREDENTIAL_FIELD_REJECTED",
            "nested {key}"
        );
    }
    // 凭据检查先于操作解析: 未知操作带凭据也按凭据拒绝。
    let response = call(&json!({"schemaVersion": 1, "operation": "nope", "token": "x"}));
    assert_eq!(error_code(&response), "POLICY_CREDENTIAL_FIELD_REJECTED");
    assert!(response["operation"].is_null());
}

#[test]
fn real_service_keys_are_not_mistaken_for_credentials() {
    let mut request = plan_request();
    request["previousServices"] = json!([{
        "id": "codex_a", "name": "Codex", "provider": "codex", "app": "codex", "isCurrent": true,
        "status": "error", "kind": "windows", "plan": "Pro", "balance": 1.0, "currency": "USD",
        "note": "n", "extra": "e", "capturedAt": NOW, "quotaAttemptedAt": NOW,
        "rateLimitedAt": NOW, "freshness": "stale", "failureKind": "tokenUnavailable",
        "windows": [{"label": "5h", "usedPercent": 1, "resetsAt": 1, "resetAt": 1, "windowMinutes": 300}],
    }]);
    assert_eq!(call(&request)["status"], "success");
}

#[test]
fn envelope_errors_are_structured() {
    assert_eq!(
        error_code(&handle_request(b"{not json")),
        "POLICY_INVALID_JSON"
    );
    assert_eq!(error_code(&handle_request(b"[]")), "POLICY_INVALID_REQUEST");
    assert_eq!(
        error_code(&handle_request(&vec![b' '; MAX_POLICY_REQUEST_BYTES + 1])),
        "POLICY_INPUT_TOO_LARGE"
    );

    let mut version = plan_request();
    version["schemaVersion"] = json!(2);
    assert_eq!(error_code(&call(&version)), "POLICY_UNSUPPORTED_SCHEMA");

    let mut operation = plan_request();
    operation["operation"] = json!("quotaDelete");
    assert_eq!(error_code(&call(&operation)), "POLICY_UNKNOWN_OPERATION");

    let mut time = plan_request();
    time["now"] = json!("yesterday");
    let response = call(&time);
    assert_eq!(error_code(&response), "POLICY_INVALID_TIME");
    assert_eq!(response["operation"], "quotaPlan");
}

#[test]
fn diagnostic_codes_match_response_schema() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../schemas/policy-response-v1.schema.json"
    ))
    .unwrap();
    let declared: Vec<&str> = schema["properties"]["diagnostics"]["items"]["properties"]["code"]
        ["enum"]
        .as_array()
        .unwrap()
        .iter()
        .map(|code| code.as_str().unwrap())
        .collect();
    let source = include_str!("../src/request.rs");
    let mut used: Vec<&str> = source
        .match_indices("\"POLICY_")
        .map(|(start, _)| {
            let rest = &source[start + 1..];
            &rest[..rest.find('"').unwrap()]
        })
        .collect();
    used.sort_unstable();
    used.dedup();
    let mut declared_sorted = declared.clone();
    declared_sorted.sort_unstable();
    assert_eq!(used, declared_sorted, "诊断码与 policy-response-v1 一致");
}
