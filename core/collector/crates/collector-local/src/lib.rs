#![deny(unsafe_code)]

//! Local file and SQLite adapters.

mod jsonl_cache;
mod sources;
mod sqlite_cache;

use collector_domain::{
    CollectionWindow, ModelDelta, ProjectDelta, TokenBucket, UsageContribution,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io::{self, BufRead};
use std::path::{Path, PathBuf};

pub const MAX_JSONL_RECORD_BYTES: usize = 1024 * 1024;
/// SQLite 缓存的压缩贡献格式版本 (`CompactContribution`)。
/// v2: 新增自然月 × 模型聚合 (modelMonths); v3 (C070): 新增最近 31 天 日期 × 模型 与今日
/// 小时 × 模型 token 桶。格式演进必须升级本常量令旧条目整体重建 (C072)。
pub const AGGREGATION_VERSION: u32 = 3;

pub use sources::{
    scan_claude, scan_claude_cached, scan_claude_with_cancellation, scan_codebuddy,
    scan_codebuddy_cached, scan_codebuddy_with_cancellation, scan_codex, scan_codex_cached,
    scan_codex_cached_with_cancellation, scan_codex_with_cancellation, scan_grok, scan_grok_cached,
    scan_grok_with_cancellation, scan_kimi_cli_cached, scan_kimi_tree, scan_kimi_tree_cached,
    scan_kimi_tree_with_cancellation, scan_opencode, scan_opencode_cached,
    scan_opencode_with_cancellation, scan_pi, scan_pi_cached, scan_pi_with_cancellation,
    scan_zcode, scan_zcode_cached, scan_zcode_with_cancellation, SourceScan, SourceScanError,
};

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ScanStats {
    pub files_visited: u64,
    pub files_scanned: u64,
    pub files_skipped: u64,
    pub duplicate_files_skipped: u64,
    pub duplicate_session_groups: u64,
    pub conflict_session_groups: u64,
    pub io_errors: u64,
    pub cache_hits: u64,
    pub cache_appends: u64,
    pub cache_rebuilds: u64,
    pub cache_corruptions: u64,
    pub cache_invalidations: u64,
    pub cache_deletions: u64,
    pub sqlite_rows_read: u64,
    pub lines_seen: u64,
    pub json_lines_parsed: u64,
    pub usage_records: u64,
    pub malformed_lines: u64,
    pub ignored_lines: u64,
    pub truncated_lines: u64,
    pub bytes_read: u64,
}

impl ScanStats {
    pub fn merge(&mut self, other: Self) {
        self.files_visited = self.files_visited.saturating_add(other.files_visited);
        self.files_scanned = self.files_scanned.saturating_add(other.files_scanned);
        self.files_skipped = self.files_skipped.saturating_add(other.files_skipped);
        self.duplicate_files_skipped = self
            .duplicate_files_skipped
            .saturating_add(other.duplicate_files_skipped);
        self.duplicate_session_groups = self
            .duplicate_session_groups
            .saturating_add(other.duplicate_session_groups);
        self.conflict_session_groups = self
            .conflict_session_groups
            .saturating_add(other.conflict_session_groups);
        self.io_errors = self.io_errors.saturating_add(other.io_errors);
        self.cache_hits = self.cache_hits.saturating_add(other.cache_hits);
        self.cache_appends = self.cache_appends.saturating_add(other.cache_appends);
        self.cache_rebuilds = self.cache_rebuilds.saturating_add(other.cache_rebuilds);
        self.cache_corruptions = self
            .cache_corruptions
            .saturating_add(other.cache_corruptions);
        self.cache_invalidations = self
            .cache_invalidations
            .saturating_add(other.cache_invalidations);
        self.cache_deletions = self.cache_deletions.saturating_add(other.cache_deletions);
        self.sqlite_rows_read = self.sqlite_rows_read.saturating_add(other.sqlite_rows_read);
        self.lines_seen = self.lines_seen.saturating_add(other.lines_seen);
        self.json_lines_parsed = self
            .json_lines_parsed
            .saturating_add(other.json_lines_parsed);
        self.usage_records = self.usage_records.saturating_add(other.usage_records);
        self.malformed_lines = self.malformed_lines.saturating_add(other.malformed_lines);
        self.ignored_lines = self.ignored_lines.saturating_add(other.ignored_lines);
        self.truncated_lines = self.truncated_lines.saturating_add(other.truncated_lines);
        self.bytes_read = self.bytes_read.saturating_add(other.bytes_read);
    }
}

/// Resolve the default incremental cache root.
///
/// macOS/Linux keep the historical `~/Library/Application Support` layout;
/// Windows resolves under `%LOCALAPPDATA%` (env first, `~/AppData/Local`
/// fallback) so machine-local caches never land in the roaming profile.
pub fn default_cache_root(home: &Path) -> PathBuf {
    #[cfg(windows)]
    {
        let local_app_data = std::env::var("LOCALAPPDATA").ok();
        windows_cache_root(home, local_app_data.as_deref())
    }
    #[cfg(not(windows))]
    {
        home.join("Library/Application Support/Bruce/collector-cache-v1")
    }
}

/// Windows cache root with the `LOCALAPPDATA` value injected for tests.
///
/// Blank env values count as unset (trimmed, matching `paths.rs`
/// `env_non_empty` semantics) so the home-relative fallback applies.
#[cfg(windows)]
fn windows_cache_root(home: &Path, local_app_data: Option<&str>) -> PathBuf {
    let trimmed = local_app_data
        .map(str::trim)
        .filter(|value| !value.is_empty());
    match trimmed {
        Some(value) => PathBuf::from(value)
            .join("Bruce")
            .join("collector-cache-v1"),
        None => home
            .join("AppData")
            .join("Local")
            .join("Bruce")
            .join("collector-cache-v1"),
    }
}

/// 清理 C116 前 Kimi Code CLI 旧版缓存引擎遗留的条目与清单 (`<64 位十六进制>.json` /
/// `manifest-<64 位十六进制>.json`), 返回删除数。
///
/// 缓存根下其余引擎的文件都带 `jsonl-` / `manifest-jsonl-` / `sqlite-` / `codex-tree-` 前缀,
/// 不会命中; 缓存可再生, 删除失败只影响磁盘占用, 静默忽略。
pub fn remove_legacy_kimi_cache(cache_root: &Path) -> u64 {
    let Ok(entries) = fs::read_dir(cache_root) else {
        return 0;
    };
    let is_digest = |value: &str| value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit());
    let mut removed = 0;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(stem) = name.strip_suffix(".json") else {
            continue;
        };
        let legacy = is_digest(stem) || stem.strip_prefix("manifest-").is_some_and(is_digest);
        if legacy
            && entry.file_type().is_ok_and(|kind| kind.is_file())
            && fs::remove_file(entry.path()).is_ok()
        {
            removed += 1;
        }
    }
    removed
}

/// 目录递归深度上限: 全部会话目录遍历 (本文件的缓存 walker、sources.rs 的
/// 未缓存 walker 与 codex 收集、jsonl_cache 的树遍历) 共用同一常量与
/// 「深度上限 + canonical 已访问集合」双重护栏 (C045)。
pub(crate) const MAX_DIRECTORY_SCAN_DEPTH: usize = 16;

/// Compact cache-only representation. Cache entries are internal and
/// rebuildable, so arrays are preferable to repeating JSON field names for
/// every daily bucket while the domain contribution remains ergonomic.
/// 自然月 × 模型的压缩缓存表示 (月 key → 模型 → 五元 token 桶).
type CompactMonthModels = Vec<(String, Vec<(String, [u64; 5])>)>;
/// 日期 × 模型的压缩缓存表示 (窗口日序号 → 模型 → 五元 token 桶; C070).
type CompactDayModels = Vec<(u16, Vec<(String, [u64; 5])>)>;
/// 今日 小时 × 模型的压缩缓存表示 (小时 → 模型 → 五元 token 桶; C070).
type CompactHourModels = Vec<(u8, Vec<(String, [u64; 5])>)>;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub(crate) struct CompactContribution {
    days: Vec<(u16, [u64; 5])>,
    #[serde(default)]
    month_models: CompactMonthModels,
    models_today: Vec<(String, [u64; 5])>,
    projects_today: Vec<(String, u64)>,
    hours: Vec<u64>,
    #[serde(default)]
    day_models: CompactDayModels,
    #[serde(default)]
    hour_models: CompactHourModels,
}

fn compact_models(models: &BTreeMap<String, TokenBucket>) -> Vec<(String, [u64; 5])> {
    models
        .iter()
        .map(|(model, bucket)| (model.clone(), bucket_array(bucket)))
        .collect()
}

fn expand_models(models: &[(String, [u64; 5])]) -> BTreeMap<String, TokenBucket> {
    models
        .iter()
        .map(|(model, values)| (model.clone(), bucket_from_array(*values)))
        .collect()
}

impl CompactContribution {
    pub(crate) fn from_domain(
        value: &UsageContribution,
        window: &CollectionWindow,
    ) -> Option<Self> {
        let days = value
            .by_day
            .iter()
            .map(|(day, bucket)| {
                window
                    .day_list
                    .iter()
                    .position(|candidate| candidate == day)
                    .and_then(|index| u16::try_from(index).ok())
                    .map(|index| (index, bucket_array(bucket)))
            })
            .collect::<Option<Vec<_>>>()?;
        let month_models = value
            .models_by_month
            .iter()
            .map(|(month, models)| {
                (
                    month.clone(),
                    models
                        .iter()
                        .map(|(model, bucket)| (model.clone(), bucket_array(bucket)))
                        .collect(),
                )
            })
            .collect();
        let day_models = value
            .models_by_day
            .iter()
            .map(|(day, models)| {
                window
                    .day_list
                    .iter()
                    .position(|candidate| candidate == day)
                    .and_then(|index| u16::try_from(index).ok())
                    .map(|index| (index, compact_models(models)))
            })
            .collect::<Option<Vec<_>>>()?;
        let hour_models = value
            .hour_models_today
            .iter()
            .map(|(hour, models)| (*hour, compact_models(models)))
            .collect();
        Some(Self {
            days,
            month_models,
            day_models,
            hour_models,
            models_today: value
                .models_today
                .iter()
                .map(|model| (model.model.clone(), bucket_array(&model.bucket)))
                .collect(),
            projects_today: value
                .projects_today
                .iter()
                .map(|project| (project.name.clone(), project.total))
                .collect(),
            hours: value.hours.clone(),
        })
    }

    pub(crate) fn to_domain(&self, window: &CollectionWindow) -> Option<UsageContribution> {
        let by_day = self
            .days
            .iter()
            .map(|(index, values)| {
                window
                    .day_list
                    .get(*index as usize)
                    .cloned()
                    .map(|day| (day, bucket_from_array(*values)))
            })
            .collect::<Option<BTreeMap<_, _>>>()?;
        let models_by_day = self
            .day_models
            .iter()
            .map(|(index, models)| {
                window
                    .day_list
                    .get(*index as usize)
                    .cloned()
                    .map(|day| (day, expand_models(models)))
            })
            .collect::<Option<BTreeMap<_, _>>>()?;
        Some(UsageContribution {
            models_by_month: self
                .month_models
                .iter()
                .map(|(month, models)| {
                    (
                        month.clone(),
                        models
                            .iter()
                            .map(|(model, values)| (model.clone(), bucket_from_array(*values)))
                            .collect::<BTreeMap<_, _>>(),
                    )
                })
                .collect(),
            models_today: self
                .models_today
                .iter()
                .map(|(model, values)| ModelDelta {
                    model: model.clone(),
                    bucket: bucket_from_array(*values),
                })
                .collect(),
            projects_today: self
                .projects_today
                .iter()
                .map(|(name, total)| ProjectDelta {
                    name: name.clone(),
                    total: *total,
                })
                .collect(),
            hours: self.hours.clone(),
            by_day,
            models_by_day,
            hour_models_today: self
                .hour_models
                .iter()
                .map(|(hour, models)| (*hour, expand_models(models)))
                .collect(),
        })
    }
}

fn bucket_array(bucket: &TokenBucket) -> [u64; 5] {
    [
        bucket.input,
        bucket.output,
        bucket.cache_read,
        bucket.cache_creation,
        bucket.total,
    ]
}

fn bucket_from_array(values: [u64; 5]) -> TokenBucket {
    TokenBucket {
        input: values[0],
        output: values[1],
        cache_read: values[2],
        cache_creation: values[3],
        total: values[4],
        // 紧凑缓存表示不携带 1 小时 TTL 份额: 只有 Claude 有该拆分, 其聚合始终从
        // 观测值重建 (C107)。
        cache_creation_1h: 0,
    }
}

/// 会话文件读缓冲 (C110): 64 KiB 降低大文件的 read 系统调用次数 (默认 8 KiB)。
pub(crate) const READ_BUFFER_BYTES: usize = 64 * 1024;

pub(crate) struct BoundedLine {
    bytes: usize,
    truncated: bool,
}

/// 读取一行到调用方复用的 `bytes_data` (C110)。
///
/// 旧实现每行新建 Vec: Claude Code 单行常达数百 KiB (工具输出), 逐行的大块分配
/// 释放触发 mmap/munmap 与缺页清零, 冷扫 0.15 s 用户态之外另耗约 0.6 s 内核态。
/// 复用缓冲后只在行长创新高时扩容。
fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    limit: usize,
    bytes_data: &mut Vec<u8>,
) -> io::Result<Option<BoundedLine>> {
    bytes_data.clear();
    let mut bytes = 0usize;
    let mut truncated = false;
    loop {
        let (chunk_len, newline_at) = {
            let chunk = reader.fill_buf()?;
            if chunk.is_empty() {
                if bytes == 0 {
                    return Ok(None);
                }
                (0, None)
            } else {
                let newline_at = chunk.iter().position(|byte| *byte == b'\n');
                (
                    newline_at.map(|index| index + 1).unwrap_or(chunk.len()),
                    newline_at,
                )
            }
        };
        if chunk_len == 0 {
            break;
        }
        {
            let chunk = reader.fill_buf()?;
            bytes = bytes.saturating_add(chunk_len);
            if !truncated {
                let remaining = limit.saturating_sub(bytes_data.len());
                let copy_len = remaining.min(chunk_len);
                bytes_data.extend_from_slice(&chunk[..copy_len]);
                if copy_len < chunk_len {
                    truncated = true;
                }
            }
        }
        reader.consume(chunk_len);
        if newline_at.is_some() {
            break;
        }
    }
    Ok(Some(BoundedLine { bytes, truncated }))
}

fn trim_line_end(value: &[u8]) -> &[u8] {
    let value = value.strip_suffix(b"\n").unwrap_or(value);
    value.strip_suffix(b"\r").unwrap_or(value)
}

#[cfg(test)]
mod tests {
    use super::{read_bounded_line, MAX_JSONL_RECORD_BYTES};
    use collector_domain::{CollectionWindow, UsageContributionBuilder};
    use serde_json::json;
    use std::fs;
    use std::io::Cursor;

    #[cfg(not(windows))]
    #[test]
    fn default_cache_root_keeps_historical_layout_outside_windows() {
        assert_eq!(
            super::default_cache_root(std::path::Path::new("/Users/dev")),
            std::path::PathBuf::from(
                "/Users/dev/Library/Application Support/Bruce/collector-cache-v1",
            )
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_cache_root_prefers_non_empty_localappdata_env() {
        assert_eq!(
            super::windows_cache_root(
                std::path::Path::new("C:\\Users\\dev"),
                Some("C:\\Users\\dev\\AppData\\Local"),
            ),
            std::path::PathBuf::from("C:\\Users\\dev\\AppData\\Local\\Bruce\\collector-cache-v1")
        );
    }

    #[cfg(windows)]
    #[test]
    fn windows_cache_root_falls_back_to_home_when_env_missing_or_blank() {
        let expected =
            std::path::PathBuf::from("C:\\Users\\dev\\AppData\\Local\\Bruce\\collector-cache-v1");
        assert_eq!(
            super::windows_cache_root(std::path::Path::new("C:\\Users\\dev"), None),
            expected
        );
        assert_eq!(
            super::windows_cache_root(std::path::Path::new("C:\\Users\\dev"), Some("   ")),
            expected
        );
    }

    #[test]
    fn oversized_line_is_consumed_without_allocating_the_full_record() {
        let mut input = Vec::from(
            br#"{"type":"usage.record","time":1785211200000,"usage":{"inputOther":1},"padding":"#,
        );
        input.extend(std::iter::repeat_n(b'x', MAX_JSONL_RECORD_BYTES + 16));
        input.extend_from_slice(b"\"}\nnext\n");
        let mut reader = Cursor::new(input);
        let mut buffer = Vec::new();
        let line = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES, &mut buffer)
            .unwrap()
            .unwrap();
        assert!(line.truncated);
        assert_eq!(
            buffer.len(),
            MAX_JSONL_RECORD_BYTES,
            "超长行只保留上限内字节"
        );
        let next = read_bounded_line(&mut reader, MAX_JSONL_RECORD_BYTES, &mut buffer)
            .unwrap()
            .unwrap();
        assert!(!next.truncated);
        assert_eq!(super::trim_line_end(&buffer), b"next", "复用缓冲读取下一行");
    }

    /// C116: 只清理旧版 Kimi 引擎遗留文件, 其余引擎的缓存与非缓存文件不动。
    #[test]
    fn legacy_kimi_cache_cleanup_only_touches_legacy_names() {
        let root = std::env::temp_dir().join(format!("bruce-legacy-kimi-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let digest = "a".repeat(64);
        let keep = [
            format!("jsonl-{digest}.json"),
            format!("manifest-jsonl-{digest}.json"),
            format!("sqlite-{digest}.json"),
            "codex-tree-v1.json".to_owned(),
            format!("{}.json", "a".repeat(63)),
            format!("{digest}.json.tmp"),
        ];
        let remove = [format!("{digest}.json"), format!("manifest-{digest}.json")];
        for name in keep.iter().chain(remove.iter()) {
            fs::write(root.join(name), "{}").unwrap();
        }
        assert_eq!(super::remove_legacy_kimi_cache(&root), 2);
        for name in &keep {
            assert!(root.join(name).exists(), "误删 {name}");
        }
        for name in &remove {
            assert!(!root.join(name).exists(), "未清理 {name}");
        }
        fs::remove_dir_all(&root).ok();
    }

    /// C070: 压缩缓存表示必须无损保留 日期×模型 与 今日 小时×模型 明细桶;
    /// 旧条目 (无新字段) 仍可反序列化, 由 AGGREGATION_VERSION 升级触发重建。
    #[test]
    fn compact_cache_round_trips_workbench_detail_buckets() {
        let context = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00", "timezone": "Asia/Shanghai", "days": 40
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let mut builder = UsageContributionBuilder::new(window.clone());
        for (at, model) in [
            (1_785_211_200_000i64 - 39 * 86_400_000, "old-model"),
            (1_785_211_200_000 - 5 * 86_400_000, "k3-agent"),
            (1_785_211_200_000 - 3_600_000, "k3-agent"),
            (1_785_211_200_000, "gpt-5"),
        ] {
            assert!(builder.record(collector_domain::UsageSample {
                timestamp_millis: at,
                model: Some(model),
                input: 7,
                output: 3,
                cache_read: 2,
                cache_creation: 1,
                cache_creation_1h: 0,
                project: None,
            }));
        }
        let contribution = builder.contribution();
        assert_eq!(contribution.models_by_day.len(), 2, "39 天前不进逐日明细");
        assert_eq!(contribution.hour_models_today.len(), 2);
        let compact = super::CompactContribution::from_domain(&contribution, &window).unwrap();
        let encoded = serde_json::to_string(&compact).unwrap();
        let decoded: super::CompactContribution = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded.to_domain(&window).unwrap(), contribution);

        let mut legacy = serde_json::to_value(&compact).unwrap();
        legacy.as_object_mut().unwrap().remove("day_models");
        legacy.as_object_mut().unwrap().remove("hour_models");
        let legacy: super::CompactContribution = serde_json::from_value(legacy).unwrap();
        let restored = legacy.to_domain(&window).unwrap();
        assert!(restored.models_by_day.is_empty() && restored.hour_models_today.is_empty());
        assert_eq!(
            super::AGGREGATION_VERSION,
            3,
            "明细结构变化须升级缓存聚合版本"
        );
    }
}
