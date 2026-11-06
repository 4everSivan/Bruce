//! 额度预警 Windows 适配层 (T29/T31, design/02 规则 15)。
//!
//! 决策内核位于共享 `collector-policy::alerts`; 本模块只负责:
//! - 把 artifact 的 `services` 传入共享内核;
//! - 把共享事件转换为 Windows 前端气泡载荷 (`QuotaAlert`);
//! - 保留阈值常量供旧调用方/文档引用。
//!
//! 状态机、窗口身份、stale/缺失语义全部在共享 crate 中实现, Windows 不再保留第二份。

use std::collections::BTreeSet;

use collector_policy::alerts::{decide as decide_shared, AlertEvent};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub use collector_policy::alerts::{alert_tier, AlertState, ALERT_STATE_VERSION};

/// 阶梯预警阈值: [50%, 80%, 95%]
pub const QUOTA_ALERT_THRESHOLDS: [f64; 3] = [50.0, 80.0, 95.0];
/// 默认 80% 告警阈值 (向后兼容常量)
pub const QUOTA_ALERT_THRESHOLD: f64 = 80.0;

/// 前端托盘气泡载荷.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaAlert {
    pub service_id: String,
    pub service_name: String,
    pub window_label: String,
    pub used_percent: f64,
    pub tier: u32,
    pub provider_id: Option<String>,
    pub reset_text: Option<String>,
    /// RFC3339 字符串 (前端 `new Date(resetsAt)` 解析); 无重置时刻为 None.
    pub resets_at: Option<String>,
    /// 共享决策内核事件 ID, 供前端/宿主去重.
    pub event_id: String,
}

impl QuotaAlert {
    fn from_event(event: AlertEvent) -> Self {
        Self {
            service_id: event.service_id,
            service_name: event.service_name,
            window_label: event.window_label,
            used_percent: event.used_percent,
            tier: u32::from(event.tier),
            provider_id: event.provider_id,
            reset_text: event.reset_text,
            resets_at: event
                .reset_at
                .and_then(|epoch| chrono::DateTime::from_timestamp(epoch, 0))
                .map(|time| time.to_rfc3339()),
            event_id: event.event_id,
        }
    }
}

/// 一次刷新决策: 输入 artifact、上次状态与投递开关, 返回新状态与需展示的气泡.
///
/// `previous == None` 表示状态文件缺失/损坏, 共享内核按静默 bootstrap 处理.
pub fn decide(
    artifact: &Value,
    previous: Option<AlertState>,
    deliverable: bool,
    active_keys: Option<&BTreeSet<String>>,
    now_ms: i64,
) -> (AlertState, Vec<QuotaAlert>) {
    let services = artifact
        .get("services")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let (state, events) = decide_shared(&services, previous, deliverable, active_keys, now_ms);
    (
        state,
        events.into_iter().map(QuotaAlert::from_event).collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn artifact(used: f64, resets_at: Option<i64>, mode: &str) -> Value {
        json!({"services": [{
            "id": "kimi_coding", "name": "Kimi", "provider": "kimi",
            "freshness": "fresh",
            "windows": [{
                "label": "5小时窗口", "windowKey": "five_hour", "windowMode": mode,
                "windowMinutes": 300, "usedPercent": used, "resetsAt": resets_at
            }]
        }]})
    }

    fn stale_artifact(used: f64, resets_at: Option<i64>) -> Value {
        json!({"services": [{
            "id": "kimi_coding", "name": "Kimi", "provider": "kimi",
            "freshness": "stale",
            "windows": [{
                "label": "5小时窗口", "windowKey": "five_hour", "windowMode": "block",
                "windowMinutes": 300, "usedPercent": used, "resetsAt": resets_at
            }]
        }]})
    }

    fn empty_state() -> AlertState {
        AlertState::default()
    }

    #[test]
    fn tier_boundaries_are_strict() {
        assert_eq!(alert_tier(50.0), 0);
        assert_eq!(alert_tier(50.01), 50);
        assert_eq!(alert_tier(80.0), 50);
        assert_eq!(alert_tier(80.01), 80);
        assert_eq!(alert_tier(94.99), 80);
        assert_eq!(alert_tier(95.0), 95);
    }

    #[test]
    fn bootstrap_is_silent_then_crosses() {
        let (state, alerts) = decide(
            &artifact(85.0, Some(1_000), "block"),
            None,
            true,
            None,
            1_000_000,
        );
        assert!(alerts.is_empty(), "无状态文件时静默 bootstrap");
        assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 80);

        let (_, alerts) = decide(
            &artifact(96.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].tier, 95);
        assert_eq!(alerts[0].service_id, "kimi_coding");
        assert!(!alerts[0].event_id.is_empty());
        assert!(alerts[0].resets_at.is_some(), "epoch 转换为 RFC3339");
    }

    #[test]
    fn crossing_dedup_and_jitter() {
        let (state, alerts) = decide(
            &artifact(85.0, Some(1_000), "block"),
            Some(empty_state()),
            true,
            None,
            1_000_000,
        );
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].tier, 80);

        let (state, alerts) = decide(
            &artifact(85.0, Some(1_001), "block"),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert!(alerts.is_empty(), "resetsAt 抖动不重报");
        assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 80);
    }

    #[test]
    fn stale_round_preserves_state() {
        let (state, alerts) = decide(
            &artifact(64.0, Some(1_000), "block"),
            Some(empty_state()),
            true,
            None,
            1_000_000,
        );
        assert_eq!(alerts.len(), 1);
        let (state, alerts) = decide(
            &stale_artifact(64.0, Some(1_000)),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert!(alerts.is_empty());
        let (state, alerts) = decide(
            &artifact(64.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_002_000,
        );
        assert!(alerts.is_empty(), "stale 轮次不得清档");
        assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 50);
    }

    #[test]
    fn manual_refresh_observes_without_delivery() {
        let (state, alerts) = decide(
            &artifact(85.0, Some(1_000), "block"),
            Some(empty_state()),
            false,
            None,
            1_000_000,
        );
        assert!(alerts.is_empty());
        assert_eq!(state.windows["kimi_coding|five_hour"].delivered_tier, 80);
        let (_, alerts) = decide(
            &artifact(85.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert!(alerts.is_empty());
    }

    #[test]
    fn non_five_hour_and_malformed_windows_are_ignored() {
        let artifact = json!({"services": [{
            "id": "kimi_coding", "name": "Kimi", "freshness": "fresh",
            "windows": [
                {"label": "每周", "windowKey": "weekly", "windowMinutes": 10_080, "usedPercent": 99.0},
                {"label": "5h", "windowMinutes": 300, "usedPercent": 90.0},
                {"label": "5小时窗口", "usedPercent": 96.0}
            ]
        }]});
        let (_, alerts) = decide(&artifact, Some(empty_state()), true, None, 1_000_000);
        assert_eq!(
            alerts.len(),
            1,
            "只有 windowMinutes=300 的窗口命中; label-only 不再猜身份"
        );
        assert_eq!(alerts[0].window_label, "5h");
    }
}
