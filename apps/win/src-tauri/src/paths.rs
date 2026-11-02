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

/// 欢迎向导 Step 1 本机只读环境扫描 (T22, 对齐 mac `LocalDependencyScanPaths.standard`)。
/// 仅执行本地目录/文件存在性检查, 零写入、零网络请求。
pub fn probe_local_agents(home: &std::path::Path) -> Vec<serde_json::Value> {
    let items: [(&str, &str, &str, bool); 9] = [
        (
            "claude",
            "Claude Code",
            "~/.claude/projects",
            home.join(".claude").join("projects").is_dir(),
        ),
        (
            "codex",
            "Codex CLI",
            "~/.codex/sessions",
            home.join(".codex").join("sessions").is_dir(),
        ),
        (
            "kimiCli",
            "Kimi Code CLI",
            "~/.kimi-code/sessions",
            home.join(".kimi-code").join("sessions").is_dir(),
        ),
        (
            "kimiWork",
            "Kimi Work",
            "kimi-desktop",
            home.join("Library")
                .join("Application Support")
                .join("kimi-desktop")
                .is_dir()
                || home
                    .join("AppData")
                    .join("Roaming")
                    .join("kimi-desktop")
                    .is_dir(),
        ),
        (
            "opencode",
            "OpenCode",
            "opencode.db",
            home.join(".local")
                .join("share")
                .join("opencode")
                .join("opencode.db")
                .is_file()
                || home
                    .join("AppData")
                    .join("Local")
                    .join("opencode")
                    .join("opencode.db")
                    .is_file(),
        ),
        (
            "pi",
            "Pi",
            "~/.pi/agent/sessions",
            home.join(".pi").join("agent").join("sessions").is_dir(),
        ),
        (
            "zcode",
            "ZCode",
            "~/.zcode/cli/db/db.sqlite",
            home.join(".zcode")
                .join("cli")
                .join("db")
                .join("db.sqlite")
                .is_file(),
        ),
        (
            "codebuddy",
            "CodeBuddy",
            "~/.codebuddy/projects",
            home.join(".codebuddy").join("projects").is_dir(),
        ),
        (
            "ccSwitch",
            "CC Switch",
            "~/.cc-switch/cc-switch.db",
            home.join(".cc-switch").join("cc-switch.db").is_file(),
        ),
    ];
    items
        .into_iter()
        .map(|(id, name, path_hint, available)| {
            serde_json::json!({
                "id": id,
                "name": name,
                "pathHint": path_hint,
                "status": if available { "available" } else { "missing" },
            })
        })
        .collect()
}
