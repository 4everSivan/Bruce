//! 后台刷新调度器 —— 对齐 mac `RefreshScheduler`/`RefreshBackoffPolicy` 语义:
//! 默认 1800s 周期; 失败按分类退避 (限流固定 300s, 其余 30s×2^(n-1)+抖动,
//! 上限 1800s, 超过 5 次回落整周期); 面板隐藏时暂停采集 (开销门控);
//! 手动刷新立即唤醒并重置退避。告警跨越沿经去重后交 Windows Toast。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::sync::{mpsc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;

use crate::alerts::{over_threshold_entries, AlertDeliveryState, QuotaAlert};
use crate::collector;
use crate::credentials::{load_credentials, CredentialPayloads};
use crate::paths::data_root;
use crate::settings::{load_settings, AppSettings};

const MAX_BACKOFF_RETRIES: u32 = 5;
const BASE_BACKOFF_SECS: u64 = 30;
const MAX_BACKOFF_SECS: u64 = 1800;
const RATE_LIMIT_BACKOFF_SECS: u64 = 300;
/// 面板隐藏时的可见性轮询间隔 (秒)。
const HIDDEN_POLL_SECS: u64 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshOutcome {
    Success,
    /// 采集失败; rate_limited 标记限流类失败 (走固定退避)。
    Failed {
        rate_limited: bool,
    },
}

#[derive(Default)]
pub struct SchedulerControl {
    /// 面板可见性门控: 隐藏时暂停采集 (对齐 mac dashboardPanelVisible 纪律)。
    pub panel_visible: AtomicBool,
    manual_refresh: Mutex<Option<mpsc::Sender<()>>>,
    pub retry_count: Mutex<u32>,
    pub alert_state: Mutex<AlertDeliveryState>,
}

impl SchedulerControl {
    pub fn new() -> Self {
        Self {
            panel_visible: AtomicBool::new(true),
            manual_refresh: Mutex::new(None),
            retry_count: Mutex::new(0),
            alert_state: Mutex::new(AlertDeliveryState::default()),
        }
    }

    pub fn request_manual_refresh(&self) {
        if let Ok(guard) = self.manual_refresh.lock() {
            if let Some(sender) = guard.as_ref() {
                let _ = sender.send(());
            }
        }
    }
}

/// 计算退避秒数 (对齐 mac RefreshBackoffPolicy: 限流固定, 其余指数 + 抖动)。
fn compute_backoff(retry_count: u32, rate_limited: bool) -> u64 {
    if rate_limited {
        return RATE_LIMIT_BACKOFF_SECS;
    }
    let exponential = BASE_BACKOFF_SECS.saturating_mul(1u64 << (retry_count - 1).min(10));
    let capped = exponential.min(MAX_BACKOFF_SECS);
    // 抖动: 0..capped/10 (避免引入 rand 依赖, 用系统纳秒)。
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u64;
    let jitter = if capped > 10 {
        nanos % (capped / 10)
    } else {
        0
    };
    (capped + jitter).min(MAX_BACKOFF_SECS)
}

fn deliver_alerts(app: &AppHandle, settings: &AppSettings, artifact: &Value) {
    if !settings.notifications_enabled {
        return;
    }
    let alerts = over_threshold_entries(artifact);
    let to_notify: Vec<QuotaAlert> = app
        .state::<SchedulerControl>()
        .alert_state
        .lock()
        .map(|mut state| state.filter_new_alerts(&alerts))
        .unwrap_or_default();
    for alert in to_notify {
        let _ = app
            .notification()
            .builder()
            .title("Bruce 配额预警")
            .body(format!(
                "{} {} 窗口已用 {:.0}%",
                alert.service_name, alert.window_label, alert.used_percent
            ))
            .show();
    }
}

/// 执行一轮采集: artifact → 视图模型 → 广播 `dashboard-updated` → 告警评估。
pub fn run_refresh(app: &AppHandle, settings: &AppSettings) -> RefreshOutcome {
    let root = data_root();
    let credentials: CredentialPayloads = load_credentials(&root);
    match collector::run_local_collection(credentials) {
        Ok(response) => {
            let rate_limited = response
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.category == "rateLimit");
            let typed = response
                .artifact
                .as_ref()
                .map(|value| {
                    serde_json::from_value::<collector_domain::AgentUsageArtifact>(value.clone())
                })
                .transpose()
                .ok()
                .flatten();
            if let Some(artifact) = response.artifact.as_ref() {
                deliver_alerts(app, settings, artifact);
            }
            if let Some(typed) = typed.as_ref() {
                let mapper = bruce_win_viewmodel::usage::PanelViewModelMapper::default();
                let now = chrono::Local::now().fixed_offset();
                let panel = mapper.make(Some(typed), now);
                if let Ok(panel_json) = serde_json::to_value(&panel) {
                    let _ = app.emit("dashboard-updated", panel_json);
                }
            }
            if response.status == collector_domain::ResponseStatus::Error {
                RefreshOutcome::Failed { rate_limited }
            } else {
                RefreshOutcome::Success
            }
        }
        Err(_) => RefreshOutcome::Failed {
            rate_limited: false,
        },
    }
}

/// 等待手动刷新信号或超时; true 表示手动唤醒。
fn wait_for_manual_or(receiver: &Receiver<()>, timeout: Duration) -> bool {
    receiver.recv_timeout(timeout).is_ok()
}

/// 后台调度主循环 (独立 std 线程; mpsc 手动唤醒桥接, 无需 tokio 计时)。
pub fn spawn(app: AppHandle) {
    let (sender, receiver) = mpsc::channel::<()>();
    if let Ok(mut guard) = app.state::<SchedulerControl>().manual_refresh.lock() {
        *guard = Some(sender);
    }
    std::thread::spawn(move || {
        let app = app;
        let mut retries: u32 = 0;
        loop {
            // 先采集后等待: 启动即出首屏数据; 可见面板周期到自动刷新。
            let settings: AppSettings = load_settings(&data_root());
            match run_refresh(&app, &settings) {
                RefreshOutcome::Success => retries = 0,
                RefreshOutcome::Failed { rate_limited } => {
                    retries = retries.saturating_add(1);
                    if let Ok(mut guard) = app.state::<SchedulerControl>().retry_count.lock() {
                        *guard = retries;
                    }
                    if retries <= MAX_BACKOFF_RETRIES {
                        let backoff = compute_backoff(retries, rate_limited);
                        if wait_for_manual_or(&receiver, Duration::from_secs(backoff)) {
                            retries = 0;
                        }
                    }
                    // 超过最大重试: 回落整周期, 由下方等待兜底。
                }
            }

            // 等待下一轮: 可见面板等整周期; 隐藏时降频轮询可见性且不采集;
            // 手动刷新随时唤醒。
            loop {
                let visible = app
                    .state::<SchedulerControl>()
                    .panel_visible
                    .load(Ordering::Relaxed);
                let wait = if visible {
                    Duration::from_secs(
                        load_settings(&data_root())
                            .refresh_interval_secs
                            .min(86_400),
                    )
                } else {
                    Duration::from_secs(HIDDEN_POLL_SECS)
                };
                if wait_for_manual_or(&receiver, wait) {
                    retries = 0;
                    break;
                }
                if visible {
                    break;
                }
                // 隐藏超时: 继续等待, 不采集 (开销门控)。
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_matches_mac_policy() {
        // 限流固定 300s。
        assert_eq!(compute_backoff(1, true), 300);
        // 指数: 30, 60, 120... 上限 1800; 抖动 < 上限/10 故只断言区间。
        for (retry, expected_min) in [(1, 30), (2, 60), (3, 120), (7, 1800)] {
            let value = compute_backoff(retry, false);
            assert!(
                value >= expected_min && value <= 1800,
                "retry={retry} value={value}"
            );
        }
    }
}
