use bruce_win_lib::{
    collector::build_configured_request, credentials::CredentialPayloads, settings::AppSettings,
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
