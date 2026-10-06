//! 数据根目录解析: 统一 `%APPDATA%\Bruce` (Windows) /
//! `~/Library/Application Support/Bruce` (mac 开发) —— 与凭证存储同一根。

use std::path::PathBuf;

use crate::credentials::app_data_root;

pub fn data_root() -> PathBuf {
    let home = std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    app_data_root(&home)
}
