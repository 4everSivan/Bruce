#![deny(unsafe_code)]

//! Token, cost, day, model, and project aggregation.

use collector_domain::{
    AgentUsage, CollectionWindow, DailyUsage, ModelUsage, ProjectUsage, TokenBucket,
};
use std::collections::{BTreeMap, HashMap};

pub use collector_domain::{ModelDelta, ProjectDelta, UsageContribution, UsageSample};

pub const AGGREGATION_ROLE: &str = "artifact-aggregation";

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

    pub fn merge_delta(&mut self, delta: &UsageContribution) -> bool {
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

    pub fn finalize(self, agent_id: &str, agent_name: &str) -> AgentUsage {
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

        let mut today_models = Vec::with_capacity(ordered_models.len());
        for (_, model, bucket) in &ordered_models {
            today_models.push(ModelUsage {
                model: model.clone(),
                total: bucket.total,
                input: bucket.display_input(),
                output: bucket.output,
                cost_usd: None,
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
            today_cost_usd: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{UsageAccumulator, UsageSample};
    use collector_domain::CollectionWindow;
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
        let agent = aggregate.finalize("fixture", "Fixture");
        assert_eq!(agent.today.input, 10);
        assert_eq!(agent.today.cache_read, 2);
        assert_eq!(agent.today.total, 16);
        assert_eq!(agent.today_models[0].input, 13);
        assert_eq!(agent.projects[0].name, "Bruce");
        assert_eq!(agent.hours.iter().sum::<u64>(), 16);
        assert_eq!(agent.daily.len(), 3);
        assert!(agent.today_models[0].cost_usd.is_none());
        assert!(agent.today_cost_usd.is_none());
        let encoded = serde_json::to_value(&agent).unwrap();
        assert!(encoded["todayCostUsd"].is_null());
        assert!(encoded["todayModels"][0]["costUsd"].is_null());
    }
}
