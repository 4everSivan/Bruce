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

pub mod runtime_core;

#[cfg(feature = "desktop")]
mod desktop {
    use std::collections::BTreeMap;

    use super::{credentials, paths, scheduler, settings};
    use crate::runtime_core::{
        compute_dashboard_geometry, replace_hotkey, window_action, MonitorBounds, TrayIconBounds,
        WindowAction,
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

    #[derive(Clone, Default)]
    struct TrayBoundsState(std::sync::Arc<std::sync::Mutex<Option<TrayIconBounds>>>);

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

    /// 依据目标显示器物理工作区 (work_area) 与托盘位置动态计算自适应尺寸并贴靠定位。
    fn apply_dashboard_geometry(
        window: &tauri::WebviewWindow,
        tray_bounds: Option<&TrayIconBounds>,
    ) {
        let monitor = if let (Some(tray), Ok(monitors)) = (tray_bounds, window.available_monitors())
        {
            monitors.into_iter().find(|m| {
                let pos = m.position();
                let sz = m.size();
                tray.x >= pos.x
                    && tray.x < pos.x + sz.width as i32
                    && tray.y >= pos.y
                    && tray.y < pos.y + sz.height as i32
            })
        } else {
            None
        };

        let target_monitor = monitor
            .or_else(|| window.current_monitor().ok().flatten())
            .or_else(|| window.primary_monitor().ok().flatten());

        if let Some(m) = target_monitor {
            let scale = m.scale_factor();
            let pos = m.position();
            let size = m.size();
            let work = m.work_area();

            let monitor_bounds = MonitorBounds {
                x: pos.x,
                y: pos.y,
                width: size.width,
                height: size.height,
                work_x: work.position.x,
                work_y: work.position.y,
                work_width: work.size.width,
                work_height: work.size.height,
                scale_factor: scale,
            };

            let geom = compute_dashboard_geometry(&monitor_bounds, tray_bounds);
            let _ = window.set_size(PhysicalSize::new(geom.width, geom.height));
            let _ = window.set_position(PhysicalPosition::new(geom.x, geom.y));
        }
    }

    fn toggle_dashboard(app: &tauri::AppHandle) {
        if let Some(window) = app.get_webview_window("dashboard") {
            if window.is_visible().unwrap_or(false) {
                let _ = window.hide();
            } else {
                let tray_bounds = app
                    .try_state::<TrayBoundsState>()
                    .and_then(|s| s.0.lock().ok().and_then(|guard| *guard));
                apply_dashboard_geometry(&window, tray_bounds.as_ref());
                let _ = window.show();
                let _ = window.set_focus();
                // 打开面板立即出新数据 (常驻周期之外的手动唤醒通道, C007)。
                app.state::<SchedulerControl>().request_manual_refresh();
            }
        }
    }

    fn persist_outer_position(x: i32, y: i32) {
        let root = paths::data_root();
        let mut stored = settings::load_settings(&root);
        if stored.panel_x != Some(x) || stored.panel_y != Some(y) {
            stored.panel_x = Some(x);
            stored.panel_y = Some(y);
            let _ = settings::save_settings(&root, &stored);
        }
    }

    fn persist_position(window: &tauri::Window) {
        if let Ok(PhysicalPosition { x, y }) = window.outer_position() {
            persist_outer_position(x, y);
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
                    toggle_dashboard(app);
                }
            })
            .map_err(|_| "HOTKEY_REGISTER_FAILED".into())
    }

    #[derive(Default)]
    struct RegisteredHotkey(Mutex<String>);

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

    /// 设置页「模型计费」的展示目录: 镜像 mac `BuiltinModelPricingCatalog` 的行集与元数据
    /// (显示名 / 厂商 / 单价), 供表格与校准弹窗消费。采集侧成本口径不受影响。
    #[tauri::command]
    fn get_model_prices() -> serde_json::Value {
        model_catalog::as_json()
    }

    #[tauri::command]
    fn get_settings() -> AppSettings {
        settings::load_settings(&paths::data_root())
    }

    #[tauri::command]
    fn save_settings_command(app: tauri::AppHandle, settings: AppSettings) -> Result<(), String> {
        settings::validate_settings(&settings)?;
        let previous = settings::load_settings(&paths::data_root());
        let registered = app.state::<RegisteredHotkey>();
        let mut current = registered.0.lock().map_err(|_| "HOTKEY_LOCK_FAILED")?;
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
        Ok(())
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

    #[tauri::command]
    fn import_codex_auth(app: tauri::AppHandle, auth: serde_json::Value) -> Result<(), String> {
        credentials::import_codex_auth(&paths::data_root(), &auth)?;
        app.state::<SchedulerControl>().request_manual_refresh();
        Ok(())
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
        if let Some(window) = app.get_webview_window("dashboard") {
            if let Ok(PhysicalPosition { x, y }) = window.outer_position() {
                persist_outer_position(x, y);
            }
            let _ = window.hide();
        }
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
        let last_unfocus = std::sync::Arc::new(std::sync::Mutex::new(None::<std::time::Instant>));
        let last_unfocus_tray = last_unfocus.clone();
        let last_unfocus_window = last_unfocus.clone();

        tauri::Builder::default()
            .plugin(tauri_plugin_notification::init())
            .plugin(tauri_plugin_global_shortcut::Builder::new().build())
            // 导出文件的系统保存对话框 (C033): 与 mac NSSavePanel 等价
            .plugin(tauri_plugin_dialog::init())
            .setup(move |app| {
                // 调度控制状态 (托盘菜单/命令/热键共享)。
                let control = SchedulerControl::new();
                if let Ok(mut state) = control.snapshot.lock() {
                    *state = crate::runtime_core::SnapshotState::load(&paths::data_root());
                }
                app.manage(control);
                app.manage(RegisteredHotkey::default());
                app.manage(TrayBoundsState::default());
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
                        if let TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            rect,
                            ..
                        } = event
                        {
                            // 防抖: 若刚刚因失去焦点隐藏（即用户点击托盘图标旨在收起面板），不再反向重新唤出
                            if let Ok(mut lock) = last_unfocus_tray.lock() {
                                if let Some(instant) = lock.take() {
                                    if instant.elapsed() < std::time::Duration::from_millis(300) {
                                        return;
                                    }
                                }
                            }
                            let app = tray.app_handle();
                            let scale = app
                                .get_webview_window("dashboard")
                                .and_then(|w| w.primary_monitor().ok().flatten())
                                .map(|m| m.scale_factor())
                                .unwrap_or(1.0);
                            let bounds = rect_to_bounds(&rect, scale);
                            if let Some(state) = app.try_state::<TrayBoundsState>() {
                                if let Ok(mut lock) = state.0.lock() {
                                    *lock = Some(bounds);
                                }
                            }
                            toggle_dashboard(app);
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
                    WindowAction::HideDashboardAndPersist => {
                        if lost_focus {
                            if let Ok(mut lock) = last_unfocus_window.lock() {
                                *lock = Some(std::time::Instant::now());
                            }
                        }
                        if let WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
                        }
                        persist_position(window);
                        let _ = window.hide();
                    }
                    WindowAction::HideSettings => {
                        if let WindowEvent::CloseRequested { api, .. } = event {
                            api.prevent_close();
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
                remove_credential_account,
                save_credential_account,
                import_codex_auth,
                claude_local_status,
                import_claude_from_local,
                get_settings,
                save_settings_command,
                credential_allowlist,
                get_credential_fields,
                save_credentials_command,
                refresh_now,
                refresh_subscription,
                open_settings,
                hide_dashboard,
                quit_app
            ])
            .run(tauri::generate_context!())
            .expect("Bruce 托盘应用运行失败");
    }
}

#[cfg(feature = "desktop")]
pub use desktop::run;
