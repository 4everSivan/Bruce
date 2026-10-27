use collector_domain::{BridgeRequest, Diagnostic};
use collector_provider::{
    catalog_entries, catalog_entry_for_app, codex_service_id, resolve_service_catalog,
    AccountDescriptor, CatalogInput, ServiceDescriptor,
};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

const CODEX_QUOTA_ACCOUNT_MAX: usize = 64;
const CODEX_QUOTA_ACCOUNT_ID_MAX: usize = 256;
const CODEX_QUOTA_DISPLAY_NAME_MAX: usize = 256;
const CODEX_QUOTA_ACCESS_TOKEN_MAX: usize = 8192;

#[derive(Debug, Clone)]
pub(crate) struct AccountPlan {
    pub service: ServiceDescriptor,
    pub account_id: Option<String>,
    pub credential: Option<Value>,
}

// C049 / C048: 前缀 / 凭据字段 / 凭据需求一律从 collector-provider 的目录表派生,
// 不再在本文件复写字符串。
fn account_prefix(app: &str) -> Option<&'static str> {
    catalog_entry_for_app(app).map(|entry| entry.prefix)
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
    for entry in catalog_entries()
        .into_iter()
        .filter(|entry| entry.direct_credential_field.is_some())
    {
        if meta
            .get(entry.app)
            .and_then(Value::as_object)
            .and_then(|value| value.get("enabled"))
            .and_then(Value::as_bool)
            == Some(true)
        {
            enabled.insert(entry.app.to_owned());
        }
    }
    enabled
}

fn account_protocol_error(code: &str, message: &str) -> Diagnostic {
    Diagnostic::new(code, "protocol", "request", message, false)
}

/// C048: 账户计划专属语义校验 (从 collector-bridge 下沉至 account 模块)。
pub(crate) fn validate_account_request(request: &BridgeRequest) -> Result<(), Diagnostic> {
    let accounts = request.credentials.get("codexQuotaAccounts");
    let order = request.context.get("codexQuotaAccountOrder");
    if let Some(retry_only) = request.context.get("codexQuotaRetryOnly") {
        if !retry_only.is_boolean() {
            return Err(account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaRetryOnly 必须是布尔值",
            ));
        }
    }
    let Some(accounts) = accounts else {
        if order.is_some() {
            return Err(account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccountOrder 必须携带 codexQuotaAccounts",
            ));
        }
        return Ok(());
    };
    let Some(accounts) = accounts.as_object() else {
        return Err(account_protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 必须是 JSON object",
        ));
    };
    if accounts.is_empty() || accounts.len() > CODEX_QUOTA_ACCOUNT_MAX {
        return Err(account_protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 数量无效",
        ));
    }
    for (account_id, payload) in accounts {
        if account_id.is_empty()
            || account_id.len() > CODEX_QUOTA_ACCOUNT_ID_MAX
            || account_id.chars().any(char::is_control)
        {
            return Err(account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts 账号 id 无效",
            ));
        }
        let Some(payload) = payload.as_object() else {
            return Err(Diagnostic::new(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "request",
                "codexQuotaAccounts 账号条目无效",
                false,
            ));
        };
        let allowed = BTreeSet::from(["access_token", "display_name"]);
        if payload.keys().any(|key| !allowed.contains(key.as_str())) {
            return Err(Diagnostic::new(
                "BRIDGE_CREDENTIAL_SCOPE",
                "security",
                "request",
                "codexQuotaAccounts 账号条目包含不允许的字段",
                false,
            ));
        }
        let access_token = payload
            .get("access_token")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                account_protocol_error(
                    "BRIDGE_INVALID_REQUEST",
                    "codexQuotaAccounts 缺少 access_token",
                )
            })?;
        if access_token.len() > CODEX_QUOTA_ACCESS_TOKEN_MAX {
            return Err(account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts access_token 超过长度上限",
            ));
        }
        let display_name = payload
            .get("display_name")
            .and_then(Value::as_str)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| {
                account_protocol_error(
                    "BRIDGE_INVALID_REQUEST",
                    "codexQuotaAccounts 缺少 display_name",
                )
            })?;
        if display_name.len() > CODEX_QUOTA_DISPLAY_NAME_MAX {
            return Err(account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccounts display_name 超过长度上限",
            ));
        }
    }
    let Some(order) = order.and_then(Value::as_array) else {
        return Err(account_protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccounts 必须携带 codexQuotaAccountOrder",
        ));
    };
    if order.is_empty() || order.len() > CODEX_QUOTA_ACCOUNT_MAX {
        return Err(account_protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccountOrder 数量无效",
        ));
    }
    let order = order
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| {
            account_protocol_error(
                "BRIDGE_INVALID_REQUEST",
                "codexQuotaAccountOrder 必须是字符串数组",
            )
        })?;
    let order_set = order.iter().collect::<BTreeSet<_>>();
    let account_set = accounts.keys().collect::<BTreeSet<_>>();
    if order_set.len() != order.len() || order_set != account_set {
        return Err(account_protocol_error(
            "BRIDGE_INVALID_REQUEST",
            "codexQuotaAccountOrder 与 codexQuotaAccounts 不一致",
        ));
    }
    Ok(())
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
    validate_account_request(request)?;
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
    let entry = catalog_entry_for_app(&service.app)?;
    if let Some(account_id) = service.id.strip_prefix(entry.prefix) {
        let payload = provider_accounts(credentials, entry.credential_field)?
            .get(account_id)?
            .clone();
        if entry.unwraps_oauth_payload {
            return payload
                .as_object()
                .and_then(|object| object.get("oauth"))
                .cloned()
                .or(Some(payload));
        }
        return Some(payload);
    }
    let direct_field = entry.direct_credential_field?;
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

    /// C122: 额度执行不再用 single-flight 去重, 依赖「每轮账号计划键唯一」——
    /// 目录账号来自 map 键、官方 provider 与多账号 id 不同形、Codex 顺序重复会被拒绝。
    #[test]
    fn account_plans_have_unique_account_keys() {
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
                "codexQuotaAccountOrder": ["acc-a", "acc-b"]
            },
            "credentials": {
                "kimiQuotaAccounts": {
                    "a": {"display_name": "Kimi A", "api_key": "fixture"},
                    "b": {"display_name": "Kimi B", "api_key": "fixture"}
                },
                "claudeQuotaAccounts": {
                    "x": {"display_name": "Claude X", "oauth": {"accessToken": "fixture"}}
                },
                "providerMeta": {"claude": {"enabled": true}},
                "codexQuotaAccounts": {
                    "acc-a": {"display_name": "Codex · A", "access_token": "fixture-a"},
                    "acc-b": {"display_name": "Codex · B", "access_token": "fixture-b"}
                }
            }
        }))
        .unwrap();
        let plans = build_account_plan(&request).unwrap();
        assert!(plans.len() >= 5, "{plans:?}");
        let keys = plans
            .iter()
            .map(|plan| {
                (
                    plan.service.app.clone(),
                    plan.account_id
                        .clone()
                        .unwrap_or_else(|| plan.service.id.clone()),
                )
            })
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(keys.len(), plans.len(), "账号计划键必须唯一");

        let mut duplicated = request.clone();
        duplicated.context.insert(
            "codexQuotaAccountOrder".to_owned(),
            json!(["acc-a", "acc-a"]),
        );
        assert!(
            build_account_plan(&duplicated).is_err(),
            "Codex 顺序重复必须拒绝"
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

    #[test]
    fn validate_account_request_enforces_codex_account_invariants() {
        let bad_order: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "codexQuotaAccountOrder": ["acc-a"]
            },
            "credentials": {}
        }))
        .unwrap();
        let err = super::validate_account_request(&bad_order).unwrap_err();
        assert_eq!(err.code, "BRIDGE_INVALID_REQUEST");

        let bad_scope: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "codexQuotaAccountOrder": ["acc-a"]
            },
            "credentials": {
                "codexQuotaAccounts": {
                    "acc-a": {
                        "display_name": "Codex A",
                        "access_token": "tok",
                        "unexpected_secret": "nope"
                    }
                }
            }
        }))
        .unwrap();
        let err = super::validate_account_request(&bad_scope).unwrap_err();
        assert_eq!(err.code, "BRIDGE_CREDENTIAL_SCOPE");
    }
}
