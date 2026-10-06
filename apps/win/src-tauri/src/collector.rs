//! 进程内采集编排 —— 经 `collector_bridge::run_bytes` 直调采集引擎,
//! 与 mac 侧 stdio Bridge 走完全相同的请求契约 (仅 capabilities 限本地)。
//!
//! 红线: 严禁在模块初始化阶段触发采集; 采集仅由用户刷新/调度显式发起。

use chrono::{Local, SecondsFormat};
use collector_bridge::run_bytes;
use collector_domain::{BridgeRequest, BridgeResponse, BridgeTimeouts, BRIDGE_SCHEMA_VERSION};
use serde_json::{Map, Value};

use crate::credentials::CredentialPayloads;

/// 本地会话扫描 + 本地定价; 出站额度 (externalQuotas) 仅在存在凭证时启用。
const LOCAL_CAPABILITIES: [&str; 2] = ["localSessions", "localPricing"];
const EXTERNAL_QUOTAS_CAPABILITY: &str = "externalQuotas";

/// 构造一次采集请求 (窗口 14 日, 本地时区); 非空凭证启用出站额度查询。
pub fn build_local_request(
    now: chrono::DateTime<Local>,
    credentials: &CredentialPayloads,
) -> BridgeRequest {
    let timezone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".to_owned());
    let mut context = Map::new();
    context.insert(
        "now".to_owned(),
        Value::String(now.to_rfc3339_opts(SecondsFormat::Secs, true)),
    );
    context.insert("timezone".to_owned(), Value::String(timezone));
    context.insert("days".to_owned(), Value::from(14));
    let mut capabilities: Vec<String> = LOCAL_CAPABILITIES
        .iter()
        .map(|item| (*item).to_owned())
        .collect();
    let credentials_value = if credentials.is_empty() {
        Map::new()
    } else {
        capabilities.push(EXTERNAL_QUOTAS_CAPABILITY.to_owned());
        credentials
            .iter()
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<Map<String, Value>>()
    };
    context.insert(
        "capabilities".to_owned(),
        Value::Array(capabilities.into_iter().map(Value::String).collect()),
    );
    BridgeRequest {
        schema_version: BRIDGE_SCHEMA_VERSION,
        run_id: uuid::Uuid::new_v4().to_string(),
        module: "agent-usage".to_owned(),
        timeouts: BridgeTimeouts {
            local_scan_seconds: 120.0,
            external_request_seconds: 30.0,
            module_seconds: 150.0,
        },
        context,
        credentials: credentials_value,
    }
}

/// 进程内执行一次采集, 返回标准 BridgeResponse (artifact schema 与 mac 一致)。
pub fn run_local_collection(credentials: CredentialPayloads) -> Result<BridgeResponse, String> {
    let request = build_local_request(Local::now(), &credentials);
    let input = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    Ok(run_bytes(&input))
}

#[cfg(test)]
mod tests {
    use super::*;
    use collector_domain::BRIDGE_SCHEMA_VERSION;

    #[test]
    fn local_request_satisfies_bridge_contract() {
        let request = build_local_request(Local::now(), &CredentialPayloads::new());
        assert_eq!(request.schema_version, BRIDGE_SCHEMA_VERSION);
        assert_eq!(request.module, "agent-usage");
        assert!(uuid::Uuid::parse_str(&request.run_id).is_ok());
        assert!(request.timeouts.local_scan_seconds <= 300.0);
        assert!(request.timeouts.module_seconds <= 600.0);
        assert!(request.credentials.is_empty(), "无凭证时不携带任何凭证");
        let capabilities = request.context["capabilities"].as_array().unwrap();
        assert!(
            capabilities
                .iter()
                .all(|value| LOCAL_CAPABILITIES.contains(&value.as_str().unwrap())),
            "无凭证时 capabilities 必须限定在本地能力集合内"
        );
    }

    #[test]
    fn credentials_enable_external_quotas_and_injection() {
        let mut credentials = CredentialPayloads::new();
        credentials.insert(
            "kimiQuotaAccounts".to_owned(),
            serde_json::json!([{ "accountID": "a1", "apiKey": "sk-test" }]),
        );
        let request = build_local_request(Local::now(), &credentials);
        let capabilities = request.context["capabilities"].as_array().unwrap();
        assert!(capabilities.iter().any(|value| value == "externalQuotas"));
        assert_eq!(
            request.credentials["kimiQuotaAccounts"],
            credentials["kimiQuotaAccounts"]
        );
    }

    #[test]
    fn local_collection_returns_bridge_response_shape() {
        // CI/真机无 agent 数据时也必须产出同 schema 的空采集响应;
        // 缓存落在应用自身可重建目录, 幂等无害。
        let response = run_local_collection(CredentialPayloads::new()).expect("本地采集不应失败");
        assert!(
            response.artifact.is_some() || !response.diagnostics.is_empty(),
            "BridgeResponse 必须携带 artifact 或诊断"
        );
    }
}
