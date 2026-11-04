use super::codebuddy::{codebuddy_message_id, codebuddy_model, codebuddy_scope, codebuddy_usage};
use super::{
    claude_cache_creation_1h, grok_content, line_may_match, number_u64, parse_json_line,
    project_from_parent, timestamp_number, SourceScan, SourceScanError,
};

/// 各 JSONL 适配器的解析前预筛子串 (C110): 只含判定所需的字面量, 是产出用量的必要条件。
const KIMI_USAGE_NEEDLES: &[&[u8]] = &[b"usage.record"];
const ASSISTANT_NEEDLES: &[&[u8]] = &[b"\"assistant\""];
const CODEBUDDY_NEEDLES: &[&[u8]] = &[b"\"assistant\"", b"\"function_call\""];
const GROK_NEEDLES: &[&[u8]] = &[b"\"user\"", b"\"assistant\""];
use crate::jsonl_cache::{
    scan_cached_jsonl_tree, scan_jsonl_file_from_offset, CachedFilePayload, DedupeKey,
    JsonlAggregator, JsonlCacheAdapter, JsonlCacheConfig, JsonlObservation, UsageProbe,
};
use crate::ScanStats;
use collector_domain::{
    CollectionWindow, UsageContribution, UsageContributionBuilder, UsageSample,
};
use collector_runtime::CancellationToken;
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::{Path, PathBuf};

/// v2 (C107): 观测值新增 Claude 1 小时 TTL 缓存写入份额; 旧条目按版本不匹配全量重建一次.
const JSONL_CACHE_PARSER_VERSION: u32 = 2;
const JSONL_CACHE_AGGREGATION_VERSION: u32 = 2;

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

/// 无去重的来源: 观测值按当前窗口逐条聚合 (C116: 缓存条目与窗口无关, 每次运行按当前窗口重建),
/// 逐文件并入后即丢弃载荷 (C176)。
pub(super) struct ObservationAggregator {
    builder: UsageContributionBuilder,
    absorbed: bool,
}

impl ObservationAggregator {
    fn new(window: &CollectionWindow) -> Self {
        Self {
            builder: UsageContributionBuilder::new(window.clone()),
            absorbed: false,
        }
    }
}

impl JsonlAggregator for ObservationAggregator {
    fn absorb(&mut self, payload: &CachedFilePayload) {
        self.absorbed = true;
        for observation in &payload.observations {
            let _ = self
                .builder
                .record(observation.sample(payload.project.as_deref()));
        }
    }

    fn finish(self) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        Ok((self.builder.contribution(), self.absorbed, None))
    }
}

/// 模型名与项目名驻留表 (C176): 去重表按下标引用, 不为每条观测复制字符串。
#[derive(Default)]
struct NameTable {
    names: Vec<String>,
    index: HashMap<String, u32>,
}

impl NameTable {
    fn intern(&mut self, value: &str) -> u32 {
        if let Some(&index) = self.index.get(value) {
            return index;
        }
        let index = self.names.len() as u32;
        self.names.push(value.to_owned());
        self.index.insert(value.to_owned(), index);
        index
    }

    fn name(&self, index: Option<u32>) -> Option<&str> {
        index.map(|index| self.names[index as usize].as_str())
    }
}

/// 去重期间保留的一条用量; 模型与项目为 `NameTable` 下标。
#[derive(Debug, Clone, Copy, Default)]
struct CompactUsage {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    cache_creation_1h: u64,
    timestamp_millis: i64,
    model: Option<u32>,
    project: Option<u32>,
}

impl CompactUsage {
    fn total(&self) -> u64 {
        self.input
            .saturating_add(self.output)
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
    }
}

/// 同一去重键多次出现时的取舍口径 (与参照实现一致)。
#[derive(Clone, Copy)]
pub(super) enum DedupeRule {
    /// Claude: 逐字段取最大 (流式写入的 usage 逐步增长), 时间戳 / 模型 / 项目取最后一次出现。
    FieldMaxLastSeen,
    /// CodeBuddy: 保留总量最大者, 总量相同取时间戳更晚者。
    LargestTotal,
}

/// 跨文件按消息 id 去重的来源 (Claude / CodeBuddy / dsh)。去重表须看完全部文件才能定稿, 但
/// 只保留定长键 + 紧凑用量; 产出顺序同旧实现: 去重表按键序, 其后为无 id 的观测 (按遍历顺序)。
pub(super) struct DedupedAggregator {
    window: CollectionWindow,
    rule: DedupeRule,
    best: BTreeMap<DedupeKey, CompactUsage>,
    direct: Vec<CompactUsage>,
    names: NameTable,
    absorbed: bool,
}

impl DedupedAggregator {
    pub(super) fn new(window: &CollectionWindow, rule: DedupeRule) -> Self {
        Self {
            window: window.clone(),
            rule,
            best: BTreeMap::new(),
            direct: Vec::new(),
            names: NameTable::default(),
            absorbed: false,
        }
    }
}

impl JsonlAggregator for DedupedAggregator {
    fn absorb(&mut self, payload: &CachedFilePayload) {
        self.absorbed = true;
        let project = payload
            .project
            .as_deref()
            .map(|project| self.names.intern(project));
        for observation in &payload.observations {
            let usage = CompactUsage {
                input: observation.input,
                output: observation.output,
                cache_read: observation.cache_read,
                cache_creation: observation.cache_creation,
                cache_creation_1h: observation.cache_creation_1h,
                timestamp_millis: observation.timestamp_millis,
                model: observation
                    .model
                    .as_deref()
                    .map(|model| self.names.intern(model)),
                project,
            };
            let Some(key) = observation.dedupe_key else {
                self.direct.push(usage);
                continue;
            };
            match self.rule {
                DedupeRule::FieldMaxLastSeen => {
                    let entry = self.best.entry(key).or_default();
                    entry.input = entry.input.max(usage.input);
                    entry.output = entry.output.max(usage.output);
                    entry.cache_read = entry.cache_read.max(usage.cache_read);
                    entry.cache_creation = entry.cache_creation.max(usage.cache_creation);
                    entry.cache_creation_1h = entry.cache_creation_1h.max(usage.cache_creation_1h);
                    entry.timestamp_millis = usage.timestamp_millis;
                    entry.model = usage.model;
                    entry.project = usage.project;
                }
                DedupeRule::LargestTotal => {
                    let replace = match self.best.get(&key) {
                        None => true,
                        Some(previous) => {
                            usage.total() > previous.total()
                                || (usage.total() == previous.total()
                                    && usage.timestamp_millis > previous.timestamp_millis)
                        }
                    };
                    if replace {
                        self.best.insert(key, usage);
                    }
                }
            }
        }
    }

    fn finish(self) -> Result<(UsageContribution, bool, Option<String>), SourceScanError> {
        let mut builder = UsageContributionBuilder::new(self.window);
        for usage in self.best.into_values().chain(self.direct) {
            let _ = builder.record(UsageSample {
                timestamp_millis: usage.timestamp_millis,
                model: self.names.name(usage.model),
                input: usage.input,
                output: usage.output,
                cache_read: usage.cache_read,
                cache_creation: usage.cache_creation,
                cache_creation_1h: usage.cache_creation_1h,
                project: self.names.name(usage.project),
            });
        }
        Ok((builder.contribution(), self.absorbed, None))
    }
}

/// 一行对 usage 口径哨兵 (C193) 的意义: 不是应带用量的行 / 是但取不到用量 / 解析出的观测。
pub(super) enum LineUsage {
    Skip,
    Missing,
    Usage(JsonlObservation),
}

impl From<Option<JsonlObservation>> for LineUsage {
    fn from(observation: Option<JsonlObservation>) -> Self {
        observation.map_or(Self::Skip, Self::Usage)
    }
}

fn observation_has_usage(observation: &JsonlObservation) -> bool {
    observation.input > 0
        || observation.output > 0
        || observation.cache_read > 0
        || observation.cache_creation > 0
}

#[allow(clippy::too_many_arguments)]
fn parse_cached_file<F>(
    path: &Path,
    modified: f64,
    start_offset: u64,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
    needles: &[&[u8]],
    project: Option<String>,
    mut parse: F,
) -> Result<CachedFilePayload, SourceScanError>
where
    F: FnMut(&Path, f64, Value, &mut ScanStats) -> LineUsage,
{
    let mut observations = Vec::new();
    let mut probe = UsageProbe::default();
    // C195: 预筛字面量是产出用量的必要条件 (C110), 超长行的保留前缀命中即为疑似用量行。
    probe.truncated_usage = scan_jsonl_file_from_offset(
        path,
        start_offset,
        cancellation,
        stats,
        needles,
        |path, line, stats| {
            if !line_may_match(line, needles) {
                stats.ignored_lines = stats.ignored_lines.saturating_add(1);
                return;
            }
            let Some(value) = parse_json_line(line, stats) else {
                return;
            };
            match parse(path, modified, value, stats) {
                LineUsage::Skip => {}
                LineUsage::Missing => probe.observe(false),
                LineUsage::Usage(observation) => {
                    probe.observe(observation_has_usage(&observation));
                    observations.push(observation);
                }
            }
        },
    )?;
    Ok(CachedFilePayload {
        project,
        observations,
        probe,
    })
}

/// Kimi Work 与 Kimi Code CLI 共用的 `usage.record` 解析 (C116: Kimi Code CLI 不再走独立的
/// 旧版缓存引擎, 两者仅缓存命名空间不同)。
pub(super) struct KimiUsageJsonlAdapter {
    source_id: &'static str,
}

impl JsonlCacheAdapter for KimiUsageJsonlAdapter {
    type Aggregator = ObservationAggregator;

    fn source_id(&self) -> &'static str {
        self.source_id
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        _window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            cancellation,
            stats,
            KIMI_USAGE_NEEDLES,
            None,
            |_, _, value, stats| {
                if value.get("type").and_then(Value::as_str) != Some("usage.record") {
                    stats.ignored_lines = stats.ignored_lines.saturating_add(1);
                    return LineUsage::Skip;
                }
                let Some(timestamp) = timestamp_number(value.get("time")) else {
                    stats.malformed_lines = stats.malformed_lines.saturating_add(1);
                    return LineUsage::Skip;
                };
                let usage = value.get("usage");
                stats.usage_records = stats.usage_records.saturating_add(1);
                LineUsage::Usage(JsonlObservation {
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
                    cache_creation_1h: 0,
                })
            },
        )
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator {
        ObservationAggregator::new(window)
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
        &KimiUsageJsonlAdapter {
            source_id: "kimi-work",
        },
        cancellation,
    )
}

/// Kimi Code CLI (`~/.kimi-code/sessions`) 的缓存扫描 (C116)。
pub fn scan_kimi_cli_cached(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_cached_jsonl_tree(
        root,
        &jsonl_cache_config(cache_root, "kimi-code-cli", window),
        &KimiUsageJsonlAdapter {
            source_id: "kimi-code-cli",
        },
        cancellation,
    )
}

struct ClaudeJsonlAdapter;

fn source_digest(source_id: &str, value: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-jsonl-dedupe-v1\0");
    hasher.update(source_id.as_bytes());
    hasher.update([0]);
    hasher.update(value.as_bytes());
    hasher.finalize().into()
}

/// 参照实现的去重键: 完整 SHA-256 的十六进制。
#[cfg(test)]
pub(super) fn digest_source_key(source_id: &str, value: &str) -> String {
    source_digest(source_id, value)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// 缓存层去重键 (C176): 同一 SHA-256 的前 128 位 (大端), 与 `digest_source_key` 同序。
pub(super) fn dedupe_key(source_id: &str, value: &str) -> DedupeKey {
    let digest = source_digest(source_id, value);
    let mut prefix = [0u8; 16];
    prefix.copy_from_slice(&digest[..16]);
    DedupeKey::from_be_bytes(prefix)
}

/// Claude 会话的项目名: 父目录名, 子代理会话加「·子代理」后缀。
fn claude_project(path: &Path) -> Option<String> {
    project_from_parent(path).map(|mut project| {
        if path
            .components()
            .any(|part| part.as_os_str() == "subagents")
        {
            project.push_str(" ·子代理");
        }
        project
    })
}

fn claude_observation(window: &CollectionWindow, value: &Value) -> Option<JsonlObservation> {
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
    Some(JsonlObservation {
        dedupe_key: message
            .get("id")
            .and_then(Value::as_str)
            .map(|id| dedupe_key("claude-message", id)),
        timestamp_millis: timestamp,
        model: message
            .get("model")
            .and_then(Value::as_str)
            .map(str::to_owned),
        input: number_u64(usage.get("input_tokens")),
        output: number_u64(usage.get("output_tokens")),
        cache_read: number_u64(usage.get("cache_read_input_tokens")),
        cache_creation: number_u64(usage.get("cache_creation_input_tokens")),
        cache_creation_1h: claude_cache_creation_1h(usage),
    })
}

impl JsonlCacheAdapter for ClaudeJsonlAdapter {
    type Aggregator = DedupedAggregator;

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
            cancellation,
            stats,
            ASSISTANT_NEEDLES,
            claude_project(path),
            |_, _, value, stats| {
                let observation = claude_observation(window, &value);
                if observation.is_some() {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation.into()
            },
        )
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator {
        DedupedAggregator::new(window, DedupeRule::FieldMaxLastSeen)
    }
}

/// 测试专用 (C196): 每个文件处理前回调, 用于模拟列目录后文件被删除的竞态。
#[cfg(test)]
pub(super) fn scan_claude_cached_with_hook(
    root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    before_file: &mut dyn FnMut(&Path),
) -> Result<SourceScan, SourceScanError> {
    crate::jsonl_cache::scan_cached_jsonl_tree_with_hook(
        root,
        &jsonl_cache_config(cache_root, "claude-code", window),
        &ClaudeJsonlAdapter,
        &CancellationToken::new(),
        before_file,
    )
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

fn codebuddy_observation(path: &Path, value: &Value, stats: &mut ScanStats) -> LineUsage {
    let record_type = value.get("type").and_then(Value::as_str);
    if record_type != Some("message") && record_type != Some("function_call") {
        return LineUsage::Skip;
    }
    if record_type == Some("message")
        && value.get("role").and_then(Value::as_str) != Some("assistant")
    {
        return LineUsage::Skip;
    }
    let Some(timestamp) = timestamp_number(value.get("timestamp")) else {
        return LineUsage::Skip;
    };
    let Some((input, output, cache_read, cache_creation)) = codebuddy_usage(value) else {
        return LineUsage::Missing;
    };
    stats.usage_records = stats.usage_records.saturating_add(1);
    let raw_key =
        codebuddy_message_id(value).map(|id| format!("{}::{id}", codebuddy_scope(path, value),));
    LineUsage::Usage(JsonlObservation {
        dedupe_key: raw_key
            .as_deref()
            .map(|key| dedupe_key("codebuddy-message", key)),
        timestamp_millis: timestamp,
        model: codebuddy_model(value),
        input,
        output,
        cache_read,
        cache_creation,
        cache_creation_1h: 0,
    })
}

impl JsonlCacheAdapter for CodeBuddyJsonlAdapter {
    type Aggregator = DedupedAggregator;

    fn source_id(&self) -> &'static str {
        "codebuddy"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        _window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            cancellation,
            stats,
            CODEBUDDY_NEEDLES,
            project_from_parent(path),
            |path, _, value, stats| codebuddy_observation(path, &value, stats),
        )
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator {
        DedupedAggregator::new(window, DedupeRule::LargestTotal)
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

/// Grok 会话的项目名: 会话文件的祖父目录名。
fn grok_project(path: &Path) -> Option<String> {
    path.parent()
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|value| value.to_str())
        .map(str::to_owned)
}

fn grok_observation(modified: f64, value: &Value) -> Option<JsonlObservation> {
    let kind = value.get("type").and_then(Value::as_str);
    if kind != Some("user") && kind != Some("assistant") {
        return None;
    }
    let content = grok_content(value.get("content"));
    if content.is_empty() {
        return None;
    }
    let tokens = (content.chars().count() as u64 / 4).max(1);
    Some(JsonlObservation {
        dedupe_key: None,
        timestamp_millis: (modified * 1000.0) as i64,
        model: Some("grok".to_owned()),
        input: if kind == Some("user") { tokens } else { 0 },
        output: if kind == Some("assistant") { tokens } else { 0 },
        cache_read: 0,
        cache_creation: 0,
        cache_creation_1h: 0,
    })
}

impl JsonlCacheAdapter for GrokJsonlAdapter {
    type Aggregator = ObservationAggregator;

    fn source_id(&self) -> &'static str {
        "grok"
    }

    fn parse_file(
        &self,
        path: &Path,
        modified: f64,
        start_offset: u64,
        _window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<CachedFilePayload, SourceScanError> {
        parse_cached_file(
            path,
            modified,
            start_offset,
            cancellation,
            stats,
            GROK_NEEDLES,
            grok_project(path),
            |_, modified, value, stats| {
                let observation = grok_observation(modified, &value);
                if observation.is_some() {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation.into()
            },
        )
    }

    fn merge_append(
        &self,
        previous: CachedFilePayload,
        appended: CachedFilePayload,
        modified: f64,
    ) -> CachedFilePayload {
        // Grok 以文件 mtime 作为全部消息的时间戳: 追加后整文件重打为新 mtime
        let current_timestamp = (modified * 1000.0) as i64;
        let mut observations = previous.observations;
        observations.extend(appended.observations);
        for observation in &mut observations {
            observation.timestamp_millis = current_timestamp;
        }
        CachedFilePayload {
            project: appended.project,
            observations,
            ..CachedFilePayload::default()
        }
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator {
        ObservationAggregator::new(window)
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
    let mut notice = None;
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
                if notice.is_none() {
                    notice = current.notice;
                }
                if !builder.merge_contribution(&current.contribution) {
                    return Err(SourceScanError::Io(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "grok root contribution is incompatible with the collection window",
                    )));
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
        notice,
    })
}

struct PiJsonlAdapter;

fn pi_observation(window: &CollectionWindow, value: &Value) -> LineUsage {
    let kind = value.get("type").and_then(Value::as_str);
    if kind == Some("session") || kind != Some("message") {
        return LineUsage::Skip;
    }
    let message = value.get("message").unwrap_or(&Value::Null);
    if message.get("role").and_then(Value::as_str) != Some("assistant") {
        return LineUsage::Skip;
    }
    let usage = message.get("usage").unwrap_or(&Value::Null);
    if usage.is_null() {
        return LineUsage::Missing;
    }
    let Some(timestamp) = timestamp_number(message.get("timestamp")).or_else(|| {
        value
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(|value| window.epoch_from_iso(value).map(|value| value * 1000))
    }) else {
        return LineUsage::Skip;
    };
    LineUsage::Usage(JsonlObservation {
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
        cache_creation_1h: 0,
    })
}

impl JsonlCacheAdapter for PiJsonlAdapter {
    type Aggregator = ObservationAggregator;

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
            cancellation,
            stats,
            ASSISTANT_NEEDLES,
            project_from_parent(path),
            |_, _, value, stats| {
                let observation = pi_observation(window, &value);
                if matches!(observation, LineUsage::Usage(_)) {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                }
                observation
            },
        )
    }

    fn aggregator(&self, window: &CollectionWindow) -> Self::Aggregator {
        ObservationAggregator::new(window)
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
