//! 数据根目录解析: 统一 `%APPDATA%\Bruce` (Windows) /
//! `~/Library/Application Support/Bruce-Windows-Dev` (mac 开发，隔离原生 App 凭证)。

use std::path::PathBuf;

use crate::credentials::app_data_root;

pub fn data_root() -> PathBuf {
    app_data_root(&home_root())
}

/// 当前用户主目录 (本机 CLI 登录态探测与采集会话路径解析共用同一事实源)。
pub fn home_root() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn collector_cache_root() -> PathBuf {
    collector_local::default_cache_root(&home_root())
}
