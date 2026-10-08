//! 应用设置持久化 —— `%APPDATA%\Bruce\config\settings.json`
//! (mac 侧对应 OnboardingConfiguration 的 config 目录约定)。
//! 原子写 + 损坏视为默认值; 字段向后兼容 (未知键忽略)。

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const DEFAULT_REFRESH_INTERVAL_SECS: u64 = 1800;
pub const PROVIDERS: &[&str] = &[
    "kimi",
    "deepseek",
    "volcengine",
    "zhipu",
    "codex",
    "claude",
    "grok",
    "opencodeGo",
    "stepfun",
];

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    /// 首次配置不可隐式授权出站查询。
    pub consent_version: u32,
    pub usage_enabled: bool,
    pub enabled_providers: Vec<String>,
    pub provider_order: Vec<String>,
    pub pricing_overrides: BTreeMap<String, serde_json::Value>,
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
            consent_version: 0,
            usage_enabled: true,
            enabled_providers: PROVIDERS.iter().map(|s| (*s).to_owned()).collect(),
            provider_order: Vec::new(),
            pricing_overrides: BTreeMap::new(),
            refresh_interval_secs: DEFAULT_REFRESH_INTERVAL_SECS,
            notifications_enabled: true,
            theme: "fluent".to_owned(),
            card_order: vec![
                "usage".to_owned(),
                "subscription".to_owned(),
                "hourly".to_owned(),
            ],
            hotkey: String::new(),
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
        Ok(mut settings) => {
            // 纵深防御: validate 只拦保存入口, 手改文件可携带越界间隔
            // (如 0 会造成零间隔 busy-loop 采集), 加载侧统一钳制 (C007)。
            settings.refresh_interval_secs = settings.refresh_interval_secs.clamp(60, 86_400);
            if validate_settings(&settings).is_ok() {
                settings
            } else {
                AppSettings::default()
            }
        }
        Err(error) => {
            eprintln!("settings.json 解析失败, 使用默认值: {error}");
            AppSettings::default()
        }
    }
}

/// 原子写入设置 (临时文件 + rename)。
pub fn save_settings(root: &Path, settings: &AppSettings) -> Result<(), String> {
    validate_settings(settings)?;
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
    if settings.consent_version > 1 {
        return Err("不支持此授权版本".to_owned());
    }
    for values in [&settings.enabled_providers, &settings.provider_order] {
        let mut seen = BTreeSet::new();
        if values
            .iter()
            .any(|id| !PROVIDERS.contains(&id.as_str()) || !seen.insert(id))
        {
            return Err("服务列表包含未知或重复服务".to_owned());
        }
    }
    let mut seen = BTreeSet::new();
    if settings
        .card_order
        .iter()
        .any(|id| !["usage", "subscription", "hourly"].contains(&id.as_str()) || !seen.insert(id))
    {
        return Err("卡片顺序包含未知或重复卡片".to_owned());
    }
    if settings.pricing_overrides.len() > 512 {
        return Err("价格覆盖条目过多".to_owned());
    }
    for (model, raw) in &settings.pricing_overrides {
        if model.trim().is_empty() || model.len() > 256 {
            return Err("模型名称无效".to_owned());
        }
        let object = raw.as_object().ok_or("价格覆盖必须为对象")?;
        for (key, value) in object {
            match key.as_str() {
                "inputPricePerMillion" | "outputPricePerMillion" | "cacheReadPricePerMillion" => {
                    if !value.is_null()
                        && !value.as_f64().is_some_and(|n| n.is_finite() && n >= 0.0)
                    {
                        return Err("价格必须为非负有限数值".to_owned());
                    }
                }
                "currency" => {
                    if !value.is_null()
                        && !value
                            .as_str()
                            .is_some_and(|s| ["USD", "CNY", "EUR", "GBP"].contains(&s))
                    {
                        return Err("不支持此币种".to_owned());
                    }
                }
                "note" => {
                    if !value.is_null() && !value.as_str().is_some_and(|s| s.len() <= 1024) {
                        return Err("价格备注无效".to_owned());
                    }
                }
                _ => return Err("价格覆盖包含未知字段".to_owned()),
            }
        }
    }
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

/// 使用 Collector 同一价格表，避免设置 UI 复制一套价格事实源。
pub fn model_prices() -> serde_json::Value {
    serde_json::to_value(collector_domain::PricingTable::default().builtin_catalog())
        .unwrap_or_default()
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
