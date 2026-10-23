//! One collector channel, bounded manual wakeups and a single interruptible retry wait.

use std::collections::BTreeSet;
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
    /// 采集通道互斥: 全量周期与 Provider 定向刷新串行执行, 快照写入不交错
    /// (mac RefreshScheduler 同一容量约束)。
    pub collection: Mutex<()>,
    /// 定向刷新进行中的 Provider (UI 契约: 目标按钮显示进度并禁用)。
    pub refreshing_providers: Mutex<BTreeSet<String>>,
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

    /// 登记一次 Provider 定向刷新; 同一 Provider 已在刷新时拒绝 (按钮禁用态的后端兜底)。
    pub fn begin_provider_refresh(&self, provider: &str) -> Result<(), String> {
        let mut providers = self
            .refreshing_providers
            .lock()
            .map_err(|_| "SCOPED_REFRESH_LOCK_FAILED")?;
        if providers.insert(provider.to_owned()) {
            Ok(())
        } else {
            Err("SCOPED_REFRESH_RUNNING".into())
        }
    }

    pub fn end_provider_refresh(&self, provider: &str) {
        if let Ok(mut providers) = self.refreshing_providers.lock() {
            providers.remove(provider);
        }
    }

    pub fn refreshing_provider_list(&self) -> Vec<String> {
        self.refreshing_providers
            .lock()
            .map(|providers| providers.iter().cloned().collect())
            .unwrap_or_default()
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
    use crate::reachability::NetworkProbe;
    use crate::runtime_core::next_delay;
    use crate::settings::{load_settings, AppSettings};
    use crate::{collector, credentials, paths};
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

    /// 导出/表格用: 取当前快照 artifact 副本 (无快照返回 None)。
    pub fn cached_artifact(app: &AppHandle) -> Option<Value> {
        let control = app.state::<SchedulerControl>();
        let state = control.snapshot.lock().ok()?;
        state.artifact().cloned()
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
        let verified = crate::settings::verified_provider_ids(&settings);
        let mut panel = state.panel_json_verified(
            chrono::Local::now().fixed_offset(),
            settings.usage_enabled,
            &settings.enabled_providers,
            Some(&verified),
            &settings.provider_order,
        );
        drop(state);
        // 订阅段定向刷新按钮的呈现输入 (mac SubscriptionRefreshControlPolicy):
        // 进行中的 Provider 与「出站额度查询已授权」。
        panel["runtime"]["refreshingProviders"] =
            serde_json::json!(control.refreshing_provider_list());
        panel["runtime"]["quotaRefreshAllowed"] = Value::Bool(settings.consent_version == 1);
        Ok(panel)
    }

    pub fn publish(app: &AppHandle) {
        if let Ok(panel) = cached_panel(app) {
            if let Some(tray) = app.tray_by_id("bruce") {
                // 托盘角标与提示和看板 HUD 状态灯同源 (C100): 同一判定表、同一色值与原因文案,
                // 两处不会一绿一红。
                let status = crate::runtime_core::dashboard_status_from_panel(&panel);
                let _ = tray.set_tooltip(Some(format!("Bruce · {}", status.reason)));
                // Reuse the application icon, but visibly tint its indicator per status tone.
                if let Some(source) = app.default_window_icon() {
                    let mut pixels = source.rgba().to_vec();
                    let width = source.width() as usize;
                    let height = source.height() as usize;
                    let color = status.tone.tray_rgba();
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
        // 与定向刷新串行: 进行中的定向刷新结束后再开始全量采集。
        let control = app.state::<SchedulerControl>();
        let _collection = control.collection.lock();
        if let Ok(mut state) = app.state::<SchedulerControl>().snapshot.lock() {
            state.begin_refresh();
        }
        publish(app);
        // C077: per-provider 额度门禁 —— 由上一份快照决定本轮查询哪些 provider
        // (新鲜或处于 429 冷却者跳过, 稍后由 carry_over 回填旧值); 手动刷新绕过两者。
        let now_ms = chrono::Utc::now().timestamp_millis();
        let interval_secs = settings.refresh_interval_secs as i64;
        let (policy, effective_settings) = {
            let previous = control
                .snapshot
                .lock()
                .ok()
                .and_then(|state| state.artifact().cloned());
            let policy = crate::quota_policy::plan(
                previous.as_ref(),
                &settings.enabled_providers,
                now_ms,
                interval_secs,
                manual,
                manual,
            );
            let mut scoped = settings.clone();
            scoped
                .enabled_providers
                .retain(|provider| !policy.is_skipped(provider));
            (policy, scoped)
        };
        let payloads = credentials::load_credentials(&root);
        // C075: 采集前自动跟随本机 Claude CLI 登录态 (零配置, 不落盘)。
        let home = paths::home_root();
        let mut first = true;
        let result = credentials::collect_with_recovery(&root, payloads, |payloads| {
            let payloads = credentials::with_local_claude(payloads, &home);
            // C085: 同范式跟随本机 Grok CLI 登录态 (零配置, 不落盘)。
            let payloads = credentials::with_local_grok(payloads, &home);
            if first {
                first = false;
                collector::run_configured_collection(payloads, &effective_settings)
            } else {
                collector::run_codex_retry(payloads, &effective_settings)
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
                        let result = state.apply_response_with_policy(
                            &response,
                            Some(&policy),
                            now_ms,
                            interval_secs,
                        );
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

    /// Provider 定向刷新 (mac `RefreshScheduler.refreshSubscription` 同契约): 只重新查询
    /// 目标 Provider 的订阅额度, 不重扫本机会话、不影响其他订阅; 全量刷新进行中、未授权、
    /// 未启用或未知 Provider 一律拒绝 (fail-closed)。立即返回, 结果经 dashboard-updated 发布;
    /// 定向刷新属于手动操作, 不投递配额预警。
    pub fn refresh_subscription(app: &AppHandle, section_id: &str) -> Result<(), String> {
        let provider = crate::runtime_core::provider_of_id(section_id);
        if !crate::settings::PROVIDERS.contains(&provider) {
            return Err("SCOPED_REFRESH_UNKNOWN_PROVIDER".into());
        }
        let provider = provider.to_owned();
        let settings = load_settings(&paths::data_root());
        if settings.consent_version != 1 {
            return Err("SCOPED_REFRESH_UNAUTHORIZED".into());
        }
        if !settings.enabled_providers.contains(&provider) {
            return Err("SCOPED_REFRESH_DISABLED".into());
        }
        let control = app.state::<SchedulerControl>();
        let full_refresh_running = control
            .snapshot
            .lock()
            .map(|state| state.phase == "refreshing")
            .unwrap_or(true);
        if full_refresh_running {
            return Err("FULL_REFRESH_RUNNING".into());
        }
        control.begin_provider_refresh(&provider)?;
        publish(app);
        let app = app.clone();
        std::thread::spawn(move || {
            let control = app.state::<SchedulerControl>();
            {
                let _collection = control.collection.lock();
                let root = paths::data_root();
                let settings = load_settings(&root);
                let payloads = credentials::load_credentials(&root);
                // C075: 定向刷新同样跟随本机 Claude CLI 登录态。
                let home = paths::home_root();
                let mut first = true;
                let result = credentials::collect_with_recovery(&root, payloads, |payloads| {
                    let payloads = credentials::with_local_claude(payloads, &home);
                    // C085: 定向刷新同样跟随本机 Grok CLI 登录态。
                    let payloads = credentials::with_local_grok(payloads, &home);
                    if first {
                        first = false;
                        collector::run_scoped_collection(payloads, &settings, &provider)
                    } else {
                        collector::run_codex_retry(payloads, &settings)
                    }
                });
                if let Ok(mut state) = control.snapshot.lock() {
                    match &result {
                        Ok(response) => {
                            // C077: 定向刷新写回目标 provider 的额度尝试时间戳。
                            let _ = state.apply_scoped_response_with_policy(
                                response,
                                &provider,
                                chrono::Utc::now().timestamp_millis(),
                            );
                        }
                        Err(_) => state.mark_provider_stale(&provider),
                    }
                    if state.save(&root).is_err() {
                        state.fail("SNAPSHOT_WRITE_FAILED");
                    }
                }
            }
            control.end_provider_refresh(&provider);
            publish(&app);
        });
        Ok(())
    }

    pub fn spawn(app: AppHandle) {
        let receiver = app.state::<SchedulerControl>().connect_manual_refresh();
        std::thread::spawn(move || {
            // C013: 采集/退避线程降到 BELOW_NORMAL —— 常驻周期扫描 (尤其装机后的
            // 全量历史首扫) 是纯后台数据面, 不与前台 UI/系统抢占调度; 手动刷新同样
            // 让出优先级, 慢一点但机器不卡。windows-sys 已有依赖, 零新增。
            #[cfg(windows)]
            unsafe {
                windows_sys::Win32::System::Threading::SetThreadPriority(
                    windows_sys::Win32::System::Threading::GetCurrentThread(),
                    windows_sys::Win32::System::Threading::THREAD_PRIORITY_BELOW_NORMAL,
                );
            }
            let mut retries = 0u32;
            let mut manual = false;
            let mut manual_reason = false;
            // C037: 边界唤醒已消费集合 —— 同一窗口重置时刻只提前唤醒一次。
            let mut boundary_consumed = std::collections::BTreeSet::new();
            // C076: 网络可达性闸门 —— 离线不发起自动刷新/不重试, 联网后单次补偿。
            let probe = crate::reachability::SystemNetworkProbe;
            let mut gate = crate::reachability::ReachabilityGate::new();
            loop {
                // Collapse requests already queued before this run into its manual reason.
                manual |= receiver.try_iter().next().is_some();
                if manual {
                    retries = 0;
                }
                let decision = gate.observe(probe.is_online());
                // 断网闸门: 自动触发在无网络时不启动采集, 也不排任何重试; 手动刷新
                // (含定向刷新) 仍允许执行一次 (对齐 mac RefreshScheduler)。
                if crate::reachability::should_skip_refresh(decision, manual) {
                    retries = 0;
                    if let Ok(mut count) = app.state::<SchedulerControl>().retry_count.lock() {
                        *count = 0;
                    }
                    if let Ok(mut state) = app.state::<SchedulerControl>().snapshot.lock() {
                        state.fail(crate::reachability::NETWORK_UNAVAILABLE);
                    }
                    publish(&app);
                    // 短周期重探, 不进入指数退避; 手动输入可提前打断。
                    manual = receiver
                        .recv_timeout(Duration::from_secs(
                            crate::reachability::OFFLINE_PROBE_INTERVAL_SECS,
                        ))
                        .is_ok();
                    continue;
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
                let mut wait = next_delay(
                    outcome,
                    retries,
                    interval,
                    compute_backoff(retries, limited),
                );
                // C037: 定时唤醒不得跨过未来的额度窗口重置时刻 —— 否则槽边界过后至下次
                // 刷新之间 (最长一个间隔) 面板仍在展示上一槽的百分比与「刷新中」。
                // 只在采集成功 (有新鲜窗口数据) 时参与调度, 失败/退避路径保持原语义。
                if matches!(outcome, RefreshOutcome::Success) {
                    let artifact = app
                        .state::<SchedulerControl>()
                        .snapshot
                        .lock()
                        .ok()
                        .and_then(|state| state.artifact().cloned());
                    if let Some(artifact) = artifact {
                        let boundaries = crate::runtime_core::window_boundaries(&artifact);
                        wait = crate::runtime_core::boundary_wake(
                            wait,
                            &boundaries,
                            chrono::Utc::now().timestamp(),
                            crate::runtime_core::WINDOW_BOUNDARY_SLACK_SECS,
                            &mut boundary_consumed,
                        );
                    }
                }
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
pub use desktop::{
    cached_artifact, cached_panel, publish, refresh_subscription, run_refresh, spawn,
};
