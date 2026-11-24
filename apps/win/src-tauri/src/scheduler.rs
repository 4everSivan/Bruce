//! One collector channel, bounded manual wakeups and a single interruptible retry wait.

use std::collections::BTreeSet;
use std::sync::{mpsc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::alerts::AlertState;
pub use crate::runtime_core::RefreshOutcome;
use crate::runtime_core::SnapshotState;

const BASE_BACKOFF_SECS: u64 = 30;
const MAX_BACKOFF_SECS: u64 = 1800;
const RATE_LIMIT_BACKOFF_SECS: u64 = 300;

/// 额度预警持久状态: `loaded=false` 时首次刷新从独立 metadata 文件按需读取;
/// 文件缺失/损坏保持 None, 由共享内核按静默 bootstrap 处理 (T31).
#[derive(Default)]
pub struct QuotaAlertRuntimeState {
    loaded: bool,
    state: Option<AlertState>,
}

impl QuotaAlertRuntimeState {
    fn previous(&mut self, path: &std::path::Path) -> Option<AlertState> {
        if !self.loaded {
            self.state = load_alert_state(path);
            self.loaded = true;
        }
        self.state.clone()
    }

    fn update(&mut self, state: AlertState) {
        self.state = Some(state);
    }
}

fn load_alert_state(path: &std::path::Path) -> Option<AlertState> {
    let data = std::fs::read(path).ok()?;
    let state: AlertState = serde_json::from_slice(&data).ok()?;
    (state.version == collector_policy::alerts::ALERT_STATE_VERSION).then_some(state)
}

/// C251: 局部刷新在途状态 —— 只有 Idle 才起线程；Running 期间的重复触发合并为
/// 一次后续执行，避免连点无界创建 OS 线程排队等待 collection 锁。
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum LocalRefreshState {
    #[default]
    Idle,
    Running,
    RunningPending,
}

#[derive(Default)]
pub struct SchedulerControl {
    manual_refresh: Mutex<Option<mpsc::SyncSender<()>>>,
    pub retry_count: Mutex<u32>,
    pub alert_state: Mutex<QuotaAlertRuntimeState>,
    pub snapshot: Mutex<SnapshotState>,
    /// 采集通道互斥: 全量周期与 Provider 定向刷新串行执行, 快照写入不交错
    /// (mac RefreshScheduler 同一容量约束)。
    pub collection: Mutex<()>,
    /// 定向刷新进行中的 Provider (UI 契约: 目标按钮显示进度并禁用)。
    pub refreshing_providers: Mutex<BTreeSet<String>>,
    local_refresh: Mutex<LocalRefreshState>,
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

    /// 局部刷新的防重入闸门 (C251): 返回 true 表示调用方应启动执行线程。
    pub fn begin_local_refresh(&self) -> bool {
        let mut state = self
            .local_refresh
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match *state {
            LocalRefreshState::Idle => {
                *state = LocalRefreshState::Running;
                true
            }
            LocalRefreshState::Running => {
                *state = LocalRefreshState::RunningPending;
                false
            }
            LocalRefreshState::RunningPending => false,
        }
    }

    /// 一轮局部刷新结束: 返回 true 表示在途期间收到过合并请求，应再执行一轮。
    pub fn finish_local_refresh(&self) -> bool {
        let mut state = self
            .local_refresh
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        match *state {
            LocalRefreshState::RunningPending => {
                *state = LocalRefreshState::Running;
                true
            }
            _ => {
                *state = LocalRefreshState::Idle;
                false
            }
        }
    }

    /// 清理用量缓存时磁盘与内存快照必须同时清空 (C251): 只删文件会让下一轮刷新
    /// 继续以陈旧内存 artifact 作为合并基线。
    pub fn reset_snapshot(&self, root: &std::path::Path) -> Result<(), String> {
        crate::runtime_core::clear_snapshot(root)?;
        if let Ok(mut state) = self.snapshot.lock() {
            *state = SnapshotState::default();
        }
        Ok(())
    }

    /// 在快照锁内克隆 artifact 后立即释放，再执行回调 (C251)。回调可能同步派发到
    /// Win32 主线程；持锁调用会与主线程的看板查询形成 AB-BA 死锁。
    pub fn with_artifact<T>(&self, action: impl FnOnce(&serde_json::Value) -> T) -> Option<T> {
        let artifact = self.snapshot.lock().ok()?.artifact().cloned()?;
        Some(action(&artifact))
    }
}

/// 计算退避秒数 (对齐 mac RefreshBackoffPolicy: 限流固定, 其余指数 + 抖动)。
/// 实现位于共享 `collector-policy::backoff_seconds` (T17); 抖动比例取系统纳秒的
/// 0..0.1 (避免引入 rand 依赖), 与两端原实现同为 capped 的 0~10%。
pub fn compute_backoff(retry_count: u32, rate_limited: bool) -> u64 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_nanos() as u64;
    let jitter_fraction = (nanos % 1000) as f64 / 10_000.0;
    collector_policy::backoff_seconds(
        retry_count,
        rate_limited,
        BASE_BACKOFF_SECS as f64,
        MAX_BACKOFF_SECS as f64,
        RATE_LIMIT_BACKOFF_SECS as f64,
        jitter_fraction,
    ) as u64
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
    use crate::alerts::decide;
    use crate::reachability::NetworkProbe;
    use crate::runtime_core::next_delay;
    use crate::settings::{load_settings, AppSettings};
    use crate::{collector, credentials, paths};
    use serde_json::Value;
    use std::time::Duration;
    use tauri::{AppHandle, Emitter, Manager};

    fn deliver_alerts(app: &AppHandle, artifact: &Value, manual: bool) {
        // 状态文件与展示快照解耦: 清理用量缓存不删除该文件 (design/02 规则 15).
        let path = paths::data_root()
            .join("metadata")
            .join("quota-alert-state-v1.json");
        let control = app.state::<SchedulerControl>();
        let (to_notify, state) = {
            let Ok(mut guard) = control.alert_state.lock() else {
                return;
            };
            let previous = guard.previous(&path);
            let (state, alerts) = decide(
                artifact,
                previous,
                !manual,
                None,
                chrono::Utc::now().timestamp_millis(),
            );
            guard.update(state.clone());
            (alerts, state)
        };
        if let Ok(data) = serde_json::to_vec(&state) {
            // 非敏感状态快照: 私有 ACL + 原子替换, 目录级 ACL 每进程只施放一次 (C251).
            let _ = credentials::atomic_managed_write(&path, &data);
        }
        if !to_notify.is_empty() {
            // C159: 退役 Windows Toast 弹窗通知, 改为向托盘气泡浮层派发并展现
            crate::show_quota_alert(app, &to_notify);
            let _ = app.emit("quota-alert-bubble", &to_notify);
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
        // 托盘配额环与悬停预览卡共用的速览 (C115): 预览卡只读 `panel.preview`,
        // 不再在前端按猜测的字段名自行推算。须在 runtime 字段写入后计算 (状态灯读取 runtime)。
        let preview = crate::tray_icon_renderer::extract_quota_summary(&panel);
        panel["preview"] = serde_json::to_value(&preview).unwrap_or(Value::Null);
        Ok(panel)
    }

    pub fn publish(app: &AppHandle) {
        if let Ok(panel) = cached_panel(app) {
            if let Some(tray) = app.tray_by_id("bruce") {
                // 方案 1: 系统托盘动态配额环与心跳状态指示
                let summary = crate::tray_icon_renderer::extract_quota_summary(&panel);
                let is_refreshing = app
                    .state::<SchedulerControl>()
                    .snapshot
                    .lock()
                    .map(|state| state.phase == "refreshing")
                    .unwrap_or(false);
                let pixels = crate::tray_icon_renderer::render_tray_quota_icon(
                    32,
                    summary.remaining_pct,
                    summary.tone,
                    is_refreshing,
                );
                let _ = tray.set_icon(Some(tauri::image::Image::new_owned(pixels, 32, 32)));
                let _ = tray.set_tooltip(Some(crate::tray_icon_renderer::tray_tooltip(&summary)));
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
                    // C251: 先在快照锁内克隆 artifact 并释放锁，再投递预警 —— 弹窗会
                    // 同步派发到 Win32 主线程，持锁调用会与主线程的看板查询 AB-BA 死锁。
                    control.with_artifact(|artifact| deliver_alerts(app, artifact, manual));
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

    /// C212: Agent 卡内刷新只跑本机会话采集; 不查询订阅额度, 上一份 services
    /// 由 `plan_local_only` + 共享 merge 原样回填。与全量/定向刷新共用采集互斥。
    ///
    /// C251: 在途期间的重复触发只记为一次合并请求，不再每次点击各起一个线程
    /// 排队等待 `collection` 锁。
    pub fn refresh_agent_usage_local(app: &AppHandle) -> Result<(), String> {
        let control = app.state::<SchedulerControl>();
        if !control.begin_local_refresh() {
            return Ok(());
        }
        let thread_app = app.clone();
        let spawned = std::thread::Builder::new()
            .name("bruce-local-refresh".into())
            .spawn(move || loop {
                run_local_refresh(&thread_app);
                if !thread_app
                    .state::<SchedulerControl>()
                    .finish_local_refresh()
                {
                    break;
                }
            });
        if let Err(error) = spawned {
            app.state::<SchedulerControl>().finish_local_refresh();
            return Err(error.to_string());
        }
        Ok(())
    }

    fn run_local_refresh(app: &AppHandle) {
        let control = app.state::<SchedulerControl>();
        let _collection = control.collection.lock();
        let root = paths::data_root();
        let settings = load_settings(&root);
        let now_ms = chrono::Utc::now().timestamp_millis();
        let interval_secs = settings.refresh_interval_secs as i64;
        if let Ok(mut state) = control.snapshot.lock() {
            state.begin_refresh();
        }
        publish(app);
        let policy = {
            let previous = control
                .snapshot
                .lock()
                .ok()
                .and_then(|state| state.artifact().cloned());
            crate::quota_policy::plan_local_only(previous.as_ref())
        };
        // 空凭证: capabilities 仅 localSessions, collector 不发起外部额度请求。
        let result =
            collector::run_configured_collection(credentials::CredentialPayloads::new(), &settings);
        if let Ok(mut state) = control.snapshot.lock() {
            match &result {
                Ok(response) => {
                    let _ = state.apply_response_with_policy(
                        response,
                        Some(&policy),
                        now_ms,
                        interval_secs,
                    );
                }
                Err(_) => state.fail("COLLECTION_FAILED"),
            }
            if state.save(&root).is_err() {
                state.fail("SNAPSHOT_WRITE_FAILED");
            }
        }
        publish(app);
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
    cached_artifact, cached_panel, publish, refresh_agent_usage_local, refresh_subscription,
    run_refresh, spawn,
};

#[cfg(test)]
mod alert_state_tests {
    use super::*;

    #[test]
    fn alert_state_round_trips_and_corrupt_is_ignored() {
        let dir = std::env::temp_dir().join(format!(
            "bruce-alert-state-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("quota-alert-state-v1.json");
        let state = AlertState {
            version: collector_policy::alerts::ALERT_STATE_VERSION,
            windows: std::collections::BTreeMap::new(),
        };
        let data = serde_json::to_vec(&state).unwrap();
        crate::credentials::atomic_private_write(&path, &data).unwrap();
        assert_eq!(load_alert_state(&path), Some(state));

        std::fs::write(&path, b"not-json").unwrap();
        assert_eq!(load_alert_state(&path), None, "损坏状态按 bootstrap 处理");

        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod concurrency_tests {
    use super::*;

    fn temp_root() -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "bruce-scheduler-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn populated_snapshot() -> SnapshotState {
        serde_json::from_value(serde_json::json!({
            "artifact": {"schemaVersion": 1, "module": "agent-usage"},
            "phase": "ok"
        }))
        .unwrap()
    }

    #[test]
    fn local_refresh_bursts_collapse_to_one_follow_up() {
        let control = SchedulerControl::new();
        assert!(control.begin_local_refresh(), "空闲时首个触发应启动线程");
        assert!(!control.begin_local_refresh(), "在途触发不得再起线程");
        assert!(!control.begin_local_refresh(), "在途触发不得再起线程");
        assert!(
            control.finish_local_refresh(),
            "在途期间的触发合并为一次后续执行"
        );
        assert!(!control.finish_local_refresh(), "后续执行结束后回到空闲");
        assert!(control.begin_local_refresh(), "空闲后可再次启动");
    }

    #[test]
    fn with_artifact_releases_the_snapshot_lock_before_the_callback() {
        let control = SchedulerControl::new();
        *control.snapshot.lock().unwrap() = populated_snapshot();
        let lock_available = control.with_artifact(|_| control.snapshot.try_lock().is_ok());
        assert_eq!(
            lock_available,
            Some(true),
            "投递预警前必须释放 snapshot 锁 (AB-BA 死锁回归)"
        );
    }

    #[test]
    fn reset_snapshot_clears_disk_and_memory() {
        let root = temp_root();
        std::fs::write(root.join("snapshot.json"), b"{}").unwrap();
        let control = SchedulerControl::new();
        *control.snapshot.lock().unwrap() = populated_snapshot();
        assert!(control.snapshot.lock().unwrap().artifact().is_some());

        control.reset_snapshot(&root).unwrap();
        assert!(
            !root.join("snapshot.json").exists(),
            "清理缓存后磁盘快照必须删除"
        );
        assert!(
            control.snapshot.lock().unwrap().artifact().is_none(),
            "清理缓存后内存快照必须同时清空"
        );

        control.reset_snapshot(&root).unwrap(); // 幂等
        let _ = std::fs::remove_dir_all(&root);
    }
}
