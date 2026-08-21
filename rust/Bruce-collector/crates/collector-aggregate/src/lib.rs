#![deny(unsafe_code)]

//! Token, cost, day, model, and project aggregation.

use collector_domain::{
    AgentUsage, CollectionWindow, DailyUsage, ModelUsage, ProjectUsage, TokenBucket,
};
use std::collections::{BTreeMap, HashMap};

pub use collector_domain::{
    AggregateDelta, ModelDelta, ProjectDelta, UsageContribution, UsageSample,
};

pub const AGGREGATION_ROLE: &str = "artifact-aggregation";

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pricing {
    pub input_per_million: f64,
    pub output_per_million: f64,
    pub cache_read_per_million: f64,
    pub cache_creation_per_million: f64,
}

#[derive(Debug, Clone, Default)]
pub struct PricingTable {
    entries: Vec<(String, Pricing)>,
}

impl PricingTable {
    pub fn new(entries: impl IntoIterator<Item = (String, Pricing)>) -> Self {
        Self {
            entries: entries
                .into_iter()
                .map(|(model, pricing)| (model.to_ascii_lowercase(), pricing))
                .collect(),
        }
    }

    pub fn estimate_cost(&self, model: &str, bucket: &TokenBucket) -> Option<f64> {
        if model.is_empty() || self.entries.is_empty() {
            return None;
        }
        let normalized = model.to_ascii_lowercase();
        let key = normalized
            .split('[')
            .next()
            .unwrap_or_default()
            .rsplit('/')
            .next()
            .unwrap_or_default()
            .trim();
        let pricing = self
            .entries
            .iter()
            .find(|(id, _)| id == &normalized || id == key)
            .map(|(_, pricing)| *pricing)
            .or_else(|| {
                self.entries
                    .iter()
                    .find(|(id, _)| !key.is_empty() && (key.contains(id) || id.contains(key)))
                    .map(|(_, pricing)| *pricing)
            })?;
        let total = bucket.input as f64 * pricing.input_per_million
            + bucket.output as f64 * pricing.output_per_million
            + bucket.cache_read as f64 * pricing.cache_read_per_million
            + bucket.cache_creation as f64 * pricing.cache_creation_per_million;
        Some(total / 1_000_000.0)
    }
}

#[derive(Debug, Clone)]
pub struct UsageAccumulator {
    window: CollectionWindow,
    by_day: BTreeMap<String, TokenBucket>,
    models_today: HashMap<String, TokenBucket>,
    model_order: Vec<String>,
    projects_today: HashMap<String, u64>,
    project_order: Vec<String>,
    hours: [u64; 24],
}

impl UsageAccumulator {
    pub fn new(window: CollectionWindow) -> Self {
        Self {
            window,
            by_day: BTreeMap::new(),
            models_today: HashMap::new(),
            model_order: Vec::new(),
            projects_today: HashMap::new(),
            project_order: Vec::new(),
            hours: [0; 24],
        }
    }

    pub fn record(&mut self, sample: UsageSample<'_>) -> bool {
        let Some(day) = self.window.day_of_millis(sample.timestamp_millis) else {
            return false;
        };
        if !self.window.contains_day(&day) {
            return false;
        }
        self.by_day.entry(day.clone()).or_default().add(
            sample.input,
            sample.output,
            sample.cache_read,
            sample.cache_creation,
        );
        if day != self.window.today {
            return true;
        }

        let model = sample
            .model
            .filter(|value| !value.is_empty())
            .unwrap_or("unknown");
        if !self.models_today.contains_key(model) {
            self.model_order.push(model.to_owned());
        }
        self.models_today.entry(model.to_owned()).or_default().add(
            sample.input,
            sample.output,
            sample.cache_read,
            sample.cache_creation,
        );
        if let Some(hour) = self.window.hour_of_millis(sample.timestamp_millis) {
            self.hours[hour] = self.hours[hour].saturating_add(
                sample
                    .input
                    .saturating_add(sample.output)
                    .saturating_add(sample.cache_read)
                    .saturating_add(sample.cache_creation),
            );
        }
        if let Some(project) = sample.project.filter(|value| !value.is_empty()) {
            if !self.projects_today.contains_key(project) {
                self.project_order.push(project.to_owned());
            }
            let entry = self.projects_today.entry(project.to_owned()).or_default();
            *entry = entry.saturating_add(
                sample
                    .input
                    .saturating_add(sample.output)
                    .saturating_add(sample.cache_read)
                    .saturating_add(sample.cache_creation),
            );
        }
        true
    }

    pub fn delta(&self) -> AggregateDelta {
        AggregateDelta {
            by_day: self.by_day.clone(),
            models_today: self
                .model_order
                .iter()
                .filter_map(|model| {
                    self.models_today
                        .get(model)
                        .cloned()
                        .map(|bucket| ModelDelta {
                            model: model.clone(),
                            bucket,
                        })
                })
                .collect(),
            projects_today: self
                .project_order
                .iter()
                .filter_map(|name| {
                    self.projects_today
                        .get(name)
                        .copied()
                        .map(|total| ProjectDelta {
                            name: name.clone(),
                            total,
                        })
                })
                .collect(),
            hours: self.hours.to_vec(),
        }
    }

    pub fn merge_delta(&mut self, delta: &AggregateDelta) -> bool {
        if delta.hours.len() != self.hours.len() {
            return false;
        }
        for (day, bucket) in &delta.by_day {
            self.by_day.entry(day.clone()).or_default().merge(bucket);
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
        true
    }

    pub fn finalize(
        self,
        agent_id: &str,
        agent_name: &str,
        pricing: Option<&PricingTable>,
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

        let mut total_cost = 0.0;
        let mut cost_known = false;
        let mut today_models = Vec::with_capacity(ordered_models.len());
        for (_, model, bucket) in &ordered_models {
            let cost = pricing.and_then(|table| table.estimate_cost(model, bucket));
            if let Some(cost) = cost {
                total_cost += cost;
                cost_known = true;
            }
            today_models.push(ModelUsage {
                model: model.clone(),
                total: bucket.total,
                input: bucket.display_input(),
                output: bucket.output,
                cost_usd: cost.map(round_four),
            });
        }
        today_models.truncate(5);
        let models = today_models
            .iter()
            .map(|model| (model.model.clone(), model.total))
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

        AgentUsage {
            id: agent_id.to_owned(),
            name: agent_name.to_owned(),
            status: "ok".to_owned(),
            note: String::new(),
            quota: None,
            today,
            daily,
            models,
            today_models,
            projects,
            hours: self.hours.to_vec(),
            today_cost_usd: cost_known.then(|| round_four(total_cost)),
        }
    }
}

fn round_four(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

#[cfg(test)]
mod tests {
    use super::{Pricing, PricingTable, UsageAccumulator, UsageSample};
    use collector_domain::{CollectionWindow, TokenBucket};
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
        let mut aggregate = UsageAccumulator::new(window());
        assert!(aggregate.record(UsageSample {
            timestamp_millis: 1_785_211_200_000,
            model: Some("provider/model[fast]"),
            input: 10,
            output: 3,
            cache_read: 2,
            cache_creation: 1,
            project: Some("Bruce"),
        }));
        let agent = aggregate.finalize("fixture", "Fixture", None);
        assert_eq!(agent.today.input, 10);
        assert_eq!(agent.today.cache_read, 2);
        assert_eq!(agent.today.total, 16);
        assert_eq!(agent.today_models[0].input, 13);
        assert_eq!(agent.projects[0].name, "Bruce");
        assert_eq!(agent.hours.iter().sum::<u64>(), 16);
        assert_eq!(agent.daily.len(), 3);
    }

    #[test]
    fn cost_matching_uses_normalized_model_and_rounds_outputs() {
        let pricing = PricingTable::new([(
            "gpt-5".to_owned(),
            Pricing {
                input_per_million: 1.25,
                output_per_million: 10.0,
                cache_read_per_million: 0.125,
                cache_creation_per_million: 0.0,
            },
        )]);
        let bucket = TokenBucket {
            input: 1000,
            output: 2000,
            cache_read: 100,
            cache_creation: 0,
            total: 3100,
        };
        assert_eq!(
            pricing.estimate_cost("openai/gpt-5[high]", &bucket),
            Some(0.021_262_5)
        );
    }
}
