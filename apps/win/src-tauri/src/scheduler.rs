//! One collector channel, bounded manual wakeups and a single interruptible retry wait.

use std::sync::{mpsc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::alerts::AlertDeliveryState;
pub use crate::runtime_core::RefreshOutcome;
use crate::runtime_core::SnapshotState;

const BASE_BACKOFF_SECS: u64 = 30;
const MAX_BACKOFF_SECS: u64 = 1800;
const RATE_LIMIT_BACKOFF_SECS: u64 = 300;

#[derive(Default)]
pub struct SchedulerControl {
    manual_refresh: Mutex<Option<mpsc::SyncSender<()>>>,
    pub retry_count: Mutex<u32>,
    pub alert_state: Mutex<AlertDeliveryState>,
    pub snapshot: Mutex<SnapshotState>,
}

impl SchedulerControl {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn request_manual_refresh(&self) {
        if let Ok(guard) = self.manual_refresh.lock() {
            if let Some(sender) = guard.as_ref() {
                // A burst during collection schedules one follow-up, without blocking IPC.
                let _ = sender.try_send(());
            }
        }
    }

    pub fn connect_manual_refresh(&self) -> mpsc::Receiver<()> {
        let (sender, receiver) = mpsc::sync_channel(1);
        if let Ok(mut guard) = self.manual_refresh.lock() {
            *guard = Some(sender);
        }
        receiver
    }
}

/// 计算退避秒数 (对齐 mac RefreshBackoffPolicy: 限流固定, 其余指数 + 抖动)。
pub fn compute_backoff(retry_count: u32, rate_limited: bool) -> u64 {
    if rate_limited {
        return RATE_LIMIT_BACKOFF_SECS;
    }
    // 公开 API 防御: 0 与 1 同为首个重试档 (裸 retry_count-1 在 0 输入时 u32 下溢 panic)。
    let exponential = BASE_BACKOFF_SECS.saturating_mul(1u64 << (retry_count.max(1) - 1).min(10));
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

/// 诊断分类: 是否限流类失败 (决定固定退避)。
/// 采集链路诊断 category 值域为 {protocol, security, provider, local, collector, runtime},
/// 不存在 "rateLimit" 值; 真实限流信号是 provider 层 code=PROVIDER_RATE_LIMIT (HTTP 429),
/// 兼容保留 category 匹配, 上游若未来补齐该分类即自然生效 (C006)。
pub fn classify_rate_limited(response: &collector_domain::BridgeResponse) -> bool {
    response.diagnostics.iter().any(|diagnostic| {
        diagnostic.code == "PROVIDER_RATE_LIMIT" || diagnostic.category == "rateLimit"
    })
}

#[cfg(feature = "desktop")]
mod desktop {
    use super::*;
    use crate::alerts::{over_threshold_entries, QuotaAlert};
    use crate::runtime_core::next_delay;
    use crate::settings::{load_settings, AppSettings};
    use crate::{collector, credentials, ledger, paths};
    use serde_json::Value;
    use std::time::Duration;
    use tauri::{AppHandle, Emitter, Manager};
    use tauri_plugin_notification::NotificationExt;

    fn deliver_alerts(app: &AppHandle, settings: &AppSettings, artifact: &Value, manual: bool) {
        let alerts = over_threshold_entries(artifact);
        // Observe crossings on manual refresh but deliver only automatic notifications.
        let to_notify: Vec<QuotaAlert> = app
            .state::<SchedulerControl>()
            .alert_state
            .lock()
            .map(|mut state| {
                state.alerts_for_refresh(&alerts, manual, settings.notifications_enabled)
            })
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

    pub fn cached_panel(app: &AppHandle) -> Result<Value, String> {
        let root = paths::data_root();
        let settings = load_settings(&root);
        let control = app.state::<SchedulerControl>();
        let mut state = control
            .snapshot
            .lock()
            .map_err(|_| "SNAPSHOT_LOCK_FAILED")?;
        state.prune_credentials(&credentials::load_credentials(&root));
        let mut panel = state.panel_json(
            chrono::Local::now().fixed_offset(),
            settings.usage_enabled,
            &settings.enabled_providers,
            &settings.provider_order,
        );
        if let Some(artifact) = state.artifact() {
            if ledger::decorate_cached_panel(&root, artifact, &mut panel).is_err() {
                panel["runtime"]["error"] = serde_json::json!("LEDGER_WRITE_FAILED");
            }
        }
        Ok(panel)
    }

    pub fn publish(app: &AppHandle) {
        if let Ok(panel) = cached_panel(app) {
            let phase = panel
                .pointer("/runtime/phase")
                .and_then(Value::as_str)
                .unwrap_or("failed");
            if let Some(tray) = app.tray_by_id("bruce") {
                let tooltip = match phase {
                    "refreshing" => "Bruce · 正在刷新",
                    "fresh" => "Bruce · 数据已更新",
                    "idle" => "Bruce · 等待采集",
                    _ => "Bruce · 数据过期或采集异常",
                };
                let _ = tray.set_tooltip(Some(tooltip));
                // Reuse the application icon, but visibly tint its indicator per runtime phase.
                if let Some(source) = app.default_window_icon() {
                    let mut pixels = source.rgba().to_vec();
                    let width = source.width() as usize;
                    let height = source.height() as usize;
                    let color = match phase {
                        "refreshing" => [60, 150, 255, 255],
                        "fresh" | "idle" => [50, 200, 100, 255],
                        _ => [255, 175, 30, 255],
                    };
                    let radius = (width.min(height) / 5).max(1);
                    for y in height.saturating_sub(radius * 2)..height {
                        for x in width.saturating_sub(radius * 2)..width {
                            let at = (y * width + x) * 4;
                            if at + 4 <= pixels.len() {
                                pixels[at..at + 4].copy_from_slice(&color);
                            }
                        }
                    }
                    let _ = tray.set_icon(Some(tauri::image::Image::new_owned(
                        pixels,
                        source.width(),
                        source.height(),
                    )));
                }
            }
            let _ = app.emit("dashboard-updated", panel);
        }
    }

    pub fn run_refresh(app: &AppHandle, settings: &AppSettings) -> RefreshOutcome {
        run_refresh_with_kind(app, settings, false)
    }

    fn run_refresh_with_kind(
        app: &AppHandle,
        settings: &AppSettings,
        manual: bool,
    ) -> RefreshOutcome {
        let root = paths::data_root();
        if let Ok(mut state) = app.state::<SchedulerControl>().snapshot.lock() {
            state.begin_refresh();
        }
        publish(app);
        let payloads = credentials::load_credentials(&root);
        let mut first = true;
        let result = credentials::collect_with_recovery(&root, payloads, |payloads| {
            if first {
                first = false;
                collector::run_configured_collection(payloads, settings)
            } else {
                collector::run_codex_retry(payloads, settings)
            }
        });
        let control = app.state::<SchedulerControl>();
        let outcome = match result {
            Ok(response) => {
                let rate_limited = classify_rate_limited(&response);
                let applied = control
                    .snapshot
                    .lock()
                    .map(|mut state| {
                        let result = state.apply_response(&response);
                        if result.is_ok() {
                            if let Some(artifact) = state.artifact() {
                                let mut panel = serde_json::json!({});
                                if ledger::decorate_panel(&root, artifact, &mut panel).is_err() {
                                    state.error = Some("LEDGER_WRITE_FAILED".into());
                                }
                            }
                        }
                        if state.save(&root).is_err() {
                            state.fail("SNAPSHOT_WRITE_FAILED");
                        }
                        result
                    })
                    .unwrap_or_else(|_| Err("SNAPSHOT_LOCK_FAILED".into()));
                if applied.is_ok() {
                    if let Ok(state) = control.snapshot.lock() {
                        if let Some(artifact) = state.artifact() {
                            deliver_alerts(app, settings, artifact, manual);
                        }
                    }
                    RefreshOutcome::Success
                } else {
                    RefreshOutcome::Failed { rate_limited }
                }
            }
            Err(_) => {
                if let Ok(mut state) = control.snapshot.lock() {
                    state.fail("COLLECTION_FAILED");
                    let _ = state.save(&root);
                }
                RefreshOutcome::Failed {
                    rate_limited: false,
                }
            }
        };
        publish(app);
        outcome
    }

    pub fn spawn(app: AppHandle) {
        let receiver = app.state::<SchedulerControl>().connect_manual_refresh();
        std::thread::spawn(move || {
            let mut retries = 0u32;
            let mut manual = false;
            let mut manual_reason = false;
            loop {
                // Collapse requests already queued before this run into its manual reason.
                manual |= receiver.try_iter().next().is_some();
                if manual {
                    retries = 0;
                }
                manual_reason =
                    crate::runtime_core::manual_alert_reason(manual, retries, manual_reason);
                let settings = load_settings(&paths::data_root());
                let outcome = run_refresh_with_kind(&app, &settings, manual_reason);
                retries = match outcome {
                    RefreshOutcome::Success => 0,
                    RefreshOutcome::Failed { .. } => retries.saturating_add(1),
                };
                if let Ok(mut count) = app.state::<SchedulerControl>().retry_count.lock() {
                    *count = retries;
                }
                let interval = load_settings(&paths::data_root())
                    .refresh_interval_secs
                    .clamp(60, 86_400);
                let limited = matches!(outcome, RefreshOutcome::Failed { rate_limited: true });
                let wait = next_delay(
                    outcome,
                    retries,
                    interval,
                    compute_backoff(retries, limited),
                );
                // Manual input replaces this one wait and begins the next run immediately.
                manual = receiver.recv_timeout(Duration::from_secs(wait)).is_ok();
                if retries > 5 {
                    retries = 0;
                }
            }
        });
    }
}

#[cfg(feature = "desktop")]
pub use desktop::{cached_panel, publish, run_refresh, spawn};
