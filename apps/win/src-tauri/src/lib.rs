//! Windows 托盘常驻壳 —— 对齐 mac `MenuBarStatusItemController` 的交互语义:
//! 托盘图标常驻, 左键切换看板面板, 右键菜单提供显示/退出; 看板为无装饰
//! 置顶窗口, 不占用任务栏。数据经 `bruce-win-viewmodel` 纯函数层产出。

mod collector;

use chrono::Local;
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};

#[tauri::command]
async fn get_dashboard() -> Result<serde_json::Value, String> {
    // 采集为 CPU/IO 密集型, 放阻塞线程池避免卡 WebView IPC 线程。
    tauri::async_runtime::spawn_blocking(move || -> Result<serde_json::Value, String> {
        let response = collector::run_local_collection()?;
        let mapper = bruce_win_viewmodel::usage::PanelViewModelMapper::default();
        let now = Local::now().fixed_offset();
        // BridgeResponse.artifact 为未类型化 Value, 按 agent-usage 契约收窄。
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

fn toggle_dashboard(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("dashboard") {
        if window.is_visible().unwrap_or(false) {
            let _ = window.hide();
        } else {
            let _ = window.show();
            let _ = window.set_focus();
        }
    }
}

pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            let show = MenuItem::with_id(app, "show", "显示看板", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出 Bruce", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&show, &quit])?;
            TrayIconBuilder::new()
                .icon(tauri::image::Image::from_bytes(include_bytes!(
                    "../icons/icon.png"
                ))?)
                .tooltip("Bruce")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "show" => toggle_dashboard(app),
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
        .invoke_handler(tauri::generate_handler![get_dashboard])
        .run(tauri::generate_context!())
        .expect("Bruce 托盘应用运行失败");
}
