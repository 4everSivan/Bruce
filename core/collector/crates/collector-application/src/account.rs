use collector_domain::{BridgeRequest, Diagnostic};
use collector_provider::{
    codex_service_id, resolve_service_catalog, AccountDescriptor, CatalogInput, ServiceDescriptor,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Clone)]
pub(crate) struct AccountPlan {
    pub service: ServiceDescriptor,
    pub account_id: Option<String>,
    pub credential: Option<Value>,
}

// C049: 前缀 / 凭据字段一律从 collector-provider 的目录表派生,
// 不再在本文件复写字符串 (原实现手工维护两份映射且无编译期约束)。
fn catalog_entry(app: &str) -> Option<collector_provider::CatalogEntry> {
    collector_provider::catalog_entries()
        .into_iter()
        .find(|entry| entry.app == app)
}

fn account_field(app: &str) -> Option<&'static str> {
    catalog_entry(app).map(|entry| entry.credential_field)
}

fn account_prefix(app: &str) -> Option<&'static str> {
    catalog_entry(app).map(|entry| entry.prefix)
}

fn display_name(value: &Value) -> Option<String> {
    value
        .as_object()
        .and_then(|object| object.get("display_name"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn provider_accounts<'a>(
    credentials: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Option<&'a serde_json::Map<String, Value>> {
    credentials.get(field).and_then(Value::as_object)
}

fn enabled_official(credentials: &serde_json::Map<String, Value>) -> BTreeSet<String> {
    let mut enabled = BTreeSet::new();
    let Some(meta) = credentials.get("providerMeta").and_then(Value::as_object) else {
        return enabled;
    };
    for app in ["claude", "grok"] {
        if meta
            .get(app)
            .and_then(Value::as_object)
            .and_then(|value| value.get("enabled"))
            .and_then(Value::as_bool)
            == Some(true)
        {
            enabled.insert(app.to_owned());
        }
    }
    enabled
}

pub(crate) fn build_account_plan(request: &BridgeRequest) -> Result<Vec<AccountPlan>, Diagnostic> {
    let mut catalog = CatalogInput {
        accounts: BTreeMap::new(),
        enabled_official: enabled_official(&request.credentials),
    };
    // 遍历目录表 (单一来源), 不再依赖本文件的第二份 app->字段映射。
    for entry in collector_provider::catalog_entries() {
        let Some(accounts) = provider_accounts(&request.credentials, entry.credential_field) else {
            continue;
        };
        let descriptors = accounts
            .iter()
            .map(|(account_id, payload)| AccountDescriptor {
                account_id: account_id.clone(),
                display_name: display_name(payload),
            })
            .collect::<Vec<_>>();
        catalog.accounts.insert(entry.app.to_owned(), descriptors);
    }
    let services = resolve_service_catalog(&catalog).map_err(|error| {
        Diagnostic::new(
            "PROVIDER_INVALID_CATALOG",
            "provider",
            "catalog",
            error.to_string(),
            false,
        )
    })?;
    let mut plans = services
        .into_iter()
        .map(|service| {
            let account_id = account_prefix(&service.app)
                .and_then(|prefix| service.id.strip_prefix(prefix))
                .map(str::to_owned);
            AccountPlan {
                credential: credential_for_service(&request.credentials, &service),
                account_id,
                service,
            }
        })
        .collect::<Vec<_>>();
    plans.extend(build_codex_account_plans(request)?);
    // C062: 额度仍新鲜或 429 冷却中的 provider 不发起本轮 HTTP 查询.
    let skip_apps = quota_skip_apps(&request.context)?;
    plans.retain(|plan| !skip_apps.contains(&plan.service.app));
    Ok(plans)
}

fn quota_skip_apps(
    context: &serde_json::Map<String, Value>,
) -> Result<BTreeSet<String>, Diagnostic> {
    let Some(value) = context.get("quotaSkipProviders") else {
        return Ok(BTreeSet::new());
    };
    let Some(items) = value.as_array() else {
        return Err(Diagnostic::new(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "context",
            "quotaSkipProviders 必须是字符串数组",
            false,
        ));
    };
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| {
                Diagnostic::new(
                    "BRIDGE_INVALID_REQUEST",
                    "protocol",
                    "context",
                    "quotaSkipProviders 必须是字符串数组",
                    false,
                )
            })
        })
        .collect()
}

pub(crate) fn build_codex_account_plans(
    request: &BridgeRequest,
) -> Result<Vec<AccountPlan>, Diagnostic> {
    let Some(raw_accounts) = request.credentials.get("codexQuotaAccounts") else {
        return Ok(Vec::new());
    };
    let Some(accounts) = raw_accounts.as_object() else {
        return Err(Diagnostic::new(
            "BRIDGE_INVALID_REQUEST",
            "security",
            "credentials",
            "codexQuotaAccounts 必须是 JSON object",
            false,
        ));
    };
    if accounts.is_empty() {
        return Ok(Vec::new());
    }
    let Some(order) = request
        .context
        .get("codexQuotaAccountOrder")
        .and_then(Value::as_array)
    else {
        return Err(Diagnostic::new(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "context",
            "codexQuotaAccounts 必须携带 codexQuotaAccountOrder",
            false,
        ));
    };
    let account_order = order
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| {
            Diagnostic::new(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "context",
                "codexQuotaAccountOrder 必须是字符串数组",
                false,
            )
        })?;
    let order_set = account_order.iter().collect::<BTreeSet<_>>();
    let account_set = accounts.keys().collect::<BTreeSet<_>>();
    if order_set.len() != account_order.len() || order_set != account_set {
        return Err(Diagnostic::new(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "context",
            "codexQuotaAccountOrder 与 codexQuotaAccounts 不一致",
            false,
        ));
    }
    Ok(account_order
        .into_iter()
        .filter_map(|account_id| {
            let payload = accounts.get(&account_id)?.clone();
            let fallback = account_id.chars().take(8).collect::<String>();
            let display_name =
                display_name(&payload).unwrap_or_else(|| format!("Codex · {fallback}"));
            Some(AccountPlan {
                service: ServiceDescriptor {
                    id: codex_service_id(&account_id),
                    name: display_name,
                    app: "codex".to_owned(),
                    is_current: false,
                },
                account_id: Some(account_id),
                credential: Some(payload),
            })
        })
        .collect())
}

fn credential_for_service(
    credentials: &serde_json::Map<String, Value>,
    service: &ServiceDescriptor,
) -> Option<Value> {
    let field = account_field(&service.app)?;
    if let Some(prefix) = account_prefix(&service.app) {
        if let Some(account_id) = service.id.strip_prefix(prefix) {
            let payload = provider_accounts(credentials, field)?
                .get(account_id)?
                .clone();
            if matches!(service.app.as_str(), "opencode-go" | "claude" | "grok") {
                return payload
                    .as_object()
                    .and_then(|object| object.get("oauth"))
                    .cloned()
                    .or(Some(payload));
            }
            return Some(payload);
        }
    }
    let direct_field = match service.app.as_str() {
        "claude" => "claudeOAuth",
        "grok" => "grokOAuth",
        _ => return None,
    };
    credentials.get(direct_field).cloned()
}

#[cfg(test)]
mod tests {
    use super::build_account_plan;
    use collector_domain::BridgeRequest;
    use collector_provider::codex_service_id;
    use serde_json::json;

    #[test]
    fn account_plan_is_stable_and_unwraps_oauth_payloads() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {"capabilities": ["externalQuotas"]},
            "credentials": {
                "grokQuotaAccounts": {
                    "z": {"display_name": "Grok Z", "oauth": {"key": "secret"}},
                    "a": {"display_name": "Grok A", "oauth": {"key": "secret"}}
                },
                "providerMeta": {"claude": {"enabled": true}}
            }
        }))
        .unwrap();
        let plans = build_account_plan(&request).unwrap();
        assert_eq!(plans[0].service.id, "claude");
        assert_eq!(plans[1].service.id, "grok_a");
        assert_eq!(plans[1].credential.as_ref().unwrap()["key"], "secret");
        assert_eq!(plans[2].service.id, "grok_z");
    }

    #[test]
    fn codex_account_plan_uses_injected_order_and_hashed_service_ids() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "capabilities": ["externalQuotas"],
                "codexQuotaAccountOrder": ["acc-z", "acc-a"]
            },
            "credentials": {
                "codexQuotaAccounts": {
                    "acc-a": {
                        "display_name": "Codex · A",
                        "access_token": "fixture-a"
                    },
                    "acc-z": {
                        "display_name": "Codex · Z",
                        "access_token": "fixture-z"
                    }
                }
            }
        }))
        .unwrap();
        let plans = build_account_plan(&request).unwrap();
        assert_eq!(plans[0].service.id, codex_service_id("acc-z"));
        assert_eq!(plans[1].service.id, codex_service_id("acc-a"));
        assert_eq!(plans[0].account_id.as_deref(), Some("acc-z"));
        assert_eq!(
            plans[0].credential.as_ref().unwrap()["access_token"],
            "fixture-z"
        );
    }

    #[test]
    fn quota_skip_providers_filters_matching_apps() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "capabilities": ["externalQuotas"],
                "quotaSkipProviders": ["claude"]
            },
            "credentials": {
                "claudeQuotaAccounts": {
                    "acc": {
                        "display_name": "Claude",
                        "oauth": {"claudeAiOauth": {"accessToken": "tok"}}
                    }
                },
                "grokQuotaAccounts": {
                    "a": {"display_name": "Grok A", "oauth": {"key": "secret"}}
                },
                "providerMeta": {"claude": {"enabled": true}}
            }
        }))
        .unwrap();
        let plans = build_account_plan(&request).unwrap();
        assert!(plans.iter().all(|plan| plan.service.app != "claude"));
        assert!(plans.iter().any(|plan| plan.service.app == "grok"));
    }

    #[test]
    fn quota_skip_providers_rejects_non_string_items() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "capabilities": ["externalQuotas"],
                "quotaSkipProviders": [1]
            },
            "credentials": {}
        }))
        .unwrap();
        let error = build_account_plan(&request).unwrap_err();
        assert_eq!(error.code, "BRIDGE_INVALID_REQUEST");
    }
}
