//! 凭证存储覆盖 —— 白名单、原子写、合并语义、平台数据根 (无 Windows 真机,
//! 自动化证据不代替 Windows 真机验收; 专属分支以 cfg(windows) 在 CI 执行)。

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs;
use std::path::PathBuf;

use base64::Engine;
use bruce_win_lib::credentials::{
    app_data_root_with, capture_stepfun_cookie_with, credential_accounts, credential_rejections,
    follow_local_claude, follow_local_grok, import_codex_discovered,
    import_volcengine_from_cc_switch, load_credentials, local_claude_status, local_grok_status,
    merge_credentials, remove_provider_credentials, save_credential_account, save_credentials,
    stepfun_account_id, validate_credential_payload, verify_subscription,
    verify_subscription_following_local, verify_subscription_with, with_local_claude,
    ClaudeLocalStatus, CredentialPayloads, DeepSeekProbe, GrokLocalStatus, StepFunCaptureOutcome,
    StepFunCookieCandidate, StepFunRemoteTransport, StepFunSite, StepFunVerifyRequest,
    SubscriptionVerification,
};
use bruce_win_lib::runtime_core::{window_action, WindowAction};
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

// MARK: - Provider 专属格式校验 (C092) 与 Cline 字段分支 (C097)

/// 逐 Provider 对齐 mac `ProviderConnectionVerifier` 的本地格式判据 (C092 / 设计规则 27)。
#[test]
fn provider_specific_key_format_is_enforced_before_saving() {
    let cases: Vec<(&str, serde_json::Value, bool)> = vec![
        // Kimi: 非空且不含空白字符。
        (
            "kimiQuotaAccounts",
            json!({"a":{"api_key":"sk-kimi-ok"}}),
            true,
        ),
        (
            "kimiQuotaAccounts",
            json!({"a":{"api_key":"sk kimi bad"}}),
            false,
        ),
        // 火山引擎: AK/SK 非空、无空白且长度 ≥8。
        (
            "volcengineQuotaAccounts",
            json!({"a":{"accessKeyId":"AKLTabcdef","secretAccessKey":"secretkey123"}}),
            true,
        ),
        (
            "volcengineQuotaAccounts",
            json!({"a":{"accessKeyId":"short","secretAccessKey":"secretkey123"}}),
            false,
        ),
        (
            "volcengineQuotaAccounts",
            json!({"a":{"accessKeyId":"AKLTabcdef","secretAccessKey":"secret key"}}),
            false,
        ),
        // Z.ai: 非空、无空白且含 `.`, base URL 主机必须是个人版站点。
        (
            "zhipuQuotaAccounts",
            json!({"a":{"api_key":"abc.def","base_url":"https://open.bigmodel.cn/api/paas/v4"}}),
            true,
        ),
        (
            "zhipuQuotaAccounts",
            json!({"a":{"api_key":"abc.def","base_url":"https://api.z.ai/api/paas/v4"}}),
            true,
        ),
        (
            "zhipuQuotaAccounts",
            json!({"a":{"api_key":"nodot","base_url":"https://open.bigmodel.cn/api/paas/v4"}}),
            false,
        ),
        (
            "zhipuQuotaAccounts",
            json!({"a":{"api_key":"abc.def","base_url":"https://evil.example.com/api/paas/v4"}}),
            false,
        ),
        // StepFun: Oasis-Token 非空且无空白。
        (
            "stepfunQuotaAccounts",
            json!({"a":{"token":"Oasis-ok-token"}}),
            true,
        ),
        (
            "stepfunQuotaAccounts",
            json!({"a":{"token":"Oasis token"}}),
            false,
        ),
        ("stepfunQuotaAccounts", json!({"a":{"token":"   "}}), false),
        // Cline: 非空、无空白且长度 ≥16。
        (
            "clineQuotaAccounts",
            json!({"a":{"api_key":"0123456789abcdef"}}),
            true,
        ),
        (
            "clineQuotaAccounts",
            json!({"a":{"api_key":"0123456789abcde"}}),
            false,
        ),
    ];
    for (field, payload, expected_ok) in cases {
        let result = validate_credential_payload(field, &payload);
        assert_eq!(
            result.is_ok(),
            expected_ok,
            "{field} {payload} 期望 ok={expected_ok}, 实际 {result:?}"
        );
    }
}

/// C097: Cline 字段此前无校验分支, 保存恒失败; 现须与 Kimi / DeepSeek / Jev 同形可保存。
#[test]
fn cline_credentials_can_be_saved_like_other_api_key_providers() {
    let root = temp_root();
    save_credential_account(
        &root,
        "clineQuotaAccounts",
        "cline-1",
        &json!({"api_key":"0123456789abcdef","display_name":"Cline · 1"}),
    )
    .expect("合法 Cline 凭据必须可保存");
    let loaded = load_credentials(&root);
    assert_eq!(
        loaded["clineQuotaAccounts"]["cline-1"]["api_key"],
        json!("0123456789abcdef")
    );
    // 形状错误仍按 C092 规则被拒, 证明该分支不是无条件放行。
    assert!(save_credential_account(
        &root,
        "clineQuotaAccounts",
        "cline-2",
        &json!({"api_key":"too-short"}),
    )
    .is_err());
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

// MARK: - 凭据载荷形状契约与 fail-closed「已配置」(C081)

/// 旧通用表单写出的扁平 oauth 形状必须被拒绝 —— 采集端解析器读不出凭据,
/// 若放行即为「保存成功但永远查不出额度」的静默失效。
#[test]
fn oauth_providers_reject_flat_token_shape() {
    for field in [
        "claudeQuotaAccounts",
        "grokQuotaAccounts",
        "opencodeGoQuotaAccounts",
    ] {
        let flat = json!({"a": {"display_name": "A", "oauth": {"access_token": "fixture-token"}}});
        assert!(
            validate_credential_payload(field, &flat).is_err(),
            "{field} 旧扁平 oauth 形状必须拒绝"
        );
    }
}

/// 与采集端解析器一致的规范形状必须被接受。
#[test]
fn oauth_providers_accept_collector_native_shapes() {
    let cases: [(&str, serde_json::Value); 5] = [
        (
            "claudeQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"claudeAiOauth": {"accessToken": "tok"}}}}),
        ),
        (
            "claudeQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"claude.ai_oauth": {"accessToken": "tok"}}}}),
        ),
        (
            "grokQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"https://auth.x.ai::injected": {"key": "gk"}}}}),
        ),
        (
            "grokQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"key": "gk"}}}),
        ),
        (
            "opencodeGoQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"auth": "Fe26.2**fixture", "workspaceId": "wrk_fixture"}}}),
        ),
    ];
    for (field, shape) in cases {
        assert!(
            validate_credential_payload(field, &shape).is_ok(),
            "{field} 规范形状必须接受: {shape}"
        );
    }
}

/// 三家各自的必需键缺失必须给出可诊断文案, 且不回显凭据值。
#[test]
fn oauth_shape_failures_are_diagnosable_without_echoing_secrets() {
    let cases: [(&str, serde_json::Value, &str); 4] = [
        (
            "claudeQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"accessToken": "fixture-secret"}}}),
            "claudeAiOauth",
        ),
        (
            "claudeQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"claudeAiOauth": {}}}}),
            "accessToken",
        ),
        (
            "grokQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"https://other.example::x": {"key": "fixture-secret"}}}}),
            "auth.x.ai",
        ),
        (
            "opencodeGoQuotaAccounts",
            json!({"a": {"display_name": "A", "oauth": {"auth": "fixture-secret"}}}),
            // C085: 文案改为直指「重新粘贴」(用户据此回到引导行重取 Cookie 与 wrk_ ID)。
            "重新粘贴",
        ),
    ];
    for (field, shape, needle) in cases {
        let error = validate_credential_payload(field, &shape).unwrap_err();
        assert!(
            error.contains(needle),
            "{field} 文案需指出缺失项 {needle}: {error}"
        );
        assert!(
            !error.contains("fixture-secret"),
            "{field} 文案不得回显凭据值: {error}"
        );
    }
}

/// 逐账号容错: 单账号形状不合法只丢该账号, 同字段的可用记录保留;
/// 全部不合法时字段整体消失 (fail-closed), 磁盘文件不被改写。
#[test]
fn invalid_account_is_dropped_without_losing_valid_siblings() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({
            "claudeQuotaAccounts": {
                "good": {"display_name": "可用", "oauth": {"claudeAiOauth": {"accessToken": "tok"}}},
                "legacy": {"display_name": "旧形状", "oauth": {"access_token": "tok"}}
            },
            "grokQuotaAccounts": {
                "broken": {"display_name": "全坏", "oauth": {"access_token": "tok"}}
            }
        })
        .to_string(),
    )
    .unwrap();

    let loaded = load_credentials(&root);
    assert_eq!(
        loaded["claudeQuotaAccounts"]["good"]["oauth"]["claudeAiOauth"]["accessToken"],
        json!("tok"),
        "合法账号必须保留"
    );
    assert!(
        loaded["claudeQuotaAccounts"].get("legacy").is_none(),
        "形状不合法的账号必须丢弃"
    );
    assert!(
        !loaded.contains_key("grokQuotaAccounts"),
        "全部账号不合法时该字段整体消失"
    );
    // 读取不改写文件: 坏账号仍在磁盘上, 便于人工诊断。
    let raw = fs::read_to_string(root.join("credentials.json")).unwrap();
    assert!(raw.contains("legacy"), "读取侧不得改写磁盘文件");
}

/// fail-closed「已配置」: 坏形状账号不进入 IPC 账号清单, 故 UI 判为未配置。
#[test]
fn unusable_shape_does_not_report_as_configured() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({"opencodeGoQuotaAccounts": {"a": {"display_name": "A", "oauth": {"access_token": "tok"}}}})
            .to_string(),
    )
    .unwrap();
    assert!(
        credential_accounts(&root).is_empty(),
        "形状不合法的账号不得出现在账号清单中"
    );
}

/// 保存路径同样拒绝坏形状, 且不落盘半成品。
#[test]
fn save_rejects_bad_oauth_shape_without_writing() {
    let root = temp_root();
    let result = save_credential_account(
        &root,
        "grokQuotaAccounts",
        "a",
        &json!({"display_name": "A", "oauth": {"access_token": "fixture-token"}}),
    );
    assert!(result.is_err(), "坏形状必须拒绝保存");
    assert!(load_credentials(&root).is_empty(), "拒绝后不得留下半成品");
}

// MARK: - 订阅 Provider 验证 (C082)

#[test]
fn verify_subscription_reports_none_without_credentials() {
    let root = temp_root();
    assert_eq!(verify_subscription(&root, "kimi").status, "none");
    assert_eq!(verify_subscription(&root, "notAProvider").status, "failed");
}

#[test]
fn verify_subscription_reports_ok_for_a_valid_record() {
    let root = temp_root();
    save_credential_account(
        &root,
        "kimiQuotaAccounts",
        "work",
        &json!({"api_key": "fixture-key"}),
    )
    .unwrap();
    let result = verify_subscription(&root, "kimi");
    assert_eq!(result.status, "ok");
    assert_eq!(result.reason, None);
}

/// 遗留的坏形状账号必须显式报 failed 并给出原因, 而不是静默消失成「未配置」。
#[test]
fn verify_subscription_surfaces_legacy_broken_shape() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({"claudeQuotaAccounts": {"legacy": {"display_name": "旧形状", "oauth": {"access_token": "tok"}}}})
            .to_string(),
    )
    .unwrap();
    let result = verify_subscription(&root, "claude");
    assert_eq!(result.status, "failed");
    assert!(
        result
            .reason
            .as_deref()
            .unwrap_or_default()
            .contains("claudeAiOauth"),
        "失败原因需指出缺失的包装: {:?}",
        result.reason
    );
}

#[test]
fn verify_subscription_reports_needs_relogin_for_reauth_required_account() {
    let root = temp_root();
    save_credential_account(
        &root,
        "codexQuotaAccounts",
        "work",
        &json!({"access_token": "fixture-token", "authorization_state": "reauthRequired"}),
    )
    .unwrap();
    assert_eq!(verify_subscription(&root, "codex").status, "needsRelogin");
}

// MARK: - 移除服务 (C089) 与本机跟随验证 (C091)

/// 移除服务删除该 Provider 的全部凭据 —— 含读取侧已丢弃、界面不可见的不合规账号与
/// 遗留整体 OAuth 字段; 其他 Provider 不受影响, 重新添加得到空账号列表。
#[test]
fn removing_a_provider_drops_every_credential_including_hidden_ones() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({
            "kimiQuotaAccounts": {
                "visible": {"display_name": "可见", "api_key": "fixture-kimi-key"},
                "hidden": {"display_name": "不合规", "api_key": "fixture kimi key"}
            },
            "claudeQuotaAccounts": {
                "work": {"display_name": "W", "oauth": {"claudeAiOauth": {"accessToken": "tok"}}}
            },
            "claudeOAuth": {"claudeAiOauth": {"accessToken": "legacy-tok"}},
            "clineQuotaAccounts": {"c1": {"display_name": "C", "api_key": "fixture-cline-key-0001"}}
        })
        .to_string(),
    )
    .unwrap();
    assert_eq!(
        credential_accounts(&root)
            .iter()
            .filter(|account| account["field"] == "kimiQuotaAccounts")
            .count(),
        1,
        "前置: 含空白的 Kimi 账号对界面不可见"
    );

    remove_provider_credentials(&root, "kimi").unwrap();
    let raw = fs::read_to_string(root.join("credentials.json")).unwrap();
    assert!(
        !raw.contains("kimiQuotaAccounts"),
        "可见与不可见账号一并删除"
    );
    assert!(
        !raw.contains("fixture kimi key"),
        "不可见账号的密钥不得残留在磁盘上"
    );
    assert!(raw.contains("clineQuotaAccounts"), "其他 Provider 不受影响");
    assert!(
        credential_accounts(&root)
            .iter()
            .all(|account| account["field"] != "kimiQuotaAccounts"),
        "重新添加得到空账号列表"
    );

    remove_provider_credentials(&root, "claude").unwrap();
    let loaded = load_credentials(&root);
    assert!(!loaded.contains_key("claudeQuotaAccounts"));
    assert!(
        !loaded.contains_key("claudeOAuth"),
        "遗留整体 OAuth 字段一并删除"
    );
    assert!(loaded.contains_key("clineQuotaAccounts"));
}

/// 失败即不动磁盘: 未知服务拒绝且文件原样; 无凭据文件时不凭空创建。
#[test]
fn removing_a_provider_fails_closed_and_never_creates_a_file() {
    let root = temp_root();
    save_credential_account(
        &root,
        "kimiQuotaAccounts",
        "work",
        &json!({"api_key": "fixture-key"}),
    )
    .unwrap();
    let before = fs::read_to_string(root.join("credentials.json")).unwrap();
    assert!(remove_provider_credentials(&root, "notAProvider").is_err());
    assert_eq!(
        fs::read_to_string(root.join("credentials.json")).unwrap(),
        before,
        "失败时一个凭据都不删"
    );

    let empty = temp_root();
    remove_provider_credentials(&empty, "kimi").unwrap();
    assert!(
        !empty.join("credentials.json").exists(),
        "无凭据文件时不得创建"
    );
}

/// Claude 零配置跟随 (C075) 不落盘: 无已存凭据时按本机登录态验证, 否则跟随中的
/// Claude 永远验证为 none、无法经验证启用 (C090)。
#[test]
fn claude_verification_follows_the_local_cli_login_without_stored_credentials() {
    let root = temp_root();
    let home = temp_home();
    assert_eq!(
        verify_subscription_following_local(&root, &home, "claude", FAR_FUTURE_MS - 1).status,
        "none",
        "未发现本机登录态仍为 none"
    );
    write_claude_credentials(&home, FAR_FUTURE_MS);
    assert_eq!(
        verify_subscription_following_local(&root, &home, "claude", FAR_FUTURE_MS - 1).status,
        "ok",
        "跟随中视为验证通过"
    );
    assert_eq!(
        verify_subscription_following_local(&root, &home, "claude", FAR_FUTURE_MS + 1).status,
        "needsRelogin",
        "本机登录态过期 → 需重新登录"
    );
    assert_eq!(
        verify_subscription_following_local(&root, &home, "kimi", FAR_FUTURE_MS - 1).status,
        "none",
        "本机 Claude 登录态不影响其他 Provider"
    );
}

/// 已存凭据优先 (对齐 with_local_claude): 坏形状的已存账号照常报 failed, 不被本机登录态掩盖。
#[test]
fn stored_claude_credentials_take_precedence_over_the_local_login() {
    let root = temp_root();
    let home = temp_home();
    write_claude_credentials(&home, FAR_FUTURE_MS);
    fs::write(
        root.join("credentials.json"),
        json!({"claudeQuotaAccounts": {"legacy": {"display_name": "旧形状", "oauth": {"access_token": "tok"}}}})
            .to_string(),
    )
    .unwrap();
    assert_eq!(
        verify_subscription_following_local(&root, &home, "claude", FAR_FUTURE_MS - 1).status,
        "failed"
    );
}

// MARK: - DeepSeek 真实试查与 CC Switch 火山引擎导入 (C083)

/// 注入式试查桩: 测试不触网, 并记录收到的 api key。
struct StubProbe {
    result: SubscriptionVerification,
    seen: std::sync::Mutex<Vec<String>>,
}

impl StubProbe {
    fn new(status: &'static str, reason: Option<&str>) -> Self {
        Self {
            result: SubscriptionVerification {
                status,
                reason: reason.map(str::to_owned),
            },
            seen: std::sync::Mutex::new(Vec::new()),
        }
    }
    fn seen(&self) -> Vec<String> {
        self.seen.lock().unwrap().clone()
    }
}

impl DeepSeekProbe for StubProbe {
    fn verify(&self, api_key: &str) -> SubscriptionVerification {
        self.seen.lock().unwrap().push(api_key.to_owned());
        self.result.clone()
    }
}

#[test]
fn deepseek_verification_runs_the_remote_probe_after_the_structural_check() {
    let root = temp_root();
    save_credential_account(
        &root,
        "deepseekQuotaAccounts",
        "work",
        &json!({"api_key": "sk-fixture-deepseek"}),
    )
    .unwrap();

    let ok = StubProbe::new("ok", None);
    assert_eq!(
        verify_subscription_with(&root, "deepseek", &ok).status,
        "ok",
        "结构校验通过后由试查结果决定"
    );
    assert_eq!(ok.seen(), vec!["sk-fixture-deepseek".to_owned()]);

    let rejected = StubProbe::new("failed", Some("API key 无效或已过期"));
    let result = verify_subscription_with(&root, "deepseek", &rejected);
    assert_eq!(result.status, "failed");
    assert_eq!(result.reason.as_deref(), Some("API key 无效或已过期"));
}

/// 结构校验失败时不得发起试查 (fail-closed, 也不把坏形状当网络问题)。
#[test]
fn deepseek_verification_skips_the_probe_when_the_shape_is_invalid() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({"deepseekQuotaAccounts": {"broken": {"display_name": "坏"}}}).to_string(),
    )
    .unwrap();
    let probe = StubProbe::new("ok", None);
    let result = verify_subscription_with(&root, "deepseek", &probe);
    assert_eq!(result.status, "failed");
    assert!(probe.seen().is_empty(), "形状不合法时不得触网");
}

/// 其他 Provider 不触网 (只做结构校验)。
#[test]
fn non_deepseek_verification_never_calls_the_probe() {
    let root = temp_root();
    save_credential_account(
        &root,
        "kimiQuotaAccounts",
        "work",
        &json!({"api_key": "fixture-key"}),
    )
    .unwrap();
    let probe = StubProbe::new("failed", Some("不应被调用"));
    assert_eq!(verify_subscription_with(&root, "kimi", &probe).status, "ok");
    assert!(probe.seen().is_empty());
}

/// 造一份最小 CC Switch 库 (providers 表)。
fn write_cc_switch_database(home: &std::path::Path, meta: &str) {
    let directory = home.join(".cc-switch");
    fs::create_dir_all(&directory).unwrap();
    let connection = rusqlite::Connection::open(directory.join("cc-switch.db")).unwrap();
    connection
        .execute_batch("CREATE TABLE providers (name TEXT PRIMARY KEY, meta TEXT);")
        .unwrap();
    connection
        .execute(
            "INSERT INTO providers (name, meta) VALUES ('火山Codingplan', ?1)",
            [meta],
        )
        .unwrap();
}

#[test]
fn volcengine_import_from_cc_switch_saves_decoded_secret_and_verifies() {
    let home = temp_home();
    let root = temp_root();
    let encoded = base64::engine::general_purpose::STANDARD.encode("SKfixture-real");
    write_cc_switch_database(
        &home,
        &format!(
            r#"{{"usage_script":{{"accessKeyId":"AKfixture","secretAccessKey":"{encoded}"}}}}"#
        ),
    );

    let result = import_volcengine_from_cc_switch(&root, &home).unwrap();
    assert_eq!(result.status, "ok", "导入后立即结构校验通过");
    let stored = load_credentials(&root);
    let accounts = stored["volcengineQuotaAccounts"].as_object().unwrap();
    assert_eq!(accounts.len(), 1);
    let (_, account) = accounts.iter().next().unwrap();
    assert_eq!(account["accessKeyId"], json!("AKfixture"));
    assert_eq!(
        account["secretAccessKey"],
        json!("SKfixture-real"),
        "SK 已解码"
    );
    assert!(account["display_name"]
        .as_str()
        .unwrap()
        .starts_with("火山引擎 · "));

    // 只读红线: 外部库未被修改 (行数不变)。
    let connection =
        rusqlite::Connection::open(home.join(".cc-switch").join("cc-switch.db")).unwrap();
    let count: i64 = connection
        .query_row("SELECT COUNT(*) FROM providers", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn volcengine_import_without_database_reports_cleanly() {
    let home = temp_home();
    let root = temp_root();
    let error = import_volcengine_from_cc_switch(&root, &home).unwrap_err();
    assert!(error.contains("CC Switch"), "错误需可诊断: {error}");
    assert!(load_credentials(&root).is_empty(), "未导入不得写入任何凭证");
}

/// C092: 被读取侧丢弃的旧账号必须能说明原因, 且绝不回传凭据值。
#[test]
fn rejected_accounts_report_a_reason_without_leaking_secrets() {
    let root = temp_root();
    fs::write(
        root.join("credentials.json"),
        json!({"kimiQuotaAccounts": {"legacy": {"display_name": "L", "api_key": "fixture kimi key"}}})
            .to_string(),
    )
    .unwrap();
    assert!(
        credential_accounts(&root).is_empty(),
        "不合规账号仍不得进入账号清单 (fail-closed 已配置)"
    );
    let rejections = credential_rejections(&root);
    assert_eq!(rejections.len(), 1, "被丢弃账号须逐条上报");
    assert_eq!(rejections[0]["field"], "kimiQuotaAccounts");
    assert_eq!(rejections[0]["accountId"], "legacy");
    assert!(
        rejections[0]["reason"]
            .as_str()
            .is_some_and(|reason| reason.contains("空白")),
        "原因须可诊断: {:?}",
        rejections[0]["reason"]
    );
    let serialized = serde_json::to_string(&rejections).unwrap();
    assert!(
        !serialized.contains("fixture kimi key"),
        "原因清单不得回传凭据值"
    );
}

// ── C084: Codex 设备码登录与本机账号只读发现 ──────────────────────────────────

/// 只读发现的 metadata-only 记录可通过校验 (无令牌), 但经 IPC 下发时 `usable = false`。
#[test]
fn codex_metadata_records_validate_but_are_not_usable() {
    let metadata = json!({"discovered-1": {"display_name":"discovered-1","email":"a@b.c","authorization_state":"reauthRequired"}});
    validate_credential_payload("codexQuotaAccounts", &metadata)
        .expect("metadata-only 记录必须通过校验 (C084)");

    let root = temp_root();
    let mut payloads = CredentialPayloads::new();
    payloads.insert("codexQuotaAccounts".to_owned(), metadata);
    save_credentials(&root, &payloads).unwrap();

    let accounts = credential_accounts(&root);
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0]["authorizationState"], json!("reauthRequired"));
    assert_eq!(
        accounts[0]["usable"],
        json!(false),
        "发现账号必须被标为不可用, 否则 UI 会误报已配置"
    );
    // 采集侧同样跳过 (collector.rs 过滤 reauthRequired), 账号不会触发出站查询。
}

/// 非元数据记录仍要求非空 access_token —— 放宽只针对发现写入的占位记录。
#[test]
fn codex_non_metadata_records_still_require_access_token() {
    let missing = json!({"a1": {"display_name":"a1"}});
    assert!(
        validate_credential_payload("codexQuotaAccounts", &missing).is_err(),
        "缺少 access_token 且非 reauthRequired 必须被拒"
    );
    let blank = json!({"a1": {"display_name":"a1","access_token":"   "}});
    assert!(validate_credential_payload("codexQuotaAccounts", &blank).is_err());
    let connected = json!({"a1": {"display_name":"a1","access_token":"fixture-access"}});
    assert!(validate_credential_payload("codexQuotaAccounts", &connected).is_ok());
}

/// 只读发现: 写 metadata-only、不覆盖已有记录、不导入任何令牌。
#[test]
fn codex_discovery_writes_metadata_only_and_never_overwrites() {
    let root = temp_root();
    let home = temp_root();
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(
        home.join(".codex").join("auth.json"),
        r#"{"tokens":{"account_id":"cli-1","email":"cli@b.c","access_token":"cli-secret"}}"#,
    )
    .unwrap();
    fs::create_dir_all(home.join(".cc-switch")).unwrap();
    fs::write(
        home.join(".cc-switch").join("codex_oauth_auth.json"),
        r#"{"accounts":{"cc-1":{"email":"cc@b.c"}}}"#,
    )
    .unwrap();

    // 用户已自己登录出来的完整记录必须保留原状。
    save_credential_account(
        &root,
        "codexQuotaAccounts",
        "cli-1",
        &json!({"display_name":"cli-1","access_token":"user-access","authorization_state":"connected"}),
    )
    .unwrap();

    let added = import_codex_discovered(&root, &home).unwrap();
    assert_eq!(added, 1, "只新增未存在的账号 (cli-1 已有, 不覆盖)");

    let stored = load_credentials(&root)["codexQuotaAccounts"].clone();
    assert_eq!(
        stored["cli-1"]["access_token"],
        json!("user-access"),
        "已有完整记录不得被元数据覆盖"
    );
    assert_eq!(stored["cli-1"]["authorization_state"], json!("connected"));
    assert_eq!(
        stored["cc-1"]["authorization_state"],
        json!("reauthRequired")
    );
    assert_eq!(stored["cc-1"]["email"], json!("cc@b.c"));
    for key in ["access_token", "refresh_token", "id_token"] {
        assert!(stored["cc-1"].get(key).is_none(), "发现记录不得携带 {key}");
    }
    // 外部文件只读: 发现过程不改写 CLI / CC Switch 文件。
    assert!(fs::read_to_string(home.join(".codex").join("auth.json"))
        .unwrap()
        .contains("cli-secret"));
    // 再次发现不产生新增 (幂等)。
    assert_eq!(import_codex_discovered(&root, &home).unwrap(), 0);
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&home);
}

/// 发现文件损坏时 fail-closed: 报可诊断错误, 不写半成品记录。
#[test]
fn codex_discovery_fails_closed_on_broken_file() {
    let root = temp_root();
    let home = temp_root();
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(home.join(".codex").join("auth.json"), "{ not json").unwrap();

    let error = import_codex_discovered(&root, &home).expect_err("损坏文件必须报错");
    assert!(error.contains("解析失败"), "错误须可诊断: {error}");
    assert!(
        !load_credentials(&root).contains_key("codexQuotaAccounts"),
        "失败时不得写入任何记录"
    );
    // 无任何发现来源时是空结果, 不是错误。
    let empty_home = temp_root();
    assert_eq!(import_codex_discovered(&root, &empty_home).unwrap(), 0);
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&home);
    let _ = fs::remove_dir_all(&empty_home);
}

// ── C085: Claude / Grok / OpenCode GO 专属对话框 ─────────────────────────────

/// 三家 OAuth Provider 的过期语义 (对齐 mac `SubscriptionCredentialEvaluator`)。
#[test]
fn oauth_providers_expiry_semantics_follow_mac() {
    let root = temp_root();
    let past = 1_600_000_000_000i64; // 2020-09 (毫秒)
    let future = 4_102_444_800_000i64; // 2100 (毫秒)

    // Claude: accessToken 过期但 refreshToken 仍在有效期 → 照常放行 (refreshPending)
    save_credential_account(
        &root,
        "claudeQuotaAccounts",
        "c1",
        &json!({"display_name":"c1","oauth":{"claudeAiOauth":{
            "accessToken":"fixture-access","expiresAt":past,
            "refreshToken":"fixture-refresh","refreshTokenExpiresAt":future}}}),
    )
    .unwrap();
    assert_eq!(
        verify_subscription(&root, "claude").status,
        "ok",
        "refreshPending 照常放行 (C085)"
    );

    // refreshToken 亦失效 → 需重新登录
    save_credential_account(
        &root,
        "claudeQuotaAccounts",
        "c1",
        &json!({"display_name":"c1","oauth":{"claudeAiOauth":{
            "accessToken":"fixture-access","expiresAt":past,
            "refreshToken":"fixture-refresh","refreshTokenExpiresAt":past}}}),
    )
    .unwrap();
    assert_eq!(verify_subscription(&root, "claude").status, "needsRelogin");

    // Grok: 作用域条目过期 → 需重新登录; 未过期 → ok
    save_credential_account(
        &root,
        "grokQuotaAccounts",
        "g1",
        &json!({"display_name":"g1","oauth":{"https://auth.x.ai::injected":{"key":"fixture-key","expires_at":past}}}),
    )
    .unwrap();
    assert_eq!(verify_subscription(&root, "grok").status, "needsRelogin");
    save_credential_account(
        &root,
        "grokQuotaAccounts",
        "g1",
        &json!({"display_name":"g1","oauth":{"https://auth.x.ai::injected":{"key":"fixture-key","expires_at":future}}}),
    )
    .unwrap();
    assert_eq!(verify_subscription(&root, "grok").status, "ok");

    // OpenCode GO: 缺 workspaceId 的文案必须指向「重新粘贴」(C085)
    let error = validate_credential_payload(
        "opencodeGoQuotaAccounts",
        &json!({"o1":{"display_name":"o1","oauth":{"auth":"fixture-cookie"}}}),
    )
    .expect_err("缺 workspaceId 必须被拒");
    assert!(error.contains("重新粘贴"), "文案须指向重新粘贴: {error}");
    let _ = fs::remove_dir_all(&root);
}

/// Grok 本机只读跟随: 命中注入 `grok-cli`、缺失静默回落、外部文件不被改写。
#[test]
fn grok_local_follow_reads_file_without_writing_back() {
    let root = temp_root();
    let home = temp_root();
    fs::create_dir_all(home.join(".grok")).unwrap();
    let path = home.join(".grok").join("auth.json");
    fs::write(
        &path,
        r#"{"https://auth.x.ai::injected":{"key":"local-key","expires_at":4102444800000}}"#,
    )
    .unwrap();

    assert_eq!(
        local_grok_status(&home, chrono::Utc::now().timestamp_millis()),
        GrokLocalStatus::Followed
    );
    assert_eq!(
        follow_local_grok(&root, &home).unwrap(),
        GrokLocalStatus::Followed
    );
    let stored = load_credentials(&root)["grokQuotaAccounts"].clone();
    assert_eq!(
        stored["grok-cli"]["oauth"]["https://auth.x.ai::injected"]["key"],
        json!("local-key")
    );
    // 外部文件只读
    assert!(fs::read_to_string(&path).unwrap().contains("local-key"));
    // 无本机登录态时不写入、返回 NotFound
    let empty = temp_root();
    let clean = temp_root();
    assert_eq!(
        follow_local_grok(&clean, &empty).unwrap(),
        GrokLocalStatus::NotFound
    );
    assert!(!load_credentials(&clean).contains_key("grokQuotaAccounts"));
    let _ = fs::remove_dir_all(&root);
    let _ = fs::remove_dir_all(&home);
    let _ = fs::remove_dir_all(&empty);
    let _ = fs::remove_dir_all(&clean);
}

// ── C086: StepFun 内嵌网页登录与自动抓 Cookie ─────────────────────────────────

struct StubStepFunTransport {
    status: u16,
    calls: std::sync::Mutex<Vec<StepFunVerifyRequest>>,
}

impl StubStepFunTransport {
    fn new(status: u16) -> Self {
        Self {
            status,
            calls: std::sync::Mutex::new(Vec::new()),
        }
    }
}

impl StepFunRemoteTransport for StubStepFunTransport {
    fn post_status(&self, request: &StepFunVerifyRequest) -> Result<u16, String> {
        self.calls.lock().unwrap().push(request.clone());
        Ok(self.status)
    }
}

/// 网页登录自动抓 Cookie: 远程 `QueryStepPlanRateLimit` 校验通过后按 DJB2 派生账号 ID 落盘,
/// 与手动粘贴同一 token 落在同一账号 (upsert 不重复), 且校验失败时不落盘。
#[test]
fn stepfun_cookie_capture_verifies_remotely_and_upserts_matching_manual_account_id() {
    let root = temp_root();
    let token = "eyJhbGciOiJIUzI1NiJ9.eyJhcHBfaWQiOiIxMDMwMCIsImRldmljZV9pZCI6ImRldi1hIn0.sig";
    let cookies = vec![StepFunCookieCandidate {
        name: "Oasis-Token".to_owned(),
        value: token.to_owned(),
        domain: ".stepfun.com".to_owned(),
    }];

    // 1. 远程返回 401 时拒绝落盘 (自动轮询返回 Waiting, 手动点击返回 Failed)
    let rejected = StubStepFunTransport::new(401);
    let outcome_rejected = capture_stepfun_cookie_with(
        &root,
        StepFunSite::Domestic,
        "https://platform.stepfun.com/step-plan",
        &cookies,
        true,
        &rejected,
    )
    .unwrap();
    assert!(matches!(
        outcome_rejected,
        StepFunCaptureOutcome::Failed { .. }
    ));
    assert!(
        !load_credentials(&root).contains_key("stepfunQuotaAccounts"),
        "远程校验失败不得落盘"
    );

    // 2. 远程返回 200 时落盘，且派生的 account_id 与 stepfun_account_id 完全一致
    let ok = StubStepFunTransport::new(200);
    let outcome_ok = capture_stepfun_cookie_with(
        &root,
        StepFunSite::Domestic,
        "https://platform.stepfun.com/step-plan",
        &cookies,
        false,
        &ok,
    )
    .unwrap();
    let account_id = match outcome_ok {
        StepFunCaptureOutcome::Captured { account_id, .. } => account_id,
        other => panic!("expected Captured, got {other:?}"),
    };
    assert_eq!(account_id, stepfun_account_id(token));

    let stored = load_credentials(&root)["stepfunQuotaAccounts"].clone();
    assert_eq!(
        stored[&account_id]["token"],
        json!(token),
        "Oasis-Token 完整写入 token"
    );
    assert_eq!(stored[&account_id]["site"], json!("domestic"));
    assert_eq!(stored[&account_id]["is_global"], json!(false));
    assert_eq!(verify_subscription(&root, "stepfun").status, "ok");

    // 3. 再次以国际站捕获同一 token: upsert 到同一 account_id 并更新站点
    let global_cookies = vec![StepFunCookieCandidate {
        name: "Oasis-Token".to_owned(),
        value: token.to_owned(),
        domain: ".stepfun.ai".to_owned(),
    }];
    let global_ok = StubStepFunTransport::new(200);
    let outcome_global = capture_stepfun_cookie_with(
        &root,
        StepFunSite::Global,
        "https://platform.stepfun.ai/plan-subscribe",
        &global_cookies,
        false,
        &global_ok,
    )
    .unwrap();
    let again_id = match outcome_global {
        StepFunCaptureOutcome::Captured { account_id, .. } => account_id,
        other => panic!("expected Captured, got {other:?}"),
    };
    assert_eq!(again_id, account_id, "同一 token 必须 upsert 到同一账号");
    let updated = load_credentials(&root)["stepfunQuotaAccounts"].clone();
    assert_eq!(updated.as_object().unwrap().len(), 1);
    assert_eq!(updated[&account_id]["site"], json!("global"));
    assert_eq!(updated[&account_id]["is_global"], json!(true));

    // 4. 辅助窗口 `stepfun-login` 绝不被 runtime_core::window_action 拦截为隐藏常驻 (规则 10)
    assert_eq!(
        window_action("stepfun-login", false, true),
        WindowAction::None
    );
    assert_eq!(
        window_action("stepfun-login", true, false),
        WindowAction::None
    );
    let _ = fs::remove_dir_all(&root);
}
