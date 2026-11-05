//! 配额预警评估与去重 —— 对齐 mac `QuotaAlertEvaluator` +
//! `SystemNotificationDeliveryPolicy` 语义。
//!
//! 纯逻辑无通知框架依赖: 从 artifact services 提取 5h 窗口用量超过三档阶梯阈值 [50%, 80%, 95%] 条目;
//! 跨越判定 (阶梯跃迁: 0 -> 50 -> 80 -> 95) 与去重状态由调用方 (调度器) 持有。

use serde_json::Value;

/// 阶梯预警阈值: [50%, 80%, 95%]
pub const QUOTA_ALERT_THRESHOLDS: [f64; 3] = [50.0, 80.0, 95.0];
/// 默认 80% 告警阈值 (向后兼容)
pub const QUOTA_ALERT_THRESHOLD: f64 = 80.0;

/// 计算用量对应的告警档位 (95, 80, 50, 或 None)
pub fn alert_tier(used_percent: f64) -> Option<u32> {
    if used_percent >= 95.0 {
        Some(95)
    } else if used_percent > 80.0 {
        Some(80)
    } else if used_percent > 50.0 {
        Some(50)
    } else {
        None
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaAlert {
    pub service_id: String,
    pub service_name: String,
    pub window_label: String,
    pub used_percent: f64,
    pub tier: u32,
    pub provider_id: Option<String>,
    pub reset_text: Option<String>,
    pub resets_at: Option<String>,
    /// 窗口重置时刻归一化 token (整数 epoch 秒 / 原始字符串), 用于窗口重置恢复判定。
    /// 不进入前端 IPC 载荷 (气泡展示仍用 resetsAt / resetText)。
    #[serde(skip)]
    pub reset_token: Option<String>,
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
        let provider_id = service
            .get("provider")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
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
            let Some(tier) = alert_tier(used) else {
                continue;
            };
            let reset_text = window
                .get("resetText")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            let resets_at = window
                .get("resetsAt")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);

            entries.push(QuotaAlert {
                service_id: service_id.to_owned(),
                service_name: name.to_owned(),
                window_label: label.to_owned(),
                used_percent: used,
                tier,
                provider_id: provider_id.clone(),
                reset_text,
                resets_at,
                reset_token: window_reset_token(window.get("resetsAt")),
            });
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

/// 窗口重置时刻归一化 token: 采集端 artifact 实际写整数 epoch 秒,
/// 兼容字符串形态; 非正数 / null / 缺失视为无重置时刻。
fn window_reset_token(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::Number(number)) => {
            let epoch = number.as_f64()?;
            if epoch > 0.0 {
                Some(format!("epoch:{}", epoch as i64))
            } else {
                None
            }
        }
        Some(Value::String(raw)) if !raw.is_empty() => Some(format!("raw:{raw}")),
        _ => None,
    }
}

/// 单个判定键 (serviceID|windowLabel) 的最近一次观察快照。
/// 用于识别「窗口在两次刷新之间被重置」(design/02 规则 15)。
#[derive(Debug, Clone, PartialEq)]
struct AlertObservation {
    used_percent: f64,
    reset_token: Option<String>,
}

/// 通知去重状态: 记录每个去重键已触发过的最高阶梯档位,
/// 并在窗口重置时清空档位记忆, 为下一周期的 50/80/95 阶梯重新放行。
///
/// 窗口重置判定命中任一信号即视为新窗口:
/// - 用量较上次观察下降超过 20 个百分点 (重置后未采到低点、直接重新爬升);
/// - 窗口重置时刻更新 (前后两次采样均带非空 resetsAt 且取值不同)。
#[derive(Debug, Default, Clone)]
pub struct AlertDeliveryState {
    delivered_tiers: std::collections::BTreeMap<String, u32>,
    observations: std::collections::BTreeMap<String, AlertObservation>,
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
        let mut new_alerts = Vec::new();
        let current_keys: std::collections::BTreeSet<String> =
            alerts.iter().map(QuotaAlert::dedup_key).collect();

        for alert in alerts {
            let key = alert.dedup_key();
            let current = AlertObservation {
                used_percent: alert.used_percent,
                reset_token: alert.reset_token.clone(),
            };
            if let Some(previous) = self.observations.get(&key) {
                if window_did_reset(previous, &current) {
                    // 新窗口: 清空旧档位记忆, 当前档位重新算作首次跨越。
                    self.delivered_tiers.remove(&key);
                }
            }
            let highest = self.delivered_tiers.get(&key).copied().unwrap_or(0);
            if alert.tier > highest {
                new_alerts.push(alert.clone());
                self.delivered_tiers.insert(key.clone(), alert.tier);
            }
            self.observations.insert(key, current);
        }

        // 清理已回落至 50% 以下的 key
        self.delivered_tiers.retain(|k, _| current_keys.contains(k));
        self.observations.retain(|k, _| current_keys.contains(k));

        new_alerts
    }
}

/// 窗口重置判定 (design/02 规则 15)。
fn window_did_reset(previous: &AlertObservation, current: &AlertObservation) -> bool {
    // ① 用量较上次观察下降超过 20 个百分点。
    if previous.used_percent - current.used_percent > 20.0 {
        return true;
    }
    // ② 窗口重置时刻更新 (两端均有值时比较; nil → 有值不算换窗)。
    match (&previous.reset_token, &current.reset_token) {
        (Some(previous_token), Some(current_token)) => previous_token != current_token,
        _ => false,
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
            "provider": "kimi",
            "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": percent, "resetsAt": "2026-10-30T15:00:00Z"}]
        });
        if let Some(value) = freshness {
            service["freshness"] = json!(value);
        }
        json!({"services": [service]})
    }

    fn artifact_with_reset_at(percent: f64, resets_at: Value) -> Value {
        json!({"services": [{
            "id": "kimi_coding",
            "name": "Kimi",
            "provider": "kimi",
            "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": percent, "resetsAt": resets_at}]
        }]})
    }

    #[test]
    fn five_hour_window_tiers_are_detected() {
        // 50% 档位 (严格大于 50%)
        let alerts_50 = over_threshold_entries(&artifact_with(60.0, None));
        assert_eq!(alerts_50.len(), 1);
        assert_eq!(alerts_50[0].dedup_key(), "kimi_coding|5h");
        assert_eq!(alerts_50[0].used_percent, 60.0);
        assert_eq!(alerts_50[0].tier, 50);
        assert_eq!(alerts_50[0].provider_id.as_deref(), Some("kimi"));
        assert_eq!(
            alerts_50[0].resets_at.as_deref(),
            Some("2026-10-30T15:00:00Z")
        );

        // 80% 档位 (严格大于 80%)
        let alerts_80 = over_threshold_entries(&artifact_with(85.0, None));
        assert_eq!(alerts_80.len(), 1);
        assert_eq!(alerts_80[0].tier, 80);

        // 95% 档位 (大于等于 95%)
        let alerts_95 = over_threshold_entries(&artifact_with(95.0, None));
        assert_eq!(alerts_95.len(), 1);
        assert_eq!(alerts_95[0].tier, 95);

        // 50% 以下不触发
        assert!(
            over_threshold_entries(&artifact_with(50.0, None)).is_empty(),
            "50% 不触发 (严格大于)"
        );
        assert!(over_threshold_entries(&artifact_with(20.0, None)).is_empty());

        // 非五小时窗口不触发
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
        let alerts = over_threshold_entries(&artifact);
        assert_eq!(alerts.len(), 1);
        assert_eq!(alerts[0].tier, 95);
    }

    #[test]
    fn alert_dedup_and_tier_progression() {
        let mut state = AlertDeliveryState::default();

        // 1. 跨入 50% 档位 (60%) -> 触发 1 条
        let first = state.filter_new_alerts(&over_threshold_entries(&artifact_with(60.0, None)));
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].tier, 50);

        // 2. 依然在 50% 档位 (70%) -> 不重复触发
        let second = state.filter_new_alerts(&over_threshold_entries(&artifact_with(70.0, None)));
        assert!(second.is_empty());

        // 3. 跃迁到 80% 档位 (85%) -> 触发 1 条
        let third = state.filter_new_alerts(&over_threshold_entries(&artifact_with(85.0, None)));
        assert_eq!(third.len(), 1);
        assert_eq!(third[0].tier, 80);

        // 4. 依然在 80% 档位 (90%) -> 不重复触发
        let fourth = state.filter_new_alerts(&over_threshold_entries(&artifact_with(90.0, None)));
        assert!(fourth.is_empty());

        // 5. 跃迁到 95% 档位 (96%) -> 触发 1 条
        let fifth = state.filter_new_alerts(&over_threshold_entries(&artifact_with(96.0, None)));
        assert_eq!(fifth.len(), 1);
        assert_eq!(fifth[0].tier, 95);

        // 6. 回落到 40% (低于 50%) -> 不产生告警，状态清理
        let recovered =
            state.filter_new_alerts(&over_threshold_entries(&artifact_with(40.0, None)));
        assert!(recovered.is_empty());

        // 7. 再次升至 85% -> 重新报警
        let refired = state.filter_new_alerts(&over_threshold_entries(&artifact_with(85.0, None)));
        assert_eq!(refired.len(), 1);
        assert_eq!(refired[0].tier, 80);
    }

    /// C206 缺陷复现: 三档全部触发后窗口被服务端重置, 但两次刷新之间没采到
    /// ≤50% 的低点 (重置后用量很快又越过 50%), 新窗口的 50% 跨越必须重新报警。
    #[test]
    fn alert_refires_after_unobserved_window_reset() {
        let mut state = AlertDeliveryState::default();

        for (percent, tier) in [(60.0, 50), (85.0, 80), (96.0, 95)] {
            let alerts =
                state.filter_new_alerts(&over_threshold_entries(&artifact_with(percent, None)));
            assert_eq!(alerts.len(), 1, "{percent}% 应触发 {tier} 档");
            assert_eq!(alerts[0].tier, tier);
        }

        // 服务端重置窗口, 下一次采样直接是 60% (无 ≤50% 中间观测)
        let refired = state.filter_new_alerts(&over_threshold_entries(&artifact_with(60.0, None)));
        assert_eq!(
            refired.len(),
            1,
            "窗口重置后再次越过 50% 应重新报警 (当前实现被旧 95 档记忆拦下)"
        );
        assert_eq!(refired[0].tier, 50);
    }

    /// C206 缺陷复现: 用量未回落但窗口重置时刻前进 (服务器侧换窗),
    /// 同一档位也必须重新报警。
    #[test]
    fn alert_refires_when_window_reset_time_advances() {
        let mut state = AlertDeliveryState::default();
        let first = state.filter_new_alerts(&over_threshold_entries(&artifact_with_reset_at(
            85.0,
            json!("2026-10-30T15:00:00Z"),
        )));
        assert_eq!(first.len(), 1);

        let second = state.filter_new_alerts(&over_threshold_entries(&artifact_with_reset_at(
            85.0,
            json!("2026-10-30T20:00:00Z"),
        )));
        assert_eq!(
            second.len(),
            1,
            "窗口重置时刻更新后同一档位应重新报警 (当前实现只看档位不看窗口)"
        );
    }
}
