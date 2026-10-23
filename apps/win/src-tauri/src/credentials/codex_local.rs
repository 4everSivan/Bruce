//! 本机 Codex 账号只读发现 (C084 / 设计规则 23)。
//!
//! 对齐 mac `CodexDiscovery` (`BruceOnboardingCore/CodexCredentialStore.swift`):
//! 只读 `%USERPROFILE%\.codex\auth.json` 与 `%USERPROFILE%\.cc-switch\codex_oauth_auth.json`,
//! 只提取账号标识与邮箱, 一律写 **metadata-only** 记录 (`authorization_state = reauthRequired`),
//! **不导入任何令牌**。已存在的记录不覆盖 —— 用户自己登录出来的完整记录优先。
//!
//! 红线: 仅只读外部文件, 绝不回写; 结构非法 / 缺账号标识一律 fail-closed (报错, 不静默
//! 产生半成品记录); 发现的账号不计入「已配置」, 因此不会触发采集出站。

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// 发现来源 (仅用于 UI 文案与测试断言, 不落盘)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryOrigin {
    /// 本机 Codex CLI `~/.codex/auth.json`。
    CliAuth,
    /// CC Switch 账号库 `~/.cc-switch/codex_oauth_auth.json`。
    CCSwitch,
}

/// 一条只读发现的账号元数据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveredAccount {
    pub account_id: String,
    pub email: Option<String>,
    pub origin: DiscoveryOrigin,
}

/// 本机 Codex CLI 认证文件路径。
pub fn cli_auth_path(home: &Path) -> PathBuf {
    home.join(".codex").join("auth.json")
}

/// CC Switch Codex 账号库路径。
pub fn ccswitch_accounts_path(home: &Path) -> PathBuf {
    home.join(".cc-switch").join("codex_oauth_auth.json")
}

/// 两个发现来源当前是否存在 (设置页按钮显隐)。
pub fn discovery_sources(home: &Path) -> (bool, bool) {
    (
        cli_auth_path(home).is_file(),
        ccswitch_accounts_path(home).is_file(),
    )
}

fn non_empty(value: Option<&Value>) -> Option<String> {
    let text = value.and_then(Value::as_str)?.trim();
    (!text.is_empty()).then(|| text.to_owned())
}

/// 解析 Codex CLI `auth.json`: 取 `tokens.account_id`, 邮箱回落 `tokens.email` → 顶层 `email`。
/// 缺 `account_id` 或结构非法时 `Err` (fail-closed, 不产生记录)。
pub fn parse_cli_auth_json(json_text: &str) -> Result<DiscoveredAccount, ()> {
    let value: Value = serde_json::from_str(json_text).map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    let tokens = object.get("tokens").and_then(Value::as_object).ok_or(())?;
    let account_id = non_empty(tokens.get("account_id")).ok_or(())?;
    let email = non_empty(tokens.get("email")).or_else(|| non_empty(object.get("email")));
    Ok(DiscoveredAccount {
        account_id,
        email,
        origin: DiscoveryOrigin::CliAuth,
    })
}

/// 解析 CC Switch `codex_oauth_auth.json`: 取 `accounts.*` 的 `email`, 键即账号 ID。
/// 缺 `accounts` 对象或结构非法时 `Err` (fail-closed, 不静默伪装成空结果)。
pub fn parse_ccswitch_accounts_json(json_text: &str) -> Result<Vec<DiscoveredAccount>, ()> {
    let value: Value = serde_json::from_str(json_text).map_err(|_| ())?;
    let object = value.as_object().ok_or(())?;
    let accounts = object
        .get("accounts")
        .and_then(Value::as_object)
        .ok_or(())?;
    let mut discovered: Vec<DiscoveredAccount> = accounts
        .iter()
        .map(|(account_id, entry)| DiscoveredAccount {
            account_id: account_id.trim().to_owned(),
            email: entry
                .as_object()
                .and_then(|entry| non_empty(entry.get("email"))),
            origin: DiscoveryOrigin::CCSwitch,
        })
        .filter(|account| !account.account_id.is_empty())
        .collect();
    discovered.sort_by(|a, b| a.account_id.cmp(&b.account_id));
    Ok(discovered)
}

/// 只读发现: 文件存在才解析; 文件缺失跳过该来源; 读取或解析失败返回可诊断错误。
pub fn discover_from_files(home: &Path) -> Result<Vec<DiscoveredAccount>, String> {
    let mut discovered = Vec::new();
    let cli = cli_auth_path(home);
    if cli.is_file() {
        let text =
            std::fs::read_to_string(&cli).map_err(|_| "Codex CLI 认证文件不可读".to_owned())?;
        discovered
            .push(parse_cli_auth_json(&text).map_err(|_| "Codex CLI 认证文件解析失败".to_owned())?);
    }
    let ccswitch = ccswitch_accounts_path(home);
    if ccswitch.is_file() {
        let text = std::fs::read_to_string(&ccswitch)
            .map_err(|_| "CC Switch Codex 账号库不可读".to_owned())?;
        discovered.extend(
            parse_ccswitch_accounts_json(&text)
                .map_err(|_| "CC Switch Codex 账号库解析失败".to_owned())?,
        );
    }
    Ok(discovered)
}

/// metadata-only 记录载荷: 只有 `display_name` / 可选 `email` / `authorization_state`。
/// 不含任何令牌, 采集端会因 `reauthRequired` 直接跳过该账号。
pub fn metadata_payload(account: &DiscoveredAccount) -> Value {
    let mut record = serde_json::Map::new();
    record.insert("display_name".to_owned(), json!(account.account_id));
    if let Some(email) = account.email.as_deref() {
        record.insert("email".to_owned(), json!(email));
    }
    record.insert("authorization_state".to_owned(), json!("reauthRequired"));
    Value::Object(record)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_auth_json_reads_account_id_and_email_fallbacks() {
        let account =
            parse_cli_auth_json(r#"{"tokens":{"account_id":"acct-1","email":"a@b.c"}}"#).unwrap();
        assert_eq!(account.account_id, "acct-1");
        assert_eq!(account.email.as_deref(), Some("a@b.c"));
        assert_eq!(account.origin, DiscoveryOrigin::CliAuth);
        // 邮箱回落顶层
        let top =
            parse_cli_auth_json(r#"{"tokens":{"account_id":"acct-2"},"email":"top@b.c"}"#).unwrap();
        assert_eq!(top.email.as_deref(), Some("top@b.c"));
        // 缺 account_id fail-closed
        assert!(parse_cli_auth_json(r#"{"tokens":{"email":"a@b.c"}}"#).is_err());
        // 缺 tokens / 非法 JSON fail-closed
        assert!(parse_cli_auth_json(r#"{"email":"a@b.c"}"#).is_err());
        assert!(parse_cli_auth_json("not json").is_err());
    }

    #[test]
    fn ccswitch_accounts_json_lists_sorted_emails() {
        let accounts = parse_ccswitch_accounts_json(
            r#"{"accounts":{"b":{"email":"b@x.c"},"a":{"email":"a@x.c"},"c":{}}}"#,
        )
        .unwrap();
        assert_eq!(
            accounts
                .iter()
                .map(|a| a.account_id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "b", "c"]
        );
        assert_eq!(accounts[0].email.as_deref(), Some("a@x.c"));
        assert_eq!(accounts[2].email, None);
        assert!(accounts
            .iter()
            .all(|a| a.origin == DiscoveryOrigin::CCSwitch));
        // 缺 accounts 对象 fail-closed
        assert!(parse_ccswitch_accounts_json(r#"{"other":{}}"#).is_err());
        assert!(parse_ccswitch_accounts_json("[]").is_err());
    }

    #[test]
    fn metadata_payload_never_carries_tokens_and_marks_reauth() {
        let account = DiscoveredAccount {
            account_id: "acct-1".to_owned(),
            email: Some("a@b.c".to_owned()),
            origin: DiscoveryOrigin::CliAuth,
        };
        let payload = metadata_payload(&account);
        assert_eq!(payload["display_name"], json!("acct-1"));
        assert_eq!(payload["email"], json!("a@b.c"));
        assert_eq!(payload["authorization_state"], json!("reauthRequired"));
        for key in ["access_token", "refresh_token", "id_token"] {
            assert!(payload.get(key).is_none(), "{key} 不得出现在发现记录中");
        }
    }

    #[test]
    fn discover_from_files_skips_missing_sources() {
        let root = std::env::temp_dir().join(format!("bruce-c084-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(root.join(".codex"));
        std::fs::write(
            root.join(".codex").join("auth.json"),
            r#"{"tokens":{"account_id":"cli-1"}}"#,
        )
        .unwrap();
        let discovered = discover_from_files(&root).unwrap();
        assert_eq!(discovered.len(), 1);
        assert_eq!(discovered[0].account_id, "cli-1");
        assert_eq!(discovery_sources(&root), (true, false));
        let _ = std::fs::remove_dir_all(&root);
    }
}
