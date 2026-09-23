#![deny(unsafe_code)]

//! Cross-platform local agent path resolution.
//!
//! Provides deterministic path resolution for local agent sessions and
//! databases, with priority given to standard environment variables,
//! platform conventions (macOS, Windows, and Linux), and directory existence
//! fallbacks.

use std::env;
use std::path::{Path, PathBuf};

/// Check if an environment variable is set to a non-empty value.
fn env_non_empty(var_name: &str) -> Option<String> {
    env::var(var_name)
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
}

/// Resolve Claude Code projects directory.
/// Priority:
/// 1. $CLAUDE_CONFIG_DIR/projects (if env set)
/// 2. $HOME/.claude/projects (default across macOS, Windows, Linux)
pub fn resolve_claude_projects_path(home: &Path) -> PathBuf {
    if let Some(config_dir) = env_non_empty("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(config_dir).join("projects");
    }
    home.join(".claude").join("projects")
}

/// Resolve Codex sessions directory.
/// Priority:
/// 1. $CODEX_HOME/sessions (if env set)
/// 2. $HOME/.codex/sessions (default)
pub fn resolve_codex_sessions_path(home: &Path) -> PathBuf {
    if let Some(codex_home) = env_non_empty("CODEX_HOME") {
        return PathBuf::from(codex_home).join("sessions");
    }
    home.join(".codex").join("sessions")
}

/// Resolve Grok home directory.
/// Priority:
/// 1. $GROK_HOME (if env set)
/// 2. $HOME/.grok (default)
pub fn resolve_grok_home_path(home: &Path) -> PathBuf {
    if let Some(grok_home) = env_non_empty("GROK_HOME") {
        return PathBuf::from(grok_home);
    }
    home.join(".grok")
}

/// Resolve OpenCode database path.
/// Priority:
/// 1. $XDG_DATA_HOME/opencode/opencode.db (if env set)
/// 2. Windows: %LOCALAPPDATA%/opencode/opencode.db or %APPDATA%/opencode/opencode.db
/// 3. Default: $HOME/.local/share/opencode/opencode.db
pub fn resolve_opencode_db_path(home: &Path) -> PathBuf {
    if let Some(xdg) = env_non_empty("XDG_DATA_HOME") {
        return PathBuf::from(xdg).join("opencode").join("opencode.db");
    }

    #[cfg(windows)]
    {
        if let Some(local_app_data) = env_non_empty("LOCALAPPDATA") {
            let candidate = PathBuf::from(local_app_data)
                .join("opencode")
                .join("opencode.db");
            if candidate.is_file() {
                return candidate;
            }
        }
        if let Some(app_data) = env_non_empty("APPDATA") {
            let candidate = PathBuf::from(app_data).join("opencode").join("opencode.db");
            if candidate.is_file() {
                return candidate;
            }
        }
    }

    // Windows fallback if env is unset or file not at appdata
    let win_local = home
        .join("AppData")
        .join("Local")
        .join("opencode")
        .join("opencode.db");
    if win_local.is_file() {
        return win_local;
    }

    home.join(".local")
        .join("share")
        .join("opencode")
        .join("opencode.db")
}

/// Resolve Kimi Work sessions directory with multiple candidate fallbacks.
/// Candidates checked in order of priority:
/// 1. macOS Daimon share runtime: Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions
/// 2. macOS Standalone runtime: Library/Application Support/kimi-desktop/kimi-code/home/sessions
/// 3. macOS Flat sessions: Library/Application Support/kimi-desktop/sessions
/// 4. Windows AppData Roaming candidates:
///    - AppData/Roaming/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions
///    - AppData/Roaming/kimi-desktop/kimi-code/home/sessions
///    - AppData/Roaming/kimi-desktop/sessions
pub fn resolve_kimi_work_sessions_path(home: &Path) -> PathBuf {
    // macOS candidates
    let mac_daimon = home
        .join("Library")
        .join("Application Support")
        .join("kimi-desktop")
        .join("daimon-share")
        .join("daimon")
        .join("runtime")
        .join("kimi-code")
        .join("home")
        .join("sessions");
    let mac_standalone = home
        .join("Library")
        .join("Application Support")
        .join("kimi-desktop")
        .join("kimi-code")
        .join("home")
        .join("sessions");
    let mac_flat = home
        .join("Library")
        .join("Application Support")
        .join("kimi-desktop")
        .join("sessions");

    // Windows candidates
    let win_roaming_base = env_non_empty("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("AppData").join("Roaming"));
    let win_daimon = win_roaming_base
        .join("kimi-desktop")
        .join("daimon-share")
        .join("daimon")
        .join("runtime")
        .join("kimi-code")
        .join("home")
        .join("sessions");
    let win_standalone = win_roaming_base
        .join("kimi-desktop")
        .join("kimi-code")
        .join("home")
        .join("sessions");
    let win_flat = win_roaming_base.join("kimi-desktop").join("sessions");

    let candidates = [
        &mac_daimon,
        &mac_standalone,
        &mac_flat,
        &win_daimon,
        &win_standalone,
        &win_flat,
    ];

    for candidate in candidates {
        if candidate.is_dir() {
            return candidate.clone();
        }
    }

    // Default to canonical macOS Daimon path if none exist yet on disk
    #[cfg(windows)]
    {
        win_daimon
    }
    #[cfg(not(windows))]
    {
        mac_daimon
    }
}

/// Resolve Orca home directory.
pub fn resolve_orca_home_path(home: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(app_data) = env_non_empty("APPDATA") {
            return PathBuf::from(app_data).join("orca");
        }
        let win_orca = home.join("AppData").join("Roaming").join("orca");
        if win_orca.is_dir() {
            return win_orca;
        }
    }

    home.join("Library")
        .join("Application Support")
        .join("orca")
}

/// Resolve Pi sessions directory.
pub fn resolve_pi_sessions_path(home: &Path) -> PathBuf {
    home.join(".pi").join("agent").join("sessions")
}

/// Resolve ZCode database path.
pub fn resolve_zcode_db_path(home: &Path) -> PathBuf {
    home.join(".zcode").join("cli").join("db").join("db.sqlite")
}

/// Resolve CodeBuddy projects directory.
pub fn resolve_codebuddy_projects_path(home: &Path) -> PathBuf {
    home.join(".codebuddy").join("projects")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_paths_resolve_under_home() {
        let home = Path::new("/custom/home");
        assert_eq!(
            resolve_claude_projects_path(home),
            PathBuf::from("/custom/home/.claude/projects")
        );
        assert_eq!(
            resolve_codex_sessions_path(home),
            PathBuf::from("/custom/home/.codex/sessions")
        );
        assert_eq!(
            resolve_grok_home_path(home),
            PathBuf::from("/custom/home/.grok")
        );
        assert_eq!(
            resolve_pi_sessions_path(home),
            PathBuf::from("/custom/home/.pi/agent/sessions")
        );
        assert_eq!(
            resolve_zcode_db_path(home),
            PathBuf::from("/custom/home/.zcode/cli/db/db.sqlite")
        );
        assert_eq!(
            resolve_codebuddy_projects_path(home),
            PathBuf::from("/custom/home/.codebuddy/projects")
        );
    }
}
