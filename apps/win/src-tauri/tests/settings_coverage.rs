//! 设置持久化覆盖 —— 校验边界、损坏回落、位置记忆与目录自建。

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use bruce_win_lib::settings::{
    load_settings, requires_collection, save_settings, sync_enabled_providers, validate_settings,
    AppSettings, SubscriptionProviderState, PROVIDERS,
};

fn temp_root() -> PathBuf {
    // 测试线程并行启动时 SystemTime 同纳秒会碰撞出共享目录 (实测 flake),
    // 以进程内原子序号保证唯一; 跨进程由 pid 区分。
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "bruce-settings-coverage-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn defaults_match_mac_scheduler_configuration() {
    let settings = AppSettings::default();
    assert_eq!(settings.refresh_interval_secs, 1800, "mac 默认刷新周期");
    assert!(settings.notifications_enabled);
    assert_eq!(settings.theme, "fluent");
    assert_eq!(settings.card_order, vec!["usage", "subscription", "hourly"]);
    assert!(settings.hotkey.is_empty(), "对齐 mac 默认不注册热键");
    assert_eq!(settings.panel_x, None);
    assert_eq!(settings.panel_y, None);
}

#[test]
fn missing_file_falls_back_to_defaults() {
    assert_eq!(load_settings(&temp_root()), AppSettings::default());
}

#[test]
fn round_trip_preserves_all_fields_including_panel_position() {
    let root = temp_root();
    let settings = AppSettings {
        refresh_interval_secs: 600,
        notifications_enabled: false,
        theme: "nothing".to_owned(),
        card_order: vec!["hourly".to_owned(), "usage".to_owned()],
        hotkey: "Ctrl+Alt+P".to_owned(),
        panel_x: Some(1920),
        panel_y: Some(-40),
        ..AppSettings::default()
    };
    save_settings(&root, &settings).unwrap();
    assert_eq!(load_settings(&root), settings, "含负坐标位置往返");
}

#[test]
fn config_round_trip_keeps_consent_provider_and_pricing_contract() {
    let root = temp_root();
    let settings: AppSettings = serde_json::from_value(serde_json::json!({
        "consentVersion": 1,
        "usageEnabled": false,
        "enabledProviders": ["kimi"],
        "providerOrder": ["kimi"],
        "pricingOverrides": {"k3": {"inputPricePerMillion": 0.25}}
    }))
    .unwrap();
    save_settings(&root, &settings).unwrap();
    let stored = serde_json::to_value(load_settings(&root)).unwrap();
    assert_eq!(stored["consentVersion"], 1);
    assert_eq!(stored["usageEnabled"], false);
    assert_eq!(stored["enabledProviders"], serde_json::json!(["kimi"]));
    assert_eq!(
        stored["pricingOverrides"]["k3"]["inputPricePerMillion"],
        0.25
    );
}

#[test]
fn unsafe_pricing_and_unknown_providers_are_rejected() {
    for raw in [
        serde_json::json!({"enabledProviders":["unknown"]}),
        serde_json::json!({"providerOrder":["kimi","kimi"]}),
        serde_json::json!({"pricingOverrides":{"k3":{"inputPricePerMillion":-1}}}),
        serde_json::json!({"pricingOverrides":{"k3":{"inputPricePerMillion":"secret"}}}),
        serde_json::json!({"consentVersion":99}),
    ] {
        let settings: AppSettings = serde_json::from_value(raw.clone()).unwrap();
        assert!(
            validate_settings(&settings).is_err(),
            "invalid settings accepted: {raw}"
        );
    }
}

#[test]
fn cline_is_a_known_provider_and_kept_in_enabled_list() {
    // C028: cline 必须进入 PROVIDERS, 否则启用列表与自定义顺序会被校验拒绝,
    // panel_json 的 enabled_providers 过滤还会把 Cline service 静默剔除。
    assert!(PROVIDERS.contains(&"cline"));
    assert!(!PROVIDERS.contains(&"jev"), "jev 界面隐藏, 不进可见清单");
    let settings = AppSettings {
        enabled_providers: vec!["cline".to_owned()],
        provider_order: vec!["cline".to_owned(), "codex".to_owned()],
        ..AppSettings::default()
    };
    assert!(validate_settings(&settings).is_ok());
    // C090: 默认不再预置任何 Provider; cline 作为已知 Provider 可被显式启用并保留。
    assert!(
        AppSettings::default().enabled_providers.is_empty(),
        "全新安装订阅集合为空"
    );
    let mut explicit = settings.clone();
    explicit.subscription_providers = Some(BTreeMap::from([(
        "cline".to_owned(),
        SubscriptionProviderState {
            enabled: true,
            ..SubscriptionProviderState::default()
        },
    )]));
    sync_enabled_providers(&mut explicit);
    assert_eq!(explicit.enabled_providers, vec!["cline".to_owned()]);
}

#[test]
fn corrupt_file_falls_back_to_defaults() {
    let root = temp_root();
    let path = root.join("config").join("settings.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, "{{{ not json").unwrap();
    assert_eq!(load_settings(&root), AppSettings::default());
}

#[test]
fn partial_json_fills_missing_fields_with_defaults() {
    let root = temp_root();
    let path = root.join("config").join("settings.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, r#"{"theme":"nothing"}"#).unwrap();
    let settings = load_settings(&root);
    assert_eq!(settings.theme, "nothing", "显式字段生效");
    assert_eq!(settings.refresh_interval_secs, 1800, "缺失字段回落默认");
    assert_eq!(settings.card_order, vec!["usage", "subscription", "hourly"]);
}

#[test]
fn out_of_range_interval_is_clamped_on_load() {
    // 纵深防御 (C007): validate 只拦保存入口, 手改文件的越界间隔
    // (0 会造成零间隔 busy-loop 采集) 必须在加载侧钳制回合法区间。
    let root = temp_root();
    let path = root.join("config").join("settings.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    for (raw, expected) in [(0u64, 60u64), (1, 60), (59, 60), (100_000, 86_400)] {
        fs::write(&path, format!(r#"{{"refreshIntervalSecs":{raw}}}"#)).unwrap();
        assert_eq!(
            load_settings(&root).refresh_interval_secs,
            expected,
            "raw={raw}"
        );
    }
}

#[test]
fn save_creates_config_directory_recursively() {
    let root = temp_root();
    assert!(!root.join("config").exists());
    save_settings(&root, &AppSettings::default()).unwrap();
    assert!(root.join("config").join("settings.json").exists());
}

#[test]
fn validate_refresh_interval_bounds_inclusive() {
    assert!(validate_settings(&AppSettings {
        refresh_interval_secs: 60,
        ..Default::default()
    })
    .is_ok());
    assert!(validate_settings(&AppSettings {
        refresh_interval_secs: 86_400,
        ..Default::default()
    })
    .is_ok());
    assert!(validate_settings(&AppSettings {
        refresh_interval_secs: 59,
        ..Default::default()
    })
    .is_err());
    assert!(validate_settings(&AppSettings {
        refresh_interval_secs: 86_401,
        ..Default::default()
    })
    .is_err());
    assert!(validate_settings(&AppSettings {
        refresh_interval_secs: 0,
        ..Default::default()
    })
    .is_err());
}

#[test]
fn validate_theme_and_hotkey_boundaries() {
    assert!(validate_settings(&AppSettings {
        theme: "fluent".to_owned(),
        ..Default::default()
    })
    .is_ok());
    assert!(validate_settings(&AppSettings {
        theme: "nothing".to_owned(),
        ..Default::default()
    })
    .is_ok());
    for theme in ["glass", "", "Nothing"] {
        assert!(validate_settings(&AppSettings {
            theme: theme.to_owned(),
            ..Default::default()
        })
        .is_err());
    }
    // 空热键表示不注册, 合法; 超长热键拒绝。
    assert!(validate_settings(&AppSettings {
        hotkey: String::new(),
        ..Default::default()
    })
    .is_ok());
    assert!(validate_settings(&AppSettings {
        hotkey: "x".repeat(65),
        ..Default::default()
    })
    .is_err());
}

#[test]
fn only_collection_inputs_trigger_an_immediate_collection() {
    // C069: 设置即时生效后每个控件单独保存; 只有改变采集输入的字段才触发全量采集。
    // C090: 启用集合由 subscription_providers 派生, 故基线取「已有启用项」的配置。
    let base = AppSettings {
        enabled_providers: PROVIDERS.iter().map(|s| (*s).to_owned()).collect(),
        ..AppSettings::default()
    };
    let changed = |edit: fn(&mut AppSettings)| {
        let mut next = base.clone();
        edit(&mut next);
        requires_collection(&base, &next)
    };
    assert!(changed(|s| s.consent_version = 1));
    assert!(changed(|s| s.usage_enabled = false));
    assert!(changed(|s| s.enabled_providers.retain(|p| p != "kimi")));
    assert!(changed(|s| {
        s.pricing_overrides.insert(
            "k3".into(),
            serde_json::json!({"inputPricePerMillion": 1.0}),
        );
    }));
    assert!(
        changed(|s| s.refresh_interval_secs = 300),
        "变更后立即重新计时"
    );
    // 纯展示 / 交互偏好: 只重新发布看板
    assert!(!changed(|s| s.theme = "nothing".into()));
    assert!(!changed(|s| s.card_order.reverse()));
    assert!(!changed(|s| s.provider_order = vec!["cline".into()]));
    assert!(!changed(|s| s.notifications_enabled = false));
    assert!(!changed(|s| s.hotkey = "Control+Shift+B".into()));
    assert!(!changed(|s| s.panel_x = Some(10)));
    // 启用集合相同、仅顺序不同不算采集输入变化
    assert!(!changed(|s| s.enabled_providers.reverse()));
}
