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
    let items: [(&str, &str, &str, bool); 10] = [
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
        // DSH (DeepSeek Harness, C189): zstd JSONL 会话树, 与 mac LocalDependencyScanner 同口径。
        (
            "dsh",
            "DSH",
            "~/.dsh/sessions",
            home.join(".dsh").join("sessions").is_dir(),
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

#[cfg(test)]
mod tests {
    use std::fs;

    use super::probe_local_agents;

    /// 临时 home (与 settings/credentials 用例同法, 收尾自清理)。
    fn temp_home(tag: &str) -> std::path::PathBuf {
        let home = std::env::temp_dir().join(format!("bruce-paths-{tag}-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&home).unwrap();
        home
    }

    #[test]
    fn probe_local_agents_lists_ten_sources_including_dsh() {
        // C189: 本机探测清单 9→10, dsh (DeepSeek Harness) 落在 codebuddy 与 ccSwitch 之间。
        let home = temp_home("dsh-missing");
        let probes = probe_local_agents(&home);
        let ids: Vec<&str> = probes
            .iter()
            .map(|item| item["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids.len(), 10, "本机探测共 10 项");
        assert_eq!(
            ids,
            [
                "claude",
                "codex",
                "kimiCli",
                "kimiWork",
                "opencode",
                "pi",
                "zcode",
                "codebuddy",
                "dsh",
                "ccSwitch",
            ]
        );
        let dsh = probes.iter().find(|item| item["id"] == "dsh").unwrap();
        assert_eq!(dsh["name"], "DSH");
        assert_eq!(dsh["pathHint"], "~/.dsh/sessions");
        assert_eq!(dsh["status"], "missing", "无 ~/.dsh/sessions 时未就绪");
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn probe_local_agents_marks_dsh_available_when_sessions_dir_exists() {
        // 与 mac LocalDependencyScanner 同口径: 只看 ~/.dsh/sessions 是否为目录。
        let home = temp_home("dsh-ready");
        fs::create_dir_all(home.join(".dsh").join("sessions")).unwrap();
        let probes = probe_local_agents(&home);
        let dsh = probes.iter().find(|item| item["id"] == "dsh").unwrap();
        assert_eq!(dsh["status"], "available");
        let _ = fs::remove_dir_all(&home);
    }
}
