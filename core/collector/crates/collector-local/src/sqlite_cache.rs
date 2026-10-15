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

const SQLITE_CACHE_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct SqliteSignature {
    pub(crate) device: u64,
    pub(crate) inode: u64,
    pub(crate) size: u64,
    pub(crate) modified_ns: u64,
    pub(crate) wal_size: u64,
    pub(crate) wal_modified_ns: u64,
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
        })
    }
}

#[cfg(unix)]
fn device_and_inode(metadata: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (metadata.dev(), metadata.ino())
}

#[cfg(not(unix))]
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
        if cache_identity_matches(entry, config, &schema_fingerprint)
            && entry.signature == signature
        {
            if let Some(contribution) = entry.contribution.to_domain(&config.window) {
                stats.cache_hits = stats.cache_hits.saturating_add(1);
                return Ok(SourceScan {
                    found: entry.found,
                    contribution,
                    stats,
                    diagnostic: entry.diagnostic.clone(),
                });
            }
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
        }
        stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);

        if entry.append_safe
            && append_signature_is_safe(&entry.signature, &signature)
            && entry.cursor.rowid.is_some()
        {
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
                    let base = entry
                        .contribution
                        .to_domain(&config.window)
                        .unwrap_or_else(|| empty_contribution(&config.window));
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
    })
}

fn empty_contribution(window: &CollectionWindow) -> UsageContribution {
    collector_domain::UsageContributionBuilder::new(window.clone()).contribution()
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
        && (current.size > previous.size
            || current.wal_size > previous.wal_size
            || current.modified_ns > previous.modified_ns
            || current.wal_modified_ns > previous.wal_modified_ns)
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
