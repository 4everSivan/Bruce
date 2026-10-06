//! 视图模型数据契约 —— 对齐 mac `PanelModels.swift` 的面板类型。
//!
//! 序列化即双端对拍协议: 字段命名 camelCase, 枚举输出稳定字符串,
//! mac 侧 Parity Harness 将产出逐字段一致的 JSON。

use serde::Serialize;

use crate::color::PanelAgentColor;
use crate::format::token_count;

// MARK: - 诊断

/// 映射过程产生的可诊断状态; 空数据, error/partial 不得静默吞掉。
/// serde tag 固定为 kind, 变体命名与 Swift case 名一致。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase"
)]
pub enum PanelDiagnostic {
    MissingArtifact {
        module: String,
    },
    AgentIssue {
        agent_id: String,
        status: String,
        note: String,
    },
    ServiceIssue {
        service_id: String,
        status: String,
        note: String,
    },
    ServiceSkipped {
        service_id: String,
        status: String,
        note: String,
    },
    WindowDropped {
        service_id: String,
        reason: String,
    },
    EmptyUsageAgents,
}

// MARK: - 用量卡

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageChartSegment {
    pub agent_id: String,
    pub color: String,
    pub color_hex: String,
    pub value: i64,
}

impl UsageChartSegment {
    pub fn new(agent_id: &str, color: PanelAgentColor, value: i64) -> Self {
        Self {
            agent_id: agent_id.to_owned(),
            color: color.name().to_owned(),
            color_hex: color.hex().to_owned(),
            value,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageChartDay {
    pub date: String,
    pub total: i64,
    pub total_text: String,
    pub segments: Vec<UsageChartSegment>,
}

impl UsageChartDay {
    pub fn new(date: String, total: i64, segments: Vec<UsageChartSegment>) -> Self {
        Self {
            date,
            total,
            total_text: token_count(total),
            segments,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageLegendItem {
    pub agent_id: String,
    pub name: String,
    pub color: String,
    pub color_hex: String,
}

impl UsageLegendItem {
    pub fn new(agent_id: &str, name: &str, color: PanelAgentColor) -> Self {
        Self {
            agent_id: agent_id.to_owned(),
            name: name.to_owned(),
            color: color.name().to_owned(),
            color_hex: color.hex().to_owned(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageBreakdownItem {
    pub label: String,
    pub value: i64,
    pub value_text: String,
}

impl UsageBreakdownItem {
    pub fn counted(label: &str, value: i64) -> Self {
        Self {
            label: label.to_owned(),
            value,
            value_text: token_count(value),
        }
    }

    /// 文本型数值 (如百分比命中率), value 仅占位。
    pub fn textual(label: &str, value_text: String) -> Self {
        Self {
            label: label.to_owned(),
            value: 0,
            value_text,
        }
    }
}

// MARK: - 用量热力图

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageHeatmapCell {
    pub date: String,
    pub total: i64,
    /// 0 = 无量; 1-5 按当日绝对总量 100M 步进分档。
    pub level: i64,
}

/// 热力图周列: 固定 7 格 (周一到周日), null 为窗口外/未来占位。
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UsageHeatmapWeek {
    pub cells: Vec<Option<UsageHeatmapCell>>,
}

// MARK: - 按月统计

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageMonthlyTotal {
    pub label: String,
    pub total_text: String,
    pub is_current: bool,
    pub key: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageHalfYearSummary {
    pub total_text: String,
    pub average_text: String,
}

// MARK: - 模型用量

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageModelRow {
    pub name: String,
    pub total_text: String,
    pub pct_text: String,
    /// 该模型占所选周期总量的份额 (0-1), 驱动进度条宽度。
    pub share: f64,
    pub color_hex: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageModelPeriod {
    pub id: String,
    pub label: String,
    pub rows: Vec<UsageModelRow>,
}

/// 模型用量区块: 三档窗口 (本月/3 月/6 月) + 可点击的日历月 (与按月 chips 联动)。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageModelUsageSection {
    pub tiers: Vec<UsageModelPeriod>,
    pub months: Vec<UsageModelPeriod>,
    pub current_month_key: String,
}

// MARK: - 用量卡主体

/// 总量分档 (sage..forest), 驱动用量卡 hero 渐变与背景 tint;
/// 阈值与 mac `UsageTier.forTotal` 一致 (100M 步进)。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum UsageTier {
    Sage,
    Moss,
    Fern,
    Pine,
    Forest,
}

impl UsageTier {
    pub fn for_total(total_tokens: i64) -> Self {
        if total_tokens < 100_000_000 {
            UsageTier::Sage
        } else if total_tokens < 200_000_000 {
            UsageTier::Moss
        } else if total_tokens < 300_000_000 {
            UsageTier::Fern
        } else if total_tokens < 400_000_000 {
            UsageTier::Pine
        } else {
            UsageTier::Forest
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            UsageTier::Sage => "sage",
            UsageTier::Moss => "moss",
            UsageTier::Fern => "fern",
            UsageTier::Pine => "pine",
            UsageTier::Forest => "forest",
        }
    }

    /// 热力图档位 (1-5), 与 heatmap level 分档阈值一致。
    pub fn heatmap_level(&self) -> i64 {
        match self {
            UsageTier::Sage => 1,
            UsageTier::Moss => 2,
            UsageTier::Fern => 3,
            UsageTier::Pine => 4,
            UsageTier::Forest => 5,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageHeroViewModel {
    pub total_tokens: i64,
    pub total_tokens_text: String,
    /// 总成本文案, 定价缺失时为 null (UI 隐藏成本位)。
    pub cost_text: Option<String>,
    /// 输入 / 输出 / 缓存读取 / 缓存命中率 四格。
    pub breakdown: Vec<UsageBreakdownItem>,
    /// 14 日堆叠柱状图数据, 日期升序, 今天在最后。
    pub days: Vec<UsageChartDay>,
    pub legend: Vec<UsageLegendItem>,
    /// LIVE 呼吸灯: artifact 生成时间在阈值内视为实时。
    pub is_live: bool,
    pub heatmap: Vec<UsageHeatmapWeek>,
    pub monthly: Vec<UsageMonthlyTotal>,
    pub half_year: Option<UsageHalfYearSummary>,
    pub models: Option<UsageModelUsageSection>,
    pub usage_tier: String,
    /// 收起态近 7 天迷你热力图档位 (末 7 天, 不足 7 天按实际天数)。
    pub collapsed_week_levels: Vec<i64>,
}

// MARK: - 逐小时卡

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DistributionBar {
    pub name: String,
    pub total: i64,
    pub total_text: String,
    /// 占本组总量的比例 0...1, 作为量条宽度。
    pub share: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HourlyAgentRow {
    pub agent_id: String,
    pub name: String,
    pub color: String,
    pub color_hex: String,
    pub today_total: i64,
    pub today_total_text: String,
    /// 24 点折线 (0-23 时)。
    pub points: Vec<i64>,
    /// 有模型或项目明细时可展开。
    pub is_expandable: bool,
    /// 模型占比, Top 3 + 其他。
    pub models: Vec<DistributionBar>,
    /// 项目分布, Top 3 + 其他。
    pub projects: Vec<DistributionBar>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HourlyLineViewModel {
    pub rows: Vec<HourlyAgentRow>,
    /// 收起态迷你折线: 全 agent 逐小时合计, 固定 24 点。
    pub collapsed_points: Vec<i64>,
    /// 收起态峰值文案 (如 "峰值 15.6K"); 无数据峰值为 0。
    pub collapsed_peak_text: String,
}

// MARK: - 面板容器

/// 面板视图模型。
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PanelViewModel {
    pub usage: Option<UsageHeroViewModel>,
    pub subscription: Option<crate::subscription::SubscriptionViewModel>,
    pub hourly: Option<HourlyLineViewModel>,
    pub diagnostics: Vec<PanelDiagnostic>,
}
