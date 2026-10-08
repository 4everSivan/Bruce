//! Windows 托盘常驻壳 —— 对齐 mac `MenuBarStatusItemController` 交互语义:
//! 托盘常驻 + 左键切换面板 + 右键菜单; 无装饰置顶面板, 失焦自动隐藏,
//! 位置记忆; 全局热键唤出; 后台调度器周期采集 (退避 + Toast, 常驻不门控)。

// 模块 pub 导出供 tests/ 集成测试覆盖 (GUI 入口 run() 除外)。
pub mod alerts;
pub mod collector;
pub mod credentials;
pub mod paths;
pub mod scheduler;
pub mod settings;

pub mod ledger;
pub mod runtime_core;

#[cfg(feature = "desktop")]
mod desktop {
    use std::collections::BTreeMap;

    use super::{credentials, paths, scheduler, settings};
    use crate::runtime_core::{replace_hotkey, window_action, WindowAction};
    use std::sync::Mutex;
    use tauri::{
        menu::{Menu, MenuItem},
        tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
        Emitter, Manager, PhysicalPosition, WindowEvent,
    };
    use tauri_plugin_global_shortcut::GlobalShortcutExt;

    use crate::scheduler::SchedulerControl;
    use crate::settings::AppSettings;

    fn toggle_dashboard(app: &tauri::AppHandle) {
        if let Some(window) = app.get_webview_window("dashboard") {
            if window.is_visible().unwrap_or(false) {
                let _ = window.hide();
            } else {
                restore_position(&window);
                let _ = window.show();
                let _ = window.set_focus();
                // 打开面板立即出新数据 (常驻周期之外的手动唤醒通道, C007)。
                app.state::<SchedulerControl>().request_manual_refresh();
            }
        }
    }

    /// 位置记忆: 显示前恢复上次面板位置。
    fn restore_position(window: &tauri::WebviewWindow) {
        let stored = settings::load_settings(&paths::data_root());
        if let (Some(x), Some(y)) = (stored.panel_x, stored.panel_y) {
            let _ = window.set_position(PhysicalPosition::new(x, y));
        }
    }

    fn persist_position(window: &tauri::Window) {
        if let Ok(PhysicalPosition { x, y }) = window.outer_position() {
            let root = paths::data_root();
            let mut stored = settings::load_settings(&root);
            if stored.panel_x != Some(x) || stored.panel_y != Some(y) {
                stored.panel_x = Some(x);
                stored.panel_y = Some(y);
                let _ = settings::save_settings(&root, &stored);
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
        Ok(
            serde_json::json!({"dataRoot":root,"cacheRoot":paths::collector_cache_root(),"snapshotPath":root.join("snapshot.json"),"status":panel["runtime"]}),
        )
    }

    #[tauri::command]
    fn get_model_prices() -> serde_json::Value {
        serde_json::to_value(settings::model_prices()).unwrap_or_else(|_| serde_json::json!({}))
    }

    #[tauri::command]
    fn get_settings() -> AppSettings {
        settings::load_settings(&paths::data_root())
    }

    #[tauri::command]
    fn save_settings_command(app: tauri::AppHandle, settings: AppSettings) -> Result<(), String> {
        settings::validate_settings(&settings)?;
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
        app.state::<SchedulerControl>().request_manual_refresh();
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

    #[tauri::command]
    fn refresh_now(control: tauri::State<SchedulerControl>) {
        control.request_manual_refresh();
    }

    #[tauri::command]
    fn quit_app(app: tauri::AppHandle) {
        app.exit(0);
    }

    /// 打开设置窗口 (mac SettingsWindowController 单实例语义: 已存在则置前)。
    #[tauri::command]
    fn open_settings(app: tauri::AppHandle) {
        if let Some(window) = app.get_webview_window("settings") {
            let _ = window.show();
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
    }

    // MARK: - 入口

    pub fn run() {
        tauri::Builder::default()
            .plugin(tauri_plugin_notification::init())
            .plugin(tauri_plugin_global_shortcut::Builder::new().build())
            .setup(|app| {
                // 调度控制状态 (托盘菜单/命令/热键共享)。
                let control = SchedulerControl::new();
                if let Ok(mut state) = control.snapshot.lock() {
                    *state = crate::runtime_core::SnapshotState::load(&paths::data_root());
                }
                app.manage(control);
                app.manage(RegisteredHotkey::default());
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
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::Click {
                            button: MouseButton::Left,
                            button_state: MouseButtonState::Up,
                            ..
                        } = event
                        {
                            toggle_dashboard(tray.app_handle());
                        }
                    })
                    .build(app)?;
                scheduler::spawn(app.handle().clone());
                Ok(())
            })
            .on_window_event(|window, event| {
                let lost_focus = matches!(event, WindowEvent::Focused(false));
                let close = matches!(event, WindowEvent::CloseRequested { .. });
                match window_action(window.label(), lost_focus, close) {
                    WindowAction::HideDashboardAndPersist => {
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
                get_model_prices,
                get_credential_accounts,
                remove_credential_account,
                save_credential_account,
                import_codex_auth,
                get_settings,
                save_settings_command,
                credential_allowlist,
                get_credential_fields,
                save_credentials_command,
                refresh_now,
                open_settings,
                quit_app
            ])
            .run(tauri::generate_context!())
            .expect("Bruce 托盘应用运行失败");
    }
}

#[cfg(feature = "desktop")]
pub use desktop::run;
