//! App-owned credential storage. Secrets never cross the metadata IPC boundary.
//! Windows uses a protected DACL for the process token SID before secret writes.

mod lifecycle;
#[cfg(windows)]
mod windows_security;
pub use lifecycle::{collect_with_recovery, collect_with_recovery_using, CodexRefreshError};

use collector_bridge::ALLOWED_CREDENTIAL_FIELDS;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

pub type CredentialPayloads = BTreeMap<String, Value>;
static STORE_LOCK: Mutex<()> = Mutex::new(());
const MAX_CREDENTIAL_BYTES: u64 = 4 * 1024 * 1024;

pub fn app_data_root(home: &Path) -> PathBuf {
    app_data_root_with(home, std::env::var_os("APPDATA").as_deref())
}
pub fn app_data_root_with(home: &Path, app_data: Option<&std::ffi::OsStr>) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(value) = app_data.filter(|value| !value.to_string_lossy().trim().is_empty()) {
            return value
                .to_str()
                .map(|s| PathBuf::from(s.trim()))
                .unwrap_or_else(|| PathBuf::from(value))
                .join("Bruce");
        }
        home.join("AppData").join("Roaming").join("Bruce")
    }
    #[cfg(not(windows))]
    {
        let _ = app_data;
        home.join("Library/Application Support/Bruce-Windows-Dev")
    }
}
fn credentials_path(root: &Path) -> PathBuf {
    root.join("credentials.json")
}
fn is_allowed_field(key: &str) -> bool {
    ALLOWED_CREDENTIAL_FIELDS.contains(&key)
}
fn valid_id(id: &str) -> bool {
    !id.trim().is_empty() && id.len() <= 256 && !id.chars().any(char::is_control)
}
fn nonempty_string(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|s| !s.trim().is_empty() && s.len() <= 32_768)
}
/// Validate the collector account-map contract, including required provider keys.
/// Error messages never interpolate credential values or arbitrary input keys.
pub fn validate_credential_payload(field: &str, payload: &Value) -> Result<(), String> {
    if !is_allowed_field(field) {
        return Err("未知凭证字段".to_owned());
    }
    let object = payload.as_object().ok_or("凭证必须是 JSON 对象")?;
    if object.len() > 64 {
        return Err("凭证账号数量超过上限".to_owned());
    }
    if field == "providerEnv" {
        return if object.values().all(Value::is_string) {
            Ok(())
        } else {
            Err("Provider 环境值必须为字符串".to_owned())
        };
    }
    if matches!(field, "providerMeta" | "claudeOAuth" | "grokOAuth") {
        return Ok(());
    }
    for (id, account) in object {
        if !valid_id(id) {
            return Err("凭证账号 ID 无效".to_owned());
        }
        let account = account.as_object().ok_or("凭证账号必须是 JSON 对象")?;
        let (allowed, required): (&[&str], &[&str]) = match field {
            "kimiQuotaAccounts" | "deepseekQuotaAccounts" => {
                (&["display_name", "api_key"], &["api_key"])
            }
            "zhipuQuotaAccounts" => (
                &["display_name", "api_key", "base_url"],
                &["api_key", "base_url"],
            ),
            "volcengineQuotaAccounts" => (
                &["display_name", "accessKeyId", "secretAccessKey"],
                &["accessKeyId", "secretAccessKey"],
            ),
            "stepfunQuotaAccounts" => (&["display_name", "token", "site", "is_global"], &["token"]),
            "codexQuotaAccounts" => (
                &[
                    "display_name",
                    "access_token",
                    "refresh_token",
                    "id_token",
                    "expiry",
                    "authorization_state",
                ],
                &["display_name", "access_token"],
            ),
            "claudeQuotaAccounts" | "grokQuotaAccounts" | "opencodeGoQuotaAccounts" => {
                (&["display_name", "oauth"], &[])
            }
            _ => return Err("凭证字段不受支持".to_owned()),
        };
        if account.keys().any(|key| !allowed.contains(&key.as_str()))
            || required
                .iter()
                .any(|key| !nonempty_string(account.get(*key)))
            || account.get("display_name").is_some_and(|value| {
                !nonempty_string(Some(value)) || value.as_str().is_some_and(|s| s.len() > 256)
            })
        {
            return Err("凭证账号字段无效或缺少必填值".to_owned());
        }
        if matches!(
            field,
            "claudeQuotaAccounts" | "grokQuotaAccounts" | "opencodeGoQuotaAccounts"
        ) && !account.get("oauth").is_some_and(Value::is_object)
        {
            return Err("OAuth 凭证必须是 JSON 对象".to_owned());
        }
        for key in ["refresh_token", "id_token", "expiry", "authorization_state"] {
            if account.get(key).is_some_and(|value| !value.is_string()) {
                return Err("令牌字段必须为字符串".to_owned());
            }
        }
        if account
            .get("site")
            .is_some_and(|value| !matches!(value.as_str(), Some("domestic" | "global")))
            || account
                .get("is_global")
                .is_some_and(|value| !value.is_boolean())
        {
            return Err("StepFun 站点字段无效".to_owned());
        }
    }
    Ok(())
}
pub fn merge_credentials(
    existing: &CredentialPayloads,
    patch: &BTreeMap<String, Option<Value>>,
) -> Result<CredentialPayloads, String> {
    let mut merged = existing.clone();
    for (key, value) in patch {
        if !is_allowed_field(key) {
            return Err("未知凭证字段".to_owned());
        }
        match value {
            Some(value) => {
                validate_credential_payload(key, value)?;
                merged.insert(key.clone(), value.clone());
            }
            None => {
                merged.remove(key);
            }
        }
    }
    Ok(merged)
}
pub fn load_credentials(root: &Path) -> CredentialPayloads {
    let path = credentials_path(root);
    if reject_link(&path).is_err() {
        return CredentialPayloads::new();
    }
    if !fs::metadata(&path).is_ok_and(|m| m.is_file() && m.len() <= MAX_CREDENTIAL_BYTES) {
        return CredentialPayloads::new();
    }
    let Ok(raw) = fs::read(&path) else {
        return CredentialPayloads::new();
    };
    let Ok(Value::Object(map)) = serde_json::from_slice::<Value>(&raw) else {
        return CredentialPayloads::new();
    };
    map.into_iter()
        .filter(|(key, value)| validate_credential_payload(key, value).is_ok())
        .collect()
}
pub fn save_credentials(root: &Path, payloads: &CredentialPayloads) -> Result<(), String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    save_unlocked(root, payloads)
}
/// UI mutation and token write-back read the latest file inside the same lock.
pub fn save_credentials_patch(
    root: &Path,
    patch: &BTreeMap<String, Option<Value>>,
) -> Result<(), String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let merged = merge_credentials(&load_credentials(root), patch)?;
    save_unlocked(root, &merged)
}
pub fn save_credential_account(
    root: &Path,
    field: &str,
    account_id: &str,
    payload: &Value,
) -> Result<(), String> {
    if !field.ends_with("QuotaAccounts") || !is_allowed_field(field) || !valid_id(account_id) {
        return Err("凭证账号目标无效".to_owned());
    }
    let mut payload = payload
        .as_object()
        .cloned()
        .ok_or("凭证账号必须是 JSON 对象")?;
    payload
        .entry("display_name")
        .or_insert_with(|| json!(account_id));
    validate_credential_payload(field, &json!({account_id: payload}))?;
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let mut latest = load_credentials(root);
    latest
        .entry(field.to_owned())
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("凭证账号映射损坏")?
        .insert(account_id.to_owned(), json!(payload));
    save_unlocked(root, &latest)
}
pub fn remove_credential_account(root: &Path, field: &str, account_id: &str) -> Result<(), String> {
    if !field.ends_with("QuotaAccounts") || !is_allowed_field(field) || !valid_id(account_id) {
        return Err("凭证账号目标无效".to_owned());
    }
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let mut latest = load_credentials(root);
    if let Some(accounts) = latest.get_mut(field).and_then(Value::as_object_mut) {
        accounts.remove(account_id);
        if accounts.is_empty() {
            latest.remove(field);
        }
    }
    save_unlocked(root, &latest)
}
/// Only these explicit metadata fields are allowed over IPC.
pub fn credential_accounts(root: &Path) -> Vec<Value> {
    let mut result = Vec::new();
    for (field, payload) in load_credentials(root) {
        if !field.ends_with("QuotaAccounts") {
            continue;
        }
        if let Some(accounts) = payload.as_object() {
            for (id, value) in accounts {
                result.push(json!({"field":field,"accountId":id,"displayName":value.get("display_name").and_then(Value::as_str).unwrap_or(id),"authorizationState":value.get("authorization_state").and_then(Value::as_str)}));
            }
        }
    }
    result
}
/// Explicit pasted CLI auth.json import; never opens or changes external files.
pub fn import_codex_auth(root: &Path, document: &Value) -> Result<(), String> {
    let tokens = document
        .get("tokens")
        .and_then(Value::as_object)
        .ok_or("Codex auth.json 缺少 tokens 对象")?;
    let id = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .filter(|id| valid_id(id))
        .ok_or("Codex auth.json 缺少有效账号 ID")?;
    let mut account = serde_json::Map::new();
    account.insert("display_name".to_owned(), json!(id));
    for key in ["access_token", "refresh_token", "id_token"] {
        if let Some(value) = tokens.get(key).filter(|value| nonempty_string(Some(value))) {
            account.insert(key.to_owned(), value.clone());
        }
    }
    save_credential_account(root, "codexQuotaAccounts", id, &Value::Object(account))
}
fn save_unlocked(root: &Path, payloads: &CredentialPayloads) -> Result<(), String> {
    for (field, payload) in payloads {
        validate_credential_payload(field, payload)?;
    }
    let body = serde_json::to_vec_pretty(payloads).map_err(|_| "凭证编码失败")?;
    if body.len() as u64 > MAX_CREDENTIAL_BYTES {
        return Err("凭证文件超过大小上限".to_owned());
    }
    if load_credentials(root).get("deepseekQuotaAccounts") != payloads.get("deepseekQuotaAccounts")
    {
        atomic_private_write(
            &root.join("deepseek-tracking-id"),
            uuid::Uuid::new_v4().to_string().as_bytes(),
        )?;
    }
    write_with_permissions(root, &body, restrict_permissions)
}
fn reject_link(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("凭证路径不得为链接或重解析点".to_owned());
                }
            }
            if metadata.file_type().is_symlink() {
                return Err("凭证路径不得为链接".to_owned());
            }
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(_) => Err("无法检查凭证路径".to_owned()),
    }
}
fn restrict_permissions(path: &Path, directory: bool) -> Result<(), String> {
    #[cfg(windows)]
    {
        windows_security::restrict(path, directory)
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
        )
        .map_err(|_| "无法设置凭证专属权限".to_owned())
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (path, directory);
        Err("不支持此平台的凭证权限保证".to_owned())
    }
}
/// A failed parent or file ACL prevents publication. File ACL is installed while
/// the new file is still empty; the old credential file remains untouched.
fn write_with_permissions(
    root: &Path,
    body: &[u8],
    mut secure: impl FnMut(&Path, bool) -> Result<(), String>,
) -> Result<(), String> {
    write_path_with_permissions(&credentials_path(root), body, &mut secure)
}

/// Reused by nonsecret snapshots/ledger to retain ACL and atomic-replace semantics on Windows.
pub(crate) fn atomic_private_write(path: &Path, body: &[u8]) -> Result<(), String> {
    write_path_with_permissions(path, body, restrict_permissions)
}

pub(crate) fn deepseek_tracking_id(root: &Path) -> Result<String, String> {
    let _guard = STORE_LOCK.lock().map_err(|_| "凭证存储事务不可用")?;
    let path = root.join("deepseek-tracking-id");
    reject_link(&path)?;
    if let Ok(id) = fs::read_to_string(&path) {
        if uuid::Uuid::parse_str(id.trim()).is_ok() {
            return Ok(id.trim().to_owned());
        }
    }
    let id = uuid::Uuid::new_v4().to_string();
    atomic_private_write(&path, id.as_bytes())?;
    Ok(id)
}

fn write_path_with_permissions(
    path: &Path,
    body: &[u8],
    mut secure: impl FnMut(&Path, bool) -> Result<(), String>,
) -> Result<(), String> {
    let root = path.parent().ok_or("存储路径无效")?;
    reject_link(root)?;
    reject_link(path)?;
    fs::create_dir_all(root).map_err(|_| "无法创建凭证目录")?;
    secure(root, true)?;
    let temporary = root.join(format!(".credentials-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|_| "无法创建凭证临时文件")?;
        secure(&temporary, false)?;
        file.write_all(body).map_err(|_| "凭证写入失败")?;
        file.sync_all().map_err(|_| "凭证同步失败")?;
        drop(file);
        #[cfg(windows)]
        windows_security::replace(&temporary, path)?;
        #[cfg(not(windows))]
        fs::rename(&temporary, path).map_err(|_| "凭证原子替换失败")?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    fn temp_root() -> PathBuf {
        std::env::temp_dir().join(format!("bruce-credentials-{}", uuid::Uuid::new_v4()))
    }
    #[test]
    fn parent_permission_failure_does_not_create_a_secret_file() {
        let root = temp_root();
        assert!(write_with_permissions(&root, b"fixture-secret", |_, _| Err(
            "acl denied".to_owned()
        ))
        .is_err());
        assert!(fs::read_dir(root).unwrap().next().is_none());
    }
    #[test]
    fn file_permission_failure_is_before_plaintext_and_preserves_original() {
        let root = temp_root();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        let original = fs::read(credentials_path(&root)).unwrap();
        let result = write_with_permissions(&root, b"fixture-secret", |path, directory| {
            if directory {
                Ok(())
            } else {
                assert!(fs::read(path).unwrap().is_empty());
                Err("acl denied".to_owned())
            }
        });
        assert!(result.is_err());
        assert_eq!(fs::read(credentials_path(&root)).unwrap(), original);
        assert_eq!(fs::read_dir(root).unwrap().count(), 1);
    }
    #[cfg(windows)]
    #[test]
    fn windows_parent_and_replaced_file_have_current_sid_only() {
        let root = temp_root();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        save_credentials(&root, &CredentialPayloads::new()).unwrap();
        windows_security::assert_current_sid_only(&root).unwrap();
        windows_security::assert_current_sid_only(&credentials_path(&root)).unwrap();
    }
}
