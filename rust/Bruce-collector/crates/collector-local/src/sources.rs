//! Agent-specific local session and usage sources.
//!
//! The cache-backed Kimi JSONL adapter remains in `lib.rs`.  This module owns
//! the other read-only sources that make up the existing agent-usage contract:
//! Claude, Codex, Grok, Pi, OpenCode, and ZCode.  It returns only derived
//! contributions and bounded diagnostics; raw lines and database payloads do
//! not cross this module boundary.

use super::{read_bounded_line, trim_line_end, ScanStats};
use collector_domain::{
    CollectionWindow, UsageContribution, UsageContributionBuilder, UsageSample,
};
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::cmp::Ordering;
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, BufReader, Read, Seek};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const MAX_SOURCE_ROWS: i64 = 10_000;

#[derive(Debug, Clone)]
pub struct SourceScan {
    pub found: bool,
    pub contribution: UsageContribution,
    pub stats: ScanStats,
    pub diagnostic: Option<String>,
}

impl SourceScan {
    fn empty(window: &CollectionWindow) -> Self {
        Self {
            found: false,
            contribution: UsageContributionBuilder::new(window.clone()).contribution(),
            stats: ScanStats::default(),
            diagnostic: None,
        }
    }
}

fn finish(
    _window: &CollectionWindow,
    builder: UsageContributionBuilder,
    stats: ScanStats,
    found: bool,
) -> SourceScan {
    SourceScan {
        found,
        contribution: builder.contribution(),
        stats,
        diagnostic: None,
    }
}

fn timestamp_number(value: Option<&Value>) -> Option<i64> {
    value
        .and_then(Value::as_i64)
        .or_else(|| {
            value
                .and_then(Value::as_u64)
                .and_then(|value| i64::try_from(value).ok())
        })
        .or_else(|| {
            value
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite())
                .map(|value| value as i64)
        })
}

fn number_u64(value: Option<&Value>) -> u64 {
    value
        .and_then(Value::as_u64)
        .or_else(|| {
            value
                .and_then(Value::as_i64)
                .and_then(|value| u64::try_from(value).ok())
        })
        .or_else(|| {
            value
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite() && *value >= 0.0)
                .map(|value| value as u64)
        })
        .unwrap_or(0)
}

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

fn parse_json_line(line: &[u8], stats: &mut ScanStats) -> Option<Value> {
    match serde_json::from_slice(line) {
        Ok(value) => {
            stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
            Some(value)
        }
        Err(_) => {
            stats.malformed_lines = stats.malformed_lines.saturating_add(1);
            None
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn record(
    builder: &mut UsageContributionBuilder,
    timestamp_millis: i64,
    model: Option<&str>,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    project: Option<&str>,
) {
    let _ = builder.record(UsageSample {
        timestamp_millis,
        model,
        input,
        output,
        cache_read,
        cache_creation,
        project,
    });
}

fn project_from_parent(path: &Path) -> Option<String> {
    path.parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn project_from_zcode(value: Option<String>, task_type: Option<String>) -> Option<String> {
    let mut project = value.and_then(|value| {
        Path::new(&value)
            .file_name()
            .and_then(|name| name.to_str())
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
    });
    if task_type.as_deref() == Some("subagent_child") {
        if let Some(name) = project.as_mut() {
            name.push_str(" ·子代理");
        }
    }
    project
}

fn scan_jsonl_tree<F>(root: &Path, cutoff_ts: f64, mut callback: F) -> io::Result<ScanStats>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
    let mut stats = ScanStats::default();
    walk_jsonl_tree(root, cutoff_ts, &mut callback, &mut stats)?;
    Ok(stats)
}

fn walk_jsonl_tree<F>(
    root: &Path,
    cutoff_ts: f64,
    callback: &mut F,
    stats: &mut ScanStats,
) -> io::Result<()>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
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
            walk_jsonl_tree(&path, cutoff_ts, callback, stats)?;
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
        scan_jsonl_file(&path, modified, callback, stats)?;
    }
    Ok(())
}

fn scan_jsonl_file<F>(
    path: &Path,
    modified: f64,
    callback: &mut F,
    stats: &mut ScanStats,
) -> io::Result<()>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
    stats.files_scanned = stats.files_scanned.saturating_add(1);
    let file = match File::open(path) {
        Ok(file) => file,
        Err(_) => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            return Ok(());
        }
    };
    let mut reader = BufReader::new(file);
    while let Some(line) = read_bounded_line(&mut reader, super::MAX_JSONL_RECORD_BYTES)? {
        stats.lines_seen = stats.lines_seen.saturating_add(1);
        stats.bytes_read = stats.bytes_read.saturating_add(line.bytes as u64);
        if line.truncated {
            stats.truncated_lines = stats.truncated_lines.saturating_add(1);
            continue;
        }
        let line = trim_line_end(&line.bytes_data);
        if line.is_empty() {
            continue;
        }
        callback(path, modified, line, stats);
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct CodexFileCandidate {
    path: PathBuf,
    modified: f64,
    size: u64,
    digest: Option<String>,
    device: u64,
    inode: u64,
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

fn collect_codex_files(
    root: &Path,
    cutoff_ts: f64,
    groups: &mut BTreeMap<String, Vec<CodexFileCandidate>>,
    stats: &mut ScanStats,
) -> io::Result<()> {
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
            collect_codex_files(&path, cutoff_ts, groups, stats)?;
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

        let canonical = fs::canonicalize(&path).unwrap_or(path);
        let file_name = canonical
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or_default();
        let (group_key, digest) =
            if file_name.starts_with("rollout-") && file_name.ends_with(".jsonl") {
                (format!("rollout:{file_name}"), None)
            } else {
                match fingerprint_file(&canonical, metadata.len()) {
                    Ok(fingerprint) => (format!("content:{fingerprint}"), Some(fingerprint)),
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
    stats: &mut ScanStats,
) -> Vec<CodexFileCandidate> {
    let mut selected = Vec::new();
    for (_, mut group) in groups {
        group.sort_by(candidate_preference);
        let winner = group.remove(0);
        if !group.is_empty() {
            stats.duplicate_session_groups = stats.duplicate_session_groups.saturating_add(1);
            stats.duplicate_files_skipped = stats
                .duplicate_files_skipped
                .saturating_add(group.len() as u64);

            let winner_digest = candidate_digest(&winner);
            let mut conflict = winner_digest.is_err();
            let winner_digest = winner_digest.ok();
            for candidate in &group {
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
                let digest = candidate_digest(candidate);
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
    selected.sort_by(|left, right| left.path.cmp(&right.path));
    selected
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

fn candidate_digest(candidate: &CodexFileCandidate) -> io::Result<String> {
    match &candidate.digest {
        Some(digest) => Ok(digest.clone()),
        None => fingerprint_file(&candidate.path, candidate.size),
    }
}

/// 头尾指纹: 首 64KB + 末 64KB + size 的 SHA-256.
/// 代替全文件哈希做副本判等 — GB 级 rollout 每轮刷新全量重读会让采集
/// 卡在分钟级; 指纹只读固定量字节. 同头同尾同长但中段不同的极端构造
/// 会被误判为相同副本 (可接受: 仍只计一次用量, 不会重复计数).
fn fingerprint_file(path: &Path, size: u64) -> io::Result<String> {
    const CHUNK: u64 = 64 * 1024;
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    hasher.update(size.to_le_bytes());
    let mut buffer = vec![0u8; CHUNK as usize];
    // 头部块 (整文件不足一块时即全部内容).
    let head_len = file.by_ref().take(CHUNK).read(&mut buffer)?;
    hasher.update(&buffer[..head_len]);
    // 中段存在时直接 seek 到末块前读取, 不重读中段.
    if size > CHUNK {
        file.seek(io::SeekFrom::Start(size - CHUNK))?;
        let mut tail = Vec::with_capacity(CHUNK as usize);
        file.by_ref().take(CHUNK).read_to_end(&mut tail)?;
        hasher.update(&tail);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Scan a Kimi Work or Kimi Code JSONL tree without the Kimi-specific cache.
/// Kimi Code's primary path continues to use the cache-backed scanner in the
/// parent module; this function is used for Kimi Work and source parity tests.
pub fn scan_kimi_tree(root: &Path, window: &CollectionWindow) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let stats = scan_jsonl_tree(root, window.cutoff_ts, |_, _, line, stats| {
        let Some(value) = parse_json_line(line, stats) else {
            return;
        };
        if value.get("type").and_then(Value::as_str) != Some("usage.record") {
            stats.ignored_lines = stats.ignored_lines.saturating_add(1);
            return;
        }
        let Some(timestamp) = timestamp_number(value.get("time")) else {
            stats.malformed_lines = stats.malformed_lines.saturating_add(1);
            return;
        };
        let usage = value.get("usage");
        record(
            &mut builder,
            timestamp,
            value.get("model").and_then(Value::as_str),
            number_u64(usage.and_then(|value| value.get("inputOther"))),
            number_u64(usage.and_then(|value| value.get("output"))),
            number_u64(usage.and_then(|value| value.get("inputCacheRead"))),
            number_u64(usage.and_then(|value| value.get("inputCacheCreation"))),
            None,
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    })
    .unwrap_or_else(|_| ScanStats::default());
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
}

#[derive(Debug, Clone, Default)]
struct ClaudeUsage {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    timestamp_millis: i64,
    model: Option<String>,
    project: Option<String>,
}

/// Scan Claude Code assistant messages, coalescing repeated writes of one
/// message id so an in-progress skeleton is not counted as real usage.
pub fn scan_claude(root: &Path, window: &CollectionWindow) -> SourceScan {
    let mut best = BTreeMap::<String, ClaudeUsage>::new();
    let mut direct = Vec::<ClaudeUsage>::new();
    let stats = scan_jsonl_tree(root, window.cutoff_ts, |path, _, line, stats| {
        let Some(value) = parse_json_line(line, stats) else {
            return;
        };
        if value.get("type").and_then(Value::as_str) != Some("assistant") {
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
        let message = value.get("message").unwrap_or(&Value::Null);
        let usage = message.get("usage").unwrap_or(&Value::Null);
        let project = project_from_parent(path).map(|mut project| {
            if path
                .components()
                .any(|part| part.as_os_str() == "subagents")
            {
                project.push_str(" ·子代理");
            }
            project
        });
        let usage = ClaudeUsage {
            input: number_u64(usage.get("input_tokens")),
            output: number_u64(usage.get("output_tokens")),
            cache_read: number_u64(usage.get("cache_read_input_tokens")),
            cache_creation: number_u64(usage.get("cache_creation_input_tokens")),
            timestamp_millis: timestamp,
            model: message
                .get("model")
                .and_then(Value::as_str)
                .map(str::to_owned),
            project,
        };
        let id = message.get("id").and_then(Value::as_str);
        if let Some(id) = id {
            let entry = best.entry(id.to_owned()).or_default();
            entry.input = entry.input.max(usage.input);
            entry.output = entry.output.max(usage.output);
            entry.cache_read = entry.cache_read.max(usage.cache_read);
            entry.cache_creation = entry.cache_creation.max(usage.cache_creation);
            entry.timestamp_millis = usage.timestamp_millis;
            entry.model = usage.model;
            entry.project = usage.project;
        } else {
            direct.push(usage);
        }
        stats.usage_records = stats.usage_records.saturating_add(1);
    })
    .unwrap_or_else(|_| ScanStats::default());
    let mut builder = UsageContributionBuilder::new(window.clone());
    for usage in best.into_values().chain(direct) {
        record(
            &mut builder,
            usage.timestamp_millis,
            usage.model.as_deref(),
            usage.input,
            usage.output,
            usage.cache_read,
            usage.cache_creation,
            usage.project.as_deref(),
        );
    }
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
}

#[derive(Debug, Clone, Default)]
struct CodeBuddyUsage {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    timestamp_millis: i64,
    model: Option<String>,
    project: Option<String>,
}

impl CodeBuddyUsage {
    fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
    }
}

fn codebuddy_provider_data(value: &Value) -> Option<&Value> {
    value
        .get("providerData")
        .or_else(|| value.get("provider_data"))
}

fn codebuddy_number(value: &Value) -> Option<u64> {
    value
        .as_u64()
        .or_else(|| value.as_i64().and_then(|value| u64::try_from(value).ok()))
        .or_else(|| {
            value
                .as_f64()
                .filter(|value| value.is_finite() && *value >= 0.0)
                .map(|value| value as u64)
        })
}

fn codebuddy_first_number(value: &Value, names: &[&str]) -> Option<u64> {
    names
        .iter()
        .find_map(|name| value.get(*name).and_then(codebuddy_number))
}

/// 返回字段列表中首个大于 0 的值; 全部缺失或为 0 时返回 None.
///
/// 不返回 `Some(0)` 兜底: 那会阻断调用方 `.or_else` 的嵌套回退
/// (扁平字段存在但为 0 时, 嵌套对象里的正值缓存明细会被丢弃).
fn codebuddy_first_positive_number(value: &Value, names: &[&str]) -> Option<u64> {
    names
        .iter()
        .filter_map(|name| value.get(*name).and_then(codebuddy_number))
        .find(|number| *number > 0)
}

fn codebuddy_nested_number(
    value: &Value,
    object_names: &[&str],
    field_names: &[&str],
) -> Option<u64> {
    object_names.iter().find_map(|object_name| {
        value
            .get(*object_name)
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_first_number(candidate, field_names))
    })
}

fn codebuddy_nested_positive_number(
    value: &Value,
    object_names: &[&str],
    field_names: &[&str],
) -> Option<u64> {
    object_names.iter().find_map(|object_name| {
        value
            .get(*object_name)
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_first_positive_number(candidate, field_names))
    })
}

/// `codebuddy_usage_fields` 的解析结果.
struct CodeBuddyUsageFields {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    /// input 是否尚未做过缓存扣减 (cache_miss 缺失时 input 仍为缓存含值口径).
    input_cache_inclusive: bool,
}

/// Return pure input, output, cache-read and cache-write counts.
///
/// CodeBuddy's `message.usage` is normalized and its `input_tokens` includes
/// cache reads. `providerData.rawUsage` follows the provider naming and may
/// expose cache hit/miss/write counts directly. Prefer raw usage whenever it
/// is available because it preserves the provider's split instead of making
/// assumptions about a normalized total.
///
/// Reasoning/thinking tokens are NOT added on top of completion output:
/// provider `completion_tokens` already includes them (verified against local
/// rollouts where `total_tokens == prompt_tokens + completion_tokens` while
/// `completion_thinking_tokens` > 0), so an additive fold would double count.
fn codebuddy_usage_fields(value: &Value, raw: bool) -> Option<CodeBuddyUsageFields> {
    let cache_read = codebuddy_first_positive_number(
        value,
        &[
            "cache_read_input_tokens",
            "cacheReadInputTokens",
            "cache_read_tokens",
            "cacheReadTokens",
            "prompt_cache_hit_tokens",
            "promptCacheHitTokens",
            "prompt_cache_hit",
            "cached_tokens",
            "cachedTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_positive_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cached_tokens",
                "cachedTokens",
                "cache_read_tokens",
                "cacheReadTokens",
            ],
        )
    })
    .unwrap_or(0);
    let cache_creation = codebuddy_first_positive_number(
        value,
        &[
            "cache_creation_input_tokens",
            "cacheCreationInputTokens",
            "cache_creation_tokens",
            "cacheCreationTokens",
            "prompt_cache_write_tokens",
            "promptCacheWriteTokens",
            "prompt_cache_write",
            "cache_write_tokens",
            "cacheWriteTokens",
            "cached_write_tokens",
            "cachedWriteTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_positive_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cache_write_tokens",
                "cacheWriteTokens",
                "cached_write_tokens",
                "cachedWriteTokens",
            ],
        )
    })
    .unwrap_or(0);
    let reported_input = codebuddy_first_number(
        value,
        &[
            "input_tokens",
            "inputTokens",
            "prompt_tokens",
            "promptTokens",
        ],
    );
    let cache_miss = codebuddy_first_number(
        value,
        &[
            "prompt_cache_miss_tokens",
            "promptCacheMissTokens",
            "cached_miss_tokens",
            "cachedMissTokens",
            "cache_miss_tokens",
            "cacheMissTokens",
        ],
    )
    .or_else(|| {
        codebuddy_nested_number(
            value,
            &["prompt_tokens_details", "promptTokensDetails"],
            &[
                "cache_miss_tokens",
                "cacheMissTokens",
                "cached_miss_tokens",
                "cachedMissTokens",
                "uncached_tokens",
                "uncachedTokens",
            ],
        )
    });
    let output = codebuddy_first_number(
        value,
        &[
            "output_tokens",
            "outputTokens",
            "completion_tokens",
            "completionTokens",
        ],
    );

    if reported_input.is_none()
        && cache_miss.is_none()
        && output.is_none()
        && cache_read == 0
        && cache_creation == 0
    {
        return None;
    }

    let input = cache_miss.unwrap_or_else(|| {
        let reported = reported_input.unwrap_or(0);
        if raw {
            reported
                .saturating_sub(cache_read)
                .saturating_sub(cache_creation)
        } else {
            // message.usage.input_tokens is cache-inclusive. The normalized
            // CodeBuddy shape does not report cache writes separately, so a
            // cache-read subtraction preserves the established project
            // contract for that shape.
            reported.saturating_sub(cache_read)
        }
    });
    // completion/reasoning 明细不再叠加: completion_tokens 已含 reasoning,
    // 叠加会对 thinking 部分双计数 (见函数注释与本机数据验证).
    Some(CodeBuddyUsageFields {
        input,
        output: output.unwrap_or(0),
        cache_read,
        cache_creation,
        input_cache_inclusive: cache_miss.is_none(),
    })
}

fn codebuddy_usage(value: &Value) -> Option<(u64, u64, u64, u64)> {
    let provider = codebuddy_provider_data(value);
    let message = value.get("message");
    let candidates = [
        (
            provider.and_then(|provider| {
                provider
                    .get("rawUsage")
                    .or_else(|| provider.get("raw_usage"))
            }),
            true,
        ),
        (provider.and_then(|provider| provider.get("usage")), false),
        (message.and_then(|message| message.get("usage")), false),
        (value.get("usage"), false),
    ];
    let mut parsed = candidates.into_iter().filter_map(|(candidate, raw)| {
        candidate
            .filter(|candidate| candidate.is_object())
            .and_then(|candidate| codebuddy_usage_fields(candidate, raw))
    });
    let mut primary = parsed.next()?;
    // 首选候选缺缓存明细时 (rawUsage 常缺 prompt_tokens_details), 用后续
    // 归一化候选补齐缓存拆分; 此时 primary 的 input 仍是缓存含值口径, 需同步
    // 扣减, 保证 input + cache_read + cache_creation 与总量守恒.
    if primary.cache_read == 0 && primary.cache_creation == 0 {
        for extra in parsed {
            if extra.cache_read == 0 && extra.cache_creation == 0 {
                continue;
            }
            if primary.input_cache_inclusive {
                primary.input = primary
                    .input
                    .saturating_sub(extra.cache_read)
                    .saturating_sub(extra.cache_creation);
            }
            primary.cache_read = extra.cache_read;
            primary.cache_creation = extra.cache_creation;
            break;
        }
    }
    Some((
        primary.input,
        primary.output,
        primary.cache_read,
        primary.cache_creation,
    ))
}

fn codebuddy_string(value: Option<&Value>, names: &[&str]) -> Option<String> {
    names.iter().find_map(|name| {
        value
            .and_then(|value| value.get(*name))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    })
}

fn codebuddy_model(value: &Value) -> Option<String> {
    let provider = codebuddy_provider_data(value);
    codebuddy_string(provider, &["model", "modelId", "model_id"])
        .or_else(|| codebuddy_string(provider, &["requestModelId", "request_model_id"]))
        .or_else(|| codebuddy_string(value.get("message"), &["model", "modelId", "model_id"]))
        .or_else(|| codebuddy_string(Some(value), &["model", "modelId", "model_id"]))
}

fn codebuddy_message_id(value: &Value) -> Option<String> {
    let provider = codebuddy_provider_data(value);
    codebuddy_string(
        provider,
        &["messageId", "message_id", "traceId", "trace_id"],
    )
    .or_else(|| codebuddy_string(Some(value), &["messageId", "message_id"]))
    .or_else(|| codebuddy_string(value.get("message"), &["id", "messageId", "message_id"]))
    .or_else(|| codebuddy_string(Some(value), &["id"]))
}

fn codebuddy_scope(path: &Path, value: &Value) -> String {
    let project = path
        .parent()
        .map(|parent| parent.to_string_lossy().into_owned())
        .unwrap_or_default();
    let session = codebuddy_string(
        Some(value),
        &[
            "sessionId",
            "session_id",
            "conversationId",
            "conversation_id",
        ],
    )
    .or_else(|| {
        codebuddy_string(
            codebuddy_provider_data(value),
            &[
                "sessionId",
                "session_id",
                "conversationId",
                "conversation_id",
            ],
        )
    });
    match session {
        Some(session) => format!("{project}::{session}"),
        None => path.to_string_lossy().into_owned(),
    }
}

/// Scan CodeBuddy CLI conversation trees (`~/.codebuddy/projects`).
///
/// Layout mirrors Claude Code: `<path-encoded-project>/<session>.jsonl`, one
/// record per line. Normalized assistant messages and provider function-call
/// records are accepted. Usage is read from `providerData.rawUsage` first,
/// then `providerData.usage`, `message.usage`, and top-level `usage`; model
/// names and IDs use the corresponding provider/message fallbacks. Rewrites
/// of one message are selected as complete snapshots by total token count and
/// deduplicated within a project/session scope. System task summaries that
/// expose only `usage.total_tokens` are intentionally ignored because the
/// artifact has no unattributed-token bucket and child records are the
/// decomposable source of truth.
pub fn scan_codebuddy(root: &Path, window: &CollectionWindow) -> SourceScan {
    let mut best = BTreeMap::<String, CodeBuddyUsage>::new();
    let mut direct = Vec::<CodeBuddyUsage>::new();
    let stats = scan_jsonl_tree(root, window.cutoff_ts, |path, _, line, stats| {
        let Some(value) = parse_json_line(line, stats) else {
            return;
        };
        let record_type = value.get("type").and_then(Value::as_str);
        if record_type != Some("message") && record_type != Some("function_call") {
            return;
        }
        if record_type == Some("message")
            && value.get("role").and_then(Value::as_str) != Some("assistant")
        {
            return;
        }
        let Some(timestamp) = timestamp_number(value.get("timestamp")) else {
            return;
        };
        let Some((input, output, cache_read, cache_creation)) = codebuddy_usage(&value) else {
            return;
        };
        let usage = CodeBuddyUsage {
            input,
            output,
            cache_read,
            cache_creation,
            timestamp_millis: timestamp,
            model: codebuddy_model(&value),
            project: project_from_parent(path),
        };
        let id = codebuddy_message_id(&value);
        if let Some(id) = id {
            let key = format!("{}::{id}", codebuddy_scope(path, &value));
            let replace = match best.get(&key) {
                None => true,
                Some(previous) => {
                    usage.total() > previous.total()
                        || (usage.total() == previous.total()
                            && usage.timestamp_millis > previous.timestamp_millis)
                }
            };
            if replace {
                best.insert(key, usage);
            }
        } else {
            direct.push(usage);
        }
        stats.usage_records = stats.usage_records.saturating_add(1);
    })
    .unwrap_or_else(|_| ScanStats::default());
    let mut builder = UsageContributionBuilder::new(window.clone());
    for usage in best.into_values().chain(direct) {
        record(
            &mut builder,
            usage.timestamp_millis,
            usage.model.as_deref(),
            usage.input,
            usage.output,
            usage.cache_read,
            usage.cache_creation,
            usage.project.as_deref(),
        );
    }
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
}

/// Scan Codex CLI and Orca rollout JSONL files.  The quota snapshot remains a
/// provider concern; this function only builds the local token contribution.
pub fn scan_codex(roots: &[PathBuf], window: &CollectionWindow) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let mut groups = BTreeMap::<String, Vec<CodexFileCandidate>>::new();
    for root in roots {
        if collect_codex_files(root, window.cutoff_ts, &mut groups, &mut stats).is_err() {
            stats.io_errors = stats.io_errors.saturating_add(1);
        }
    }
    let selected = resolve_codex_files(groups, &mut stats);
    for candidate in selected {
        let mut current_model: Option<String> = None;
        let mut total_high_water: Option<CodexTokenCounters> = None;
        let mut last_signature_by_source = BTreeMap::<Option<String>, CodexTokenSignature>::new();
        let mut previous_token_signature: Option<CodexTokenSignature> = None;
        if scan_jsonl_file(
            &candidate.path,
            candidate.modified,
            &mut |_, _, line, stats| {
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
                record(
                    &mut builder,
                    timestamp,
                    current_model.as_deref(),
                    usage.input.saturating_sub(usage.cache_read),
                    usage.output,
                    usage.cache_read,
                    0,
                    None,
                );
                stats.usage_records = stats.usage_records.saturating_add(1);
            },
            &mut stats,
        )
        .is_err()
        {
            stats.io_errors = stats.io_errors.saturating_add(1);
        }
    }
    let mut result = finish(window, builder, stats.clone(), stats.files_scanned > 0);
    if stats.conflict_session_groups > 0 {
        result.diagnostic = Some(format!(
            "Codex 会话副本内容冲突, 已保守选择单份文件 (冲突组: {})",
            stats.conflict_session_groups
        ));
    }
    result
}

fn grok_content(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.clone(),
        Some(Value::Array(values)) => values
            .iter()
            .filter_map(|value| match value {
                Value::String(value) => Some(value.clone()),
                Value::Object(value) => {
                    value.get("text").and_then(Value::as_str).map(str::to_owned)
                }
                _ => None,
            })
            .collect::<Vec<_>>()
            .join(" "),
        _ => String::new(),
    }
}

pub fn scan_grok(roots: &[PathBuf], window: &CollectionWindow) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    for root in roots {
        let current = scan_jsonl_tree(root, window.cutoff_ts, |path, modified, line, stats| {
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
            let kind = value.get("type").and_then(Value::as_str);
            if kind != Some("user") && kind != Some("assistant") {
                return;
            }
            let content = grok_content(value.get("content"));
            if content.is_empty() {
                return;
            }
            let tokens = (content.chars().count() as u64 / 4).max(1);
            let project = path
                .parent()
                .and_then(Path::parent)
                .and_then(Path::file_name)
                .and_then(|value| value.to_str());
            record(
                &mut builder,
                (modified * 1000.0) as i64,
                Some("grok"),
                if kind == Some("user") { tokens } else { 0 },
                if kind == Some("assistant") { tokens } else { 0 },
                0,
                0,
                project,
            );
            stats.usage_records = stats.usage_records.saturating_add(1);
        })
        .unwrap_or_else(|_| ScanStats::default());
        stats.merge(current);
    }
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
}

pub fn scan_pi(root: &Path, window: &CollectionWindow) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let stats = scan_jsonl_tree(root, window.cutoff_ts, |path, _, line, stats| {
        let Some(value) = parse_json_line(line, stats) else {
            return;
        };
        let kind = value.get("type").and_then(Value::as_str);
        if kind == Some("session") {
            return;
        }
        if kind != Some("message") {
            return;
        }
        let message = value.get("message").unwrap_or(&Value::Null);
        if message.get("role").and_then(Value::as_str) != Some("assistant") {
            return;
        }
        let usage = message.get("usage").unwrap_or(&Value::Null);
        if usage.is_null() {
            return;
        }
        let timestamp = timestamp_number(message.get("timestamp")).or_else(|| {
            value
                .get("timestamp")
                .and_then(Value::as_str)
                .and_then(|value| window.epoch_from_iso(value).map(|value| value * 1000))
        });
        let Some(timestamp) = timestamp else { return };
        let project = project_from_parent(path);
        record(
            &mut builder,
            if timestamp < 10_000_000_000 {
                timestamp * 1000
            } else {
                timestamp
            },
            message.get("model").and_then(Value::as_str),
            number_u64(usage.get("input")),
            number_u64(usage.get("output")).saturating_add(number_u64(usage.get("reasoning"))),
            number_u64(usage.get("cacheRead")),
            number_u64(usage.get("cacheWrite")),
            project.as_deref(),
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    })
    .unwrap_or_else(|_| ScanStats::default());
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
}

fn sqlite_error(window: &CollectionWindow, message: &str) -> SourceScan {
    let mut result = SourceScan::empty(window);
    result.diagnostic = Some(message.to_owned());
    result
}

fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
}

pub fn scan_opencode(path: &Path, window: &CollectionWindow) -> SourceScan {
    if !path.is_file() {
        return SourceScan::empty(window);
    }
    let connection = match open_read_only(path) {
        Ok(connection) => connection,
        Err(_) => return sqlite_error(window, "本机 opencode 数据库暂不可读"),
    };
    let any_message = match connection.query_row("SELECT 1 FROM message LIMIT 1", [], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(_) => true,
        Err(rusqlite::Error::QueryReturnedNoRows) => false,
        Err(_) => return sqlite_error(window, "本机 opencode 数据库 schema 不兼容"),
    };
    if !any_message {
        return SourceScan::empty(window);
    }
    // 行数超上限时按 rowid DESC 截断, 保留最新插入的消息 (rowid 随追加单调递增);
    // WITHOUT ROWID 表不支持该排序时回退旧行为 (无序全量前 N 行), 不把兼容性变成报错.
    let mut statement = match connection
        .prepare("SELECT data FROM message WHERE data LIKE '%tokens%' ORDER BY rowid DESC LIMIT ?1")
        .or_else(|_| {
            connection.prepare("SELECT data FROM message WHERE data LIKE '%tokens%' LIMIT ?1")
        }) {
        Ok(statement) => statement,
        Err(_) => return sqlite_error(window, "本机 opencode 数据库 schema 不兼容"),
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let rows = match statement.query_map([MAX_SOURCE_ROWS], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(_) => return sqlite_error(window, "本机 opencode 数据库查询失败"),
    };
    let mut collected = Vec::new();
    for row in rows {
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok(data) = row else { continue };
        collected.push(data);
    }
    // 回放顺序反转为时间升序, 保持聚合语义与全量扫描一致.
    for data in collected.into_iter().rev() {
        let Ok(value) = serde_json::from_str::<Value>(&data) else {
            stats.malformed_lines = stats.malformed_lines.saturating_add(1);
            continue;
        };
        stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
        if value.get("role").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let tokens = value.get("tokens").unwrap_or(&Value::Null);
        let Some(created) =
            timestamp_number(value.get("time").and_then(|value| value.get("created")))
        else {
            continue;
        };
        if created < (window.cutoff_ts * 1000.0) as i64 {
            continue;
        }
        let cache = tokens.get("cache").unwrap_or(&Value::Null);
        record(
            &mut builder,
            created,
            value
                .get("modelID")
                .and_then(Value::as_str)
                .or(Some("opencode")),
            number_u64(tokens.get("input")),
            number_u64(tokens.get("output")).saturating_add(number_u64(tokens.get("reasoning"))),
            number_u64(cache.get("read")),
            number_u64(cache.get("write")),
            None,
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    }
    finish(window, builder, stats, true)
}

pub fn scan_zcode(path: &Path, window: &CollectionWindow) -> SourceScan {
    if !path.is_file() {
        return SourceScan::empty(window);
    }
    let connection = match open_read_only(path) {
        Ok(connection) => connection,
        Err(error) => return sqlite_error(window, &format!("本机 zcode 数据库暂不可读: {error}")),
    };
    let any_usage = match connection.query_row("SELECT 1 FROM model_usage LIMIT 1", [], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(_) => true,
        Err(rusqlite::Error::QueryReturnedNoRows) => false,
        Err(error) => {
            return sqlite_error(window, &format!("本机 zcode 数据库 schema 不兼容: {error}"))
        }
    };
    if !any_usage {
        return SourceScan::empty(window);
    }
    let mut statement = match connection.prepare(
        "SELECT m.started_at, m.model_id, m.input_tokens, m.output_tokens, \
         m.reasoning_tokens, m.cache_creation_input_tokens, m.cache_read_input_tokens, \
         s.directory, s.task_type FROM model_usage m LEFT JOIN session s ON s.id = m.session_id \
         WHERE m.started_at >= ?1 ORDER BY m.started_at DESC LIMIT ?2",
    ) {
        Ok(statement) => statement,
        Err(error) => {
            return sqlite_error(window, &format!("本机 zcode 数据库 schema 不兼容: {error}"))
        }
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let cutoff_ms = (window.cutoff_ts * 1000.0) as i64;
    // 行数超上限时按 started_at DESC 截断, 保留最新记录 (旧记录滑出窗口后自愈);
    // 折叠前反转回时间升序, 保持模型出现顺序等聚合语义与全量扫描一致.
    let rows = match statement.query_map([cutoff_ms, MAX_SOURCE_ROWS], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<String>>(7)?,
            row.get::<_, Option<String>>(8)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(error) => return sqlite_error(window, &format!("本机 zcode 数据库查询失败: {error}")),
    };
    let mut collected = Vec::new();
    for row in rows {
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok(row) = row else { continue };
        collected.push(row);
    }
    for (
        started_at,
        model,
        input,
        output,
        reasoning,
        cache_creation,
        cache_read,
        directory,
        task_type,
    ) in collected.into_iter().rev()
    {
        let input = u64::try_from(input.unwrap_or(0)).unwrap_or(0);
        let output = u64::try_from(output.unwrap_or(0)).unwrap_or(0);
        let reasoning = u64::try_from(reasoning.unwrap_or(0)).unwrap_or(0);
        let cache_creation = u64::try_from(cache_creation.unwrap_or(0)).unwrap_or(0);
        let cache_read = u64::try_from(cache_read.unwrap_or(0)).unwrap_or(0);
        if input == 0 && output == 0 && reasoning == 0 && cache_creation == 0 && cache_read == 0 {
            continue;
        }
        let project = project_from_zcode(directory, task_type);
        record(
            &mut builder,
            started_at,
            model.as_deref().or(Some("unknown")),
            input
                .saturating_sub(cache_read)
                .saturating_sub(cache_creation),
            output.saturating_add(reasoning),
            cache_read,
            cache_creation,
            project.as_deref(),
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    }
    finish(window, builder, stats, true)
}

#[cfg(test)]
mod tests {
    use super::scan_codex;
    use collector_domain::CollectionWindow;
    use serde_json::{json, Map, Value};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::time::{SystemTime, UNIX_EPOCH};

    fn window() -> CollectionWindow {
        let context: Map<String, Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        CollectionWindow::from_context(&context).unwrap()
    }

    fn temp_root(label: &str) -> PathBuf {
        let suffix = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "bruce-codex-dedup-{label}-{}-{suffix}",
            std::process::id()
        ));
        fs::create_dir_all(&root).unwrap();
        root
    }

    /// 行数超上限时必须保留最新记录: 10_010 行中最早的 10 行被截掉,
    /// 最新 10_000 行全部进入聚合 (7/26 归零, 7/28 完整).
    #[test]
    fn zcode_row_cap_keeps_newest_rows() {
        use rusqlite::Connection;
        let root = temp_root("zcode-cap");
        let db_path = root.join("db.sqlite");
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE session (id text primary key, directory text, task_type text);
                 CREATE TABLE model_usage (
                    started_at integer not null, model_id text,
                    input_tokens integer, output_tokens integer, reasoning_tokens integer,
                    cache_creation_input_tokens integer, cache_read_input_tokens integer,
                    session_id text
                 );",
            )
            .unwrap();
        // 窗口: 2026-07-26 00:00+08 = base - 216_000_000ms; base = 7/28 12:00+08.
        let base = 1_785_211_200_000_i64;
        let old_ts = base - 215_700_000; // 7/26 00:05+08
        let new_ts = base - 3_600_000; // 7/28 11:00+08
        connection.execute("BEGIN", []).unwrap();
        for i in 0..10 {
            connection
                .execute(
                    "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', 1000, 0)",
                    [old_ts + i],
                )
                .unwrap();
        }
        for i in 0..10_000 {
            connection
                .execute(
                    "INSERT INTO model_usage (started_at, model_id, input_tokens, output_tokens) \
                     VALUES (?1, 'glm', 10, 0)",
                    [new_ts + i],
                )
                .unwrap();
        }
        connection.execute("COMMIT", []).unwrap();
        drop(connection);

        let scan = super::scan_zcode(&db_path, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        assert!(scan.found, "应识别到数据");
        assert_eq!(scan.stats.sqlite_rows_read, 10_000, "应恰好读到上限行数");
        let by_day = &scan.contribution.by_day;
        assert_eq!(
            by_day
                .get("2026-07-26")
                .map(|bucket| bucket.total)
                .unwrap_or(0),
            0,
            "被截断的最早 10 行不得计入 7/26"
        );
        assert_eq!(
            by_day
                .get("2026-07-28")
                .map(|bucket| bucket.total)
                .unwrap_or(0),
            10_000 * 10,
            "最新 10_000 行应完整计入 7/28"
        );
        fs::remove_dir_all(&root).ok();
    }

    /// 行数超上限时按 rowid DESC 保留最新消息: 最早的 10 行被截掉,
    /// 最新 10_000 行完整进入聚合.
    #[test]
    fn opencode_row_cap_keeps_newest_messages() {
        use rusqlite::Connection;
        let root = temp_root("opencode-cap");
        let db_path = root.join("opencode.db");
        let connection = Connection::open(&db_path).unwrap();
        connection
            .execute("CREATE TABLE message (data text not null)", [])
            .unwrap();
        let base = 1_785_211_200_000_i64; // 7/28 12:00+08
        let old_ts = base - 215_700_000; // 7/26 00:05+08
        let new_ts = base - 3_600_000; // 7/28 11:00+08
        let message = |created: i64, input: u64| {
            json!({
                "role": "assistant",
                "time": { "created": created },
                "tokens": { "input": input, "output": 0 },
                "modelID": "qwen3-coder",
            })
            .to_string()
        };
        connection.execute("BEGIN", []).unwrap();
        for i in 0..10 {
            connection
                .execute(
                    "INSERT INTO message (data) VALUES (?1)",
                    [&message(old_ts + i, 1000)],
                )
                .unwrap();
        }
        for i in 0..10_000 {
            connection
                .execute(
                    "INSERT INTO message (data) VALUES (?1)",
                    [&message(new_ts + i, 7)],
                )
                .unwrap();
        }
        connection.execute("COMMIT", []).unwrap();
        drop(connection);

        let scan = super::scan_opencode(&db_path, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        assert_eq!(scan.stats.sqlite_rows_read, 10_000, "应恰好读到上限行数");
        let by_day = &scan.contribution.by_day;
        assert_eq!(
            by_day
                .get("2026-07-26")
                .map(|bucket| bucket.total)
                .unwrap_or(0),
            0,
            "被截断的最早 10 行不得计入 7/26"
        );
        assert_eq!(
            by_day
                .get("2026-07-28")
                .map(|bucket| bucket.total)
                .unwrap_or(0),
            10_000 * 7,
            "最新 10_000 行应完整计入 7/28"
        );
        fs::remove_dir_all(&root).ok();
    }

    /// CodeBuddy 会话树扫描: assistant 行 usage (input 含 cache_read 需扣减)、
    /// providerData.model 模型名、messageId 去重选择完整快照, 非消息行忽略.
    #[test]
    fn codebuddy_scans_assistant_usage_with_message_id_dedup() {
        let root = temp_root("codebuddy");
        let session_dir = root.join("Users-sivan-demo-project");
        fs::create_dir_all(&session_dir).unwrap();
        let base = 1_785_211_200_000_i64; // 2026-07-28 12:00+08 (窗口今天)
        let line = |role: &str, input: u64, output: u64, cache_read: u64, id: Option<&str>| {
            json!({
                "type": "message",
                "role": role,
                "timestamp": base,
                "message": { "usage": {
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": cache_read,
                    "total_tokens": input + output,
                }},
                "providerData": {
                    "model": "hy3",
                    "messageId": id,
                },
            })
            .to_string()
        };
        let content = [
            // 无 usage 的 assistant 行 (流式部分写入) 应忽略.
            json!({"type": "message", "role": "assistant", "timestamp": base}).to_string(),
            // m1 首次: input 1000(含 cache 200) → 纯输入 800, 总量 1100.
            line("assistant", 1000, 100, 200, Some("m1")),
            // m1 重写: input 1500 → 完整快照总量 1600 (不叠加).
            line("assistant", 1500, 100, 200, Some("m1")),
            // 无 messageId 的直接行: 总量 50.
            line("assistant", 50, 0, 0, None),
            // 非 assistant 行忽略.
            line("user", 999, 0, 0, Some("m2")),
        ]
        .join("\n");
        fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        assert!(scan.found, "应识别到会话文件");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.total, 1600 + 50, "去重后的 m1 加直接行");
        assert_eq!(today.input, 1300 + 50, "纯输入口径 (已扣 cache_read)");
        assert_eq!(today.cache_read, 200, "cache_read 单列");
        assert_eq!(
            scan.contribution.models_today[0].model, "hy3",
            "模型名取自 providerData.model"
        );
        assert_eq!(
            scan.contribution.projects_today[0].name, "Users-sivan-demo-project",
            "项目名取自会话目录"
        );
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn codebuddy_reads_raw_usage_from_function_call() {
        let root = temp_root("codebuddy-raw");
        let session_dir = root.join("Users-sivan-demo-project");
        fs::create_dir_all(&session_dir).unwrap();
        let base = 1_785_211_200_000_i64;
        let content = json!({
            "type": "function_call",
            "sessionId": "session-a",
            "timestamp": base,
            "providerData": {
                "requestModelId": "glm-5.2",
                "messageId": "raw-1",
                "rawUsage": {
                    "prompt_tokens": 1200,
                    "completion_tokens": 50,
                    "completion_thinking_tokens": 20,
                    "prompt_cache_hit_tokens": 300,
                    "prompt_cache_write_tokens": 100
                }
            }
        })
        .to_string();
        fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.input, 800, "raw prompt_tokens 应扣除两类缓存");
        assert_eq!(today.output, 50, "completion_tokens 已含 thinking, 不再叠加");
        assert_eq!(today.cache_read, 300);
        assert_eq!(today.cache_creation, 100);
        assert_eq!(today.total, 1250);
        assert_eq!(scan.contribution.models_today[0].model, "glm-5.2");
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn codebuddy_reads_camel_case_cache_breakdown() {
        let root = temp_root("codebuddy-camel");
        let session_dir = root.join("Users-sivan-demo-project");
        fs::create_dir_all(&session_dir).unwrap();
        let base = 1_785_211_200_000_i64;
        let content = json!({
            "type": "function_call",
            "timestamp": base,
            "providerData": {
                "model": "glm-5.2",
                "rawUsage": {
                    "cachedMissTokens": 700,
                    "cachedTokens": 200,
                    "cachedWriteTokens": 50,
                    "completionTokens": 30,
                    "reasoningTokens": 10
                }
            }
        })
        .to_string();
        fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.input, 700);
        assert_eq!(today.output, 30, "completionTokens 已含 reasoningTokens");
        assert_eq!(today.cache_read, 200);
        assert_eq!(today.cache_creation, 50);
        assert_eq!(today.total, 980);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn codebuddy_merges_normalized_cache_when_raw_usage_lacks_breakdown() {
        // 本机真实形态: rawUsage 无任何缓存明细, 缓存拆分只在归一化 usage 中;
        // 合并后 input 需同步扣减, 保持 input + output + cache_read == total.
        let root = temp_root("codebuddy-cache-merge");
        let session_dir = root.join("Users-sivan-Desktop");
        fs::create_dir_all(&session_dir).unwrap();
        let base = 1_785_211_200_000_i64;
        let content = json!({
            "type": "message",
            "role": "assistant",
            "timestamp": base,
            "providerData": {
                "model": "glm-5.3-flash",
                "messageId": "raw-2",
                "rawUsage": {
                    "prompt_tokens": 24575,
                    "completion_tokens": 109,
                    "total_tokens": 24684,
                    "completion_tokens_details": {"reasoning_tokens": 64}
                }
            },
            "message": {"usage": {
                "input_tokens": 24575,
                "output_tokens": 109,
                "total_tokens": 24684,
                "cache_read_input_tokens": 384
            }}
        })
        .to_string();
        fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.input, 24191, "归一化 cache_read 应从 input 中扣减");
        assert_eq!(today.output, 109);
        assert_eq!(today.cache_read, 384, "rawUsage 缺明细时应回退归一化缓存");
        assert_eq!(today.cache_creation, 0);
        assert_eq!(today.total, 24684);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn codebuddy_nested_cache_detail_survives_flat_zero_field() {
        // 扁平 cached_tokens 为 0 不应阻断嵌套 prompt_tokens_details 的正值回退:
        // 旧行为返回 Some(0) 中断 or_else 链, 缓存明细被丢弃、input 全额计入.
        let root = temp_root("codebuddy-zero-trap");
        let session_dir = root.join("Users-sivan-demo-project");
        fs::create_dir_all(&session_dir).unwrap();
        let base = 1_785_211_200_000_i64;
        let content = json!({
            "type": "function_call",
            "timestamp": base,
            "providerData": {
                "model": "glm-5.2",
                "messageId": "raw-3",
                "rawUsage": {
                    "prompt_tokens": 1000,
                    "completion_tokens": 20,
                    "cached_tokens": 0,
                    "prompt_tokens_details": {"cached_tokens": 300}
                }
            }
        })
        .to_string();
        fs::write(session_dir.join("session-a.jsonl"), content).unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.input, 700);
        assert_eq!(today.output, 20);
        assert_eq!(today.cache_read, 300, "嵌套正值缓存应命中, 不被扁平 0 阻断");
        assert_eq!(today.cache_creation, 0);
        assert_eq!(today.total, 1020);
        fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn codebuddy_dedup_uses_complete_snapshot_and_session_scope() {
        let root = temp_root("codebuddy-snapshot");
        let project_a = root.join("project-a");
        let project_b = root.join("project-b");
        fs::create_dir_all(&project_a).unwrap();
        fs::create_dir_all(&project_b).unwrap();
        let base = 1_785_211_200_000_i64;
        let line = |session: &str, input: u64, output: u64, id: &str| {
            json!({
                "type": "message",
                "role": "assistant",
                "sessionId": session,
                "timestamp": base,
                "message": { "usage": {
                    "input_tokens": input,
                    "output_tokens": output,
                    "cache_read_input_tokens": 0
                }},
                "providerData": {
                    "model": "hy3",
                    "messageId": id,
                },
            })
            .to_string()
        };
        // The first complete snapshot has the larger total. A field-wise max
        // would incorrectly combine these two rewrites into 250 tokens.
        let first = line("session-a", 100, 100, "same-id");
        let rewrite = line("session-a", 150, 1, "same-id");
        fs::write(
            project_a.join("session-a.jsonl"),
            [first, rewrite].join("\n"),
        )
        .unwrap();
        // The same provider message id in another session must remain a
        // separate contribution.
        fs::write(
            project_b.join("session-b.jsonl"),
            line("session-b", 10, 5, "same-id"),
        )
        .unwrap();

        let scan = super::scan_codebuddy(&root, &window());
        assert!(scan.diagnostic.is_none(), "扫描不应报错");
        let today = &scan.contribution.by_day["2026-07-28"];
        assert_eq!(today.input, 110);
        assert_eq!(today.output, 105);
        assert_eq!(today.total, 215, "应选择完整快照并按会话隔离去重");
        fs::remove_dir_all(&root).ok();
    }

    fn write_token_file(
        root: &Path,
        name: &str,
        last_input: u64,
        last_output: u64,
        total_input: u64,
        padding: &str,
    ) {
        let path = root.join("2026").join("07").join("28").join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let line = json!({
            "timestamp": "2026-07-28T04:00:00Z",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": last_input,
                        "cached_input_tokens": 0,
                        "output_tokens": last_output
                    },
                    "total_token_usage": {
                        "input_tokens": total_input,
                        "output_tokens": total_input
                    }
                }
            },
            "padding": padding
        });
        let mut bytes = serde_json::to_vec(&line).unwrap();
        bytes.push(b'\n');
        fs::write(path, bytes).unwrap();
    }

    fn write_codex_lines(root: &Path, name: &str, lines: &[Value]) {
        let path = root.join("2026").join("07").join("28").join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let content = lines
            .iter()
            .map(|line| serde_json::to_string(line).unwrap())
            .collect::<Vec<_>>()
            .join("\n");
        fs::write(path, format!("{content}\n")).unwrap();
    }

    fn codex_turn_context(timestamp: &str, model: &str) -> Value {
        json!({
            "timestamp": timestamp,
            "type": "turn_context",
            "payload": { "model": model }
        })
    }

    fn codex_token_count(timestamp: &str, input: u64, cache_read: u64, output: u64) -> Value {
        json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "last_token_usage": {
                        "input_tokens": input,
                        "cached_input_tokens": cache_read,
                        "output_tokens": output
                    }
                }
            }
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn codex_token_snapshot(
        timestamp: &str,
        total_input: u64,
        total_cache_read: u64,
        total_output: u64,
        last_input: u64,
        last_cache_read: u64,
        last_output: u64,
        limit_id: &str,
    ) -> Value {
        json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": total_input,
                        "cached_input_tokens": total_cache_read,
                        "output_tokens": total_output
                    },
                    "last_token_usage": {
                        "input_tokens": last_input,
                        "cached_input_tokens": last_cache_read,
                        "output_tokens": last_output
                    }
                },
                "rate_limits": { "limit_id": limit_id }
            }
        })
    }

    fn codex_total_snapshot(
        timestamp: &str,
        total_input: u64,
        total_cache_read: u64,
        total_output: u64,
        limit_id: &str,
    ) -> Value {
        json!({
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": total_input,
                        "cached_input_tokens": total_cache_read,
                        "output_tokens": total_output
                    },
                    "last_token_usage": {}
                },
                "rate_limits": { "limit_id": limit_id }
            }
        })
    }

    fn today_total(result: &super::SourceScan) -> u64 {
        result
            .contribution
            .by_day
            .get("2026-07-28")
            .map(|bucket| bucket.total)
            .unwrap_or(0)
    }

    #[test]
    fn duplicate_rollout_copies_are_counted_once() {
        let first = temp_root("duplicate-first");
        let second = temp_root("duplicate-second");
        write_token_file(&first, "rollout-duplicate.jsonl", 10, 2, 100, "same");
        write_token_file(&second, "rollout-duplicate.jsonl", 10, 2, 100, "same");

        let result = scan_codex(&[first.clone(), second.clone()], &window());

        assert_eq!(today_total(&result), 12);
        assert_eq!(result.stats.files_scanned, 1);
        assert_eq!(result.stats.usage_records, 1);
        assert_eq!(result.stats.duplicate_files_skipped, 1);
        assert_eq!(result.stats.duplicate_session_groups, 1);
        assert_eq!(result.stats.conflict_session_groups, 0);
        assert!(result.diagnostic.is_none());
        fs::remove_dir_all(first).unwrap();
        fs::remove_dir_all(second).unwrap();
    }

    #[test]
    fn distinct_rollout_sessions_are_both_counted() {
        let first = temp_root("distinct-first");
        let second = temp_root("distinct-second");
        write_token_file(&first, "rollout-first.jsonl", 10, 2, 100, "first");
        write_token_file(&second, "rollout-second.jsonl", 20, 3, 200, "second");

        let result = scan_codex(&[first.clone(), second.clone()], &window());

        assert_eq!(today_total(&result), 35);
        assert_eq!(result.stats.files_scanned, 2);
        assert_eq!(result.stats.usage_records, 2);
        assert_eq!(result.stats.duplicate_files_skipped, 0);
        assert_eq!(result.stats.duplicate_session_groups, 0);
        fs::remove_dir_all(first).unwrap();
        fs::remove_dir_all(second).unwrap();
    }

    #[test]
    fn conflicting_rollout_copies_are_not_added_twice() {
        let first = temp_root("conflict-first");
        let second = temp_root("conflict-second");
        write_token_file(&first, "rollout-conflict.jsonl", 10, 2, 100, "short");
        write_token_file(
            &second,
            "rollout-conflict.jsonl",
            20,
            3,
            200,
            "longer-content-that-wins",
        );

        let result = scan_codex(&[first.clone(), second.clone()], &window());

        assert_eq!(today_total(&result), 23);
        assert_eq!(result.stats.files_scanned, 1);
        assert_eq!(result.stats.duplicate_files_skipped, 1);
        assert_eq!(result.stats.duplicate_session_groups, 1);
        assert_eq!(result.stats.conflict_session_groups, 1);
        assert!(result.diagnostic.is_some());
        fs::remove_dir_all(first).unwrap();
        fs::remove_dir_all(second).unwrap();
    }

    /// 硬链接副本 (Orca 双根形态) 与大文件 (>64KB, 走头尾指纹 seek 路径)
    /// 均判为相同副本只计一次, 不再全文件哈希.
    #[test]
    fn codex_hardlink_and_large_copies_dedup_without_full_hash() {
        let first = temp_root("hardlink-first");
        let second = temp_root("hardlink-second");
        // 大 padding 使文件 >128KB, 覆盖指纹的头块 + seek 尾块路径.
        let big = "x".repeat(200_000);
        write_token_file(&first, "rollout-hard.jsonl", 10, 2, 100, &big);
        let source = first
            .join("2026")
            .join("07")
            .join("28")
            .join("rollout-hard.jsonl");
        let link_dir = second.join("2026").join("07").join("28");
        fs::create_dir_all(&link_dir).unwrap();
        fs::hard_link(&source, link_dir.join("rollout-hard.jsonl")).unwrap();

        let result = scan_codex(&[first.clone(), second.clone()], &window());

        assert_eq!(result.stats.files_scanned, 1, "硬链接副本只计一次");
        assert_eq!(result.stats.duplicate_files_skipped, 1);
        assert_eq!(result.stats.duplicate_session_groups, 1);
        assert_eq!(
            result.stats.conflict_session_groups, 0,
            "同 inode 不得判冲突"
        );
        assert!(result.diagnostic.is_none());
        fs::remove_dir_all(first).unwrap();
        fs::remove_dir_all(second).unwrap();
    }

    #[test]
    fn codex_uses_last_token_usage_not_cumulative_total() {
        let root = temp_root("last-usage");
        write_token_file(&root, "rollout-last.jsonl", 4, 2, 400, "single");

        let result = scan_codex(std::slice::from_ref(&root), &window());

        assert_eq!(today_total(&result), 6);
        assert_eq!(result.stats.usage_records, 1);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn codex_attributes_usage_to_the_current_turn_context_model() {
        let root = temp_root("model-attribution");
        write_codex_lines(
            &root,
            "rollout-models.jsonl",
            &[
                codex_turn_context("2026-07-28T04:00:00Z", "gpt-5.4"),
                codex_token_count("2026-07-28T04:00:01Z", 10, 2, 3),
                codex_turn_context("2026-07-28T04:00:02Z", "gpt-5.3-codex"),
                codex_token_count("2026-07-28T04:00:03Z", 20, 5, 4),
            ],
        );

        let result = scan_codex(std::slice::from_ref(&root), &window());
        let model_totals = result
            .contribution
            .models_today
            .iter()
            .map(|entry| (entry.model.clone(), entry.bucket.total))
            .collect::<std::collections::BTreeMap<_, _>>();

        assert_eq!(model_totals.get("gpt-5.4"), Some(&13));
        assert_eq!(model_totals.get("gpt-5.3-codex"), Some(&24));
        assert!(!model_totals.contains_key("codex"));
        let month_totals = result
            .contribution
            .models_by_month
            .get("2026-07")
            .unwrap()
            .iter()
            .map(|(model, bucket)| (model.clone(), bucket.total))
            .collect::<std::collections::BTreeMap<_, _>>();
        assert_eq!(month_totals, model_totals);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn codex_deduplicates_replayed_token_snapshots_across_limit_sources() {
        let root = temp_root("snapshot-dedup");
        write_codex_lines(
            &root,
            "rollout-snapshots.jsonl",
            &[
                codex_turn_context("2026-07-28T04:00:00Z", "gpt-5.4"),
                codex_token_snapshot("2026-07-28T04:00:01Z", 100, 20, 10, 100, 20, 10, "codex"),
                codex_token_snapshot(
                    "2026-07-28T04:00:02Z",
                    100,
                    20,
                    10,
                    100,
                    20,
                    10,
                    "codex_bengalfox",
                ),
            ],
        );

        let result = scan_codex(std::slice::from_ref(&root), &window());

        assert_eq!(today_total(&result), 110);
        assert_eq!(result.stats.usage_records, 1);
        assert_eq!(result.contribution.models_today[0].bucket.total, 110);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn codex_uses_cumulative_total_when_last_usage_is_missing_across_model_switch() {
        let root = temp_root("cumulative-model-switch");
        write_codex_lines(
            &root,
            "rollout-cumulative.jsonl",
            &[
                codex_turn_context("2026-07-28T04:00:00Z", "model-a"),
                codex_total_snapshot("2026-07-28T04:00:01Z", 100, 20, 10, "codex"),
                codex_turn_context("2026-07-28T04:00:02Z", "model-b"),
                codex_total_snapshot("2026-07-28T04:00:03Z", 150, 30, 15, "codex"),
            ],
        );

        let result = scan_codex(std::slice::from_ref(&root), &window());
        let model_totals = result
            .contribution
            .models_today
            .iter()
            .map(|entry| (entry.model.clone(), entry.bucket.total))
            .collect::<std::collections::BTreeMap<_, _>>();

        assert_eq!(model_totals.get("model-a"), Some(&110));
        assert_eq!(model_totals.get("model-b"), Some(&55));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn codex_uses_unknown_model_when_no_model_context_exists() {
        let root = temp_root("unknown-model");
        write_codex_lines(
            &root,
            "rollout-unknown.jsonl",
            &[codex_token_count("2026-07-28T04:00:00Z", 10, 2, 3)],
        );

        let result = scan_codex(std::slice::from_ref(&root), &window());
        let model_totals = result
            .contribution
            .models_today
            .iter()
            .map(|entry| (entry.model.clone(), entry.bucket.total))
            .collect::<std::collections::BTreeMap<_, _>>();

        assert_eq!(model_totals.get("unknown"), Some(&13));
        assert!(!model_totals.contains_key("codex"));
        fs::remove_dir_all(root).unwrap();
    }
}
