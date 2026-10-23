//! 应用设置持久化 —— `%APPDATA%\Bruce\config\settings.json`
//! (mac 侧对应 OnboardingConfiguration 的 config 目录约定)。
//! 原子写 + 损坏视为默认值; 字段向后兼容 (未知键忽略)。

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const DEFAULT_REFRESH_INTERVAL_SECS: u64 = 1800;
/// 界面可见的 Provider 清单 (对齐 mac 设置页可见范围: SubscriptionProviderID.allCases
/// 的 11 家中 Jev 官方未开放查额 API 双端界面隐藏, 其余 10 家含 Cline 全部可配)。
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
    "cline",
];

/// 订阅 Provider 的验证状态 (C082, 对齐 mac `SubscriptionVerificationStatus`)。
pub const VERIFICATION_STATUSES: &[&str] = &["none", "ok", "failed", "needsRelogin"];

/// 单个订阅 Provider 的非敏感配置 (C082 / C090)。**存在即已添加** —— 订阅额度页只列出
/// 已添加的 Provider; `enabled` 是该 Provider 启用态的**唯一事实源**, `enabled_providers`
/// 只是它在采集 / 看板 / 额度门禁侧的投影 (由 `sync_enabled_providers` 派生, C090)。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SubscriptionProviderState {
    /// 启用开关 (C090): 验证通过即启用, 验证失败 / 需重新登录即禁用 (fail-closed)。
    pub enabled: bool,
    pub last_verified_at: Option<String>,
    /// none | ok | failed | needsRelogin。
    pub verification_status: String,
    /// 验证失败原因 (仅 status=failed 时有值; 不回显凭据)。
    pub failure_reason: Option<String>,
}

impl Default for SubscriptionProviderState {
    fn default() -> Self {
        Self {
            enabled: false,
            last_verified_at: None,
            verification_status: "none".to_owned(),
            failure_reason: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AppSettings {
    /// 首次配置不可隐式授权出站查询。
    pub consent_version: u32,
    pub usage_enabled: bool,
    pub enabled_providers: Vec<String>,
    pub provider_order: Vec<String>,
    /// 已添加的订阅 Provider (C082): 键存在即已添加。
    /// `None` 表示尚未迁移 —— 加载时按 `enabled_providers` 播种, 保留升级前的可见集合;
    /// 一旦前端保存过设置即为 `Some` (允许用户移除到空集合, 不会被再次播种)。
    pub subscription_providers: Option<BTreeMap<String, SubscriptionProviderState>>,
    pub pricing_overrides: BTreeMap<String, serde_json::Value>,
    /// 后台刷新间隔 (秒); mac 默认 1800。
    pub refresh_interval_secs: u64,
    /// 配额预警 Toast 通知开关。
    pub notifications_enabled: bool,
    /// 看板主题: fluent | nothing。
    pub theme: String,
    /// 卡片展示顺序 (usage/subscription/hourly)。
    pub card_order: Vec<String>,
    /// 看板布局模式: stack (纵向级联) | tabbed (顶栏 Tab)。
    #[serde(default = "default_layout_mode")]
    pub layout_mode: String,
    /// 顶栏 Tab 模式当前激活卡片 (usage | subscription | hourly)。
    #[serde(default = "default_active_card_id")]
    pub active_card_id: String,
    /// 全局热键 (Tauri accelerator 语法); 空串表示未注册。
    pub hotkey: String,
    /// 面板位置记忆 (物理像素坐标; None 表示尚未记录)。
    pub panel_x: Option<i32>,
    pub panel_y: Option<i32>,
}

fn default_layout_mode() -> String {
    "stack".to_owned()
}

fn default_active_card_id() -> String {
    "usage".to_owned()
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            consent_version: 0,
            usage_enabled: true,
            // C090: 全新安装不预置任何订阅 Provider (对齐 mac「未添加」), 由「添加服务」显式建立;
            // 启用集合由 subscription_providers 派生 (sync_enabled_providers)。
            enabled_providers: Vec::new(),
            provider_order: Vec::new(),
            subscription_providers: None,
            pricing_overrides: BTreeMap::new(),
            refresh_interval_secs: DEFAULT_REFRESH_INTERVAL_SECS,
            notifications_enabled: true,
            theme: "fluent".to_owned(),
            card_order: vec![
                "usage".to_owned(),
                "subscription".to_owned(),
                "hourly".to_owned(),
            ],
            layout_mode: "stack".to_owned(),
            active_card_id: "usage".to_owned(),
            hotkey: String::new(),
            panel_x: None,
            panel_y: None,
        }
    }
}

/// 已添加的订阅 Provider 集合 (C082): 未迁移时按启用集合播种 (升级保留既有可见集合)。
pub fn added_subscription_providers(
    settings: &AppSettings,
) -> BTreeMap<String, SubscriptionProviderState> {
    settings.subscription_providers.clone().unwrap_or_else(|| {
        settings
            .enabled_providers
            .iter()
            .map(|id| {
                (
                    id.clone(),
                    SubscriptionProviderState {
                        // 迁移播种: 升级前在启用集合里即为启用 (C090)。
                        enabled: true,
                        ..SubscriptionProviderState::default()
                    },
                )
            })
            .collect()
    })
}

/// 启用集合归一 (C090 / 设计规则 22)。
///
/// `subscriptionProviders[id].enabled` 是启用态的唯一事实源, `enabled_providers` 是它的
/// 投影 —— 采集装配、看板订阅段过滤与额度门禁仍消费后者, 故在加载与保存两侧统一由前者
/// 派生, 杜绝两个启用事实源漂移 (手改配置文件同样被纠正)。顺序取 `PROVIDERS` 稳定序,
/// 保证采集装配顺序确定。
pub fn sync_enabled_providers(settings: &mut AppSettings) {
    let added = added_subscription_providers(settings);
    settings.enabled_providers = PROVIDERS
        .iter()
        .filter(|provider| added.get(**provider).is_some_and(|state| state.enabled))
        .map(|provider| (*provider).to_owned())
        .collect();
}

/// 设置变更是否需要立即重新采集 (C069)。设置窗口改为即时生效后每个控件都会单独保存,
/// 只有改变采集输入的字段才值得一次全量采集 —— 授权、本机会话开关、启用的 Provider 集合、
/// 价格覆盖, 以及刷新间隔 (mac「变更后立即重新计时」); 主题、卡片/Provider 顺序、通知、
/// 热键与面板位置只需重新发布看板, 否则连续切换开关会触发一串全量扫描。
pub fn requires_collection(previous: &AppSettings, next: &AppSettings) -> bool {
    let providers = |settings: &AppSettings| -> BTreeSet<String> {
        settings.enabled_providers.iter().cloned().collect()
    };
    previous.consent_version != next.consent_version
        || previous.usage_enabled != next.usage_enabled
        || providers(previous) != providers(next)
        || previous.pricing_overrides != next.pricing_overrides
        || previous.refresh_interval_secs != next.refresh_interval_secs
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
            // 先按原样校验 (未知 Provider 仍一律拒绝), 再派生启用集合 (C090):
            // 手改文件造成的 enabled 漂移在此纠正, 不影响既有「非法即回落默认」语义。
            if validate_settings(&settings).is_ok() {
                sync_enabled_providers(&mut settings);
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
/// 落盘前按原样校验 (未知 Provider 仍一律拒绝), 再把启用集合归一为
/// `subscription_providers` 的派生投影 (C090), 保证文件内两处口径一致。
pub fn save_settings(root: &Path, settings: &AppSettings) -> Result<(), String> {
    validate_settings(settings)?;
    let mut normalized = settings.clone();
    sync_enabled_providers(&mut normalized);
    let settings = &normalized;
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
    if !["stack", "tabbed"].contains(&settings.layout_mode.as_str()) {
        return Err("不支持此看板布局模式".to_owned());
    }
    if !["usage", "subscription", "hourly"].contains(&settings.active_card_id.as_str()) {
        return Err("不支持此激活卡片标识".to_owned());
    }
    if let Some(providers) = &settings.subscription_providers {
        for (id, state) in providers {
            if !PROVIDERS.contains(&id.as_str()) {
                return Err("已添加服务包含未知服务".to_owned());
            }
            if !VERIFICATION_STATUSES.contains(&state.verification_status.as_str()) {
                return Err("验证状态无效".to_owned());
            }
            if state
                .failure_reason
                .as_ref()
                .is_some_and(|reason| reason.len() > 1024)
            {
                return Err("验证失败原因过长".to_owned());
            }
        }
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
#[cfg(test)]
mod tests {
    use super::*;

    fn temp_root() -> PathBuf {
        // 并行测试可能取到同一微秒时间戳, 追加进程内序号保证每条用例独占目录。
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "bruce-win-settings-test-{}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
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

    // MARK: - 已添加订阅 Provider (C082)

    #[test]
    fn added_providers_seed_from_enabled_providers_until_explicit() {
        // 全新安装 (C090): 不预置任何订阅 Provider, 对齐 mac「未添加」。
        let fresh = AppSettings::default();
        assert!(fresh.enabled_providers.is_empty(), "全新安装启用集合为空");
        assert!(fresh.subscription_providers.is_none(), "默认未迁移");
        assert!(added_subscription_providers(&fresh).is_empty());

        // 升级用户: 未迁移时按启用集合播种, 且播种项视为已启用。
        let upgraded = AppSettings {
            enabled_providers: PROVIDERS.iter().map(|s| (*s).to_owned()).collect(),
            ..AppSettings::default()
        };
        let seeded = added_subscription_providers(&upgraded);
        assert_eq!(seeded.len(), PROVIDERS.len(), "未迁移时按启用集合播种");
        assert!(seeded.contains_key("cline"));
        assert!(
            seeded.values().all(|state| state.enabled),
            "播种项必须视为已启用, 否则升级会静默关停既有订阅"
        );
        // 归一后启用集合不变 (迁移不得丢启用项)。
        let mut normalized = upgraded.clone();
        sync_enabled_providers(&mut normalized);
        assert_eq!(normalized.enabled_providers, upgraded.enabled_providers);
    }

    /// C090: `enabled` 是启用态唯一事实源, `enabled_providers` 为其派生投影。
    #[test]
    fn enabled_providers_is_derived_from_subscription_state() {
        let mut settings = AppSettings {
            subscription_providers: Some(BTreeMap::from([
                (
                    "kimi".to_owned(),
                    SubscriptionProviderState {
                        enabled: true,
                        verification_status: "ok".to_owned(),
                        ..SubscriptionProviderState::default()
                    },
                ),
                (
                    "cline".to_owned(),
                    SubscriptionProviderState {
                        // 已添加但验证失败 → 不得出现在启用集合里。
                        enabled: false,
                        verification_status: "failed".to_owned(),
                        ..SubscriptionProviderState::default()
                    },
                ),
            ])),
            // 故意写入漂移值, 归一必须纠正它。
            enabled_providers: vec!["cline".to_owned(), "grok".to_owned()],
            ..AppSettings::default()
        };
        sync_enabled_providers(&mut settings);
        assert_eq!(settings.enabled_providers, vec!["kimi".to_owned()]);

        // 落盘与加载两侧都保持派生口径。
        let root = temp_root();
        save_settings(&root, &settings).unwrap();
        let loaded = load_settings(&root);
        assert_eq!(loaded.enabled_providers, vec!["kimi".to_owned()]);
    }

    /// C090: 保存入口先按原样校验, 未知 Provider 仍一律拒绝 (不得被归一静默吞掉)。
    #[test]
    fn unknown_provider_is_still_rejected_before_normalization() {
        let root = temp_root();
        let settings = AppSettings {
            enabled_providers: vec!["notAProvider".to_owned()],
            ..AppSettings::default()
        };
        assert!(save_settings(&root, &settings).is_err());
    }

    /// 显式集合是权威: 允许移除到空集合, 不会被再次播种。
    #[test]
    fn explicit_added_set_survives_round_trip_including_empty() {
        let root = temp_root();
        let settings = AppSettings {
            subscription_providers: Some(BTreeMap::new()),
            ..AppSettings::default()
        };
        save_settings(&root, &settings).unwrap();
        let loaded = load_settings(&root);
        assert_eq!(
            loaded.subscription_providers,
            Some(BTreeMap::new()),
            "空集合必须被保留 (不得回落到播种)"
        );
        assert!(added_subscription_providers(&loaded).is_empty());

        let with_one = AppSettings {
            subscription_providers: Some(BTreeMap::from([(
                "kimi".to_owned(),
                SubscriptionProviderState {
                    enabled: true,
                    last_verified_at: Some("2026-10-22T08:00:00Z".to_owned()),
                    verification_status: "ok".to_owned(),
                    failure_reason: None,
                },
            )])),
            ..AppSettings::default()
        };
        save_settings(&root, &with_one).unwrap();
        let loaded = load_settings(&root);
        assert_eq!(
            loaded.subscription_providers,
            with_one.subscription_providers
        );
    }

    #[test]
    fn unknown_provider_or_bad_verification_status_is_rejected() {
        assert!(validate_settings(&AppSettings {
            subscription_providers: Some(BTreeMap::from([(
                "notAProvider".to_owned(),
                SubscriptionProviderState::default(),
            )])),
            ..AppSettings::default()
        })
        .is_err());
        assert!(validate_settings(&AppSettings {
            subscription_providers: Some(BTreeMap::from([(
                "kimi".to_owned(),
                SubscriptionProviderState {
                    verification_status: "weird".to_owned(),
                    ..SubscriptionProviderState::default()
                },
            )])),
            ..AppSettings::default()
        })
        .is_err());
    }

    /// 已添加集合变化本身不触发全量采集 (启用集合未变)。
    #[test]
    fn added_set_change_does_not_require_collection() {
        let previous = AppSettings::default();
        let next = AppSettings {
            subscription_providers: Some(BTreeMap::new()),
            ..AppSettings::default()
        };
        assert!(!requires_collection(&previous, &next));
    }
}
