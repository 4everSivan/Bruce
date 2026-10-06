//! 应用设置持久化 —— `%APPDATA%\Bruce\config\settings.json`
//! (mac 侧对应 OnboardingConfiguration 的 config 目录约定)。
//! 原子写 + 损坏视为默认值; 字段向后兼容 (未知键忽略)。

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const DEFAULT_REFRESH_INTERVAL_SECS: u64 = 1800;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    /// 后台刷新间隔 (秒); mac 默认 1800。
    pub refresh_interval_secs: u64,
    /// 配额预警 Toast 通知开关。
    pub notifications_enabled: bool,
    /// 看板主题: fluent | nothing。
    pub theme: String,
    /// 卡片展示顺序 (usage/subscription/hourly)。
    pub card_order: Vec<String>,
    /// 全局热键 (Tauri accelerator 语法); 空串表示未注册。
    pub hotkey: String,
    /// 面板位置记忆 (物理像素坐标; None 表示尚未记录)。
    pub panel_x: Option<i32>,
    pub panel_y: Option<i32>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            refresh_interval_secs: DEFAULT_REFRESH_INTERVAL_SECS,
            notifications_enabled: true,
            theme: "fluent".to_owned(),
            card_order: vec![
                "usage".to_owned(),
                "subscription".to_owned(),
                "hourly".to_owned(),
            ],
            hotkey: "CommandOrControl+Shift+B".to_owned(),
            panel_x: None,
            panel_y: None,
        }
    }
}

fn settings_path(root: &Path) -> PathBuf {
    root.join("config").join("settings.json")
}

/// 加载设置; 文件缺失/损坏/字段缺失一律回落默认值 (与 mac load 语义一致)。
pub fn load_settings(root: &Path) -> AppSettings {
    let Ok(raw) = fs::read_to_string(settings_path(root)) else {
        return AppSettings::default();
    };
    match serde_json::from_str::<AppSettings>(&raw) {
        Ok(settings) => settings,
        Err(error) => {
            eprintln!("settings.json 解析失败, 使用默认值: {error}");
            AppSettings::default()
        }
    }
}

/// 原子写入设置 (临时文件 + rename)。
pub fn save_settings(root: &Path, settings: &AppSettings) -> Result<(), String> {
    let path = settings_path(root);
    let parent = path
        .parent()
        .ok_or_else(|| "设置路径缺少父目录".to_owned())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let body = serde_json::to_vec_pretty(settings).map_err(|error| error.to_string())?;
    let temporary = parent.join(format!(
        ".settings-{}-{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| error.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(|error| error.to_string())?;
        }
        file.write_all(&body).map_err(|error| error.to_string())?;
    }
    fs::rename(&temporary, &path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        error.to_string()
    })?;
    Ok(())
}

/// 设置合法性校验 (UI 保存入口共用)。
pub fn validate_settings(settings: &AppSettings) -> Result<(), String> {
    if !(60..=86_400).contains(&settings.refresh_interval_secs) {
        return Err("刷新间隔必须在 60 秒到 24 小时之间".to_owned());
    }
    if settings.theme != "fluent" && settings.theme != "nothing" {
        return Err("主题仅支持 fluent / nothing".to_owned());
    }
    if !settings.hotkey.is_empty() && settings.hotkey.len() > 64 {
        return Err("热键配置过长".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root() -> PathBuf {
        let root = std::env::temp_dir().join(format!(
            "bruce-win-settings-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn missing_settings_fall_back_to_defaults_and_round_trip() {
        let root = temp_root();
        assert_eq!(load_settings(&root), AppSettings::default());

        let settings = AppSettings {
            refresh_interval_secs: 600,
            theme: "nothing".to_owned(),
            notifications_enabled: false,
            ..AppSettings::default()
        };
        save_settings(&root, &settings).unwrap();
        assert_eq!(load_settings(&root), settings);
    }

    #[test]
    fn invalid_settings_are_rejected() {
        assert!(validate_settings(&AppSettings {
            refresh_interval_secs: 1,
            ..AppSettings::default()
        })
        .is_err());
        assert!(validate_settings(&AppSettings {
            theme: "glass".to_owned(),
            ..AppSettings::default()
        })
        .is_err());
    }
}
