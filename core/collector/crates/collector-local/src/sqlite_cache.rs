//! Rebuildable, read-only SQLite cursor cache.
//!
//! The cache stores only a compact derived contribution and the file/cursor
//! identity needed to decide whether an incremental read is safe. The source
//! database is never opened for writing and no database payload is persisted
//! in this module.

use super::sources::{SourceScan, SourceScanError};
use super::{CompactContribution, ScanStats};
use collector_domain::{CollectionWindow, UsageContribution};
use collector_runtime::CancellationToken;
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const SQLITE_CACHE_SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct SqliteSignature {
    pub(crate) device: u64,
    pub(crate) inode: u64,
    pub(crate) size: u64,
    pub(crate) modified_ns: u64,
    pub(crate) wal_size: u64,
    pub(crate) wal_modified_ns: u64,
    /// SQLite 主库文件头的 change counter (偏移 24, 4 字节大端).
    ///
    /// 每次写事务递增; 被整体替换的库文件通常使其回退. 这是**不依赖文件
    /// 时间戳粒度**的内容变更信号 —— Windows 上文件时间戳粒度约 15ms,
    /// 同一刻度内的写入可能让 size/mtime 签名"看起来没变", 仅凭时间戳会把
    /// 替换误判为追加并返回陈旧用量 (CI: 2026-10-15 Windows 作业红).
    pub(crate) change_counter: u32,
}

impl SqliteSignature {
    fn from_path(path: &Path) -> io::Result<Self> {
        let metadata = fs::metadata(path)?;
        let (device, inode) = device_and_inode(&metadata);
        let wal_path = PathBuf::from(format!("{}-wal", path.to_string_lossy()));
        let wal = fs::metadata(wal_path).ok();
        Ok(Self {
            device,
            inode,
            size: metadata.len(),
            modified_ns: modified_ns(&metadata),
            wal_size: wal.as_ref().map_or(0, fs::Metadata::len),
            wal_modified_ns: wal.as_ref().map_or(0, modified_ns),
            change_counter: read_change_counter(path),
        })
    }
}

#[cfg(unix)]
fn device_and_inode(metadata: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(windows)]
fn device_and_inode(metadata: &fs::Metadata) -> (u64, u64) {
    use std::os::windows::fs::MetadataExt;
    // Windows 无 inode: 以创建时间充当文件身份 —— 被整体替换 (重新创建) 的库
    // 文件会获得新的创建时间, 而追加不影响创建时间, 与 change counter 共同
    // 识别「替换 vs 追加」, 避免替换被误判为追加而返回陈旧用量.
    (0, metadata.creation_time())
}

#[cfg(not(any(unix, windows)))]
fn device_and_inode(_metadata: &fs::Metadata) -> (u64, u64) {
    (0, 0)
}

fn modified_ns(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos() as u64)
        .unwrap_or(0)
}

/// 读取 SQLite 主库文件头的 change counter (偏移 24, 大端 u32).
/// 读取失败 (空文件/无权限/被截断) 一律返回 0, 由 size/mtime 兜底判定.
fn read_change_counter(path: &Path) -> u32 {
    use std::io::{Read, Seek, SeekFrom};
    let Ok(mut file) = fs::File::open(path) else {
        return 0;
    };
    if file.seek(SeekFrom::Start(24)).is_err() {
        return 0;
    }
    let mut buffer = [0u8; 4];
    if file.read_exact(&mut buffer).is_err() {
        return 0;
    }
    u32::from_be_bytes(buffer)
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct SqliteCursor {
    pub(crate) rowid: Option<i64>,
    pub(crate) timestamp_millis: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct SqliteCacheEntry {
    pub(crate) schema_version: u32,
    pub(crate) source_id: String,
    pub(crate) parser_version: u32,
    pub(crate) schema_fingerprint: String,
    pub(crate) signature: SqliteSignature,
    pub(crate) cursor: SqliteCursor,
    pub(crate) window_days: u32,
    pub(crate) timezone: String,
    pub(crate) today: String,
    pub(crate) found: bool,
    pub(crate) append_safe: bool,
    pub(crate) diagnostic: Option<String>,
    #[serde(default)]
    pub(crate) capped: bool,
    pub(crate) contribution: CompactContribution,
}

#[derive(Debug, Clone)]
pub(crate) struct SqliteCacheConfig {
    pub(crate) cache_root: PathBuf,
    pub(crate) source_id: String,
    pub(crate) parser_version: u32,
    pub(crate) window: CollectionWindow,
}

#[derive(Debug, Clone)]
pub(crate) struct SqliteReadResult {
    pub(crate) contribution: UsageContribution,
    pub(crate) cursor: SqliteCursor,
    pub(crate) found: bool,
    pub(crate) rows_read: u64,
    pub(crate) diagnostic: Option<String>,
    pub(crate) append_safe: bool,
    /// 行数截断 (C041): 计划内降级, 上游归为信息级诊断, 不触发 Partial。
    pub(crate) capped: bool,
}

pub(crate) trait SqliteIncrementalAdapter {
    fn source_id(&self) -> &'static str;

    fn schema_fingerprint(&self, connection: &Connection) -> Result<String, SourceScanError>;

    fn read_full(
        &self,
        connection: &Connection,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError>;

    fn read_since(
        &self,
        connection: &Connection,
        cursor: &SqliteCursor,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError>;

    fn merge_delta(
        &self,
        base: &UsageContribution,
        delta: &UsageContribution,
        window: &CollectionWindow,
    ) -> UsageContribution;
}

pub(crate) fn scan_sqlite_cached<A: SqliteIncrementalAdapter>(
    path: &Path,
    config: &SqliteCacheConfig,
    adapter: &A,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    cancellation.check()?;
    if config.source_id != adapter.source_id() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "sqlite cache source identity mismatch",
        )
        .into());
    }
    if !path.is_file() {
        return Ok(SourceScan::empty(&config.window));
    }

    let mut stats = ScanStats {
        files_visited: 1,
        files_scanned: 1,
        ..ScanStats::default()
    };
    let signature = match SqliteSignature::from_path(path) {
        Ok(signature) => signature,
        Err(_) => {
            return Ok(diagnostic_scan(
                &config.window,
                config.source_id.as_str(),
                "暂不可读",
            ))
        }
    };
    let connection = match Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    ) {
        Ok(connection) => connection,
        Err(_) => {
            return Ok(diagnostic_scan(
                &config.window,
                config.source_id.as_str(),
                "暂不可读",
            ))
        }
    };
    let schema_fingerprint = match adapter.schema_fingerprint(&connection) {
        Ok(fingerprint) => fingerprint,
        Err(SourceScanError::Runtime(error)) => return Err(error.into()),
        Err(SourceScanError::Io(_)) => {
            return Ok(diagnostic_scan(
                &config.window,
                config.source_id.as_str(),
                "schema 不兼容",
            ))
        }
    };
    let cache_path = cache_path(path, config);
    let cached = match load_cache(&cache_path) {
        CacheLoad::Entry(entry) => Some(entry),
        CacheLoad::Missing => None,
        CacheLoad::Corrupt => {
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
            None
        }
    };

    if let Some(entry) = cached.as_ref() {
        let identity_matches = cache_identity_matches(entry, config, &schema_fingerprint);
        if identity_matches && entry.signature == signature {
            if let Some(contribution) = entry.contribution.to_domain(&config.window) {
                stats.cache_hits = stats.cache_hits.saturating_add(1);
                return Ok(SourceScan {
                    found: entry.found,
                    contribution,
                    stats,
                    diagnostic: entry.diagnostic.clone(),
                    capped: entry.capped,
                });
            }
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
        }
        stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);

        // C040 防线一: 增量追加以缓存身份全匹配为前置 (窗口长度/时区/今日)。
        // 身份错位 (窗口长度或时区配置变更) 时, 旧条目的 days 索引在新窗口
        // day_list 下会整体平移到错误的日期 (短条目读长窗口时恰好全部在界内,
        // 解码"成功"但日期是错的), 或越界导致解码失败 —— 两种形态都严禁跨窗口
        // 增量合并, 一律整体回退全量重建。
        // C040 防线二: 同身份下 base 解码失败 (条目结构损坏) 同样回退全量重建,
        // 严禁以空 base 落地 —— 该路径曾把历史清空而游标照常前推 (无自愈)。
        let can_append = identity_matches
            && entry.append_safe
            && append_signature_is_safe(&entry.signature, &signature)
            && entry.cursor.rowid.is_some();
        'append: {
            if !can_append {
                break 'append;
            }
            let base = match entry.contribution.to_domain(&config.window) {
                Some(base) => base,
                None => {
                    stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
                    break 'append;
                }
            };
            cancellation.check()?;
            match adapter.read_since(
                &connection,
                &entry.cursor,
                &config.window,
                cancellation,
                &mut stats,
            ) {
                Ok(delta) if delta.diagnostic.is_none() && delta.append_safe => {
                    stats.sqlite_rows_read = stats.sqlite_rows_read.max(delta.rows_read);
                    cancellation.check()?;
                    let contribution =
                        adapter.merge_delta(&base, &delta.contribution, &config.window);
                    let cursor = merge_cursor(&entry.cursor, &delta.cursor);
                    let found = entry.found || delta.found;
                    let cache_entry = make_entry(
                        config,
                        &signature,
                        &schema_fingerprint,
                        &cursor,
                        found,
                        delta.diagnostic.clone(),
                        delta.append_safe,
                        delta.capped,
                        &contribution,
                    );
                    match write_cache(&cache_path, &cache_entry, cancellation) {
                        Ok(()) => {}
                        Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                        Err(SourceScanError::Io(_)) => {
                            stats.io_errors = stats.io_errors.saturating_add(1)
                        }
                    }
                    stats.cache_appends = stats.cache_appends.saturating_add(1);
                    cancellation.check()?;
                    return Ok(SourceScan {
                        found,
                        contribution,
                        stats,
                        diagnostic: delta.diagnostic,
                        capped: delta.capped,
                    });
                }
                Ok(_) | Err(SourceScanError::Io(_)) => {
                    stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
                }
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            }
        }
    }

    cancellation.check()?;
    let result = match adapter.read_full(&connection, &config.window, cancellation, &mut stats) {
        Ok(result) => result,
        Err(SourceScanError::Runtime(error)) => return Err(error.into()),
        Err(SourceScanError::Io(_)) => {
            return Ok(diagnostic_scan(
                &config.window,
                config.source_id.as_str(),
                "查询失败",
            ))
        }
    };
    cancellation.check()?;
    stats.sqlite_rows_read = stats.sqlite_rows_read.max(result.rows_read);
    let contribution = result.contribution;
    let compact =
        CompactContribution::from_domain(&contribution, &config.window).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "sqlite contribution window mismatch",
            )
        })?;
    let entry = SqliteCacheEntry {
        schema_version: SQLITE_CACHE_SCHEMA_VERSION,
        source_id: config.source_id.clone(),
        parser_version: config.parser_version,
        schema_fingerprint,
        signature,
        cursor: result.cursor,
        window_days: config.window.days,
        timezone: config.window.timezone_name.clone(),
        today: config.window.today.clone(),
        found: result.found,
        append_safe: result.append_safe,
        diagnostic: result.diagnostic.clone(),
        capped: result.capped,
        contribution: compact,
    };
    match write_cache(&cache_path, &entry, cancellation) {
        Ok(()) => {}
        Err(SourceScanError::Runtime(error)) => return Err(error.into()),
        Err(SourceScanError::Io(_)) => stats.io_errors = stats.io_errors.saturating_add(1),
    }
    cancellation.check()?;
    stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
    Ok(SourceScan {
        found: result.found,
        contribution,
        stats,
        diagnostic: result.diagnostic,
        capped: result.capped,
    })
}

fn diagnostic_scan(window: &CollectionWindow, source_id: &str, detail: &str) -> SourceScan {
    let mut result = SourceScan::empty(window);
    result.diagnostic = Some(format!("本机 {source_id} 数据库{detail}"));
    result
}

fn cache_identity_matches(
    entry: &SqliteCacheEntry,
    config: &SqliteCacheConfig,
    schema_fingerprint: &str,
) -> bool {
    entry.schema_version == SQLITE_CACHE_SCHEMA_VERSION
        && entry.source_id == config.source_id
        && entry.parser_version == config.parser_version
        && entry.schema_fingerprint == schema_fingerprint
        && entry.window_days == config.window.days
        && entry.timezone == config.window.timezone_name
        && entry.today == config.window.today
}

fn append_signature_is_safe(previous: &SqliteSignature, current: &SqliteSignature) -> bool {
    previous.device == current.device
        && previous.inode == current.inode
        && current.size >= previous.size
        && current.wal_size >= previous.wal_size
        && current.modified_ns >= previous.modified_ns
        && current.wal_modified_ns >= previous.wal_modified_ns
        // 计数器回退 ⇒ 库文件被整体替换 (非追加): 必须回退全量重建,
        // 否则 read_since 会因 rowid 游标越过新库行而静默返回陈旧用量。
        && current.change_counter >= previous.change_counter
        && (current.size > previous.size
            || current.wal_size > previous.wal_size
            || current.modified_ns > previous.modified_ns
            || current.wal_modified_ns > previous.wal_modified_ns
            || current.change_counter != previous.change_counter)
}

fn merge_cursor(previous: &SqliteCursor, current: &SqliteCursor) -> SqliteCursor {
    SqliteCursor {
        rowid: match (previous.rowid, current.rowid) {
            (Some(left), Some(right)) => Some(left.max(right)),
            (left, right) => right.or(left),
        },
        timestamp_millis: match (previous.timestamp_millis, current.timestamp_millis) {
            (Some(left), Some(right)) => Some(left.max(right)),
            (left, right) => right.or(left),
        },
    }
}

#[allow(clippy::too_many_arguments)]
fn make_entry(
    config: &SqliteCacheConfig,
    signature: &SqliteSignature,
    schema_fingerprint: &str,
    cursor: &SqliteCursor,
    found: bool,
    diagnostic: Option<String>,
    append_safe: bool,
    capped: bool,
    contribution: &UsageContribution,
) -> SqliteCacheEntry {
    SqliteCacheEntry {
        schema_version: SQLITE_CACHE_SCHEMA_VERSION,
        source_id: config.source_id.clone(),
        parser_version: config.parser_version,
        schema_fingerprint: schema_fingerprint.to_owned(),
        signature: signature.clone(),
        cursor: cursor.clone(),
        window_days: config.window.days,
        timezone: config.window.timezone_name.clone(),
        today: config.window.today.clone(),
        found,
        append_safe,
        diagnostic,
        capped,
        contribution: CompactContribution::from_domain(contribution, &config.window)
            .expect("usage contribution must match its collection window"),
    }
}

fn cache_path(path: &Path, config: &SqliteCacheConfig) -> PathBuf {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-sqlite-cache-v1\0");
    hasher.update(config.source_id.as_bytes());
    hasher.update([0]);
    hasher.update(path.to_string_lossy().as_bytes());
    config
        .cache_root
        .join(format!("sqlite-{:x}.json", hasher.finalize()))
}

enum CacheLoad {
    Missing,
    Corrupt,
    Entry(Box<SqliteCacheEntry>),
}

fn load_cache(path: &Path) -> CacheLoad {
    let data = match fs::read(path) {
        Ok(data) => data,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return CacheLoad::Missing,
        Err(_) => return CacheLoad::Corrupt,
    };
    match serde_json::from_slice(&data) {
        Ok(entry) => CacheLoad::Entry(Box::new(entry)),
        Err(_) => CacheLoad::Corrupt,
    }
}

fn write_cache(
    path: &Path,
    entry: &SqliteCacheEntry,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    cancellation.check()?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "sqlite cache path has no parent",
        )
    })?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("sqlite-cache"),
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let result = (|| -> Result<(), SourceScanError> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(SourceScanError::Io)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))
                .map_err(SourceScanError::Io)?;
        }
        serde_json::to_writer(&mut file, entry).map_err(|error| {
            SourceScanError::Io(io::Error::new(io::ErrorKind::InvalidData, error))
        })?;
        file.write_all(b"\n").map_err(SourceScanError::Io)?;
        drop(file);
        cancellation.check()?;
        fs::rename(&temporary, path).map_err(SourceScanError::Io)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::{append_signature_is_safe, read_change_counter, SqliteSignature};
    use std::fs;
    use std::io::Write;
    use std::path::PathBuf;

    fn signature(size: u64, modified_ns: u64, change_counter: u32) -> SqliteSignature {
        // device/inode 恒取 (0, 0): 复刻 Windows 无 inode 身份的场景
        SqliteSignature {
            device: 0,
            inode: 0,
            size,
            modified_ns,
            wal_size: 0,
            wal_modified_ns: 0,
            change_counter,
        }
    }

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "bruce-sqlite-signature-{}-{name}",
            std::process::id()
        ))
    }

    /// 替换 (而非追加) 的库文件必须判为非追加: 否则 read_since 的 rowid 游标
    /// 会越过新库行, 静默返回陈旧用量 (2026-10-15 Windows CI 失败根因).
    #[test]
    fn replaced_database_is_not_append_safe_when_counter_regresses() {
        let previous = signature(1_000, 100, 3);
        // 体积更大、时间戳更新, 仅计数器回退 —— 必须判为替换
        let replaced = signature(2_000, 200, 1);
        assert!(
            !append_signature_is_safe(&previous, &replaced),
            "计数器回退必须判为非追加 (回退全量重建)"
        );
    }

    /// 真实追加: 计数器递增 → 允许走游标增量。
    #[test]
    fn appended_database_with_growing_counter_is_append_safe() {
        let previous = signature(1_000, 100, 3);
        assert!(append_signature_is_safe(
            &previous,
            &signature(2_000, 200, 4)
        ));
    }

    /// Windows 时间戳粒度粗: 同尺寸同时间戳的写入仅计数器变化, 也必须视为变更。
    #[test]
    fn same_stamp_write_is_detected_through_counter() {
        let previous = signature(1_000, 100, 3);
        assert!(
            append_signature_is_safe(&previous, &signature(1_000, 100, 4)),
            "计数器变化必须视为内容变更 (不依赖时间戳粒度)"
        );
    }

    /// 计数器读取: 从 SQLite 头偏移 24 读取大端 u32; 文件过短回退 0。
    #[test]
    fn change_counter_reads_header_offset() {
        let path = temp_path("counter");
        let mut header = vec![0u8; 28];
        header[24..28].copy_from_slice(&7u32.to_be_bytes());
        fs::write(&path, &header).unwrap();
        assert_eq!(read_change_counter(&path), 7);
        fs::remove_file(&path).ok();

        let short = temp_path("short");
        let mut file = fs::File::create(&short).unwrap();
        file.write_all(&[0u8; 8]).unwrap();
        drop(file);
        assert_eq!(read_change_counter(&short), 0, "过短文件必须回退 0");
        fs::remove_file(&short).ok();

        assert_eq!(
            read_change_counter(&temp_path("missing")),
            0,
            "缺失文件必须回退 0"
        );
    }
}
