//! 凭证存储覆盖 —— 白名单、原子写、合并语义、平台数据根 (无 Windows 真机,
//! 测试即验收; Windows 专属分支以 cfg(windows) 在 windows-latest CI 执行)。

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::path::PathBuf;

use bruce_win_lib::credentials::{
    app_data_root_with, load_credentials, merge_credentials, save_credentials, CredentialPayloads,
};
use serde_json::json;

fn temp_root() -> PathBuf {
    // 测试线程并行启动时 SystemTime 同纳秒会碰撞出共享目录 (实测 flake),
    // 以进程内原子序号保证唯一; 跨进程由 pid 区分。
    static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let root = std::env::temp_dir().join(format!(
        "bruce-cred-coverage-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    fs::create_dir_all(&root).unwrap();
    root
}

fn sample_payloads() -> CredentialPayloads {
    let mut payloads = CredentialPayloads::new();
    payloads.insert(
        "kimiQuotaAccounts".to_owned(),
        json!([{ "accountID": "a1", "apiKey": "sk-kimi-test" }]),
    );
    payloads.insert(
        "deepseekQuotaAccounts".to_owned(),
        json!([{ "accountID": "d1", "apiKey": "sk-ds-test" }]),
    );
    payloads
}

#[test]
fn load_missing_file_is_empty() {
    assert!(load_credentials(&temp_root()).is_empty());
}

#[test]
fn save_then_load_round_trips_all_fields() {
    let root = temp_root();
    let payloads = sample_payloads();
    save_credentials(&root, &payloads).unwrap();
    assert_eq!(load_credentials(&root), payloads, "全字段往返一致");
}

#[test]
fn save_empty_map_clears_all_entries() {
    let root = temp_root();
    save_credentials(&root, &sample_payloads()).unwrap();
    save_credentials(&root, &CredentialPayloads::new()).unwrap();
    assert!(load_credentials(&root).is_empty(), "空表覆盖即清空");
}

#[test]
fn save_rejects_every_unknown_field() {
    let root = temp_root();
    for key in ["notAProvider", "claudeOAuthExtra", "kimiQuotaAccount"] {
        let mut payloads = CredentialPayloads::new();
        payloads.insert(key.to_owned(), json!({"x": 1}));
        assert!(
            save_credentials(&root, &payloads).is_err(),
            "{key} 必须拒绝"
        );
    }
    // 拒绝后磁盘不得留下半成品。
    assert!(load_credentials(&root).is_empty());
}

#[test]
fn load_silently_drops_unknown_fields() {
    let root = temp_root();
    let path = root.join("credentials.json");
    fs::write(
        &path,
        r#"{"legacyField":{"a":1},"codexQuotaAccounts":[{"accountID":"c1"}]}"#,
    )
    .unwrap();
    let loaded = load_credentials(&root);
    assert_eq!(loaded.len(), 1);
    assert!(loaded.contains_key("codexQuotaAccounts"));
}

#[test]
fn corrupt_file_is_treated_as_unconfigured() {
    let root = temp_root();
    fs::write(root.join("credentials.json"), "{broken json").unwrap();
    assert!(
        load_credentials(&root).is_empty(),
        "损坏视为缺失, 不阻塞本地采集"
    );
    fs::write(root.join("credentials.json"), "").unwrap();
    assert!(load_credentials(&root).is_empty());
}

#[test]
fn merge_semantics_overwrite_delete_and_keep() {
    let existing = sample_payloads();
    let mut patch: BTreeMap<String, Option<serde_json::Value>> = BTreeMap::new();
    // 覆盖。
    patch.insert(
        "kimiQuotaAccounts".to_owned(),
        Some(json!([{ "accountID": "a2", "apiKey": "sk-new" }])),
    );
    // 删除。
    patch.insert("deepseekQuotaAccounts".to_owned(), None);
    // 未提及的键保留 (codex 原本不存在, 通过第二次合并加入)。
    let merged = merge_credentials(&existing, &patch).unwrap();
    assert_eq!(
        merged["kimiQuotaAccounts"],
        json!([{ "accountID": "a2", "apiKey": "sk-new" }])
    );
    assert!(!merged.contains_key("deepseekQuotaAccounts"));

    let mut patch = BTreeMap::new();
    patch.insert(
        "codexQuotaAccounts".to_owned(),
        Some(json!([{ "accountID": "c1" }])),
    );
    let merged = merge_credentials(&merged, &patch).unwrap();
    assert_eq!(merged.len(), 2);
    assert!(merged.contains_key("kimiQuotaAccounts"));
    assert!(merged.contains_key("codexQuotaAccounts"));
}

#[test]
fn merge_rejects_unknown_fields_even_from_frontend() {
    let mut patch: BTreeMap<String, Option<serde_json::Value>> = BTreeMap::new();
    patch.insert("injected".to_owned(), Some(json!({"evil": true})));
    assert!(merge_credentials(&CredentialPayloads::new(), &patch).is_err());
}

#[test]
fn merged_payloads_persist_via_save() {
    let root = temp_root();
    save_credentials(&root, &sample_payloads()).unwrap();
    let existing = load_credentials(&root);
    let mut patch: BTreeMap<String, Option<serde_json::Value>> = BTreeMap::new();
    patch.insert("deepseekQuotaAccounts".to_owned(), None);
    let merged = merge_credentials(&existing, &patch).unwrap();
    save_credentials(&root, &merged).unwrap();
    let reloaded = load_credentials(&root);
    assert_eq!(reloaded.len(), 1);
    assert!(reloaded.contains_key("kimiQuotaAccounts"));
}

#[test]
fn unicode_and_large_payloads_round_trip() {
    let root = temp_root();
    let mut payloads = CredentialPayloads::new();
    payloads.insert(
        "stepfunQuotaAccounts".to_owned(),
        json!([{ "accountID": "国际站账号", "note": "含中文/emoji 🎉/换行\n说明" }]),
    );
    payloads.insert(
        "providerEnv".to_owned(),
        json!({ "batch": (0..200).map(|index| json!({"k": index})).collect::<Vec<_>>() }),
    );
    save_credentials(&root, &payloads).unwrap();
    assert_eq!(load_credentials(&root), payloads);
}

#[test]
#[cfg(unix)]
fn unix_file_permissions_are_owner_only() {
    use std::os::unix::fs::PermissionsExt;
    let root = temp_root();
    save_credentials(&root, &sample_payloads()).unwrap();
    let mode = fs::metadata(root.join("credentials.json"))
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600, "等价 mac POSIX 0600 语义");
}

#[test]
#[cfg(windows)]
fn windows_data_root_resolves_from_appdata_env() {
    // windows-latest CI 上执行: APPDATA 优先, 回退 ~/AppData/Roaming。
    let home = PathBuf::from("C:\\Users\\runneradmin");
    let root = app_data_root_with(
        &home,
        Some(OsStr::new("C:\\Users\\runneradmin\\AppData\\Roaming")),
    );
    assert_eq!(
        root,
        PathBuf::from("C:\\Users\\runneradmin\\AppData\\Roaming\\Bruce")
    );
    let root = app_data_root_with(&home, None);
    assert_eq!(
        root,
        PathBuf::from("C:\\Users\\runneradmin\\AppData\\Roaming\\Bruce")
    );
    // 空串环境值视为未设置 (trim 语义)。
    let root = app_data_root_with(&home, Some(OsStr::new("")));
    assert_eq!(
        root,
        PathBuf::from("C:\\Users\\runneradmin\\AppData\\Roaming\\Bruce")
    );
}

#[test]
#[cfg(not(windows))]
fn unix_data_root_ignores_appdata_hint() {
    let home = PathBuf::from("/Users/dev");
    let root = app_data_root_with(&home, Some(OsStr::new("/unused")));
    assert_eq!(
        root,
        PathBuf::from("/Users/dev/Library/Application Support/Bruce")
    );
}
