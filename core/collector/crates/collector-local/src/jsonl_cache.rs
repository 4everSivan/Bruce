//! Rebuildable cache engine for local JSONL sources.
//!
//! Only derived observations and compact contributions cross the cache
//! boundary. Raw JSONL lines, credentials, and source paths are never stored.

use super::sources::{SourceScan, SourceScanError};
use super::{
    read_bounded_line, trim_line_end, CompactContribution, ScanStats, MAX_DIRECTORY_SCAN_DEPTH,
    MAX_JSONL_RECORD_BYTES, READ_BUFFER_BYTES,
};
use collector_domain::{CollectionWindow, UsageContribution};
use collector_runtime::CancellationToken;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const JSONL_CACHE_SCHEMA_VERSION: u32 = 1;
const FINGERPRINT_SEGMENT_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct JsonlFileSignature {
    pub(crate) device: u64,
    pub(crate) inode: u64,
    pub(crate) size: u64,
    pub(crate) modified_ns: u64,
}

impl JsonlFileSignature {
    fn from_metadata(metadata: &fs::Metadata) -> Self {
        let modified_ns = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_nanos() as u64)
            .unwrap_or(0);
        let (device, inode) = file_identity(metadata);
        Self {
            device,
            inode,
            size: metadata.len(),
            modified_ns,
        }
    }
}

fn file_identity(metadata: &fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (metadata.dev(), metadata.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        (0, 0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct CachedUsageObservation {
    pub(crate) dedupe_key: Option<String>,
    pub(crate) timestamp_millis: i64,
    pub(crate) model: Option<String>,
    pub(crate) input: u64,
    pub(crate) output: u64,
    pub(crate) cache_read: u64,
    pub(crate) cache_creation: u64,
    /// cache_creation 中按 1 小时 TTL 写入的部分 (C107); 旧缓存条目缺省为 0。
    #[serde(default)]
    pub(crate) cache_creation_1h: u64,
    pub(crate) project: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct CachedFilePayload {
    pub(crate) contribution: CompactContribution,
    pub(crate) observations: Vec<CachedUsageObservation>,
}

#[derive(Debug, Clone)]
pub(crate) struct JsonlCacheConfig {
    pub(crate) cache_root: PathBuf,
    pub(crate) source_id: String,
    pub(crate) parser_version: u32,
    pub(crate) aggregation_version: u32,
    pub(crate) window: CollectionWindow,
}

pub(crate) trait JsonlCacheAdapter {
    fn source_id(&self) -> &'static str;

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError>;

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload;

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError>;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct JsonlCacheWindow {
    days: u32,
    timezone: String,
    today: String,
}

impl JsonlCacheWindow {
    fn from_config(config: &JsonlCacheConfig) -> Self {
        Self {
            days: config.window.days,
            timezone: config.window.timezone_name.clone(),
            today: config.window.today.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct JsonlCacheEntry {
    schema_version: u32,
    source_id: String,
    source_path_digest: String,
    parser_version: u32,
    aggregation_version: u32,
    window: JsonlCacheWindow,
    file: JsonlFileSignature,
    safe_offset: u64,
    head_length: u64,
    prefix_tail_length: u64,
    head_fingerprint: String,
    prefix_tail_fingerprint: String,
    payload: CachedFilePayload,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct JsonlCacheManifest {
    schema_version: u32,
    source_id: String,
    source_root_digest: String,
    source_path_digests: std::collections::BTreeSet<String>,
}

enum CacheLoad {
    Missing,
    Corrupt,
    Entry(Box<JsonlCacheEntry>),
}

pub(crate) fn scan_cached_jsonl_tree<A: JsonlCacheAdapter>(
    root: &Path,
    config: &JsonlCacheConfig,
    adapter: &A,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    cancellation.check()?;
    if config.source_id != adapter.source_id() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "jsonl cache source identity mismatch",
        )
        .into());
    }
    if !root.exists() {
        return Ok(SourceScan::empty(&config.window));
    }
    if !root.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotADirectory,
            "jsonl source root is not a directory",
        )
        .into());
    }

    let mut state = TreeState {
        config,
        adapter,
        cancellation,
        stats: ScanStats::default(),
        seen: std::collections::BTreeSet::new(),
        payloads: Vec::new(),
        visited_dirs: std::collections::BTreeSet::new(),
    };
    visit_tree(root, &mut state, 0)?;
    cancellation.check()?;
    reconcile_deleted_cache(root, &mut state)?;
    cancellation.check()?;
    let (contribution, adapter_found, diagnostic) =
        adapter.aggregate(&state.payloads, &config.window)?;
    cancellation.check()?;
    if let Err(error) = write_manifest(root, &state) {
        record_cache_write_error(error, &mut state.stats)?;
    }
    cancellation.check()?;
    let found = state.stats.files_scanned > 0 || adapter_found;
    Ok(SourceScan {
        found,
        contribution,
        stats: state.stats,
        diagnostic,
        capped: false,
    })
}

struct TreeState<'a, A> {
    config: &'a JsonlCacheConfig,
    adapter: &'a A,
    cancellation: &'a CancellationToken,
    stats: ScanStats,
    seen: std::collections::BTreeSet<String>,
    payloads: Vec<CachedFilePayload>,
    /// C045: 已访问目录 canonical 路径集合, 与 `walk_jsonl_tree` 同款环防护。
    visited_dirs: std::collections::BTreeSet<PathBuf>,
}

/// 递归遍历会话目录树。
///
/// C045: 深度上限与已访问集合是硬性护栏 —— 会话目录可能包含 symlink 环
/// (如 a -> b -> a), 无防护时递归不会终止 (栈溢出/路径无限增长)。
/// 与 `sources.rs::walk_jsonl_tree` 使用同一套判定语义 (深度上限 + canonical 去重)。
fn visit_tree<A: JsonlCacheAdapter>(
    root: &Path,
    state: &mut TreeState<'_, A>,
    depth: usize,
) -> Result<(), SourceScanError> {
    state.cancellation.check()?;
    if depth > MAX_DIRECTORY_SCAN_DEPTH {
        return Ok(());
    }
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
            state.stats.io_errors = state.stats.io_errors.saturating_add(1);
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        state.cancellation.check()?;
        let Ok(entry) = entry else {
            state.stats.io_errors = state.stats.io_errors.saturating_add(1);
            continue;
        };
        let path = entry.path();
        let Ok(metadata) = entry.metadata() else {
            state.stats.io_errors = state.stats.io_errors.saturating_add(1);
            continue;
        };
        if metadata.is_dir() {
            let canonical = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
            if state.visited_dirs.insert(canonical) {
                visit_tree(&path, state, depth + 1)?;
            }
            continue;
        }
        if !metadata.is_file() || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
        {
            continue;
        }
        state.stats.files_visited = state.stats.files_visited.saturating_add(1);
        let modified = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_secs_f64())
            .unwrap_or(0.0);
        if modified < state.config.window.cutoff_ts {
            state.stats.files_skipped = state.stats.files_skipped.saturating_add(1);
            continue;
        }
        state.stats.files_scanned = state.stats.files_scanned.saturating_add(1);
        if let Some(payload) = process_file(&path, modified, state)? {
            state.payloads.push(payload);
        }
    }
    Ok(())
}

fn process_file<A: JsonlCacheAdapter>(
    path: &Path,
    modified: f64,
    state: &mut TreeState<'_, A>,
) -> Result<Option<CachedFilePayload>, SourceScanError> {
    state.cancellation.check()?;
    let source_path_digest = digest_with_source(state.config.source_id.as_str(), path);
    state.seen.insert(source_path_digest.clone());
    let cache_path = entry_path(&state.config.cache_root, &source_path_digest);
    let metadata = fs::metadata(path)?;
    let current_file = JsonlFileSignature::from_metadata(&metadata);
    let loaded = load_entry(&cache_path);
    if matches!(loaded, CacheLoad::Corrupt) {
        state.stats.cache_corruptions = state.stats.cache_corruptions.saturating_add(1);
    }
    if let CacheLoad::Entry(entry) = loaded {
        if cache_identity_matches(&entry, &source_path_digest, state.config)
            && entry.file == current_file
            && cache_payload_is_valid(&entry, &state.config.window)
        {
            state.stats.cache_hits = state.stats.cache_hits.saturating_add(1);
            return Ok(Some(entry.payload.clone()));
        }
        if cache_identity_matches(&entry, &source_path_digest, state.config)
            && cache_payload_is_valid(&entry, &state.config.window)
            && append_is_safe(path, &entry, &current_file, state.cancellation)?
        {
            let appended = match state.adapter.parse_file(
                path,
                modified,
                entry.safe_offset,
                &state.config.window,
                state.cancellation,
                &mut state.stats,
            ) {
                Ok(payload) => payload,
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    state.stats.io_errors = state.stats.io_errors.saturating_add(1);
                    return Ok(None);
                }
            };
            let merged = state.adapter.merge_append(
                &entry.payload,
                &appended,
                modified,
                &state.config.window,
            );
            if let Err(error) = cache_payload_entry(
                path,
                &metadata,
                state.config,
                source_path_digest.as_str(),
                merged.clone(),
                &cache_path,
                state.cancellation,
            ) {
                record_cache_write_error(error, &mut state.stats)?;
            }
            state.stats.cache_appends = state.stats.cache_appends.saturating_add(1);
            return Ok(Some(merged));
        }
        state.stats.cache_invalidations = state.stats.cache_invalidations.saturating_add(1);
    }

    let payload = match state.adapter.parse_file(
        path,
        modified,
        0,
        &state.config.window,
        state.cancellation,
        &mut state.stats,
    ) {
        Ok(payload) => payload,
        Err(SourceScanError::Runtime(error)) => return Err(error.into()),
        Err(SourceScanError::Io(_)) => {
            state.stats.io_errors = state.stats.io_errors.saturating_add(1);
            return Ok(None);
        }
    };
    if let Err(error) = cache_payload_entry(
        path,
        &metadata,
        state.config,
        source_path_digest.as_str(),
        payload.clone(),
        &cache_path,
        state.cancellation,
    ) {
        record_cache_write_error(error, &mut state.stats)?;
    }
    state.stats.cache_rebuilds = state.stats.cache_rebuilds.saturating_add(1);
    Ok(Some(payload))
}

fn cache_payload_is_valid(entry: &JsonlCacheEntry, window: &CollectionWindow) -> bool {
    entry.safe_offset <= entry.file.size
        && entry.head_length <= entry.file.size
        && entry.prefix_tail_length <= entry.file.size
        && entry.payload.contribution.to_domain(window).is_some()
}

fn cache_payload_entry(
    path: &Path,
    metadata: &fs::Metadata,
    config: &JsonlCacheConfig,
    source_path_digest: &str,
    payload: CachedFilePayload,
    cache_path: &Path,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    let entry = make_entry(
        path,
        metadata,
        config,
        source_path_digest,
        payload,
        cancellation,
    )?;
    write_entry(cache_path, &entry, cancellation)
}

fn record_cache_write_error(
    error: SourceScanError,
    stats: &mut ScanStats,
) -> Result<(), SourceScanError> {
    match error {
        SourceScanError::Io(_) => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            Ok(())
        }
        SourceScanError::Runtime(error) => Err(error.into()),
    }
}

fn cache_identity_matches(
    entry: &JsonlCacheEntry,
    source_path_digest: &str,
    config: &JsonlCacheConfig,
) -> bool {
    entry.schema_version == JSONL_CACHE_SCHEMA_VERSION
        && entry.source_id == config.source_id
        && entry.source_path_digest == source_path_digest
        && entry.parser_version == config.parser_version
        && entry.aggregation_version == config.aggregation_version
        && entry.window == JsonlCacheWindow::from_config(config)
}

fn append_is_safe(
    path: &Path,
    entry: &JsonlCacheEntry,
    current_file: &JsonlFileSignature,
    cancellation: &CancellationToken,
) -> Result<bool, SourceScanError> {
    if entry.safe_offset != entry.file.size
        || current_file.size <= entry.file.size
        || current_file.device != entry.file.device
        || current_file.inode != entry.file.inode
    {
        return Ok(false);
    }
    cancellation.check()?;
    let head = fingerprint_range(path, 0, entry.head_length, cancellation)?;
    let prefix_tail_start = entry.safe_offset.saturating_sub(entry.prefix_tail_length);
    let prefix_tail = fingerprint_range(
        path,
        prefix_tail_start,
        entry.prefix_tail_length,
        cancellation,
    )?;
    Ok(head == entry.head_fingerprint && prefix_tail == entry.prefix_tail_fingerprint)
}

fn make_entry(
    path: &Path,
    metadata: &fs::Metadata,
    config: &JsonlCacheConfig,
    source_path_digest: &str,
    payload: CachedFilePayload,
    cancellation: &CancellationToken,
) -> Result<JsonlCacheEntry, SourceScanError> {
    let file = JsonlFileSignature::from_metadata(metadata);
    let head_length = file.size.min(FINGERPRINT_SEGMENT_BYTES);
    let prefix_tail_length = file.size.min(FINGERPRINT_SEGMENT_BYTES);
    let safe_offset = if ends_with_newline(path, file.size, cancellation)? {
        file.size
    } else {
        0
    };
    Ok(JsonlCacheEntry {
        schema_version: JSONL_CACHE_SCHEMA_VERSION,
        source_id: config.source_id.clone(),
        source_path_digest: source_path_digest.to_owned(),
        parser_version: config.parser_version,
        aggregation_version: config.aggregation_version,
        window: JsonlCacheWindow::from_config(config),
        file,
        safe_offset,
        head_length,
        prefix_tail_length,
        head_fingerprint: fingerprint_range(path, 0, head_length, cancellation)?,
        prefix_tail_fingerprint: fingerprint_range(
            path,
            safe_offset.saturating_sub(prefix_tail_length),
            prefix_tail_length,
            cancellation,
        )?,
        payload,
    })
}

fn reconcile_deleted_cache<A: JsonlCacheAdapter>(
    root: &Path,
    state: &mut TreeState<'_, A>,
) -> Result<(), SourceScanError> {
    state.cancellation.check()?;
    let manifest_path = manifest_path(root, state.config);
    let previous = match fs::read(&manifest_path) {
        Ok(data) => serde_json::from_slice::<JsonlCacheManifest>(&data).ok(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(_) => {
            state.stats.cache_corruptions = state.stats.cache_corruptions.saturating_add(1);
            None
        }
    };
    if let Some(previous) = previous {
        if previous.schema_version == JSONL_CACHE_SCHEMA_VERSION
            && previous.source_id == state.config.source_id
        {
            for digest in previous.source_path_digests.difference(&state.seen) {
                state.cancellation.check()?;
                match fs::remove_file(entry_path(&state.config.cache_root, digest)) {
                    Ok(()) => {
                        state.stats.cache_deletions = state.stats.cache_deletions.saturating_add(1)
                    }
                    Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                    Err(_) => state.stats.io_errors = state.stats.io_errors.saturating_add(1),
                }
            }
        }
    }
    Ok(())
}

fn write_manifest<A: JsonlCacheAdapter>(
    root: &Path,
    state: &TreeState<'_, A>,
) -> Result<(), SourceScanError> {
    let manifest = JsonlCacheManifest {
        schema_version: JSONL_CACHE_SCHEMA_VERSION,
        source_id: state.config.source_id.clone(),
        source_root_digest: digest_with_source(state.config.source_id.as_str(), root),
        source_path_digests: state.seen.clone(),
    };
    write_json(
        &manifest_path(root, state.config),
        &manifest,
        state.cancellation,
    )
}

fn manifest_path(root: &Path, config: &JsonlCacheConfig) -> PathBuf {
    config.cache_root.join(format!(
        "manifest-jsonl-{}.json",
        digest_with_source(config.source_id.as_str(), root)
    ))
}

fn entry_path(cache_root: &Path, source_path_digest: &str) -> PathBuf {
    cache_root.join(format!("jsonl-{source_path_digest}.json"))
}

fn digest_with_source(source_id: &str, path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-jsonl-cache-v1\0");
    hasher.update(source_id.as_bytes());
    hasher.update([0]);
    hasher.update(path.to_string_lossy().as_bytes());
    format!("{:x}", hasher.finalize())
}

fn load_entry(path: &Path) -> CacheLoad {
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

fn write_entry(
    path: &Path,
    entry: &JsonlCacheEntry,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    write_json(path, entry, cancellation)
}

fn write_json<T: Serialize>(
    path: &Path,
    value: &T,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    cancellation.check()?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "jsonl cache path has no parent",
        )
    })?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("jsonl-cache"),
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
        // C110: 先序列化到内存再一次写入 —— 直接 to_writer 到未缓冲的 File 会把每个
        // JSON 记号变成一次 write 系统调用 (Claude 冷扫约 0.6 s 内核态)。
        let mut bytes = serde_json::to_vec(value).map_err(|error| {
            SourceScanError::Io(io::Error::new(io::ErrorKind::InvalidData, error))
        })?;
        bytes.push(b'\n');
        file.write_all(&bytes).map_err(SourceScanError::Io)?;
        drop(file);
        cancellation.check()?;
        fs::rename(&temporary, path).map_err(SourceScanError::Io)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub(crate) fn scan_jsonl_file_from_offset<F>(
    path: &Path,
    start_offset: u64,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
    mut callback: F,
) -> Result<(), SourceScanError>
where
    F: FnMut(&Path, &[u8], &mut ScanStats),
{
    cancellation.check()?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start_offset))?;
    let mut reader = BufReader::with_capacity(READ_BUFFER_BYTES, file);
    let mut line_buffer = Vec::new();
    loop {
        cancellation.check()?;
        let Some(line) = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES, &mut line_buffer)?
        else {
            break;
        };
        stats.lines_seen = stats.lines_seen.saturating_add(1);
        stats.bytes_read = stats.bytes_read.saturating_add(line.bytes as u64);
        if line.truncated {
            stats.truncated_lines = stats.truncated_lines.saturating_add(1);
            continue;
        }
        let line = trim_line_end(&line_buffer);
        if line.is_empty() {
            continue;
        }
        callback(path, line, stats);
    }
    Ok(())
}

fn fingerprint_range(
    path: &Path,
    start: u64,
    length: u64,
    cancellation: &CancellationToken,
) -> Result<String, SourceScanError> {
    cancellation.check()?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut hasher = Sha256::new();
    let mut remaining = length;
    let mut buffer = [0u8; 8192];
    while remaining > 0 {
        cancellation.check()?;
        let requested = remaining.min(buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..requested])?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "jsonl fingerprint range exceeds file size",
            )
            .into());
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn ends_with_newline(
    path: &Path,
    size: u64,
    cancellation: &CancellationToken,
) -> Result<bool, SourceScanError> {
    if size == 0 {
        return Ok(true);
    }
    cancellation.check()?;
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(size - 1))?;
    let mut byte = [0u8; 1];
    file.read_exact(&mut byte)?;
    Ok(byte[0] == b'\n')
}
