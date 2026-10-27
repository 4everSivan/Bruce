//! 订阅额度 per-provider 门禁覆盖 (C077) —— 新鲜度跳过、429 partial 冷却、时间戳写回、
//! 跳过 provider 旧值回填、手动刷新绕过冷却。纯逻辑级 (真机行为仍以 Windows 验收为准)。

use bruce_win_lib::quota_policy::{
    annotate_provider, merge, plan, rate_limited_providers_in, timestamp_iso, QuotaRunPolicy,
    RATE_LIMIT_COOLDOWN_SECS,
};
use bruce_win_lib::runtime_core::SnapshotState;
use collector_domain::{BridgeResponse, ResponseStatus};
use serde_json::{json, Value};

/// 固定时钟 (2025-10-08T08:00:00Z)。
const NOW_MS: i64 = 1_759_910_400_000;
const INTERVAL_SECS: i64 = 1800;
const MINUTE_MS: i64 = 60_000;

fn ago(minutes: i64) -> String {
    timestamp_iso(NOW_MS - minutes * MINUTE_MS)
}

fn enabled(providers: &[&str]) -> Vec<String> {
    providers.iter().map(|p| (*p).to_owned()).collect()
}

fn artifact(services: Vec<Value>) -> Value {
    json!({
        "schemaVersion": 1,
        "module": "agent-usage",
        "generatedAt": timestamp_iso(NOW_MS),
        "agents": [],
        "services": services,
        "totalCostUsd": 0.0,
    })
}

/// 一个成功且有尝试时间戳的 provider service。
fn ok_service(id: &str, attempted_minutes_ago: i64) -> Value {
    json!({
        "id": id,
        "name": id,
        "status": "ok",
        "kind": "windows",
        "capturedAt": ago(attempted_minutes_ago),
        "quotaAttemptedAt": ago(attempted_minutes_ago),
        "windows": [{"label": "5h", "usedPercent": 10}],
    })
}

/// 一个命中 429 的 provider service。
fn rate_limited_service(id: &str, limited_minutes_ago: i64) -> Value {
    json!({
        "id": id,
        "name": id,
        "status": "partial",
        "kind": "windows",
        "note": "查询失败: Provider 请求触发限流 (HTTP 429)",
        "rateLimitedAt": ago(limited_minutes_ago),
    })
}

#[test]
fn fresh_provider_is_skipped_while_stale_provider_is_due() {
    let previous = artifact(vec![ok_service("kimi_a", 10), ok_service("zhipu_a", 40)]);
    let policy = plan(
        Some(&previous),
        &enabled(&["kimi", "zhipu"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(
        policy.is_skipped("kimi"),
        "10 分钟前尝试过, 未满间隔 → 跳过"
    );
    assert!(!policy.is_skipped("zhipu"), "40 分钟前尝试过 → 重查");
    assert!(policy.include_external_quotas, "有 provider 需要查询");
}

#[test]
fn all_fresh_providers_produce_a_local_only_run() {
    let previous = artifact(vec![ok_service("kimi_a", 5), ok_service("zhipu_a", 5)]);
    let policy = plan(
        Some(&previous),
        &enabled(&["kimi", "zhipu"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(!policy.include_external_quotas, "全部新鲜 → 本地专用 run");
    assert_eq!(policy.skip_providers.len(), 2, "全部 provider 回填");
}

#[test]
fn provider_without_history_is_always_queried() {
    let previous = artifact(vec![ok_service("kimi_a", 1)]);
    let policy = plan(
        Some(&previous),
        &enabled(&["kimi", "claude"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(!policy.is_skipped("claude"), "新启用 provider 必须首查");
    assert!(policy.is_skipped("kimi"));
}

#[test]
fn rate_limited_provider_cools_down_while_others_refresh() {
    let previous = artifact(vec![
        rate_limited_service("claude_a", 5),
        ok_service("kimi_a", 40),
    ]);
    let policy = plan(
        Some(&previous),
        &enabled(&["claude", "kimi"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(
        policy.rate_limited_providers.contains("claude"),
        "命中 429 进入冷却"
    );
    assert!(
        policy.is_skipped("claude"),
        "冷却期内跳过 (partial, 仅该 provider)"
    );
    assert!(!policy.is_skipped("kimi"), "其余 provider 照常查询");
    assert!(policy.include_external_quotas);
}

#[test]
fn cooldown_expires_and_provider_is_queried_again() {
    let previous = artifact(vec![rate_limited_service("claude_a", 31)]);
    let policy = plan(
        Some(&previous),
        &enabled(&["claude"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(!policy.is_skipped("claude"), "冷却期满自动恢复");
    assert!(policy.rate_limited_providers.is_empty());
}

#[test]
fn manual_refresh_bypasses_freshness_and_cooldown() {
    let previous = artifact(vec![
        ok_service("kimi_a", 1),
        rate_limited_service("claude_a", 1),
    ]);
    let policy = plan(
        Some(&previous),
        &enabled(&["kimi", "claude"]),
        NOW_MS,
        INTERVAL_SECS,
        true,
        true,
    );
    assert_eq!(policy, QuotaRunPolicy::include_all());
    assert!(policy.skip_providers.is_empty());
}

#[test]
fn codex_is_never_skipped_by_cooldown_or_freshness() {
    // Codex 处于 429 冷却仍必须查询 (四源合并链路需要完整首轮结果); 其余 provider 照常门禁。
    let previous = artifact(vec![
        rate_limited_service("codex_a", 1),
        ok_service("zhipu_a", 40),
    ]);
    let policy = plan(
        Some(&previous),
        &enabled(&["codex", "zhipu"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(!policy.is_skipped("codex"), "Codex 冷却中也不进入 skip");
    assert!(
        policy.rate_limited_providers.contains("codex"),
        "冷却事实仍记录"
    );
    assert!(!policy.is_skipped("zhipu"), "过期 provider 照常查询");
    assert!(policy.include_external_quotas);
}

#[test]
fn timestamps_are_written_on_success_and_cleared_after_recovery() {
    // 成功: 写 quotaAttemptedAt, 无 rateLimitedAt。
    let current = merge(
        None,
        &artifact(vec![ok_service("kimi_a", 40)]),
        &QuotaRunPolicy::include_all(),
        NOW_MS,
        INTERVAL_SECS,
    );
    assert_eq!(
        current["services"][0]["quotaAttemptedAt"],
        json!(timestamp_iso(NOW_MS))
    );
    assert!(current["services"][0].get("rateLimitedAt").is_none());

    // 429: 写 rateLimitedAt。
    let limited = merge(
        None,
        &artifact(vec![rate_limited_service("claude_a", 40)]),
        &QuotaRunPolicy::include_all(),
        NOW_MS,
        INTERVAL_SECS,
    );
    assert_eq!(
        limited["services"][0]["rateLimitedAt"],
        json!(timestamp_iso(NOW_MS))
    );

    // 恢复成功: 清除 rateLimitedAt。
    let recovered = merge(
        None,
        &artifact(vec![json!({
            "id": "claude_a", "status": "ok", "kind": "windows",
            "capturedAt": timestamp_iso(NOW_MS), "rateLimitedAt": ago(5),
        })]),
        &QuotaRunPolicy::include_all(),
        NOW_MS,
        INTERVAL_SECS,
    );
    assert!(
        recovered["services"][0].get("rateLimitedAt").is_none(),
        "成功后清除冷却"
    );
}

#[test]
fn skipped_provider_is_carried_over_with_stale_marking() {
    let previous = artifact(vec![
        ok_service("kimi_a", 5),
        rate_limited_service("claude_a", 5),
    ]);
    let policy = plan(
        Some(&previous),
        &enabled(&["kimi", "claude"]),
        NOW_MS,
        INTERVAL_SECS,
        false,
        false,
    );
    // 本轮只返回了未被跳过的 service (无)。
    let current = merge(
        Some(&previous),
        &artifact(vec![]),
        &policy,
        NOW_MS,
        INTERVAL_SECS,
    );

    let services = current["services"].as_array().unwrap();
    assert_eq!(services.len(), 2, "被跳过的 provider 全部回填");
    let claude = services.iter().find(|s| s["id"] == "claude_a").unwrap();
    assert_eq!(
        claude["freshness"], "stale",
        "429 冷却 provider 回填强制标 stale"
    );
    let kimi = services.iter().find(|s| s["id"] == "kimi_a").unwrap();
    assert_eq!(kimi["freshness"], "fresh", "新鲜回填保持 fresh");
}

#[test]
fn rate_limit_note_detection_and_scoped_annotation() {
    let limited = artifact(vec![rate_limited_service("claude_a", 1)]);
    assert!(rate_limited_providers_in(Some(&limited)).contains("claude"));
    let healthy = artifact(vec![ok_service("kimi_a", 1)]);
    assert!(rate_limited_providers_in(Some(&healthy)).is_empty());

    // 定向刷新只标注目标 provider。
    let mut mixed = artifact(vec![ok_service("kimi_a", 40), ok_service("claude_a", 40)]);
    annotate_provider(&mut mixed, "claude", NOW_MS);
    let claude = mixed["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["id"] == "claude_a")
        .unwrap();
    assert_eq!(claude["quotaAttemptedAt"], json!(timestamp_iso(NOW_MS)));
}

#[test]
fn cooldown_window_matches_mac_constant() {
    assert_eq!(RATE_LIMIT_COOLDOWN_SECS, 1800);
}

#[test]
fn snapshot_carries_over_skipped_providers_end_to_end() {
    let mut state = SnapshotState::default();
    // 先落一份快照: kimi 新鲜, claude 刚被 429 限流。
    let first = BridgeResponse {
        schema_version: 1,
        run_id: "00000000-0000-0000-0000-000000000000".to_owned(),
        status: ResponseStatus::Success,
        generated_at: timestamp_iso(NOW_MS),
        artifact: Some(artifact(vec![
            ok_service("kimi_a", 1),
            rate_limited_service("claude_a", 1),
        ])),
        credential_updates: vec![],
        credential_challenges: vec![],
        diagnostics: vec![],
    };
    state.apply_response(&first).unwrap();

    // 本轮 kimi 新鲜 + claude 冷却 → 本地专用 run (services 为空), 回填两个 provider。
    let policy = plan(
        state.artifact(),
        &enabled(&["kimi", "claude"]),
        NOW_MS + 60_000,
        INTERVAL_SECS,
        false,
        false,
    );
    assert!(!policy.include_external_quotas, "全部跳过 → 本地专用 run");
    let second = BridgeResponse {
        schema_version: 1,
        run_id: "00000000-0000-0000-0000-000000000001".to_owned(),
        status: ResponseStatus::Success,
        generated_at: timestamp_iso(NOW_MS + 60_000),
        artifact: Some(artifact(vec![])),
        credential_updates: vec![],
        credential_challenges: vec![],
        diagnostics: vec![],
    };
    state
        .apply_response_with_policy(&second, Some(&policy), NOW_MS + 60_000, INTERVAL_SECS)
        .unwrap();
    let services = state.artifact().unwrap()["services"].as_array().unwrap();
    assert_eq!(services.len(), 2, "跳过的 provider 不丢");
    let claude = services.iter().find(|s| s["id"] == "claude_a").unwrap();
    assert_eq!(claude["freshness"], "stale", "冷却 provider 回填标 stale");
    assert_eq!(claude["status"], "partial", "旧状态保留, 未被清空");
    let kimi = services.iter().find(|s| s["id"] == "kimi_a").unwrap();
    assert_eq!(kimi["freshness"], "fresh", "未过期的回填保持 fresh");
}

/// C118: 显式 provider / failureKind 优先 (mac quotaPolicyPrefersExplicitProviderAndFailureKind 同义),
/// 旧 artifact 回退 id 前缀与 note 文案。
#[test]
fn explicit_provider_and_failure_kind_take_precedence() {
    use bruce_win_lib::quota_policy::{is_rate_limited, rate_limited_providers_in};
    use bruce_win_lib::runtime_core::provider_id;
    use serde_json::json;

    assert_eq!(
        provider_id(&json!({"id": "custom_account", "provider": "deepseek"})),
        "deepseek"
    );
    assert_eq!(
        provider_id(&json!({"id": "zhipu_abc"})),
        "zhipu",
        "旧 artifact 回退 id 前缀"
    );

    let codex = json!({"id": "codex_a", "provider": "codex", "status": "error",
        "failureKind": "rateLimit", "note": "额度查询暂时失败, 请稍后重试"});
    assert!(
        is_rate_limited(&codex),
        "failureKind=rateLimit 必须识别为限流"
    );
    let misleading = json!({"id": "deepseek", "provider": "deepseek", "status": "error",
        "failureKind": "server", "note": "查询失败: 余额 429 元以下"});
    assert!(
        !is_rate_limited(&misleading),
        "failureKind 存在时不得再匹配 note"
    );
    let legacy = json!({"id": "kimi_coding", "status": "error", "note": "查询失败: Provider 请求触发限流 (HTTP 429)"});
    assert!(is_rate_limited(&legacy), "旧 artifact 回退 note 文案");

    let artifact = json!({"services": [codex, misleading, legacy]});
    let limited = rate_limited_providers_in(Some(&artifact));
    assert!(limited.contains("codex") && limited.contains("kimi") && !limited.contains("deepseek"));
}

/// C120: 与 mac `QuotaRefreshPolicy.plan` 共享的门禁对拍用例 (tests/fixtures/quota-policy-parity)。
#[test]
fn plan_matches_shared_parity_fixture() {
    use bruce_win_lib::quota_policy::plan;
    use serde_json::{json, Value};

    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .find(|path| path.join("core/collector").is_dir())
        .expect("repository root")
        .to_path_buf();
    let fixture: Value = serde_json::from_str(
        &std::fs::read_to_string(root.join("tests/fixtures/quota-policy-parity/cases.json"))
            .unwrap(),
    )
    .unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 18, "共享 fixture 覆盖全部判定分支");
    let strings = |value: &Value| -> Vec<String> {
        value
            .as_array()
            .unwrap()
            .iter()
            .map(|item| item.as_str().unwrap().to_owned())
            .collect()
    };
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let now_ms = chrono::DateTime::parse_from_rfc3339(case["now"].as_str().unwrap())
            .unwrap()
            .timestamp_millis();
        let previous = json!({"services": case["services"].clone()});
        let policy = plan(
            Some(&previous),
            &strings(&case["enabledProviders"]),
            now_ms,
            case["intervalSeconds"].as_i64().unwrap(),
            case["forceRefresh"].as_bool().unwrap(),
            case["bypassCooldown"].as_bool().unwrap(),
        );
        let expected = &case["expected"];
        assert_eq!(
            policy.include_external_quotas,
            expected["includeExternalQuotas"].as_bool().unwrap(),
            "{name}: includeExternalQuotas"
        );
        assert_eq!(
            policy.skip_providers.into_iter().collect::<Vec<_>>(),
            strings(&expected["skipProviders"]),
            "{name}: skipProviders"
        );
        assert_eq!(
            policy
                .rate_limited_providers
                .into_iter()
                .collect::<Vec<_>>(),
            strings(&expected["rateLimitedProviders"]),
            "{name}: rateLimitedProviders"
        );
    }
}

/// T13: 与 mac `QuotaCarryOverMerger` / 共享 `collector-policy` 共用的回填对拍用例
/// (tests/fixtures/quota-carry-over-parity), 逐字段比较合并后的有序 services。
#[test]
fn merge_matches_shared_carry_over_fixture() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .find(|path| path.join("core/collector").is_dir())
        .expect("repository root")
        .to_path_buf();
    let fixture: Value = serde_json::from_str(
        &std::fs::read_to_string(root.join("tests/fixtures/quota-carry-over-parity/cases.json"))
            .unwrap(),
    )
    .unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 14, "共享 fixture 覆盖全部回填分支");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let now_ms = chrono::DateTime::parse_from_rfc3339(case["now"].as_str().unwrap())
            .unwrap()
            .timestamp_millis();
        let previous = case["previous"]
            .as_array()
            .map(|services| json!({"services": services}));
        let policy: QuotaRunPolicy = serde_json::from_value(case["policy"].clone()).unwrap();
        let merged = merge(
            previous.as_ref(),
            &artifact(case["current"].as_array().unwrap().clone()),
            &policy,
            now_ms,
            case["intervalSeconds"].as_i64().unwrap(),
        );
        assert_eq!(merged["services"], case["expected"], "{name}");
    }
}
