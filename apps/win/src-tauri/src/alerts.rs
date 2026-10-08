//! 配额预警评估与去重 —— 对齐 mac `QuotaAlertEvaluator` +
//! `SystemNotificationDeliveryPolicy` 语义。
//!
//! 纯逻辑无通知框架依赖: 从 artifact services 提取 5h 窗口用量超阈值条目;
//! 跨越判定 (上次未超 → 本次超) 与去重状态由调用方 (调度器) 持有。

use serde_json::Value;

/// 预警阈值: 5h 窗口用量 > 80% 触发 (与 mac 一致)。
pub const QUOTA_ALERT_THRESHOLD: f64 = 80.0;

#[derive(Debug, Clone, PartialEq)]
pub struct QuotaAlert {
    pub service_id: String,
    pub service_name: String,
    pub window_label: String,
    pub used_percent: f64,
}

impl QuotaAlert {
    /// 去重键: "serviceID|windowLabel" (与 mac 一致)。
    pub fn dedup_key(&self) -> String {
        format!("{}|{}", self.service_id, self.window_label)
    }
}

/// 返回当前 artifact 全部超阈值条目; stale 条目 (本轮失败保留旧额度) 不触发。
pub fn over_threshold_entries(artifact: &Value) -> Vec<QuotaAlert> {
    let Some(services) = artifact.get("services").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut entries = Vec::new();
    for service in services {
        let Some(service_id) = service.get("id").and_then(Value::as_str) else {
            continue;
        };
        // 任务 7: stale 条目不得重复触发阈值通知。
        if service.get("freshness").and_then(Value::as_str) == Some("stale") {
            continue;
        }
        let name = service
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(service_id);
        let Some(windows) = service.get("windows").and_then(Value::as_array) else {
            continue;
        };
        for window in windows {
            let Some(label) = window.get("label").and_then(Value::as_str) else {
                continue;
            };
            if !is_five_hour_window(label, window.get("windowMinutes")) {
                continue;
            }
            let Some(used) = numeric_value(window.get("usedPercent")) else {
                continue;
            };
            if used > QUOTA_ALERT_THRESHOLD {
                entries.push(QuotaAlert {
                    service_id: service_id.to_owned(),
                    service_name: name.to_owned(),
                    window_label: label.to_owned(),
                    used_percent: used,
                });
            }
        }
    }
    entries
}

/// 5h 窗口判定: windowMinutes == 300 优先, 其次标签文本
/// (火山引擎等接口 windowMinutes 为空, 只有 "5小时窗口" 标签)。
fn is_five_hour_window(label: &str, window_minutes: Option<&Value>) -> bool {
    if let Some(minutes) = window_minutes.and_then(Value::as_i64) {
        return minutes == 300;
    }
    let lowered = label.to_lowercase();
    lowered.contains("5h") || label.contains("5小时") || label.contains("5 小时")
}

fn numeric_value(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64(),
        _ => None,
    }
}

/// 通知去重状态: 记录上一轮已在告警中的去重键集合。
/// 仅在 "上次未超 → 本次超" 的跨越沿触发通知, 持续超标不重复打扰。
#[derive(Debug, Default)]
pub struct AlertDeliveryState {
    active_keys: std::collections::BTreeSet<String>,
}

impl AlertDeliveryState {
    /// Manual refresh updates crossing state without sending a notification.
    pub fn alerts_for_refresh(
        &mut self,
        alerts: &[QuotaAlert],
        manual: bool,
        enabled: bool,
    ) -> Vec<QuotaAlert> {
        let fresh = self.filter_new_alerts(alerts);
        if manual || !enabled {
            Vec::new()
        } else {
            fresh
        }
    }
    /// 输入本轮超阈值条目, 返回需要真正发出通知的条目。
    pub fn filter_new_alerts(&mut self, alerts: &[QuotaAlert]) -> Vec<QuotaAlert> {
        let current: std::collections::BTreeSet<String> =
            alerts.iter().map(QuotaAlert::dedup_key).collect();
        let new_alerts: Vec<QuotaAlert> = alerts
            .iter()
            .filter(|alert| !self.active_keys.contains(&alert.dedup_key()))
            .cloned()
            .collect();
        self.active_keys = current;
        new_alerts
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn artifact_with(percent: f64, freshness: Option<&str>) -> Value {
        let mut service = json!({
            "id": "kimi_coding",
            "name": "Kimi",
            "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": percent}]
        });
        if let Some(value) = freshness {
            service["freshness"] = json!(value);
        }
        json!({"services": [service]})
    }

    #[test]
    fn five_hour_window_over_threshold_is_detected() {
        let alerts = over_threshold_entries(&artifact_with(85.0, None));
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].dedup_key(), "kimi_coding|5h");
        assert_eq!(alerts[0].used_percent, 85.0);

        assert!(
            over_threshold_entries(&artifact_with(80.0, None)).is_empty(),
            "80% 不触发 (严格大于)"
        );
        assert!(over_threshold_entries(&artifact_with(20.0, None)).is_empty());

        // 非五小时窗口不触发。
        let other = json!({"services": [{"id": "s", "name": "S",
            "windows": [{"label": "每周", "windowMinutes": 10080, "usedPercent": 99.0}]}]});
        assert!(over_threshold_entries(&other).is_empty());
    }

    #[test]
    fn stale_entries_never_trigger() {
        assert!(over_threshold_entries(&artifact_with(99.0, Some("stale"))).is_empty());
    }

    #[test]
    fn label_only_five_hour_detection_matches_mac() {
        let artifact = json!({"services": [{"id": "volc", "name": "Volc",
            "windows": [{"label": "5小时窗口", "usedPercent": 95.0}]}]});
        assert_eq!(over_threshold_entries(&artifact).len(), 1);
    }

    #[test]
    fn alert_dedup_only_fires_on_crossing() {
        let mut state = AlertDeliveryState::default();
        // 首次超标: 通知。
        assert_eq!(
            state
                .filter_new_alerts(&over_threshold_entries(&artifact_with(85.0, None)))
                .len(),
            1
        );
        // 持续超标: 不重复。
        assert!(state
            .filter_new_alerts(&over_threshold_entries(&artifact_with(90.0, None)))
            .is_empty());
        // 回落后再超标: 再次通知。
        assert!(state
            .filter_new_alerts(&over_threshold_entries(&artifact_with(20.0, None)))
            .is_empty());
        assert_eq!(
            state
                .filter_new_alerts(&over_threshold_entries(&artifact_with(95.0, None)))
                .len(),
            1
        );
    }
}
