//! 配额预警覆盖 —— 阈值边界、stale 排除、多服务排序、跨越沿去重。

use bruce_win_lib::alerts::{over_threshold_entries, AlertDeliveryState};
use serde_json::json;

fn service(id: &str, name: &str, windows: serde_json::Value) -> serde_json::Value {
    json!({"id": id, "name": name, "status": "ok", "kind": "windows", "windows": windows})
}

#[test]
fn threshold_is_strictly_greater_than_eighty() {
    let artifact = json!({"services": [service("kimi_coding", "Kimi",
        json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 80.0}]))]});
    assert!(over_threshold_entries(&artifact).is_empty(), "80% 不触发");

    let artifact = json!({"services": [service("kimi_coding", "Kimi",
        json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 80.01}]))]});
    let alerts = over_threshold_entries(&artifact);
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].used_percent, 80.01);
}

#[test]
fn integer_used_percent_is_accepted() {
    let artifact = json!({"services": [service("kimi_coding", "Kimi",
        json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 85}]))]});
    let alerts = over_threshold_entries(&artifact);
    assert_eq!(alerts[0].used_percent, 85.0, "整数百分比按 f64 语义");
}

#[test]
fn stale_services_never_trigger_alerts() {
    let artifact = json!({"services": [
        {"id": "kimi_coding", "name": "Kimi", "status": "ok", "freshness": "stale",
         "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": 99.0}]}
    ]});
    assert!(
        over_threshold_entries(&artifact).is_empty(),
        "旧额度不得重复告警"
    );
}

#[test]
fn only_five_hour_windows_trigger_with_label_fallback() {
    let artifact = json!({"services": [service("kimi_coding", "Kimi", json!([
        {"label": "5h", "windowMinutes": 300, "usedPercent": 90.0},
        {"label": "每周", "windowMinutes": 10080, "usedPercent": 95.0},
        {"label": "5小时窗口", "usedPercent": 96.0},
        {"label": "5 小时", "usedPercent": 97.0},
        {"label": "月度", "usedPercent": 98.0}
    ]))]});
    let alerts = over_threshold_entries(&artifact);
    let labels: Vec<&str> = alerts
        .iter()
        .map(|alert| alert.window_label.as_str())
        .collect();
    assert_eq!(
        labels,
        vec!["5h", "5小时窗口", "5 小时"],
        "windowMinutes 300 与文本回退命中, 其他不触发"
    );
}

#[test]
fn multiple_services_keep_artifact_order() {
    let artifact = json!({"services": [
        service("zhipu", "智谱", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 90.0}])),
        service("kimi_coding", "Kimi", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 85.0}]))
    ]});
    let alerts = over_threshold_entries(&artifact);
    assert_eq!(alerts.len(), 2);
    assert_eq!(alerts[0].service_id, "zhipu", "保持 artifact 顺序");
    assert_eq!(alerts[1].service_id, "kimi_coding");
}

#[test]
fn missing_or_malformed_fields_are_skipped_silently() {
    let artifact = json!({"services": [
        {"id": "a", "status": "ok"},                                                     // 无 windows
        {"id": "b", "status": "ok", "windows": ["not-an-object"]},                       // 窗口非对象
        {"id": "c", "status": "ok", "windows": [{"usedPercent": 90.0}]},                 // 缺 label
        {"id": "d", "status": "ok", "windows": [{"label": "5h"}]},                       // 缺 usedPercent
        service("e", "E", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 99.0}]))
    ]});
    let alerts = over_threshold_entries(&artifact);
    assert_eq!(alerts.len(), 1, "只有 service e 有效");
    assert_eq!(alerts[0].service_id, "e");
}

#[test]
fn dedup_fires_only_on_crossing_transitions() {
    let mut state = AlertDeliveryState::default();
    let alerts_at = |percent| {
        over_threshold_entries(&json!({"services": [service("kimi_coding", "Kimi",
            json!([{"label": "5h", "windowMinutes": 300, "usedPercent": percent}]))]}))
    };
    assert_eq!(
        state.filter_new_alerts(&alerts_at(85.0)).len(),
        1,
        "首次超标通知"
    );
    assert!(
        state.filter_new_alerts(&alerts_at(90.0)).is_empty(),
        "持续超标不重复"
    );
    assert!(
        state.filter_new_alerts(&alerts_at(50.0)).is_empty(),
        "回落不通知"
    );
    assert_eq!(
        state.filter_new_alerts(&alerts_at(95.0)).len(),
        1,
        "再次跨越重新通知"
    );
}

#[test]
fn dedup_tracks_each_service_window_independently() {
    let mut state = AlertDeliveryState::default();
    let artifact = json!({"services": [
        service("kimi_coding", "Kimi", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 90.0}])),
        service("zhipu", "智谱", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 95.0}]))
    ]});
    assert_eq!(
        state
            .filter_new_alerts(&over_threshold_entries(&artifact))
            .len(),
        2
    );

    // kimi 回落, zhipu 持续: 下一轮无通知。
    let artifact = json!({"services": [
        service("zhipu", "智谱", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 96.0}]))
    ]});
    assert!(state
        .filter_new_alerts(&over_threshold_entries(&artifact))
        .is_empty());

    // kimi 再次超标: 仅 kimi 通知。
    let artifact = json!({"services": [
        service("kimi_coding", "Kimi", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 88.0}])),
        service("zhipu", "智谱", json!([{"label": "5h", "windowMinutes": 300, "usedPercent": 97.0}]))
    ]});
    let pending = state.filter_new_alerts(&over_threshold_entries(&artifact));
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].service_id, "kimi_coding");
}
