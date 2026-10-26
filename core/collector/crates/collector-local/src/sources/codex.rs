use super::{
    finish, line_may_match, number_u64, parse_json_line, scan_jsonl_file, SourceScan,
    SourceScanError,
};
use crate::jsonl_cache::CachedUsageObservation;

/// Codex rollout 中参与聚合的行类型 (C110 解析前预筛)。
const CODEX_NEEDLES: &[&[u8]] = &[b"turn_context", b"token_count"];
use crate::{ScanStats, MAX_DIRECTORY_SCAN_DEPTH};
use collector_domain::{CollectionWindow, UsageContributionBuilder};
use collector_runtime::CancellationToken;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
struct CodexTokenCounters {
    input: u64,
    cache_read: u64,
    output: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct CodexTokenSignature {
    total: Option<CodexTokenCounters>,
    last: Option<CodexTokenCounters>,
}

fn codex_counter(value: &Value, names: &[&str]) -> u64 {
    names
        .iter()
        .find_map(|name| value.get(*name))
        .map(|value| number_u64(Some(value)))
        .unwrap_or(0)
}

fn codex_token_counters(value: Option<&Value>) -> Option<CodexTokenCounters> {
    let value = value?;
    let object = value.as_object()?;
    let has_supported_field = [
        "input_tokens",
        "cached_input_tokens",
        "cache_read_input_tokens",
        "output_tokens",
        "total_tokens",
    ]
    .iter()
    .any(|field| object.contains_key(*field));
    if !has_supported_field {
        return None;
    }
    Some(CodexTokenCounters {
        input: codex_counter(value, &["input_tokens"]),
        cache_read: codex_counter(value, &["cached_input_tokens", "cache_read_input_tokens"]),
        output: codex_counter(value, &["output_tokens"]),
    })
}

fn codex_token_signature(info: &Value) -> Option<CodexTokenSignature> {
    let total = codex_token_counters(info.get("total_token_usage"));
    let last = codex_token_counters(info.get("last_token_usage"));
    (total.is_some() || last.is_some()).then_some(CodexTokenSignature { total, last })
}

fn codex_snapshot_source(payload: &Value) -> Option<String> {
    payload
        .get("rate_limits")
        .and_then(|value| value.get("limit_id"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn codex_delta(
    previous: Option<&CodexTokenCounters>,
    current: &CodexTokenCounters,
) -> CodexTokenCounters {
    let Some(previous) = previous else {
        return *current;
    };
    CodexTokenCounters {
        input: current.input.saturating_sub(previous.input),
        cache_read: current.cache_read.saturating_sub(previous.cache_read),
        output: current.output.saturating_sub(previous.output),
    }
}

fn update_codex_high_water(high_water: &mut CodexTokenCounters, current: &CodexTokenCounters) {
    high_water.input = high_water.input.max(current.input);
    high_water.cache_read = high_water.cache_read.max(current.cache_read);
    high_water.output = high_water.output.max(current.output);
}

#[derive(Debug, Clone)]
pub(super) struct CodexFileCandidate {
    pub(super) path: PathBuf,
    pub(super) modified: f64,
    pub(super) size: u64,
    pub(super) digest: Option<String>,
    pub(super) device: u64,
    pub(super) inode: u64,
}

/// 文件物理身份 (dev, inode); 非 unix 平台回落 (0, 0) 表示不可用.
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

/// codex 文件收集的递归护栏 (C045): 深度上限 + 已访问目录 canonical 集合。
/// 与 `walk_jsonl_tree` / `jsonl_cache::visit_tree` 使用同一套判定语义,
/// 防止 symlink 环导致无限递归 (栈溢出/路径无限增长)。
#[derive(Default)]
#[cfg_attr(not(test), allow(dead_code))]
pub(super) struct CodexTreeGuard {
    visited_dirs: BTreeSet<PathBuf>,
}

pub(super) fn collect_codex_files(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    groups: &mut BTreeMap<String, Vec<CodexFileCandidate>>,
    stats: &mut ScanStats,
    guard: &mut CodexTreeGuard,
    depth: usize,
) -> Result<(), SourceScanError> {
    cancellation.check()?;
    if depth > MAX_DIRECTORY_SCAN_DEPTH {
        return Ok(());
    }
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    for entry in entries {
        cancellation.check()?;
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
            let canonical_dir = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
            if guard.visited_dirs.insert(canonical_dir) {
                collect_codex_files(
                    &path,
                    cutoff_ts,
                    cancellation,
                    groups,
                    stats,
                    guard,
                    depth + 1,
                )?;
            }
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
            .map(|value| value.as_secs_f64())
            .unwrap_or(0.0);
        if modified < cutoff_ts {
            stats.files_skipped = stats.files_skipped.saturating_add(1);
            continue;
        }

        cancellation.check()?;
        let canonical = fs::canonicalize(&path).unwrap_or(path);
        let file_name = canonical
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        let (group_key, digest) =
            if file_name.starts_with("rollout-") && file_name.ends_with(".jsonl") {
                (format!("rollout:{file_name}"), None)
            } else {
                cancellation.check()?;
                match fingerprint_file(&canonical, metadata.len(), cancellation) {
                    Ok(fingerprint) => (format!("content:{fingerprint}"), Some(fingerprint)),
                    Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                    Err(_) => {
                        stats.io_errors = stats.io_errors.saturating_add(1);
                        (format!("path:{}", canonical.display()), None)
                    }
                }
            };
        let (device, inode) = file_identity(&metadata);
        groups
            .entry(group_key)
            .or_default()
            .push(CodexFileCandidate {
                path: canonical,
                modified,
                size: metadata.len(),
                digest,
                device,
                inode,
            });
    }
    Ok(())
}

fn resolve_codex_files(
    groups: BTreeMap<String, Vec<CodexFileCandidate>>,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<Vec<CodexFileCandidate>, SourceScanError> {
    let mut selected = Vec::new();
    for (_, mut group) in groups {
        cancellation.check()?;
        sort_codex_candidates(&mut group, cancellation)?;
        let winner = group.remove(0);
        if !group.is_empty() {
            stats.duplicate_session_groups = stats.duplicate_session_groups.saturating_add(1);
            stats.duplicate_files_skipped = stats
                .duplicate_files_skipped
                .saturating_add(group.len() as u64);

            let winner_digest = candidate_digest(&winner, cancellation);
            let mut conflict = winner_digest.is_err();
            let winner_digest = winner_digest.ok();
            for candidate in &group {
                cancellation.check()?;
                // 硬链接副本 (同 dev+inode) 是同一物理文件, 零 IO 判等;
                // Orca 的 codex-accounts 与 runtime-home 即此形态, 免去 GB 级重读.
                if winner.inode != 0
                    && candidate.inode == winner.inode
                    && candidate.device == winner.device
                {
                    continue;
                }
                if candidate.size != winner.size {
                    conflict = true;
                    continue;
                }
                let digest = candidate_digest(candidate, cancellation);
                match (&winner_digest, digest) {
                    (Some(winner), Ok(candidate)) if winner == &candidate => {}
                    _ => conflict = true,
                }
            }
            if conflict {
                stats.conflict_session_groups = stats.conflict_session_groups.saturating_add(1);
            }
        }
        selected.push(winner);
    }
    sort_codex_candidates_by_path(&mut selected, cancellation)?;
    Ok(selected)
}

fn sort_codex_candidates(
    candidates: &mut [CodexFileCandidate],
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    let cancellation_error = std::cell::Cell::new(None);
    candidates.sort_by(|left, right| match cancellation.check() {
        Ok(()) => candidate_preference(left, right),
        Err(error) => {
            cancellation_error.set(Some(error));
            Ordering::Equal
        }
    });
    cancellation_error
        .get()
        .map_or(Ok(()), |error| Err(error.into()))
}

fn sort_codex_candidates_by_path(
    candidates: &mut [CodexFileCandidate],
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    let cancellation_error = std::cell::Cell::new(None);
    candidates.sort_by(|left, right| match cancellation.check() {
        Ok(()) => left.path.cmp(&right.path),
        Err(error) => {
            cancellation_error.set(Some(error));
            Ordering::Equal
        }
    });
    cancellation_error
        .get()
        .map_or(Ok(()), |error| Err(error.into()))
}

fn candidate_preference(left: &CodexFileCandidate, right: &CodexFileCandidate) -> Ordering {
    right
        .size
        .cmp(&left.size)
        .then_with(|| {
            right
                .modified
                .partial_cmp(&left.modified)
                .unwrap_or(Ordering::Equal)
        })
        .then_with(|| left.path.cmp(&right.path))
}

fn candidate_digest(
    candidate: &CodexFileCandidate,
    cancellation: &CancellationToken,
) -> Result<String, SourceScanError> {
    cancellation.check()?;
    match &candidate.digest {
        Some(digest) => Ok(digest.clone()),
        None => fingerprint_file(&candidate.path, candidate.size, cancellation),
    }
}

/// 头尾指纹: 首 64KB + 末 64KB + size 的 SHA-256.
/// 代替全文件哈希做副本判等 — GB 级 rollout 每轮刷新全量重读会让采集
/// 卡在分钟级; 指纹只读固定量字节. 同头同尾同长但中段不同的极端构造
/// 会被误判为相同副本 (可接受: 仍只计一次用量, 不会重复计数).
fn fingerprint_file(
    path: &Path,
    size: u64,
    cancellation: &CancellationToken,
) -> Result<String, SourceScanError> {
    const CHUNK: u64 = 64 * 1024;
    cancellation.check()?;
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    hasher.update(size.to_le_bytes());
    let mut buffer = vec![0u8; CHUNK as usize];
    // 头部块 (整文件不足一块时即全部内容).
    let head_len = io::Read::by_ref(&mut file).take(CHUNK).read(&mut buffer)?;
    hasher.update(&buffer[..head_len]);
    // 中段存在时直接 seek 到末块前读取, 不重读中段.
    if size > CHUNK {
        cancellation.check()?;
        file.seek(io::SeekFrom::Start(size - CHUNK))?;
        let mut tail = Vec::with_capacity(CHUNK as usize);
        io::Read::by_ref(&mut file)
            .take(CHUNK)
            .read_to_end(&mut tail)?;
        hasher.update(&tail);
    }
    cancellation.check()?;
    Ok(format!("{:x}", hasher.finalize()))
}

/// Scan Codex CLI and Orca rollout JSONL files.  The quota snapshot remains a
/// provider concern; this function only builds the local token contribution.
pub fn scan_codex(roots: &[PathBuf], window: &CollectionWindow) -> SourceScan {
    scan_codex_with_cancellation(roots, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_codex_with_cancellation(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut stats = ScanStats::default();
    let mut groups = BTreeMap::<String, Vec<CodexFileCandidate>>::new();
    for root in roots {
        let mut guard = CodexTreeGuard::default();
        match collect_codex_files(
            root,
            window.cutoff_ts,
            cancellation,
            &mut groups,
            &mut stats,
            &mut guard,
            0,
        ) {
            Ok(()) => {}
            Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            Err(SourceScanError::Io(_)) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
            }
        }
    }
    let selected = resolve_codex_files(groups, cancellation, &mut stats)?;
    let mut builder = UsageContributionBuilder::new(window.clone());
    scan_selected_codex(selected, window, cancellation, &mut builder, &mut stats)?;
    let mut result = finish(window, builder, stats.clone(), stats.files_scanned > 0);
    if stats.conflict_session_groups > 0 {
        result.diagnostic = Some(format!(
            "Codex 会话副本内容冲突, 已保守选择单份文件 (冲突组: {})",
            stats.conflict_session_groups
        ));
    }
    Ok(result)
}

// ---- Codex 按文件观测缓存 (C117) ----
//
// Codex rollout 文件是 append-only: 同一 (path, size, mtime, dev, inode) 身份即同一内容。
// 每个选中文件缓存其解析出的、与窗口无关的用量观测; 下次刷新只重解析身份变化的文件
// (通常只有正在进行的会话), 其余直接复用, 再按当前窗口聚合。
// 旧实现以整树身份签名 + 按窗口聚合的快照为缓存: 任一文件追加、跨日或改窗口长度都会
// 让整树重读, 且每轮都要为全部候选文件读取头尾指纹来计算签名。

/// v1 (C117): 观测值格式变化或 Codex 解析规则变化时必须升级, 令旧缓存整体重建。
const CODEX_FILE_CACHE_SCHEMA: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct CodexFileCache {
    schema_version: u32,
    /// 解析无时区时间戳所用的时区; 天数 / today 不进身份。
    timezone: String,
    files: BTreeMap<String, CodexFileEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct CodexFileEntry {
    size: u64,
    modified: f64,
    device: u64,
    inode: u64,
    observations: Vec<CachedUsageObservation>,
}

impl CodexFileEntry {
    fn matches(&self, candidate: &CodexFileCandidate) -> bool {
        self.size == candidate.size
            && self.modified == candidate.modified
            && self.device == candidate.device
            && self.inode == candidate.inode
    }
}

fn codex_file_cache_path(cache_root: &Path) -> PathBuf {
    cache_root.join("codex-files-v1.json")
}

/// C117 前的整树缓存文件, 迁移后删除。
fn legacy_codex_tree_cache_path(cache_root: &Path) -> PathBuf {
    cache_root.join("codex-tree-v1.json")
}

fn codex_path_key(path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-codex-file-v1\0");
    hasher.update(path.to_string_lossy().as_bytes());
    format!("{:x}", hasher.finalize())
}

enum CodexCacheLoad {
    Missing,
    Corrupt,
    Loaded(CodexFileCache),
}

fn load_codex_file_cache(path: &Path) -> CodexCacheLoad {
    match fs::read(path) {
        Ok(data) => match serde_json::from_slice(&data) {
            Ok(cache) => CodexCacheLoad::Loaded(cache),
            Err(_) => CodexCacheLoad::Corrupt,
        },
        Err(error) if error.kind() == io::ErrorKind::NotFound => CodexCacheLoad::Missing,
        Err(_) => CodexCacheLoad::Corrupt,
    }
}

fn write_codex_file_cache(
    path: &Path,
    cache: &CodexFileCache,
    cancellation: &CancellationToken,
) -> Result<(), SourceScanError> {
    cancellation.check()?;
    let Some(parent) = path.parent() else {
        return Ok(());
    };
    let _ = fs::create_dir_all(parent);
    let temporary = parent.join(format!(
        ".codex-files-v1.tmp-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let written = (|| -> io::Result<()> {
        // C047: create_new + 显式 0600; C110: 序列化到内存后一次写入。
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        let mut file = options.open(&temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        let mut bytes = serde_json::to_vec(cache)?;
        bytes.push(b'\n');
        file.write_all(&bytes)?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    cancellation.check()?;
    // 缓存可再生: 写盘失败只影响下一轮命中率, 不影响本轮结果。
    Ok(())
}

/// 解析一个 Codex rollout 文件为与窗口无关的用量观测 (C117: 供按文件缓存复用)。
///
/// 解析状态 (当前模型、累计高水位、重放快照去重) 只在单个文件内有效, 故文件一旦变化
/// 即整文件重解析; 时区仅用于无时区时间戳。
fn parse_codex_file(
    candidate: &CodexFileCandidate,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<Vec<CachedUsageObservation>, SourceScanError> {
    cancellation.check()?;
    let mut current_model: Option<String> = None;
    let mut total_high_water: Option<CodexTokenCounters> = None;
    let mut last_signature_by_source = BTreeMap::<Option<String>, CodexTokenSignature>::new();
    let mut previous_token_signature: Option<CodexTokenSignature> = None;
    let mut observations = Vec::new();
    scan_jsonl_file(
        &candidate.path,
        candidate.modified,
        cancellation,
        &mut |_, _, line, stats| {
            // C110: 只有 turn_context (模型) 与 token_count (用量) 行参与聚合
            if !line_may_match(line, CODEX_NEEDLES) {
                stats.ignored_lines = stats.ignored_lines.saturating_add(1);
                return;
            }
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
            if value.get("type").and_then(Value::as_str) == Some("turn_context") {
                if let Some(model) = value
                    .get("payload")
                    .and_then(|payload| {
                        payload
                            .get("model")
                            .or_else(|| payload.get("info").and_then(|info| info.get("model")))
                    })
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|model| !model.is_empty())
                {
                    current_model = Some(model.to_owned());
                }
                return;
            }
            if value
                .get("payload")
                .and_then(|value| value.get("type"))
                .and_then(Value::as_str)
                != Some("token_count")
            {
                return;
            }
            let Some(timestamp) = value
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(|value| window.epoch_from_iso(value))
                .map(|value| value.saturating_mul(1000))
            else {
                return;
            };
            let payload = value.get("payload").unwrap_or(&Value::Null);
            let info = payload.get("info").unwrap_or(&Value::Null);
            let model = info
                .get("model")
                .and_then(Value::as_str)
                .or_else(|| info.get("model_name").and_then(Value::as_str))
                .or_else(|| payload.get("model").and_then(Value::as_str))
                .or_else(|| value.get("model").and_then(Value::as_str));
            if let Some(model) = model.map(str::trim).filter(|model| !model.is_empty()) {
                current_model = Some(model.to_owned());
            }
            let Some(signature) = codex_token_signature(info) else {
                return;
            };
            let snapshot_source = codex_snapshot_source(payload);
            let duplicate_snapshot = signature.total.is_some()
                && (last_signature_by_source.get(&snapshot_source) == Some(&signature)
                    || previous_token_signature.as_ref() == Some(&signature));
            if signature.total.is_some() {
                last_signature_by_source.insert(snapshot_source, signature.clone());
            }
            previous_token_signature = Some(signature.clone());
            let usage = if duplicate_snapshot {
                CodexTokenCounters {
                    input: 0,
                    cache_read: 0,
                    output: 0,
                }
            } else if let Some(last) = signature.last {
                last
            } else if let Some(total) = signature.total {
                codex_delta(total_high_water.as_ref(), &total)
            } else {
                return;
            };
            if let Some(total) = signature.total.as_ref() {
                if let Some(high_water) = total_high_water.as_mut() {
                    update_codex_high_water(high_water, total);
                } else {
                    total_high_water = Some(*total);
                }
            }
            if usage.input == 0 && usage.cache_read == 0 && usage.output == 0 {
                return;
            }
            observations.push(CachedUsageObservation {
                dedupe_key: None,
                timestamp_millis: timestamp,
                model: current_model.clone(),
                input: usage.input.saturating_sub(usage.cache_read),
                output: usage.output,
                cache_read: usage.cache_read,
                cache_creation: 0,
                cache_creation_1h: 0,
                project: None,
            });
            stats.usage_records = stats.usage_records.saturating_add(1);
        },
        stats,
        #[cfg(test)]
        &mut None,
    )?;
    Ok(observations)
}

fn scan_selected_codex(
    selected: Vec<CodexFileCandidate>,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    builder: &mut UsageContributionBuilder,
    stats: &mut ScanStats,
) -> Result<(), SourceScanError> {
    for candidate in selected {
        match parse_codex_file(&candidate, window, cancellation, stats) {
            Ok(observations) => {
                for observation in &observations {
                    let _ = builder.record(observation.sample());
                }
            }
            Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            Err(SourceScanError::Io(_)) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
            }
        }
    }
    Ok(())
}

/// 带按文件观测缓存的 Codex 扫描 (C117): 只重解析身份变化的文件, 跨日与改窗口长度
/// 直接复用缓存, 再按当前窗口聚合; 结果与 `scan_codex` 一致。缓存可再生, 损坏时整体重建
/// 并以信息级说明暴露 (C046)。
pub fn scan_codex_cached(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cache_root: &Path,
) -> SourceScan {
    scan_codex_cached_with_cancellation(roots, window, cache_root, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_codex_cached_with_cancellation(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut stats = ScanStats::default();
    let mut groups = BTreeMap::<String, Vec<CodexFileCandidate>>::new();
    for root in roots {
        let mut guard = CodexTreeGuard::default();
        match collect_codex_files(
            root,
            window.cutoff_ts,
            cancellation,
            &mut groups,
            &mut stats,
            &mut guard,
            0,
        ) {
            Ok(()) => {}
            Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            Err(SourceScanError::Io(_)) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
            }
        }
    }
    cancellation.check()?;
    let has_selected_codex_files = groups.values().any(|candidates| !candidates.is_empty());
    let selected = resolve_codex_files(groups, cancellation, &mut stats)?;

    let cache_path = codex_file_cache_path(cache_root);
    let mut previous = match load_codex_file_cache(&cache_path) {
        CodexCacheLoad::Loaded(cache)
            if cache.schema_version == CODEX_FILE_CACHE_SCHEMA
                && cache.timezone == window.timezone_name =>
        {
            cache.files
        }
        CodexCacheLoad::Loaded(_) => {
            stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
            BTreeMap::new()
        }
        CodexCacheLoad::Corrupt => {
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
            BTreeMap::new()
        }
        CodexCacheLoad::Missing => BTreeMap::new(),
    };
    let previous_count = previous.len();
    let mut files = BTreeMap::new();
    let mut changed = false;
    let mut builder = UsageContributionBuilder::new(window.clone());
    for candidate in &selected {
        cancellation.check()?;
        let key = codex_path_key(&candidate.path);
        let entry = match previous.remove(&key) {
            Some(entry) if entry.matches(candidate) => {
                stats.cache_hits = stats.cache_hits.saturating_add(1);
                entry
            }
            _ => match parse_codex_file(candidate, window, cancellation, &mut stats) {
                Ok(observations) => {
                    stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
                    changed = true;
                    CodexFileEntry {
                        size: candidate.size,
                        modified: candidate.modified,
                        device: candidate.device,
                        inode: candidate.inode,
                        observations,
                    }
                }
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                    continue;
                }
            },
        };
        for observation in &entry.observations {
            let _ = builder.record(observation.sample());
        }
        files.insert(key, entry);
    }
    // 未再被选中的文件 (删除 / 移出窗口 / 副本落选) 从缓存移除
    let removed = previous.len() as u64;
    stats.cache_deletions = stats.cache_deletions.saturating_add(removed);
    if changed || removed > 0 || files.len() != previous_count {
        let cache = CodexFileCache {
            schema_version: CODEX_FILE_CACHE_SCHEMA,
            timezone: window.timezone_name.clone(),
            files,
        };
        write_codex_file_cache(&cache_path, &cache, cancellation)?;
    }
    let _ = fs::remove_file(legacy_codex_tree_cache_path(cache_root));
    cancellation.check()?;

    let mut result = finish(window, builder, stats.clone(), has_selected_codex_files);
    let mut notes: Vec<String> = Vec::new();
    if stats.cache_corruptions > 0 {
        notes.push("Codex 缓存文件格式异常, 已整体重建".to_owned());
    }
    if stats.conflict_session_groups > 0 {
        notes.push(format!(
            "Codex 会话副本内容冲突, 已保守选择单份文件 (冲突组: {})",
            stats.conflict_session_groups
        ));
    }
    if !notes.is_empty() {
        result.diagnostic = Some(notes.join("; "));
    }
    Ok(result)
}
