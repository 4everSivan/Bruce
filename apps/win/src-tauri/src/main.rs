// 阻止 Windows 发布构建保留 console 窗口; 逻辑主体在 lib.rs。
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    bruce_win_lib::run()
}
