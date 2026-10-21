#![deny(unsafe_code)]

//! Token, cost, day, model, and project aggregation.

use collector_domain::{
    AgentUsage, CollectionWindow, DailyModelUsage, DailyUsage, HourModelUsage, ModelUsage,
    MonthModelUsage, PricingTable, ProjectUsage, TokenBucket,
};
use std::collections::{BTreeMap, HashMap};

pub use collector_domain::{ModelDelta, ProjectDelta, UsageContribution, UsageSample};

#[derive(Debug, Clone)]
pub struct UsageAccumulator {
    window: CollectionWindow,
    by_day: BTreeMap<String, TokenBucket>,
    models_by_month: BTreeMap<String, BTreeMap<String, TokenBucket>>,
    models_today: HashMap<String, TokenBucket>,
    model_order: Vec<String>,
    projects_today: HashMap<String, u64>,
    project_order: Vec<String>,
    hours: [u64; 24],
    models_by_day: BTreeMap<String, BTreeMap<String, TokenBucket>>,
    hour_models_today: BTreeMap<u8, BTreeMap<String, TokenBucket>>,
}

/// 一个 token 桶的采集端计价 (C070): 无匹配单价时两者均为 None, 工作台计为未定价。
fn price_bucket(
    pricing: &PricingTable,
    model: &str,
    bucket: &TokenBucket,
) -> (Option<f64>, Option<f64>) {
    match pricing.resolve(model) {
        Some(rule) => (
            Some(pricing.calculate_cost(bucket, &rule)),
            Some(pricing.calculate_cache_savings(bucket, &rule)),
        ),
        None => (None, None),
    }
}

impl UsageAccumulator {
    pub fn new(window: CollectionWindow) -> Self {
        Self {
            window,
            by_day: BTreeMap::new(),
            models_by_month: BTreeMap::new(),
            models_today: HashMap::new(),
            model_order: Vec::new(),
            projects_today: HashMap::new(),
            project_order: Vec::new(),
            hours: [0; 24],
            models_by_day: BTreeMap::new(),
            hour_models_today: BTreeMap::new(),
        }
    }

    pub fn merge_delta(&mut self, delta: &UsageContribution) -> bool {
        if delta.hours.len() != self.hours.len() {
            return false;
        }
        for (day, bucket) in &delta.by_day {
            self.by_day.entry(day.clone()).or_default().merge(bucket);
        }
        for (month, models) in &delta.models_by_month {
            let month_entry = self.models_by_month.entry(month.clone()).or_default();
            for (model, bucket) in models {
                month_entry.entry(model.clone()).or_default().merge(bucket);
            }
        }
        for model in &delta.models_today {
            if !self.models_today.contains_key(&model.model) {
                self.model_order.push(model.model.clone());
            }
            self.models_today
                .entry(model.model.clone())
                .or_default()
                .merge(&model.bucket);
        }
        for project in &delta.projects_today {
            if !self.projects_today.contains_key(&project.name) {
                self.project_order.push(project.name.clone());
            }
            let entry = self.projects_today.entry(project.name.clone()).or_default();
            *entry = entry.saturating_add(project.total);
        }
        for (index, value) in delta.hours.iter().enumerate() {
            self.hours[index] = self.hours[index].saturating_add(*value);
        }
        for (day, models) in &delta.models_by_day {
            let day_entry = self.models_by_day.entry(day.clone()).or_default();
            for (model, bucket) in models {
                day_entry.entry(model.clone()).or_default().merge(bucket);
            }
        }
        for (hour, models) in &delta.hour_models_today {
            let hour_entry = self.hour_models_today.entry(*hour).or_default();
            for (model, bucket) in models {
                hour_entry.entry(model.clone()).or_default().merge(bucket);
            }
        }
        true
    }

    pub fn finalize(self, agent_id: &str, agent_name: &str) -> AgentUsage {
        self.finalize_with_pricing(agent_id, agent_name, &PricingTable::default())
    }

    pub fn finalize_with_pricing(
        self,
        agent_id: &str,
        agent_name: &str,
        pricing: &PricingTable,
    ) -> AgentUsage {
        let empty = TokenBucket::default();
        let daily = self
            .window
            .day_list
            .iter()
            .map(|date| {
                let bucket = self.by_day.get(date).unwrap_or(&empty);
                DailyUsage {
                    date: date.clone(),
                    input: bucket.display_input(),
                    output: bucket.output,
                    total: bucket.total,
                    cache_read: bucket.cache_read,
                    cache_creation: bucket.cache_creation,
                }
            })
            .collect();
        let today = self
            .by_day
            .get(&self.window.today)
            .cloned()
            .unwrap_or_default();

        let mut ordered_models: Vec<(usize, String, TokenBucket)> = self
            .model_order
            .iter()
            .enumerate()
            .filter_map(|(position, model)| {
                self.models_today
                    .get(model)
                    .cloned()
                    .map(|bucket| (position, model.clone(), bucket))
            })
            .filter(|(_, model, bucket)| model != "<synthetic>" && bucket.total > 0)
            .collect();
        ordered_models.sort_by(|left, right| {
            right
                .2
                .total
                .cmp(&left.2.total)
                .then_with(|| left.0.cmp(&right.0))
        });

        let mut today_models = Vec::with_capacity(ordered_models.len());
        for (_, model, bucket) in &ordered_models {
            let cost_usd = pricing
                .resolve(model)
                .map(|rule| pricing.calculate_cost(bucket, &rule));
            today_models.push(ModelUsage {
                model: model.clone(),
                total: bucket.total,
                input: bucket.display_input(),
                output: bucket.output,
                cost_usd,
            });
        }
        today_models.truncate(5);
        let models = today_models
            .iter()
            .map(|model| (model.model.clone(), model.total))
            .collect();

        let mut total_today_cost = 0.0;
        let mut has_cost = false;
        for (model, bucket) in &self.models_today {
            if let Some(rule) = pricing.resolve(model) {
                total_today_cost += pricing.calculate_cost(bucket, &rule);
                has_cost = true;
            }
        }
        let today_cost_usd = if has_cost && total_today_cost > 0.0 {
            Some(total_today_cost)
        } else {
            None
        };

        let model_months: BTreeMap<String, BTreeMap<String, u64>> = self
            .models_by_month
            .iter()
            .map(|(month, models)| {
                (
                    month.clone(),
                    models
                        .iter()
                        .map(|(model, bucket)| (model.clone(), bucket.total))
                        .collect(),
                )
            })
            .collect();

        let mut projects: Vec<(usize, String, u64)> = self
            .project_order
            .iter()
            .enumerate()
            .filter_map(|(position, project)| {
                self.projects_today
                    .get(project)
                    .copied()
                    .map(|total| (position, project.clone(), total))
            })
            .collect();
        projects.sort_by(|left, right| right.2.cmp(&left.2).then_with(|| left.0.cmp(&right.0)));
        let projects = projects
            .into_iter()
            .take(3)
            .map(|(_, name, total)| ProjectUsage { name, total })
            .collect();

        // C070 工作台明细: 非零桶全部输出 (不过滤任何模型), 任一范围内模型桶合计 = token 合计。
        // 只保留窗口内且属于最近 DETAIL_DAYS 天的日期 (增量缓存可能残留更早日期)。
        let detail_floor = self
            .window
            .day_list
            .len()
            .saturating_sub(collector_domain::DETAIL_DAYS);
        let detail_days: std::collections::BTreeSet<&String> =
            self.window.day_list[detail_floor..].iter().collect();
        let daily_models = self
            .models_by_day
            .iter()
            .filter(|(day, _)| detail_days.contains(day))
            .flat_map(|(day, models)| {
                models
                    .iter()
                    .filter(|(_, bucket)| bucket.total > 0)
                    .map(move |(model, bucket)| (day, model, bucket))
            })
            .map(|(day, model, bucket)| {
                let (cost_usd, cache_savings_usd) = price_bucket(pricing, model, bucket);
                DailyModelUsage {
                    date: day.clone(),
                    model: model.clone(),
                    tokens: bucket.clone(),
                    cost_usd,
                    cache_savings_usd,
                }
            })
            .collect();
        let month_models = self
            .models_by_month
            .iter()
            .flat_map(|(month, models)| {
                models
                    .iter()
                    .filter(|(_, bucket)| bucket.total > 0)
                    .map(move |(model, bucket)| (month, model, bucket))
            })
            .map(|(month, model, bucket)| {
                let (cost_usd, cache_savings_usd) = price_bucket(pricing, model, bucket);
                MonthModelUsage {
                    month: month.clone(),
                    model: model.clone(),
                    tokens: bucket.clone(),
                    cost_usd,
                    cache_savings_usd,
                }
            })
            .collect();
        let hour_models = self
            .hour_models_today
            .iter()
            .flat_map(|(hour, models)| {
                models
                    .iter()
                    .filter(|(_, bucket)| bucket.total > 0)
                    .map(move |(model, bucket)| (*hour, model, bucket))
            })
            .map(|(hour, model, bucket)| {
                let (cost_usd, cache_savings_usd) = price_bucket(pricing, model, bucket);
                HourModelUsage {
                    hour,
                    model: model.clone(),
                    tokens: bucket.clone(),
                    cost_usd,
                    cache_savings_usd,
                }
            })
            .collect();

        AgentUsage {
            id: agent_id.to_owned(),
            name: agent_name.to_owned(),
            status: "ok".to_owned(),
            note: String::new(),
            quota: None,
            today,
            daily,
            models,
            model_months,
            today_models,
            projects,
            hours: self.hours.to_vec(),
            today_cost_usd,
            daily_models,
            month_models,
            hour_models,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{UsageAccumulator, UsageSample};
    use collector_domain::{CollectionWindow, UsageContributionBuilder};
    use serde_json::json;

    fn window() -> CollectionWindow {
        let context = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        CollectionWindow::from_context(&context).unwrap()
    }

    #[test]
    fn window_boundaries_and_cache_input_match_shared_contract() {
        let mut builder = UsageContributionBuilder::new(window());
        assert!(builder.record(UsageSample {
            timestamp_millis: 1_785_211_200_000,
            model: Some("provider/model[fast]"),
            input: 10,
            output: 3,
            cache_read: 2,
            cache_creation: 1,
            project: Some("Bruce"),
        }));
        let contribution = builder.contribution();
        let mut aggregate = UsageAccumulator::new(window());
        assert!(aggregate.merge_delta(&contribution));
        let agent = aggregate.finalize("fixture", "Fixture");
        assert_eq!(agent.today.input, 10);
        assert_eq!(agent.today.cache_read, 2);
        assert_eq!(agent.today.total, 16);
        assert_eq!(agent.today_models[0].input, 13);
        assert_eq!(agent.projects[0].name, "Bruce");
        assert_eq!(agent.hours.iter().sum::<u64>(), 16);
        assert_eq!(agent.daily.len(), 3);
        // 自然月 × 模型聚合: 3 天窗口全部落在 2026-07, 样本模型全量归档
        assert_eq!(agent.model_months.len(), 1);
        let july = &agent.model_months["2026-07"];
        assert_eq!(july["provider/model[fast]"], 16);
        assert!(agent.today_models[0].cost_usd.is_none());
        assert!(agent.today_cost_usd.is_none());
        let encoded = serde_json::to_value(&agent).unwrap();
        assert!(encoded["todayCostUsd"].is_null());
        assert!(encoded["todayModels"][0]["costUsd"].is_null());
        assert_eq!(
            encoded["modelMonths"]["2026-07"]["provider/model[fast]"],
            16
        );
    }

    #[test]
    fn pricing_calculates_positive_costs_for_builtin_and_overrides() {
        let mut builder = UsageContributionBuilder::new(window());
        assert!(builder.record(UsageSample {
            timestamp_millis: 1_785_211_200_000,
            model: Some("k3-agent"),
            input: 1_000_000,
            output: 100_000,
            cache_read: 500_000,
            cache_creation: 0,
            project: Some("Bruce"),
        }));
        let contribution = builder.contribution();
        let mut aggregate = UsageAccumulator::new(window());
        assert!(aggregate.merge_delta(&contribution));
        let agent = aggregate.finalize("fixture", "Fixture");
        assert!(agent.today_cost_usd.is_some());
        let cost = agent.today_cost_usd.unwrap();
        assert!((cost - 4.65).abs() < 1e-4);
        assert_eq!(agent.today_models[0].cost_usd, Some(cost));
    }

    /// C070: 工作台明细桶 —— 最近 31 天 日期×模型、全部月份 月×模型、今日 小时×模型,
    /// 均为原始 token 口径并带采集端计价; 逐日补充原始缓存拆分。
    #[test]
    fn workbench_detail_buckets_are_real_bounded_and_priced() {
        const NOW: i64 = 1_785_211_200_000; // 2026-07-28T12:00:00+08:00
        const DAY: i64 = 86_400_000;
        let window = {
            let context = serde_json::from_value(json!({
                "now": "2026-07-28T12:00:00+08:00", "timezone": "Asia/Shanghai", "days": 40
            }))
            .unwrap();
            CollectionWindow::from_context(&context).unwrap()
        };
        let mut builder = UsageContributionBuilder::new(window.clone());
        let sample = |at: i64, model: &'static str, input: u64, cache_read: u64| UsageSample {
            timestamp_millis: at,
            model: Some(model),
            input,
            output: 100,
            cache_read,
            cache_creation: 10,
            project: None,
        };
        // 39 天前 (超出 31 天明细期, 只进月桶), 20 天前, 今日 10:00 与 12:00 两个模型
        for record in [
            sample(NOW - 39 * DAY, "k3-agent", 1_000, 0),
            sample(NOW - 20 * DAY, "k3-agent", 2_000, 500),
            sample(NOW - 2 * 3_600_000, "k3-agent", 3_000, 1_000),
            sample(NOW, "mystery-model", 4_000, 0),
        ] {
            assert!(builder.record(record));
        }
        let mut aggregate = UsageAccumulator::new(window);
        assert!(aggregate.merge_delta(&builder.contribution()));
        let agent = aggregate.finalize("fixture", "Fixture");

        // 逐日原始缓存拆分; input 仍为含缓存的展示口径
        let today = agent.daily.last().unwrap();
        assert_eq!(today.cache_read, 1_000);
        assert_eq!(today.cache_creation, 20);
        assert_eq!(today.input, 3_000 + 4_000 + 1_000 + 20);

        // 日期×模型: 39 天前的样本不在明细期内; 每天模型桶之和 = 当日合计
        let dates: std::collections::BTreeSet<&str> =
            agent.daily_models.iter().map(|d| d.date.as_str()).collect();
        assert_eq!(dates.len(), 2, "只含 20 天前与今日");
        for day in &agent.daily {
            let sum: u64 = agent
                .daily_models
                .iter()
                .filter(|d| d.date == day.date)
                .map(|d| d.tokens.total)
                .sum();
            if dates.contains(day.date.as_str()) {
                assert_eq!(sum, day.total, "{}", day.date);
            }
        }
        // 月×模型覆盖全部月份 (6 月与 7 月)
        let months: std::collections::BTreeSet<&str> = agent
            .month_models
            .iter()
            .map(|m| m.month.as_str())
            .collect();
        assert_eq!(months, ["2026-06", "2026-07"].into_iter().collect());
        let month_total: u64 = agent.month_models.iter().map(|m| m.tokens.total).sum();
        let daily_total: u64 = agent.daily.iter().map(|d| d.total).sum();
        assert_eq!(month_total, daily_total);

        // 今日 小时×模型: 10 点 k3-agent, 12 点 mystery-model; 与 hours 合计一致
        let hours: Vec<(u8, &str)> = agent
            .hour_models
            .iter()
            .map(|h| (h.hour, h.model.as_str()))
            .collect();
        assert_eq!(hours, vec![(10, "k3-agent"), (12, "mystery-model")]);
        let hour_sum: u64 = agent.hour_models.iter().map(|h| h.tokens.total).sum();
        assert_eq!(hour_sum, agent.hours.iter().sum::<u64>());

        // 计价: 内置单价命中则有费用与缓存收益; 未知模型两者为 null (工作台计为未定价)
        let priced = agent
            .daily_models
            .iter()
            .find(|d| d.model == "k3-agent" && d.tokens.cache_read == 1_000)
            .unwrap();
        // k3-agent: 输入 3.00 / 输出 15.00 / 缓存读 0.30 (USD/1M); 缓存写入按输入计价
        let expected = (3_000.0 * 3.0 + 100.0 * 15.0 + 1_000.0 * 0.30 + 10.0 * 3.0) / 1_000_000.0;
        assert!((priced.cost_usd.unwrap() - expected).abs() < 1e-12);
        assert!((priced.cache_savings_usd.unwrap() - 1_000.0 * 2.70 / 1_000_000.0).abs() < 1e-12);
        let unpriced = agent
            .hour_models
            .iter()
            .find(|h| h.model == "mystery-model")
            .unwrap();
        assert!(unpriced.cost_usd.is_none() && unpriced.cache_savings_usd.is_none());

        // 序列化字段名 (artifact 契约)
        let encoded = serde_json::to_value(&agent).unwrap();
        assert!(encoded["dailyModels"][0]["cacheRead"].is_u64());
        assert!(encoded["monthModels"][0]["month"].is_string());
        assert!(encoded["hourModels"][0]["hour"].is_u64());
        assert!(encoded["daily"][0]["cacheCreation"].is_u64());
    }
}
