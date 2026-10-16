//! 跨运行台账缓存的文件实现 (C038)。
//!
//! 分层约定 (design/01): 缓存落在 collector-local (磁盘 + 缓存根), 使用方
//! (collector-provider) 只持有 `LedgerCache` 端口, 保持无状态。
//! 载荷为不透明 JSON 文本, 本模块不解析其结构。

use collector_runtime::LedgerCache;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

/// 台账缓存子目录 (挂在 collector 缓存根下, 与源级缓存同级)。
const LEDGER_SUBDIR: &str = "provider-ledger";

/// 文件落盘的台账缓存: `<cache_root>/provider-ledger/<key>.json`。
pub struct FileLedgerCache {
    root: PathBuf,
}

impl FileLedgerCache {
    pub fn new(cache_root: impl Into<PathBuf>) -> Self {
        Self {
            root: cache_root.into().join(LEDGER_SUBDIR),
        }
    }

    /// key -> 文件名: 只保留安全字符, 其余替换为 `_`, 避免路径穿越与非法名。
    fn path_for(&self, key: &str) -> PathBuf {
        let mut file = String::with_capacity(key.len());
        for character in key.chars() {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                file.push(character);
            } else {
                file.push('_');
            }
        }
        self.root.join(format!("{file}.json"))
    }
}

impl LedgerCache for FileLedgerCache {
    fn load(&self, key: &str) -> Option<String> {
        // 读取失败一律视为无缓存: 调用方会退回全量重扫并重建。
        fs::read_to_string(self.path_for(key)).ok()
    }

    fn store(&self, key: &str, payload: &str) {
        let path = self.path_for(key);
        let Some(parent) = path.parent() else { return };
        if fs::create_dir_all(parent).is_err() {
            return;
        }
        let temporary = parent.join(format!(
            ".{}.tmp-{}-{}",
            path.file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("ledger"),
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temporary)?;
            #[cfg(unix)]
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
            file.write_all(payload.as_bytes())?;
            // 缓存可重建: create-new 临时文件 + rename 提供整文件原子视图, 不做 fsync。
            drop(file);
            fs::rename(&temporary, &path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{FileLedgerCache, LedgerCache};

    fn temp_root(name: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "bruce-ledger-cache-{}-{}",
            name,
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        root
    }

    #[test]
    fn round_trips_payload_and_sanitizes_key() {
        let root = temp_root("roundtrip");
        let cache = FileLedgerCache::new(&root);
        assert_eq!(cache.load("cline-ledger/acct-1"), None);
        cache.store("cline-ledger/acct-1", "{\"version\":1}");
        assert_eq!(
            cache.load("cline-ledger/acct-1").as_deref(),
            Some("{\"version\":1}")
        );
        // 路径穿越/非法字符被消毒, 不会逃出缓存根。
        cache.store("../../etc/passwd", "x");
        assert!(!root.join("..").join("..").join("etc").exists());
        // 二次写入覆盖 (原子替换)。
        cache.store("cline-ledger/acct-1", "{\"version\":1,\"complete\":true}");
        assert!(cache
            .load("cline-ledger/acct-1")
            .is_some_and(|text| text.contains("complete")));
        let _ = std::fs::remove_dir_all(&root);
    }
}
