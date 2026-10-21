//! C068: 订阅卡 Provider 定向刷新 (mac `RefreshScheduler.refreshSubscription` 同契约) 与
//! Cline 凭证注入漏表的回归锁。全部为纯逻辑断言, 不触网、不扫描本机会话。

use bruce_win_lib::{
    collector::{build_configured_request, build_scoped_request, quota_credential_field},
    credentials::CredentialPayloads,
    runtime_core::{merge_scoped_snapshot, provider_of_id, SnapshotState},
    settings::{AppSettings, PROVIDERS},
};
use collector_domain::{BridgeResponse, ResponseStatus, BRIDGE_SCHEMA_VERSION};
use serde_json::{json, Value};

fn consented(providers: &[&str]) -> AppSettings {
    AppSettings {
        consent_version: 1,
        enabled_providers: providers.iter().map(|p| (*p).to_owned()).collect(),
        ..Default::default()
    }
}

fn credentials() -> CredentialPayloads {
    serde_json::from_value(json!({
        "kimiQuotaAccounts": {"k": {"api_key": "kimi-fixture"}},
        "clineQuotaAccounts": {"work": {"api_key": "cline-fixture", "display_name": "work"}},
        "claudeOAuth": {"accessToken": "claude-fixture"},
        "codexQuotaAccounts": {"c": {"access_token": "access-fixture", "refresh_token": "private-fixture", "display_name": "C"}}
    }))
    .unwrap()
}

#[test]
fn every_visible_provider_has_an_allowed_credential_field() {
    for provider in PROVIDERS {
        let field = quota_credential_field(provider)
            .unwrap_or_else(|| panic!("{provider} 缺少凭证字段映射 (该家额度会被静默跳过)"));
        assert!(
            collector_bridge::ALLOWED_CREDENTIAL_FIELDS.contains(&field),
            "{field} 不在 Bridge 凭证白名单内"
        );
    }
    assert_eq!(quota_credential_field("unknown"), None);
}

#[test]
fn full_collection_now_injects_cline_credentials() {
    // C068 前 build_configured_request 的 provider→字段表漏了 cline: 设置页可保存
    // Cline 凭证, 采集请求却从不携带, 看板永远拿不到 Cline 额度。
    let request =
        build_configured_request(chrono::Local::now(), &credentials(), &consented(&["cline"]));
    assert_eq!(
        request.credentials["clineQuotaAccounts"]["work"]["api_key"],
        "cline-fixture"
    );
    assert!(request.context["capabilities"]
        .as_array()
        .unwrap()
        .contains(&json!("externalQuotas")));
}

#[test]
fn scoped_request_carries_only_the_target_provider_and_quota_capability() {
    let settings = AppSettings {
        pricing_overrides: [("k3".to_owned(), json!({"inputPricePerMillion": 1.0}))].into(),
        ..consented(&["kimi", "cline", "codex", "claude"])
    };
    let request =
        build_scoped_request(chrono::Local::now(), &credentials(), &settings, "cline").unwrap();
    assert_eq!(request.schema_version, BRIDGE_SCHEMA_VERSION);
    assert_eq!(request.context["capabilities"], json!(["externalQuotas"]));
    assert_eq!(request.context["subscriptionQuotaOnly"], json!(true));
    assert_eq!(request.context["subscriptionProviders"], json!(["cline"]));
    assert_eq!(
        request.credentials.keys().collect::<Vec<_>>(),
        vec!["clineQuotaAccounts"],
        "只装配目标 Provider 凭证"
    );
    for absent in ["days", "pricingOverrides", "codexQuotaAccountOrder"] {
        assert!(
            request.context.get(absent).is_none(),
            "定向刷新不得携带 {absent}"
        );
    }

    // Codex 目标: account order 随凭证键携带, 私有 refresh token 不过 Bridge 边界
    let codex =
        build_scoped_request(chrono::Local::now(), &credentials(), &settings, "codex").unwrap();
    assert_eq!(codex.context["codexQuotaAccountOrder"], json!(["c"]));
    assert!(!serde_json::to_string(&codex)
        .unwrap()
        .contains("private-fixture"));

    // Claude 目标: OAuth 与官方账号发现开关 (providerMeta) 同步装配
    let claude =
        build_scoped_request(chrono::Local::now(), &credentials(), &settings, "claude").unwrap();
    assert_eq!(
        claude.credentials["claudeOAuth"]["accessToken"],
        "claude-fixture"
    );
    assert_eq!(
        claude.credentials["providerMeta"]["claude"]["enabled"],
        json!(true)
    );
}

#[test]
fn scoped_request_fails_closed() {
    let now = chrono::Local::now();
    let cases = [
        (
            AppSettings {
                consent_version: 0,
                ..consented(&["kimi"])
            },
            "kimi",
            "SCOPED_REFRESH_UNAUTHORIZED",
        ),
        (
            consented(&["kimi"]),
            "jev",
            "SCOPED_REFRESH_UNKNOWN_PROVIDER",
        ),
        (consented(&["kimi"]), "cline", "SCOPED_REFRESH_DISABLED"),
        (
            consented(&["deepseek"]),
            "deepseek",
            "SCOPED_REFRESH_UNCONFIGURED",
        ),
    ];
    for (settings, provider, code) in cases {
        let error = build_scoped_request(now, &credentials(), &settings, provider).unwrap_err();
        assert_eq!(error, code, "provider={provider}");
    }
}

#[test]
fn section_ids_normalize_to_provider_keys() {
    for (id, provider) in [
        ("cline", "cline"),
        ("zhipu_9be91cf0", "zhipu"),
        ("deepseek_sk-8425d", "deepseek"),
        ("codex_083e86578ca407aa", "codex"),
        ("kimi_coding", "kimi"),
        ("opencode_go_main", "opencodeGo"),
        ("stepfun_cfc5d7b3", "stepfun"),
    ] {
        assert_eq!(provider_of_id(id), provider, "{id}");
    }
}

fn previous_artifact() -> Value {
    json!({
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-10-20T08:00:00+08:00",
        "agents": [{"id": "claude-code", "name": "Claude Code", "status": "ok", "note": "", "todayCostUsd": null,
            "today": {"input": 1, "output": 1, "cacheRead": 0, "cacheCreation": 0, "total": 2},
            "daily": [], "hours": []}],
        "totalCostUsd": 1.25,
        "services": [
            {"id": "kimi_coding", "name": "Kimi", "status": "ok", "freshness": "fresh",
             "capturedAt": "2026-10-20T08:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 10}]},
            {"id": "cline_work", "name": "Cline · work", "status": "ok", "freshness": "fresh",
             "capturedAt": "2026-10-20T08:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 40}]},
            {"id": "cline_gone", "name": "Cline · gone", "status": "ok", "freshness": "fresh",
             "capturedAt": "2026-10-20T08:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 5}]}
        ]
    })
}

fn scoped_round(services: Value) -> Value {
    json!({
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-10-20T09:00:00+08:00",
        "agents": [], "totalCostUsd": null, "services": services
    })
}

fn service<'a>(artifact: &'a Value, id: &str) -> Option<&'a Value> {
    artifact["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == id)
}

#[test]
fn scoped_merge_replaces_only_the_target_provider() {
    let previous = previous_artifact();
    let round = scoped_round(json!([
        {"id": "cline_work", "name": "Cline · work", "status": "ok",
         "capturedAt": "2026-10-20T09:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 55}]}
    ]));
    let merged = merge_scoped_snapshot(Some(&previous), &round, "cline");
    // 非目标 Provider 与本机会话/成本保留上一份完整快照
    assert_eq!(
        service(&merged, "kimi_coding"),
        service(&previous, "kimi_coding")
    );
    assert_eq!(merged["agents"], previous["agents"]);
    assert_eq!(merged["totalCostUsd"], json!(1.25));
    // 目标成功: 新窗口 + fresh; 本轮未返回的已断开账号不从历史复活
    let work = service(&merged, "cline_work").unwrap();
    assert_eq!(work["windows"][0]["usedPercent"], json!(55));
    assert_eq!(work["freshness"], "fresh");
    assert!(service(&merged, "cline_gone").is_none());
    assert_eq!(merged["generatedAt"], "2026-10-20T09:00:00+08:00");
}

#[test]
fn scoped_merge_keeps_qualified_old_windows_when_the_target_fails() {
    let previous = previous_artifact();
    let round = scoped_round(json!([
        {"id": "cline_work", "name": "Cline · work", "status": "error", "note": "HTTP 500", "windows": []},
        {"id": "cline_new", "name": "Cline · new", "status": "error", "windows": []}
    ]));
    let merged = merge_scoped_snapshot(Some(&previous), &round, "cline");
    let work = service(&merged, "cline_work").unwrap();
    assert_eq!(
        work["freshness"], "stale",
        "有合格旧值: 借用旧窗口并标 stale"
    );
    assert_eq!(work["windows"][0]["usedPercent"], json!(40));
    assert_eq!(work["status"], "error", "失败状态如实保留, 不伪装成功");
    let new = service(&merged, "cline_new").unwrap();
    assert_eq!(new["freshness"], "unavailable", "无合格历史: unavailable");
}

#[test]
fn scoped_merge_without_previous_snapshot_has_no_agents() {
    let round =
        scoped_round(json!([{"id": "kimi_coding", "name": "Kimi", "status": "ok", "windows": []}]));
    let merged = merge_scoped_snapshot(None, &round, "kimi");
    assert_eq!(merged["agents"], json!([]));
    assert_eq!(merged["totalCostUsd"], Value::Null);
}

fn response(artifact: Option<Value>, status: ResponseStatus) -> BridgeResponse {
    BridgeResponse {
        schema_version: BRIDGE_SCHEMA_VERSION,
        run_id: "scoped-test".into(),
        generated_at: "2026-10-20T09:00:00+08:00".into(),
        status,
        artifact,
        credential_updates: vec![],
        credential_challenges: vec![],
        diagnostics: vec![],
    }
}

#[test]
fn applying_a_scoped_response_leaves_global_state_untouched() {
    let mut state: SnapshotState = serde_json::from_value(json!({
        "artifact": previous_artifact(), "phase": "partial",
        "lastSuccessAt": "2026-10-19T08:00:00+08:00", "error": "COLLECTION_PARTIAL", "diagnostics": ["PROVIDER_RATE_LIMIT"]
    }))
    .unwrap();
    let round = scoped_round(json!([
        {"id": "kimi_coding", "name": "Kimi", "status": "ok", "capturedAt": "2026-10-20T09:00:00+08:00",
         "windows": [{"label": "5h", "usedPercent": 70}]}
    ]));
    state
        .apply_scoped_response(&response(Some(round), ResponseStatus::Success), "kimi")
        .unwrap();
    // 定向刷新不代表本机会话已更新: 全局 phase / lastSuccessAt / 错误码沿用全量采集
    assert_eq!(state.phase, "partial");
    assert_eq!(
        state.last_success_at.as_deref(),
        Some("2026-10-19T08:00:00+08:00")
    );
    assert_eq!(state.error.as_deref(), Some("COLLECTION_PARTIAL"));
    let artifact = state.artifact().unwrap();
    assert_eq!(
        service(artifact, "kimi_coding").unwrap()["windows"][0]["usedPercent"],
        json!(70)
    );
    assert!(service(artifact, "cline_work").is_some());

    // Bridge 整体失败: 只把目标 Provider 的合格旧值降级 stale, 其他 Provider 不动
    let error = state
        .apply_scoped_response(&response(None, ResponseStatus::Error), "cline")
        .unwrap_err();
    assert_eq!(error, "SCOPED_REFRESH_FAILED");
    let artifact = state.artifact().unwrap();
    assert_eq!(
        service(artifact, "cline_work").unwrap()["freshness"],
        "stale"
    );
    assert_eq!(
        service(artifact, "kimi_coding").unwrap()["freshness"],
        "fresh"
    );
}

#[test]
fn panel_sections_carry_the_normalized_provider_for_known_providers_only() {
    let mut artifact = previous_artifact();
    artifact["services"].as_array_mut().unwrap().extend([
        json!({"id": "opencode_go_main", "name": "OpenCode GO", "status": "ok",
               "capturedAt": "2026-10-20T08:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 3}]}),
        json!({"id": "mystery_x", "name": "Mystery", "status": "ok",
               "capturedAt": "2026-10-20T08:00:00+08:00", "windows": [{"label": "5h", "usedPercent": 3}]}),
    ]);
    let state: SnapshotState =
        serde_json::from_value(json!({"artifact": artifact, "phase": "fresh"})).unwrap();
    let mut enabled: Vec<String> = PROVIDERS.iter().map(|p| (*p).to_owned()).collect();
    enabled.push("mystery".into());
    let now = chrono::DateTime::parse_from_rfc3339("2026-10-20T09:00:00+08:00").unwrap();
    let panel = state.panel_json(now, true, &enabled, &[]);
    let providers: Vec<(String, Option<String>)> = panel["subscription"]["sections"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            (
                s["id"].as_str().unwrap().to_owned(),
                s.get("provider").and_then(Value::as_str).map(str::to_owned),
            )
        })
        .collect();
    for (id, provider) in &providers {
        match id.as_str() {
            "kimi_coding" => assert_eq!(provider.as_deref(), Some("kimi")),
            "cline" => assert_eq!(provider.as_deref(), Some("cline"), "多账号分组 section"),
            "opencode_go_main" => assert_eq!(provider.as_deref(), Some("opencodeGo")),
            other => assert!(provider.is_none(), "未知 section {other} 不附 provider"),
        }
    }
    assert!(providers.iter().any(|(id, _)| id == "opencode_go_main"));
}
