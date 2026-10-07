//! 订阅凭证本地存储 —— 对齐 mac 凭据安全基线 (设计 02: 原子落盘/最小权限)。
//!
//! Windows 落盘 `%APPDATA%\Bruce\credentials.json` (等价 mac 0600 语义);
//! 键集合受 bridge `ALLOWED_CREDENTIAL_FIELDS` 白名单约束, 未知键拒绝写入,
//! 读取时静默丢弃, 防止契约外数据进入采集链路。

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use collector_bridge::ALLOWED_CREDENTIAL_FIELDS;

/// 订阅 provider 凭证载荷: 字段名 → provider 专属 JSON 载荷
/// (如 "kimiQuotaAccounts" → 账号数组; 结构由采集端契约定义)。
pub type CredentialPayloads = BTreeMap<String, Value>;

use serde_json::Value;

/// `%APPDATA%\Bruce` 根目录 (mac 开发环境回落到 ~/Library/Application Support)。
pub fn app_data_root(home: &Path) -> PathBuf {
    app_data_root_with(home, std::env::var_os("APPDATA").as_deref())
}

/// 可注入 APPDATA 的版本 (测试用; 与 collector-local windows_cache_root 同模式)。
pub fn app_data_root_with(home: &Path, app_data: Option<&std::ffi::OsStr>) -> PathBuf {
    #[cfg(windows)]
    {
        if let Some(app_data) = app_data
            .map(PathBuf::from)
            .filter(|value| !value.as_os_str().is_empty())
        {
            return app_data.join("Bruce");
        }
        home.join("AppData").join("Roaming").join("Bruce")
    }
    #[cfg(not(windows))]
    {
        let _ = app_data;
        home.join("Library/Application Support/Bruce")
    }
}

/// 凭证合并语义 (明文凭证不回显前端): patch 带值覆盖、显式 None 删除、
/// 未提及保留; 白名单外键直接拒绝。
pub fn merge_credentials(
    existing: &CredentialPayloads,
    patch: &BTreeMap<String, Option<Value>>,
) -> Result<CredentialPayloads, String> {
    let mut merged = existing.clone();
    for (key, value) in patch {
        if !is_allowed_field(key) {
            return Err(format!("未知凭证字段: {key}"));
        }
        match value {
            Some(value) => {
                merged.insert(key.clone(), value.clone());
            }
            None => {
                merged.remove(key);
            }
        }
    }
    Ok(merged)
}

fn credentials_path(root: &Path) -> PathBuf {
    root.join("credentials.json")
}

fn is_allowed_field(key: &str) -> bool {
    ALLOWED_CREDENTIAL_FIELDS.contains(&key)
}

/// 从磁盘加载凭证; 文件缺失返回空表, 白名单外键静默丢弃, 损坏文件视为缺失
/// (与 mac AtomicJSONStore 的 corrupt 处理口径一致, 绝不因凭证问题阻塞本地采集)。
pub fn load_credentials(root: &Path) -> CredentialPayloads {
    let path = credentials_path(root);
    let Ok(raw) = fs::read_to_string(&path) else {
        return CredentialPayloads::new();
    };
    let Ok(Value::Object(map)) = serde_json::from_str::<Value>(&raw) else {
        eprintln!("credentials.json 无法解析, 视为未配置: {}", path.display());
        return CredentialPayloads::new();
    };
    map.into_iter()
        .filter(|(key, _)| is_allowed_field(key))
        .collect()
}

/// 原子写入: 临时文件 (create_new) → rename 替换, 崩溃安全;
/// 写入前全量校验白名单, 任一未知键即拒绝 (防手改文件引入契约外字段)。
pub fn save_credentials(root: &Path, payloads: &CredentialPayloads) -> Result<(), String> {
    for key in payloads.keys() {
        if !is_allowed_field(key) {
            return Err(format!("未知凭证字段: {key}"));
        }
    }
    let path = credentials_path(root);
    let parent = path
        .parent()
        .ok_or_else(|| "凭证路径缺少父目录".to_owned())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;

    let body = serde_json::to_vec_pretty(payloads).map_err(|error| error.to_string())?;
    let temporary = parent.join(format!(
        ".credentials-{}-{}.tmp",
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
        file.sync_all().map_err(|error| error.to_string())?;
    }
    // Windows: rename 前对临时文件收紧 ACL (仅当前用户), 失败不阻塞写入
    // (权限加固为尽力而为; 文件内容本身仍受白名单与原子替换保护)。
    #[cfg(windows)]
    restrict_permissions_windows(&temporary);
    fs::rename(&temporary, &path).map_err(|error| {
        let _ = fs::remove_file(&temporary);
        error.to_string()
    })?;
    Ok(())
}

#[cfg(windows)]
fn restrict_permissions_windows(path: &Path) {
    use std::os::windows::process::CommandExt;

    // icacls: 关闭继承, 仅保留当前用户完全控制; 静默失败 (尽力而为)。
    let _ = std::process::Command::new("icacls")
        .arg(path)
        .args(["/inheritance:r"])
        .args([
            "/grant:r",
            &format!("{}:F", std::env::var("USERNAME").unwrap_or_default()),
        ])
        .creation_flags(0x0800_0000) // CREATE_NO_WINDOW
        .status();
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_root() -> PathBuf {
        // 同名纳秒在并行测试线程下会碰撞 (见 tests/ 同款修复), 原子序号保证唯一。
        static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let root = std::env::temp_dir().join(format!(
            "bruce-win-credentials-test-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn missing_file_loads_empty_and_save_round_trips() {
        let root = temp_root();
        assert!(load_credentials(&root).is_empty());

        let mut payloads = CredentialPayloads::new();
        payloads.insert(
            "kimiQuotaAccounts".to_owned(),
            json!([{ "accountID": "a1", "apiKey": "sk-test" }]),
        );
        save_credentials(&root, &payloads).unwrap();
        let loaded = load_credentials(&root);
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded["kimiQuotaAccounts"], payloads["kimiQuotaAccounts"]);
    }

    #[test]
    fn unknown_field_is_rejected_on_save_and_dropped_on_load() {
        let root = temp_root();
        let mut payloads = CredentialPayloads::new();
        payloads.insert("notAProvider".to_owned(), json!({"x": 1}));
        assert!(save_credentials(&root, &payloads).is_err());

        // 白名单外键读取时被静默丢弃。
        let path = credentials_path(&root);
        fs::write(
            &path,
            r#"{"notAProvider":{"x":1},"deepseekQuotaAccounts":[]}"#,
        )
        .unwrap();
        let loaded = load_credentials(&root);
        assert_eq!(loaded.len(), 1);
        assert!(loaded.contains_key("deepseekQuotaAccounts"));
    }

    #[test]
    fn corrupt_file_is_treated_as_missing() {
        let root = temp_root();
        fs::write(credentials_path(&root), "{not json").unwrap();
        assert!(load_credentials(&root).is_empty());
    }
}
