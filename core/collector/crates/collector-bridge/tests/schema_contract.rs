//! C266: Bridge / policy JSON Schema 与实现白名单的契约校准。
//!
//! 校验器不引入 JSON Schema 运行时依赖：这里锁定“实现实际接受/产生的字段必须出现在
//! schema 中”的关键集合，防止 schema 再次与桥接实现漂移。

use collector_bridge::ALLOWED_CREDENTIAL_FIELDS;
use serde_json::Value;

fn schema(name: &str) -> Value {
    let path = format!("{}/../../schemas/{name}", env!("CARGO_MANIFEST_DIR"));
    let body = std::fs::read_to_string(&path).expect("schema 文件应存在");
    serde_json::from_str(&body).expect("schema 必须是合法 JSON")
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(str::to_owned)
        .collect()
}

#[test]
fn request_schema_covers_bridge_modules_context_and_credentials() {
    let request = schema("request-v1.schema.json");
    let modules = strings(&request["properties"]["module"]["enum"]);
    assert!(modules.contains(&"agent-usage".to_owned()));
    assert!(
        modules.contains(&"request-log".to_owned()),
        "request-log 模块必须可表达"
    );

    let context = request["properties"]["context"]["properties"]
        .as_object()
        .expect("context properties");
    for field in [
        "home",
        "now",
        "timezone",
        "days",
        "paths",
        "capabilities",
        "quotaRetryOnly",
        "codexQuotaAccountOrder",
        "localUsageOnly",
        "quotaSkipProviders",
        "egressRules",
        "pricingOverrides",
        "pricingCatalog",
        "operation",
        "start",
        "end",
        "agentIds",
        "model",
        "status",
        "page",
        "pageSize",
    ] {
        assert!(
            context.contains_key(field),
            "request context 缺字段 {field}"
        );
    }

    let credentials = request["properties"]["credentials"]["$ref"]
        .as_str()
        .and_then(|reference| reference.strip_prefix("#/$defs/"))
        .and_then(|name| request["$defs"][name]["properties"].as_object())
        .expect("credentials $defs");
    for field in ALLOWED_CREDENTIAL_FIELDS {
        assert!(
            credentials.contains_key(*field),
            "request credentials 缺白名单字段 {field}"
        );
    }
    // quotaAccounts 不再只允许 display_name（真实账号携带 api_key / token 等）。
    assert_eq!(
        request["$defs"]["quotaAccounts"]["additionalProperties"]["additionalProperties"],
        Value::Bool(true)
    );
}

#[test]
fn response_schema_includes_runtime_diagnostics() {
    let response = schema("response-v1.schema.json");
    let categories = strings(&response["$defs"]["diagnostic"]["properties"]["category"]["enum"]);
    for category in [
        "protocol",
        "security",
        "collector",
        "schema",
        "auth",
        "network",
        "storage",
        "runtime",
        "internal",
    ] {
        assert!(
            categories.contains(&category.to_owned()),
            "诊断分类缺 {category}"
        );
    }
}

#[test]
fn policy_schemas_cover_alert_decide() {
    let request = schema("policy-request-v1.schema.json");
    let cases = request["oneOf"].as_array().expect("policy request oneOf");
    assert!(
        cases
            .iter()
            .any(|case| { case["properties"]["operation"]["const"] == "alertDecide" }),
        "policy-request 缺 alertDecide"
    );

    let response = schema("policy-response-v1.schema.json");
    let operations = strings(&response["properties"]["operation"]["enum"]);
    assert!(operations.contains(&"alertDecide".to_owned()));
    let results = response["properties"]["result"]["oneOf"]
        .as_array()
        .expect("policy response result oneOf");
    assert!(
        results.iter().any(|case| {
            case["required"].as_array().is_some_and(|required| {
                strings(&Value::Array(required.clone()))
                    == ["state".to_owned(), "events".to_owned()]
            })
        }),
        "policy-response 缺 alertDecide {{state, events}}"
    );
}
