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
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{self, BufReader};
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

fn project_from_kimi_path(path: &Path) -> Option<String> {
    path.components().find_map(|component| {
        let value = component.as_os_str().to_str()?;
        if !value.starts_with("wd_") {
            return None;
        }
        let name = value.strip_prefix("wd_")?;
        let (name, _) = name.rsplit_once('_').unwrap_or((name, ""));
        let name = name.replace('-', "/");
        (!name.is_empty()).then_some(name)
    })
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
        stats.files_scanned = stats.files_scanned.saturating_add(1);
        let file = match File::open(&path) {
            Ok(file) => file,
            Err(_) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
                continue;
            }
        };
        let mut reader = BufReader::new(file);
        loop {
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
            callback(&path, modified, line, stats);
        }
    }
    Ok(())
}

/// Scan a Kimi Work or Kimi Code JSONL tree without the Kimi-specific cache.
/// Kimi Code's primary path continues to use the cache-backed scanner in the
/// parent module; this function is used for Kimi Work and source parity tests.
pub fn scan_kimi_tree(
    root: &Path,
    window: &CollectionWindow,
    project_from_path: bool,
) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let stats = scan_jsonl_tree(root, window.cutoff_ts, |path, _, line, stats| {
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
            project_from_path
                .then(|| project_from_kimi_path(path))
                .flatten()
                .as_deref(),
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

/// Scan Codex CLI and Orca rollout JSONL files.  The quota snapshot remains a
/// provider concern; this function only builds the local token contribution.
pub fn scan_codex(roots: &[PathBuf], window: &CollectionWindow) -> SourceScan {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    for root in roots {
        let current = scan_jsonl_tree(root, window.cutoff_ts, |_, _, line, stats| {
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
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
            let usage = info.get("last_token_usage").unwrap_or(&Value::Null);
            let input_total = number_u64(usage.get("input_tokens"));
            let cache_read = number_u64(usage.get("cached_input_tokens"));
            let output = number_u64(usage.get("output_tokens"));
            if input_total == 0 && cache_read == 0 && output == 0 {
                return;
            }
            record(
                &mut builder,
                timestamp,
                Some("codex"),
                input_total.saturating_sub(cache_read),
                output,
                cache_read,
                0,
                None,
            );
            stats.usage_records = stats.usage_records.saturating_add(1);
        })
        .unwrap_or_else(|_| ScanStats::default());
        stats.merge(current);
    }
    finish(window, builder, stats.clone(), stats.files_scanned > 0)
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
    let mut statement =
        match connection.prepare("SELECT data FROM message WHERE data LIKE '%tokens%' LIMIT ?1") {
            Ok(statement) => statement,
            Err(_) => return sqlite_error(window, "本机 opencode 数据库 schema 不兼容"),
        };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let rows = match statement.query_map([MAX_SOURCE_ROWS], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(_) => return sqlite_error(window, "本机 opencode 数据库查询失败"),
    };
    for row in rows {
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok(data) = row else { continue };
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
         WHERE m.started_at >= ?1 ORDER BY m.started_at LIMIT ?2",
    ) {
        Ok(statement) => statement,
        Err(error) => {
            return sqlite_error(window, &format!("本机 zcode 数据库 schema 不兼容: {error}"))
        }
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let cutoff_ms = (window.cutoff_ts * 1000.0) as i64;
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
    for row in rows {
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok((
            started_at,
            model,
            input,
            output,
            reasoning,
            cache_creation,
            cache_read,
            directory,
            task_type,
        )) = row
        else {
            continue;
        };
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
