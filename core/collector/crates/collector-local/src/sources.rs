//! Agent-specific local session and usage sources.
//!
//! The cache-backed Kimi JSONL adapter remains in `lib.rs`. This module owns
//! the other read-only sources that make up the existing agent-usage contract:
//! Claude, Codex, Grok, Pi, OpenCode, and ZCode. Submodules under `sources/`
//! split individual adapters and test suites by responsibility (C053).

mod codebuddy;
mod codex;
mod jsonl_adapters;
mod sqlite_adapters;
#[cfg(test)]
mod tests_cache;
#[cfg(test)]
mod tests_sources;

pub use codebuddy::{scan_codebuddy, scan_codebuddy_with_cancellation};
pub use codex::{
    scan_codex, scan_codex_cached, scan_codex_cached_with_cancellation,
    scan_codex_with_cancellation,
};
pub use jsonl_adapters::{
    scan_claude_cached, scan_codebuddy_cached, scan_grok_cached, scan_kimi_tree_cached,
    scan_pi_cached,
};
pub use sqlite_adapters::{
    scan_opencode, scan_opencode_cached, scan_opencode_with_cancellation, scan_zcode,
    scan_zcode_cached, scan_zcode_with_cancellation,
};

use super::{read_bounded_line, trim_line_end, ScanStats};
use collector_domain::{
    CollectionWindow, UsageContribution, UsageContributionBuilder, UsageSample,
};
use collector_runtime::{CancellationToken, RuntimeError};
use jsonl_adapters::digest_source_key;
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, BufReader};
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

/// SQLite 源单次扫描的行数上限 (C041: 1 万 → 3 万)。
/// 上限语义为「保留最新、丢最旧」的计划内降级 (capped 标记 + 信息级诊断),
/// 3 万覆盖 ZCode 自身修剪后的存量天花板 (~1.1 万行), 常态下不再触发。
pub(super) const MAX_SOURCE_ROWS: i64 = 30_000;

#[derive(Debug, Clone)]
pub struct SourceScan {
    pub found: bool,
    pub contribution: UsageContribution,
    pub stats: ScanStats,
    pub diagnostic: Option<String>,
    /// 行数截断 (C041): 计划内降级标记, 上游据此把诊断归为信息级
    /// (LOCAL_SOURCE_ROWS_CAPPED), 不把采集 envelope 打成 Partial。
    pub capped: bool,
}

#[derive(Debug)]
pub enum SourceScanError {
    Io(io::Error),
    Runtime(RuntimeError),
}

impl From<io::Error> for SourceScanError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<RuntimeError> for SourceScanError {
    fn from(error: RuntimeError) -> Self {
        Self::Runtime(error)
    }
}

impl SourceScan {
    pub fn empty(window: &CollectionWindow) -> Self {
        Self {
            found: false,
            contribution: UsageContributionBuilder::new(window.clone()).contribution(),
            stats: ScanStats::default(),
            diagnostic: None,
            capped: false,
        }
    }
}

pub(super) fn finish(
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
        capped: false,
    }
}

pub(super) fn timestamp_number(value: Option<&Value>) -> Option<i64> {
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

pub(super) fn number_u64(value: Option<&Value>) -> u64 {
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

pub(super) fn parse_json_line(line: &[u8], stats: &mut ScanStats) -> Option<Value> {
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
pub(super) fn record(
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
        cache_creation_1h: 0,
        project,
    });
}

/// Claude Code 用量里 1 小时 TTL 的缓存写入 token (C107): `usage.cache_creation.
/// ephemeral_1h_input_tokens`; 旧日志无该拆分时为 0 (整体按 5 分钟写入计价)。
pub(super) fn claude_cache_creation_1h(usage: &Value) -> u64 {
    number_u64(
        usage
            .get("cache_creation")
            .and_then(|split| split.get("ephemeral_1h_input_tokens")),
    )
}

pub(super) fn record_claude_usage(builder: &mut UsageContributionBuilder, usage: &ClaudeUsage) {
    let _ = builder.record(UsageSample {
        timestamp_millis: usage.timestamp_millis,
        model: usage.model.as_deref(),
        input: usage.input,
        output: usage.output,
        cache_read: usage.cache_read,
        cache_creation: usage.cache_creation,
        cache_creation_1h: usage.cache_creation_1h,
        project: usage.project.as_deref(),
    });
}

pub(super) fn project_from_parent(path: &Path) -> Option<String> {
    path.parent()
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

pub(super) fn project_from_zcode(
    value: Option<String>,
    task_type: Option<String>,
) -> Option<String> {
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

/// 与 lib.rs 缓存 walker / jsonl_cache 树遍历共用同一深度护栏 (C045).
const MAX_DIRECTORY_SCAN_DEPTH: usize = super::MAX_DIRECTORY_SCAN_DEPTH;

pub(super) fn scan_jsonl_tree<F>(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    mut callback: F,
) -> Result<ScanStats, SourceScanError>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
    scan_jsonl_tree_impl(
        root,
        cutoff_ts,
        cancellation,
        &mut callback,
        #[cfg(test)]
        None,
    )
}

#[cfg(test)]
#[cfg(test)]
pub(super) fn scan_jsonl_tree_with_line_probe<F, P>(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    mut callback: F,
    mut line_probe: P,
) -> Result<ScanStats, SourceScanError>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
    P: FnMut(),
{
    scan_jsonl_tree_impl(
        root,
        cutoff_ts,
        cancellation,
        &mut callback,
        Some(&mut line_probe),
    )
}

fn scan_jsonl_tree_impl<F>(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    callback: &mut F,
    #[cfg(test)] mut line_probe: Option<&mut dyn FnMut()>,
) -> Result<ScanStats, SourceScanError>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
    let mut stats = ScanStats::default();
    let mut visited_dirs = BTreeSet::new();
    if let Ok(canonical) = fs::canonicalize(root) {
        visited_dirs.insert(canonical);
    }
    walk_jsonl_tree(
        root,
        cutoff_ts,
        cancellation,
        callback,
        &mut stats,
        0,
        &mut visited_dirs,
        #[cfg(test)]
        &mut line_probe,
    )?;
    Ok(stats)
}

// 参数含递归状态 (depth/visited_dirs) 与测试探针, 拆分结构体收益低于可读性损失.
#[allow(clippy::too_many_arguments)]
fn walk_jsonl_tree<F>(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    callback: &mut F,
    stats: &mut ScanStats,
    depth: usize,
    visited_dirs: &mut BTreeSet<PathBuf>,
    #[cfg(test)] line_probe: &mut Option<&mut dyn FnMut()>,
) -> Result<(), SourceScanError>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
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
            let canonical = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
            if visited_dirs.insert(canonical) {
                walk_jsonl_tree(
                    &path,
                    cutoff_ts,
                    cancellation,
                    callback,
                    stats,
                    depth + 1,
                    visited_dirs,
                    #[cfg(test)]
                    line_probe,
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
        scan_jsonl_file(
            &path,
            modified,
            cancellation,
            callback,
            stats,
            #[cfg(test)]
            line_probe,
        )?;
    }
    Ok(())
}

pub(super) fn scan_jsonl_file<F>(
    path: &Path,
    modified: f64,
    cancellation: &CancellationToken,
    callback: &mut F,
    stats: &mut ScanStats,
    #[cfg(test)] line_probe: &mut Option<&mut dyn FnMut()>,
) -> Result<(), SourceScanError>
where
    F: FnMut(&Path, f64, &[u8], &mut ScanStats),
{
    cancellation.check()?;
    stats.files_scanned = stats.files_scanned.saturating_add(1);
    let file = match File::open(path) {
        Ok(file) => file,
        Err(_) => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            return Ok(());
        }
    };
    let mut reader = BufReader::new(file);
    loop {
        cancellation.check()?;
        let Some(line) = read_bounded_line(&mut reader, super::MAX_JSONL_RECORD_BYTES)? else {
            break;
        };
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
        #[cfg(test)]
        if let Some(probe) = line_probe.as_deref_mut() {
            probe();
        }
    }
    Ok(())
}

/// Scan a Kimi Work or Kimi Code JSONL tree without the Kimi-specific cache.
/// Kimi Code's primary path continues to use the cache-backed scanner in the
/// parent module; this function is used for Kimi Work and source parity tests.
pub fn scan_kimi_tree(root: &Path, window: &CollectionWindow) -> SourceScan {
    scan_kimi_tree_with_cancellation(root, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_kimi_tree_with_cancellation(
    root: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let stats = scan_jsonl_tree(root, window.cutoff_ts, cancellation, |_, _, line, stats| {
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
    })?;
    Ok(finish(
        window,
        builder,
        stats.clone(),
        stats.files_scanned > 0,
    ))
}

#[derive(Debug, Clone, Default)]
pub(super) struct ClaudeUsage {
    pub(super) input: u64,
    pub(super) output: u64,
    pub(super) cache_read: u64,
    pub(super) cache_creation: u64,
    /// cache_creation 中按 1 小时 TTL 写入的部分 (C107)。
    pub(super) cache_creation_1h: u64,
    pub(super) timestamp_millis: i64,
    pub(super) model: Option<String>,
    pub(super) project: Option<String>,
}

/// Scan Claude Code assistant messages, coalescing repeated writes of one
/// message id so an in-progress skeleton is not counted as real usage.
pub fn scan_claude(root: &Path, window: &CollectionWindow) -> SourceScan {
    scan_claude_with_cancellation(root, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_claude_with_cancellation(
    root: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut best = BTreeMap::<String, ClaudeUsage>::new();
    let mut direct = Vec::<ClaudeUsage>::new();
    let stats = scan_jsonl_tree(
        root,
        window.cutoff_ts,
        cancellation,
        |path, _, line, stats| {
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
                cache_creation_1h: claude_cache_creation_1h(usage),
                timestamp_millis: timestamp,
                model: message
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                project,
            };
            let id = message.get("id").and_then(Value::as_str);
            if let Some(id) = id {
                let entry = best
                    .entry(digest_source_key("claude-message", id))
                    .or_default();
                entry.input = entry.input.max(usage.input);
                entry.output = entry.output.max(usage.output);
                entry.cache_read = entry.cache_read.max(usage.cache_read);
                entry.cache_creation = entry.cache_creation.max(usage.cache_creation);
                entry.cache_creation_1h = entry.cache_creation_1h.max(usage.cache_creation_1h);
                entry.timestamp_millis = usage.timestamp_millis;
                entry.model = usage.model;
                entry.project = usage.project;
            } else {
                direct.push(usage);
            }
            stats.usage_records = stats.usage_records.saturating_add(1);
        },
    )?;
    let mut builder = UsageContributionBuilder::new(window.clone());
    for usage in best.into_values().chain(direct) {
        record_claude_usage(&mut builder, &usage);
    }
    Ok(finish(
        window,
        builder,
        stats.clone(),
        stats.files_scanned > 0,
    ))
}

pub(super) fn grok_content(value: Option<&Value>) -> String {
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
    scan_grok_with_cancellation(roots, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_grok_with_cancellation(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    for root in roots {
        let current = scan_jsonl_tree(
            root,
            window.cutoff_ts,
            cancellation,
            |path, modified, line, stats| {
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
            },
        );
        match current {
            Ok(current) => stats.merge(current),
            Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            Err(SourceScanError::Io(_)) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
            }
        }
    }
    Ok(finish(
        window,
        builder,
        stats.clone(),
        stats.files_scanned > 0,
    ))
}

pub fn scan_pi(root: &Path, window: &CollectionWindow) -> SourceScan {
    scan_pi_with_cancellation(root, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_pi_with_cancellation(
    root: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let stats = scan_jsonl_tree(
        root,
        window.cutoff_ts,
        cancellation,
        |path, _, line, stats| {
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
        },
    )?;
    Ok(finish(
        window,
        builder,
        stats.clone(),
        stats.files_scanned > 0,
    ))
}
