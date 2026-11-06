//! 订阅额度预警决策内核 (design/02 规则 15, design/08 §4.2 第 6 条).
//!
//! 纯函数: 从 artifact `services` 提取窗口观测, 结合上次持久状态与
//! `deliverable` / `activeKeys` 计算新状态与告警事件. 不读写文件、不出站、不含凭据.
//!
//! 语义要点:
//! - 判定键 `serviceID|windowKey`; `label` 只作展示.
//! - 观测质量三态: fresh / 非 fresh (stale/unavailable) / 缺失;
//!   只有 fresh 观测参与跨越、回落与换窗, 非 fresh 仅更新 lastSeenAt.
//! - 换窗: block 模式按 resetsAt 前移振幅门限; rolling 只认 fresh 用量回落;
//!   回退 resetsAt 视为上游修正, 不换窗.
//! - 状态文件缺失/损坏 (`previousState` 为 None) 时静默 bootstrap, 不投递.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// 当前状态 schema 版本.
pub const ALERT_STATE_VERSION: u8 = 1;
/// 告警只处理 5 小时窗口; 可告警集合后续扩展时只改这里.
pub const ALERTABLE_WINDOW_KEYS: [&str; 1] = ["five_hour"];
/// 档位阈值 (与 C159/C206 一致): >50 / >80 / >=95.
pub const ALERT_THRESHOLDS: [f64; 3] = [50.0, 80.0, 95.0];
/// 回落判据: 较上次 fresh 观测下降超过 20 个百分点.
const RESET_DROP_PERCENT: f64 = 20.0;
/// 换窗振幅门限下限 (秒): 避免秒级抖动被误判为新窗口.
const MIN_WINDOW_ADVANCE_SECS: i64 = 300;

/// 每个判定键的持久状态.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowAlertState {
    /// 稳定窗口实例标识: 初值取归一化 resetsAt, 仅在确认换窗时更新.
    pub window_id: String,
    /// 已投递的最高档位: 0 / 50 / 80 / 95.
    pub delivered_tier: u8,
    /// 上次 fresh 观测; None 表示尚未见过 fresh 观测.
    #[serde(default)]
    pub last_fresh: Option<FreshObservation>,
    /// 最近一次见到该键的时间 (含 stale 轮次), 用于诊断.
    pub last_seen_at_ms: i64,
}

/// 上次 fresh 观测快照.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FreshObservation {
    pub used_percent: f64,
    #[serde(default)]
    pub resets_at: Option<i64>,
    #[serde(default)]
    pub window_minutes: Option<u64>,
    pub observed_at_ms: i64,
}

/// 持久状态 (版本化).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AlertState {
    pub version: u8,
    #[serde(default)]
    pub windows: BTreeMap<String, WindowAlertState>,
}

impl Default for AlertState {
    fn default() -> Self {
        Self {
            version: ALERT_STATE_VERSION,
            windows: BTreeMap::new(),
        }
    }
}

/// 需要投递给宿主的告警事件.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AlertEvent {
    pub event_id: String,
    pub key: String,
    pub service_id: String,
    pub service_name: String,
    #[serde(default)]
    pub provider_id: Option<String>,
    pub window_key: String,
    pub window_label: String,
    pub used_percent: f64,
    pub tier: u8,
    #[serde(default)]
    pub reset_at: Option<i64>,
    #[serde(default)]
    pub reset_text: Option<String>,
}

/// 单条窗口观测 (内部).
#[derive(Debug, Clone, PartialEq)]
struct Observation {
    key: String,
    service_id: String,
    service_name: String,
    provider_id: Option<String>,
    window_key: String,
    window_label: String,
    window_mode: String,
    window_minutes: Option<u64>,
    used_percent: f64,
    resets_at: Option<i64>,
    reset_text: Option<String>,
    fresh: bool,
    observed_at_ms: i64,
}

/// 决策入口: 输入本轮 services、上次状态、投递开关、启用键集合与当前时间.
///
/// `previous == None` 视为状态文件缺失/损坏, 按静默 bootstrap 处理.
/// `active_keys == None` 表示宿主无法提供启用集合, 不做 GC.
pub fn decide(
    services: &[Value],
    previous: Option<AlertState>,
    deliverable: bool,
    active_keys: Option<&BTreeSet<String>>,
    now_ms: i64,
) -> (AlertState, Vec<AlertEvent>) {
    let (mut state, bootstrap) = match previous {
        Some(mut state) if state.version == ALERT_STATE_VERSION => {
            state.version = ALERT_STATE_VERSION;
            (state, false)
        }
        _ => (AlertState::default(), true),
    };

    if let Some(active_keys) = active_keys {
        state.windows.retain(|key, _| active_keys.contains(key));
    }

    let observations = collect_observations(services, now_ms);
    let mut events = Vec::new();

    for observation in observations {
        let key = observation.key.clone();
        let window_id = window_id_for(observation.resets_at);
        let entry = state
            .windows
            .entry(key.clone())
            .or_insert_with(|| WindowAlertState {
                window_id: window_id.clone(),
                delivered_tier: 0,
                last_fresh: None,
                last_seen_at_ms: now_ms,
            });

        if !observation.fresh {
            // stale / unavailable / carried: 只更新 lastSeenAt, 不动档位与 fresh 快照.
            entry.last_seen_at_ms = now_ms;
            continue;
        }

        let current = FreshObservation {
            used_percent: observation.used_percent,
            resets_at: observation.resets_at,
            window_minutes: observation.window_minutes,
            observed_at_ms: now_ms,
        };
        let new_window = entry
            .last_fresh
            .as_ref()
            .is_some_and(|previous| is_new_window(previous, &current, &observation.window_mode));
        if new_window {
            entry.window_id = window_id;
            entry.delivered_tier = 0;
        } else if entry.window_id.is_empty() {
            entry.window_id = window_id;
        }

        let tier = alert_tier(observation.used_percent);
        if tier == 0 {
            // fresh 观测确认回落到 50% 及以下: 清空档位记忆.
            entry.delivered_tier = 0;
        } else if bootstrap {
            // 状态文件缺失/损坏: 静默初始化到当前档位, 不在启动时打扰.
            entry.delivered_tier = tier;
        } else if tier > entry.delivered_tier {
            entry.delivered_tier = tier;
            if deliverable {
                events.push(AlertEvent {
                    event_id: format!("{key}|{}|{tier}", entry.window_id),
                    key: key.clone(),
                    service_id: observation.service_id,
                    service_name: observation.service_name,
                    provider_id: observation.provider_id,
                    window_key: observation.window_key,
                    window_label: observation.window_label,
                    used_percent: observation.used_percent,
                    tier,
                    reset_at: observation.resets_at,
                    reset_text: observation.reset_text,
                });
            }
        }

        entry.last_fresh = Some(current);
        entry.last_seen_at_ms = now_ms;
    }

    (state, events)
}

/// 档位计算: 95 (>=95) / 80 (>80) / 50 (>50) / 0.
pub fn alert_tier(used_percent: f64) -> u8 {
    if used_percent >= 95.0 {
        95
    } else if used_percent > 80.0 {
        80
    } else if used_percent > 50.0 {
        50
    } else {
        0
    }
}

fn is_new_window(previous: &FreshObservation, current: &FreshObservation, mode: &str) -> bool {
    let drop = previous.used_percent - current.used_percent > RESET_DROP_PERCENT;
    match mode {
        "rolling" => drop,
        "block" => is_new_block_window(previous, current, drop),
        // unknown / 缺字段: 保守并集 (振幅门限 + 过期边界回落).
        _ => is_new_block_window(previous, current, drop),
    }
}

fn is_new_block_window(
    previous: &FreshObservation,
    current: &FreshObservation,
    drop: bool,
) -> bool {
    if let (Some(previous_reset), Some(current_reset)) = (previous.resets_at, current.resets_at) {
        if current_reset > previous_reset
            && current_reset - previous_reset >= window_advance_gate(previous, current)
        {
            return true;
        }
        // 旧重置时刻已过期, 且 fresh 用量实测回落 → 视为换窗兜底信号.
        if previous_reset <= current.observed_at_ms / 1000 && drop {
            return true;
        }
        // resetsAt 回退或小幅漂移: 上游修正, 不换窗.
        return false;
    }
    // 边界缺失时只能靠实测回落.
    drop
}

fn window_advance_gate(previous: &FreshObservation, current: &FreshObservation) -> i64 {
    let minutes = current
        .window_minutes
        .or(previous.window_minutes)
        .unwrap_or(300);
    let gate = (minutes as i64).saturating_mul(60) / 4;
    gate.max(MIN_WINDOW_ADVANCE_SECS)
}

fn window_id_for(resets_at: Option<i64>) -> String {
    resets_at
        .map(|value| format!("epoch:{value}"))
        .unwrap_or_else(|| "none".to_owned())
}

fn collect_observations(services: &[Value], now_ms: i64) -> Vec<Observation> {
    let mut by_key: BTreeMap<String, Observation> = BTreeMap::new();
    for service in services {
        let Some(service_id) = service.get("id").and_then(Value::as_str) else {
            continue;
        };
        let service_name = service
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(service_id);
        let provider_id = service
            .get("provider")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let freshness = service.get("freshness").and_then(Value::as_str);
        let fresh = !matches!(freshness, Some("stale" | "unavailable"));
        let Some(windows) = service.get("windows").and_then(Value::as_array) else {
            continue;
        };
        for window in windows {
            let window_key = window
                .get("windowKey")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| legacy_window_key(window));
            if !ALERTABLE_WINDOW_KEYS.contains(&window_key.as_str()) {
                continue;
            }
            let Some(used_percent) = numeric_value(window.get("usedPercent")) else {
                continue;
            };
            let key = format!("{service_id}|{window_key}");
            let observation = Observation {
                key: key.clone(),
                service_id: service_id.to_owned(),
                service_name: service_name.to_owned(),
                provider_id: provider_id.clone(),
                window_key,
                window_label: window
                    .get("label")
                    .and_then(Value::as_str)
                    .unwrap_or("5小时窗口")
                    .to_owned(),
                window_mode: window
                    .get("windowMode")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
                    .to_owned(),
                window_minutes: window.get("windowMinutes").and_then(Value::as_u64),
                used_percent,
                resets_at: reset_epoch(window.get("resetsAt")),
                reset_text: window
                    .get("resetText")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                fresh,
                observed_at_ms: now_ms,
            };
            let replace = match by_key.get(&key) {
                None => true,
                Some(existing) => {
                    (observation.fresh && !existing.fresh)
                        || (observation.fresh == existing.fresh
                            && observation.used_percent > existing.used_percent)
                }
            };
            if replace {
                by_key.insert(key, observation);
            }
        }
    }
    by_key.into_values().collect()
}

/// 旧 artifact 无 windowKey 时按 windowMinutes 推导兼容键 (只用升级首轮, 不读 label).
fn legacy_window_key(window: &Value) -> String {
    match window.get("windowMinutes").and_then(Value::as_u64) {
        Some(300) => "five_hour",
        Some(10_080) => "weekly",
        Some(43_200) => "monthly",
        _ => "generic",
    }
    .to_owned()
}

fn numeric_value(value: Option<&Value>) -> Option<f64> {
    match value {
        Some(Value::Number(number)) => number.as_f64(),
        _ => None,
    }
}

/// resetsAt 归一化为 epoch 秒: 整数 / 浮点 / RFC3339 字符串; 非正数与 null 视为无重置时刻.
fn reset_epoch(value: Option<&Value>) -> Option<i64> {
    match value {
        Some(Value::Number(number)) => number
            .as_i64()
            .or_else(|| number.as_f64().map(|value| value as i64))
            .filter(|value| *value > 0),
        Some(Value::String(text)) => chrono::DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|time| time.timestamp())
            .filter(|value| *value > 0)
            .or_else(|| text.parse::<i64>().ok().filter(|value| *value > 0)),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn services(used: f64, resets_at: Option<i64>, mode: &str) -> Vec<Value> {
        vec![json!({
            "id": "claude_acc",
            "name": "Claude",
            "provider": "claude",
            "freshness": "fresh",
            "windows": [{
                "label": "每 5 小时",
                "windowKey": "five_hour",
                "windowMode": mode,
                "windowMinutes": 300,
                "usedPercent": used,
                "resetsAt": resets_at,
            }]
        })]
    }

    fn stale_services(used: f64, resets_at: Option<i64>) -> Vec<Value> {
        vec![json!({
            "id": "claude_acc",
            "name": "Claude",
            "provider": "claude",
            "freshness": "stale",
            "windows": [{
                "label": "每 5 小时",
                "windowKey": "five_hour",
                "windowMode": "block",
                "windowMinutes": 300,
                "usedPercent": used,
                "resetsAt": resets_at,
            }]
        })]
    }

    fn empty_state() -> AlertState {
        AlertState::default()
    }

    fn decide_seq(
        state: Option<AlertState>,
        steps: &[(f64, Option<i64>, &str)],
    ) -> (AlertState, Vec<AlertEvent>) {
        let mut current = state;
        let mut all = Vec::new();
        for (index, (used, reset, mode)) in steps.iter().enumerate() {
            let (next, events) = decide(
                &services(*used, *reset, mode),
                current,
                true,
                None,
                1_000_000 + index as i64 * 1_000,
            );
            current = Some(next);
            all.extend(events);
        }
        (current.unwrap(), all)
    }

    #[test]
    fn tier_boundaries_match_design() {
        assert_eq!(alert_tier(50.0), 0);
        assert_eq!(alert_tier(50.1), 50);
        assert_eq!(alert_tier(80.0), 50);
        assert_eq!(alert_tier(80.1), 80);
        assert_eq!(alert_tier(95.0), 95);
    }

    #[test]
    fn tier_progression_and_same_tier_dedup() {
        let (state, events) = decide_seq(
            Some(empty_state()),
            &[
                (60.0, Some(1_000), "block"),
                (70.0, Some(1_000), "block"),
                (85.0, Some(1_000), "block"),
                (90.0, Some(1_000), "block"),
                (96.0, Some(1_000), "block"),
            ],
        );
        assert_eq!(
            events.iter().map(|event| event.tier).collect::<Vec<_>>(),
            [50, 80, 95]
        );
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 95);
    }

    #[test]
    fn reset_at_jitter_does_not_refire() {
        let (state, events) = decide_seq(
            Some(empty_state()),
            &[
                (64.0, Some(1_000), "block"),
                (64.0, Some(1_001), "block"),
                (64.0, Some(999), "block"),
            ],
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].tier, 50);
        let entry = &state.windows["claude_acc|five_hour"];
        assert_eq!(entry.delivered_tier, 50);
        assert_eq!(entry.window_id, "epoch:1000");
    }

    #[test]
    fn stale_and_missing_rounds_preserve_state() {
        let (mut state, events) = decide(
            &services(64.0, Some(1_000), "block"),
            Some(empty_state()),
            true,
            None,
            1_000_000,
        );
        assert_eq!(events.len(), 1);
        state = decide(
            &stale_services(64.0, Some(1_000)),
            Some(state),
            true,
            None,
            1_001_000,
        )
        .0;
        state = decide(
            &services(64.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_002_000,
        )
        .0;
        state = decide(&[], Some(state), true, None, 1_003_000).0;
        let (state, events) = decide(
            &services(64.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_004_000,
        );
        assert!(events.is_empty());
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 50);
    }

    #[test]
    fn real_window_reset_refires_current_tier() {
        let (state, events) = decide_seq(
            Some(empty_state()),
            &[(96.0, Some(1_000), "block"), (60.0, Some(19_000), "block")],
        );
        assert_eq!(
            events.iter().map(|event| event.tier).collect::<Vec<_>>(),
            [95, 50]
        );
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 50);
    }

    #[test]
    fn recovery_then_crossing_refires_once() {
        let (_, events) = decide_seq(
            Some(empty_state()),
            &[
                (85.0, Some(1_000), "block"),
                (40.0, Some(1_000), "block"),
                (60.0, Some(1_000), "block"),
            ],
        );
        assert_eq!(
            events.iter().map(|event| event.tier).collect::<Vec<_>>(),
            [80, 50]
        );
    }

    #[test]
    fn backward_reset_is_correction_not_new_window() {
        let (state, events) = decide_seq(
            Some(empty_state()),
            &[(85.0, Some(1_000), "block"), (85.0, Some(900), "block")],
        );
        assert_eq!(
            events.iter().map(|event| event.tier).collect::<Vec<_>>(),
            [80]
        );
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 80);
    }

    #[test]
    fn rolling_window_ignores_reset_advance_but_recovers_on_drop() {
        let (state, events) = decide_seq(
            Some(empty_state()),
            &[
                (85.0, Some(1_000), "rolling"),
                (85.0, Some(1_300), "rolling"),
                (40.0, Some(1_600), "rolling"),
                (60.0, Some(1_900), "rolling"),
            ],
        );
        assert_eq!(
            events.iter().map(|event| event.tier).collect::<Vec<_>>(),
            [80, 50]
        );
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 50);
    }

    #[test]
    fn bootstrap_is_silent_then_crosses_normally() {
        let (state, events) = decide(
            &services(85.0, Some(1_000), "block"),
            None,
            true,
            None,
            1_000_000,
        );
        assert!(events.is_empty());
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 80);
        let (_, events) = decide(
            &services(96.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].tier, 95);
    }

    #[test]
    fn new_key_in_existing_state_crosses_normally() {
        let (_, events) = decide(
            &services(85.0, Some(1_000), "block"),
            Some(empty_state()),
            true,
            None,
            1_000_000,
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].tier, 80);
    }

    #[test]
    fn manual_refresh_observes_without_delivery() {
        let (state, events) = decide(
            &services(85.0, Some(1_000), "block"),
            Some(empty_state()),
            false,
            None,
            1_000_000,
        );
        assert!(events.is_empty());
        assert_eq!(state.windows["claude_acc|five_hour"].delivered_tier, 80);
        let (_, events) = decide(
            &services(85.0, Some(1_000), "block"),
            Some(state),
            true,
            None,
            1_001_000,
        );
        assert!(events.is_empty());
    }

    #[test]
    fn active_keys_gc_removes_deleted_accounts_only() {
        let state = AlertState {
            version: 1,
            windows: BTreeMap::from([
                (
                    "claude_acc|five_hour".to_owned(),
                    WindowAlertState {
                        window_id: "epoch:1000".to_owned(),
                        delivered_tier: 50,
                        last_fresh: None,
                        last_seen_at_ms: 1,
                    },
                ),
                (
                    "zhipu_acc|five_hour".to_owned(),
                    WindowAlertState {
                        window_id: "epoch:2000".to_owned(),
                        delivered_tier: 80,
                        last_fresh: None,
                        last_seen_at_ms: 1,
                    },
                ),
            ]),
        };
        let active = BTreeSet::from(["zhipu_acc|five_hour".to_owned()]);
        let (state, _) = decide(&[], Some(state), true, Some(&active), 2_000_000);
        assert!(!state.windows.contains_key("claude_acc|five_hour"));
        assert!(state.windows.contains_key("zhipu_acc|five_hour"));
    }

    #[test]
    fn legacy_artifact_without_window_key_uses_window_minutes() {
        let legacy = vec![json!({
            "id": "claude_acc",
            "name": "Claude",
            "freshness": "fresh",
            "windows": [{
                "label": "每 5 小时",
                "windowMinutes": 300,
                "usedPercent": 60.0,
                "resetsAt": 1_000
            }]
        })];
        let (_, events) = decide(&legacy, Some(empty_state()), true, None, 1_000_000);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].window_key, "five_hour");
        assert_eq!(events[0].tier, 50);
    }
}
