//! 配额预警覆盖 (T31): 共享 collector-policy::alerts 决策 + Windows 前端载荷映射。
//!
//! 状态机、窗口身份、stale/缺失语义在共享 crate 中单份实现; 本文件锁定宿主适配结果。

use bruce_win_lib::alerts::{decide, AlertState};
use serde_json::{json, Value};

fn service(id: &str, name: &str, windows: Value) -> Value {
    json!({
        "id": id, "name": name, "provider": id, "status": "ok",
        "freshness": "fresh", "windows": windows
    })
}

fn window(percent: f64, resets_at: Option<i64>) -> Value {
    json!({
        "label": "5h", "windowKey": "five_hour", "windowMode": "block",
        "windowMinutes": 300, "usedPercent": percent, "resetsAt": resets_at
    })
}

fn artifact(services: Value) -> Value {
    json!({"services": services})
}

fn one(percent: f64) -> Value {
    artifact(json!([service(
        "kimi_coding",
        "Kimi",
        json!([window(percent, Some(1000))])
    )]))
}

#[test]
fn threshold_tier_boundaries_are_strictly_evaluated() {
    let cases = [
        (50.0, None),
        (50.01, Some(50)),
        (80.0, Some(50)),
        (80.01, Some(80)),
        (94.99, Some(80)),
        (95.0, Some(95)),
    ];
    for (percent, expected) in cases {
        let (_, alerts) = decide(
            &one(percent),
            Some(AlertState::default()),
            true,
            None,
            1_000_000,
        );
        match expected {
            None => assert!(alerts.is_empty(), "{percent}% 不应触发"),
            Some(tier) => {
                assert_eq!(alerts.len(), 1, "{percent}% 应触发");
                assert_eq!(alerts[0].tier, tier, "{percent}% 档位");
            }
        }
    }
}

#[test]
fn integer_used_percent_is_accepted() {
    let artifact = artifact(json!([service(
        "kimi_coding",
        "Kimi",
        json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 85}])
    )]));
    let (_, alerts) = decide(
        &artifact,
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts[0].used_percent, 85.0, "整数百分比按 f64 语义");
}

#[test]
fn stale_round_preserves_delivered_tier() {
    let (state, alerts) = decide(
        &one(99.0),
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts[0].tier, 95);

    let stale = artifact(json!([{
        "id": "kimi_coding", "name": "Kimi", "status": "ok", "freshness": "stale",
        "windows": [window(99.0, Some(1000))]
    }]));
    let (state, alerts) = decide(&stale, Some(state), true, None, 1_001_000);
    assert!(alerts.is_empty(), "stale 轮次不投递");

    let (_, alerts) = decide(&one(99.0), Some(state), true, None, 1_002_000);
    assert!(alerts.is_empty(), "stale 不得清空档位记忆");
}

#[test]
fn only_five_hour_windows_trigger() {
    let artifact = artifact(json!([service(
        "kimi_coding",
        "Kimi",
        json!([
            {"label": "每周", "windowKey": "weekly", "windowMinutes": 10_080, "usedPercent": 99.0},
            {"label": "5h", "windowMinutes": 300, "usedPercent": 90.0},
            {"label": "5小时窗口", "usedPercent": 96.0}
        ])
    )]));
    let (_, alerts) = decide(
        &artifact,
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts.len(), 1, "只有 5h 窗口命中; label-only 不再猜身份");
    assert_eq!(alerts[0].window_label, "5h");
}

#[test]
fn multiple_services_are_independent() {
    let artifact = artifact(json!([
        service("kimi_coding", "Kimi", json!([window(90.0, Some(1000))])),
        service("zhipu", "Z.ai", json!([window(95.0, Some(2000))]))
    ]));
    let (_, alerts) = decide(
        &artifact,
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts.len(), 2);
    let ids: Vec<&str> = alerts
        .iter()
        .map(|alert| alert.service_id.as_str())
        .collect();
    assert!(ids.contains(&"kimi_coding") && ids.contains(&"zhipu"));
}

#[test]
fn dedup_fires_only_on_crossing_transitions() {
    let (state, alerts) = decide(
        &one(85.0),
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].tier, 80);

    let (state, alerts) = decide(&one(90.0), Some(state), true, None, 1_001_000);
    assert!(alerts.is_empty(), "持续超标不重复");

    let (state, alerts) = decide(&one(50.0), Some(state), true, None, 1_002_000);
    assert!(alerts.is_empty(), "回落不通知");
    assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 0);

    let (_, alerts) = decide(&one(95.0), Some(state), true, None, 1_003_000);
    assert_eq!(alerts.len(), 1, "再次跨越重新通知");
    assert_eq!(alerts[0].tier, 95);
}

#[test]
fn jitter_does_not_refire() {
    let (state, alerts) = decide(
        &one(64.0),
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts.len(), 1);
    for (index, reset) in [1001_i64, 999].into_iter().enumerate() {
        let artifact = artifact(json!([service(
            "kimi_coding",
            "Kimi",
            json!([window(64.0, Some(reset))])
        )]));
        let (next, alerts) = decide(
            &artifact,
            Some(state.clone()),
            true,
            None,
            1_001_000 + index as i64 * 1_000,
        );
        assert!(alerts.is_empty(), "resetsAt 抖动/回退不应重报");
        assert_eq!(next.windows["kimi_coding|five_hour"].delivered_tier, 50);
    }
}

#[test]
fn missing_or_malformed_fields_are_skipped_silently() {
    let artifact = json!({"services": [
        {"id": "a", "status": "ok"},
        {"id": "b", "status": "ok", "windows": ["not-an-object"]},
        {"id": "c", "status": "ok", "windows": [{"usedPercent": 90.0}]},
        {"id": "d", "status": "ok", "windows": [{"windowKey": "five_hour"}]},
        service("e", "E", json!([window(99.0, Some(1000))]))
    ]});
    let (_, alerts) = decide(
        &artifact,
        Some(AlertState::default()),
        true,
        None,
        1_000_000,
    );
    assert_eq!(alerts.len(), 1, "只有 service e 有效");
    assert_eq!(alerts[0].service_id, "e");
}

#[test]
fn manual_refresh_observes_without_delivery() {
    let (state, alerts) = decide(
        &one(85.0),
        Some(AlertState::default()),
        false,
        None,
        1_000_000,
    );
    assert!(alerts.is_empty());
    assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 80);
    let (_, alerts) = decide(&one(85.0), Some(state), true, None, 1_001_000);
    assert!(alerts.is_empty(), "手动已观察的档位不应在自动刷新重投");
}

#[test]
fn bootstrap_is_silent_and_event_payload_is_frontend_ready() {
    let (state, alerts) = decide(&one(85.0), None, true, None, 1_000_000);
    assert!(alerts.is_empty(), "无状态文件时静默 bootstrap");
    let (_, alerts) = decide(&one(96.0), Some(state), true, None, 1_001_000);
    assert_eq!(alerts.len(), 1);
    let alert = &alerts[0];
    assert!(!alert.event_id.is_empty(), "事件 ID 供去重");
    assert_eq!(alert.tier, 95);
    assert!(
        alert.resets_at.is_some(),
        "epoch 转为 RFC3339 供前端 new Date"
    );
    assert!(alert.resets_at.as_deref().unwrap().contains('T'));
}
