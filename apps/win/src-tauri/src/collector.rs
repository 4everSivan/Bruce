//! 进程内采集编排 —— 经 `collector_bridge::run_bytes` 直调采集引擎,
//! 与 mac 侧 stdio Bridge 走完全相同的请求契约 (仅 capabilities 限本地)。
//!
//! 红线: 严禁在模块初始化阶段触发采集; 采集仅由用户刷新/调度显式发起。

use chrono::{Local, SecondsFormat};
use collector_bridge::run_bytes;
use collector_domain::{BridgeRequest, BridgeResponse, BridgeTimeouts, BRIDGE_SCHEMA_VERSION};
use serde_json::{Map, Value};

use crate::credentials::CredentialPayloads;
use crate::settings::AppSettings;

/// 本地会话扫描 + 本地定价; 出站额度 (externalQuotas) 仅在存在凭证时启用。
const LOCAL_CAPABILITIES: [&str; 2] = ["localSessions", "localPricing"];
const EXTERNAL_QUOTAS_CAPABILITY: &str = "externalQuotas";

/// 构造一次采集请求 (窗口 182 天对齐 mac CollectorRunInput 半年口径: 14 日柱状图
/// 由视图模型层 suffix 截取, 全量 daily 供热力图与按月聚合); 非空凭证启用出站额度。
pub fn build_local_request(
    now: chrono::DateTime<Local>,
    credentials: &CredentialPayloads,
) -> BridgeRequest {
    let timezone = iana_time_zone::get_timezone().unwrap_or_else(|_| "UTC".to_owned());
    let mut context = Map::new();
    // mac 事实源 (CollectorRunInput.swift:379) 显式携带 home, 采集端会话路径解析依赖它;
    // 非 UTF-8 路径下省略该字段 (采集端回落默认 home 解析)。
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .and_then(|value| value.into_string().ok())
        .map(Value::from);
    if let Some(home) = home {
        context.insert("home".to_owned(), home);
    }
    context.insert(
        "now".to_owned(),
        Value::String(now.to_rfc3339_opts(SecondsFormat::Secs, true)),
    );
    context.insert("timezone".to_owned(), Value::String(timezone));
    context.insert("days".to_owned(), Value::from(182));
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
    run_configured_collection(credentials, &AppSettings::default())
}

/// 应用入口统一消费配置；凭据存在并不等于用户已授权联网。
pub fn build_configured_request(
    now: chrono::DateTime<Local>,
    credentials: &CredentialPayloads,
    settings: &AppSettings,
) -> BridgeRequest {
    let mut filtered = CredentialPayloads::new();
    if settings.consent_version == 1 {
        for provider in &settings.enabled_providers {
            let field = match provider.as_str() {
                "kimi" => "kimiQuotaAccounts",
                "deepseek" => "deepseekQuotaAccounts",
                "volcengine" => "volcengineQuotaAccounts",
                "zhipu" => "zhipuQuotaAccounts",
                "claude" => "claudeQuotaAccounts",
                "grok" => "grokQuotaAccounts",
                "opencodeGo" => "opencodeGoQuotaAccounts",
                "codex" => "codexQuotaAccounts",
                "stepfun" => "stepfunQuotaAccounts",
                _ => continue,
            };
            if let Some(value) = credentials
                .get(field)
                .filter(|v| v.as_object().is_some_and(|o| !o.is_empty()))
            {
                let value = if provider == "codex" {
                    // Refresh/id tokens are app-private and rejected by the shared Bridge boundary.
                    Value::Object(
                        value
                            .as_object()
                            .unwrap()
                            .iter()
                            .filter(|(_, raw)| raw["authorization_state"] != "reauthRequired")
                            .map(|(id, raw)| {
                                let account = ["access_token", "display_name"]
                                    .iter()
                                    .filter_map(|key| {
                                        raw.get(*key).map(|v| ((*key).to_owned(), v.clone()))
                                    })
                                    .collect();
                                (id.clone(), Value::Object(account))
                            })
                            .collect(),
                    )
                } else {
                    value.clone()
                };
                if value.as_object().is_some_and(|o| !o.is_empty()) {
                    filtered.insert(field.to_owned(), value);
                }
            }
            if ["claude", "grok"].contains(&provider.as_str()) {
                let field = if provider == "claude" {
                    "claudeOAuth"
                } else {
                    "grokOAuth"
                };
                if let Some(value) = credentials.get(field) {
                    filtered.insert(field.into(), value.clone());
                }
                // Official account discovery is explicitly enabled only for a configured provider.
                let configured = filtered.contains_key(field)
                    || filtered.contains_key(&format!("{provider}QuotaAccounts"));
                if configured {
                    filtered
                        .entry("providerMeta".into())
                        .or_insert_with(|| serde_json::json!({}))[provider] =
                        serde_json::json!({"enabled":true});
                }
            }
        }
    }
    let mut request = build_local_request(now, &filtered);
    if !settings.usage_enabled {
        request.context["capabilities"]
            .as_array_mut()
            .unwrap()
            .retain(|v| v != "localSessions");
    }
    if let Some(accounts) = filtered
        .get("codexQuotaAccounts")
        .and_then(Value::as_object)
    {
        request.context.insert(
            "codexQuotaAccountOrder".into(),
            Value::Array(accounts.keys().map(|s| Value::String(s.clone())).collect()),
        );
    }
    if !settings.pricing_overrides.is_empty() {
        request.context.insert(
            "pricingOverrides".into(),
            serde_json::to_value(&settings.pricing_overrides).unwrap_or_default(),
        );
    }
    request
}

pub fn run_configured_collection(
    credentials: CredentialPayloads,
    settings: &AppSettings,
) -> Result<BridgeResponse, String> {
    let request = build_configured_request(Local::now(), &credentials, settings);
    let input = serde_json::to_vec(&request).map_err(|error| error.to_string())?;
    Ok(run_bytes(&input))
}

/// OAuth challenge recovery queries only Codex quotas; local sessions and other providers are not repeated.
pub fn run_codex_retry(
    credentials: CredentialPayloads,
    settings: &AppSettings,
) -> Result<BridgeResponse, String> {
    let mut settings = settings.clone();
    settings.enabled_providers = vec!["codex".into()];
    settings.usage_enabled = false;
    let mut request = build_configured_request(Local::now(), &credentials, &settings);
    request
        .context
        .insert("codexQuotaRetryOnly".into(), Value::Bool(true));
    request
        .context
        .insert("capabilities".into(), serde_json::json!(["externalQuotas"]));
    if request.credentials.is_empty() {
        return Err("CODEX_RETRY_UNAUTHORIZED".into());
    }
    Ok(run_bytes(
        &serde_json::to_vec(&request).map_err(|_| "CODEX_RETRY_INVALID")?,
    ))
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
        // 禁用本机会话能力，单测绝不扫描真实用户目录或落真实缓存。
        let settings = AppSettings {
            usage_enabled: false,
            ..Default::default()
        };
        let response = run_configured_collection(CredentialPayloads::new(), &settings)
            .expect("本地采集不应失败");
        assert!(
            response.artifact.is_some() || !response.diagnostics.is_empty(),
            "BridgeResponse 必须携带 artifact 或诊断"
        );
    }
}
