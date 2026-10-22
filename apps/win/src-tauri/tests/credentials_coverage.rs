//! 凭证存储覆盖 —— 白名单、原子写、合并语义、平台数据根 (无 Windows 真机,
//! 自动化证据不代替 Windows 真机验收; 专属分支以 cfg(windows) 在 CI 执行)。

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::path::PathBuf;

use bruce_win_lib::credentials::{
    app_data_root_with, follow_local_claude, load_credentials, local_claude_status,
    merge_credentials, save_credentials, with_local_claude, ClaudeLocalStatus, CredentialPayloads,
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
        json!({"a1":{"api_key":"sk-kimi-test"}}),
    );
    payloads.insert(
        "deepseekQuotaAccounts".to_owned(),
        json!({"d1":{"api_key":"sk-ds-test"}}),
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
fn oversized_credential_write_is_rejected_without_losing_existing_accounts() {
    let root = temp_root();
    let original = sample_payloads();
    save_credentials(&root, &original).unwrap();
    let oversized = BTreeMap::from([(
        "claudeOAuth".to_owned(),
        json!({"access_token": "x".repeat(4 * 1024 * 1024)}),
    )]);
    assert!(save_credentials(&root, &oversized).is_err());
    assert_eq!(load_credentials(&root), original);
}

#[test]
fn load_silently_drops_unknown_fields() {
    let root = temp_root();
    let path = root.join("credentials.json");
    fs::write(
        &path,
        r#"{"legacyField":{"a":1},"codexQuotaAccounts":{"c1":{"display_name":"C1","access_token":"fixture-token"}}}"#,
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
        Some(json!({"a2":{"api_key":"sk-new"}})),
    );
    // 删除。
    patch.insert("deepseekQuotaAccounts".to_owned(), None);
    // 未提及的键保留 (codex 原本不存在, 通过第二次合并加入)。
    let merged = merge_credentials(&existing, &patch).unwrap();
    assert_eq!(
        merged["kimiQuotaAccounts"],
        json!({"a2":{"api_key":"sk-new"}})
    );
    assert!(!merged.contains_key("deepseekQuotaAccounts"));

    let mut patch = BTreeMap::new();
    patch.insert(
        "codexQuotaAccounts".to_owned(),
        Some(json!({"c1":{"display_name":"C1","access_token":"fixture-token"}})),
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
        json!({"国际站账号":{"display_name":"含中文/emoji 🎉/换行\n说明","token":"fixture-token","site":"global"}}),
    );
    payloads.insert(
        "providerEnv".to_owned(),
        json!({"largeText":"测试".repeat(200)}),
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
        PathBuf::from("/Users/dev/Library/Application Support/Bruce-Windows-Dev")
    );
}

#[test]
fn account_arrays_are_rejected_instead_of_silently_ignored_by_collector() {
    let patch = BTreeMap::from([(
        "kimiQuotaAccounts".to_owned(),
        Some(json!([{"accountID":"a1","apiKey":"fixture"}])),
    )]);
    assert!(merge_credentials(&CredentialPayloads::new(), &patch).is_err());
}

// MARK: - 本机 Claude CLI 登录态跟随 (C075)

/// 独立临时 home 目录。
fn temp_home() -> PathBuf {
    let root = temp_root().join("home");
    fs::create_dir_all(&root).unwrap();
    root
}

/// 写一份 Claude CLI 凭证文件 (`.claude/.credentials.json`)。
fn write_claude_credentials(home: &std::path::Path, expires_at_ms: i64) {
    let dir = home.join(".claude");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join(".credentials.json"),
        json!({"claudeAiOauth": {
            "accessToken": "sk-ant-oat-fixture",
            "refreshToken": "sk-ant-ort-fixture",
            "expiresAt": expires_at_ms,
        }})
        .to_string(),
    )
    .unwrap();
}

const FAR_FUTURE_MS: i64 = 4_102_444_800_000; // 2100-01-01
const LONG_PAST_MS: i64 = 1_600_000_000_000; // 2020-09-13 (毫秒, > 1e12 触发毫秒口径)

#[test]
fn claude_local_credentials_file_is_followed_without_manual_paste() {
    let home = temp_home();
    write_claude_credentials(&home, FAR_FUTURE_MS);
    assert_eq!(
        local_claude_status(&home, FAR_FUTURE_MS - 1),
        ClaudeLocalStatus::Followed
    );
    let injected = with_local_claude(CredentialPayloads::new(), &home);
    assert_eq!(
        injected["claudeQuotaAccounts"]["claude-cli"]["oauth"]["claudeAiOauth"]["accessToken"],
        json!("sk-ant-oat-fixture")
    );
    assert_eq!(
        injected["claudeQuotaAccounts"]["claude-cli"]["display_name"],
        json!("Claude CLI")
    );
}

#[test]
fn claude_local_falls_back_to_dot_claude_json() {
    let home = temp_home();
    // 无 .claude/.credentials.json, 仅 .claude.json 存在 → 回退命中。
    fs::write(
        home.join(".claude.json"),
        json!({"claudeAiOauth": {"accessToken": "sk-ant-oat-json"}}).to_string(),
    )
    .unwrap();
    assert_eq!(
        local_claude_status(&home, FAR_FUTURE_MS),
        ClaudeLocalStatus::Followed
    );
    let injected = with_local_claude(CredentialPayloads::new(), &home);
    assert_eq!(
        injected["claudeQuotaAccounts"]["claude-cli"]["oauth"]["claudeAiOauth"]["accessToken"],
        json!("sk-ant-oat-json")
    );
}

#[test]
fn claude_local_missing_or_malformed_is_silent() {
    let home = temp_home();
    // 无文件: 不报错, 状态 NotFound, 注入保持原样 (不新增空字段)。
    assert_eq!(
        local_claude_status(&home, FAR_FUTURE_MS),
        ClaudeLocalStatus::NotFound
    );
    let original = sample_payloads();
    assert_eq!(with_local_claude(original.clone(), &home), original);

    // 结构非法 (无 accessToken): 同样静默回落。
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::write(
        home.join(".claude").join(".credentials.json"),
        "{broken json",
    )
    .unwrap();
    assert_eq!(
        local_claude_status(&home, FAR_FUTURE_MS),
        ClaudeLocalStatus::NotFound
    );
}

#[test]
fn claude_local_expired_token_is_reported_as_expired() {
    let home = temp_home();
    write_claude_credentials(&home, LONG_PAST_MS);
    assert_eq!(
        local_claude_status(&home, FAR_FUTURE_MS),
        ClaudeLocalStatus::Expired
    );
}

#[test]
fn claude_local_does_not_override_user_stored_accounts() {
    let home = temp_home();
    write_claude_credentials(&home, FAR_FUTURE_MS);
    let stored = CredentialPayloads::from([(
        "claudeQuotaAccounts".to_owned(),
        json!({"work": {"display_name": "工作", "oauth": {"claudeAiOauth": {"accessToken": "stored"}}}}),
    )]);
    // 用户已存自有账号 → 不注入 CLI 跟随 (手工配置优先)。
    assert_eq!(with_local_claude(stored.clone(), &home), stored);
}

#[test]
fn follow_local_claude_persists_cli_account() {
    let home = temp_home();
    let root = temp_root();
    write_claude_credentials(&home, FAR_FUTURE_MS);
    assert_eq!(
        follow_local_claude(&root, &home).unwrap(),
        ClaudeLocalStatus::Followed
    );
    let stored = load_credentials(&root);
    assert_eq!(
        stored["claudeQuotaAccounts"]["claude-cli"]["oauth"]["claudeAiOauth"]["accessToken"],
        json!("sk-ant-oat-fixture")
    );
    // 无本机登录态时不写入任何凭证。
    let empty_home = temp_home();
    let empty_root = temp_root();
    assert_eq!(
        follow_local_claude(&empty_root, &empty_home).unwrap(),
        ClaudeLocalStatus::NotFound
    );
    assert!(load_credentials(&empty_root).is_empty());
}
