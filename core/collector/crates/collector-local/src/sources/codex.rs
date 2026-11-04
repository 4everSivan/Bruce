use super::{
    finish, line_may_match, number_u64, parse_json_line, scan_jsonl_file, SourceScan,
    SourceScanError,
};
use crate::cache_util::fingerprint_head_tail;
use crate::jsonl_cache::CachedUsageObservation;

/// Codex rollout 中参与聚合的行类型 (C110 解析前预筛; C190 起含单次响应记录)。
const CODEX_NEEDLES: &[&[u8]] = &[b"turn_context", b"token_count", b"token_usage_record"];

/// 头尾指纹只读的定长块 (C117): 与 jsonl 缓存的头部/尾部段大小一致。
const CODEX_FINGERPRINT_CHUNK_BYTES: u64 = 64 * 1024;
use crate::{ScanStats, MAX_DIRECTORY_SCAN_DEPTH};
use collector_domain::{CollectionWindow, UsageContributionBuilder};
use collector_runtime::CancellationToken;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::borrow::Cow;
use std::cmp::Ordering;
use std::collections::{hash_map::Entry, BTreeMap, BTreeSet, HashMap};
use std::fs;
use std::io::{self, Write};
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

/// C190: 单次响应记录行 (`type = token_usage_record`) 只取 response_id 与 usage。
#[derive(Deserialize)]
struct CodexUsageRecordLine {
    #[serde(rename = "type")]
    kind: Option<String>,
    payload: Option<CodexUsageRecord>,
}

#[derive(Deserialize)]
struct CodexUsageRecord {
    response_id: Option<String>,
    usage: Option<CodexRecordUsage>,
}

#[derive(Deserialize)]
struct CodexRecordUsage {
    input_tokens: Option<u64>,
    cached_input_tokens: Option<u64>,
    cache_read_input_tokens: Option<u64>,
    output_tokens: Option<u64>,
}

impl CodexUsageRecord {
    /// 与 `codex_token_counters` 同口径的计数; 缺 response_id 或 usage 时不登记。
    fn into_pending(self) -> Option<(String, CodexTokenCounters)> {
        let response_id = self.response_id.filter(|id| !id.is_empty())?;
        let usage = self.usage?;
        Some((
            response_id,
            CodexTokenCounters {
                input: usage.input_tokens.unwrap_or(0),
                cache_read: usage
                    .cached_input_tokens
                    .or(usage.cache_read_input_tokens)
                    .unwrap_or(0),
                output: usage.output_tokens.unwrap_or(0),
            },
        ))
    }
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
    /// 缓存身份用的整数纳秒 mtime: f64 秒经 JSON 往返会差 1 ULP (C117)。
    pub(super) modified_ns: u64,
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
        let since_epoch = metadata
            .modified()
            .ok()
            .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
            .unwrap_or_default();
        let modified = since_epoch.as_secs_f64();
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
                match fingerprint_head_tail(
                    &canonical,
                    metadata.len(),
                    CODEX_FINGERPRINT_CHUNK_BYTES,
                    cancellation,
                ) {
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
                modified_ns: since_epoch.as_nanos() as u64,
                size: metadata.len(),
                digest,
                device,
                inode,
            });
    }
    Ok(())
}

/// 同名 rollout 即同一会话 (文件名含会话 UUID)。组内按偏好排序 (size 大者优先); 与首份
/// 物理相同 (硬链接) 或内容相同 (同 size + 头尾指纹) 的副本零解析跳过, 其余副本保留,
/// 逐份解析后由 `merge_codex_copies` 按单次响应去重键取并集 (C190)。组按首份路径排序。
fn resolve_codex_files(
    groups: BTreeMap<String, Vec<CodexFileCandidate>>,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<Vec<Vec<CodexFileCandidate>>, SourceScanError> {
    let mut resolved = Vec::new();
    for (_, mut group) in groups {
        cancellation.check()?;
        sort_codex_candidates(&mut group, cancellation)?;
        let winner = group.remove(0);
        let mut members = Vec::with_capacity(1 + group.len());
        if !group.is_empty() {
            stats.duplicate_session_groups = stats.duplicate_session_groups.saturating_add(1);
            let winner_digest = match candidate_digest(&winner, cancellation) {
                Ok(digest) => Some(digest),
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => None,
            };
            for candidate in group {
                cancellation.check()?;
                // 硬链接副本 (同 dev+inode) 是同一物理文件, 零 IO 判等;
                // Orca 的 codex-accounts 与 runtime-home 即此形态, 免去 GB 级重读.
                let hard_link = winner.inode != 0
                    && candidate.inode == winner.inode
                    && candidate.device == winner.device;
                let identical = hard_link
                    || (candidate.size == winner.size
                        && match (&winner_digest, candidate_digest(&candidate, cancellation)) {
                            (_, Err(SourceScanError::Runtime(error))) => return Err(error.into()),
                            (Some(winner), Ok(digest)) => winner == &digest,
                            _ => false,
                        });
                if identical {
                    stats.duplicate_files_skipped = stats.duplicate_files_skipped.saturating_add(1);
                } else {
                    members.push(candidate);
                }
            }
        }
        members.insert(0, winner);
        resolved.push(members);
    }
    cancellation.check()?;
    resolved.sort_by(|left, right| left[0].path.cmp(&right[0].path));
    Ok(resolved)
}

fn observation_total(observation: &CachedUsageObservation) -> u64 {
    observation
        .input
        .saturating_add(observation.output)
        .saturating_add(observation.cache_read)
        .saturating_add(observation.cache_creation)
}

/// 旧版 rollout (无单次响应记录) 的回退去重键: token_count 毫秒时间戳 + 本次用量。
fn codex_signature_key(timestamp_millis: i64, input: u64, cache_read: u64, output: u64) -> String {
    format!("t:{timestamp_millis}:{input}:{cache_read}:{output}")
}

fn observation_dedupe_key(observation: &CachedUsageObservation) -> Cow<'_, str> {
    match observation.dedupe_key.as_deref() {
        Some(key) => Cow::Borrowed(key),
        None => Cow::Owned(codex_signature_key(
            observation.timestamp_millis,
            observation.input.saturating_add(observation.cache_read),
            observation.cache_read,
            observation.output,
        )),
    }
}

/// 同一会话各副本的观测按单次响应去重键取并集 (C190)。副本的共享前缀逐字节相同, 同一次
/// 响应在各副本中得到同一个键; 每个键保留该键下总量最大的那份副本的观测 —— 值一致时取
/// 偏好靠前的副本, 同一 response_id 取值不一致时取大, 不会把同一次响应计两次。
/// 返回合并后的观测 (按副本偏好、文件内原顺序) 与是否分叉: 只要有键来自首份以外的副本,
/// 或同一键在副本间取值不一致, 即为分叉; 短副本是长副本前缀时不算分叉。
fn merge_codex_copies<'a>(
    copies: &[&'a [CachedUsageObservation]],
) -> (Vec<&'a CachedUsageObservation>, bool) {
    if let [only] = copies {
        return (only.iter().collect(), false);
    }
    let mut chosen: HashMap<Cow<'a, str>, (usize, u64)> = HashMap::new();
    let mut disagreement = false;
    for (index, copy) in copies.iter().enumerate() {
        let mut totals: HashMap<Cow<'a, str>, u64> = HashMap::new();
        for observation in copy.iter() {
            let total = totals
                .entry(observation_dedupe_key(observation))
                .or_default();
            *total = total.saturating_add(observation_total(observation));
        }
        for (key, total) in totals {
            match chosen.entry(key) {
                Entry::Vacant(entry) => {
                    entry.insert((index, total));
                }
                Entry::Occupied(mut entry) => {
                    let best = entry.get().1;
                    disagreement |= best != total;
                    if total > best {
                        entry.insert((index, total));
                    }
                }
            }
        }
    }
    let diverged = disagreement || chosen.values().any(|(index, _)| *index != 0);
    let merged = copies
        .iter()
        .enumerate()
        .flat_map(|(index, copy)| {
            let chosen = &chosen;
            copy.iter().filter(move |observation| {
                chosen
                    .get(&observation_dedupe_key(observation))
                    .is_some_and(|(owner, _)| *owner == index)
            })
        })
        .collect();
    (merged, diverged)
}

fn diverged_copies_notice(groups: u64) -> String {
    format!("Codex 会话副本已分叉, 已按单次响应合并 (会话组: {groups})")
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
        None => fingerprint_head_tail(
            &candidate.path,
            candidate.size,
            CODEX_FINGERPRINT_CHUNK_BYTES,
            cancellation,
        ),
    }
}

/// Scan Codex CLI and Orca rollout JSONL files.  The quota snapshot remains a
/// provider concern; this function only builds the local token contribution.
#[cfg(test)]
pub(crate) fn scan_codex(roots: &[PathBuf], window: &CollectionWindow) -> SourceScan {
    scan_codex_with_cancellation(roots, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

#[cfg(test)]
pub(crate) fn scan_codex_with_cancellation(
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
    let groups = resolve_codex_files(groups, cancellation, &mut stats)?;
    let mut builder = UsageContributionBuilder::new(window.clone());
    scan_selected_codex(groups, window, cancellation, &mut builder, &mut stats)?;
    let mut result = finish(window, builder, stats.clone(), stats.files_scanned > 0);
    if stats.conflict_session_groups > 0 {
        result.notice = Some(diverged_copies_notice(stats.conflict_session_groups));
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

/// 观测值格式变化或 Codex 解析规则变化时必须升级, 令旧缓存整体重建。
/// v1 (C117); v2 (C190): 每条观测带单次响应去重键 (`r:<response_id>` / `t:<毫秒时间戳>`),
/// 供同会话副本取并集 —— 升版同时让 C197 前被写成空观测的条目整体重解析一次。
const CODEX_FILE_CACHE_SCHEMA: u32 = 2;

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
    /// 整数纳秒: serde_json 默认浮点解析不保证往返精确, f64 秒约 1/8 的 mtime
    /// 读回后差 1 ULP, 会让未变化的文件每轮都判为变化 (与 JSONL / SQLite 缓存同口径)。
    modified_ns: u64,
    device: u64,
    inode: u64,
    observations: Vec<CachedUsageObservation>,
}

impl CodexFileEntry {
    fn matches(&self, candidate: &CodexFileCandidate) -> bool {
        self.size == candidate.size
            && self.modified_ns == candidate.modified_ns
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
    // C190: 最近一条单次响应记录 (response_id + 用量), 由下一条用量相同的 token_count 认领。
    let mut pending_record: Option<(String, CodexTokenCounters)> = None;
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
            if line_may_match(line, &[b"token_usage_record"]) {
                // C190: Codex 0.164+ 在每个 token_count 前写一行单次响应记录, 带全局唯一的
                // response_id; 只记下, 用量仍以 token_count 为准。按需字段反序列化, 不为
                // 这类行 (每次响应一行) 构建 JSON DOM。
                if let Ok(record) = serde_json::from_slice::<CodexUsageRecordLine>(line) {
                    if record.kind.as_deref() == Some("token_usage_record") {
                        stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
                        pending_record = record.payload.and_then(CodexUsageRecord::into_pending);
                        return;
                    }
                }
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
            // C190: 单次响应去重键 —— 前一条记录用量相同时取其 response_id, 否则 (旧版
            // rollout) 取本条 token_count 的毫秒时间戳 + 本次用量; 同会话副本据此取并集。
            let dedupe_key = match pending_record.take() {
                Some((response_id, record)) if record == usage => format!("r:{response_id}"),
                other => {
                    pending_record = other;
                    codex_signature_key(timestamp, usage.input, usage.cache_read, usage.output)
                }
            };
            observations.push(CachedUsageObservation {
                dedupe_key: Some(dedupe_key),
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

#[cfg(test)]
fn scan_selected_codex(
    groups: Vec<Vec<CodexFileCandidate>>,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    builder: &mut UsageContributionBuilder,
    stats: &mut ScanStats,
) -> Result<(), SourceScanError> {
    for group in groups {
        let mut parsed = Vec::with_capacity(group.len());
        for candidate in &group {
            match parse_codex_file(candidate, window, cancellation, stats) {
                Ok(observations) => parsed.push(observations),
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                }
            }
        }
        let copies: Vec<&[CachedUsageObservation]> = parsed.iter().map(Vec::as_slice).collect();
        let (merged, diverged) = merge_codex_copies(&copies);
        if diverged {
            stats.conflict_session_groups = stats.conflict_session_groups.saturating_add(1);
        }
        for observation in merged {
            let _ = builder.record(observation.sample());
        }
    }
    Ok(())
}

/// 带按文件观测缓存的 Codex 扫描 (C117): 只重解析身份变化的文件, 跨日与改窗口长度
/// 直接复用缓存, 再按当前窗口聚合; 结果与 `scan_codex` 一致。缓存可再生, 损坏时整体重建
/// 并以信息级说明暴露 (C046)。
#[cfg(test)]
pub(crate) fn scan_codex_cached(
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
    let groups = resolve_codex_files(groups, cancellation, &mut stats)?;

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
    let mut unreadable_files = 0_u64;
    let mut builder = UsageContributionBuilder::new(window.clone());
    for group in &groups {
        let mut entries = Vec::with_capacity(group.len());
        for candidate in group {
            cancellation.check()?;
            let key = codex_path_key(&candidate.path);
            let entry = match previous.remove(&key) {
                Some(entry) if entry.matches(candidate) => {
                    stats.cache_hits = stats.cache_hits.saturating_add(1);
                    entry
                }
                stale => match parse_codex_file(candidate, window, cancellation, &mut stats) {
                    Ok(observations) => {
                        stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
                        changed = true;
                        CodexFileEntry {
                            size: candidate.size,
                            modified_ns: candidate.modified_ns,
                            device: candidate.device,
                            inode: candidate.inode,
                            observations,
                        }
                    }
                    Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                    Err(SourceScanError::Io(_)) => {
                        // C197: 打开 / 读取失败只缓存成功解析的结果 —— 不得以当前文件身份写入空条目
                        // (文件恢复可读后身份不变, 会永久命中空条目)。与 dsh 活写兜底同口径: 该路径
                        // 有旧条目时沿用其陈旧观测 (保留旧身份, 下一轮仍会重试), 没有则本轮不计入;
                        // 只计 io_errors, 不计 cache_hits / cache_rebuilds / cache_deletions。
                        stats.io_errors = stats.io_errors.saturating_add(1);
                        unreadable_files = unreadable_files.saturating_add(1);
                        match stale {
                            Some(entry) => entry,
                            None => continue,
                        }
                    }
                },
            };
            entries.push((key, entry));
        }
        // C190: 同会话各副本按单次响应去重键取并集后再并入聚合。
        let copies: Vec<&[CachedUsageObservation]> = entries
            .iter()
            .map(|(_, entry)| entry.observations.as_slice())
            .collect();
        let (merged, diverged) = merge_codex_copies(&copies);
        if diverged {
            stats.conflict_session_groups = stats.conflict_session_groups.saturating_add(1);
        }
        for observation in merged {
            let _ = builder.record(observation.sample());
        }
        files.extend(entries);
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
        notes.push(diverged_copies_notice(stats.conflict_session_groups));
    }
    if unreadable_files > 0 {
        notes.push(format!(
            "Codex 会话文件读取失败 {unreadable_files} 个, 本轮沿用上次结果或暂未计入, 下次刷新重试"
        ));
    }
    // C198: 缓存重建、副本取舍与读取失败计数都是说明, 不是故障 —— 走信息级 notice,
    // 不把 Codex 置 error。
    if !notes.is_empty() {
        result.notice = Some(notes.join("; "));
    }
    Ok(result)
}

#[cfg(test)]
pub(super) fn test_candidate(path: &Path) -> CodexFileCandidate {
    let metadata = fs::metadata(path).unwrap();
    let since_epoch = metadata
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap();
    let (device, inode) = file_identity(&metadata);
    CodexFileCandidate {
        path: path.to_owned(),
        modified: since_epoch.as_secs_f64(),
        modified_ns: since_epoch.as_nanos() as u64,
        size: metadata.len(),
        digest: None,
        device,
        inode,
    }
}

#[cfg(test)]
pub(super) fn test_parse(
    candidate: &CodexFileCandidate,
    window: &CollectionWindow,
) -> Vec<CachedUsageObservation> {
    parse_codex_file(
        candidate,
        window,
        &CancellationToken::new(),
        &mut ScanStats::default(),
    )
    .unwrap()
}
