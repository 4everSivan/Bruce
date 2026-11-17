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
        None,
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

fn egress_blocked_service(id: &str, reason: &str) -> Value {
    json!({
        "id": id,
        "provider": "claude",
        "status": "error",
        "failureKind": "network",
        "windows": [],
        "egress": {
            "status": "blocked",
            "reason": reason,
            "expected": "US",
            "observed": null,
            "maskedIp": null
        }
    })
}

#[test]
fn transient_egress_failure_does_not_consume_quota_freshness_slot() {
    let mut artifact = json!({"services": [
        egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT")
    ]});
    let ids = BTreeSet::from(["claude_1".to_owned()]);

    let first = epoch_ms("2026-11-16T12:00:00Z");
    annotate_services(&mut artifact, None, &ids, first);
    let service = &artifact["services"][0];
    assert!(
        service.get("quotaAttemptedAt").is_none(),
        "瞬态探测失败不得冒充额度尝试"
    );
    assert_eq!(service["egressRetryCount"], 1);
    assert_eq!(service["egressRetryAt"], "2026-11-16T12:01:30Z");

    annotate_services(&mut artifact, None, &ids, epoch_ms("2026-11-16T12:01:30Z"));
    assert_eq!(artifact["services"][0]["egressRetryCount"], 2);
    assert_eq!(
        artifact["services"][0]["egressRetryAt"],
        "2026-11-16T12:04:30Z"
    );

    annotate_services(&mut artifact, None, &ids, epoch_ms("2026-11-16T12:04:30Z"));
    assert_eq!(artifact["services"][0]["egressRetryCount"], 3);
    assert_eq!(
        artifact["services"][0]["egressRetryAt"],
        "2026-11-16T12:09:30Z"
    );

    annotate_services(&mut artifact, None, &ids, epoch_ms("2026-11-16T12:09:30Z"));
    assert_eq!(artifact["services"][0]["egressRetryCount"], 4);
    assert!(
        artifact["services"][0].get("egressRetryAt").is_none(),
        "三次退避耗尽后回到正常周期"
    );
}

#[test]
fn non_transient_egress_block_keeps_attempt_timestamp() {
    let mut artifact = json!({"services": [
        egress_blocked_service("claude_1", "EGRESS_COUNTRY_MISMATCH")
    ]});
    annotate_services(
        &mut artifact,
        None,
        &BTreeSet::from(["claude_1".to_owned()]),
        epoch_ms("2026-11-16T12:00:00Z"),
    );
    let service = &artifact["services"][0];
    assert_eq!(service["quotaAttemptedAt"], "2026-11-16T12:00:00Z");
    assert!(service.get("egressRetryAt").is_none());
    assert!(service.get("egressRetryCount").is_none());
}

#[test]
fn plan_waits_for_egress_retry_at_then_forces_due() {
    let now = epoch_ms("2026-11-16T12:00:00Z");
    let mut service = egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT");
    service["capturedAt"] = json!("2026-11-16T11:59:00Z");
    service["egressRetryAt"] = json!("2026-11-16T12:01:00Z");
    let previous = json!({"services": [service]});
    let input = |now_ms| PlanInput {
        previous: Some(&previous),
        enabled_providers: None,
        now_ms,
        interval_secs: 1800,
        force_refresh: false,
        bypass_cooldown: false,
        suppress_external_quotas: false,
    };

    let waiting = plan(&input(now));
    assert!(!waiting.include_external_quotas);
    assert_eq!(
        waiting.skip_providers,
        BTreeSet::from(["claude".to_owned()])
    );

    let due = plan(&input(epoch_ms("2026-11-16T12:01:01Z")));
    assert!(
        due.include_external_quotas,
        "egressRetryAt 到点后必须绕过 30 分钟新鲜度门禁"
    );
    assert!(due.skip_providers.is_empty());
}

#[test]
fn codex_is_not_skipped_while_egress_retry_is_pending() {
    let now = epoch_ms("2026-11-16T12:00:00Z");
    let mut service = egress_blocked_service("codex_1", "EGRESS_PROBE_TIMEOUT");
    service["provider"] = json!("codex");
    service["egressRetryAt"] = json!("2026-11-16T12:01:00Z");
    let previous = json!({"services": [service]});
    let policy = plan(&PlanInput {
        previous: Some(&previous),
        enabled_providers: None,
        now_ms: now,
        interval_secs: 1800,
        force_refresh: false,
        bypass_cooldown: false,
        suppress_external_quotas: false,
    });
    assert!(policy.include_external_quotas);
    assert!(policy.skip_providers.is_empty());
}

/// 真实整轮路径 (C237): 每轮由 plan 决定是否查询, Collector 产出全新的 service 对象
/// (不带上一轮的 egressRetryCount), 再由 merge 与上一份 artifact 合并。
fn egress_round(previous: &Value, now_ms: i64, reason: &str) -> Value {
    let policy = plan(&PlanInput {
        previous: Some(previous),
        enabled_providers: None,
        now_ms,
        interval_secs: 1800,
        force_refresh: false,
        bypass_cooldown: false,
        suppress_external_quotas: false,
    });
    assert!(
        policy.include_external_quotas && !policy.is_skipped("claude"),
        "到点的瞬态出口失败必须进入本轮查询"
    );
    let current = json!({"services": [egress_blocked_service("claude_1", reason)]});
    merge(Some(previous), &current, &policy, now_ms, 1800)
}

fn ok_claude_service(captured: &str) -> Value {
    let mut service = service("claude_1", "claude", captured);
    service.as_object_mut().unwrap().remove("quotaAttemptedAt");
    service
}

#[test]
fn egress_retry_count_escalates_across_merge_rounds() {
    let mut artifact = json!({"services": [ok_claude_service("2026-11-16T11:00:00Z")]});
    let mut now_ms = epoch_ms("2026-11-16T12:00:00Z");
    let expected = [
        (1, Some("2026-11-16T12:01:30Z")),
        (2, Some("2026-11-16T12:04:30Z")),
        (3, Some("2026-11-16T12:09:30Z")),
        (4, None),
    ];
    for (round, (count, retry_at)) in expected.into_iter().enumerate() {
        artifact = egress_round(&artifact, now_ms, "EGRESS_PROBE_TIMEOUT");
        let service = &artifact["services"][0];
        assert_eq!(
            service["egressRetryCount"],
            count,
            "第 {} 轮计数",
            round + 1
        );
        assert_eq!(
            service.get("egressRetryAt").and_then(Value::as_str),
            retry_at,
            "第 {} 轮重试时刻",
            round + 1
        );
        assert_eq!(service["freshness"], "stale", "失败借用合格旧值");
        assert_eq!(service["capturedAt"], "2026-11-16T11:00:00Z");
        if let Some(retry_at) = retry_at {
            now_ms = epoch_ms(retry_at);
        }
    }
}

#[test]
fn egress_retry_count_resets_after_success() {
    let mut artifact = json!({"services": [ok_claude_service("2026-11-16T11:00:00Z")]});
    artifact = egress_round(
        &artifact,
        epoch_ms("2026-11-16T12:00:00Z"),
        "EGRESS_PROBE_TIMEOUT",
    );
    artifact = egress_round(
        &artifact,
        epoch_ms("2026-11-16T12:01:30Z"),
        "EGRESS_PROXY_UNREACHABLE",
    );
    assert_eq!(artifact["services"][0]["egressRetryCount"], 2);

    let now_ms = epoch_ms("2026-11-16T12:04:30Z");
    let current = json!({"services": [ok_claude_service("2026-11-16T12:04:30Z")]});
    artifact = merge(
        Some(&artifact),
        &current,
        &QuotaRunPolicy::include_all(),
        now_ms,
        1800,
    );
    let service = &artifact["services"][0];
    assert!(service.get("egressRetryCount").is_none(), "成功清除计数");
    assert!(service.get("egressRetryAt").is_none());
    assert_eq!(service["quotaAttemptedAt"], "2026-11-16T12:04:30Z");

    // 成功后的新一轮失败重新从第 1 次计。
    let later = epoch_ms("2026-11-16T13:00:00Z");
    let current = json!({"services": [egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT")]});
    artifact = merge(
        Some(&artifact),
        &current,
        &QuotaRunPolicy::include_all(),
        later,
        1800,
    );
    assert_eq!(artifact["services"][0]["egressRetryCount"], 1);
    assert_eq!(
        artifact["services"][0]["egressRetryAt"],
        "2026-11-16T13:01:30Z"
    );
}

#[test]
fn egress_retry_count_not_inherited_by_non_transient_block() {
    let mut artifact = json!({"services": [ok_claude_service("2026-11-16T11:00:00Z")]});
    artifact = egress_round(
        &artifact,
        epoch_ms("2026-11-16T12:00:00Z"),
        "EGRESS_PROBE_TIMEOUT",
    );
    artifact = egress_round(
        &artifact,
        epoch_ms("2026-11-16T12:01:30Z"),
        "EGRESS_PROBE_TIMEOUT",
    );
    assert_eq!(artifact["services"][0]["egressRetryCount"], 2);

    // 转为国家不匹配 (明确决策): 不继承, 写尝试时间戳并清除两个字段。
    artifact = egress_round(
        &artifact,
        epoch_ms("2026-11-16T12:04:30Z"),
        "EGRESS_COUNTRY_MISMATCH",
    );
    let service = &artifact["services"][0];
    assert!(service.get("egressRetryCount").is_none());
    assert!(service.get("egressRetryAt").is_none());
    assert_eq!(service["quotaAttemptedAt"], "2026-11-16T12:04:30Z");

    // 之后再出现瞬态失败: 上一份不是瞬态阻断, 从第 1 次计。
    let now_ms = epoch_ms("2026-11-16T13:00:00Z");
    let current = json!({"services": [egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT")]});
    artifact = merge(
        Some(&artifact),
        &current,
        &QuotaRunPolicy::include_all(),
        now_ms,
        1800,
    );
    assert_eq!(artifact["services"][0]["egressRetryCount"], 1);
}

#[test]
fn scoped_annotation_inherits_egress_retry_count_from_previous() {
    // 定向刷新 (C237): 定向合并器用本轮新对象替换目标 service, 计数须从合并前的上一份继承。
    let mut previous_service = egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT");
    previous_service["egressRetryCount"] = json!(2);
    previous_service["egressRetryAt"] = json!("2026-11-16T12:04:30Z");
    let previous = json!({"services": [previous_service]});
    let ids = BTreeSet::from(["claude_1".to_owned()]);

    let mut merged =
        json!({"services": [egress_blocked_service("claude_1", "EGRESS_PROBE_TIMEOUT")]});
    annotate_services(
        &mut merged,
        Some(&previous),
        &ids,
        epoch_ms("2026-11-16T12:04:30Z"),
    );
    assert_eq!(merged["services"][0]["egressRetryCount"], 3);
    assert_eq!(
        merged["services"][0]["egressRetryAt"],
        "2026-11-16T12:09:30Z"
    );

    // 本轮成功: 不继承, 两个字段被清除。
    let mut recovered = json!({"services": [{"id": "claude_1", "provider": "claude", "status": "ok", "windows": []}]});
    annotate_services(
        &mut recovered,
        Some(&previous),
        &ids,
        epoch_ms("2026-11-16T12:04:30Z"),
    );
    assert!(recovered["services"][0].get("egressRetryCount").is_none());
    assert!(recovered["services"][0].get("egressRetryAt").is_none());
}
