//! CC Switch 火山引擎凭据只读导入 (C083)。
//!
//! 对齐 mac `CCSwitchVolcengineImporter`: 只读打开 CC Switch 的 SQLite 库, 执行
//! `SELECT meta FROM providers WHERE name='火山Codingplan' LIMIT 1`, 取
//! `meta.usage_script.accessKeyId` / `secretAccessKey` (缺失时回落顶层同名键),
//! SK 做最多 2 次 base64 解码。
//!
//! 红线 (设计规则 §4.3): **全程只读** —— 连接以 `SQLITE_OPEN_READ_ONLY` 打开,
//! 不执行任何 DDL/写入, 不修改 CC Switch 的任何数据。

use base64::Engine;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// CC Switch 中火山引擎 Coding Plan 的 provider 名 (与 mac 同字面量)。
const PROVIDER_NAME: &str = "火山Codingplan";
/// 与 mac 一致的 8 秒查询超时预算 (rusqlite 无超时参数, 由只读单条 SELECT 天然满足)。
const _QUERY_BUDGET_SECS: u64 = 8;

/// 数据库候选路径: Windows 上 CC Switch 的落点未实测, 同时探测 Tauri 默认
/// appDataDir 与 mac 同款的用户目录布局 (设计规则 §4.3 的外部库只读约束)。
pub fn candidate_paths(home: &Path) -> Vec<PathBuf> {
    let mut paths = Vec::new();
    if let Some(app_data) = std::env::var_os("APPDATA").filter(|value| !value.is_empty()) {
        paths.push(
            PathBuf::from(app_data)
                .join("cc-switch")
                .join("cc-switch.db"),
        );
    }
    paths.push(home.join(".cc-switch").join("cc-switch.db"));
    paths
}

/// 找到第一个存在的 CC Switch 库; 都不存在返回 `None`。
pub fn database_path(home: &Path) -> Option<PathBuf> {
    candidate_paths(home)
        .into_iter()
        .find(|path| path.is_file())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VolcengineCredentials {
    pub access_key: String,
    pub secret_key: String,
}

/// 只读读取火山引擎 AK/SK。错误文案不含凭据值。
pub fn import_credentials(database: &Path) -> Result<VolcengineCredentials, String> {
    let connection = Connection::open_with_flags(
        database,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|_| "无法只读打开 CC Switch 数据库".to_owned())?;
    let meta: String = connection
        .query_row(
            "SELECT meta FROM providers WHERE name = ?1 LIMIT 1",
            [PROVIDER_NAME],
            |row| row.get(0),
        )
        .map_err(|error| match error {
            rusqlite::Error::QueryReturnedNoRows => {
                format!("CC Switch 中未找到「{PROVIDER_NAME}」配置")
            }
            _ => "CC Switch 数据库查询失败".to_owned(),
        })?;
    drop(connection);
    parse_meta(&meta)
}

/// 解析 provider meta JSON: `usage_script.{accessKeyId,secretAccessKey}` 优先,
/// 回落顶层同名键; SK 取最深一次成功的 base64 解码。
pub fn parse_meta(meta: &str) -> Result<VolcengineCredentials, String> {
    let document: Value =
        serde_json::from_str(meta.trim()).map_err(|_| "CC Switch meta 不是合法 JSON")?;
    let usage_script = document.get("usage_script");
    let read = |key: &str| -> Option<String> {
        usage_script
            .and_then(|script| script.get(key))
            .or_else(|| document.get(key))
            .and_then(Value::as_str)
            .map(|value| value.trim().to_owned())
            .filter(|value| !value.is_empty())
    };
    let access_key = read("accessKeyId").ok_or("CC Switch meta 缺少 accessKeyId")?;
    let secret_key = read("secretAccessKey").ok_or("CC Switch meta 缺少 secretAccessKey")?;
    Ok(VolcengineCredentials {
        access_key,
        secret_key: fully_decoded(&secret_key),
    })
}

/// SK 解码候选 `[raw, dec1?, dec2?]`: 解码失败 (非 base64 或非 UTF-8) 即停止。
pub fn decode_candidates(raw: &str) -> Vec<String> {
    let mut candidates = vec![raw.to_owned()];
    let mut current = raw.to_owned();
    for _ in 0..2 {
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(current.trim())
            .ok()
            .and_then(|bytes| String::from_utf8(bytes).ok())
            .filter(|value| !value.is_empty());
        match decoded {
            Some(value) => {
                candidates.push(value.clone());
                current = value;
            }
            None => break,
        }
    }
    candidates
}

/// 取最深的成功解码候选 (与 mac `VolcengineSecretDecoder.fullyDecoded` 同语义)。
pub fn fully_decoded(raw: &str) -> String {
    decode_candidates(raw)
        .pop()
        .unwrap_or_else(|| raw.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use std::fs;

    fn temp_root() -> PathBuf {
        // 并行测试同进程内可能取到同一时间戳 (macOS 时钟仅微秒精度), 追加进程内序号保证唯一,
        // 否则两条用例共用同一库文件, 后建表的一方报 "table providers already exists"。
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "bruce-ccswitch-{}-{}-{}",
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

    /// 造一份最小 CC Switch 库: providers(name, meta)。
    fn write_database(root: &Path, meta: &str) -> PathBuf {
        let path = root.join("cc-switch.db");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch("CREATE TABLE providers (name TEXT PRIMARY KEY, meta TEXT);")
            .unwrap();
        connection
            .execute(
                "INSERT INTO providers (name, meta) VALUES (?1, ?2)",
                [PROVIDER_NAME, meta],
            )
            .unwrap();
        drop(connection);
        path
    }

    #[test]
    fn import_reads_ak_sk_from_usage_script() {
        let root = temp_root();
        let path = write_database(
            &root,
            &format!(
                r#"{{"usage_script":{{"accessKeyId":"AKfixture","secretAccessKey":"{}"}}}}"#,
                STANDARD.encode("SKfixture")
            ),
        );
        let credentials = import_credentials(&path).unwrap();
        assert_eq!(credentials.access_key, "AKfixture");
        assert_eq!(
            credentials.secret_key, "SKfixture",
            "SK 取 base64 解码后的真实值"
        );
    }

    #[test]
    fn import_falls_back_to_top_level_keys() {
        let root = temp_root();
        let path = write_database(
            &root,
            r#"{"accessKeyId":"AKtop","secretAccessKey":"SKplain"}"#,
        );
        let credentials = import_credentials(&path).unwrap();
        assert_eq!(credentials.access_key, "AKtop");
        assert_eq!(credentials.secret_key, "SKplain", "非 base64 时保留原值");
    }

    #[test]
    fn import_reports_missing_row_and_missing_fields() {
        let root = temp_root();
        let path = write_database(&root, r#"{"usage_script":{"accessKeyId":"AKonly"}}"#);
        assert!(import_credentials(&path)
            .unwrap_err()
            .contains("secretAccessKey"));
        let empty = write_database(&temp_root(), r#"{"usage_script":{}}"#);
        assert!(import_credentials(&empty).is_err());
    }

    #[test]
    fn missing_database_is_not_found() {
        let root = temp_root();
        assert!(database_path(&root).is_none());
    }

    #[test]
    fn candidates_stop_at_first_failed_decode() {
        assert_eq!(decode_candidates("SKplain"), vec!["SKplain".to_owned()]);
        let once = STANDARD.encode("SKreal");
        assert_eq!(fully_decoded(&once), "SKreal");
    }
}
