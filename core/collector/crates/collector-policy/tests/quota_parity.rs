//! 共享额度策略的裁判用例: 双端共用的 quota-policy-parity (门禁) 与
//! quota-carry-over-parity (回填) fixture, 以及 fixture 之外的入口语义。

use std::collections::BTreeSet;

use collector_policy::{
    annotate_provider, annotate_services, merge, merge_round, plan, provider_of_id, timestamp_iso,
    PlanInput, QuotaRunPolicy,
};
use serde_json::{json, Value};

const PLAN_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-policy-parity/cases.json");
const CARRY_OVER_FIXTURE: &str =
    include_str!("../../../../../tests/fixtures/quota-carry-over-parity/cases.json");

fn epoch_ms(text: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(text)
        .unwrap()
        .timestamp_millis()
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn plan_matches_shared_parity_fixture() {
    let fixture: Value = serde_json::from_str(PLAN_FIXTURE).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 18, "共享 fixture 覆盖全部判定分支");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let previous = json!({"services": case["services"].clone()});
        let enabled = strings(&case["enabledProviders"]);
        let policy = plan(&PlanInput {
            previous: Some(&previous),
            enabled_providers: Some(&enabled),
            now_ms: epoch_ms(case["now"].as_str().unwrap()),
            interval_secs: case["intervalSeconds"].as_i64().unwrap(),
            force_refresh: case["forceRefresh"].as_bool().unwrap(),
            bypass_cooldown: case["bypassCooldown"].as_bool().unwrap(),
            suppress_external_quotas: false,
        });
        let expected: QuotaRunPolicy = serde_json::from_value(case["expected"].clone()).unwrap();
        assert_eq!(policy, expected, "{name}");
    }
}

#[test]
fn merge_matches_shared_carry_over_fixture() {
    let fixture: Value = serde_json::from_str(CARRY_OVER_FIXTURE).unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 14, "共享 fixture 覆盖全部回填分支");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let previous = case["previous"]
            .as_array()
            .map(|services| json!({"services": services}));
        let current = json!({"schemaVersion": 1, "services": case["current"].clone()});
        let policy: QuotaRunPolicy = serde_json::from_value(case["policy"].clone()).unwrap();
        let merged = merge(
            previous.as_ref(),
            &current,
            &policy,
            epoch_ms(case["now"].as_str().unwrap()),
            case["intervalSeconds"].as_i64().unwrap(),
        );
        assert_eq!(merged["services"], case["expected"], "{name}");
        assert_eq!(merged["schemaVersion"], 1, "{name}: 保留 artifact 其余字段");
    }
}

fn service(id: &str, provider: &str, captured: &str) -> Value {
    json!({
        "id": id,
        "provider": provider,
        "status": "ok",
        "kind": "windows",
        "windows": [],
        "capturedAt": captured,
        "quotaAttemptedAt": captured,
    })
}

#[test]
fn suppressed_run_skips_every_previous_provider() {
    // C071: 锁屏抑制 = 本地专用 run 且上一份全部 provider 进入 skip (含未启用、Codex)。
    let previous = json!({"services": [
        service("kimi_coding", "kimi", "2026-10-26T11:00:00Z"),
        service("codex_a", "codex", "2026-10-26T11:00:00Z"),
    ]});
    let enabled = vec!["kimi".to_owned()];
    let policy = plan(&PlanInput {
        previous: Some(&previous),
        enabled_providers: Some(&enabled),
        now_ms: epoch_ms("2026-10-26T12:00:00Z"),
        interval_secs: 1800,
        force_refresh: true,
        bypass_cooldown: true,
        suppress_external_quotas: true,
    });
    assert!(!policy.include_external_quotas);
    assert_eq!(
        policy.skip_providers,
        BTreeSet::from(["codex".to_owned(), "kimi".to_owned()])
    );
    assert!(policy.rate_limited_providers.is_empty());
}

#[test]
fn unknown_enabled_set_falls_back_to_previous_providers() {
    let now_ms = epoch_ms("2026-10-26T12:00:00Z");
    let fresh = json!({"services": [service("kimi_coding", "kimi", "2026-10-26T11:55:00Z")]});
    let input = |previous| PlanInput {
        previous,
        enabled_providers: None,
        now_ms,
        interval_secs: 1800,
        force_refresh: false,
        bypass_cooldown: false,
        suppress_external_quotas: false,
    };
    let policy = plan(&input(Some(&fresh)));
    assert!(!policy.include_external_quotas);
    assert_eq!(policy.skip_providers, BTreeSet::from(["kimi".to_owned()]));
    // 无历史且启用集合未知: 查询全部。
    assert_eq!(plan(&input(None)), QuotaRunPolicy::include_all());
}

#[test]
fn round_merge_keeps_current_order_without_timestamps() {
    let previous = json!({"services": [service("kimi_coding", "kimi", "2026-10-26T11:00:00Z")]});
    let current = json!({"services": [
        {"id": "zhipu_a", "provider": "zhipu", "status": "error", "windows": [], "capturedAt": "2026-10-26T12:00:00Z"},
        {"id": "kimi_coding", "provider": "kimi", "status": "partial", "windows": []},
    ]});
    let merged = merge_round(Some(&previous), &current);
    let services = merged["services"].as_array().unwrap();
    assert_eq!(services[0]["id"], "zhipu_a");
    assert_eq!(services[0]["freshness"], "unavailable");
    assert!(services[0].get("capturedAt").is_none());
    assert_eq!(services[1]["freshness"], "stale");
    assert_eq!(services[1]["capturedAt"], "2026-10-26T11:00:00Z");
    assert!(services
        .iter()
        .all(|service| service.get("quotaAttemptedAt").is_none()));
}

#[test]
fn scoped_annotation_stamps_only_selected_services() {
    let now_ms = epoch_ms("2026-10-26T12:00:00Z");
    let now = timestamp_iso(now_ms);
    let artifact = json!({"services": [
        {"id": "kimi_coding", "provider": "kimi", "status": "ok", "windows": [], "rateLimitedAt": "2026-10-26T11:00:00Z"},
        {"id": "zhipu_a", "provider": "zhipu", "status": "partial", "failureKind": "rateLimit", "windows": [], "freshness": "stale"},
        {"id": "deepseek", "provider": "deepseek", "status": "ok", "windows": []},
    ]});

    let mut by_id = artifact.clone();
    annotate_services(
        &mut by_id,
        &BTreeSet::from(["kimi_coding".to_owned(), "zhipu_a".to_owned()]),
        now_ms,
    );
    let services = by_id["services"].as_array().unwrap();
    assert_eq!(services[0]["quotaAttemptedAt"], now.as_str());
    assert!(
        services[0].get("rateLimitedAt").is_none(),
        "成功清除限流时间"
    );
    assert_eq!(services[0]["freshness"], "fresh");
    assert_eq!(services[1]["rateLimitedAt"], now.as_str());
    assert_eq!(
        services[1]["freshness"], "stale",
        "失败不改写定向合并给出的新鲜度"
    );
    assert_eq!(
        services[2], artifact["services"][2],
        "未选中的 service 原样保留"
    );

    let mut by_provider = artifact.clone();
    annotate_provider(&mut by_provider, "zhipu", now_ms);
    assert_eq!(by_provider["services"][1]["quotaAttemptedAt"], now.as_str());
    assert!(by_provider["services"][0].get("quotaAttemptedAt").is_none());
}

#[test]
fn legacy_service_ids_resolve_to_providers() {
    for (id, provider) in [
        ("kimi_coding", "kimi"),
        ("volcengine", "volcengine"),
        ("glm_9be9", "zhipu"),
        ("opencode_go_a1", "opencodeGo"),
        ("stepfun_a1", "stepfun"),
        ("jev_a1", "jev"),
        ("cline", "cline"),
        ("unknown_x", "unknown_x"),
    ] {
        assert_eq!(provider_of_id(id), provider, "{id}");
    }
}

#[test]
fn non_object_artifact_is_returned_unchanged() {
    let current = json!(["not", "an", "artifact"]);
    let merged = merge(None, &current, &QuotaRunPolicy::include_all(), 0, 1800);
    assert_eq!(merged, current);
}
