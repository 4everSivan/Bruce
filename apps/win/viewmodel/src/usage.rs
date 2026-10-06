//! 用量/逐小时映射 —— 对齐 mac `UsageMapping.swift` 与 `PanelViewModelMapper`。
//!
//! 规则注释与 Swift 端保持同源; 任何行为差异都是对拍缺陷。

use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Datelike, Duration, NaiveDate};
use collector_domain::AgentUsageArtifact;

use crate::color::PanelAgentColor;
use crate::format::{cost_text, token_count};
use crate::models::{
    DistributionBar, HourlyAgentRow, HourlyLineViewModel, PanelDiagnostic, PanelViewModel,
    UsageBreakdownItem, UsageChartDay, UsageChartSegment, UsageHalfYearSummary, UsageHeatmapCell,
    UsageHeatmapWeek, UsageHeroViewModel, UsageLegendItem, UsageModelPeriod, UsageModelRow,
    UsageModelUsageSection, UsageMonthlyTotal, UsageTier,
};

/// 模型名 -> 颜色的稳定调色板 (跨周期一致; 按名称排序取色, 超出后循环)。
const MODEL_PALETTE: [&str; 8] = [
    "#0a84ff", "#ff9f0a", "#bf5af2", "#64d2ff", "#ff375f", "#30d158", "#ffcf7a", "#8e8e93",
];

/// LIVE 判定回看下限 (秒): 允许轻微时钟偏差。
const LIVE_LOOKBACK_SECS: i64 = -300;
/// LIVE 判定阈值默认值, 覆盖 30 分钟刷新周期加缓冲。
pub const DEFAULT_LIVE_THRESHOLD_SECS: i64 = 45 * 60;

/// 面板视图模型映射器 (对齐 `PanelViewModelMapper`)。
#[derive(Debug, Clone, Copy)]
pub struct PanelViewModelMapper {
    pub live_threshold_secs: i64,
}

impl Default for PanelViewModelMapper {
    fn default() -> Self {
        Self {
            live_threshold_secs: DEFAULT_LIVE_THRESHOLD_SECS,
        }
    }
}

impl PanelViewModelMapper {
    /// artifact -> 面板视图模型; `now` 由调用方注入保证可测。
    /// 订阅卡映射 (SubscriptionMapping 对齐) 在 T03 阶段补齐, 当前恒为 null。
    pub fn make(
        &self,
        agent_usage: Option<&AgentUsageArtifact>,
        now: DateTime<chrono::FixedOffset>,
    ) -> PanelViewModel {
        let mut diagnostics: Vec<PanelDiagnostic> = Vec::new();
        match agent_usage {
            Some(artifact) => {
                let usage = self.make_usage(artifact, now, &mut diagnostics);
                let hourly = self.make_hourly(artifact, &mut diagnostics);
                PanelViewModel {
                    usage: Some(usage),
                    subscription: None,
                    hourly: Some(hourly),
                    diagnostics,
                }
            }
            None => {
                diagnostics.push(PanelDiagnostic::MissingArtifact {
                    module: "agentUsage".to_owned(),
                });
                PanelViewModel {
                    usage: None,
                    subscription: None,
                    hourly: None,
                    diagnostics,
                }
            }
        }
    }

    // MARK: 用量卡

    pub fn make_usage(
        &self,
        artifact: &AgentUsageArtifact,
        now: DateTime<chrono::FixedOffset>,
        diagnostics: &mut Vec<PanelDiagnostic>,
    ) -> UsageHeroViewModel {
        if artifact.agents.is_empty() {
            diagnostics.push(PanelDiagnostic::EmptyUsageAgents);
        }
        for agent in &artifact.agents {
            if agent.status != "ok" {
                diagnostics.push(PanelDiagnostic::AgentIssue {
                    agent_id: agent.id.clone(),
                    status: agent.status.clone(),
                    note: normalized_note(&agent.note).unwrap_or_default(),
                });
            }
        }

        let mut totals = (0, 0, 0, 0, 0);
        for agent in &artifact.agents {
            totals.0 += agent.today.input as i64;
            totals.1 += agent.today.output as i64;
            totals.2 += agent.today.cache_read as i64;
            totals.3 += agent.today.cache_creation as i64;
            totals.4 += agent.today.total as i64;
        }

        // 14 日日期轴: 取各 agent daily 的日期并集升序, 保留最后 14 天。
        let mut date_set = BTreeSet::new();
        for agent in &artifact.agents {
            for day in &agent.daily {
                date_set.insert(day.date.clone());
            }
        }
        let dates: Vec<&String> = date_set.iter().rev().take(14).collect::<Vec<_>>();
        let dates: Vec<String> = dates.into_iter().rev().cloned().collect();
        let days: Vec<UsageChartDay> = dates
            .iter()
            .map(|date| {
                let mut segments: Vec<UsageChartSegment> = Vec::new();
                let mut total = 0;
                for agent in &artifact.agents {
                    let value = agent
                        .daily
                        .iter()
                        .find(|day| &day.date == date)
                        .map(|day| day.total as i64)
                        .unwrap_or(0);
                    total += value;
                    if value > 0 {
                        segments.push(UsageChartSegment::new(
                            &agent.id,
                            PanelAgentColor::resolve(&agent.id),
                            value,
                        ));
                    }
                }
                UsageChartDay::new((*date).clone(), total, segments)
            })
            .collect();

        // 图例: 14 日窗口内有量的 agent, 保持 artifact 顺序。
        let legend: Vec<UsageLegendItem> = artifact
            .agents
            .iter()
            .filter(|agent| agent.daily.iter().rev().take(14).any(|day| day.total > 0))
            .map(|agent| {
                UsageLegendItem::new(&agent.id, &agent.name, PanelAgentColor::resolve(&agent.id))
            })
            .collect();

        let is_live = parse_iso_date(&artifact.generated_at)
            .map(|generated_at| {
                let age = (now - generated_at).num_seconds();
                age >= LIVE_LOOKBACK_SECS && age <= self.live_threshold_secs
            })
            .unwrap_or(false);

        // 缓存命中率: 缓存读取 / (输入 + 缓存读取 + 缓存创建), 分母为 0 显示占位符。
        let cache_base = totals.0 + totals.2 + totals.3;
        let cache_hit_rate_text = if cache_base > 0 {
            format!("{:.0}%", totals.2 as f64 / cache_base as f64 * 100.0)
        } else {
            "—".to_owned()
        };

        let (monthly, half_year) = self.make_usage_monthly(artifact);
        // 收起态近 7 天: 14 日柱状数据末 7 天, 与热力图同一绝对阈值分档。
        let collapsed_week_levels: Vec<i64> = days
            .iter()
            .rev()
            .take(7)
            .rev()
            .map(|day| {
                if day.total < 1 {
                    0
                } else {
                    UsageTier::for_total(day.total).heatmap_level()
                }
            })
            .collect();
        UsageHeroViewModel {
            total_tokens: totals.4,
            total_tokens_text: token_count(totals.4),
            cost_text: artifact.total_cost_usd.map(cost_text),
            breakdown: vec![
                UsageBreakdownItem::counted("输入", totals.0),
                UsageBreakdownItem::counted("输出", totals.1),
                UsageBreakdownItem::counted("缓存读取", totals.2),
                UsageBreakdownItem::textual("缓存命中率", cache_hit_rate_text),
            ],
            days,
            legend,
            is_live,
            heatmap: make_usage_heatmap(artifact),
            monthly,
            half_year,
            models: make_usage_models(artifact),
            usage_tier: UsageTier::for_total(totals.4).name().to_owned(),
            collapsed_week_levels,
        }
    }

    // MARK: 按月统计

    /// 按日历月 (yyyy-MM) 聚合全量 daily, 保留最近 6 个月, 末位为当月;
    /// 半年总量为窗口全部 daily 之和, 月均按实际覆盖月数平均 (整除截断)。
    pub fn make_usage_monthly(
        &self,
        artifact: &AgentUsageArtifact,
    ) -> (Vec<UsageMonthlyTotal>, Option<UsageHalfYearSummary>) {
        let mut totals_by_month: BTreeMap<String, i64> = BTreeMap::new();
        let mut grand_total = 0;
        for agent in &artifact.agents {
            for day in &agent.daily {
                if day.date.len() < 7 {
                    continue;
                }
                let key = day.date[..7].to_owned();
                *totals_by_month.entry(key).or_insert(0) += day.total as i64;
                grand_total += day.total as i64;
            }
        }
        let keys: Vec<String> = totals_by_month
            .keys()
            .rev()
            .take(6)
            .rev()
            .cloned()
            .collect();
        let Some(current_key) = keys.last() else {
            return (Vec::new(), None);
        };
        let months = keys
            .iter()
            .map(|key| UsageMonthlyTotal {
                label: month_label(key),
                total_text: token_count(totals_by_month[key]),
                is_current: key == current_key,
                key: key.clone(),
            })
            .collect();
        let summary = UsageHalfYearSummary {
            total_text: token_count(grand_total),
            average_text: token_count(grand_total / keys.len() as i64),
        };
        (months, Some(summary))
    }
}

// MARK: 模型用量

/// 模型用量区块: 聚合各 agent 的自然月 × 模型数据为三档窗口 (本月/3 月/6 月)
/// 与可点击日历月 (最新在前); 行按所选周期用量降序, 进度条为周期内份额。
/// 旧版 artifact 无 modelMonths 时返回 None (区块隐藏)。
///
/// 注: 同数值并列时 Swift 端 sort 不保证稳定, 本实现以模型名升序破并列;
/// 对拍 fixture 避免构造并列值场景。
pub fn make_usage_models(artifact: &AgentUsageArtifact) -> Option<UsageModelUsageSection> {
    let mut by_month: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();
    for agent in &artifact.agents {
        for (month, models) in &agent.model_months {
            for (model, total) in models {
                *by_month
                    .entry(month.clone())
                    .or_default()
                    .entry(model.clone())
                    .or_insert(0) += *total as i64;
            }
        }
    }
    if by_month.is_empty() {
        return None;
    }

    let keys: Vec<String> = by_month.keys().cloned().collect();
    let current_key = keys.last().cloned().unwrap_or_default();
    let all_models: Vec<String> = {
        let set: BTreeSet<&String> = by_month.values().flat_map(|models| models.keys()).collect();
        set.into_iter().cloned().collect()
    };
    let mut color_by_model: BTreeMap<String, String> = BTreeMap::new();
    for (index, model) in all_models.iter().enumerate() {
        color_by_model.insert(
            model.clone(),
            MODEL_PALETTE[index % MODEL_PALETTE.len()].to_owned(),
        );
    }

    fn rows_for(
        month_keys: &[String],
        by_month: &BTreeMap<String, BTreeMap<String, i64>>,
        color_by_model: &BTreeMap<String, String>,
    ) -> Vec<UsageModelRow> {
        let mut totals: BTreeMap<String, i64> = BTreeMap::new();
        for key in month_keys {
            if let Some(models) = by_month.get(key) {
                for (model, total) in models {
                    *totals.entry(model.clone()).or_insert(0) += *total;
                }
            }
        }
        let grand: i64 = totals.values().sum();
        if grand <= 0 {
            return Vec::new();
        }
        let mut entries: Vec<(&String, i64)> = totals.iter().map(|(k, v)| (k, *v)).collect();
        entries.sort_by(|lhs, rhs| rhs.1.cmp(&lhs.1).then_with(|| lhs.0.cmp(rhs.0)));
        entries
            .into_iter()
            .map(|(model, total)| {
                let share = total as f64 / grand as f64;
                let pct = (share * 100.0).round() as i64;
                UsageModelRow {
                    name: model.clone(),
                    total_text: token_count(total),
                    pct_text: format!("{pct}%"),
                    share,
                    color_hex: color_by_model
                        .get(model)
                        .cloned()
                        .unwrap_or_else(|| "#8e8e93".to_owned()),
                }
            })
            .collect()
    }

    let tiers = vec![
        UsageModelPeriod {
            id: "m1".to_owned(),
            label: "本月".to_owned(),
            rows: rows_for(
                std::slice::from_ref(&current_key),
                &by_month,
                &color_by_model,
            ),
        },
        UsageModelPeriod {
            id: "m3".to_owned(),
            label: "3 月".to_owned(),
            rows: rows_for(
                &keys[keys.len().saturating_sub(3)..],
                &by_month,
                &color_by_model,
            ),
        },
        UsageModelPeriod {
            id: "m6".to_owned(),
            label: "6 月".to_owned(),
            rows: rows_for(&keys, &by_month, &color_by_model),
        },
    ];
    let months = keys
        .iter()
        .rev()
        .map(|key| UsageModelPeriod {
            id: key.clone(),
            label: month_label(key),
            rows: rows_for(std::slice::from_ref(key), &by_month, &color_by_model),
        })
        .collect();
    Some(UsageModelUsageSection {
        tiers,
        months,
        current_month_key: current_key,
    })
}

// MARK: 用量热力图

/// 全量 daily 窗口 (不做 14 日截断) 按周列 × 周日行 (周一起) 组织;
/// level 按当日绝对总量以 100M 步进分 0-5 档 (与 UsageTier 一致),
/// 窗口外与未来格为 None。日期为纯 "yyyy-MM-dd" 字符串, 周一网格起点
/// 与 Swift 端 firstWeekday=2 的周区间语义等价。
pub fn make_usage_heatmap(artifact: &AgentUsageArtifact) -> Vec<UsageHeatmapWeek> {
    let mut totals_by_date: BTreeMap<String, i64> = BTreeMap::new();
    for agent in &artifact.agents {
        for day in &agent.daily {
            *totals_by_date.entry(day.date.clone()).or_insert(0) += day.total as i64;
        }
    }
    let parse_date = |value: &str| NaiveDate::parse_from_str(value, "%Y-%m-%d").ok();
    let Some(first_date) = totals_by_date.keys().next().and_then(|key| parse_date(key)) else {
        return Vec::new();
    };
    let Some(last_date) = totals_by_date
        .keys()
        .next_back()
        .and_then(|key| parse_date(key))
    else {
        return Vec::new();
    };
    // 首日所在周的周一作为网格起点。
    let grid_start =
        first_date - Duration::days(first_date.weekday().num_days_from_monday() as i64);

    let mut weeks: Vec<UsageHeatmapWeek> = Vec::new();
    let mut week_start = grid_start;
    while week_start <= last_date {
        let mut cells: Vec<Option<UsageHeatmapCell>> = Vec::with_capacity(7);
        for offset in 0..7 {
            let date = week_start + Duration::days(offset);
            if date < first_date || date > last_date {
                cells.push(None);
                continue;
            }
            let key = date.format("%Y-%m-%d").to_string();
            let total = totals_by_date.get(&key).copied().unwrap_or(0);
            cells.push(Some(UsageHeatmapCell {
                date: key,
                total,
                level: heatmap_level(total),
            }));
        }
        weeks.push(UsageHeatmapWeek { cells });
        week_start += Duration::days(7);
    }
    weeks
}

/// 绝对阈值分档: 0 无量, 1-5 对应 UsageTier sage..forest (100M 步进)。
fn heatmap_level(total: i64) -> i64 {
    if total < 1 {
        0
    } else if total < 100_000_000 {
        1
    } else if total < 200_000_000 {
        2
    } else if total < 300_000_000 {
        3
    } else if total < 400_000_000 {
        4
    } else {
        5
    }
}

// MARK: 逐小时卡

impl PanelViewModelMapper {
    pub fn make_hourly(
        &self,
        artifact: &AgentUsageArtifact,
        diagnostics: &mut Vec<PanelDiagnostic>,
    ) -> HourlyLineViewModel {
        let _ = diagnostics;
        // 柱状图下方只显示今日有量的 agent; 其余 (含 ok 但今日闲置,
        // 或仅窗口内有历史量) 不显示, not_found 等状态由用量卡诊断覆盖。
        let mut rows: Vec<HourlyAgentRow> = artifact
            .agents
            .iter()
            .filter(|agent| agent.today.total > 0)
            .map(|agent| {
                let mut model_entries: Vec<(&String, i64)> = agent
                    .models
                    .iter()
                    .map(|(model, total)| (model, *total as i64))
                    .collect();
                // 按用量降序, 并列按模型名升序 (与 Swift 比较器一致)。
                model_entries.sort_by(|lhs, rhs| rhs.1.cmp(&lhs.1).then_with(|| lhs.0.cmp(rhs.0)));
                let models = top_distribution(
                    &model_entries
                        .into_iter()
                        .map(|(name, total)| (name.clone(), total))
                        .collect::<Vec<_>>(),
                    agent.today.total as i64,
                    3,
                );
                let project_entries: Vec<(String, i64)> = agent
                    .projects
                    .iter()
                    .map(|project| (project.name.clone(), project.total as i64))
                    .collect();
                let projects = top_distribution(&project_entries, agent.today.total as i64, 3);
                let today_total = agent.today.total as i64;
                HourlyAgentRow {
                    agent_id: agent.id.clone(),
                    name: hourly_display_name(&agent.id, &agent.name),
                    color: PanelAgentColor::resolve(&agent.id).name().to_owned(),
                    color_hex: PanelAgentColor::resolve(&agent.id).hex().to_owned(),
                    today_total,
                    today_total_text: token_count(today_total),
                    points: agent.hours.iter().map(|value| *value as i64).collect(),
                    is_expandable: !models.is_empty() || !projects.is_empty(),
                    models,
                    projects,
                }
            })
            // 按今日用量从高到低动态排序 (稳定排序: 并列保持 artifact 顺序)。
            .collect();
        rows.sort_by(|lhs, rhs| rhs.today_total.cmp(&lhs.today_total));

        let collapsed_points: Vec<i64> = (0..24)
            .map(|hour| {
                rows.iter()
                    .map(|row| row.points.get(hour).copied().unwrap_or(0))
                    .sum()
            })
            .collect();
        let collapsed_peak_text = format!(
            "峰值 {}",
            token_count(collapsed_points.iter().copied().max().unwrap_or(0))
        );
        HourlyLineViewModel {
            rows,
            collapsed_points,
            collapsed_peak_text,
        }
    }
}

/// 逐小时卡展示名: 仅显示层覆盖, 不动 artifact 契约名。
pub fn hourly_display_name(id: &str, fallback: &str) -> String {
    if id == "kimi-code-cli" {
        "Kimi Code".to_owned()
    } else {
        fallback.to_owned()
    }
}

/// Top N + 其他聚合; base 为分组总量 (份额分母)。
/// models 的 entries 覆盖全部模型, 其他 = Top N 之外的余量;
/// projects 的 entries 只有 Top 3, 其他 = 今日总量与已知的差值。
pub fn top_distribution(
    entries: &[(String, i64)],
    base: i64,
    limit: usize,
) -> Vec<DistributionBar> {
    if entries.is_empty() {
        return Vec::new();
    }
    let entries_total: i64 = entries.iter().map(|(_, total)| total).sum();
    let denominator = base.max(entries_total);
    if denominator <= 0 {
        return Vec::new();
    }
    let mut bars: Vec<DistributionBar> = entries
        .iter()
        .take(limit)
        .map(|(name, total)| DistributionBar {
            name: name.clone(),
            total: *total,
            total_text: token_count(*total),
            share: *total as f64 / denominator as f64,
        })
        .collect();
    let bars_total: i64 = bars.iter().map(|bar| bar.total).sum();
    let other_total = denominator - bars_total;
    if other_total > 0 {
        bars.push(DistributionBar {
            name: "其他".to_owned(),
            total: other_total,
            total_text: token_count(other_total),
            share: other_total as f64 / denominator as f64,
        });
    }
    bars
}

// MARK: 工具

fn normalized_note(note: &str) -> Option<String> {
    if note.is_empty() {
        None
    } else {
        Some(note.to_owned())
    }
}

fn parse_iso_date(value: &str) -> Option<DateTime<chrono::FixedOffset>> {
    DateTime::parse_from_rfc3339(value).ok()
}

/// "2026-07" -> "7月" (去掉年份与前导零, 跨年月份自然区分)。
fn month_label(key: &str) -> String {
    let month = &key[key.len() - 2..];
    let trimmed = month.strip_prefix('0').unwrap_or(month);
    format!("{trimmed}月")
}
