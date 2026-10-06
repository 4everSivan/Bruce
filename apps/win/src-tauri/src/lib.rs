//! Windows 托盘常驻壳 —— 对齐 mac `MenuBarStatusItemController` 交互语义:
//! 托盘常驻 + 左键切换面板 + 右键菜单; 无装饰置顶面板, 失焦自动隐藏,
//! 位置记忆; 全局热键唤出; 后台调度器周期采集 (退避 + 可见性门控 + Toast)。

mod alerts;
mod collector;
mod credentials;
mod paths;
mod scheduler;
mod settings;

use std::collections::BTreeMap;
use std::sync::atomic::Ordering;

use chrono::Local;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, PhysicalPosition, WindowEvent,
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

/// 按当前设置注册全局热键 (设置变更时先 unregister_all 再注册)。
fn register_hotkey(app: &tauri::AppHandle, hotkey: &str) -> Result<(), String> {
    app.global_shortcut()
        .unregister_all()
        .map_err(|error| error.to_string())?;
    if hotkey.is_empty() {
        return Ok(());
    }
    app.global_shortcut()
        .on_shortcut(hotkey, |app, _shortcut, event| {
            if event.state == tauri_plugin_global_shortcut::ShortcutState::Pressed {
                toggle_dashboard(app);
            }
        })
        .map_err(|error| error.to_string())
}

// MARK: - IPC 命令

#[tauri::command]
async fn get_dashboard() -> Result<serde_json::Value, String> {
    // 采集为 CPU/IO 密集型, 放阻塞线程池避免卡 WebView IPC 线程。
    tauri::async_runtime::spawn_blocking(move || -> Result<serde_json::Value, String> {
        let root = paths::data_root();
        let credentials = credentials::load_credentials(&root);
        let response = collector::run_local_collection(credentials)?;
        let mapper = bruce_win_viewmodel::usage::PanelViewModelMapper::default();
        let now = Local::now().fixed_offset();
        let artifact = response
            .artifact
            .as_ref()
            .map(|value| {
                serde_json::from_value::<collector_domain::AgentUsageArtifact>(value.clone())
            })
            .transpose()
            .map_err(|error| error.to_string())?;
        let panel = mapper.make(artifact.as_ref(), now);
        serde_json::to_value(&panel).map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}

#[tauri::command]
fn get_settings() -> AppSettings {
    settings::load_settings(&paths::data_root())
}

#[tauri::command]
fn save_settings_command(app: tauri::AppHandle, settings: AppSettings) -> Result<(), String> {
    settings::validate_settings(&settings)?;
    settings::save_settings(&paths::data_root(), &settings)?;
    // 热键可能已变更: 重新注册 (失败不阻塞保存, 记录诊断)。
    if let Err(error) = register_hotkey(&app, &settings.hotkey) {
        eprintln!("热键注册失败: {error}");
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
    let mut merged = credentials::load_credentials(&root);
    for (key, value) in payloads {
        match value {
            Some(value) => {
                merged.insert(key, value);
            }
            None => {
                merged.remove(&key);
            }
        }
    }
    credentials::save_credentials(&root, &merged)?;
    // 凭证变化后立即刷新, 让订阅卡尽快呈现 出站额度。
    app.state::<SchedulerControl>().request_manual_refresh();
    Ok(())
}

#[tauri::command]
fn refresh_now(control: tauri::State<SchedulerControl>) {
    control.request_manual_refresh();
}

#[tauri::command]
fn set_panel_visible(control: tauri::State<SchedulerControl>, visible: bool) {
    control.panel_visible.store(visible, Ordering::Relaxed);
    if visible {
        control.request_manual_refresh();
    }
}

// MARK: - 入口

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .setup(|app| {
            // 调度控制状态 (托盘菜单/命令/热键共享)。
            app.manage(SchedulerControl::new());
            // 后台调度器 (采集 + 退避 + 可见性门控 + Toast)。
            scheduler::spawn(app.handle().clone());
            // 全局热键 (设置可配)。
            let hotkey = settings::load_settings(&paths::data_root()).hotkey;
            if let Err(error) = register_hotkey(app.handle(), &hotkey) {
                eprintln!("全局热键注册失败: {error}");
            }

            let show = MenuItem::with_id(app, "show", "显示看板", true, None::<&str>)?;
            let refresh = MenuItem::with_id(app, "refresh", "立即刷新", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Bruce", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &refresh, &quit])?;
            TrayIconBuilder::new()
                .icon(tauri::image::Image::from_bytes(include_bytes!(
                    "../icons/icon.png"
                ))?)
                .tooltip("Bruce")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => toggle_dashboard(app),
                    "refresh" => app.state::<SchedulerControl>().request_manual_refresh(),
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
            Ok(())
        })
        .on_window_event(|window, event| match event {
            WindowEvent::Focused(false) => {
                // 失焦自动隐藏 (对齐 mac 面板交互); 隐藏前记忆位置并门控采集。
                persist_position(window);
                window
                    .app_handle()
                    .state::<SchedulerControl>()
                    .panel_visible
                    .store(false, Ordering::Relaxed);
                let _ = window.hide();
            }
            WindowEvent::Focused(true) => {
                window
                    .app_handle()
                    .state::<SchedulerControl>()
                    .panel_visible
                    .store(true, Ordering::Relaxed);
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            get_dashboard,
            get_settings,
            save_settings_command,
            credential_allowlist,
            get_credential_fields,
            save_credentials_command,
            refresh_now,
            set_panel_visible
        ])
        .run(tauri::generate_context!())
        .expect("Bruce 托盘应用运行失败");
}
