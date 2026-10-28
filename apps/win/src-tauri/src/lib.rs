//! Windows 托盘常驻壳 —— 对齐 mac `MenuBarStatusItemController` 交互语义:
//! 托盘常驻 + 左键切换面板 + 右键菜单; 无装饰置顶面板, 失焦自动隐藏,
//! 位置记忆; 全局热键唤出; 后台调度器周期采集 (退避 + Toast, 常驻不门控)。

// 模块 pub 导出供 tests/ 集成测试覆盖 (GUI 入口 run() 除外)。
pub mod alerts;
pub mod collector;
pub mod credentials;
pub mod paths;
pub mod quota_policy;
pub mod reachability;
pub mod scheduler;
pub mod settings;
pub mod software_update;
pub mod tray_icon_renderer;

pub mod runtime_core;

#[cfg(feature = "desktop")]
mod desktop {
    use std::collections::BTreeMap;

    use super::{credentials, paths, scheduler, settings};
    use crate::runtime_core::{
        compute_dashboard_geometry, replace_hotkey, select_dashboard_placement,
        suspend_or_resume_hotkey, window_action, DashboardActivityState, DashboardOpenSource,
        MonitorBounds, ToggleDecision, TrayIconBounds, UnfocusDecision, WindowAction,
    };
    use bruce_win_viewmodel::analytics::AnalyticsRange;
    use bruce_win_viewmodel::model_catalog;
    use std::sync::Mutex;
    use tauri::{
        menu::{Menu, MenuItem},
        tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
        Emitter, Manager, PhysicalPosition, PhysicalSize, WindowEvent,
    };
    use tauri_plugin_global_shortcut::GlobalShortcutExt;

    use crate::scheduler::SchedulerControl;
    use crate::settings::AppSettings;
    use crate::software_update::desktop_impl::UpdateState;

    #[derive(Clone, Default)]
    struct TrayBoundsState(std::sync::Arc<std::sync::Mutex<Option<TrayIconBounds>>>);

    #[derive(Clone, Default)]
    struct ActivityState(std::sync::Arc<std::sync::Mutex<DashboardActivityState>>);

    fn rect_to_bounds(rect: &tauri::Rect, scale: f64) -> TrayIconBounds {
        let pos = rect.position.to_physical::<i32>(scale);
        let sz = rect.size.to_physical::<u32>(scale);
        TrayIconBounds {
            x: pos.x,
            y: pos.y,
            width: sz.width,
            height: sz.height,
        }
    }

    fn monitor_to_bounds(m: &tauri::Monitor) -> MonitorBounds {
        let scale = m.scale_factor();
        let pos = m.position();
        let size = m.size();
        let work = m.work_area();
        MonitorBounds {
            x: pos.x,
            y: pos.y,
            width: size.width,
            height: size.height,
            work_x: work.position.x,
            work_y: work.position.y,
            work_width: work.size.width,
            work_height: work.size.height,
            scale_factor: scale,
        }
    }

    /// 依据目标显示器物理工作区 (work_area) 与托盘/光标位置动态计算自适应尺寸并贴靠定位 (C016/C099):
    /// 托盘唤出贴托盘, 热键唤出在光标所在屏弹出 (托盘不在该屏时按该屏任务栏角落贴靠)。
    fn apply_dashboard_geometry(
        window: &tauri::WebviewWindow,
        tray_bounds: Option<&TrayIconBounds>,
        source: DashboardOpenSource,
    ) {
        let cursor = window
            .cursor_position()
            .ok()
            .map(|pos| (pos.x.round() as i32, pos.y.round() as i32));
        let (placed_monitor, tray_anchor) = match window.available_monitors() {
            Ok(monitors) => {
                let bounds: Vec<MonitorBounds> = monitors.iter().map(monitor_to_bounds).collect();
                let placement = select_dashboard_placement(&bounds, tray_bounds, cursor, source);
                (
                    placement
                        .monitor_index
                        .and_then(|idx| monitors.into_iter().nth(idx)),
                    placement.tray_anchor,
                )
            }
            Err(_) => (None, tray_bounds.copied()),
        };
        let target_monitor = placed_monitor
            .or_else(|| window.current_monitor().ok().flatten())
            .or_else(|| window.primary_monitor().ok().flatten());

        if let Some(m) = target_monitor {
            let monitor_bounds = monitor_to_bounds(&m);
            let geom = compute_dashboard_geometry(&monitor_bounds, tray_anchor.as_ref());
            let _ = window.set_size(PhysicalSize::new(geom.width, geom.height));
            let _ = window.set_position(PhysicalPosition::new(geom.x, geom.y));
        }
    }

    fn apply_preview_geometry(window: &tauri::WebviewWindow, tray_bounds: Option<&TrayIconBounds>) {
        let target_monitor = window
            .current_monitor()
            .ok()
            .flatten()
            .or_else(|| window.primary_monitor().ok().flatten());

        if let Some(m) = target_monitor {
            let monitor_bounds = monitor_to_bounds(&m);
            let geom = crate::runtime_core::compute_preview_geometry(&monitor_bounds, tray_bounds);
            let _ = window.set_size(PhysicalSize::new(geom.width, geom.height));
            let _ = window.set_position(PhysicalPosition::new(geom.x, geom.y));
        }
    }

    fn show_preview(app: &tauri::AppHandle) {
        // 互斥保障: 若主面板已打开，则不弹出微缩预览卡
        if let Some(dashboard) = app.get_webview_window("dashboard") {
            if dashboard.is_visible().unwrap_or(false) {
                return;
            }
        }
        let Some(preview_window) = app.get_webview_window("preview") else {
            return;
        };
        // C115: 托盘 Move 事件随指针移动连续触发; 预览卡已显示时直接返回,
        // 不再逐次读取 settings.json 并重复 set_size / set_position / show / always_on_top。
        if preview_window.is_visible().unwrap_or(false) {
            return;
        }

        let settings = settings::load_settings(&paths::data_root());
        if !settings.tray_hover_preview {
            return;
        }

        let tray_bounds = app
            .try_state::<TrayBoundsState>()
            .and_then(|s| s.0.lock().ok().and_then(|guard| *guard));
        apply_preview_geometry(&preview_window, tray_bounds.as_ref());
        let _ = preview_window.show();
        let _ = preview_window.set_always_on_top(true);
    }

    fn hide_preview(app: &tauri::AppHandle) {
        if let Some(window) = app.get_webview_window("preview") {
            let _ = window.hide();
        }
    }

    fn show_dashboard(app: &tauri::AppHandle, source: DashboardOpenSource) {
        hide_preview(app);
        if let Some(window) = app.get_webview_window("dashboard") {
            let tray_bounds = app
                .try_state::<TrayBoundsState>()
                .and_then(|s| s.0.lock().ok().and_then(|guard| *guard));
            apply_dashboard_geometry(&window, tray_bounds.as_ref(), source);
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_always_on_top(true);
            let _ = window.set_focus();
            let _ = window.emit("dashboard-show-transition", ());
            // 打开面板立即出新数据 (常驻周期之外的手动唤醒通道, C007)。
            app.state::<SchedulerControl>().request_manual_refresh();
        }
    }

    fn toggle_dashboard(app: &tauri::AppHandle) {
        hide_preview(app);
        if let Some(window) = app.get_webview_window("dashboard") {
            if window.is_visible().unwrap_or(false) {
                if let Some(activity) = app.try_state::<ActivityState>() {
                    if let Ok(mut guard) = activity.0.lock() {
                        guard.record_explicit_hide();
                    }
                }
                let _ = window.hide();
            } else {
                if let Some(activity) = app.try_state::<ActivityState>() {
                    if let Ok(mut guard) = activity.0.lock() {
                        guard.record_shown(std::time::Instant::now());
                    }
                }
                // 仅托盘菜单「显示看板」调用: 菜单弹在托盘处, 面板随托盘定位
                show_dashboard(app, DashboardOpenSource::Tray);
            }
        }
    }

    /// Validate and stage the new global shortcut before replacing the old one.
    fn register_hotkey(app: &tauri::AppHandle, hotkey: &str) -> Result<(), String> {
        if hotkey.is_empty() {
            return Ok(());
        }
        let parsed: tauri_plugin_global_shortcut::Shortcut =
            hotkey.parse().map_err(|_| "HOTKEY_INVALID".to_owned())?;
        app.global_shortcut()
            .on_shortcut(parsed, |app, _shortcut, event| {
                if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                    let is_visible = app
                        .get_webview_window("dashboard")
                        .and_then(|w| w.is_visible().ok())
                        .unwrap_or(false);
                    let decision = app
                        .try_state::<ActivityState>()
                        .and_then(|s| {
                            s.0.lock().ok().map(|mut g| {
                                g.on_hotkey_pressed(std::time::Instant::now(), is_visible)
                            })
                        })
                        .unwrap_or(if is_visible {
                            ToggleDecision::Hide
                        } else {
                            ToggleDecision::Show
                        });
                    match decision {
                        ToggleDecision::Show => show_dashboard(app, DashboardOpenSource::Hotkey),
                        ToggleDecision::Hide => {
                            if let Some(window) = app.get_webview_window("dashboard") {
                                let _ = window.hide();
                            }
                        }
                        ToggleDecision::Ignore => {}
                    }
                }
            })
            .map_err(|_| "HOTKEY_REGISTER_FAILED".into())
    }

    #[derive(Default)]
    struct RegisteredHotkey(Mutex<String>);

    /// 进入 / 退出热键录制态 (C099): 先翻转防误弹开关, 再真正注销 / 恢复已生效热键 ——
    /// RegisterHotKey 会截走组合键, 只挂起回调时设置页仍录不到当前热键。
    fn apply_hotkey_recording(
        app: &tauri::AppHandle,
        current: &mut String,
        recording: bool,
    ) -> Result<(), String> {
        let was_recording = app
            .try_state::<ActivityState>()
            .and_then(|s| {
                s.0.lock()
                    .ok()
                    .map(|mut g| g.set_recording_hotkey(recording))
            })
            .unwrap_or(false);
        let result = suspend_or_resume_hotkey(
            current,
            was_recording,
            recording,
            |key| register_hotkey(app, key),
            |key| {
                app.global_shortcut()
                    .unregister(key)
                    .map_err(|_| "HOTKEY_SUSPEND_FAILED".into())
            },
        );
        if result.is_err() && !recording {
            // 挂起时注销未成功 (热键仍在册) 则视为已恢复; 否则热键已失效, 清空登记,
            // 避免后续替换去注销一个不存在的注册。
            if app.global_shortcut().is_registered(current.as_str()) {
                return Ok(());
            }
            current.clear();
            return Err("HOTKEY_RESUME_FAILED".into());
        }
        result
    }

    // MARK: - IPC 命令

    #[tauri::command]
    fn get_dashboard(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        scheduler::cached_panel(&app)
    }

    #[tauri::command]
    fn get_runtime_info(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let root = paths::data_root();
        let panel = scheduler::cached_panel(&app)?;
        let artifact = scheduler::cached_artifact(&app);
        // 「模型计费」表所需: 今日总费用 (artifact totalCostUsd) 与按模型今日用量汇总
        let model_usage = artifact
            .as_ref()
            .map(crate::runtime_core::model_usage)
            .unwrap_or_default();
        let total_cost = artifact
            .as_ref()
            .and_then(|value| value.get("totalCostUsd"))
            .and_then(serde_json::Value::as_f64);
        let generated_at = artifact
            .as_ref()
            .and_then(|value| value.get("generatedAt"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        Ok(serde_json::json!({
            "version": app.package_info().version.to_string(),
            "dataRoot": root,
            "cacheRoot": paths::collector_cache_root(),
            "snapshotPath": root.join("snapshot.json"),
            "status": panel["runtime"],
            "diagnostics": panel["diagnostics"],
            "usage": panel["usage"],
            "totalCostUsd": total_cost,
            "modelUsage": model_usage,
            "generatedAt": generated_at
        }))
    }

    /// 清理用量缓存: 仅删除本应用快照 (与 mac「清理用量缓存」语义一致 —— 不动配置、
    /// 凭证与账单统计); 随后请求一次刷新以重建快照。
    #[tauri::command]
    fn clear_snapshot_cache(app: tauri::AppHandle) -> Result<(), String> {
        crate::runtime_core::clear_snapshot(&paths::data_root())?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    /// 导出账单 CSV: 列与 mac `billingReportCSV` 一致, UTF-8 BOM 前置 (Excel 识别中文),
    /// 写入 `<dataRoot>/exports/` 并返回完整路径。Windows 侧不弹系统保存对话框 (见
    /// design 05 §4.4 的适配取舍), 路径由界面回显。
    #[tauri::command]
    fn export_billing(
        app: tauri::AppHandle,
        path: Option<String>,
    ) -> Result<serde_json::Value, String> {
        let Some(artifact) = scheduler::cached_artifact(&app) else {
            return Err("暂无可导出的用量数据, 请先刷新".to_owned());
        };
        let csv = crate::runtime_core::billing_csv(&artifact)
            .ok_or_else(|| "暂无可导出的用量数据, 请先刷新".to_owned())?;
        let target = crate::runtime_core::resolve_export_path(
            &paths::data_root(),
            "Bruce-billing",
            "csv",
            path.as_deref(),
        )?;
        crate::runtime_core::write_export(&target, format!("\u{feff}{csv}").as_bytes())?;
        Ok(serde_json::json!({ "path": target }))
    }

    /// 设置页「Agent 用量」工作台快照 (C070): 计算见 viewmodel `analytics` (mac golden 对拍)。
    #[tauri::command]
    fn get_usage_analytics(
        app: tauri::AppHandle,
        range: String,
    ) -> Result<bruce_win_viewmodel::analytics::AnalyticsSnapshot, String> {
        let range = AnalyticsRange::parse(&range).ok_or("UNKNOWN_RANGE")?;
        let settings = settings::load_settings(&paths::data_root());
        let artifact = scheduler::cached_artifact(&app);
        Ok(crate::runtime_core::usage_analytics(
            artifact.as_ref(),
            settings.usage_enabled,
            range,
        ))
    }

    /// 工作台「导出 CSV 账单」(mac `exportCSV`): 所选范围的归一模型; UTF-8 BOM 前置 (Excel)。
    #[tauri::command]
    fn export_workbench_csv(
        app: tauri::AppHandle,
        range: String,
        path: Option<String>,
    ) -> Result<serde_json::Value, String> {
        let snapshot = get_usage_analytics(app, range)?;
        let csv = crate::runtime_core::workbench_csv(&snapshot)
            .ok_or_else(|| "当前范围暂无模型用量明细, 请先刷新".to_owned())?;
        let target = crate::runtime_core::resolve_export_path(
            &paths::data_root(),
            "bruce_agent_usage",
            "csv",
            path.as_deref(),
        )?;
        crate::runtime_core::write_export(&target, format!("\u{feff}{csv}").as_bytes())?;
        Ok(serde_json::json!({ "path": target }))
    }

    /// 工作台「导出 JSON 明细」(mac `exportJSON`): 完整 artifact, 键排序缩进。
    #[tauri::command]
    fn export_workbench_json(
        app: tauri::AppHandle,
        path: Option<String>,
    ) -> Result<serde_json::Value, String> {
        let Some(artifact) = scheduler::cached_artifact(&app) else {
            return Err("当前暂无已缓存的 Agent 用量数据".to_owned());
        };
        let body =
            serde_json::to_vec_pretty(&artifact).map_err(|_| "EXPORT_WRITE_FAILED".to_owned())?;
        let target = crate::runtime_core::resolve_export_path(
            &paths::data_root(),
            "bruce_agent_usage_artifact",
            "json",
            path.as_deref(),
        )?;
        crate::runtime_core::write_export(&target, &body)?;
        Ok(serde_json::json!({ "path": target }))
    }

    /// 导出诊断报告: 脱敏单文件 JSON (mac 为 zip 包, Windows 侧不引入压缩依赖)。
    #[tauri::command]
    fn export_diagnostics(
        app: tauri::AppHandle,
        path: Option<String>,
    ) -> Result<serde_json::Value, String> {
        let panel = scheduler::cached_panel(&app)?;
        let report = crate::runtime_core::diagnostics_report(
            &app.package_info().version.to_string(),
            &panel,
        );
        let target = crate::runtime_core::resolve_export_path(
            &paths::data_root(),
            "Bruce-diagnostics",
            "json",
            path.as_deref(),
        )?;
        let body =
            serde_json::to_vec_pretty(&report).map_err(|_| "EXPORT_WRITE_FAILED".to_owned())?;
        crate::runtime_core::write_export(&target, &body)?;
        Ok(serde_json::json!({ "path": target }))
    }

    /// 设置页「模型计费」的展示目录 (行集 / 显示名 / 厂商 / 单价), 供表格与校准弹窗消费;
    /// 与采集端计费同源于 `pricing-catalog.json` (C108)。
    #[tauri::command]
    fn get_model_prices() -> serde_json::Value {
        model_catalog::as_json()
    }

    #[tauri::command]
    fn get_settings() -> AppSettings {
        settings::load_settings(&paths::data_root())
    }

    #[tauri::command]
    fn save_settings_command(
        app: tauri::AppHandle,
        mut settings: AppSettings,
    ) -> Result<AppSettings, String> {
        settings::validate_settings(&settings)?;
        // 启用集合恒由 subscription_providers 派生 (C090 / 设计规则 22): 归一后落盘并回传,
        // 前端据此刷新本地缓存, 避免两处启用口径漂移。
        settings::sync_enabled_providers(&mut settings);
        let previous = settings::load_settings(&paths::data_root());
        let registered = app.state::<RegisteredHotkey>();
        let mut current = registered.0.lock().map_err(|_| "HOTKEY_LOCK_FAILED")?;
        // 录制态下旧热键处于注销状态: 先恢复登记, 替换流程才能按原语义注销旧键。
        let _ = apply_hotkey_recording(&app, &mut current, false);
        replace_hotkey(
            &current,
            &settings.hotkey,
            |key| register_hotkey(&app, key),
            |key| {
                app.global_shortcut()
                    .unregister(key)
                    .map_err(|_| "HOTKEY_UNREGISTER_FAILED".into())
            },
            || settings::save_settings(&paths::data_root(), &settings),
        )?;
        *current = settings.hotkey.clone();
        drop(current);
        let _ = app.emit("settings-updated", &settings);
        scheduler::publish(&app);
        // 设置即时生效 (C069): 只有采集输入变化才触发全量采集, 其余变更仅重新发布看板
        if settings::requires_collection(&previous, &settings) {
            app.state::<SchedulerControl>().request_manual_refresh();
        }
        Ok(settings)
    }

    #[tauri::command]
    fn credential_allowlist() -> Vec<String> {
        collector_bridge::ALLOWED_CREDENTIAL_FIELDS
            .iter()
            .map(|field| (*field).to_owned())
            .collect()
    }

    #[tauri::command]
    fn get_credential_fields() -> Vec<String> {
        credentials::load_credentials(&paths::data_root())
            .into_keys()
            .collect()
    }

    /// 凭证合并语义 (明文凭证不回显前端):
    /// 请求中带值的键覆盖, 显式 null 删除, 未提及的键保留原值。
    #[tauri::command]
    fn save_credentials_command(
        app: tauri::AppHandle,
        payloads: BTreeMap<String, Option<serde_json::Value>>,
    ) -> Result<(), String> {
        let root = paths::data_root();
        credentials::save_credentials_patch(&root, &payloads)?;
        // 凭证变化后立即刷新, 让订阅卡尽快呈现 出站额度。
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    #[tauri::command]
    fn get_credential_accounts() -> Vec<serde_json::Value> {
        credentials::credential_accounts(&paths::data_root())
    }

    /// 被读取侧丢弃的账号原因 (C092): 只回字段 / 账号 ID / 原因文案, 不含凭据值。
    #[tauri::command]
    fn get_credential_rejections() -> Vec<serde_json::Value> {
        credentials::credential_rejections(&paths::data_root())
    }

    #[tauri::command]
    fn remove_credential_account(
        app: tauri::AppHandle,
        field: String,
        account_id: String,
    ) -> Result<(), String> {
        credentials::remove_credential_account(&paths::data_root(), &field, &account_id)?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    #[tauri::command]
    fn save_credential_account(
        app: tauri::AppHandle,
        field: String,
        account_id: String,
        payload: serde_json::Value,
    ) -> Result<(), String> {
        credentials::save_credential_account(&paths::data_root(), &field, &account_id, &payload)?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    /// 重命名账号 (T18): 只改 display_name, 成功后触发定向刷新。
    #[tauri::command]
    fn rename_credential_account(
        app: tauri::AppHandle,
        field: String,
        account_id: String,
        display_name: String,
    ) -> Result<(), String> {
        credentials::rename_credential_account(
            &paths::data_root(),
            &field,
            &account_id,
            &display_name,
        )?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    /// 用系统默认浏览器打开外部地址 (C084)。走 Win32 `ShellExecuteW`, 不新增依赖;
    /// 非 Windows 构建下不可用 (开发机只跑测试, 真实打开由 Windows 侧承担)。
    #[cfg(windows)]
    fn open_external_url(url: &str) -> Result<(), String> {
        use windows_sys::Win32::UI::Shell::ShellExecuteW;
        let operation: Vec<u16> = "open\0".encode_utf16().collect();
        let file: Vec<u16> = format!("{url}\0").encode_utf16().collect();
        // Win32 约定: 返回值 <= 32 表示失败。
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                operation.as_ptr(),
                file.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1, // SW_SHOWNORMAL
            )
        };
        if result as isize > 32 {
            Ok(())
        } else {
            Err("无法打开系统浏览器".to_owned())
        }
    }

    #[cfg(not(windows))]
    fn open_external_url(_url: &str) -> Result<(), String> {
        Err("仅 Windows 支持打开外部浏览器".to_owned())
    }

    #[tauri::command]
    fn import_codex_auth(app: tauri::AppHandle, auth: serde_json::Value) -> Result<(), String> {
        credentials::import_codex_auth(&paths::data_root(), &auth)?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    /// 阻塞型网络请求移出主线程 (C109)。
    ///
    /// Tauri 2 的同步 command 在主线程执行: 期间托盘、看板与设置窗口全部失去响应,
    /// 网络慢时最长卡住整个请求超时 (设备码 30 s / DeepSeek 试查 8 s)。凡含出站
    /// HTTP 的 command 一律声明为 `async` 并经此放到阻塞线程池, 不占用 Tokio 工作线程。
    async fn off_main_thread<T, F>(work: F) -> Result<T, String>
    where
        T: Send + 'static,
        F: FnOnce() -> T + Send + 'static,
    {
        tauri::async_runtime::spawn_blocking(work)
            .await
            .map_err(|_| "BACKGROUND_TASK_FAILED".to_owned())
    }

    /// `ShellExecuteW` 可能委托经 COM 激活的 Shell 扩展, 须在已初始化 COM 的主 (STA)
    /// 线程调用: async command 运行在 Tokio 工作线程, 故派回主线程执行并等待结果 (C109)。
    async fn open_external_url_on_main_thread(app: &tauri::AppHandle, url: &'static str) -> bool {
        let (sender, receiver) = std::sync::mpsc::channel();
        let scheduled = app.run_on_main_thread(move || {
            let _ = sender.send(open_external_url(url).is_ok());
        });
        if scheduled.is_err() {
            return false;
        }
        off_main_thread(move || receiver.recv().unwrap_or(false))
            .await
            .unwrap_or(false)
    }

    /// Codex 设备码登录第一步 (C084 / 设计规则 23): 申请设备码并尝试打开官方验证页。
    /// 只由用户在设置页点击触发。打不开浏览器不算致命 —— 前端仍展示 user_code 与地址。
    #[tauri::command]
    async fn codex_device_start(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let authorization = off_main_thread(credentials::codex_device_start)
            .await?
            .map_err(|e| e.message())?;
        let browser_opened =
            open_external_url_on_main_thread(&app, credentials::CODEX_VERIFICATION_URL).await;
        Ok(serde_json::json!({
            "deviceAuthId": authorization.device_auth_id,
            "userCode": authorization.user_code,
            "verificationUrl": credentials::CODEX_VERIFICATION_URL,
            "intervalSeconds": authorization.interval_secs,
            "expiresInSeconds": authorization.expires_in_secs,
            "browserOpened": browser_opened,
        }))
    }

    /// Codex 设备码登录第二步: 单次轮询 (前端按 interval 驱动, 便于呈现等待 / 完成阶段)。
    /// 授权完成后在同一次调用里换码、写账号并请求定向刷新; 任一步失败 fail-closed, 不写半成品。
    #[tauri::command]
    async fn codex_device_poll(
        app: tauri::AppHandle,
        device_auth_id: String,
        user_code: String,
        issued_at_millis: i64,
        expires_in_seconds: u64,
    ) -> Result<serde_json::Value, String> {
        off_main_thread(move || {
            codex_device_poll_blocking(
                &app,
                device_auth_id,
                user_code,
                issued_at_millis,
                expires_in_seconds,
            )
        })
        .await?
    }

    /// 单次轮询 + 授权后换码落库 (均为阻塞 HTTP / 磁盘), 只在 `off_main_thread` 内调用。
    fn codex_device_poll_blocking(
        app: &tauri::AppHandle,
        device_auth_id: String,
        user_code: String,
        issued_at_millis: i64,
        expires_in_seconds: u64,
    ) -> Result<serde_json::Value, String> {
        let elapsed = chrono::Utc::now().timestamp_millis() - issued_at_millis;
        if elapsed >= (expires_in_seconds as i64) * 1000 {
            return Ok(serde_json::json!({"status": "expired"}));
        }
        let authorization = credentials::CodexDeviceAuthorization {
            device_auth_id,
            user_code,
            interval_secs: 0,
            expires_in_secs: expires_in_seconds,
        };
        match credentials::codex_device_poll_once(&authorization).map_err(|e| e.message())? {
            credentials::CodexPollOutcome::Pending => Ok(serde_json::json!({"status": "pending"})),
            credentials::CodexPollOutcome::Authorized(grant) => {
                let account =
                    credentials::codex_device_exchange(&grant, chrono::Utc::now().timestamp())
                        .map_err(|e| e.message())?;
                credentials::save_credential_account(
                    &paths::data_root(),
                    "codexQuotaAccounts",
                    &account.account_id,
                    &account.to_payload(),
                )?;
                app.state::<SchedulerControl>().request_manual_refresh();
                Ok(serde_json::json!({
                    "status": "authorized",
                    "accountId": account.account_id,
                    "email": account.email,
                }))
            }
        }
    }

    /// 重新打开 Codex 验证页 (C084)。
    #[tauri::command]
    fn open_verification_page() -> Result<(), String> {
        open_external_url(credentials::CODEX_VERIFICATION_URL)
    }

    /// 只读发现本机 Codex 账号 (C084): 读 CLI 与 CC Switch 文件, 只写元数据、不导入令牌。
    #[tauri::command]
    fn codex_import_discovered(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let added = credentials::import_codex_discovered(&paths::data_root(), &paths::home_root())?;
        if added > 0 {
            app.state::<SchedulerControl>().request_manual_refresh();
        }
        Ok(serde_json::json!({"added": added}))
    }

    /// 两个 Codex 发现来源文件是否存在 (设置页按钮显隐)。
    #[tauri::command]
    fn codex_discovery_sources() -> serde_json::Value {
        let (cli_auth, cc_switch) = credentials::codex_discovery_sources(&paths::home_root());
        serde_json::json!({"cliAuth": cli_auth, "ccSwitch": cc_switch})
    }

    /// 本机 Claude CLI 登录态只读探测 (C075, 设置页状态文案): 返回状态与已存账号数。
    #[tauri::command]
    fn claude_local_status() -> serde_json::Value {
        let home = paths::home_root();
        let status = credentials::local_claude_status(&home, chrono::Utc::now().timestamp_millis());
        let stored = credentials::load_credentials(&paths::data_root())
            .get("claudeQuotaAccounts")
            .and_then(serde_json::Value::as_object)
            .map(|accounts| accounts.len())
            .unwrap_or(0);
        serde_json::json!({"status": status.as_str(), "storedAccountCount": stored})
    }

    /// 读取本机 Claude 登录态并保存为 `claude-cli` 账号 (C075): 只读外部文件, 不回写。
    #[tauri::command]
    fn import_claude_from_local(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let status = credentials::follow_local_claude(&paths::data_root(), &paths::home_root())?;
        if status != credentials::ClaudeLocalStatus::NotFound {
            app.state::<SchedulerControl>().request_manual_refresh();
        }
        Ok(serde_json::json!({"status": status.as_str()}))
    }

    /// 本机 Grok CLI 登录态只读探测 (C085, 设置页状态文案): 返回状态与已存账号数。
    #[tauri::command]
    fn grok_local_status() -> serde_json::Value {
        let home = paths::home_root();
        let status = credentials::local_grok_status(&home, chrono::Utc::now().timestamp_millis());
        let stored = credentials::load_credentials(&paths::data_root())
            .get("grokQuotaAccounts")
            .and_then(serde_json::Value::as_object)
            .map(|accounts| accounts.len())
            .unwrap_or(0);
        serde_json::json!({"status": status.as_str(), "storedAccountCount": stored})
    }

    /// 读取本机 Grok 登录态并保存为 `grok-cli` 账号 (C085): 只读外部文件, 不回写。
    #[tauri::command]
    fn import_grok_from_local(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let status = credentials::follow_local_grok(&paths::data_root(), &paths::home_root())?;
        if status != credentials::GrokLocalStatus::NotFound {
            app.state::<SchedulerControl>().request_manual_refresh();
        }
        Ok(serde_json::json!({"status": status.as_str()}))
    }

    /// 订阅 Provider 验证 (C082): 结构校验口径与写入路径一致, 返回
    /// `{status, reason}`; 前端据此落 `subscriptionProviders` 的验证状态。
    /// DeepSeek 在结构校验通过后追加一次真实试查 (C083)。
    /// Claude 无已存凭据时按本机 CLI 只读跟随判定 (C091)。
    #[tauri::command]
    async fn verify_subscription(provider: String) -> serde_json::Value {
        let verified = off_main_thread(move || {
            credentials::verify_subscription_following_local(
                &paths::data_root(),
                &paths::home_root(),
                &provider,
                chrono::Utc::now().timestamp_millis(),
            )
        })
        .await;
        match verified {
            Ok(result) => serde_json::json!({"status": result.status, "reason": result.reason}),
            Err(_) => serde_json::json!({"status": "failed", "reason": "验证任务异常中止, 请重试"}),
        }
    }

    /// 移除服务 (C089): 一次性删除该 Provider 的全部凭据; 失败时一个都不删。
    #[tauri::command]
    fn remove_provider_credentials(app: tauri::AppHandle, provider: String) -> Result<(), String> {
        credentials::remove_provider_credentials(&paths::data_root(), &provider)?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
    }

    /// CC Switch 库是否可用 (C083): 决定火山引擎对话框是否显示「从 CC Switch 导入」。
    #[tauri::command]
    fn ccswitch_status() -> serde_json::Value {
        serde_json::json!({
            "available": credentials::ccswitch_database_path(&paths::home_root()).is_some()
        })
    }

    /// 从 CC Switch 只读导入火山引擎 AK/SK 并保存 (C083); 不修改外部库。
    #[tauri::command]
    fn import_volcengine_from_ccswitch(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
        let result = credentials::import_volcengine_from_cc_switch(
            &paths::data_root(),
            &paths::home_root(),
        )?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(serde_json::json!({"status": result.status, "reason": result.reason}))
    }

    // ── StepFun 网页登录窗口与 Cookie 自动捕获 (C086 / 设计规则 24) ───────────────

    const STEPFUN_LOGIN_WINDOW_LABEL: &str = "stepfun-login";

    fn parse_stepfun_site(raw: &str) -> Result<credentials::StepFunSite, String> {
        credentials::StepFunSite::parse(raw).ok_or_else(|| "未知 StepFun 站点".to_owned())
    }

    /// 从 WebviewWindow 采集候选 Cookie。
    ///
    /// 调用方必须位于 `async` command 或独立线程: WebView2 的 `cookies()` / `cookies_for_url()`
    /// 在 Windows 同步 command 中会因 STA 重入死锁 (wry#583)。
    fn collect_stepfun_cookies(
        window: &tauri::WebviewWindow,
        site: credentials::StepFunSite,
    ) -> Vec<credentials::StepFunCookieCandidate> {
        let mut out = Vec::new();
        if let Ok(home_url) = site.home_url().parse::<tauri::Url>() {
            if let Ok(cookies) = window.cookies_for_url(home_url) {
                for cookie in cookies {
                    out.push(credentials::StepFunCookieCandidate {
                        name: cookie.name().to_owned(),
                        value: cookie.value().to_owned(),
                        domain: cookie.domain().unwrap_or(site.domain_keyword()).to_owned(),
                    });
                }
            }
        }
        if let Ok(cookies) = window.cookies() {
            for cookie in cookies {
                out.push(credentials::StepFunCookieCandidate {
                    name: cookie.name().to_owned(),
                    value: cookie.value().to_owned(),
                    domain: cookie.domain().unwrap_or_default().to_owned(),
                });
            }
        }
        out
    }

    /// 打开或切换 StepFun 网页登录窗口 (`WebviewUrl::External`, async command 避免 STA 死锁)。
    #[tauri::command]
    async fn stepfun_web_login_open(
        app: tauri::AppHandle,
        site: String,
    ) -> Result<serde_json::Value, String> {
        let site = parse_stepfun_site(&site)?;
        let target_url: tauri::Url = site
            .base_url()
            .parse()
            .map_err(|_| "StepFun 订阅页地址无效".to_owned())?;
        let title = format!("登录阶跃星辰开放平台 · {}", site.display_name());

        if let Some(window) = app.get_webview_window(STEPFUN_LOGIN_WINDOW_LABEL) {
            let _ = window.set_title(&title);
            let _ = window.navigate(target_url);
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_focus();
        } else {
            let app_for_load = app.clone();
            let window = tauri::WebviewWindowBuilder::new(
                &app,
                STEPFUN_LOGIN_WINDOW_LABEL,
                tauri::WebviewUrl::External(target_url),
            )
            .title(&title)
            .inner_size(580.0, 700.0)
            .min_inner_size(540.0, 640.0)
            .resizable(true)
            .center()
            .user_agent(credentials::STEPFUN_DESKTOP_CHROME_UA)
            .on_page_load(move |_window, payload| {
                let loading = matches!(payload.event(), tauri::webview::PageLoadEvent::Started);
                let _ = app_for_load.emit(
                    "stepfun-page-load",
                    serde_json::json!({
                        "url": payload.url().as_str(),
                        "loading": loading,
                    }),
                );
            })
            .build()
            .map_err(|e| format!("无法打开 StepFun 登录窗口: {e}"))?;
            let _ = window.show();
            let _ = window.set_focus();
        }

        Ok(serde_json::json!({
            "site": site.as_str(),
            "url": site.base_url(),
            "title": title,
            "intervalMs": 2000,
        }))
    }

    /// 网页登录工具栏动作: 后退 / 前进 / 刷新 / 订阅页 / 平台首页。
    #[tauri::command]
    async fn stepfun_web_login_action(
        app: tauri::AppHandle,
        action: String,
        site: Option<String>,
    ) -> Result<serde_json::Value, String> {
        let window = app
            .get_webview_window(STEPFUN_LOGIN_WINDOW_LABEL)
            .ok_or_else(|| "StepFun 登录窗口尚未打开".to_owned())?;
        let parsed_site = site
            .as_deref()
            .and_then(credentials::StepFunSite::parse)
            .unwrap_or(credentials::StepFunSite::Domestic);
        match action.as_str() {
            "back" => {
                let _ = window.eval("window.history.back()");
            }
            "forward" => {
                let _ = window.eval("window.history.forward()");
            }
            "reload" => {
                let _ = window.reload();
            }
            "plan" => {
                if let Ok(url) = parsed_site.base_url().parse::<tauri::Url>() {
                    let _ = window.navigate(url);
                }
            }
            "home" => {
                if let Ok(url) = parsed_site.home_url().parse::<tauri::Url>() {
                    let _ = window.navigate(url);
                }
            }
            _ => return Err("未知网页操作".to_owned()),
        }
        let current_url = window.url().map(|u| u.to_string()).unwrap_or_default();
        Ok(serde_json::json!({ "url": current_url }))
    }

    /// 双轨自动轮询与手动「我已登录，立即绑定」共用的异步 Cookie 提取与远程校验入口。
    ///
    /// 必须保持 `async fn`: 在 Tokio 工作线程上调用 `cookies_for_url` / `cookies` 与远程
    /// `QueryStepPlanRateLimit` 校验, 绝不阻塞 Win32 STA 主线程。
    #[tauri::command]
    async fn stepfun_web_login_poll(
        app: tauri::AppHandle,
        site: String,
        manual: bool,
    ) -> Result<serde_json::Value, String> {
        let site = parse_stepfun_site(&site)?;
        let Some(window) = app.get_webview_window(STEPFUN_LOGIN_WINDOW_LABEL) else {
            return Ok(serde_json::json!({
                "status": "closed",
                "message": "登录窗口已关闭",
                "currentUrl": "",
            }));
        };
        let current_url = window.url().map(|u| u.to_string()).unwrap_or_default();
        let cookies = collect_stepfun_cookies(&window, site);
        match credentials::capture_stepfun_cookie(
            &paths::data_root(),
            site,
            &current_url,
            &cookies,
            manual,
        )? {
            credentials::StepFunCaptureOutcome::Captured {
                site: captured_site,
                account_id,
                message,
                ..
            } => {
                let _ = window.close();
                app.state::<SchedulerControl>().request_manual_refresh();
                Ok(serde_json::json!({
                    "status": "captured",
                    "site": captured_site.as_str(),
                    "accountId": account_id,
                    "message": message,
                    "currentUrl": current_url,
                }))
            }
            credentials::StepFunCaptureOutcome::Waiting { message } => Ok(serde_json::json!({
                "status": "waiting",
                "message": message,
                "currentUrl": current_url,
            })),
            credentials::StepFunCaptureOutcome::Failed { message } => Ok(serde_json::json!({
                "status": "failed",
                "message": message,
                "currentUrl": current_url,
            })),
        }
    }

    /// 清除当前站点域下的全部登录 Cookie 并重新加载订阅页 (对齐 `clearSessionAndReload`)。
    #[tauri::command]
    async fn stepfun_web_login_clear_session(
        app: tauri::AppHandle,
        site: String,
    ) -> Result<serde_json::Value, String> {
        let site = parse_stepfun_site(&site)?;
        let window = app
            .get_webview_window(STEPFUN_LOGIN_WINDOW_LABEL)
            .ok_or_else(|| "StepFun 登录窗口尚未打开".to_owned())?;
        if let Ok(home_url) = site.home_url().parse::<tauri::Url>() {
            if let Ok(cookies) = window.cookies_for_url(home_url) {
                for cookie in cookies {
                    let _ = window.delete_cookie(cookie);
                }
            }
        }
        if let Ok(cookies) = window.cookies() {
            for cookie in cookies {
                let domain = cookie.domain().unwrap_or_default();
                if credentials::stepfun_cookie_matches_site(domain, site) {
                    let _ = window.delete_cookie(cookie);
                }
            }
        }
        if let Ok(base_url) = site.base_url().parse::<tauri::Url>() {
            let _ = window.navigate(base_url);
        }
        Ok(serde_json::json!({
            "status": "cleared",
            "url": site.base_url(),
            "message": format!("已清空 {} 登录缓存，正在刷新...", site.display_name()),
        }))
    }

    /// 关闭 StepFun 网页登录窗口。
    #[tauri::command]
    async fn stepfun_web_login_close(app: tauri::AppHandle) -> Result<(), String> {
        if let Some(window) = app.get_webview_window(STEPFUN_LOGIN_WINDOW_LABEL) {
            let _ = window.close();
        }
        Ok(())
    }

    #[tauri::command]
    fn refresh_now(control: tauri::State<SchedulerControl>) {
        control.request_manual_refresh();
    }

    /// 订阅卡 Provider 定向刷新 (section ID 由后端归一为 provider, 未知一律拒绝)。
    #[tauri::command]
    fn refresh_subscription(app: tauri::AppHandle, section_id: String) -> Result<(), String> {
        scheduler::refresh_subscription(&app, &section_id)
    }

    #[tauri::command]
    fn hide_dashboard(app: tauri::AppHandle) {
        if let Some(activity) = app.try_state::<ActivityState>() {
            if let Ok(mut guard) = activity.0.lock() {
                guard.record_explicit_hide();
            }
        }
        if let Some(window) = app.get_webview_window("dashboard") {
            let _ = window.hide();
        }
        hide_preview(&app);
    }

    #[tauri::command]
    fn hide_preview_window(app: tauri::AppHandle) -> Result<(), String> {
        hide_preview(&app);
        Ok(())
    }

    #[tauri::command]
    fn expand_dashboard(app: tauri::AppHandle) -> Result<(), String> {
        hide_preview(&app);
        show_dashboard(&app, DashboardOpenSource::Tray);
        Ok(())
    }

    /// 设置页热键录制态门控 (C099): 录制期间注销已生效热键, 设置页才能重新录到同一组合键;
    /// 退出录制即恢复注册, 恢复失败回 `HOTKEY_RESUME_FAILED` 供前端提示。
    #[tauri::command]
    fn set_hotkey_recording(app: tauri::AppHandle, recording: bool) -> Result<(), String> {
        let registered = app.state::<RegisteredHotkey>();
        let mut current = registered.0.lock().map_err(|_| "HOTKEY_LOCK_FAILED")?;
        apply_hotkey_recording(&app, &mut current, recording)
    }

    #[tauri::command]
    fn quit_app(app: tauri::AppHandle) {
        app.exit(0);
    }

    /// 打开设置窗口 (mac SettingsWindowController 单实例语义: 已存在则置前)。
    /// 静态配置于 tauri.conf.json，随应用在主线程完成 WebView2 初始化并隐藏预备。
    /// 若窗口因异常缺失，在主线程兜底创建并显式呈现。
    #[tauri::command]
    fn open_settings(app: tauri::AppHandle) {
        if let Some(window) = app.get_webview_window("settings") {
            let _ = window.show();
            let _ = window.unminimize();
            let _ = window.set_focus();
            return;
        }
        let app_clone = app.clone();
        let _ = app.run_on_main_thread(move || {
            if let Ok(window) = tauri::WebviewWindowBuilder::new(
                &app_clone,
                "settings",
                tauri::WebviewUrl::App("settings.html".into()),
            )
            .title("Bruce 设置")
            .inner_size(1040.0, 680.0)
            .min_inner_size(980.0, 620.0)
            .resizable(true)
            .center()
            .build()
            {
                let _ = window.show();
                let _ = window.set_focus();
            }
        });
    }

    // MARK: - 入口

    pub fn run() {
        tauri::Builder::default()
            .plugin(tauri_plugin_notification::init())
            .plugin(tauri_plugin_global_shortcut::Builder::new().build())
            // 导出文件的系统保存对话框 (C033): 与 mac NSSavePanel 等价
            .plugin(tauri_plugin_dialog::init())
            // 应用内软件更新 (T11): latest.json 检查 + minisign 验签 + NSIS 静默安装
            .plugin(tauri_plugin_updater::Builder::new().build())
            .setup(move |app| {
                // 调度控制状态 (托盘菜单/命令/热键共享)。
                let control = SchedulerControl::new();
                if let Ok(mut state) = control.snapshot.lock() {
                    *state = crate::runtime_core::SnapshotState::load(&paths::data_root());
                }
                app.manage(control);
                app.manage(RegisteredHotkey::default());
                app.manage(TrayBoundsState::default());
                app.manage(ActivityState::default());
                // 软件更新状态机 + 自动检查 (启动 30 秒后首查, 每 24 小时一次)。
                app.manage(UpdateState::default());
                crate::software_update::desktop_impl::spawn_auto_check(app.handle().clone());
                // 后台调度器 (常驻周期采集 + 退避 + Toast)。
                // 全局热键 (设置可配)。
                let hotkey = settings::load_settings(&paths::data_root()).hotkey;
                if let Err(error) = register_hotkey(app.handle(), &hotkey) {
                    eprintln!("全局热键注册失败: {error}");
                } else if let Ok(mut registered) = app.state::<RegisteredHotkey>().0.lock() {
                    *registered = hotkey;
                }

                let show = MenuItem::with_id(app, "show", "显示看板", true, None::<&str>)?;
                let refresh = MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>)?;
                let settings_item = MenuItem::with_id(app, "settings", "设置", true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "退出 Bruce", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&show, &refresh, &settings_item, &quit])?;
                TrayIconBuilder::with_id("bruce")
                    .icon(tauri::image::Image::from_bytes(include_bytes!(
                        "../icons/icon.png"
                    ))?)
                    .tooltip("Bruce")
                    .menu(&menu)
                    .show_menu_on_left_click(false)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "show" => toggle_dashboard(app),
                        "refresh" => app.state::<SchedulerControl>().request_manual_refresh(),
                        "settings" => open_settings(app.clone()),
                        "quit" => app.exit(0),
                        _ => {}
                    })
                    .on_tray_icon_event(move |tray, event| {
                        let app = tray.app_handle();
                        let tray_rect = match &event {
                            TrayIconEvent::Click { rect, .. }
                            | TrayIconEvent::DoubleClick { rect, .. }
                            | TrayIconEvent::Enter { rect, .. }
                            | TrayIconEvent::Move { rect, .. } => Some(rect),
                            _ => None,
                        };
                        if let Some(rect) = tray_rect {
                            let scale = app
                                .get_webview_window("dashboard")
                                .and_then(|w| w.primary_monitor().ok().flatten())
                                .map(|m| m.scale_factor())
                                .unwrap_or(1.0);
                            let bounds = rect_to_bounds(rect, scale);
                            if bounds.width > 0 && bounds.height > 0 {
                                if let Some(state) = app.try_state::<TrayBoundsState>() {
                                    if let Ok(mut lock) = state.0.lock() {
                                        *lock = Some(bounds);
                                    }
                                }
                            }
                        }
                        if matches!(
                            &event,
                            TrayIconEvent::Enter { .. } | TrayIconEvent::Move { .. }
                        ) {
                            show_preview(app);
                        }
                        if let TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        } = event
                        {
                            hide_preview(app);
                            let is_visible = app
                                .get_webview_window("dashboard")
                                .and_then(|w| w.is_visible().ok())
                                .unwrap_or(false);
                            let decision = app
                                .try_state::<ActivityState>()
                                .and_then(|s| {
                                    s.0.lock().ok().map(|mut g| {
                                        g.on_tray_left_click(std::time::Instant::now(), is_visible)
                                    })
                                })
                                .unwrap_or(if is_visible {
                                    ToggleDecision::Hide
                                } else {
                                    ToggleDecision::Show
                                });
                            match decision {
                                ToggleDecision::Show => {
                                    show_dashboard(app, DashboardOpenSource::Tray)
                                }
                                ToggleDecision::Hide => {
                                    if let Some(window) = app.get_webview_window("dashboard") {
                                        let _ = window.hide();
                                    }
                                }
                                ToggleDecision::Ignore => {}
                            }
                        }
                    })
                    .build(app)?;
                scheduler::spawn(app.handle().clone());
                Ok(())
            })
            .on_window_event(move |window, event| {
                let lost_focus = matches!(event, WindowEvent::Focused(false));
                let close = matches!(event, WindowEvent::CloseRequested { .. });
                match window_action(window.label(), lost_focus, close) {
                    WindowAction::HidePreview => {
                        if let WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                        }
                        let _ = window.hide();
                    }
                    WindowAction::HideDashboardAndPersist => {
                        if let WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                        }
                        if lost_focus {
                            let decision = window
                                .app_handle()
                                .try_state::<ActivityState>()
                                .and_then(|s| {
                                    s.0.lock().ok().map(|mut g| {
                                        g.on_dashboard_unfocus(std::time::Instant::now())
                                    })
                                })
                                .unwrap_or(UnfocusDecision::Hide);
                            match decision {
                                UnfocusDecision::IgnoreTransientAndRefocus => {
                                    let _ = window.set_focus();
                                    return;
                                }
                                UnfocusDecision::AlreadyHidden => {
                                    return;
                                }
                                UnfocusDecision::Hide => {}
                            }
                        } else if let Some(activity) =
                            window.app_handle().try_state::<ActivityState>()
                        {
                            if let Ok(mut guard) = activity.0.lock() {
                                guard.record_explicit_hide();
                            }
                        }
                        let _ = window.hide();
                    }
                    WindowAction::HideSettings => {
                        if let WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                        }
                        // 录制中关闭设置窗口: 恢复被注销的已生效热键。
                        let app = window.app_handle();
                        if let Ok(mut current) = app.state::<RegisteredHotkey>().0.lock() {
                            if let Err(error) = apply_hotkey_recording(app, &mut current, false) {
                                eprintln!("全局热键恢复失败: {error}");
                            }
                        }
                        let _ = window.hide();
                    }
                    WindowAction::None => {}
                }
            })
            .invoke_handler(tauri::generate_handler![
                get_dashboard,
                get_runtime_info,
                clear_snapshot_cache,
                export_billing,
                export_diagnostics,
                get_usage_analytics,
                export_workbench_csv,
                export_workbench_json,
                get_model_prices,
                get_credential_accounts,
                get_credential_rejections,
                remove_credential_account,
                save_credential_account,
                rename_credential_account,
                import_codex_auth,
                codex_device_start,
                codex_device_poll,
                open_verification_page,
                codex_import_discovered,
                codex_discovery_sources,
                claude_local_status,
                import_claude_from_local,
                grok_local_status,
                import_grok_from_local,
                get_settings,
                save_settings_command,
                credential_allowlist,
                get_credential_fields,
                save_credentials_command,
                verify_subscription,
                remove_provider_credentials,
                ccswitch_status,
                import_volcengine_from_ccswitch,
                stepfun_web_login_open,
                stepfun_web_login_action,
                stepfun_web_login_poll,
                stepfun_web_login_clear_session,
                stepfun_web_login_close,
                refresh_now,
                refresh_subscription,
                open_settings,
                hide_dashboard,
                hide_preview_window,
                expand_dashboard,
                set_hotkey_recording,
                quit_app,
                crate::software_update::desktop_impl::update_state,
                crate::software_update::desktop_impl::update_check,
                crate::software_update::desktop_impl::update_download,
                crate::software_update::desktop_impl::update_install,
                crate::software_update::desktop_impl::update_cancel,
                crate::software_update::desktop_impl::update_dismiss_ready,
                crate::software_update::desktop_impl::update_skip,
                crate::software_update::desktop_impl::update_unskip,
                crate::software_update::desktop_impl::open_release_page
            ])
            .run(tauri::generate_context!())
            .expect("Bruce 托盘应用运行失败");
    }
}

#[cfg(feature = "desktop")]
pub use desktop::run;
