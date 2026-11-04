//! Rebuildable cache engine for local JSONL sources.
//!
//! Only derived usage observations cross the cache boundary. Raw JSONL lines,
//! credentials, and source paths are never stored.
//!
//! C116: 条目只保存与采集窗口无关的观测值 (时间戳 + token 计数), 身份不含 `today` /
//! 窗口天数 —— 每次运行再按当前窗口聚合。旧实现把按窗口天序号压缩的贡献写进条目并以
//! `today` 为身份, 每天首轮刷新与改动窗口长度都会让全部条目失效、整树重新解析。
//!
//! C176: 扫描逐文件把载荷并入适配器的聚合器, 不再同时持有全部文件的观测; 条目载荷改为
//! 紧凑形状 (文件级 project、按文件去重的模型表、128 位去重键、缩写字段名)。

use super::sources::{SourceScan, SourceScanError};
use super::{
    read_bounded_line, trim_line_end, ScanStats, MAX_DIRECTORY_SCAN_DEPTH, MAX_JSONL_RECORD_BYTES,
    READ_BUFFER_BYTES,
};
use crate::cache_util::{
    ends_with_newline, fingerprint_range, load_json_cache, write_json_atomic, CacheLoad,
};
use collector_domain::{CollectionWindow, UsageContribution};
use collector_runtime::CancellationToken;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{self, BufReader, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// v2 (C116): 条目去掉按窗口压缩的贡献与窗口身份, 只存观测值。
/// v3 (C176): 紧凑载荷 (见 `CachedFilePayload`); 旧版本条目仍可解析, 按版本不匹配重建一次,
/// 不计为损坏。
const JSONL_CACHE_SCHEMA_VERSION: u32 = 3;
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

/// 一条与窗口无关的用量观测 (C116)。缺省值不落盘以控制条目体积。
/// C176 起只剩 Codex 按文件缓存使用 (其格式不随 JSONL 层变化); JSONL 层见 `JsonlObservation`。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct CachedUsageObservation {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) dedupe_key: Option<String>,
    pub(crate) timestamp_millis: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) model: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) input: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) output: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) cache_read: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) cache_creation: u64,
    /// cache_creation 中按 1 小时 TTL 写入的部分 (C107)。
    #[serde(default, skip_serializing_if = "is_zero")]
    pub(crate) cache_creation_1h: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) project: Option<String>,
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}

impl CachedUsageObservation {
    pub(crate) fn sample(&self) -> collector_domain::UsageSample<'_> {
        collector_domain::UsageSample {
            timestamp_millis: self.timestamp_millis,
            model: self.model.as_deref(),
            input: self.input,
            output: self.output,
            cache_read: self.cache_read,
            cache_creation: self.cache_creation,
            cache_creation_1h: self.cache_creation_1h,
            project: self.project.as_deref(),
        }
    }
}

/// JSONL 去重键 (C176): SHA-256(域分隔 + 命名空间 + 原始 id) 的前 128 位, 大端解释。
/// 数值序与旧版 64 位十六进制键的字典序一致, 去重表的遍历 (即聚合与模型首见) 顺序不变。
pub(crate) type DedupeKey = u128;

/// 一条与窗口无关的 JSONL 用量观测 (C116 / C176)。project 由文件路径推导、同一文件恒定,
/// 存于文件级载荷而不在每条观测上重复。
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct JsonlObservation {
    pub(crate) dedupe_key: Option<DedupeKey>,
    pub(crate) timestamp_millis: i64,
    pub(crate) model: Option<String>,
    pub(crate) input: u64,
    pub(crate) output: u64,
    pub(crate) cache_read: u64,
    pub(crate) cache_creation: u64,
    /// cache_creation 中按 1 小时 TTL 写入的部分 (C107)。
    pub(crate) cache_creation_1h: u64,
}

impl JsonlObservation {
    pub(crate) fn sample<'a>(
        &'a self,
        project: Option<&'a str>,
    ) -> collector_domain::UsageSample<'a> {
        collector_domain::UsageSample {
            timestamp_millis: self.timestamp_millis,
            model: self.model.as_deref(),
            input: self.input,
            output: self.output,
            cache_read: self.cache_read,
            cache_creation: self.cache_creation,
            cache_creation_1h: self.cache_creation_1h,
            project,
        }
    }
}

/// 一个 JSONL 文件的观测载荷。落盘形状 (v3) 由下方手写 serde 决定:
/// `{"project", "models": [..], "observations": [{"k","t","m","i","o","r","w","h"}]}`,
/// 其中 `m` 是 `models` 下标, `k` 是 32 位十六进制去重键, 零值与缺省不落盘。
#[derive(Debug, Clone, PartialEq, Default)]
pub(crate) struct CachedFilePayload {
    pub(crate) project: Option<String>,
    pub(crate) observations: Vec<JsonlObservation>,
}

#[derive(Serialize)]
struct PayloadWireOut<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    project: Option<&'a str>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    models: Vec<&'a str>,
    observations: Vec<ObservationWireOut>,
}

#[derive(Serialize)]
struct ObservationWireOut {
    #[serde(rename = "k", skip_serializing_if = "Option::is_none")]
    dedupe_key: Option<String>,
    #[serde(rename = "t")]
    timestamp_millis: i64,
    #[serde(rename = "m", skip_serializing_if = "Option::is_none")]
    model: Option<u32>,
    #[serde(rename = "i", skip_serializing_if = "is_zero")]
    input: u64,
    #[serde(rename = "o", skip_serializing_if = "is_zero")]
    output: u64,
    #[serde(rename = "r", skip_serializing_if = "is_zero")]
    cache_read: u64,
    #[serde(rename = "w", skip_serializing_if = "is_zero")]
    cache_creation: u64,
    #[serde(rename = "h", skip_serializing_if = "is_zero")]
    cache_creation_1h: u64,
}

/// 读取侧全部字段可缺省、未知字段忽略: 旧版本条目 (字段名不同) 也能解析出来,
/// 再由条目身份按版本不匹配判失效 —— 版本升级不计为损坏。
#[derive(Deserialize)]
struct PayloadWireIn {
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    models: Vec<String>,
    #[serde(default)]
    observations: Vec<ObservationWireIn>,
}

#[derive(Deserialize)]
struct ObservationWireIn {
    #[serde(rename = "k", default)]
    dedupe_key: Option<String>,
    #[serde(rename = "t", default)]
    timestamp_millis: i64,
    #[serde(rename = "m", default)]
    model: Option<u32>,
    #[serde(rename = "i", default)]
    input: u64,
    #[serde(rename = "o", default)]
    output: u64,
    #[serde(rename = "r", default)]
    cache_read: u64,
    #[serde(rename = "w", default)]
    cache_creation: u64,
    #[serde(rename = "h", default)]
    cache_creation_1h: u64,
}

impl Serialize for CachedFilePayload {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut models = Vec::<&str>::new();
        let mut model_index = HashMap::<&str, u32>::new();
        let mut observations = Vec::with_capacity(self.observations.len());
        for observation in &self.observations {
            let model = observation.model.as_deref().map(|model| {
                *model_index.entry(model).or_insert_with(|| {
                    models.push(model);
                    (models.len() - 1) as u32
                })
            });
            observations.push(ObservationWireOut {
                dedupe_key: observation.dedupe_key.map(|key| format!("{key:032x}")),
                timestamp_millis: observation.timestamp_millis,
                model,
                input: observation.input,
                output: observation.output,
                cache_read: observation.cache_read,
                cache_creation: observation.cache_creation,
                cache_creation_1h: observation.cache_creation_1h,
            });
        }
        PayloadWireOut {
            project: self.project.as_deref(),
            models,
            observations,
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for CachedFilePayload {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = PayloadWireIn::deserialize(deserializer)?;
        let mut observations = Vec::with_capacity(wire.observations.len());
        for observation in wire.observations {
            let dedupe_key = match observation.dedupe_key {
                Some(raw) if raw.len() == 32 => Some(
                    u128::from_str_radix(&raw, 16)
                        .map_err(|_| D::Error::custom("invalid jsonl dedupe key"))?,
                ),
                Some(_) => return Err(D::Error::custom("invalid jsonl dedupe key")),
                None => None,
            };
            let model = match observation.model {
                Some(index) => Some(
                    wire.models
                        .get(index as usize)
                        .cloned()
                        .ok_or_else(|| D::Error::custom("jsonl model index out of range"))?,
                ),
                None => None,
            };
            observations.push(JsonlObservation {
                dedupe_key,
                timestamp_millis: observation.timestamp_millis,
                model,
                input: observation.input,
                output: observation.output,
                cache_read: observation.cache_read,
                cache_creation: observation.cache_creation,
                cache_creation_1h: observation.cache_creation_1h,
            });
        }
        Ok(Self {
            project: wire.project,
            observations,
        })
    }
}

#[derive(Debug, Clone)]
pub(crate) struct JsonlCacheConfig {
    pub(crate) cache_root: PathBuf,
    pub(crate) source_id: String,
    pub(crate) parser_version: u32,
    pub(crate) aggregation_version: u32,
    pub(crate) window: CollectionWindow,
}

/// 逐文件并入的聚合器 (C176): 按目录遍历顺序收到每个文件的载荷, 扫描结束后产出贡献。
/// 并入顺序与旧实现「全部载入后统一聚合」的遍历顺序相同, 结果逐字节一致。
pub(crate) trait JsonlAggregator {
    fn absorb(&mut self, payload: &CachedFilePayload);

    /// 返回 (贡献, 是否并入过任何文件, 诊断)。
    fn finish(self) -> Result<(UsageContribution, bool, Option<String>), SourceScanError>;
}

pub(crate) trait JsonlCacheAdapter {
    type Aggregator: JsonlAggregator;

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

    /// 合并追加段的观测值 (默认直接拼接; Grok 以文件 mtime 为时间戳, 需整体重打)。
    fn merge_append(
        &self,
        previous: CachedFilePayload,
        appended: CachedFilePayload,
        _modified: f64,
    ) -> CachedFilePayload {
        let mut observations = previous.observations;
        observations.extend(appended.observations);
        CachedFilePayload {
            project: appended.project,
            observations,
        }
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct JsonlCacheEntry {
    schema_version: u32,
    source_id: String,
    source_path_digest: String,
    parser_version: u32,
    aggregation_version: u32,
    /// 解析无时区时间戳所用的时区 (C116: 仅此项与窗口相关; 天数 / today 不进身份)。
    #[serde(default)]
    timezone: String,
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
        visited_dirs: std::collections::BTreeSet::new(),
    };
    let mut aggregator = adapter.aggregator(&config.window);
    visit_tree(root, &mut state, &mut aggregator, 0)?;
    cancellation.check()?;
    reconcile_deleted_cache(root, &mut state)?;
    cancellation.check()?;
    let (contribution, adapter_found, diagnostic) = aggregator.finish()?;
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
    })
}

struct TreeState<'a, A> {
    config: &'a JsonlCacheConfig,
    adapter: &'a A,
    cancellation: &'a CancellationToken,
    stats: ScanStats,
    seen: std::collections::BTreeSet<String>,
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
    aggregator: &mut A::Aggregator,
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
                visit_tree(&path, state, aggregator, depth + 1)?;
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
            aggregator.absorb(&payload);
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
    let loaded: CacheLoad<JsonlCacheEntry> = load_json_cache(&cache_path);
    if matches!(loaded, CacheLoad::Corrupt) {
        state.stats.cache_corruptions = state.stats.cache_corruptions.saturating_add(1);
    }
    if let CacheLoad::Entry(mut entry) = loaded {
        if cache_identity_matches(&entry, &source_path_digest, state.config)
            && entry.file == current_file
            && cache_payload_is_valid(&entry)
        {
            state.stats.cache_hits = state.stats.cache_hits.saturating_add(1);
            return Ok(Some(std::mem::take(&mut entry.payload)));
        }
        if cache_identity_matches(&entry, &source_path_digest, state.config)
            && cache_payload_is_valid(&entry)
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
            let merged =
                state
                    .adapter
                    .merge_append(std::mem::take(&mut entry.payload), appended, modified);
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

fn cache_payload_is_valid(entry: &JsonlCacheEntry) -> bool {
    entry.safe_offset <= entry.file.size
        && entry.head_length <= entry.file.size
        && entry.prefix_tail_length <= entry.file.size
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
    write_json_atomic(cache_path, &entry, cancellation)
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
        && entry.timezone == config.window.timezone_name
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
        timezone: config.window.timezone_name.clone(),
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
    write_json_atomic(
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
