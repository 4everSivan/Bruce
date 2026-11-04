//! dsh (DeepSeek Harness) 本机会话源 (C189)。
//!
//! 会话落盘为 `~/.dsh/sessions/<workspace-dir>/<session-id>/session.v4.jsonl.zstd`:
//! 每行一个 JSON 事件, 每次追加写成一个独立的 zstd 帧 (单文件常态数百帧), 因此必须
//! 多帧串接解码; 也正因为压缩以帧为边界, 解压后的字节偏移无法用于增量追加 —— 文件签名
//! (dev/ino/size/mtime_ns) 一旦变化即整文件重建, 未变化则直接复用缓存观测。
//!
//! 解码用纯 Rust 的 `ruzstd` 而不是 C 版 `zstd` crate: 不引入 zstd-sys 的 C 编译链,
//! macOS Universal 2 与 Windows Tauri 交叉构建都无需额外准备 C 工具链; 该依赖可离线
//! 精确锁版 (`=0.7.3`)。代价是解码比 C 实现慢 (只影响冷扫描, 热扫描命中缓存不触解码)。
//!
//! 活写兜底: 正在写入的会话可能被抓到「帧未写完」的撕裂状态而解析失败。此时若缓存里
//! 仍有该路径的旧条目, 就沿用它的陈旧观测继续本轮聚合 (计 io_errors, 不计 cache_hits /
//! cache_deletions), 避免用户看到该会话本轮数字骤降; 下一轮签名仍不一致会再次尝试重建。
//!
//! 用量只出现在 `{"type":"assistant/message","time":<epoch ms>,"data":{"usage":{..},
//! "message":{"id":..,"source":{"model":..}}}}`。usage 为 camelCase:
//! `inputTokens` 是非缓存输入, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`;
//! `totalTokens` 是前三者的派生值, 不能当输入再计一次。fork/seed 会话会继承历史消息,
//! 故跨文件按 message id 去重; 项目名取会话头 `cwd` 的末段 (文件级)。

use super::jsonl_adapters::{dedupe_key, DedupeRule, DedupedAggregator};
use super::{
    line_may_match, number_u64, parse_json_line, timestamp_number, SourceScan, SourceScanError,
};
use crate::cache_util::{load_json_cache, write_json_atomic, CacheLoad};
use crate::jsonl_cache::{
    file_drift_notice, join_notices, truncated_usage_notice, unreadable_files_notice,
    CachedFilePayload, JsonlAggregator, JsonlFileSignature, JsonlObservation, UsageProbe,
    FILE_DRIFT_STREAK,
};
use crate::{
    read_bounded_line, trim_line_end, ScanStats, MAX_DIRECTORY_SCAN_DEPTH, MAX_JSONL_RECORD_BYTES,
    READ_BUFFER_BYTES,
};
use collector_domain::CollectionWindow;
use collector_runtime::CancellationToken;
use ruzstd::frame_decoder::{BlockDecodingStrategy, FrameDecoder, FrameDecoderError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::cell::Cell;
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::UNIX_EPOCH;

/// 压缩会话后缀 (dsh 现行格式)。逐个追加事件各写一帧。
const DSH_COMPRESSED_SUFFIX: &str = ".jsonl.zstd";
/// 未压缩 JSONL 后缀: 测试夹具与将来的纯文本格式。
const DSH_PLAIN_SUFFIX: &str = ".jsonl";

/// 缓存身份: 缓存载荷格式 / 解析规则 / 聚合规则任一变化都必须升版, 令旧条目整体重建。
const DSH_CACHE_SCHEMA_VERSION: u32 = 1;
const DSH_CACHE_PARSER_VERSION: u32 = 1;
const DSH_CACHE_AGGREGATION_VERSION: u32 = 1;
const DSH_SOURCE_ID: &str = "dsh";

/// 去重键命名空间: 键 = SHA-256(域分隔 + 命名空间 + message id) 的前 128 位。
const DSH_DEDUPE_NAMESPACE: &str = "dsh-message";

/// 一条用量事件必须出现的字面量 (解析前预筛, C110): 用量行含 `"usage"`, 会话头含 `"cwd"`;
/// C193 起助手消息即使不含 `"usage"` 也要解析 (计入口径哨兵, 防 usage 键改名后被预筛静默滤掉)。
/// 其余事件 (step/tool/reasoning 流块) 不建 JSON DOM。
const DSH_NEEDLES: &[&[u8]] = &[b"\"usage\"", b"\"cwd\"", b"assistant/message"];

/// C195: 超长行的保留前缀含这些结构化字面量即为疑似用量行 (会话头的 `"cwd"` 不算)。
const DSH_USAGE_NEEDLES: &[&[u8]] = &[b"\"usage\"", b"\"assistant/message\""];

/// 单帧解压内容上限 (C189): dsh 常态一帧一条事件 (实测最大约 250 KiB), 8 MiB 留足余量。
/// C192 起在解码中逐块强制执行 (声明窗口或已解出字节超限即中止该帧), 超出只跳过该帧;
/// 同一上限也约束一帧压缩字节的缓冲。
const DSH_MAX_FRAME_CONTENT_BYTES: u64 = 8 * 1024 * 1024;

/// 受支持的 usage 字段。只有 `totalTokens` (派生值) 的行不构成用量记录。
const DSH_TOKEN_FIELDS: &[&str] = &[
    "inputTokens",
    "outputTokens",
    "cacheReadTokens",
    "cacheWriteTokens",
];

/// 按文件签名缓存的会话观测。载荷即 JSONL 缓存引擎的紧凑形状 (文件级 project +
/// 模型表 + 128 位去重键), 与窗口无关; 每次运行再按当前窗口聚合。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct DshCacheFile {
    schema_version: u32,
    source_id: String,
    parser_version: u32,
    aggregation_version: u32,
    /// 源文件路径摘要 → 该文件的观测载荷。
    files: BTreeMap<String, DshFileEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct DshFileEntry {
    file: JsonlFileSignature,
    payload: CachedFilePayload,
    /// C192: 损坏 / 超限而跳过的压缩帧数; 部分成功的解析照常缓存, 签名不变时直接命中,
    /// 不再每轮整文件重解压后失败。
    #[serde(default, skip_serializing_if = "is_zero_u32")]
    damaged_frames: u32,
}

fn is_zero_u32(value: &u32) -> bool {
    *value == 0
}

/// 一个待解析的会话文件。
struct DshCandidate {
    path: PathBuf,
    file: JsonlFileSignature,
}

/// dsh 会话的缓存扫描入口: 未变化的文件只读缓存条目 (不解压、不解析), 变化的文件整文件重建。
pub fn scan_dsh_cached(
    sessions_root: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_dsh(sessions_root, window, Some(cache_root), cancellation)
}

/// 不走缓存的参照实现, 只供对拍用例使用。
#[cfg(test)]
pub(crate) fn scan_dsh_uncached(sessions_root: &Path, window: &CollectionWindow) -> SourceScan {
    scan_dsh(sessions_root, window, None, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

fn scan_dsh(
    sessions_root: &Path,
    window: &CollectionWindow,
    cache_root: Option<&Path>,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    cancellation.check()?;
    // 未安装 / 从未使用 dsh: 源不存在即空结果, 不产生 I/O 故障。
    if !sessions_root.exists() {
        return Ok(SourceScan::empty(window));
    }
    if !sessions_root.is_dir() {
        return Err(io::Error::new(
            io::ErrorKind::NotADirectory,
            "dsh sessions root is not a directory",
        )
        .into());
    }

    let mut stats = ScanStats::default();
    let mut candidates = Vec::new();
    let mut visited_dirs = BTreeSet::new();
    if let Ok(canonical) = fs::canonicalize(sessions_root) {
        visited_dirs.insert(canonical);
    }
    collect_dsh_files(
        sessions_root,
        window.cutoff_ts,
        cancellation,
        &mut candidates,
        &mut stats,
        &mut visited_dirs,
        0,
    )?;
    cancellation.check()?;
    // 遍历顺序由文件系统给出; 排序让去重取舍与 payload 顺序在机器之间稳定。
    candidates.sort_by(|left, right| left.path.cmp(&right.path));

    let cache_path = cache_root.map(dsh_cache_path);
    let mut previous = BTreeMap::new();
    if let Some(cache_path) = cache_path.as_deref() {
        match load_json_cache::<DshCacheFile>(cache_path) {
            CacheLoad::Missing => {}
            CacheLoad::Corrupt => {
                stats.cache_corruptions = stats.cache_corruptions.saturating_add(1);
            }
            CacheLoad::Entry(entry) => {
                if dsh_cache_identity_matches(&entry) {
                    previous = entry.files;
                } else {
                    stats.cache_invalidations = stats.cache_invalidations.saturating_add(1);
                }
            }
        }
    }
    let previous_count = previous.len();

    let mut aggregator = DedupedAggregator::new(window, DedupeRule::LargestTotal);
    let mut drifted_files = 0_u64;
    let mut truncated_usage = 0_u64;
    let mut damaged_frames = 0_u64;
    let mut unreadable_files = 0_u64;
    let mut entries = BTreeMap::new();
    let mut changed = false;
    for candidate in &candidates {
        cancellation.check()?;
        let key = dsh_path_key(&candidate.path);
        let previous_entry = previous.remove(&key);
        let entry = match previous_entry {
            Some(entry) if entry.file == candidate.file => {
                // 签名一致: 命中缓存, 跳过解压与 JSON 解析。
                stats.cache_hits = stats.cache_hits.saturating_add(1);
                entry
            }
            // zstd 帧无法按解压后字节偏移增量解析, 变更文件一律整文件重建。
            fallback => match parse_dsh_file(&candidate.path, cancellation, &mut stats) {
                Ok((payload, health)) => {
                    changed = true;
                    stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
                    // C192: 撕裂的末帧之前的帧照常计入; 文件写完后签名变化即重建。
                    if health.torn_tail {
                        stats.io_errors = stats.io_errors.saturating_add(1);
                    }
                    DshFileEntry {
                        file: candidate.file.clone(),
                        payload,
                        damaged_frames: health.damaged,
                    }
                }
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    // 单文件损坏 / 读取失败: 计入 io_errors, 其余源数据照常产出。
                    // 活写撕裂兜底: 若该路径有旧条目, 沿用其陈旧观测继续本轮聚合, 免得
                    // 正在写入的会话在这一次刷新里整段消失; 口径上只计 io_errors ——
                    // 既不是 cache_hits (没有复用已确认未变化的条目), 也不是
                    // cache_rebuilds (重建失败), 条目也不进 cache_deletions。
                    // 陈旧条目保留的是旧签名, 下一轮签名仍不一致会再次尝试重建, 一旦
                    // 文件写完即被真实观测替换。
                    stats.io_errors = stats.io_errors.saturating_add(1);
                    // C201: 整文件读取失败 (撕裂末帧不走这里) 计入说明。
                    unreadable_files = unreadable_files.saturating_add(1);
                    match fallback {
                        Some(entry) => entry,
                        None => continue,
                    }
                }
            },
        };
        if entry.payload.probe.drifted(FILE_DRIFT_STREAK) {
            drifted_files = drifted_files.saturating_add(1);
        }
        truncated_usage =
            truncated_usage.saturating_add(u64::from(entry.payload.probe.truncated_usage));
        damaged_frames = damaged_frames.saturating_add(u64::from(entry.damaged_frames));
        // C176: 逐文件并入聚合器后即丢弃载荷, 不把全部观测同时留在内存里。
        aggregator.absorb(&entry.payload);
        entries.insert(key, entry);
    }

    // 已删除 / 已移出窗口的条目在此清理; 活写兜底保留的陈旧条目已回填进 `entries`,
    // 故不计入 cache_deletions。
    let removed = previous.len();
    stats.cache_deletions = stats.cache_deletions.saturating_add(removed as u64);
    if let Some(cache_path) = cache_path {
        if changed || removed > 0 || entries.len() != previous_count {
            let cache = DshCacheFile {
                schema_version: DSH_CACHE_SCHEMA_VERSION,
                source_id: DSH_SOURCE_ID.to_owned(),
                parser_version: DSH_CACHE_PARSER_VERSION,
                aggregation_version: DSH_CACHE_AGGREGATION_VERSION,
                files: entries,
            };
            match write_json_atomic(&cache_path, &cache, cancellation) {
                Ok(()) => {}
                // 缓存可再生: 写盘失败只影响下一轮命中率, 本轮结果不变。
                Err(SourceScanError::Runtime(error)) => return Err(error.into()),
                Err(SourceScanError::Io(_)) => {
                    stats.io_errors = stats.io_errors.saturating_add(1);
                }
            }
        }
    }
    cancellation.check()?;

    let (contribution, _absorbed, diagnostic) = aggregator.finish()?;
    cancellation.check()?;
    Ok(SourceScan {
        found: stats.files_scanned > 0,
        contribution,
        stats,
        diagnostic,
        notice: join_notices(
            [
                (drifted_files > 0).then(|| file_drift_notice(drifted_files)),
                (truncated_usage > 0).then(|| truncated_usage_notice(truncated_usage)),
                (damaged_frames > 0).then(|| {
                    format!(
                        "{damaged_frames} 个 dsh 压缩帧损坏或超过 {} MiB 上限, 已跳过这些帧",
                        DSH_MAX_FRAME_CONTENT_BYTES / (1024 * 1024)
                    )
                }),
                (unreadable_files > 0).then(|| unreadable_files_notice(unreadable_files)),
            ]
            .into_iter()
            .flatten()
            .collect(),
        ),
    })
}

fn dsh_cache_identity_matches(cache: &DshCacheFile) -> bool {
    cache.schema_version == DSH_CACHE_SCHEMA_VERSION
        && cache.source_id == DSH_SOURCE_ID
        && cache.parser_version == DSH_CACHE_PARSER_VERSION
        && cache.aggregation_version == DSH_CACHE_AGGREGATION_VERSION
}

fn dsh_cache_path(cache_root: &Path) -> PathBuf {
    cache_root.join("dsh-sessions-v1.json")
}

fn dsh_path_key(path: &Path) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"bruce-dsh-session-v1\0");
    hasher.update(path.to_string_lossy().as_bytes());
    format!("{:x}", hasher.finalize())
}

/// 递归收集会话文件; 深度上限 + canonical 已访问集合与其它源同一套 symlink 环防护 (C045)。
#[allow(clippy::too_many_arguments)]
fn collect_dsh_files(
    root: &Path,
    cutoff_ts: f64,
    cancellation: &CancellationToken,
    candidates: &mut Vec<DshCandidate>,
    stats: &mut ScanStats,
    visited_dirs: &mut BTreeSet<PathBuf>,
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
            let canonical = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
            if visited_dirs.insert(canonical) {
                collect_dsh_files(
                    &path,
                    cutoff_ts,
                    cancellation,
                    candidates,
                    stats,
                    visited_dirs,
                    depth + 1,
                )?;
            }
            continue;
        }
        if !metadata.is_file() || !is_dsh_session_file(&path) {
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
        candidates.push(DshCandidate {
            file: dsh_file_signature(&metadata),
            path,
        });
    }
    Ok(())
}

fn is_dsh_session_file(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|value| value.to_str()) else {
        return false;
    };
    name.ends_with(DSH_COMPRESSED_SUFFIX) || name.ends_with(DSH_PLAIN_SUFFIX)
}

/// 缓存身份用的文件签名; mtime 用整数纳秒, f64 秒经 JSON 往返会差 1 ULP (C117)。
fn dsh_file_signature(metadata: &fs::Metadata) -> JsonlFileSignature {
    let modified_ns = metadata
        .modified()
        .ok()
        .and_then(|value| value.duration_since(UNIX_EPOCH).ok())
        .map(|value| value.as_nanos() as u64)
        .unwrap_or(0);
    let (device, inode) = file_identity(metadata);
    JsonlFileSignature {
        device,
        inode,
        size: metadata.len(),
        modified_ns,
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

/// 解析一个会话文件为与窗口无关的观测载荷。
fn parse_dsh_file(
    path: &Path,
    cancellation: &CancellationToken,
    stats: &mut ScanStats,
) -> Result<(CachedFilePayload, FrameHealth), SourceScanError> {
    cancellation.check()?;
    let (mut reader, health) = open_dsh_reader(path)?;
    let mut project: Option<String> = None;
    let mut observations = Vec::new();
    let mut probe = UsageProbe::default();
    let mut line_buffer = Vec::new();
    loop {
        cancellation.check()?;
        let Some(line) = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES, &mut line_buffer)?
        else {
            break;
        };
        stats.lines_seen = stats.lines_seen.saturating_add(1);
        // 压缩会话的字节数按解压后口径统计, 与其它 JSONL 源可比。
        stats.bytes_read = stats.bytes_read.saturating_add(line.bytes as u64);
        if line.truncated {
            stats.truncated_lines = stats.truncated_lines.saturating_add(1);
            // C195: 保留前缀含用量字面量的超长行是疑似用量行, 计入并持久化。
            if line_may_match(&line_buffer, DSH_USAGE_NEEDLES) {
                probe.truncated_usage = probe.truncated_usage.saturating_add(1);
            }
            continue;
        }
        let line = trim_line_end(&line_buffer);
        if line.is_empty() {
            continue;
        }
        if !line_may_match(line, DSH_NEEDLES) {
            stats.ignored_lines = stats.ignored_lines.saturating_add(1);
            continue;
        }
        let Some(value) = parse_json_line(line, stats) else {
            continue;
        };
        match value.get("type").and_then(Value::as_str) {
            Some("session") => {
                // 会话头提供项目路径 (文件级, 只取首个); 它不是用量记录。
                if project.is_none() {
                    project = value
                        .get("cwd")
                        .and_then(Value::as_str)
                        .and_then(project_from_cwd);
                }
                stats.ignored_lines = stats.ignored_lines.saturating_add(1);
            }
            Some("assistant/message") => match dsh_event_observation(&value) {
                DshLineOutcome::Usage(observation) => {
                    stats.usage_records = stats.usage_records.saturating_add(1);
                    probe.observe(
                        observation.input > 0
                            || observation.output > 0
                            || observation.cache_read > 0
                            || observation.cache_creation > 0,
                    );
                    observations.push(observation);
                }
                DshLineOutcome::Ignored => {
                    // C193: 助手消息却取不到用量字段, 计入口径哨兵。
                    probe.observe(false);
                    stats.ignored_lines = stats.ignored_lines.saturating_add(1);
                }
                DshLineOutcome::Malformed => {
                    stats.malformed_lines = stats.malformed_lines.saturating_add(1);
                }
            },
            _ => {
                stats.ignored_lines = stats.ignored_lines.saturating_add(1);
            }
        }
    }
    Ok((
        CachedFilePayload {
            project,
            observations,
            probe,
        },
        health.get(),
    ))
}

enum DshLineOutcome {
    Usage(JsonlObservation),
    /// 行内没有可用的用量字段 (例如只带派生 `totalTokens`)。
    Ignored,
    /// 是用量事件的形状但缺时间戳。
    Malformed,
}

fn dsh_event_observation(value: &Value) -> DshLineOutcome {
    let data = value.get("data").unwrap_or(&Value::Null);
    let Some(usage) = data.get("usage").and_then(Value::as_object) else {
        return DshLineOutcome::Ignored;
    };
    if !DSH_TOKEN_FIELDS
        .iter()
        .any(|field| usage.contains_key(*field))
    {
        return DshLineOutcome::Ignored;
    }
    let Some(timestamp_millis) = timestamp_number(value.get("time")) else {
        return DshLineOutcome::Malformed;
    };
    let message = data.get("message").unwrap_or(&Value::Null);
    DshLineOutcome::Usage(JsonlObservation {
        dedupe_key: message
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(|id| dedupe_key(DSH_DEDUPE_NAMESPACE, id)),
        timestamp_millis,
        model: message
            .get("source")
            .and_then(|source| source.get("model"))
            .and_then(Value::as_str)
            .map(str::to_owned),
        input: number_u64(usage.get("inputTokens")),
        output: number_u64(usage.get("outputTokens")),
        cache_read: number_u64(usage.get("cacheReadTokens")),
        cache_creation: number_u64(usage.get("cacheWriteTokens")),
        cache_creation_1h: 0,
    })
}

/// 会话头 `cwd` 的末段作为项目名; 同时兼容 `/` 与 `\` 分隔符 (会话可能来自其它平台)。
fn project_from_cwd(cwd: &str) -> Option<String> {
    cwd.split(['/', '\\'])
        .rfind(|part| !part.is_empty())
        .map(str::to_owned)
}

/// 一个会话文件的帧健康状况 (C192), 解析结束后由调用方读取。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
struct FrameHealth {
    /// 损坏 / 超限而跳过的帧数 (首帧之后)。
    damaged: u32,
    /// 末帧在文件末尾被截断 (活写撕裂); 之前的帧照常计入。
    torn_tail: bool,
}

/// 会话行读取器与其帧健康状况 (未压缩文件的健康状况恒为默认值)。
type DshReader = (Box<dyn BufRead>, Rc<Cell<FrameHealth>>);

/// 打开会话文件为行读取器: `.jsonl.zstd` 走多帧流式解码, 其余按未压缩 JSONL 读。
fn open_dsh_reader(path: &Path) -> Result<DshReader, SourceScanError> {
    let file = File::open(path)?;
    let health = Rc::new(Cell::new(FrameHealth::default()));
    let compressed = path
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|name| name.ends_with(DSH_COMPRESSED_SUFFIX));
    if !compressed {
        return Ok((
            Box::new(BufReader::with_capacity(READ_BUFFER_BYTES, file)),
            health,
        ));
    }
    let source = BufReader::with_capacity(READ_BUFFER_BYTES, file);
    Ok((
        Box::new(BufReader::with_capacity(
            READ_BUFFER_BYTES,
            MultiFrameReader::new(source, Rc::clone(&health)),
        )),
        health,
    ))
}

/// zstd 帧魔数 (RFC 8878 §3.1.1) 与可跳过帧魔数 (§3.1.2: 0x184D2A50..=0x184D2A5F)。
const ZSTD_MAGIC: [u8; 4] = [0x28, 0xb5, 0x2f, 0xfd];
const SKIPPABLE_MAGIC: u32 = 0x184d_2a50;
const SKIPPABLE_MAGIC_MASK: u32 = 0xffff_fff0;
/// Block_Maximum_Size 上限 (§3.1.1.2.3: min(Window_Size, 128 KiB))。
const ZSTD_MAX_BLOCK_BYTES: usize = 128 * 1024;

/// 按帧头 / 块头切出的一帧 (C192)。
enum FrameRead {
    /// 完整的一帧, 压缩字节在 `compressed` 中。
    Frame,
    /// 可跳过帧 (`damaged=false`) 或超限帧 (`damaged=true`), 已流式丢弃至帧尾。
    Skipped {
        damaged: bool,
    },
    /// 帧结构损坏 (魔数 / 保留位 / 保留块类型 / 块长越界), 帧尾未知, 需按魔数重新同步。
    Corrupt,
    /// 帧在文件末尾被截断。
    Torn,
    End,
}

/// 多帧 zstd 流式解码 (C189 / C192)。
///
/// dsh 每次追加写一个独立帧 (实测帧头一律声明 2 MiB 窗口、带校验和、不声明内容长度, 每帧
/// ≤ 4 块)。C192 起先按帧头与块头 (RFC 8878, 不解码) 切出一帧的压缩字节, 再单独解码这一帧:
/// - 帧彼此独立, 坏帧 (块内容解码失败 / 解出超过 `DSH_MAX_FRAME_CONTENT_BYTES`) 只跳过该帧
///   并计数, 帧尾由块头确定, 不影响其后的帧; 结构损坏 (帧尾未知) 时按魔数重新同步;
/// - 末帧在文件末尾被截断 (活写撕裂) 时其前的帧照常产出;
/// - 只有首帧不可解时整文件按损坏上报 (很可能根本不是 zstd 会话);
/// - 帧上限在解码中强制执行: 声明窗口超过上限即整帧流式丢弃, 否则逐块解码并随时取出,
///   已解出字节超限即中止 —— 峰值内存约为上限 + 窗口 + 一块, 不再整帧解码进内存后才检查。
///
/// 不能用 `StreamingDecoder::read` 连着读下一帧: 它为避免破坏环形窗口, 未到帧尾时可能返回 0,
/// 把这种 0 当帧边界会丢掉该帧剩余内容。
struct MultiFrameReader<R: BufRead> {
    source: R,
    frame: FrameDecoder,
    /// 当前帧的压缩字节 (受上限约束)。
    compressed: Vec<u8>,
    /// 当前帧的解压内容。
    pending: Vec<u8>,
    /// `pending` 已返回给调用方的字节数。
    offset: usize,
    finished: bool,
    decoded_frames: u32,
    health: Rc<Cell<FrameHealth>>,
}

impl<R: BufRead> MultiFrameReader<R> {
    fn new(source: R, health: Rc<Cell<FrameHealth>>) -> Self {
        Self {
            source,
            frame: FrameDecoder::new(),
            compressed: Vec::new(),
            pending: Vec::new(),
            offset: 0,
            finished: false,
            decoded_frames: 0,
            health,
        }
    }

    /// 解出下一帧的内容到 `pending`; 流已到末尾时返回 false。
    fn decode_next_frame(&mut self) -> io::Result<bool> {
        let mut magic_read = false;
        loop {
            let first = self.decoded_frames == 0 && self.health.get().damaged == 0;
            match self.read_frame(magic_read)? {
                FrameRead::End => return Ok(false),
                FrameRead::Torn if first => {
                    return Err(dsh_frame_error("first frame is truncated"))
                }
                FrameRead::Torn => {
                    self.update_health(|health| health.torn_tail = true);
                    return Ok(false);
                }
                FrameRead::Corrupt if first => {
                    return Err(dsh_frame_error("first frame is corrupt"))
                }
                FrameRead::Corrupt => {
                    self.update_health(|health| health.damaged = health.damaged.saturating_add(1));
                    magic_read = self.resync()?;
                    if !magic_read {
                        return Ok(false);
                    }
                }
                FrameRead::Skipped { damaged: false } => magic_read = false,
                FrameRead::Skipped { damaged: true } if first => {
                    return Err(dsh_frame_error("first frame exceeds the frame limit"))
                }
                FrameRead::Skipped { damaged: true } => {
                    self.update_health(|health| health.damaged = health.damaged.saturating_add(1));
                    magic_read = false;
                }
                FrameRead::Frame => {
                    magic_read = false;
                    match self.decode_frame() {
                        Ok(true) => {
                            self.decoded_frames = self.decoded_frames.saturating_add(1);
                            return Ok(true);
                        }
                        Ok(false) | Err(_) if first => {
                            return Err(dsh_frame_error("first frame cannot be decoded"))
                        }
                        Ok(false) | Err(_) => self.update_health(|health| {
                            health.damaged = health.damaged.saturating_add(1)
                        }),
                    }
                }
            }
        }
    }

    fn update_health(&self, update: impl FnOnce(&mut FrameHealth)) {
        let mut health = self.health.get();
        update(&mut health);
        self.health.set(health);
    }

    /// 按帧头与块头读出一帧的压缩字节 (不解码)。
    fn read_frame(&mut self, magic_read: bool) -> io::Result<FrameRead> {
        self.compressed.clear();
        let mut magic = ZSTD_MAGIC;
        if !magic_read {
            match read_full(&mut self.source, &mut magic)? {
                0 => return Ok(FrameRead::End),
                4 => {}
                _ => return Ok(FrameRead::Torn),
            }
        }
        let magic_value = u32::from_le_bytes(magic);
        if magic_value & SKIPPABLE_MAGIC_MASK == SKIPPABLE_MAGIC {
            let mut size = [0u8; 4];
            if read_full(&mut self.source, &mut size)? < 4 {
                return Ok(FrameRead::Torn);
            }
            let length = u64::from(u32::from_le_bytes(size));
            return Ok(if skip_bytes(&mut self.source, length)? < length {
                FrameRead::Torn
            } else {
                FrameRead::Skipped { damaged: false }
            });
        }
        if magic != ZSTD_MAGIC {
            return Ok(FrameRead::Corrupt);
        }
        let mut descriptor = [0u8; 1];
        if read_full(&mut self.source, &mut descriptor)? < 1 {
            return Ok(FrameRead::Torn);
        }
        let descriptor = descriptor[0];
        if descriptor & 0b0000_1000 != 0 {
            return Ok(FrameRead::Corrupt);
        }
        let single_segment = descriptor & 0b0010_0000 != 0;
        let has_checksum = descriptor & 0b0000_0100 != 0;
        let window_length = usize::from(!single_segment);
        let dictionary_length = [0, 1, 2, 4][usize::from(descriptor & 0b11)];
        let content_size_length = match descriptor >> 6 {
            0 => usize::from(single_segment),
            1 => 2,
            2 => 4,
            _ => 8,
        };
        let mut header = [0u8; 13];
        let header = &mut header[..window_length + dictionary_length + content_size_length];
        if read_full(&mut self.source, header)? < header.len() {
            return Ok(FrameRead::Torn);
        }
        let window = if single_segment {
            let field = &header[dictionary_length..];
            let mut value = field
                .iter()
                .rev()
                .fold(0u64, |value, byte| (value << 8) | u64::from(*byte));
            if content_size_length == 2 {
                value += 256;
            }
            value
        } else {
            let exponent = u32::from(header[0] >> 3);
            let base = 1u64 << (10 + exponent);
            base + (base / 8) * u64::from(header[0] & 0b111)
        };
        // 声明窗口超过上限的帧整帧流式丢弃 (解码器会按窗口分配缓冲)。
        let mut oversized = window > DSH_MAX_FRAME_CONTENT_BYTES;
        if !oversized {
            self.compressed.extend_from_slice(&ZSTD_MAGIC);
            self.compressed.push(descriptor);
            self.compressed.extend_from_slice(header);
        }
        loop {
            let mut block_header = [0u8; 3];
            if read_full(&mut self.source, &mut block_header)? < 3 {
                return Ok(FrameRead::Torn);
            }
            let raw = u32::from(block_header[0])
                | (u32::from(block_header[1]) << 8)
                | (u32::from(block_header[2]) << 16);
            let last = raw & 1 == 1;
            let block_type = (raw >> 1) & 0b11;
            let block_size = (raw >> 3) as usize;
            if block_type == 3 || block_size > ZSTD_MAX_BLOCK_BYTES {
                return Ok(FrameRead::Corrupt);
            }
            // RLE 块只有 1 字节负载, Block_Size 是解出长度。
            let content = if block_type == 1 { 1 } else { block_size };
            if !oversized
                && (self.compressed.len() + 3 + content) as u64 > DSH_MAX_FRAME_CONTENT_BYTES
            {
                oversized = true;
                self.compressed.clear();
            }
            if oversized {
                if skip_bytes(&mut self.source, content as u64)? < content as u64 {
                    return Ok(FrameRead::Torn);
                }
            } else {
                self.compressed.extend_from_slice(&block_header);
                let start = self.compressed.len();
                self.compressed.resize(start + content, 0);
                if read_full(&mut self.source, &mut self.compressed[start..])? < content {
                    return Ok(FrameRead::Torn);
                }
            }
            if last {
                break;
            }
        }
        if has_checksum {
            let mut checksum = [0u8; 4];
            if read_full(&mut self.source, &mut checksum)? < 4 {
                return Ok(FrameRead::Torn);
            }
            if !oversized {
                self.compressed.extend_from_slice(&checksum);
            }
        }
        Ok(if oversized {
            FrameRead::Skipped { damaged: true }
        } else {
            FrameRead::Frame
        })
    }

    /// 解码 `compressed` 中的一帧到 `pending`: 逐块解码并随时取出, 已解出字节超过上限即
    /// 中止 (返回 false)。
    fn decode_frame(&mut self) -> Result<bool, FrameDecoderError> {
        let mut cursor: &[u8] = &self.compressed;
        self.frame.init(&mut cursor)?;
        self.pending.clear();
        self.offset = 0;
        loop {
            self.frame
                .decode_blocks(&mut cursor, BlockDecodingStrategy::UptoBlocks(1))?;
            self.frame
                .collect_to_writer(&mut self.pending)
                .map_err(|_| FrameDecoderError::NotYetInitialized)?;
            if self.pending.len() as u64 > DSH_MAX_FRAME_CONTENT_BYTES {
                self.pending.clear();
                return Ok(false);
            }
            if self.frame.is_finished() {
                return Ok(true);
            }
        }
    }

    /// 帧结构损坏后按魔数重新同步; 找到时魔数已读掉 (返回 true), 到流末尾返回 false。
    fn resync(&mut self) -> io::Result<bool> {
        let mut matched = 0usize;
        loop {
            let chunk = self.source.fill_buf()?;
            if chunk.is_empty() {
                return Ok(false);
            }
            let mut consumed = 0usize;
            let mut found = false;
            for &byte in chunk {
                consumed += 1;
                if byte == ZSTD_MAGIC[matched] {
                    matched += 1;
                    if matched == ZSTD_MAGIC.len() {
                        found = true;
                        break;
                    }
                } else {
                    // 魔数四个字节互不相同, 失配时只需看当前字节能否作为新的开头。
                    matched = usize::from(byte == ZSTD_MAGIC[0]);
                }
            }
            self.source.consume(consumed);
            if found {
                return Ok(true);
            }
        }
    }
}

/// 读满 `buffer` 或读到流末尾, 返回读到的字节数。
fn read_full(source: &mut impl Read, buffer: &mut [u8]) -> io::Result<usize> {
    let mut filled = 0;
    while filled < buffer.len() {
        match source.read(&mut buffer[filled..]) {
            Ok(0) => break,
            Ok(read) => filled += read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
    Ok(filled)
}

/// 流式丢弃 `length` 字节 (不缓冲), 返回实际丢弃的字节数。
fn skip_bytes(source: &mut impl Read, length: u64) -> io::Result<u64> {
    io::copy(&mut source.take(length), &mut io::sink())
}

impl<R: BufRead> Read for MultiFrameReader<R> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        if out.is_empty() {
            return Ok(0);
        }
        loop {
            if self.offset < self.pending.len() {
                let available = self.pending.len() - self.offset;
                let take = available.min(out.len());
                out[..take].copy_from_slice(&self.pending[self.offset..self.offset + take]);
                self.offset += take;
                return Ok(take);
            }
            if self.finished || !self.decode_next_frame()? {
                self.finished = true;
                return Ok(0);
            }
            // 空帧 (无内容) 时继续解码下一帧。
        }
    }
}

fn dsh_frame_error(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("dsh zstd {message}"))
}
