//! Antigravity (CLI + IDE) local usage source.
//!
//! Both products write the same layout under `~/.gemini`:
//! `brain/<session>/.system_generated/logs/transcript_full.jsonl`.
//! Only completed PLANNER_RESPONSE rows with exact counters are imported.
//! Token semantics match the source: input excludes cache, output already
//! includes thinking; never subtract cache or add reasoning again.

use super::super::{
    read_bounded_line, trim_line_end, ScanStats, MAX_JSONL_RECORD_BYTES, READ_BUFFER_BYTES,
};
use super::{finish, SourceScan, SourceScanError};
use crate::cache_util::{load_json_cache, write_json_atomic, CacheLoad};
use collector_domain::{CollectionWindow, RequestRecord, UsageContributionBuilder, UsageSample};
use collector_runtime::CancellationToken;
use rusqlite::{params_from_iter, types::Value as SqlValue, Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs::{self, File};
use std::io::BufReader;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const ANTIGRAVITY_CACHE_VERSION: u32 = 2;
const TRANSCRIPT_RELATIVE: &str = ".system_generated/logs/transcript_full.jsonl";
const KIND_USER: u8 = 1;
const KIND_PLANNER: u8 = 2;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
struct CachedStep {
    step: u64,
    kind: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    timestamp: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model: Option<String>,
    /// Parsed `Model Selection` display name from USER_INPUT; content is never stored.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    selection: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    input: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    output: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    cache_read: u64,
    #[serde(default, skip_serializing_if = "is_zero")]
    cache_creation: u64,
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}

#[derive(Debug, Serialize, Deserialize)]
struct CacheEntry {
    version: u32,
    mtime_ns: u64,
    size: u64,
    steps: Vec<CachedStep>,
}

struct MergedStep {
    step: CachedStep,
    root_index: usize,
}

struct SessionData {
    steps: BTreeMap<u64, MergedStep>,
    project: Option<String>,
    native_db: Option<PathBuf>,
    copies: usize,
    conflict: bool,
}

#[derive(Debug, Clone, Copy)]
struct NativeTiming {
    first_token_ms: i64,
    latency_ms: i64,
}

/// Scan Antigravity CLI and IDE brain roots as one agent.
///
/// `roots` are the `brain` directories themselves; the sibling
/// `conversation_summaries.db` is used only for an optional project name.
pub fn scan_antigravity_cached(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut stats = ScanStats::default();
    let found = roots.iter().any(|root| root.is_dir());
    if !found {
        return Ok(SourceScan::empty(window));
    }

    let cache_dir = cache_root.join("antigravity");
    let mut sessions: BTreeMap<String, SessionData> = BTreeMap::new();

    for (root_index, root) in roots.iter().enumerate() {
        cancellation.check()?;
        let Ok(canonical_root) = fs::canonicalize(root) else {
            stats.io_errors = stats.io_errors.saturating_add(1);
            continue;
        };
        let projects = read_projects(root);
        let entries = match fs::read_dir(root) {
            Ok(entries) => entries,
            Err(_) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
                continue;
            }
        };
        for entry in entries.flatten() {
            cancellation.check()?;
            let session_id = match entry.file_name().to_str().map(str::to_owned) {
                Some(value) if valid_session_id(&value) => value,
                _ => continue,
            };
            if !entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false) {
                continue;
            }
            stats.files_visited = stats.files_visited.saturating_add(1);
            let transcript = entry.path().join(TRANSCRIPT_RELATIVE);
            if !transcript.is_file() {
                stats.files_skipped = stats.files_skipped.saturating_add(1);
                continue;
            }
            let Ok(canonical_transcript) = fs::canonicalize(&transcript) else {
                stats.io_errors = stats.io_errors.saturating_add(1);
                continue;
            };
            if !canonical_transcript.starts_with(&canonical_root) {
                stats.files_skipped = stats.files_skipped.saturating_add(1);
                continue;
            }
            let metadata = match fs::metadata(&canonical_transcript) {
                Ok(metadata) => metadata,
                Err(_) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                    continue;
                }
            };
            let mtime_ns = modified_ns(&metadata);
            let size = metadata.len();
            let cache_path = cache_path(&cache_dir, &canonical_transcript);
            let steps = match load_steps(
                &canonical_transcript,
                mtime_ns,
                size,
                &cache_path,
                window,
                cancellation,
                &mut stats,
            ) {
                Ok(steps) => steps,
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                    continue;
                }
            };
            let project = projects.get(&session_id).cloned();
            let native_db = root
                .parent()
                .map(|app| app.join("conversations").join(format!("{session_id}.db")))
                .filter(|path| path.is_file());
            let session = sessions.entry(session_id).or_insert_with(|| SessionData {
                steps: BTreeMap::new(),
                project: project.clone(),
                native_db: native_db.clone(),
                copies: 0,
                conflict: false,
            });
            if session.project.is_none() {
                session.project = project;
            }
            if session.native_db.is_none() {
                session.native_db = native_db;
            }
            session.copies = session.copies.saturating_add(1);
            for step in steps {
                let current = MergedStep {
                    step: step.clone(),
                    root_index,
                };
                match session.steps.get(&step.step) {
                    None => {
                        session.steps.insert(step.step, current);
                    }
                    Some(existing) => {
                        if !same_step(&existing.step, &step) {
                            session.conflict = true;
                        }
                        let existing_ts = existing.step.timestamp.unwrap_or(i64::MIN);
                        let next_ts = step.timestamp.unwrap_or(i64::MIN);
                        if next_ts > existing_ts
                            || (next_ts == existing_ts && root_index >= existing.root_index)
                        {
                            session.steps.insert(step.step, current);
                        }
                    }
                }
            }
        }
    }

    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut saw_completed = 0u64;
    let mut token_rows = 0u64;
    let mut duplicate_sessions = 0u64;
    let mut conflicting_sessions = 0u64;

    for (session_id, session) in &sessions {
        if session.copies > 1 {
            duplicate_sessions = duplicate_sessions.saturating_add(1);
            stats.duplicate_session_groups = stats.duplicate_session_groups.saturating_add(1);
        }
        if session.conflict {
            conflicting_sessions = conflicting_sessions.saturating_add(1);
            stats.conflict_session_groups = stats.conflict_session_groups.saturating_add(1);
        }
        let wanted_steps: Vec<u64> = session
            .steps
            .values()
            .filter_map(|merged| {
                let step = &merged.step;
                let total = step
                    .input
                    .saturating_add(step.output)
                    .saturating_add(step.cache_read)
                    .saturating_add(step.cache_creation);
                (step.kind == KIND_PLANNER && step.status.as_deref() == Some("DONE") && total > 0)
                    .then_some(step.step)
            })
            .collect();
        let timings = session
            .native_db
            .as_deref()
            .map(|path| read_native_timing(path, &wanted_steps))
            .unwrap_or_default();
        let mut current_model: Option<String> = None;
        let mut current_raw_model: Option<String> = None;
        for merged in session.steps.values() {
            let step = &merged.step;
            match step.kind {
                KIND_USER => {
                    if let Some(selection) = step.selection.as_deref() {
                        current_raw_model = Some(selection.to_owned());
                        current_model = normalize_model(selection);
                    }
                }
                KIND_PLANNER => {
                    saw_completed = saw_completed.saturating_add(1);
                    if step.status.as_deref() != Some("DONE") {
                        continue;
                    }
                    let total = step
                        .input
                        .saturating_add(step.output)
                        .saturating_add(step.cache_read)
                        .saturating_add(step.cache_creation);
                    if total == 0 {
                        continue;
                    }
                    token_rows = token_rows.saturating_add(1);
                    let Some(timestamp) = step.timestamp else {
                        continue;
                    };
                    let raw_model = step.model.clone().or_else(|| current_raw_model.clone());
                    // Orchestrator 等无公开模型 ID 的标签保留原始显示名：不猜测
                    // 映射、不参与计价，但模型用量与请求日志都不再落到 unknown。
                    let model = raw_model
                        .as_deref()
                        .and_then(normalize_model)
                        .or_else(|| current_model.clone())
                        .or_else(|| raw_model.clone());
                    let sample = UsageSample {
                        timestamp_millis: timestamp,
                        model: model.as_deref(),
                        input: step.input,
                        output: step.output,
                        cache_read: step.cache_read,
                        cache_creation: step.cache_creation,
                        cache_creation_1h: 0,
                        project: session.project.as_deref(),
                    };
                    if builder.record(sample) {
                        stats.usage_records = stats.usage_records.saturating_add(1);
                    }
                    let timing = timings.get(&step.step);
                    builder.record_request(RequestRecord {
                        key: antigravity_request_key(session_id, step.step),
                        timestamp_millis: timestamp,
                        model,
                        raw_model,
                        project: session.project.clone(),
                        input: step.input,
                        output: step.output,
                        cache_read: step.cache_read,
                        cache_creation: step.cache_creation,
                        cache_creation_1h: 0,
                        fidelity: "exact".to_owned(),
                        latency_ms: timing.map(|value| value.latency_ms),
                        first_token_ms: timing.map(|value| value.first_token_ms),
                    });
                }
                _ => {}
            }
        }
    }

    let mut notes = Vec::new();
    if saw_completed == 0 {
        notes.push("未发现可计量的完成响应".to_owned());
    } else if token_rows == 0 {
        notes.push("Antigravity 会话未记录 Token（旧版 CLI 或无计量字段），未计入用量".to_owned());
    } else if token_rows < saw_completed {
        notes.push(format!(
            "Antigravity {} 个完成响应未记录 Token，已跳过",
            saw_completed - token_rows
        ));
    }
    if token_rows > 0 && stats.usage_records == 0 {
        notes.push("Antigravity 响应均不在采集窗口内".to_owned());
    }
    if duplicate_sessions > 0 {
        notes.push(format!(
            "Antigravity {duplicate_sessions} 个会话在 CLI/IDE 多根出现，已按 step 合并"
        ));
    }
    if conflicting_sessions > 0 {
        notes.push(format!(
            "Antigravity {conflicting_sessions} 个会话副本存在差异，已取较新 step"
        ));
    }
    if stats.io_errors > 0 {
        notes.push(format!(
            "Antigravity {} 个会话读取失败，已跳过",
            stats.io_errors
        ));
    }

    let mut result = finish(window, builder, stats, found);
    result.notice = (!notes.is_empty()).then(|| notes.join("；"));
    Ok(result)
}

fn antigravity_request_key(session_id: &str, step: u64) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"antigravity-request:");
    hasher.update(session_id.as_bytes());
    hasher.update(b":");
    hasher.update(step.to_string().as_bytes());
    let digest = hasher.finalize();
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    format!("{:032x}", u128::from_be_bytes(bytes))
}

/// Read exact first-token / total latency from Antigravity's native conversation
/// database when it is available. Missing or locked native stores are ignored:
/// the request still imports with token counters and a `—` speed.
fn read_native_timing(path: &Path, wanted_steps: &[u64]) -> HashMap<u64, NativeTiming> {
    let mut result = HashMap::new();
    if wanted_steps.is_empty() || !path.is_file() {
        return result;
    }
    let Ok(connection) = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return result;
    };
    let _ = connection.busy_timeout(Duration::from_millis(300));
    let wanted: std::collections::HashSet<u64> = wanted_steps.iter().copied().collect();
    let mut generations = HashMap::new();
    if let Ok(mut statement) = connection.prepare("SELECT idx, metadata FROM steps") {
        if let Ok(rows) = statement.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Option<Vec<u8>>>(1)?))
        }) {
            for row in rows.flatten() {
                let Ok(step) = u64::try_from(row.0) else {
                    continue;
                };
                if !wanted.contains(&step) {
                    continue;
                }
                if let Some(metadata) = row.1.as_deref() {
                    if let Some(generation) = step_generation(metadata) {
                        generations.insert(step, generation);
                    }
                }
            }
        }
    }
    if generations.is_empty() {
        return result;
    }
    let mut generation_ids: Vec<u64> = generations.values().copied().collect();
    generation_ids.sort_unstable();
    generation_ids.dedup();
    let mut timings = HashMap::new();
    for chunk in generation_ids.chunks(400) {
        let placeholders = vec!["?"; chunk.len()].join(", ");
        let values: Vec<SqlValue> = chunk
            .iter()
            .map(|value| SqlValue::Integer(*value as i64))
            .collect();
        let sql = format!("SELECT idx, data FROM gen_metadata WHERE idx IN ({placeholders})");
        let Ok(mut statement) = connection.prepare(&sql) else {
            continue;
        };
        let Ok(rows) = statement.query_map(params_from_iter(values.iter()), |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Option<Vec<u8>>>(1)?))
        }) else {
            continue;
        };
        for row in rows.flatten() {
            let Ok(index) = u64::try_from(row.0) else {
                continue;
            };
            if let Some(data) = row.1.as_deref() {
                if let Some(timing) = timing_from_generation(data) {
                    timings.insert(index, timing);
                }
            }
        }
    }
    for (step, generation) in generations {
        if let Some(timing) = timings.get(&generation) {
            result.insert(step, *timing);
        }
    }
    result
}

/// `steps.metadata` -> field 20 (generation reference) -> field 3 index.
fn step_generation(metadata: &[u8]) -> Option<u64> {
    let reference = message_field(metadata, 20)?;
    Some(varint_field(reference, 3).unwrap_or(0))
}

/// `gen_metadata.data` -> field 1 (response) -> field 11 / 12 durations.
fn timing_from_generation(data: &[u8]) -> Option<NativeTiming> {
    let response = message_field(data, 1)?;
    let first_token_ms = duration_millis(message_field(response, 11)?)?;
    let streaming_ms = duration_millis(message_field(response, 12)?)?;
    let latency_ms = first_token_ms.checked_add(streaming_ms)?;
    (latency_ms > 0).then_some(NativeTiming {
        first_token_ms,
        latency_ms,
    })
}

fn duration_millis(data: &[u8]) -> Option<i64> {
    let seconds = i64::try_from(varint_field(data, 1).unwrap_or(0)).ok()?;
    let nanos = i64::try_from(varint_field(data, 2).unwrap_or(0)).ok()?;
    seconds
        .checked_mul(1000)?
        .checked_add(nanos / 1_000_000)
        .filter(|value| *value >= 0)
}

fn message_field(bytes: &[u8], target: u64) -> Option<&[u8]> {
    let mut position = 0;
    while position < bytes.len() {
        let (field, wire) = next_key(bytes, &mut position)?;
        match wire {
            0 => {
                read_varint(bytes, &mut position)?;
            }
            1 => position = position.checked_add(8)?,
            2 => {
                let length = usize::try_from(read_varint(bytes, &mut position)?).ok()?;
                let end = position.checked_add(length)?;
                if end > bytes.len() {
                    return None;
                }
                if field == target {
                    return Some(&bytes[position..end]);
                }
                position = end;
            }
            5 => position = position.checked_add(4)?,
            _ => return None,
        }
    }
    None
}

fn varint_field(bytes: &[u8], target: u64) -> Option<u64> {
    let mut position = 0;
    while position < bytes.len() {
        let (field, wire) = next_key(bytes, &mut position)?;
        if wire == 0 {
            let value = read_varint(bytes, &mut position)?;
            if field == target {
                return Some(value);
            }
            continue;
        }
        match wire {
            1 => position = position.checked_add(8)?,
            2 => {
                let length = usize::try_from(read_varint(bytes, &mut position)?).ok()?;
                position = position.checked_add(length)?;
            }
            5 => position = position.checked_add(4)?,
            _ => return None,
        }
    }
    None
}

fn next_key(bytes: &[u8], position: &mut usize) -> Option<(u64, u8)> {
    let key = read_varint(bytes, position)?;
    Some((key >> 3, (key & 7) as u8))
}

fn read_varint(bytes: &[u8], position: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while *position < bytes.len() && shift < 64 {
        let byte = bytes[*position];
        *position += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

fn load_steps(
    transcript: &Path,
    mtime_ns: u64,
    size: u64,
    cache_path: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<Vec<CachedStep>, SourceScanError> {
    let loaded = load_json_cache::<CacheEntry>(cache_path);
    let old_steps = match &loaded {
        CacheLoad::Entry(entry) if entry.version == ANTIGRAVITY_CACHE_VERSION => {
            Some(entry.steps.clone())
        }
        CacheLoad::Corrupt => {
            stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
            None
        }
        _ => None,
    };
    if let CacheLoad::Entry(entry) = &loaded {
        if entry.version == ANTIGRAVITY_CACHE_VERSION
            && entry.mtime_ns == mtime_ns
            && entry.size == size
        {
            stats.cache_hits = stats.cache_hits.saturating_add(1);
            return Ok(entry.steps.clone());
        }
    }
    stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
    match parse_transcript(transcript, window, cancellation, stats) {
        Ok(steps) => {
            stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
            let entry = CacheEntry {
                version: ANTIGRAVITY_CACHE_VERSION,
                mtime_ns,
                size,
                steps: steps.clone(),
            };
            if let Err(error) = write_json_atomic(cache_path, &entry, cancellation) {
                match error {
                    SourceScanError::Runtime(error) => return Err(error.into()),
                    SourceScanError::Io(_) => {
                        stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
                    }
                }
            }
            Ok(steps)
        }
        Err(SourceScanError::Runtime(error)) => Err(error.into()),
        Err(SourceScanError::Io(error)) => {
            stats.io_errors = stats.io_errors.saturating_add(1);
            if let Some(steps) = old_steps {
                Ok(steps)
            } else {
                Err(error.into())
            }
        }
    }
}

fn parse_transcript(
    path: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<Vec<CachedStep>, SourceScanError> {
    let file = File::open(path)?;
    let mut reader = BufReader::with_capacity(READ_BUFFER_BYTES, file);
    let mut line_buffer = Vec::new();
    let mut steps: BTreeMap<u64, CachedStep> = BTreeMap::new();
    loop {
        cancellation.check()?;
        let Some(line) = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES, &mut line_buffer)?
        else {
            break;
        };
        stats.lines_seen = stats.lines_seen.saturating_add(1);
        stats.bytes_read = stats.bytes_read.saturating_add(line_buffer.len() as u64);
        if line.truncated {
            stats.truncated_lines = stats.truncated_lines.saturating_add(1);
            continue;
        }
        let value: Value = match serde_json::from_slice(trim_line_end(&line_buffer)) {
            Ok(value) => value,
            Err(_) => {
                stats.malformed_lines = stats.malformed_lines.saturating_add(1);
                continue;
            }
        };
        stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
        let Some(step_index) = value.get("step_index").and_then(Value::as_u64) else {
            continue;
        };
        let kind = match value.get("type").and_then(Value::as_str) {
            Some("USER_INPUT") => KIND_USER,
            Some("PLANNER_RESPONSE") => KIND_PLANNER,
            _ => continue,
        };
        let timestamp = value
            .get("created_at")
            .and_then(Value::as_str)
            .and_then(|value| window.epoch_from_iso(value))
            .map(|value| value.saturating_mul(1000));
        let step = if kind == KIND_USER {
            CachedStep {
                step: step_index,
                kind,
                status: None,
                timestamp,
                model: None,
                selection: value
                    .get("content")
                    .and_then(Value::as_str)
                    .and_then(model_selection),
                input: 0,
                output: 0,
                cache_read: 0,
                cache_creation: 0,
            }
        } else {
            CachedStep {
                step: step_index,
                kind,
                status: value
                    .get("status")
                    .and_then(Value::as_str)
                    .map(str::to_owned),
                timestamp,
                model: value
                    .get("model")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty() && !value.eq_ignore_ascii_case("unknown"))
                    .map(str::to_owned),
                selection: None,
                input: number(value.get("input_tokens")),
                output: number(value.get("output_tokens")),
                cache_read: number(value.get("cache_read_tokens")),
                cache_creation: number(value.get("cache_write_tokens"))
                    .max(number(value.get("cache_creation_tokens"))),
            }
        };
        steps.insert(step_index, step);
    }
    Ok(steps.into_values().collect())
}

fn read_projects(brain_root: &Path) -> HashMap<String, String> {
    let Some(app_dir) = brain_root.parent() else {
        return HashMap::new();
    };
    let db = app_dir.join("conversation_summaries.db");
    if !db.is_file() {
        return HashMap::new();
    }
    let Ok(connection) = Connection::open_with_flags(
        &db,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return HashMap::new();
    };
    let _ = connection.busy_timeout(Duration::from_millis(300));
    let Ok(mut statement) =
        connection.prepare("SELECT conversation_id, workspace_uris FROM conversation_summaries")
    else {
        return HashMap::new();
    };
    let Ok(rows) = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    }) else {
        return HashMap::new();
    };
    let mut projects = HashMap::new();
    for row in rows.flatten() {
        let (session_id, uris) = row;
        if !valid_session_id(&session_id) {
            continue;
        }
        let Some(project) = first_project(&uris) else {
            continue;
        };
        projects.insert(session_id, project);
    }
    projects
}

fn first_project(uris: &str) -> Option<String> {
    let values: Vec<String> = serde_json::from_str(uris).ok()?;
    let first = values.into_iter().next()?;
    let path = first.strip_prefix("file://").unwrap_or(&first);
    let decoded = percent_decode(path);
    Path::new(&decoded)
        .file_name()
        .and_then(|value| value.to_str())
        .map(str::to_owned)
        .filter(|value| !value.is_empty())
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' && index + 2 < bytes.len() {
            if let (Some(high), Some(low)) = (hex(bytes[index + 1]), hex(bytes[index + 2])) {
                output.push(high * 16 + low);
                index += 3;
                continue;
            }
        }
        output.push(bytes[index]);
        index += 1;
    }
    String::from_utf8_lossy(&output).into_owned()
}

fn hex(value: u8) -> Option<u8> {
    match value {
        b'0'..=b'9' => Some(value - b'0'),
        b'a'..=b'f' => Some(value - b'a' + 10),
        b'A'..=b'F' => Some(value - b'A' + 10),
        _ => None,
    }
}

fn model_selection(content: &str) -> Option<String> {
    let start = content.find("Model Selection")?;
    let rest = &content[start..];
    let to = rest.find(" to ")? + 4;
    let tail = &rest[to..];
    let end = tail
        .find(". ")
        .or_else(|| tail.find('\n'))
        .or_else(|| tail.find('`'))
        .unwrap_or(tail.len());
    let model = tail[..end].trim().trim_matches('.').trim();
    if model.is_empty() || model.eq_ignore_ascii_case("none") {
        None
    } else {
        Some(model.to_owned())
    }
}

fn normalize_model(display: &str) -> Option<String> {
    let display = display.trim();
    if display.is_empty()
        || display.eq_ignore_ascii_case("none")
        || display.eq_ignore_ascii_case("unknown")
    {
        return None;
    }
    let lower = display.to_ascii_lowercase();
    if lower.contains("orchestrator") || lower == "gemini-api" {
        return None;
    }
    let mut id = if display.contains(' ') {
        lower
            .replace(" (", "-")
            .replace(['(', ')'], "")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join("-")
    } else {
        lower
    };
    for suffix in [
        "-xhigh", "-high", "-medium", "-low", "-max", "-trial", "-tiered", "-n",
    ] {
        if let Some(stripped) = id.strip_suffix(suffix) {
            id = stripped.to_owned();
            break;
        }
    }
    (!id.is_empty()).then_some(id)
}

fn same_step(left: &CachedStep, right: &CachedStep) -> bool {
    left.kind == right.kind
        && left.status == right.status
        && left.model == right.model
        && left.selection == right.selection
        && left.input == right.input
        && left.output == right.output
        && left.cache_read == right.cache_read
        && left.cache_creation == right.cache_creation
}

fn number(value: Option<&Value>) -> u64 {
    value.and_then(Value::as_u64).unwrap_or(0)
}

fn valid_session_id(value: &str) -> bool {
    !value.is_empty()
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
}

fn modified_ns(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos() as u64)
        .unwrap_or_else(|| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map_or(0, |value| value.as_nanos() as u64)
        })
}

fn cache_path(cache_dir: &Path, transcript: &Path) -> PathBuf {
    let mut hasher = Sha256::new();
    hasher.update(transcript.to_string_lossy().as_bytes());
    cache_dir.join(format!("{:x}.json", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "bruce-antigravity-{name}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn window() -> CollectionWindow {
        let context = json!({
            "now": "2026-11-19T12:00:00Z",
            "timezone": "UTC",
            "days": 2
        });
        CollectionWindow::from_context(context.as_object().unwrap()).unwrap()
    }

    fn write_transcript(root: &Path, session: &str, rows: &[Value]) -> PathBuf {
        let path = root.join(session).join(TRANSCRIPT_RELATIVE);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut body = String::new();
        for row in rows {
            body.push_str(&serde_json::to_string(row).unwrap());
            body.push('\n');
        }
        fs::write(&path, body).unwrap();
        path
    }

    fn planner(step: u64, input: u64, output: u64, cache_read: u64) -> Value {
        json!({
            "step_index": step,
            "type": "PLANNER_RESPONSE",
            "status": "DONE",
            "created_at": "2026-11-19T10:00:00Z",
            "input_tokens": input,
            "output_tokens": output,
            "cache_read_tokens": cache_read
        })
    }

    #[test]
    fn token_semantics_and_model_inheritance() {
        let root = temp_dir("tokens");
        let cache = temp_dir("tokens-cache");
        write_transcript(
            &root,
            "session-a",
            &[
                json!({
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-19T09:59:00Z",
                    "content": "Model Selection` from None to Gemini 3.6 Flash (High). No need to comment."
                }),
                planner(1, 100, 5, 20),
            ],
        );
        let scan = scan_antigravity_cached(
            std::slice::from_ref(&root),
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        let bucket = scan.contribution.by_day.values().next().unwrap();
        assert_eq!(bucket.input, 100, "input excludes cache");
        assert_eq!(bucket.cache_read, 20);
        assert_eq!(bucket.output, 5);
        assert_eq!(bucket.total, 125);
        assert_eq!(scan.contribution.models_today[0].model, "gemini-3.6-flash");
        assert_eq!(scan.stats.usage_records, 1);
        assert_eq!(scan.requests.len(), 1);
        let request = &scan.requests[0];
        assert_eq!(request.key.len(), 32);
        assert_eq!(request.model.as_deref(), Some("gemini-3.6-flash"));
        assert_eq!(
            request.raw_model.as_deref(),
            Some("Gemini 3.6 Flash (High)")
        );
        assert_eq!(
            (request.input, request.output, request.cache_read),
            (100, 5, 20)
        );
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(cache);
    }

    #[test]
    fn orchestrator_rows_keep_raw_label_without_pricing_guess() {
        let root = temp_dir("orchestrator-label");
        let cache = temp_dir("orchestrator-label-cache");
        write_transcript(
            &root,
            "session-o",
            &[
                json!({
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-19T09:59:00Z",
                    "content": "Model Selection` from None to Orchestrator (Neon)."
                }),
                planner(1, 100, 5, 0),
            ],
        );
        let scan = scan_antigravity_cached(
            std::slice::from_ref(&root),
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(
            scan.contribution.models_today[0].model, "Orchestrator (Neon)",
            "模型用量不得落回 unknown"
        );
        assert_eq!(scan.requests.len(), 1);
        assert_eq!(
            scan.requests[0].model.as_deref(),
            Some("Orchestrator (Neon)")
        );
        assert_eq!(
            scan.requests[0].raw_model.as_deref(),
            Some("Orchestrator (Neon)")
        );
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(cache);
    }

    #[test]
    fn same_step_last_write_wins_and_cache_is_warm() {
        let root = temp_dir("rewrite");
        let cache = temp_dir("rewrite-cache");
        write_transcript(
            &root,
            "session-b",
            &[
                json!({
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-19T09:59:00Z",
                    "content": "Model Selection` from None to Gemini 4 Pro (Low)."
                }),
                planner(1, 10, 1, 0),
                planner(1, 10, 9, 0),
            ],
        );
        let first = scan_antigravity_cached(
            std::slice::from_ref(&root),
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(first.contribution.by_day.values().next().unwrap().output, 9);
        let second = scan_antigravity_cached(
            std::slice::from_ref(&root),
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        assert_eq!(first.contribution, second.contribution);
        assert!(second.stats.cache_hits > 0);
        assert_eq!(second.stats.json_lines_parsed, 0);
        assert_eq!(second.contribution.models_today[0].model, "gemini-4-pro");
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(cache);
    }

    #[test]
    fn cli_without_tokens_is_visible_not_error() {
        let root = temp_dir("cli");
        let cache = temp_dir("cli-cache");
        write_transcript(
            &root,
            "session-c",
            &[json!({
                "step_index": 1,
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-19T10:00:00Z"
            })],
        );
        let scan = scan_antigravity_cached(
            std::slice::from_ref(&root),
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        assert!(scan.found);
        assert!(scan.diagnostic.is_none());
        assert!(scan.contribution.by_day.is_empty());
        assert!(scan.notice.unwrap_or_default().contains("未记录 Token"));
        let _ = fs::remove_dir_all(root);
        let _ = fs::remove_dir_all(cache);
    }

    #[test]
    fn duplicate_roots_merge_steps_once() {
        let cli = temp_dir("dual-cli");
        let ide = temp_dir("dual-ide");
        let cache = temp_dir("dual-cache");
        write_transcript(
            &cli,
            "session-d",
            &[
                json!({
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-19T09:59:00Z",
                    "content": "Model Selection` from None to Gemini 3.6 Flash (High)."
                }),
                planner(1, 10, 1, 0),
            ],
        );
        write_transcript(
            &ide,
            "session-d",
            &[
                json!({
                    "step_index": 0,
                    "type": "USER_INPUT",
                    "status": "DONE",
                    "created_at": "2026-11-19T09:59:00Z",
                    "content": "Model Selection` from None to Gemini 3.6 Flash (High)."
                }),
                planner(1, 10, 1, 0),
                planner(2, 20, 2, 0),
            ],
        );
        let scan = scan_antigravity_cached(
            &[cli.clone(), ide.clone()],
            &window(),
            &cache,
            &CancellationToken::new(),
        )
        .unwrap();
        let bucket = scan.contribution.by_day.values().next().unwrap();
        assert_eq!(bucket.input, 30, "step 1 counted once + step 2");
        assert_eq!(bucket.output, 3);
        assert_eq!(scan.stats.duplicate_session_groups, 1);
        assert!(scan.notice.unwrap_or_default().contains("多根"));
        let _ = fs::remove_dir_all(cli);
        let _ = fs::remove_dir_all(ide);
        let _ = fs::remove_dir_all(cache);
    }

    fn encode_varint(mut value: u64) -> Vec<u8> {
        let mut bytes = Vec::new();
        loop {
            let byte = (value & 0x7f) as u8;
            value >>= 7;
            if value == 0 {
                bytes.push(byte);
                return bytes;
            }
            bytes.push(byte | 0x80);
        }
    }

    fn encode_varint_field(field: u64, value: u64) -> Vec<u8> {
        let mut bytes = encode_varint(field << 3);
        bytes.extend(encode_varint(value));
        bytes
    }

    fn encode_bytes_field(field: u64, payload: &[u8]) -> Vec<u8> {
        let mut bytes = encode_varint((field << 3) | 2);
        bytes.extend(encode_varint(payload.len() as u64));
        bytes.extend_from_slice(payload);
        bytes
    }

    fn duration(seconds: u64, nanos: u64) -> Vec<u8> {
        let mut bytes = encode_varint_field(1, seconds);
        bytes.extend(encode_varint_field(2, nanos));
        bytes
    }

    #[test]
    fn native_timing_decodes_duration_fields() {
        let mut response = encode_bytes_field(11, &duration(1, 0));
        response.extend(encode_bytes_field(12, &duration(1, 500_000_000)));
        let generation = encode_bytes_field(1, &response);
        let timing = timing_from_generation(&generation).unwrap();
        assert_eq!(timing.first_token_ms, 1_000);
        assert_eq!(timing.latency_ms, 2_500);
        let metadata = encode_bytes_field(20, &encode_varint_field(3, 7));
        assert_eq!(step_generation(&metadata), Some(7));
    }

    #[test]
    fn native_timing_reads_the_session_database() {
        let dir = temp_dir("native-timing");
        let path = dir.join("session.db");
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE steps (idx INTEGER PRIMARY KEY, metadata BLOB);
                 CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB);",
            )
            .unwrap();
        let metadata = encode_bytes_field(20, &encode_varint_field(3, 7));
        let mut response = encode_bytes_field(11, &duration(0, 800_000_000));
        response.extend(encode_bytes_field(12, &duration(1, 200_000_000)));
        let data = encode_bytes_field(1, &response);
        connection
            .execute(
                "INSERT INTO steps (idx, metadata) VALUES (5, ?1)",
                rusqlite::params![metadata],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO gen_metadata (idx, data) VALUES (7, ?1)",
                rusqlite::params![data],
            )
            .unwrap();
        drop(connection);
        let timings = read_native_timing(&path, &[5, 6]);
        assert_eq!(timings.len(), 1);
        let timing = timings.get(&5).unwrap();
        assert_eq!(timing.first_token_ms, 800);
        assert_eq!(timing.latency_ms, 2_000);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn model_selection_parser_is_bounded() {
        assert_eq!(
            model_selection("Model Selection` from None to Gemini 3.8 Flash (High). No need"),
            Some("Gemini 3.8 Flash (High)".to_owned())
        );
        assert_eq!(
            normalize_model("Gemini 3.8 Flash (High)"),
            Some("gemini-3.8-flash".to_owned())
        );
        assert_eq!(normalize_model("Orchestrator Carbon"), None);
        assert_eq!(normalize_model("gemini-api"), None);
    }
}
