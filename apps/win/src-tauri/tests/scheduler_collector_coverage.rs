//! 刷新调度与采集请求契约覆盖 —— 退避策略、限流分类、请求序列化往返。

use bruce_win_lib::scheduler::{classify_rate_limited, compute_backoff};
use collector_domain::{BridgeRequest, Diagnostic, BRIDGE_SCHEMA_VERSION};
use serde_json::json;

#[test]
fn backoff_is_fixed_for_rate_limit() {
    for retry in [1u32, 3, 7] {
        assert_eq!(compute_backoff(retry, true), 300, "限流固定退避 (对齐 mac)");
    }
}

#[test]
fn backoff_is_exponential_with_jitter_and_cap() {
    // 指数基线 30s×2^(n-1); 抖动 < 基线/10; 上限 1800 (抖动后被 cap 截断)。
    for (retry, base) in [(1u32, 30u64), (2, 60), (3, 120), (4, 240)] {
        let value = compute_backoff(retry, false);
        assert!(
            value >= base && value < base + base / 10,
            "retry={retry} value={value}"
        );
    }
    assert_eq!(compute_backoff(8, false), 1800, "30<<7=3840 -> 截断 1800");
    assert_eq!(compute_backoff(20, false), 1800, "移位饱和后仍为上限");
}

#[test]
fn backoff_treats_zero_retry_as_first_attempt() {
    // 公开 API 防御: 0 与 1 同为首个重试档 (裸 retry_count-1 在 0 输入时 u32 下溢 panic, C006)。
    for retry in [0u32, 1] {
        let value = compute_backoff(retry, false);
        assert!((30..33).contains(&value), "retry={retry} value={value}");
    }
}

#[test]
fn rate_limit_classification_reads_bridge_diagnostics() {
    let run_id = "00000000-0000-0000-0000-000000000000";
    // 真实采集链路形态: provider 层 429 诊断的 category="provider"、code=PROVIDER_RATE_LIMIT
    // (全仓无 category="rateLimit" 产生点, 旧测试自造该值属自证清白, C006 修正)。
    let provider_rate_limited = collector_domain::BridgeResponse::error(
        run_id,
        "2026-07-28T12:00:00+08:00",
        Diagnostic::new(
            "PROVIDER_RATE_LIMIT",
            "provider",
            "external",
            "HTTP 429",
            true,
        ),
    );
    assert!(
        classify_rate_limited(&provider_rate_limited),
        "provider 429 诊断为限流"
    );

    let plain = collector_domain::BridgeResponse::error(
        run_id,
        "2026-07-28T12:00:00+08:00",
        Diagnostic::new(
            "PROVIDER_SERVER_ERROR",
            "provider",
            "external",
            "HTTP 502",
            true,
        ),
    );
    assert!(
        !classify_rate_limited(&plain),
        "非限流 provider 错误不判为限流"
    );

    // 兼容: 上游若未来补齐 category="rateLimit" 分类亦生效。
    let future_category = collector_domain::BridgeResponse::error(
        run_id,
        "2026-07-28T12:00:00+08:00",
        Diagnostic::new("ANY_CODE", "rateLimit", "external", "429", true),
    );
    assert!(classify_rate_limited(&future_category));
}

#[test]
fn local_request_serializes_and_round_trips_through_domain_type() {
    let credentials = bruce_win_lib::credentials::CredentialPayloads::new();
    let request = bruce_win_lib::collector::build_local_request(chrono::Local::now(), &credentials);
    // Serialize -> Value -> Deserialize 往返 (deny_unknown_fields 兼容性锁定)。
    let value = serde_json::to_value(&request).unwrap();
    let parsed: BridgeRequest = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(parsed.schema_version, BRIDGE_SCHEMA_VERSION);
    assert_eq!(parsed.module, "agent-usage");
    assert_eq!(parsed.timeouts.local_scan_seconds, 120.0);
    assert_eq!(parsed.timeouts.module_seconds, 150.0);
    // 字段命名契约 (mac Bridge 同一协议)。
    assert!(value.get("schemaVersion").is_some());
    assert!(value.get("runId").is_some());
    assert!(value["timeouts"].get("localScanSeconds").is_some());
    assert!(value.get("credentials").is_some());
}

#[test]
fn request_context_is_valid_for_collection_window() {
    let request = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    // now 可被 RFC3339 解析 (CollectionWindow.parse_now 前置条件)。
    chrono::DateTime::parse_from_rfc3339(request.context["now"].as_str().expect("now 为字符串"))
        .expect("now 为合法 RFC3339");
    assert!(
        !request.context["timezone"].as_str().unwrap().is_empty(),
        "时区非空"
    );
    // 采集窗口对齐 mac 事实源 (CollectorRunInput.swift:380 days=182 半年口径):
    // 热力图与按月聚合依赖全量 daily, 14 日柱状图由视图模型层截取 (C008)。
    assert_eq!(request.context["days"].as_u64(), Some(182));
    assert!(
        request.context["home"]
            .as_str()
            .is_some_and(|value| !value.is_empty()),
        "home 上下文非空 (对齐 mac 显式携带)"
    );
    // runId 是合法 UUID (validate_request 前置条件)。
    uuid::Uuid::parse_str(&request.run_id).expect("runId 为 UUID");
}

#[test]
fn credentials_injection_enables_external_quotas_only_when_present() {
    let empty = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    let capabilities: Vec<&str> = empty.context["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    assert_eq!(capabilities, vec!["localSessions"]);
    assert!(empty.credentials.is_empty());

    let mut credentials = bruce_win_lib::credentials::CredentialPayloads::new();
    credentials.insert(
        "kimiQuotaAccounts".to_owned(),
        json!([{ "accountID": "a1", "apiKey": "sk-test" }]),
    );
    credentials.insert(
        "providerMeta".to_owned(),
        json!({"claude": {"enabled": true}}),
    );
    let request = bruce_win_lib::collector::build_local_request(chrono::Local::now(), &credentials);
    let capabilities: Vec<&str> = request.context["capabilities"]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| value.as_str().unwrap())
        .collect();
    assert!(
        capabilities.contains(&"externalQuotas"),
        "有凭证即启用出站额度"
    );
    assert_eq!(capabilities.len(), 2, "且不重复注入本地能力");
    assert_eq!(
        request.credentials["kimiQuotaAccounts"],
        credentials["kimiQuotaAccounts"]
    );
    assert_eq!(
        request.credentials["providerMeta"],
        json!({"claude": {"enabled": true}})
    );
}

#[test]
fn timeout_values_stay_within_bridge_limits() {
    let request = bruce_win_lib::collector::build_local_request(
        chrono::Local::now(),
        &bruce_win_lib::credentials::CredentialPayloads::new(),
    );
    assert!(
        request.timeouts.local_scan_seconds > 0.0 && request.timeouts.local_scan_seconds <= 300.0
    );
    assert!(
        request.timeouts.external_request_seconds > 0.0
            && request.timeouts.external_request_seconds <= 300.0
    );
    assert!(request.timeouts.module_seconds > 0.0 && request.timeouts.module_seconds <= 600.0);
}

#[test]
fn window_boundaries_read_reset_epochs_from_windows_services_only() {
    use bruce_win_lib::runtime_core::window_boundaries;
    // 只取 kind="windows" 服务的 windows[].resetsAt; 其它 kind / 缺字段 / null 一律忽略。
    let artifact = json!({
        "services": [
            {"id": "cline", "kind": "windows", "windows": [
                {"label": "5小时窗口", "resetsAt": 1791543327},
                {"label": "每周窗口", "resetsAt": null},
                {"label": "每月窗口"}
            ]},
            {"id": "deepseek", "kind": "balance", "windows": [{"resetsAt": 1}]},
            {"id": "grok", "kind": "windows"}
        ]
    });
    assert_eq!(window_boundaries(&artifact), vec![1791543327]);
    // 无 services / 空 artifact: 空集 (回落原间隔), 不 panic。
    assert!(window_boundaries(&json!({})).is_empty());
    assert!(window_boundaries(&json!({"services": []})).is_empty());
}

#[test]
fn boundary_wake_never_crosses_future_window_reset() {
    use bruce_win_lib::runtime_core::boundary_wake;
    let mut consumed = std::collections::BTreeSet::new();
    let now = 1_000_000_i64;
    // 边界还剩 600s (间隔 1800s): 唤醒提前到 600 + slack, 不做满间隔等待。
    assert_eq!(
        boundary_wake(1800, &[now + 600], now, 20, &mut consumed),
        620
    );
    // 同一边界只消费一次: 紧接着再算 (窗口未刷新) 回落原间隔, 不产生风暴。
    assert_eq!(
        boundary_wake(1800, &[now + 600], now, 20, &mut consumed),
        1800
    );
    // 已进入过去的边界既不唤醒也不记忆 (滚动窗口滑出时刻前移时天然免疫)。
    let mut past: std::collections::BTreeSet<i64> = std::collections::BTreeSet::new();
    assert_eq!(boundary_wake(1800, &[now - 5], now, 20, &mut past), 1800);
    assert!(past.is_empty(), "过期边界不得进入消费集合");
    // 比间隔更远的边界不缩短等待 (避免无谓提前刷新)。
    assert_eq!(
        boundary_wake(1800, &[now + 7200], now, 20, &mut consumed),
        1800
    );
    // 多窗口取最近的一个; 无边界时回落间隔。
    assert_eq!(
        boundary_wake(
            1800,
            &[now + 3000, now + 900, now + 5000],
            now,
            20,
            &mut consumed
        ),
        920
    );
    assert_eq!(boundary_wake(1800, &[], now, 20, &mut consumed), 1800);
}

#[test]
fn boundary_wake_consumes_only_the_chosen_boundary_and_prunes_past_entries() {
    use bruce_win_lib::runtime_core::boundary_wake;
    let now = 2_000_000_i64;
    let mut consumed = std::collections::BTreeSet::from([now - 10, now + 60, now + 5000]);
    // 最近边界已被消费 → 取次近; 过去的条目被剪掉。
    assert_eq!(
        boundary_wake(1800, &[now + 60, now + 5000], now, 20, &mut consumed),
        1800
    );
    assert_eq!(
        consumed,
        std::collections::BTreeSet::from([now + 60, now + 5000])
    );
    // 换一个更近的边界 (新的窗口) → 立即采用并消费。
    assert_eq!(
        boundary_wake(1800, &[now + 100], now, 20, &mut consumed),
        120
    );
    assert!(consumed.contains(&(now + 100)));
}
