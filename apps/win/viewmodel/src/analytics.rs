//! Agent 用量工作台分析 —— mac `WorkbenchAnalytics.swift` / `ModelNormalizer.swift` /
//! `AnalyticsModels.swift` 的逐条镜像 (design 06 §4.2, C070)。
//!
//! 纯函数: 只读 artifact, 不估算 —— 数值都可追溯到 artifact 字段或采集端计价结果; 旧 artifact
//! 缺明细桶 / 缺缓存拆分时对应指标为 `None` / 「—」。浮点累加顺序、排序次序键与 Swift 侧逐条一致,
//! 由 mac `PanelParityHarness` 产出的 `*.analytics.json` golden 逐字段对拍
//! (`tests/analytics_parity.rs`)。

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::color::PanelAgentColor;
use crate::format::token_count;
use crate::model_catalog::catalog;

// MARK: - 时间范围与粒度

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalyticsRange {
    Today,
    SevenDays,
    ThirtyDays,
    ThisMonth,
    AllTime,
}

impl AnalyticsRange {
    /// 与 mac `AnalyticsTimeRange.allCases` 同序。
    pub const ALL: [AnalyticsRange; 5] = [
        AnalyticsRange::Today,
        AnalyticsRange::SevenDays,
        AnalyticsRange::ThirtyDays,
        AnalyticsRange::ThisMonth,
        AnalyticsRange::AllTime,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            AnalyticsRange::Today => "today",
            AnalyticsRange::SevenDays => "7d",
            AnalyticsRange::ThirtyDays => "30d",
            AnalyticsRange::ThisMonth => "month",
            AnalyticsRange::AllTime => "all",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|range| range.as_str() == raw)
    }

    fn granularity(&self) -> Granularity {
        match self {
            AnalyticsRange::Today => Granularity::Hour,
            AnalyticsRange::SevenDays | AnalyticsRange::ThirtyDays | AnalyticsRange::ThisMonth => {
                Granularity::Day
            }
            AnalyticsRange::AllTime => Granularity::Month,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Granularity {
    Hour,
    Day,
    Month,
}

// MARK: - 输入: artifact 的工作台视图
//
// 不复用 collector-domain 的 AgentUsage: 那里缺失的明细数组 / 缓存拆分会默认成空或 0,
// 而工作台必须区分「旧 artifact 没有该字段」(显示「—」) 与「有字段但为空」(显示 0)。

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Artifact {
    generated_at: String,
    agents: Vec<Agent>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Agent {
    id: String,
    name: String,
    status: String,
    note: Option<String>,
    today: Bucket,
    daily: Vec<Day>,
    hours: Vec<i64>,
    projects: Option<Vec<ProjectUsage>>,
    daily_models: Option<Vec<Detail>>,
    month_models: Option<Vec<Detail>>,
    hour_models: Option<Vec<Detail>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bucket {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_creation: i64,
    total: i64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Day {
    date: String,
    /// 展示口径: 含缓存读取与缓存写入。
    input: i64,
    output: i64,
    total: i64,
    cache_read: Option<i64>,
    cache_creation: Option<i64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Detail {
    date: Option<String>,
    month: Option<String>,
    hour: Option<i64>,
    model: String,
    input: i64,
    output: i64,
    cache_read: i64,
    cache_creation: i64,
    total: i64,
    cost_usd: Option<f64>,
    cache_savings_usd: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProjectUsage {
    pub name: String,
    pub total: i64,
}

// MARK: - 输出 (serde 与 mac golden 同构)

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsSnapshot {
    pub range: &'static str,
    pub kpi: AnalyticsKpi,
    pub models: Vec<CanonicalModel>,
    pub timeline: AnalyticsTimeline,
    /// 范围内 token > 0 的 Agent, 按总量降序。
    pub agents: Vec<AnalyticsAgentCard>,
    /// 今日 24 小时 token 合计 (全部 Agent)。
    pub today_hourly_tokens: Vec<i64>,
}

/// 工作台 KPI: token 四象限为原始口径 (输入不含缓存), 四者之和 = 总量。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsKpi {
    pub total_tokens: i64,
    pub total_tokens_text: String,
    pub equivalent_m_text: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_creation_tokens: i64,
    pub cache_split_available: bool,
    pub input_tokens_text: String,
    pub output_tokens_text: String,
    pub cache_read_tokens_text: String,
    pub cache_creation_tokens_text: String,
    pub total_cost_usd: Option<f64>,
    pub cost_text: String,
    pub priced_tokens: i64,
    pub unpriced_tokens: i64,
    pub average_cost_per_million_text: String,
    pub cost_tag_text: String,
    pub cache_hit_rate_text: String,
    pub cache_savings_usd: Option<f64>,
    pub cache_saved_cost_text: String,
    pub active_agents_count: i64,
    pub top_agent_text: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalModel {
    pub canonical_key: String,
    pub display_name: String,
    pub vendor: String,
    pub color_hex: String,
    pub total_tokens: i64,
    pub total_tokens_text: String,
    pub cost_usd: Option<f64>,
    pub cost_text: Option<String>,
    pub share_percent: f64,
    pub sources: Vec<ModelSource>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSource {
    pub raw_model_name: String,
    pub agent_id: String,
    pub agent_display_name: String,
    pub tokens: i64,
    pub tokens_text: String,
    pub cost_usd: Option<f64>,
    pub cost_text: Option<String>,
    pub share_of_model_percent: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsTimeline {
    pub granularity: Granularity,
    pub points: Vec<TimelinePoint>,
    pub peak_summary: String,
    pub avg_summary: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TimelinePoint {
    pub label: String,
    pub total_tokens: i64,
    pub cost_usd: f64,
    /// Agent id / `type_input|type_output|type_cache` / `model_<规范键>` -> token。
    pub series_values: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnalyticsAgentCard {
    pub agent_id: String,
    pub name: String,
    pub status: String,
    pub note: Option<String>,
    pub total_tokens: i64,
    pub total_tokens_text: String,
    pub cost_usd: Option<f64>,
    pub cost_text: String,
    pub share_percent: f64,
    /// 比例条三段 (输入含缓存写入 / 输出 / 缓存读取) 之和 = 总量。
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cache_read_tokens: i64,
    pub cache_creation_tokens: i64,
    pub color_hex: String,
    pub top_projects: Vec<ProjectUsage>,
    pub top_models: Vec<CanonicalModel>,
}

// MARK: - 文案格式 (mac `AnalyticsFormat`; Rust `{:.N}` 与 C printf 同为精确值舍入, 平局取偶)

/// "$12.34"
pub fn usd(value: f64) -> String {
    format!("${value:.2}")
}

/// "12.3%"
pub fn percent_text(value: f64) -> String {
    format!("{value:.1}%")
}

/// 「等价」量级文案: "1.23 B" / "45.67 M" / "8.9 K" / "123"。
pub fn scaled_tokens(value: i64) -> String {
    if value >= 1_000_000_000 {
        return format!("{:.2} B", value as f64 / 1_000_000_000.0);
    }
    if value >= 1_000_000 {
        return format!("{:.2} M", value as f64 / 1_000_000.0);
    }
    if value >= 1_000 {
        return format!("{:.1} K", value as f64 / 1_000.0);
    }
    value.to_string()
}

// MARK: - 模型名归一 (mac `ModelNormalizer`)

/// 规范键: 1. 小写、去首尾空白; 2. 截去第一个 `[` 起的标记; 3. 以最后一个 `/` 为界剥离前缀;
/// 4. 剥离尾部 `-YYYYMMDD`, 其次 `-MMDD`; 5. 剥离尾部 `-latest`。不做跨型号别名合并。
pub fn canonical_key(raw: &str) -> String {
    let mut key = raw.to_lowercase().trim().to_owned();
    if let Some(index) = key.find('[') {
        key = key[..index].trim().to_owned();
    }
    if let Some(index) = key.rfind('/') {
        key = key[index + 1..].trim().to_owned();
    }
    if let Some(stripped) = strip_digit_suffix(&key, 8).or_else(|| strip_digit_suffix(&key, 4)) {
        key = stripped;
    }
    if let Some(stripped) = key.strip_suffix("-latest") {
        key = stripped.to_owned();
    }
    if key.is_empty() {
        "unknown".to_owned()
    } else {
        key
    }
}

/// 尾部恰为 `-` + `digits` 位数字时返回剥离后的键。
fn strip_digit_suffix(key: &str, digits: usize) -> Option<String> {
    let bytes = key.as_bytes();
    if bytes.len() < digits + 1 {
        return None;
    }
    let start = bytes.len() - digits;
    (bytes[start - 1] == b'-' && bytes[start..].iter().all(u8::is_ascii_digit))
        .then(|| key[..start - 1].to_owned())
}

fn catalog_entry(key: &str) -> Option<&'static crate::model_catalog::CatalogEntry> {
    catalog()
        .iter()
        .find(|entry| canonical_key(entry.model_name) == key)
}

/// 展示名: 目录精确命中取目录展示名, 否则即规范键本身。
pub fn display_name(key: &str) -> String {
    catalog_entry(key)
        .map(|entry| entry.display_name.to_owned())
        .unwrap_or_else(|| key.to_owned())
}

/// 前缀 → 厂商 (目录未收录时的兜底, 按序匹配)。
const VENDOR_PREFIXES: &[(&[&str], &str)] = &[
    (&["claude"], "Anthropic"),
    (&["gpt", "o1", "o3", "o4", "codex"], "OpenAI"),
    (&["deepseek"], "DeepSeek"),
    (&["glm", "codegeex"], "智谱 AI (Zhipu)"),
    (&["kimi", "k2", "k3", "moonshot"], "Moonshot"),
    (&["gemini"], "Google"),
    (&["qwen"], "阿里云 (Qwen)"),
    (&["doubao"], "字节跳动 (Doubao)"),
    (&["step"], "StepFun"),
    (&["grok"], "xAI"),
    (&["minimax", "abab"], "MiniMax"),
    (&["hunyuan", "hy3", "hy4"], "腾讯混元"),
];

/// 厂商: 目录精确命中取目录厂商, 否则按规范键前缀推断, 未知为「其他」。
pub fn vendor(key: &str) -> String {
    if let Some(entry) = catalog_entry(key) {
        return entry.vendor.to_owned();
    }
    VENDOR_PREFIXES
        .iter()
        .find(|(prefixes, _)| prefixes.iter().any(|prefix| key.starts_with(prefix)))
        .map(|(_, vendor)| (*vendor).to_owned())
        .unwrap_or_else(|| "其他".to_owned())
}

const BRAND_COLORS: &[(&[&str], &str)] = &[
    (&["claude", "sonnet", "opus"], "#FF9F0A"),
    (&["deepseek"], "#30D158"),
    (&["glm", "zhipu"], "#40C8E0"),
    (&["gpt", "openai", "codex"], "#0A84FF"),
    (&["gemini", "google"], "#1A73E8"),
    (&["qwen", "tongyi"], "#624AFF"),
    (&["doubao", "bytedance"], "#007AFF"),
    (&["kimi", "k3"], "#BF5AF2"),
    (&["step"], "#FF375F"),
    (&["grok", "xai"], "#FFFFFF"),
    (&["minimax", "abab"], "#E03E2D"),
    (&["mimo", "xiaomi"], "#FF6900"),
    (&["hunyuan", "tencent", "hy3", "hy4"], "#00A3FF"),
    (&["baichuan"], "#E64A19"),
];

/// 模型品牌识别色 (纯展示; 按规范键子串匹配, 按序取首个)。
pub fn color_hex(key: &str) -> String {
    BRAND_COLORS
        .iter()
        .find(|(needles, _)| needles.iter().any(|needle| key.contains(needle)))
        .map(|(_, hex)| (*hex).to_owned())
        .unwrap_or_else(|| "#8E8E93".to_owned())
}

// MARK: - 计算

/// 原始口径 token 合计 (输入不含缓存)。
#[derive(Debug, Clone, Copy, Default)]
struct Tokens {
    input: i64,
    output: i64,
    cache_read: i64,
    cache_creation: i64,
    total: i64,
}

impl Tokens {
    /// daily.input 为展示口径 (含缓存读写), 还原为原始输入; 旧 artifact 缺拆分时缓存计 0。
    fn from_day(day: &Day) -> Self {
        let cache_read = day.cache_read.unwrap_or(0);
        let cache_creation = day.cache_creation.unwrap_or(0);
        Tokens {
            input: (day.input - cache_read - cache_creation).max(0),
            output: day.output,
            cache_read,
            cache_creation,
            total: day.total,
        }
    }

    fn add(&mut self, other: Tokens) {
        self.input += other.input;
        self.output += other.output;
        self.cache_read += other.cache_read;
        self.cache_creation += other.cache_creation;
        self.total += other.total;
    }
}

/// 范围内一个明细桶 (绑定所属 Agent 在 artifact 中的下标)。
struct Entry<'a> {
    agent_index: usize,
    detail: &'a Detail,
}

#[derive(Default)]
struct TimelineBucket {
    total: i64,
    by_agent: BTreeMap<String, i64>,
    /// (输入含缓存写入, 输出, 缓存读取); 数据不足时为 None, 不出构成序列。
    types: Option<(i64, i64, i64)>,
    by_model: BTreeMap<String, i64>,
    cost: f64,
}

/// 无 artifact (或 artifact 无法解码) 时的空快照。
pub fn empty(range: AnalyticsRange) -> AnalyticsSnapshot {
    AnalyticsSnapshot {
        range: range.as_str(),
        kpi: make_kpi(&[], &[], &[], false, false),
        models: Vec::new(),
        timeline: AnalyticsTimeline {
            granularity: range.granularity(),
            points: Vec::new(),
            peak_summary: "—".to_owned(),
            avg_summary: "—".to_owned(),
        },
        agents: Vec::new(),
        today_hourly_tokens: vec![0; 24],
    }
}

/// 工作台一次性快照; artifact 解码失败按无数据处理 (与 mac `decodedAgentUsageArtifact() == nil` 同)。
pub fn make(artifact: &Value, range: AnalyticsRange) -> AnalyticsSnapshot {
    match Artifact::deserialize(artifact) {
        Ok(artifact) => make_typed(&artifact, range),
        Err(_) => empty(range),
    }
}

fn make_typed(artifact: &Artifact, range: AnalyticsRange) -> AnalyticsSnapshot {
    let agents = &artifact.agents;
    // collector 的 daily 覆盖窗口内每一个自然日 (含 0), 末位即今日
    let window_dates: Vec<&str> = agents
        .iter()
        .flat_map(|agent| agent.daily.iter().map(|day| day.date.as_str()))
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    let today: String = window_dates
        .last()
        .map(|date| (*date).to_owned())
        .unwrap_or_else(|| artifact.generated_at.chars().take(10).collect());
    let range_dates: Vec<String> = match range {
        AnalyticsRange::Today => vec![today.clone()],
        AnalyticsRange::SevenDays => suffix(&window_dates, 7),
        AnalyticsRange::ThirtyDays => suffix(&window_dates, 30),
        AnalyticsRange::ThisMonth => {
            let month: String = today.chars().take(7).collect();
            window_dates
                .iter()
                .filter(|date| date.starts_with(&month))
                .map(|date| (*date).to_owned())
                .collect()
        }
        AnalyticsRange::AllTime => window_dates.iter().map(|date| (*date).to_owned()).collect(),
    };
    let date_set: BTreeSet<&str> = range_dates.iter().map(String::as_str).collect();
    // 今日取 today 桶 (恒有拆分); 多日范围要求每个 daily 都带缓存拆分 (旧 artifact 没有)
    let cache_split_available = range == AnalyticsRange::Today
        || agents.iter().all(|agent| {
            agent.daily.iter().all(|day| {
                !date_set.contains(day.date.as_str())
                    || (day.cache_read.is_some() && day.cache_creation.is_some())
            })
        });

    // 1. 各 Agent 范围内 token (原始口径, 四象限之和 = total)
    let agent_tokens: Vec<Tokens> = agents
        .iter()
        .map(|agent| {
            if range == AnalyticsRange::Today {
                return Tokens {
                    input: agent.today.input,
                    output: agent.today.output,
                    cache_read: agent.today.cache_read,
                    cache_creation: agent.today.cache_creation,
                    total: agent.today.total,
                };
            }
            let mut tokens = Tokens::default();
            for day in &agent.daily {
                if date_set.contains(day.date.as_str()) {
                    tokens.add(Tokens::from_day(day));
                }
            }
            tokens
        })
        .collect();

    // 2. 范围内明细桶: 今日 / 7·30 天 / 本月取 dailyModels, 全部历史取 monthModels
    let detail_available = agents.iter().any(|agent| {
        if range == AnalyticsRange::AllTime {
            agent.month_models.is_some()
        } else {
            agent.daily_models.is_some()
        }
    });
    let mut entries: Vec<Entry> = Vec::new();
    for (agent_index, agent) in agents.iter().enumerate() {
        if range == AnalyticsRange::AllTime {
            for detail in agent.month_models.iter().flatten() {
                entries.push(Entry {
                    agent_index,
                    detail,
                });
            }
        } else {
            for detail in agent.daily_models.iter().flatten() {
                if date_set.contains(detail.date.as_deref().unwrap_or("")) {
                    entries.push(Entry {
                        agent_index,
                        detail,
                    });
                }
            }
        }
    }

    let entries: Vec<&Entry> = entries.iter().collect();
    let models = canonical_models(&entries, agents);
    let top_model_keys: Vec<String> = models
        .iter()
        .take(5)
        .map(|model| model.canonical_key.clone())
        .collect();
    AnalyticsSnapshot {
        range: range.as_str(),
        kpi: make_kpi(
            agents,
            &agent_tokens,
            &entries,
            detail_available,
            cache_split_available,
        ),
        timeline: make_timeline(range, agents, &range_dates, &top_model_keys),
        agents: make_agent_cards(range, agents, &agent_tokens, &entries, detail_available),
        models,
        today_hourly_tokens: (0..24)
            .map(|hour| {
                agents
                    .iter()
                    .map(|agent| agent.hours.get(hour).copied().unwrap_or(0))
                    .sum::<i64>()
            })
            .collect(),
    }
}

fn suffix(dates: &[&str], count: usize) -> Vec<String> {
    dates[dates.len().saturating_sub(count)..]
        .iter()
        .map(|date| (*date).to_owned())
        .collect()
}

/// 字符级后缀 (Swift `String.suffix(_:)`): 不足 `count` 个字符时返回全部。
fn char_suffix(text: &str, count: usize) -> String {
    let length = text.chars().count();
    text.chars().skip(length.saturating_sub(count)).collect()
}

fn percent(part: i64, whole: i64) -> f64 {
    if whole > 0 {
        part as f64 / whole as f64 * 100.0
    } else {
        0.0
    }
}

/// 已定价桶金额之和: 无桶 (范围内无用量) 为 0; 有桶但全部未定价为 None (显示「—」, 不估算)。
fn priced_sum(entries: &[&Entry], value: fn(&Detail) -> Option<f64>) -> Option<f64> {
    if entries.is_empty() {
        return Some(0.0);
    }
    ordered_sum(entries.iter().filter_map(|entry| value(entry.detail)))
}

/// 按给定顺序左累加; 空序列为 None。f64 的 `sum()` 自 -0.0 起, 而 -0.0 + c₁ = c₁ 精确成立,
/// 故非空序列与 Swift `reduce(0, +)` 逐位一致 (累加顺序必须与 Swift 侧相同)。
fn ordered_sum(values: impl Iterator<Item = f64>) -> Option<f64> {
    let values: Vec<f64> = values.collect();
    (!values.is_empty()).then(|| values.into_iter().sum())
}

fn detail_cost(detail: &Detail) -> Option<f64> {
    detail.cost_usd
}

fn detail_savings(detail: &Detail) -> Option<f64> {
    detail.cache_savings_usd
}

// MARK: - KPI

fn make_kpi(
    agents: &[Agent],
    agent_tokens: &[Tokens],
    entries: &[&Entry],
    detail_available: bool,
    cache_split_available: bool,
) -> AnalyticsKpi {
    let mut totals = Tokens::default();
    for tokens in agent_tokens {
        totals.add(*tokens);
    }
    let priced_tokens = entries
        .iter()
        .filter(|entry| entry.detail.cost_usd.is_some())
        .map(|entry| entry.detail.total)
        .sum();
    let unpriced_tokens = entries
        .iter()
        .filter(|entry| entry.detail.cost_usd.is_none())
        .map(|entry| entry.detail.total)
        .sum();

    // 最活跃 Agent: 总量最大, 并列取 artifact 中靠前者
    let mut top_index: Option<usize> = None;
    for (index, tokens) in agent_tokens.iter().enumerate() {
        if tokens.total <= 0 {
            continue;
        }
        if let Some(current) = top_index {
            if agent_tokens[current].total >= tokens.total {
                continue;
            }
        }
        top_index = Some(index);
    }
    let total_cost_usd = if detail_available {
        priced_sum(entries, detail_cost)
    } else {
        None
    };
    let cache_savings_usd = if detail_available {
        priced_sum(entries, detail_savings)
    } else {
        None
    };
    kpi_summary(KpiInput {
        totals,
        cache_split_available,
        total_cost_usd,
        priced_tokens,
        unpriced_tokens,
        cache_savings_usd,
        active_agents_count: agent_tokens
            .iter()
            .filter(|tokens| tokens.total > 0)
            .count() as i64,
        top_agent: top_index.map(|index| {
            (
                agents[index].name.clone(),
                percent(agent_tokens[index].total, totals.total),
            )
        }),
    })
}

struct KpiInput {
    totals: Tokens,
    cache_split_available: bool,
    total_cost_usd: Option<f64>,
    priced_tokens: i64,
    unpriced_tokens: i64,
    cache_savings_usd: Option<f64>,
    active_agents_count: i64,
    /// (名称, 占比 %)
    top_agent: Option<(String, f64)>,
}

/// mac `AnalyticsKPISummary.init` 的文案规则。
fn kpi_summary(input: KpiInput) -> AnalyticsKpi {
    let totals = input.totals;
    let split_text = |value: i64| {
        if input.cache_split_available {
            token_count(value)
        } else {
            "—".to_owned()
        }
    };
    let average_cost_per_million_text = match input.total_cost_usd {
        Some(cost) if input.priced_tokens > 0 => {
            usd(cost / input.priced_tokens as f64 * 1_000_000.0) + " / 1M"
        }
        _ => "—".to_owned(),
    };
    let cost_tag_text = if input.unpriced_tokens > 0 {
        token_count(input.unpriced_tokens) + " 未定价"
    } else if input.total_cost_usd.is_none() {
        "无明细".to_owned()
    } else {
        "单价表计价".to_owned()
    };
    let cache_base = totals.input + totals.cache_read + totals.cache_creation;
    let cache_hit_rate_text = if input.cache_split_available && cache_base > 0 {
        percent_text(totals.cache_read as f64 / cache_base as f64 * 100.0)
    } else {
        "—".to_owned()
    };
    AnalyticsKpi {
        total_tokens: totals.total,
        total_tokens_text: token_count(totals.total),
        equivalent_m_text: scaled_tokens(totals.total),
        input_tokens: totals.input,
        output_tokens: totals.output,
        cache_read_tokens: totals.cache_read,
        cache_creation_tokens: totals.cache_creation,
        cache_split_available: input.cache_split_available,
        input_tokens_text: split_text(totals.input),
        output_tokens_text: token_count(totals.output),
        cache_read_tokens_text: split_text(totals.cache_read),
        cache_creation_tokens_text: split_text(totals.cache_creation),
        total_cost_usd: input.total_cost_usd,
        cost_text: input
            .total_cost_usd
            .map(usd)
            .unwrap_or_else(|| "—".to_owned()),
        priced_tokens: input.priced_tokens,
        unpriced_tokens: input.unpriced_tokens,
        average_cost_per_million_text,
        cost_tag_text,
        cache_hit_rate_text,
        cache_savings_usd: input.cache_savings_usd,
        cache_saved_cost_text: input
            .cache_savings_usd
            .map(|value| format!("省 {}", usd(value)))
            .unwrap_or_else(|| "—".to_owned()),
        active_agents_count: input.active_agents_count,
        top_agent_text: input
            .top_agent
            .map(|(name, share)| format!("最活跃 {name} · {}", percent_text(share)))
            .unwrap_or_else(|| "—".to_owned()),
    }
}

// MARK: - 模型归并

/// 按规范键归并; 来源按 (原始模型名, Agent) 区分。次序: token 降序 → 规范键 / 原始名 → Agent 下标。
fn canonical_models(entries: &[&Entry], agents: &[Agent]) -> Vec<CanonicalModel> {
    #[derive(Default)]
    struct SourceTotal {
        tokens: i64,
        cost: Option<f64>,
    }
    let mut model_totals: BTreeMap<String, i64> = BTreeMap::new();
    let mut sources: BTreeMap<String, BTreeMap<(String, usize), SourceTotal>> = BTreeMap::new();
    for entry in entries {
        let key = canonical_key(&entry.detail.model);
        *model_totals.entry(key.clone()).or_default() += entry.detail.total;
        let source = sources
            .entry(key)
            .or_default()
            .entry((entry.detail.model.clone(), entry.agent_index))
            .or_default();
        source.tokens += entry.detail.total;
        if let Some(cost) = entry.detail.cost_usd {
            source.cost = Some(source.cost.unwrap_or(0.0) + cost);
        }
    }
    let grand_total: i64 = model_totals.values().sum();
    let mut summaries: Vec<CanonicalModel> = model_totals
        .into_iter()
        .map(|(key, total)| {
            let mut ordered: Vec<(&(String, usize), &SourceTotal)> = sources
                .get(&key)
                .map(|map| map.iter().collect())
                .unwrap_or_default();
            ordered.sort_by(|(left_key, left), (right_key, right)| {
                right
                    .tokens
                    .cmp(&left.tokens)
                    .then_with(|| left_key.0.cmp(&right_key.0))
                    .then_with(|| left_key.1.cmp(&right_key.1))
            });
            let contributions: Vec<ModelSource> = ordered
                .into_iter()
                .map(|((raw, agent_index), source)| {
                    let agent = &agents[*agent_index];
                    ModelSource {
                        raw_model_name: raw.clone(),
                        agent_id: agent.id.clone(),
                        agent_display_name: agent.name.clone(),
                        tokens: source.tokens,
                        tokens_text: token_count(source.tokens),
                        cost_usd: source.cost,
                        cost_text: source.cost.map(usd),
                        share_of_model_percent: percent(source.tokens, total),
                    }
                })
                .collect();
            let cost = ordered_sum(contributions.iter().filter_map(|source| source.cost_usd));
            CanonicalModel {
                display_name: display_name(&key),
                vendor: vendor(&key),
                color_hex: color_hex(&key),
                total_tokens: total,
                total_tokens_text: token_count(total),
                cost_usd: cost,
                cost_text: cost.map(usd),
                share_percent: percent(total, grand_total),
                sources: contributions,
                canonical_key: key,
            }
        })
        .collect();
    summaries.sort_by(|left, right| {
        right
            .total_tokens
            .cmp(&left.total_tokens)
            .then_with(|| left.canonical_key.cmp(&right.canonical_key))
    });
    summaries
}

// MARK: - 时序

fn make_timeline(
    range: AnalyticsRange,
    agents: &[Agent],
    range_dates: &[String],
    top_model_keys: &[String],
) -> AnalyticsTimeline {
    // 模型序列只画范围 Top 5; 费用计全部明细桶 (未定价桶计 0)
    let add_models = |details: Vec<&Detail>, bucket: &mut TimelineBucket| {
        for detail in details {
            let key = canonical_key(&detail.model);
            if top_model_keys.contains(&key) {
                *bucket.by_model.entry(key).or_default() += detail.total;
            }
            bucket.cost += detail.cost_usd.unwrap_or(0.0);
        }
    };

    let granularity = range.granularity();
    let mut labeled: Vec<(String, TimelineBucket)> = Vec::new();
    match granularity {
        Granularity::Hour => {
            let hour_detail_available = agents.iter().any(|agent| agent.hour_models.is_some());
            for hour in 0..24usize {
                let mut bucket = TimelineBucket::default();
                for agent in agents {
                    let value = agent.hours.get(hour).copied().unwrap_or(0);
                    bucket.total += value;
                    if value > 0 {
                        bucket.by_agent.insert(agent.id.clone(), value);
                    }
                }
                if hour_detail_available {
                    let details: Vec<&Detail> = agents
                        .iter()
                        .flat_map(|agent| agent.hour_models.iter().flatten())
                        .filter(|detail| detail.hour == Some(hour as i64))
                        .collect();
                    bucket.types = Some((
                        details.iter().map(|d| d.input + d.cache_creation).sum(),
                        details.iter().map(|d| d.output).sum(),
                        details.iter().map(|d| d.cache_read).sum(),
                    ));
                    add_models(details, &mut bucket);
                }
                labeled.push((format!("{hour:02}:00"), bucket));
            }
        }
        Granularity::Day => {
            for date in range_dates {
                let mut bucket = day_bucket(agents, std::slice::from_ref(date));
                let details: Vec<&Detail> = agents
                    .iter()
                    .flat_map(|agent| agent.daily_models.iter().flatten())
                    .filter(|detail| detail.date.as_deref() == Some(date.as_str()))
                    .collect();
                add_models(details, &mut bucket);
                labeled.push((char_suffix(date, 5), bucket));
            }
        }
        Granularity::Month => {
            let mut months: Vec<String> = Vec::new();
            for date in range_dates {
                let month: String = date.chars().take(7).collect();
                if !months.contains(&month) {
                    months.push(month);
                }
            }
            for month in months {
                let dates: Vec<String> = range_dates
                    .iter()
                    .filter(|date| date.starts_with(&month))
                    .cloned()
                    .collect();
                let mut bucket = day_bucket(agents, &dates);
                let details: Vec<&Detail> = agents
                    .iter()
                    .flat_map(|agent| agent.month_models.iter().flatten())
                    .filter(|detail| detail.month.as_deref() == Some(month.as_str()))
                    .collect();
                add_models(details, &mut bucket);
                labeled.push((month, bucket));
            }
        }
    }

    let points: Vec<TimelinePoint> = labeled
        .into_iter()
        .map(|(label, bucket)| {
            let mut series = bucket.by_agent;
            if let Some((input, output, cache)) = bucket.types {
                series.insert("type_input".to_owned(), input);
                series.insert("type_output".to_owned(), output);
                series.insert("type_cache".to_owned(), cache);
            }
            for (key, value) in bucket.by_model {
                series.insert(format!("model_{key}"), value);
            }
            TimelinePoint {
                label,
                total_tokens: bucket.total,
                cost_usd: bucket.cost,
                series_values: series,
            }
        })
        .collect();

    // 峰值取首个最大点 (全 0 时无峰值)
    let mut peak: Option<&TimelinePoint> = None;
    for point in &points {
        if point.total_tokens > peak.map(|p| p.total_tokens).unwrap_or(0) {
            peak = Some(point);
        }
    }
    let sum: i64 = points.iter().map(|point| point.total_tokens).sum();
    let average = if points.is_empty() {
        0
    } else {
        sum / points.len() as i64
    };
    let (peak_title, average_title) = match granularity {
        Granularity::Hour => ("峰值时段", "时均"),
        Granularity::Day => ("峰值", "日均"),
        Granularity::Month => ("峰值月", "月均"),
    };
    let peak_summary = peak
        .map(|point| {
            format!(
                "🔥 {peak_title}: **{}** ({} Tokens)",
                point.label,
                token_count(point.total_tokens)
            )
        })
        .unwrap_or_else(|| "—".to_owned());
    AnalyticsTimeline {
        granularity,
        avg_summary: format!("{average_title}: **{}** Tokens", token_count(average)),
        peak_summary,
        points,
    }
}

/// 若干自然日合计: Agent 序列与 Token 构成取自 `daily`; 任一天缺缓存拆分 (旧 artifact) 时不出构成。
fn day_bucket(agents: &[Agent], dates: &[String]) -> TimelineBucket {
    let mut bucket = TimelineBucket::default();
    let mut types = (0i64, 0i64, 0i64);
    let mut types_available = true;
    for agent in agents {
        let mut agent_total = 0;
        for day in &agent.daily {
            if !dates.contains(&day.date) {
                continue;
            }
            agent_total += day.total;
            if day.cache_read.is_none() || day.cache_creation.is_none() {
                types_available = false;
            }
            let tokens = Tokens::from_day(day);
            types.0 += tokens.input + tokens.cache_creation;
            types.1 += tokens.output;
            types.2 += tokens.cache_read;
        }
        bucket.total += agent_total;
        if agent_total > 0 {
            bucket.by_agent.insert(agent.id.clone(), agent_total);
        }
    }
    bucket.types = types_available.then_some(types);
    bucket
}

// MARK: - Agent 对比

fn make_agent_cards(
    range: AnalyticsRange,
    agents: &[Agent],
    agent_tokens: &[Tokens],
    entries: &[&Entry],
    detail_available: bool,
) -> Vec<AnalyticsAgentCard> {
    let range_total: i64 = agent_tokens.iter().map(|tokens| tokens.total).sum();
    let mut cards: Vec<(usize, AnalyticsAgentCard)> = agents
        .iter()
        .enumerate()
        .filter(|(index, _)| agent_tokens[*index].total > 0)
        .map(|(index, agent)| {
            let tokens = agent_tokens[index];
            let own: Vec<&Entry> = entries
                .iter()
                .copied()
                .filter(|entry| entry.agent_index == index)
                .collect();
            let cost_usd = if detail_available {
                priced_sum(&own, detail_cost)
            } else {
                None
            };
            (
                index,
                AnalyticsAgentCard {
                    agent_id: agent.id.clone(),
                    name: agent.name.clone(),
                    status: agent.status.clone(),
                    note: agent.note.clone(),
                    total_tokens: tokens.total,
                    total_tokens_text: token_count(tokens.total),
                    cost_usd,
                    cost_text: cost_usd.map(usd).unwrap_or_else(|| "—".to_owned()),
                    share_percent: percent(tokens.total, range_total),
                    input_tokens: tokens.input + tokens.cache_creation,
                    output_tokens: tokens.output,
                    cache_read_tokens: tokens.cache_read,
                    cache_creation_tokens: tokens.cache_creation,
                    color_hex: PanelAgentColor::resolve(&agent.id).hex().to_owned(),
                    // collector 只采集今日项目分布, 其他范围不冒用
                    top_projects: if range == AnalyticsRange::Today {
                        agent.projects.clone().unwrap_or_default()
                    } else {
                        Vec::new()
                    },
                    top_models: canonical_models(&own, agents),
                },
            )
        })
        .collect();
    cards.sort_by(|(left_index, left), (right_index, right)| {
        right
            .total_tokens
            .cmp(&left.total_tokens)
            .then_with(|| left_index.cmp(right_index))
    });
    cards.into_iter().map(|(_, card)| card).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_key_strips_channel_snapshot_and_marker_but_never_aliases() {
        assert_eq!(
            canonical_key("cline-pass/deepseek-v4.1-flash"),
            "deepseek-v4.1-flash"
        );
        assert_eq!(
            canonical_key("anthropic/claude-3-7-sonnet-20250219"),
            "claude-3-7-sonnet"
        );
        assert_eq!(canonical_key("gpt-5.4-mini-0305"), "gpt-5.4-mini");
        assert_eq!(canonical_key("gpt-4o-latest"), "gpt-4o");
        assert_eq!(canonical_key("deepseek-r1[thinking]"), "deepseek-r1");
        assert_eq!(canonical_key("  "), "unknown");
        for raw in [
            "deepseek-flash",
            "glm-4.5",
            "gpt-5.4-preview",
            "x-123456789",
        ] {
            assert_eq!(canonical_key(raw), raw, "{raw} 不得被别名合并");
        }
        assert_eq!(display_name("deepseek-v4.1-flash"), "DeepSeek V4.1 Flash");
        assert_eq!(display_name("deepseek-flash"), "deepseek-flash");
        assert_eq!(vendor("deepseek-flash"), "DeepSeek");
        assert_eq!(vendor("acme-coder"), "其他");
        // 目录模型名本身带 -latest 时按同一规则归一后精确匹配
        assert_eq!(display_name("jev"), "Jev Latest");
    }

    #[test]
    fn range_round_trips_through_its_wire_name() {
        for range in AnalyticsRange::ALL {
            assert_eq!(AnalyticsRange::parse(range.as_str()), Some(range));
        }
        assert_eq!(AnalyticsRange::parse("week"), None);
    }

    #[test]
    fn undecodable_artifact_yields_the_empty_snapshot() {
        let snapshot = make(
            &serde_json::json!({"agents": "oops"}),
            AnalyticsRange::Today,
        );
        assert_eq!(snapshot, empty(AnalyticsRange::Today));
        assert_eq!(snapshot.kpi.cost_text, "—");
        assert_eq!(snapshot.kpi.cost_tag_text, "无明细");
        assert_eq!(snapshot.today_hourly_tokens.len(), 24);
    }
}
