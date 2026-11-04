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
    file_drift_notice, CachedFilePayload, JsonlAggregator, JsonlFileSignature, JsonlObservation,
    UsageProbe, FILE_DRIFT_STREAK,
};
use crate::{
    read_bounded_line, trim_line_end, ScanStats, MAX_DIRECTORY_SCAN_DEPTH, MAX_JSONL_RECORD_BYTES,
    READ_BUFFER_BYTES,
};
use collector_domain::CollectionWindow;
use collector_runtime::CancellationToken;
use ruzstd::frame::ReadFrameHeaderError;
use ruzstd::frame_decoder::{BlockDecodingStrategy, FrameDecoder, FrameDecoderError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File};
use std::io::{self, BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
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

/// 单帧解压内容上限 (C189): dsh 常态一帧一条事件 (实测最大约 250 KiB), 8 MiB 留足余量;
/// 多帧流式解码必须把整帧缓冲出来才能取出 (环形窗口保留的字节在帧尾前不可取), 该上限把
/// 病态 / 损坏帧的峰值内存钉住, 超出即按数据损坏跳过该文件。
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
                Ok(payload) => {
                    changed = true;
                    stats.cache_rebuilds = stats.cache_rebuilds.saturating_add(1);
                    DshFileEntry {
                        file: candidate.file.clone(),
                        payload,
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
        notice: (drifted_files > 0).then(|| file_drift_notice(drifted_files)),
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
) -> Result<CachedFilePayload, SourceScanError> {
    cancellation.check()?;
    let mut reader = open_dsh_reader(path)?;
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
    Ok(CachedFilePayload {
        project,
        observations,
        probe,
    })
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

/// 打开会话文件为行读取器: `.jsonl.zstd` 走多帧流式解码, 其余按未压缩 JSONL 读。
fn open_dsh_reader(path: &Path) -> Result<Box<dyn BufRead>, SourceScanError> {
    let file = File::open(path)?;
    let compressed = path
        .file_name()
        .and_then(|value| value.to_str())
        .is_some_and(|name| name.ends_with(DSH_COMPRESSED_SUFFIX));
    if !compressed {
        return Ok(Box::new(BufReader::with_capacity(READ_BUFFER_BYTES, file)));
    }
    let source = BufReader::with_capacity(READ_BUFFER_BYTES, file);
    Ok(Box::new(BufReader::with_capacity(
        READ_BUFFER_BYTES,
        MultiFrameReader::new(source),
    )))
}

/// 多帧 zstd 流式解码 (C189)。
///
/// dsh 每次追加写一个独立帧, 单文件常态数百帧; ruzstd 的 `StreamingDecoder` 只解码单帧,
/// 这里逐帧 `FrameDecoder::init` → `decode_blocks(All)` → `collect_to_writer`, 并复用同一个
/// `FrameDecoder` (解码缓冲跨帧复用, 不逐帧重新分配)。一帧的内容先落到 `pending`
/// (dsh 一帧即一行事件, 内存受单行上限约束), 再按调用方的缓冲长度切片返回 —— 不能用
/// `StreamingDecoder::read` 连着读下一帧: 它为避免破坏环形窗口, 未到帧尾时可能返回 0,
/// 把这种 0 当帧边界会丢掉该帧剩余内容。
/// 合法但无负载的 skippable frame 跳过; 其余解码错误按数据损坏上报, 由调用方跳过该文件。
struct MultiFrameReader<R: BufRead> {
    source: R,
    frame: FrameDecoder,
    /// 当前帧的解压内容。
    pending: Vec<u8>,
    /// `pending` 已返回给调用方的字节数。
    offset: usize,
    finished: bool,
}

impl<R: BufRead> MultiFrameReader<R> {
    fn new(source: R) -> Self {
        Self {
            source,
            frame: FrameDecoder::new(),
            pending: Vec::new(),
            offset: 0,
            finished: false,
        }
    }

    /// 解出下一帧的全部内容到 `pending`; 流已到末尾时返回 false。
    fn decode_next_frame(&mut self) -> io::Result<bool> {
        loop {
            if self.source.fill_buf()?.is_empty() {
                return Ok(false);
            }
            match self.frame.init(&mut self.source) {
                Ok(()) => break,
                Err(FrameDecoderError::ReadFrameHeaderError(ReadFrameHeaderError::SkipFrame {
                    length,
                    ..
                })) => {
                    let mut skip = (&mut self.source).take(u64::from(length));
                    io::copy(&mut skip, &mut io::sink())?;
                }
                Err(error) => return Err(dsh_zstd_error(error)),
            }
        }
        // 帧头声明了内容长度时先挡掉病态大帧, 不解压。
        let declared = self.frame.content_size();
        if declared > DSH_MAX_FRAME_CONTENT_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("dsh zstd frame declares {declared} bytes, exceeds the frame limit"),
            ));
        }
        // 一帧内的块可能很多 (大行), 解到帧尾再整体取出。
        while !self.frame.is_finished() {
            self.frame
                .decode_blocks(&mut self.source, BlockDecodingStrategy::All)
                .map_err(dsh_zstd_error)?;
        }
        self.pending.clear();
        self.offset = 0;
        self.frame.collect_to_writer(&mut self.pending)?;
        if self.pending.len() as u64 > DSH_MAX_FRAME_CONTENT_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "dsh zstd frame content exceeds the frame limit",
            ));
        }
        Ok(true)
    }
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

fn dsh_zstd_error(error: FrameDecoderError) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, error)
}
