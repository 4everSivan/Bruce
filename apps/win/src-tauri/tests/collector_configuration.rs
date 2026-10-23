use std::collections::BTreeMap;

use bruce_win_lib::{
    collector::build_configured_request,
    credentials::CredentialPayloads,
    settings::{sync_enabled_providers, AppSettings, SubscriptionProviderState},
};
use serde_json::json;

#[test]
fn consent_filters_providers_and_private_codex_tokens_never_cross_bridge() {
    let credentials: CredentialPayloads = serde_json::from_value(json!({
        "kimiQuotaAccounts":{"a":{"api_key":"test-key"}},
        "deepseekQuotaAccounts":{"b":{"api_key":"test-key"}},
        "codexQuotaAccounts":{"c":{"access_token":"access-fixture","refresh_token":"private-fixture","expiry":"2030-01-01T00:00:00Z","display_name":"C"}}
    })).unwrap();
    let mut settings = AppSettings::default();
    let request = build_configured_request(chrono::Local::now(), &credentials, &settings);
    assert!(request.credentials.is_empty());
    assert!(!request.context["capabilities"]
        .as_array()
        .unwrap()
        .contains(&json!("externalQuotas")));
    settings.consent_version = 1;
    settings.enabled_providers = vec!["codex".into(), "kimi".into()];
    settings.usage_enabled = false;
    settings
        .pricing_overrides
        .insert("k3".into(), json!({"inputPricePerMillion":0.25}));
    let request = build_configured_request(chrono::Local::now(), &credentials, &settings);
    assert!(!request.credentials.contains_key("deepseekQuotaAccounts"));
    assert_eq!(request.context["codexQuotaAccountOrder"], json!(["c"]));
    assert_eq!(
        request.credentials["codexQuotaAccounts"]["c"],
        json!({"access_token":"access-fixture","display_name":"C"})
    );
    assert_eq!(
        request.context["pricingOverrides"]["k3"]["inputPricePerMillion"],
        0.25
    );
    assert!(!request.context["capabilities"]
        .as_array()
        .unwrap()
        .contains(&json!("localSessions")));
    assert!(!serde_json::to_string(&request)
        .unwrap()
        .contains("private-fixture"));
}

/// C089 / C090: 移出已添加集合 (或验证失败禁用) 后, 即使磁盘上仍有该 Provider 的凭据,
/// 采集装配也不得再带上它 —— 启用集合是 `subscription_providers` 的派生投影。
#[test]
fn removed_or_disabled_provider_is_never_assembled_for_collection() {
    let credentials: CredentialPayloads = serde_json::from_value(json!({
        "kimiQuotaAccounts":{"a":{"api_key":"test-key"}},
        "clineQuotaAccounts":{"b":{"api_key":"test-key-0000000001"}},
        "deepseekQuotaAccounts":{"c":{"api_key":"test-key"}}
    }))
    .unwrap();
    let enabled = SubscriptionProviderState {
        enabled: true,
        verification_status: "ok".to_owned(),
        ..SubscriptionProviderState::default()
    };
    let mut settings = AppSettings {
        consent_version: 1,
        // 移除前: kimi / cline / deepseek 均在启用集合内 (未迁移的升级用户)。
        enabled_providers: vec!["kimi".into(), "cline".into(), "deepseek".into()],
        ..AppSettings::default()
    };
    // 移除 kimi (移出已添加集合), deepseek 验证失败被禁用, cline 保持启用。
    settings.subscription_providers = Some(BTreeMap::from([
        ("cline".to_owned(), enabled.clone()),
        (
            "deepseek".to_owned(),
            SubscriptionProviderState {
                enabled: false,
                verification_status: "failed".to_owned(),
                ..enabled
            },
        ),
    ]));
    sync_enabled_providers(&mut settings);
    let request = build_configured_request(chrono::Local::now(), &credentials, &settings);
    assert!(request.credentials.contains_key("clineQuotaAccounts"));
    assert!(
        !request.credentials.contains_key("kimiQuotaAccounts"),
        "已移除的 Provider 不得再被查询"
    );
    assert!(
        !request.credentials.contains_key("deepseekQuotaAccounts"),
        "验证失败被禁用的 Provider 不得再被查询"
    );
}

#[test]
fn configured_local_request_crosses_real_bridge_with_price_overrides() {
    let mut settings = AppSettings {
        usage_enabled: false,
        ..Default::default()
    };
    settings
        .pricing_overrides
        .insert("k3".into(), json!({"outputPricePerMillion":0.5}));
    let request =
        build_configured_request(chrono::Local::now(), &CredentialPayloads::new(), &settings);
    let response = collector_bridge::run_bytes(&serde_json::to_vec(&request).unwrap());
    assert!(response.artifact.is_some(), "{:?}", response.diagnostics);
}
