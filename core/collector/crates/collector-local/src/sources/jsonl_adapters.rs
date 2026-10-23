use super::codebuddy::{
    codebuddy_message_id, codebuddy_model, codebuddy_scope, codebuddy_usage, CodeBuddyUsage,
};
use super::{
    grok_content, number_u64, parse_json_line, project_from_parent, record, timestamp_number,
    ClaudeUsage, SourceScan, SourceScanError,
};
use crate::jsonl_cache::{
    scan_cached_jsonl_tree, scan_jsonl_file_from_offset, CachedFilePayload, CachedUsageObservation,
    JsonlCacheAdapter, JsonlCacheConfig,
};
use crate::{CompactContribution, ScanStats};
use collector_domain::{CollectionWindow, UsageContribution, UsageContributionBuilder};
use collector_runtime::CancellationToken;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

const JSONL_CACHE_PARSER_VERSION: u32 = 1;
const JSONL_CACHE_AGGREGATION_VERSION: u32 = 1;

pub(super) fn jsonl_cache_config(
    cache_root: &Path,
    source_id: &str,
    window: &CollectionWindow,
) -> JsonlCacheConfig {
    JsonlCacheConfig {
        cache_root: cache_root.to_owned(),
        source_id: source_id.to_owned(),
        parser_version: JSONL_CACHE_PARSER_VERSION,
        aggregation_version: JSONL_CACHE_AGGREGATION_VERSION,
        window: window.clone(),
    }
}

fn invalid_cached_payload() -> SourceScanError {
    SourceScanError::Io(io::Error::new(
        io::ErrorKind::InvalidData,
        "jsonl cache contribution is incompatible with the collection window",
    ))
}

fn compact_payload(
    observations: Vec<CachedUsageObservation>,
    contribution: UsageContribution,
    window: &CollectionWindow,
) -> CachedFilePayload {
    let compact = CompactContribution::from_domain(&contribution, window)
        .expect("usage contribution built for the same window must be compactable");
    CachedFilePayload {
        contribution: compact,
        observations,
    }
}

fn payload_from_observations(
    observations: Vec<CachedUsageObservation>,
    window: &CollectionWindow,
) -> CachedFilePayload {
    let mut builder = UsageContributionBuilder::new(window.clone());
    for observation in &observations {
        record(
            &mut builder,
            observation.timestamp_millis,
            observation.model.as_deref(),
            observation.input,
            observation.output,
            observation.cache_read,
            observation.cache_creation,
            observation.project.as_deref(),
        );
    }
    compact_payload(observations, builder.contribution(), window)
}

fn merge_additive_payloads(
    previous: &CachedFilePayload,
    appended: &CachedFilePayload,
    window: &CollectionWindow,
) -> CachedFilePayload {
    let (Some(previous), Some(appended)) = (
        previous.contribution.to_domain(window),
        appended.contribution.to_domain(window),
    ) else {
        return appended.clone();
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    if !builder.merge_contribution(&previous) || !builder.merge_contribution(&appended) {
        return compact_payload(Vec::new(), appended, window);
    }
    compact_payload(Vec::new(), builder.contribution(), window)
}

fn aggregate_additive_payloads(
    payloads: &[CachedFilePayload],
    window: &CollectionWindow,
) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
    let mut builder = UsageContributionBuilder::new(window.clone());
    for payload in payloads {
        let Some(contribution) = payload.contribution.to_domain(window) else {
            return Err(invalid_cached_payload());
        };
        if !builder.merge_contribution(&contribution) {
            return Err(invalid_cached_payload());
        }
    }
    Ok((builder.contribution(), !payloads.is_empty(), None))
}

fn parse_cached_file<F>(
    path: &Path,
    modified: f64,
    start_offset: u64,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
    mut parse: F,
) -> Result<CachedFilePayload, SourceScanError>
where
    F: FnMut(&Path, f64, Value, &mut ScanStats) -> Option<CachedUsageObservation>,
{
    let mut observations = Vec::new();
    scan_jsonl_file_from_offset(
        path,
        start_offset,
        cancellation,
        stats,
        |path, line, stats| {
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
            if let Some(observation) = parse(path, modified, value, stats) {
                observations.push(observation);
            }
        },
    )?;
    Ok(payload_from_observations(observations, window))
}

pub(super) struct KimiWorkJsonlAdapter;

impl JsonlCacheAdapter for KimiWorkJsonlAdapter {
    fn source_id(&self) -> &'static str {
        "kimi-work"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            window,
            cancellation,
            stats,
            |_, _, value, stats| {
                if value.get("type").and_then(Value::as_str) != Some("usage.record") {
                    stats.ignored_lines = stats.ignored_lines.saturating_add(1);
                    return None;
                }
                let Some(timestamp) = timestamp_number(value.get("time")) else {
                    stats.malformed_lines = stats.malformed_lines.saturating_add(1);
                    return None;
                };
                let usage = value.get("usage");
                stats.usage_records = stats.usage_records.saturating_add(1);
                Some(CachedUsageObservation {
                    dedupe_key: None,
                    timestamp_millis: timestamp,
                    model: value
                        .get("model")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    input: number_u64(usage.and_then(|value| value.get("inputOther"))),
                    output: number_u64(usage.and_then(|value| value.get("output"))),
                    cache_read: number_u64(usage.and_then(|value| value.get("inputCacheRead"))),
                    cache_creation: number_u64(
                        usage.and_then(|value| value.get("inputCacheCreation")),
                    ),
                    project: None,
                })
            },
        )
    }

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        _modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload {
        merge_additive_payloads(previous, appended, window)
    }

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        aggregate_additive_payloads(payloads, window)
    }
}

pub fn scan_kimi_tree_cached(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_cached_jsonl_tree(
        root,
        &jsonl_cache_config(cache_root, "kimi-work", window),
        &KimiWorkJsonlAdapter,
        cancellation,
    )
}

struct ClaudeJsonlAdapter;

pub(super) fn digest_source_key(source_id: &str, value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-jsonl-dedupe-v1\0");
    hasher.update(source_id.as_bytes());
    hasher.update([0]);
    hasher.update(value.as_bytes());
    format!("{:x}", hasher.finalize())
}

fn claude_observation(
    path: &Path,
    window: &CollectionWindow,
    value: &Value,
) -> Option<CachedUsageObservation> {
    if value.get("type").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let timestamp = value
        .get("timestamp")
        .and_then(Value::as_str)
        .and_then(|value| window.epoch_from_iso(value))
        .map(|value| value.saturating_mul(1000))?;
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
    Some(CachedUsageObservation {
        dedupe_key: message
            .get("id")
            .and_then(Value::as_str)
            .map(|id| digest_source_key("claude-message", id)),
        timestamp_millis: timestamp,
        model: message
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned),
        input: number_u64(usage.get("input_tokens")),
        output: number_u64(usage.get("output_tokens")),
        cache_read: number_u64(usage.get("cache_read_input_tokens")),
        cache_creation: number_u64(usage.get("cache_creation_input_tokens")),
        project,
    })
}

fn claude_usage_from_observation(observation: &CachedUsageObservation) -> ClaudeUsage {
    ClaudeUsage {
        input: observation.input,
        output: observation.output,
        cache_read: observation.cache_read,
        cache_creation: observation.cache_creation,
        timestamp_millis: observation.timestamp_millis,
        model: observation.model.clone(),
        project: observation.project.clone(),
    }
}

fn aggregate_claude_payloads(
    payloads: &[CachedFilePayload],
    window: &CollectionWindow,
) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
    let mut best = BTreeMap::<String, ClaudeUsage>::new();
    let mut direct = Vec::<ClaudeUsage>::new();
    for payload in payloads {
        if payload.contribution.to_domain(window).is_none() {
            return Err(invalid_cached_payload());
        }
        for observation in &payload.observations {
            let usage = claude_usage_from_observation(observation);
            if let Some(key) = observation.dedupe_key.as_ref() {
                let entry = best.entry(key.clone()).or_default();
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
        }
    }
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
    Ok((builder.contribution(), !payloads.is_empty(), None))
}

impl JsonlCacheAdapter for ClaudeJsonlAdapter {
    fn source_id(&self) -> &'static str {
        "claude-code"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            window,
            cancellation,
            stats,
            |path, _, value, stats| {
                let observation = claude_observation(path, window, &value);
                if observation.is_some() {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation
            },
        )
    }

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        _modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload {
        let mut observations = previous.observations.clone();
        observations.extend(appended.observations.iter().cloned());
        payload_from_observations(observations, window)
    }

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        aggregate_claude_payloads(payloads, window)
    }
}

pub fn scan_claude_cached(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_cached_jsonl_tree(
        root,
        &jsonl_cache_config(cache_root, "claude-code", window),
        &ClaudeJsonlAdapter,
        cancellation,
    )
}

struct CodeBuddyJsonlAdapter;

fn codebuddy_observation(
    path: &Path,
    value: &Value,
    stats: &mut ScanStats,
) -> Option<CachedUsageObservation> {
    let record_type = value.get("type").and_then(Value::as_str);
    if record_type != Some("message") && record_type != Some("function_call") {
        return None;
    }
    if record_type == Some("message")
        && value.get("role").and_then(Value::as_str) != Some("assistant")
    {
        return None;
    }
    let timestamp = timestamp_number(value.get("timestamp"))?;
    let (input, output, cache_read, cache_creation) = codebuddy_usage(value)?;
    stats.usage_records = stats.usage_records.saturating_add(1);
    let raw_key =
        codebuddy_message_id(value).map(|id| format!("{}::{id}", codebuddy_scope(path, value),));
    Some(CachedUsageObservation {
        dedupe_key: raw_key
            .as_deref()
            .map(|key| digest_source_key("codebuddy-message", key)),
        timestamp_millis: timestamp,
        model: codebuddy_model(value),
        input,
        output,
        cache_read,
        cache_creation,
        project: project_from_parent(path),
    })
}

fn codebuddy_usage_from_observation(observation: &CachedUsageObservation) -> CodeBuddyUsage {
    CodeBuddyUsage {
        input: observation.input,
        output: observation.output,
        cache_read: observation.cache_read,
        cache_creation: observation.cache_creation,
        timestamp_millis: observation.timestamp_millis,
        model: observation.model.clone(),
        project: observation.project.clone(),
    }
}

fn aggregate_codebuddy_payloads(
    payloads: &[CachedFilePayload],
    window: &CollectionWindow,
) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
    let mut best = BTreeMap::<String, CodeBuddyUsage>::new();
    let mut direct = Vec::<CodeBuddyUsage>::new();
    for payload in payloads {
        if payload.contribution.to_domain(window).is_none() {
            return Err(invalid_cached_payload());
        }
        for observation in &payload.observations {
            let usage = codebuddy_usage_from_observation(observation);
            if let Some(key) = observation.dedupe_key.as_ref() {
                let replace = match best.get(key) {
                    None => true,
                    Some(previous) => {
                        usage.total() > previous.total()
                            || (usage.total() == previous.total()
                                && usage.timestamp_millis > previous.timestamp_millis)
                    }
                };
                if replace {
                    best.insert(key.clone(), usage);
                }
            } else {
                direct.push(usage);
            }
        }
    }
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
    Ok((builder.contribution(), !payloads.is_empty(), None))
}

impl JsonlCacheAdapter for CodeBuddyJsonlAdapter {
    fn source_id(&self) -> &'static str {
        "codebuddy"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            window,
            cancellation,
            stats,
            |path, _, value, stats| codebuddy_observation(path, &value, stats),
        )
    }

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        _modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload {
        let mut observations = previous.observations.clone();
        observations.extend(appended.observations.iter().cloned());
        payload_from_observations(observations, window)
    }

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        aggregate_codebuddy_payloads(payloads, window)
    }
}

pub fn scan_codebuddy_cached(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_cached_jsonl_tree(
        root,
        &jsonl_cache_config(cache_root, "codebuddy", window),
        &CodeBuddyJsonlAdapter,
        cancellation,
    )
}

struct GrokJsonlAdapter;

fn grok_observation(path: &Path, modified: f64, value: &Value) -> Option<CachedUsageObservation> {
    let kind = value.get("type").and_then(Value::as_str);
    if kind != Some("user") && kind != Some("assistant") {
        return None;
    }
    let content = grok_content(value.get("content"));
    if content.is_empty() {
        return None;
    }
    let tokens = (content.chars().count() as u64 / 4).max(1);
    let project = path
        .parent()
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .map(str::to_owned);
    Some(CachedUsageObservation {
        dedupe_key: None,
        timestamp_millis: (modified * 1000.0) as i64,
        model: Some("grok".to_owned()),
        input: if kind == Some("user") { tokens } else { 0 },
        output: if kind == Some("assistant") { tokens } else { 0 },
        cache_read: 0,
        cache_creation: 0,
        project,
    })
}

impl JsonlCacheAdapter for GrokJsonlAdapter {
    fn source_id(&self) -> &'static str {
        "grok"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            window,
            cancellation,
            stats,
            |path, modified, value, stats| {
                let observation = grok_observation(path, modified, &value);
                if observation.is_some() {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation
            },
        )
    }

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload {
        let current_timestamp = (modified * 1000.0) as i64;
        let mut observations = previous.observations.clone();
        for observation in &mut observations {
            observation.timestamp_millis = current_timestamp;
        }
        observations.extend(appended.observations.iter().cloned());
        payload_from_observations(observations, window)
    }

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        aggregate_additive_payloads(payloads, window)
    }
}

pub fn scan_grok_cached(
    roots: &[PathBuf],
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let mut found = false;
    let mut diagnostic = None;
    for root in roots {
        let current = scan_cached_jsonl_tree(
            root,
            &jsonl_cache_config(cache_root, "grok", window),
            &GrokJsonlAdapter,
            cancellation,
        );
        match current {
            Ok(current) => {
                found |= current.found;
                stats.merge(current.stats);
                if diagnostic.is_none() {
                    diagnostic = current.diagnostic;
                }
                if !builder.merge_contribution(&current.contribution) {
                    return Err(invalid_cached_payload());
                }
            }
            Err(SourceScanError::Runtime(error)) => return Err(error.into()),
            Err(SourceScanError::Io(_)) => {
                stats.io_errors = stats.io_errors.saturating_add(1);
            }
        }
    }
    Ok(SourceScan {
        found,
        contribution: builder.contribution(),
        stats,
        diagnostic,
        capped: false,
    })
}

struct PiJsonlAdapter;

fn pi_observation(
    path: &Path,
    window: &CollectionWindow,
    value: &Value,
) -> Option<CachedUsageObservation> {
    let kind = value.get("type").and_then(Value::as_str);
    if kind == Some("session") || kind != Some("message") {
        return None;
    }
    let message = value.get("message").unwrap_or(&Value::Null);
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return None;
    }
    let usage = message.get("usage").unwrap_or(&Value::Null);
    if usage.is_null() {
        return None;
    }
    let timestamp = timestamp_number(message.get("timestamp")).or_else(|| {
        value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(|value| window.epoch_from_iso(value).map(|value| value * 1000))
    })?;
    Some(CachedUsageObservation {
        dedupe_key: None,
        timestamp_millis: if timestamp < 10_000_000_000 {
            timestamp * 1000
        } else {
            timestamp
        },
        model: message
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned),
        input: number_u64(usage.get("input")),
        output: number_u64(usage.get("output")).saturating_add(number_u64(usage.get("reasoning"))),
        cache_read: number_u64(usage.get("cacheRead")),
        cache_creation: number_u64(usage.get("cacheWrite")),
        project: project_from_parent(path),
    })
}

impl JsonlCacheAdapter for PiJsonlAdapter {
    fn source_id(&self) -> &'static str {
        "pi"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            window,
            cancellation,
            stats,
            |path, _, value, stats| {
                let observation = pi_observation(path, window, &value);
                if observation.is_some() {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation
            },
        )
    }

    fn merge_append(
        &self,
        previous: &CachedFilePayload,
        appended: &CachedFilePayload,
        _modified: f64,
        window: &CollectionWindow,
    ) -> CachedFilePayload {
        merge_additive_payloads(previous, appended, window)
    }

    fn aggregate(
        &self,
        payloads: &[CachedFilePayload],
        window: &CollectionWindow,
    ) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        aggregate_additive_payloads(payloads, window)
    }
}

pub fn scan_pi_cached(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_cached_jsonl_tree(
        root,
        &jsonl_cache_config(cache_root, "pi", window),
        &PiJsonlAdapter,
        cancellation,
    )
}
