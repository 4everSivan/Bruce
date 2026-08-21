#![deny(unsafe_code)]

//! Local file and SQLite adapters.

mod sources;
mod sqlite;

use collector_domain::{
    CollectionWindow, ModelDelta, ProjectDelta, SourceDeltaChange, TokenBucket, UsageContribution,
    UsageContributionBuilder, UsageSample,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::SyncSender;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

pub const ADAPTER_ROLE: &str = "local-read-only";
pub const KIMI_USAGE_RECORD_TYPE: &str = "usage.record";
pub const MAX_JSONL_RECORD_BYTES: usize = 1024 * 1024;
pub const CACHE_SCHEMA_VERSION: u32 = 1;
pub const PARSER_VERSION: u32 = 2;
pub const AGGREGATION_VERSION: u32 = 1;
const FINGERPRINT_SEGMENT_BYTES: u64 = 64 * 1024;
// Cache files are small but numerous; one bounded writer avoids APFS metadata
// contention while still overlapping serialization with the source scan.
const CACHE_WRITERS: usize = 1;

pub use sources::{
    scan_claude, scan_codex, scan_grok, scan_kimi_tree, scan_opencode, scan_pi, scan_zcode,
    SourceScan,
};
pub use sqlite::{
    check_sqlite_schema, read_bounded_sqlite_rows, SqliteBoundedQuery, SqliteLimits,
    SqliteReadError, SqliteReadStats, SqliteSchema,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalUsageRecord {
    pub timestamp_millis: i64,
    pub model: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanStats {
    pub files_visited: u64,
    pub files_scanned: u64,
    pub files_skipped: u64,
    pub io_errors: u64,
    pub cache_hits: u64,
    pub cache_appends: u64,
    pub cache_rebuilds: u64,
    pub cache_corruptions: u64,
    pub cache_invalidations: u64,
    pub cache_deletions: u64,
    pub sqlite_rows_read: u64,
    pub lines_seen: u64,
    pub json_lines_parsed: u64,
    pub usage_records: u64,
    pub malformed_lines: u64,
    pub ignored_lines: u64,
    pub truncated_lines: u64,
    pub bytes_read: u64,
}

/// Result of a local source scan. The local crate exposes only domain-level
/// contributions and source changes; aggregate implementation details stay in
/// `collector-aggregate`.
#[derive(Debug, Clone)]
pub struct LocalScanResult {
    pub stats: ScanStats,
    pub contribution: UsageContribution,
    pub changes: Vec<SourceDeltaChange>,
}

impl ScanStats {
    pub fn merge(&mut self, other: Self) {
        self.files_visited = self.files_visited.saturating_add(other.files_visited);
        self.files_scanned = self.files_scanned.saturating_add(other.files_scanned);
        self.files_skipped = self.files_skipped.saturating_add(other.files_skipped);
        self.io_errors = self.io_errors.saturating_add(other.io_errors);
        self.cache_hits = self.cache_hits.saturating_add(other.cache_hits);
        self.cache_appends = self.cache_appends.saturating_add(other.cache_appends);
        self.cache_rebuilds = self.cache_rebuilds.saturating_add(other.cache_rebuilds);
        self.cache_corruptions = self
            .cache_corruptions
            .saturating_add(other.cache_corruptions);
        self.cache_invalidations = self
            .cache_invalidations
            .saturating_add(other.cache_invalidations);
        self.cache_deletions = self.cache_deletions.saturating_add(other.cache_deletions);
        self.sqlite_rows_read = self.sqlite_rows_read.saturating_add(other.sqlite_rows_read);
        self.lines_seen = self.lines_seen.saturating_add(other.lines_seen);
        self.json_lines_parsed = self
            .json_lines_parsed
            .saturating_add(other.json_lines_parsed);
        self.usage_records = self.usage_records.saturating_add(other.usage_records);
        self.malformed_lines = self.malformed_lines.saturating_add(other.malformed_lines);
        self.ignored_lines = self.ignored_lines.saturating_add(other.ignored_lines);
        self.truncated_lines = self.truncated_lines.saturating_add(other.truncated_lines);
        self.bytes_read = self.bytes_read.saturating_add(other.bytes_read);
    }
}

#[derive(Debug, Deserialize)]
struct RawRecord {
    #[serde(rename = "type")]
    record_type: Option<String>,
    time: Option<f64>,
    model: Option<String>,
    usage: Option<RawUsage>,
}

#[derive(Debug, Default, Deserialize)]
struct RawUsage {
    #[serde(rename = "inputOther")]
    input_other: Option<u64>,
    output: Option<u64>,
    #[serde(rename = "inputCacheRead")]
    input_cache_read: Option<u64>,
    #[serde(rename = "inputCacheCreation")]
    input_cache_creation: Option<u64>,
}

/// Stream one JSONL file without retaining its records in memory.
pub fn scan_path<F>(path: &Path, callback: F) -> io::Result<ScanStats>
where
    F: FnMut(LocalUsageRecord),
{
    let file = File::open(path)?;
    scan_reader(BufReader::new(file), callback)
}

pub fn scan_path_from_offset<F>(path: &Path, offset: u64, callback: F) -> io::Result<ScanStats>
where
    F: FnMut(LocalUsageRecord),
{
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(offset))?;
    scan_reader(BufReader::new(file), callback)
}

/// Scan only recent `.jsonl` files beneath `root`. A missing root is a valid
/// empty source, matching the Python adapter's not-found behavior.
pub fn scan_tree<F>(root: &Path, cutoff_ts: f64, mut callback: F) -> io::Result<ScanStats>
where
    F: FnMut(LocalUsageRecord),
{
    let mut stats = ScanStats::default();
    if !root.is_dir() {
        return Ok(stats);
    }
    visit_tree(root, cutoff_ts, &mut callback, &mut stats)?;
    Ok(stats)
}

#[derive(Debug, Clone)]
pub struct CacheConfig {
    pub cache_root: PathBuf,
    pub window: CollectionWindow,
    pub pricing_version: u32,
}

pub fn default_cache_root(home: &Path) -> PathBuf {
    home.join("Library/Application Support/Bruce/collector-cache-v1")
}

/// Scan a source tree while reusing only versioned derived aggregate deltas.
/// Cache files never contain raw JSONL, paths, credentials, or provider data.
pub fn scan_tree_cached(root: &Path, config: &CacheConfig) -> io::Result<LocalScanResult> {
    let mut changes = Vec::new();
    let stats = scan_tree_cached_with_sink(root, config, |change| {
        changes.push(change);
        Ok(())
    })?;
    let mut builder = UsageContributionBuilder::new(config.window.clone());
    for change in &changes {
        if let Some(added) = &change.added {
            if !builder.merge_contribution(added) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "source contribution has invalid hour buckets",
                ));
            }
        }
    }
    Ok(LocalScanResult {
        stats,
        contribution: builder.contribution(),
        changes,
    })
}

/// Scan a source tree and emit one bounded domain-level change at a time.
///
/// The sink is called only with derived contributions. It never receives raw
/// JSONL records, paths, credentials, or provider responses. Returning an I/O
/// error stops the traversal so an application-level bounded queue can apply
/// backpressure or cancellation.
pub fn scan_tree_cached_with_sink<F>(
    root: &Path,
    config: &CacheConfig,
    mut sink: F,
) -> io::Result<ScanStats>
where
    F: FnMut(SourceDeltaChange) -> io::Result<()>,
{
    let mut stats = ScanStats::default();
    let mut seen = BTreeSet::new();
    let (cache_sender, cache_receiver) = std::sync::mpsc::sync_channel::<CacheWriteJob>(4);
    let cache_receiver = Arc::new(Mutex::new(cache_receiver));
    let cache_writers = (0..CACHE_WRITERS)
        .map(|_| {
            let cache_receiver = Arc::clone(&cache_receiver);
            std::thread::spawn(move || {
                let mut errors = 0u64;
                loop {
                    let job = cache_receiver
                        .lock()
                        .expect("cache writer queue mutex poisoned")
                        .recv();
                    let Ok(job) = job else { break };
                    if write_cache(&job.path, &job.entry).is_err() {
                        errors = errors.saturating_add(1);
                    }
                }
                errors
            })
        })
        .collect::<Vec<_>>();
    let scan_result = if root.is_dir() {
        visit_tree_cached(
            root,
            config,
            &mut seen,
            &mut stats,
            &cache_sender,
            &mut sink,
        )
    } else {
        Ok(())
    };
    drop(cache_sender);
    let cache_write_errors = cache_writers
        .into_iter()
        .map(|writer| {
            writer
                .join()
                .map_err(|_| io::Error::new(io::ErrorKind::Other, "cache writer thread panicked"))
        })
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .sum::<u64>();
    stats.io_errors = stats.io_errors.saturating_add(cache_write_errors);
    scan_result?;
    reconcile_deleted_cache(root, config, &seen, &mut stats, &mut sink)?;
    Ok(stats)
}

fn visit_tree_cached<F>(
    root: &Path,
    config: &CacheConfig,
    seen: &mut BTreeSet<String>,
    stats: &mut ScanStats,
    cache_sender: &SyncSender<CacheWriteJob>,
    sink: &mut F,
) -> io::Result<()>
where
    F: FnMut(SourceDeltaChange) -> io::Result<()>,
{
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    for entry in entries {
        let Ok(entry) = entry else {
            stats.io_errors = stats.io_errors.saturating_add(1);
            continue;
        };
        let path = entry.path();
        let Ok(metadata) = entry.metadata() else {
            stats.io_errors = stats.io_errors.saturating_add(1);
            continue;
        };
        if metadata.is_dir() {
            visit_tree_cached(&path, config, seen, stats, cache_sender, sink)?;
            continue;
        }
        if !metadata.is_file() || path.extension().and_then(|value| value.to_str()) != Some("jsonl")
        {
            continue;
        }
        stats.files_visited = stats.files_visited.saturating_add(1);
        let modified = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_secs_f64());
        if modified.is_some_and(|value| value < config.window.cutoff_ts) {
            stats.files_skipped = stats.files_skipped.saturating_add(1);
            continue;
        }
        stats.files_scanned = stats.files_scanned.saturating_add(1);
        process_cached_file(&path, &metadata, config, seen, stats, cache_sender, sink)?;
    }
    Ok(())
}

struct CacheWriteJob {
    path: PathBuf,
    entry: CacheEntry,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct FileSignature {
    device: u64,
    inode: u64,
    size: u64,
    modified_ns: u64,
}

impl FileSignature {
    fn from_metadata(metadata: &fs::Metadata) -> Self {
        let modified_ns = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .map(|value| value.as_nanos() as u64)
            .unwrap_or(0);
        #[cfg(unix)]
        let (device, inode) = (metadata.dev(), metadata.ino());
        #[cfg(not(unix))]
        let (device, inode) = (0, 0);
        Self {
            device,
            inode,
            size: metadata.len(),
            modified_ns,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct CacheWindow {
    days: u32,
    timezone: String,
    today: String,
    pricing_version: u32,
}

impl CacheWindow {
    fn from_config(config: &CacheConfig) -> Self {
        Self {
            days: config.window.days,
            timezone: config.window.timezone_name.clone(),
            today: config.window.today.clone(),
            pricing_version: config.pricing_version,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct CacheEntry {
    schema_version: u32,
    source_kind: String,
    source_path_digest: String,
    parser_version: u32,
    aggregation_version: u32,
    window: CacheWindow,
    file: FileSignature,
    safe_offset: u64,
    head_length: u64,
    prefix_tail_length: u64,
    head_fingerprint: String,
    prefix_tail_fingerprint: String,
    delta: CompactContribution,
}

/// Compact cache-only representation. Cache entries are internal and
/// rebuildable, so arrays are preferable to repeating JSON field names for
/// every daily bucket while the domain contribution remains ergonomic.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct CompactContribution {
    days: Vec<(u16, [u64; 5])>,
    models_today: Vec<(String, [u64; 5])>,
    projects_today: Vec<(String, u64)>,
    hours: Vec<u64>,
}

impl CompactContribution {
    fn from_domain(value: &UsageContribution, window: &CollectionWindow) -> Option<Self> {
        let days = value
            .by_day
            .iter()
            .map(|(day, bucket)| {
                window
                    .day_list
                    .iter()
                    .position(|candidate| candidate == day)
                    .and_then(|index| u16::try_from(index).ok())
                    .map(|index| (index, bucket_array(bucket)))
            })
            .collect::<Option<Vec<_>>>()?;
        Some(Self {
            days,
            models_today: value
                .models_today
                .iter()
                .map(|model| (model.model.clone(), bucket_array(&model.bucket)))
                .collect(),
            projects_today: value
                .projects_today
                .iter()
                .map(|project| (project.name.clone(), project.total))
                .collect(),
            hours: value.hours.clone(),
        })
    }

    fn to_domain(&self, window: &CollectionWindow) -> Option<UsageContribution> {
        let by_day = self
            .days
            .iter()
            .map(|(index, values)| {
                window
                    .day_list
                    .get(*index as usize)
                    .cloned()
                    .map(|day| (day, bucket_from_array(*values)))
            })
            .collect::<Option<BTreeMap<_, _>>>()?;
        Some(UsageContribution {
            models_today: self
                .models_today
                .iter()
                .map(|(model, values)| ModelDelta {
                    model: model.clone(),
                    bucket: bucket_from_array(*values),
                })
                .collect(),
            projects_today: self
                .projects_today
                .iter()
                .map(|(name, total)| ProjectDelta {
                    name: name.clone(),
                    total: *total,
                })
                .collect(),
            hours: self.hours.clone(),
            by_day,
        })
    }
}

fn bucket_array(bucket: &TokenBucket) -> [u64; 5] {
    [
        bucket.input,
        bucket.output,
        bucket.cache_read,
        bucket.cache_creation,
        bucket.total,
    ]
}

fn bucket_from_array(values: [u64; 5]) -> TokenBucket {
    TokenBucket {
        input: values[0],
        output: values[1],
        cache_read: values[2],
        cache_creation: values[3],
        total: values[4],
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct CacheManifest {
    schema_version: u32,
    source_kind: String,
    source_root_digest: String,
    source_path_digests: BTreeSet<String>,
}

enum CacheLoad {
    Missing,
    Corrupt,
    Entry(Box<CacheEntry>),
}

fn process_cached_file<F>(
    path: &Path,
    metadata: &fs::Metadata,
    config: &CacheConfig,
    seen: &mut BTreeSet<String>,
    stats: &mut ScanStats,
    cache_sender: &SyncSender<CacheWriteJob>,
    sink: &mut F,
) -> io::Result<()>
where
    F: FnMut(SourceDeltaChange) -> io::Result<()>,
{
    let source_path_digest = digest_bytes(path.to_string_lossy().as_bytes());
    seen.insert(source_path_digest.clone());
    let cache_path = config.cache_root.join(format!("{source_path_digest}.json"));
    let current_file = FileSignature::from_metadata(metadata);
    let loaded = load_cache(&cache_path);
    if matches!(&loaded, CacheLoad::Corrupt) {
        stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
    }
    if let CacheLoad::Entry(entry) = loaded {
        if cache_identity_matches(&entry, &source_path_digest, config) && entry.file == current_file
        {
            if let Some(delta) = entry.delta.to_domain(&config.window) {
                stats.cache_hits = stats.cache_hits.saturating_add(1);
                sink(SourceDeltaChange::replace(
                    source_path_digest.clone(),
                    None,
                    Some(delta),
                ))?;
                return Ok(());
            }
            stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
        }
        if cache_identity_matches(&entry, &source_path_digest, config)
            && append_is_safe(path, &entry, &current_file)?
        {
            if let Some(previous_delta) = entry.delta.to_domain(&config.window) {
                if let Some(mut delta_builder) = UsageContributionBuilder::from_contribution(
                    config.window.clone(),
                    &previous_delta,
                ) {
                    let append_stats = scan_path_from_offset(path, entry.safe_offset, |record| {
                        record_into(&mut delta_builder, record);
                    })?;
                    let delta = delta_builder.contribution();
                    let current_metadata = fs::metadata(path)?;
                    let new_entry =
                        make_cache_entry(path, &current_metadata, config, delta.clone())?;
                    if cache_sender
                        .send(CacheWriteJob {
                            path: cache_path.clone(),
                            entry: new_entry,
                        })
                        .is_err()
                    {
                        stats.io_errors = stats.io_errors.saturating_add(1);
                    }
                    sink(SourceDeltaChange::replace(
                        source_path_digest.clone(),
                        Some(previous_delta),
                        Some(delta),
                    ))?;
                    stats.cache_appends = stats.cache_appends.saturating_add(1);
                    stats.lines_seen = stats.lines_seen.saturating_add(append_stats.lines_seen);
                    stats.json_lines_parsed = stats
                        .json_lines_parsed
                        .saturating_add(append_stats.json_lines_parsed);
                    stats.usage_records = stats
                        .usage_records
                        .saturating_add(append_stats.usage_records);
                    stats.malformed_lines = stats
                        .malformed_lines
                        .saturating_add(append_stats.malformed_lines);
                    stats.ignored_lines = stats
                        .ignored_lines
                        .saturating_add(append_stats.ignored_lines);
                    stats.truncated_lines = stats
                        .truncated_lines
                        .saturating_add(append_stats.truncated_lines);
                    stats.bytes_read = stats.bytes_read.saturating_add(append_stats.bytes_read);
                    return Ok(());
                }
            }
        }
        stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
    }

    let mut rebuilt = UsageContributionBuilder::new(config.window.clone());
    let scan_stats = scan_path(path, |record| record_into(&mut rebuilt, record))?;
    let delta = rebuilt.contribution();
    let current_metadata = fs::metadata(path)?;
    let entry = make_cache_entry(path, &current_metadata, config, delta.clone())?;
    if cache_sender
        .send(CacheWriteJob {
            path: cache_path,
            entry,
        })
        .is_err()
    {
        stats.io_errors = stats.io_errors.saturating_add(1);
    }
    sink(SourceDeltaChange::replace(
        source_path_digest,
        None,
        Some(delta),
    ))?;
    stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
    stats.lines_seen = stats.lines_seen.saturating_add(scan_stats.lines_seen);
    stats.json_lines_parsed = stats
        .json_lines_parsed
        .saturating_add(scan_stats.json_lines_parsed);
    stats.usage_records = stats.usage_records.saturating_add(scan_stats.usage_records);
    stats.malformed_lines = stats
        .malformed_lines
        .saturating_add(scan_stats.malformed_lines);
    stats.ignored_lines = stats.ignored_lines.saturating_add(scan_stats.ignored_lines);
    stats.truncated_lines = stats
        .truncated_lines
        .saturating_add(scan_stats.truncated_lines);
    stats.bytes_read = stats.bytes_read.saturating_add(scan_stats.bytes_read);
    Ok(())
}

fn reconcile_deleted_cache<F>(
    root: &Path,
    config: &CacheConfig,
    seen: &BTreeSet<String>,
    stats: &mut ScanStats,
    sink: &mut F,
) -> io::Result<()>
where
    F: FnMut(SourceDeltaChange) -> io::Result<()>,
{
    let source_root_digest = digest_bytes(root.to_string_lossy().as_bytes());
    let manifest_path = config
        .cache_root
        .join(format!("manifest-{source_root_digest}.json"));
    let previous = match fs::read(&manifest_path) {
        Ok(data) => match serde_json::from_slice::<CacheManifest>(&data) {
            Ok(manifest)
                if manifest.schema_version == CACHE_SCHEMA_VERSION
                    && manifest.source_kind == KIMI_USAGE_RECORD_TYPE
                    && manifest.source_root_digest == source_root_digest =>
            {
                Some(manifest)
            }
            Ok(_) | Err(_) => {
                stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
                None
            }
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(_) => {
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
            None
        }
    };
    if let Some(previous) = previous {
        for digest in previous.source_path_digests.difference(seen) {
            if !is_digest(digest) {
                continue;
            }
            let cache_path = config.cache_root.join(format!("{digest}.json"));
            let removed = match load_cache(&cache_path) {
                CacheLoad::Entry(entry) if cache_identity_matches(&entry, digest, config) => {
                    entry.delta.to_domain(&config.window)
                }
                CacheLoad::Missing | CacheLoad::Corrupt | CacheLoad::Entry(_) => None,
            };
            match fs::remove_file(cache_path) {
                Ok(()) => {
                    stats.cache_deletions = stats.cache_deletions.saturating_add(1);
                    sink(SourceDeltaChange::replace(digest.clone(), removed, None))?;
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(_) => stats.io_errors = stats.io_errors.saturating_add(1),
            }
        }
    }
    let manifest = CacheManifest {
        schema_version: CACHE_SCHEMA_VERSION,
        source_kind: KIMI_USAGE_RECORD_TYPE.to_owned(),
        source_root_digest,
        source_path_digests: seen.clone(),
    };
    if write_manifest(&manifest_path, &manifest).is_err() {
        stats.io_errors = stats.io_errors.saturating_add(1);
    }
    Ok(())
}

fn is_digest(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn record_into(builder: &mut UsageContributionBuilder, record: LocalUsageRecord) {
    let model = record.model.as_deref();
    builder.record(UsageSample {
        timestamp_millis: record.timestamp_millis,
        model,
        input: record.input,
        output: record.output,
        cache_read: record.cache_read,
        cache_creation: record.cache_creation,
        project: None,
    });
}

fn cache_identity_matches(
    entry: &CacheEntry,
    source_path_digest: &str,
    config: &CacheConfig,
) -> bool {
    entry.schema_version == CACHE_SCHEMA_VERSION
        && entry.source_kind == KIMI_USAGE_RECORD_TYPE
        && entry.source_path_digest == source_path_digest
        && entry.parser_version == PARSER_VERSION
        && entry.aggregation_version == AGGREGATION_VERSION
        && entry.window == CacheWindow::from_config(config)
}

fn append_is_safe(
    path: &Path,
    entry: &CacheEntry,
    current_file: &FileSignature,
) -> io::Result<bool> {
    if entry.safe_offset != entry.file.size
        || current_file.size <= entry.file.size
        || current_file.device != entry.file.device
        || current_file.inode != entry.file.inode
    {
        return Ok(false);
    }
    let head = fingerprint_range(path, 0, entry.head_length)?;
    let prefix_tail_start = entry.safe_offset.saturating_sub(entry.prefix_tail_length);
    let prefix_tail = fingerprint_range(path, prefix_tail_start, entry.prefix_tail_length)?;
    Ok(head == entry.head_fingerprint && prefix_tail == entry.prefix_tail_fingerprint)
}

fn make_cache_entry(
    path: &Path,
    metadata: &fs::Metadata,
    config: &CacheConfig,
    delta: UsageContribution,
) -> io::Result<CacheEntry> {
    let file = FileSignature::from_metadata(metadata);
    let head_length = file.size.min(FINGERPRINT_SEGMENT_BYTES);
    let prefix_tail_length = file.size.min(FINGERPRINT_SEGMENT_BYTES);
    let safe_offset = if ends_with_newline(path, file.size)? {
        file.size
    } else {
        0
    };
    Ok(CacheEntry {
        schema_version: CACHE_SCHEMA_VERSION,
        source_kind: KIMI_USAGE_RECORD_TYPE.to_owned(),
        source_path_digest: digest_bytes(path.to_string_lossy().as_bytes()),
        parser_version: PARSER_VERSION,
        aggregation_version: AGGREGATION_VERSION,
        window: CacheWindow::from_config(config),
        file,
        safe_offset,
        head_length,
        prefix_tail_length,
        head_fingerprint: fingerprint_range(path, 0, head_length)?,
        prefix_tail_fingerprint: fingerprint_range(
            path,
            safe_offset.saturating_sub(prefix_tail_length),
            prefix_tail_length,
        )?,
        delta: CompactContribution::from_domain(&delta, &config.window).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "contribution day is outside cache window",
            )
        })?,
    })
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

fn write_cache(path: &Path, entry: &CacheEntry) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "cache path has no parent"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("entry"),
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
        serde_json::to_writer(&mut file, entry)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        file.write_all(b"\n")?;
        // Cache entries are derived and rebuildable. The create-new temp file
        // followed by rename gives readers an atomic whole-entry view; doing a
        // durability fsync for every source file made cold refresh scale with
        // the number of files and dominated the Rust performance gate.
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn write_manifest(path: &Path, manifest: &CacheManifest) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "manifest path has no parent")
    })?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("manifest"),
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
        serde_json::to_writer(&mut file, manifest)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        file.write_all(b"\n")?;
        // The manifest is derived from per-file entries and can be rebuilt
        // after a crash. Atomic rename is sufficient here; a durability sync
        // on every refresh adds avoidable metadata latency.
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn fingerprint_range(path: &Path, start: u64, length: u64) -> io::Result<String> {
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(start))?;
    let mut hasher = Sha256::new();
    let mut remaining = length;
    let mut buffer = [0u8; 8192];
    while remaining > 0 {
        let requested = remaining.min(buffer.len() as u64) as usize;
        let read = file.read(&mut buffer[..requested])?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "fingerprint range exceeds file size",
            ));
        }
        hasher.update(&buffer[..read]);
        remaining -= read as u64;
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn digest_bytes(value: &[u8]) -> String {
    format!("{:x}", Sha256::digest(value))
}

fn ends_with_newline(path: &Path, size: u64) -> io::Result<bool> {
    if size == 0 {
        return Ok(true);
    }
    let mut file = File::open(path)?;
    file.seek(SeekFrom::Start(size - 1))?;
    let mut byte = [0u8; 1];
    file.read_exact(&mut byte)?;
    Ok(byte[0] == b'\n')
}

fn visit_tree<F>(
    root: &Path,
    cutoff_ts: f64,
    callback: &mut F,
    stats: &mut ScanStats,
) -> io::Result<()>
where
    F: FnMut(LocalUsageRecord),
{
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    for entry in entries {
        let Ok(entry) = entry else {
            stats.io_errors = stats.io_errors.saturating_add(1);
            continue;
        };
        let path = entry.path();
        let Ok(metadata) = entry.metadata() else {
            stats.io_errors = stats.io_errors.saturating_add(1);
            continue;
        };
        if metadata.is_dir() {
            visit_tree(&path, cutoff_ts, callback, stats)?;
            continue;
        }
        if metadata.is_file() && path.extension().and_then(|value| value.to_str()) == Some("jsonl")
        {
            stats.files_visited = stats.files_visited.saturating_add(1);
            let modified = metadata
                .modified()
                .ok()
                .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
                .map(|value| value.as_secs_f64());
            if modified.is_some_and(|value| value < cutoff_ts) {
                stats.files_skipped = stats.files_skipped.saturating_add(1);
                continue;
            }
            match scan_path(&path, &mut *callback) {
                Ok(file_stats) => {
                    stats.files_scanned = stats.files_scanned.saturating_add(1);
                    stats.merge(file_stats);
                }
                Err(_) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                }
            }
        }
    }
    Ok(())
}

/// Parse Kimi `usage.record` lines and invoke the callback as each record is
/// decoded. Unknown JSON fields are intentionally ignored for forward
/// compatibility; malformed or over-sized records are counted and skipped.
pub fn scan_reader<R, F>(mut reader: R, mut callback: F) -> io::Result<ScanStats>
where
    R: BufRead,
    F: FnMut(LocalUsageRecord),
{
    let mut stats = ScanStats::default();
    while let Some(line) = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES)? {
        stats.lines_seen += 1;
        stats.bytes_read = stats.bytes_read.saturating_add(line.bytes as u64);
        if line.truncated {
            stats.truncated_lines += 1;
            continue;
        }
        let trimmed = trim_line_end(&line.bytes_data);
        if trimmed.is_empty() {
            continue;
        }
        let record: RawRecord = match serde_json::from_slice(trimmed) {
            Ok(value) => value,
            Err(_) => {
                stats.malformed_lines += 1;
                continue;
            }
        };
        stats.json_lines_parsed += 1;
        if record.record_type.as_deref() != Some(KIMI_USAGE_RECORD_TYPE) {
            stats.ignored_lines += 1;
            continue;
        }
        let Some(timestamp) = record.time.filter(|value| value.is_finite()) else {
            stats.malformed_lines += 1;
            continue;
        };
        if timestamp < i64::MIN as f64 || timestamp > i64::MAX as f64 {
            stats.malformed_lines += 1;
            continue;
        }
        let usage = record.usage.unwrap_or_default();
        callback(LocalUsageRecord {
            timestamp_millis: timestamp as i64,
            model: record.model,
            input: usage.input_other.unwrap_or(0),
            output: usage.output.unwrap_or(0),
            cache_read: usage.input_cache_read.unwrap_or(0),
            cache_creation: usage.input_cache_creation.unwrap_or(0),
        });
        stats.usage_records += 1;
    }
    Ok(stats)
}

struct BoundedLine {
    bytes_data: Vec<u8>,
    bytes: usize,
    truncated: bool,
}

fn read_bounded_line<R: BufRead>(reader: &mut R, limit: usize) -> io::Result<Option<BoundedLine>> {
    let mut bytes_data = Vec::with_capacity(limit.min(4096));
    let mut bytes = 0usize;
    let mut truncated = false;
    loop {
        let (chunk_len, newline_at) = {
            let chunk = reader.fill_buf()?;
            if chunk.is_empty() {
                if bytes == 0 {
                    return Ok(None);
                }
                (0, None)
            } else {
                let newline_at = chunk.iter().position(|byte| *byte == b'\n');
                (
                    newline_at.map(|index| index + 1).unwrap_or(chunk.len()),
                    newline_at,
                )
            }
        };
        if chunk_len == 0 {
            break;
        }
        {
            let chunk = reader.fill_buf()?;
            bytes = bytes.saturating_add(chunk_len);
            if !truncated {
                let remaining = limit.saturating_sub(bytes_data.len());
                let copy_len = remaining.min(chunk_len);
                bytes_data.extend_from_slice(&chunk[..copy_len]);
                if copy_len < chunk_len {
                    truncated = true;
                }
            }
        }
        reader.consume(chunk_len);
        if newline_at.is_some() {
            break;
        }
    }
    Ok(Some(BoundedLine {
        bytes_data,
        bytes,
        truncated,
    }))
}

fn trim_line_end(value: &[u8]) -> &[u8] {
    let value = value.strip_suffix(b"\n").unwrap_or(value);
    value.strip_suffix(b"\r").unwrap_or(value)
}

#[cfg(test)]
mod tests {
    use super::{
        default_cache_root, scan_reader, scan_tree_cached, CacheConfig, LocalUsageRecord,
        MAX_JSONL_RECORD_BYTES,
    };
    use collector_domain::CollectionWindow;
    use serde_json::json;
    use std::fs::{self, OpenOptions};
    use std::io::{Cursor, Write};

    fn today_total(result: &super::LocalScanResult, window: &CollectionWindow) -> u64 {
        result
            .contribution
            .by_day
            .get(&window.today)
            .map(|bucket| bucket.total)
            .unwrap_or(0)
    }

    #[test]
    fn streams_valid_records_and_ignores_unknown_fields() {
        let input = br#"
{"type":"usage.record","time":1785211200000,"model":"gpt-5","usage":{"inputOther":10,"output":4,"inputCacheRead":2,"inputCacheCreation":1},"futureField":{"secret":"not-retained"}}
{"type":"other","time":1785211200000}
{"type":"usage.record","time":1785211201000,"usage":{}}
"#;
        let mut records = Vec::<LocalUsageRecord>::new();
        let stats = scan_reader(Cursor::new(input), |record| records.push(record)).unwrap();
        assert_eq!(stats.usage_records, 2);
        assert_eq!(stats.ignored_lines, 1);
        assert_eq!(records[0].input, 10);
        assert_eq!(records[0].cache_creation, 1);
        assert_eq!(records[1].model, None);
    }

    #[test]
    fn malformed_and_empty_lines_do_not_abort_the_stream() {
        let input = b"\nnot-json\n{\"type\":\"usage.record\",\"time\":null}\n";
        let mut count = 0;
        let stats = scan_reader(Cursor::new(input), |_| count += 1).unwrap();
        assert_eq!(count, 0);
        assert_eq!(stats.malformed_lines, 2);
    }

    #[test]
    fn oversized_line_is_consumed_without_allocating_the_full_record() {
        let mut input = Vec::from(
            br#"{"type":"usage.record","time":1785211200000,"usage":{"inputOther":1},"padding":"#,
        );
        input.extend(std::iter::repeat_n(b'x', MAX_JSONL_RECORD_BYTES + 16));
        input.extend_from_slice(b"\"}\n");
        let stats =
            scan_reader(Cursor::new(input), |_| panic!("truncated record emitted")).unwrap();
        assert_eq!(stats.lines_seen, 1);
        assert_eq!(stats.truncated_lines, 1);
        assert_eq!(stats.usage_records, 0);
    }

    #[test]
    fn cache_reuses_unchanged_files_and_reads_only_appends() {
        let root =
            std::env::temp_dir().join(format!("bruce-collector-cache-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        let sessions = root.join("home/.kimi-code/sessions");
        fs::create_dir_all(&sessions).unwrap();
        let path = sessions.join("fixture.jsonl");
        let first = json!({
            "type": "usage.record",
            "time": 1785211200000i64,
            "model": "gpt-5",
            "usage": {"inputOther": 10, "output": 2}
        });
        fs::write(&path, format!("{}\n", first)).unwrap();
        let context = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 14
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let config = CacheConfig {
            cache_root: default_cache_root(&root.join("home")),
            window: window.clone(),
            pricing_version: 1,
        };

        let cold = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(cold.stats.cache_rebuilds, 1);
        assert_eq!(today_total(&cold, &window), 12);

        let warm = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(warm.stats.cache_hits, 1);
        assert_eq!(warm.stats.lines_seen, 0);
        assert_eq!(today_total(&warm, &window), 12);

        let second = json!({
            "type": "usage.record",
            "time": 1785211201000i64,
            "model": "gpt-5",
            "usage": {"inputOther": 3, "output": 1}
        });
        let mut append = OpenOptions::new().append(true).open(&path).unwrap();
        writeln!(append, "{}", second).unwrap();
        let appended = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(appended.stats.cache_appends, 1);
        assert_eq!(appended.stats.lines_seen, 1);
        assert_eq!(today_total(&appended, &window), 16);

        let replacement = json!({
            "type": "usage.record",
            "time": 1785211200000i64,
            "model": "gpt-5",
            "usage": {"inputOther": 1, "output": 1}
        });
        fs::write(&path, format!("{}\n", replacement)).unwrap();
        let rebuilt = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(rebuilt.stats.cache_rebuilds, 1);
        assert_eq!(today_total(&rebuilt, &window), 2);

        let cache_file = fs::read_dir(&config.cache_root)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.extension().and_then(|value| value.to_str()) == Some("json")
                    && !path
                        .file_name()
                        .and_then(|value| value.to_str())
                        .is_some_and(|value| value.starts_with("manifest-"))
            })
            .unwrap();
        fs::write(&cache_file, b"not-json\n").unwrap();
        let corrupt = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(corrupt.stats.cache_corruptions, 1);
        assert_eq!(corrupt.stats.cache_rebuilds, 1);
        let cache_text = fs::read_to_string(&cache_file).unwrap();
        assert!(!cache_text.contains("inputOther"));
        fs::remove_file(&path).unwrap();
        let deleted = scan_tree_cached(&sessions, &config).unwrap();
        assert_eq!(deleted.stats.cache_deletions, 1);
        assert_eq!(today_total(&deleted, &config.window), 0);
        assert!(!cache_file.exists());
        let _ = fs::remove_dir_all(root);
    }
}
