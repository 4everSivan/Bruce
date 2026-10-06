//! 进程内采集编排 —— 经 `collector_bridge::run_bytes` 直调采集引擎,
//! 与 mac 侧 stdio Bridge 走完全相同的请求契约 (仅 capabilities 限本地)。
//!
//! 红线: 严禁在模块初始化阶段触发采集; 采集仅由用户刷新/调度显式发起。

use chrono::{Local, SecondsFormat};
use collector_bridge::run_bytes;
use collector_domain::{BridgeRequest, BridgeResponse, BridgeTimeouts, BRIDGE_SCHEMA_VERSION};
use serde_json::{Map, Value};

/// 本地会话扫描 + 本地定价; 出站额度查询 (externalQuotas) 随 T03 接入。
const LOCAL_CAPABILITIES: [&str; 2] = ["localSessions", "localPricing"];

/// 构造一次本地采集请求 (窗口 14 日, 本地时区)。
pub fn build_local_request(now: chrono::DateTime<Local>) -> BridgeRequest {
    let timezone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".to_owned());
    let mut context = Map::new();
    context.insert(
        "now".to_owned(),
        Value::String(now.to_rfc3339_opts(SecondsFormat::Secs, true)),
    );
    context.insert("timezone".to_owned(), Value::String(timezone));
    context.insert("days".to_owned(), Value::from(14));
    context.insert(
        "capabilities".to_owned(),
        Value::Array(
            LOCAL_CAPABILITIES
                .iter()
                .map(|item| Value::from(*item))
                .collect(),
        ),
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
        credentials: Map::new(),
    }
}

/// 进程内执行一次采集, 返回标准 BridgeResponse (artifact schema 与 mac 一致)。
pub fn run_local_collection() -> Result<BridgeResponse, String> {
    let request = build_local_request(Local::now());
    let input = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    Ok(run_bytes(&input))
}

#[cfg(test)]
mod tests {
    use super::*;
    use collector_domain::BRIDGE_SCHEMA_VERSION;

    #[test]
    fn local_request_satisfies_bridge_contract() {
        let request = build_local_request(Local::now());
        assert_eq!(request.schema_version, BRIDGE_SCHEMA_VERSION);
        assert_eq!(request.module, "agent-usage");
        assert!(uuid::Uuid::parse_str(&request.run_id).is_ok());
        assert!(request.timeouts.local_scan_seconds <= 300.0);
        assert!(request.timeouts.module_seconds <= 600.0);
        assert!(request.credentials.is_empty(), "本地采集不携带任何凭证");
        let capabilities = request.context["capabilities"].as_array().unwrap();
        assert!(
            capabilities
                .iter()
                .all(|value| LOCAL_CAPABILITIES.contains(&value.as_str().unwrap())),
            "capabilities 必须限定在本地能力集合内"
        );
    }

    #[test]
    fn local_collection_returns_bridge_response_shape() {
        // CI/真机无 agent 数据时也必须产出同 schema 的空采集响应。
        let response = run_local_collection().expect("本地采集不应失败");
        assert!(
            response.artifact.is_some() || !response.diagnostics.is_empty(),
            "BridgeResponse 必须携带 artifact 或诊断"
        );
    }
}
