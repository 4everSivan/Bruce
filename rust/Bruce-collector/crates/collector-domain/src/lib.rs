#![deny(unsafe_code)]

//! Stable domain types shared by the Rust Collector crates.

use chrono::{DateTime, FixedOffset, SecondsFormat, TimeZone, Timelike, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::str::FromStr;

pub const BRIDGE_SCHEMA_VERSION: u8 = 1;
pub const AGENT_USAGE_SCHEMA_VERSION: u8 = 1;
pub const AGENT_USAGE_MODULE: &str = "agent-usage";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BridgeRequest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u8,
    #[serde(rename = "runId")]
    pub run_id: String,
    pub module: String,
    pub timeouts: BridgeTimeouts,
    pub context: Map<String, Value>,
    pub credentials: Map<String, Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BridgeTimeouts {
    #[serde(rename = "localScanSeconds")]
    pub local_scan_seconds: f64,
    #[serde(rename = "externalRequestSeconds")]
    pub external_request_seconds: f64,
    #[serde(rename = "moduleSeconds")]
    pub module_seconds: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Diagnostic {
    pub code: String,
    pub category: String,
    pub stage: String,
    pub message: String,
    pub retryable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct BridgeResponse {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u8,
    #[serde(rename = "runId")]
    pub run_id: String,
    #[serde(rename = "generatedAt")]
    pub generated_at: String,
    pub status: ResponseStatus,
    pub artifact: Option<Value>,
    #[serde(rename = "credentialUpdates")]
    pub credential_updates: Vec<Value>,
    #[serde(rename = "credentialChallenges")]
    pub credential_challenges: Vec<Value>,
    pub diagnostics: Vec<Diagnostic>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ResponseStatus {
    Success,
    Partial,
    Error,
}

/// The explicit date/time window used by every local source in one refresh.
///
/// `chrono-tz` keeps the boundary calculation in the requested IANA timezone
/// instead of converting timestamps to the machine timezone in each adapter.
#[derive(Debug, Clone, PartialEq)]
pub struct CollectionWindow {
    pub timezone_name: String,
    pub timezone: Tz,
    pub now: DateTime<FixedOffset>,
    pub today: String,
    pub day_list: Vec<String>,
    pub cutoff_ts: f64,
    pub days: u32,
    day_start_millis: Vec<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowError {
    InvalidTimezone(String),
    InvalidNow(String),
    InvalidDays,
}

impl fmt::Display for WindowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidTimezone(value) => write!(f, "invalid timezone: {value}"),
            Self::InvalidNow(value) => write!(f, "invalid now: {value}"),
            Self::InvalidDays => write!(f, "days must be between 1 and 366"),
        }
    }
}

impl std::error::Error for WindowError {}

impl CollectionWindow {
    pub fn from_context(context: &Map<String, Value>) -> Result<Self, WindowError> {
        let timezone_name = context
            .get("timezone")
            .and_then(Value::as_str)
            .unwrap_or("UTC")
            .to_owned();
        let timezone = Tz::from_str(&timezone_name)
            .map_err(|_| WindowError::InvalidTimezone(timezone_name.clone()))?;
        let days = context.get("days").and_then(Value::as_u64).unwrap_or(14);
        if !(1..=366).contains(&days) {
            return Err(WindowError::InvalidDays);
        }
        let now = match context.get("now").and_then(Value::as_str) {
            Some(value) => parse_now(value, timezone)?,
            None => Utc::now().fixed_offset(),
        };
        let local_now = now.with_timezone(&timezone);
        let today = local_now.format("%Y-%m-%d").to_string();
        let today_date = local_now.date_naive();
        let mut day_list = Vec::with_capacity(days as usize);
        for offset in (0..days).rev() {
            let date = today_date
                .checked_sub_signed(chrono::Duration::days(offset as i64))
                .expect("date range is bounded");
            day_list.push(date.format("%Y-%m-%d").to_string());
        }
        let oldest_date = today_date
            .checked_sub_signed(chrono::Duration::days(days as i64 - 1))
            .expect("date range is bounded");
        let mut day_start_millis = Vec::with_capacity(day_list.len() + 1);
        for index in 0..=days {
            let date = oldest_date
                .checked_add_signed(chrono::Duration::days(index as i64))
                .expect("date range is bounded");
            let local_midnight = date.and_hms_opt(0, 0, 0).expect("midnight is valid");
            let boundary = timezone
                .from_local_datetime(&local_midnight)
                .earliest()
                .or_else(|| timezone.from_local_datetime(&local_midnight).latest())
                .expect("timezone has a day boundary")
                .timestamp_millis();
            day_start_millis.push(boundary);
        }
        Ok(Self {
            timezone_name,
            timezone,
            now,
            today,
            day_list,
            cutoff_ts: now.timestamp() as f64 - (days as f64 + 1.0) * 86_400.0,
            days: days as u32,
            day_start_millis,
        })
    }

    pub fn day_index_of_millis(&self, timestamp_millis: i64) -> Option<usize> {
        self.day_start_millis
            .partition_point(|boundary| *boundary <= timestamp_millis)
            .checked_sub(1)
            .filter(|index| *index < self.day_list.len())
    }

    pub fn day_of_millis(&self, timestamp_millis: i64) -> Option<String> {
        self.day_index_of_millis(timestamp_millis)
            .and_then(|index| self.day_list.get(index).cloned())
    }

    pub fn hour_of_millis(&self, timestamp_millis: i64) -> Option<usize> {
        let value = Utc.timestamp_millis_opt(timestamp_millis).single()?;
        Some(value.with_timezone(&self.timezone).hour() as usize)
    }

    pub fn epoch_from_iso(&self, value: &str) -> Option<i64> {
        parse_timestamp(value, self.timezone).map(|timestamp| timestamp.timestamp())
    }

    pub fn generated_at(&self) -> String {
        self.now
            .with_timezone(&self.timezone)
            .to_rfc3339_opts(SecondsFormat::Secs, true)
    }

    pub fn contains_day(&self, day: &str) -> bool {
        self.day_list
            .first()
            .map(|first| day >= first)
            .unwrap_or(false)
            && day <= self.today.as_str()
    }
}

fn parse_now(value: &str, timezone: Tz) -> Result<DateTime<FixedOffset>, WindowError> {
    parse_timestamp(value, timezone)
        .map(|value| value.fixed_offset())
        .ok_or_else(|| WindowError::InvalidNow(value.to_owned()))
}

fn parse_timestamp(value: &str, timezone: Tz) -> Option<DateTime<Utc>> {
    if let Ok(parsed) = DateTime::parse_from_rfc3339(value) {
        return Some(parsed.with_timezone(&Utc));
    }
    let naive = chrono::NaiveDateTime::parse_from_str(value, "%Y-%m-%dT%H:%M:%S%.f").ok()?;
    timezone
        .from_local_datetime(&naive)
        .earliest()
        .map(|value| value.with_timezone(&Utc))
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct TokenBucket {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub total: u64,
}

impl TokenBucket {
    pub fn add(&mut self, input: u64, output: u64, cache_read: u64, cache_creation: u64) {
        self.input = self.input.saturating_add(input);
        self.output = self.output.saturating_add(output);
        self.cache_read = self.cache_read.saturating_add(cache_read);
        self.cache_creation = self.cache_creation.saturating_add(cache_creation);
        self.total = self.total.saturating_add(
            input
                .saturating_add(output)
                .saturating_add(cache_read)
                .saturating_add(cache_creation),
        );
    }

    pub fn display_input(&self) -> u64 {
        self.input
            .saturating_add(self.cache_read)
            .saturating_add(self.cache_creation)
    }

    pub fn merge(&mut self, other: &Self) {
        self.input = self.input.saturating_add(other.input);
        self.output = self.output.saturating_add(other.output);
        self.cache_read = self.cache_read.saturating_add(other.cache_read);
        self.cache_creation = self.cache_creation.saturating_add(other.cache_creation);
        self.total = self.total.saturating_add(other.total);
    }
}

/// A source-local usage sample that can be folded without touching the
/// filesystem, SQLite, network, or credential layers.
#[derive(Debug, Clone, Copy)]
pub struct UsageSample<'a> {
    pub timestamp_millis: i64,
    pub model: Option<&'a str>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub project: Option<&'a str>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelDelta {
    pub model: String,
    pub bucket: TokenBucket,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectDelta {
    pub name: String,
    pub total: u64,
}

/// Derived, source-local aggregate persisted by the incremental cache. It
/// contains no raw lines, message text, credentials, or provider responses.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageContribution {
    pub by_day: BTreeMap<String, TokenBucket>,
    pub models_today: Vec<ModelDelta>,
    pub projects_today: Vec<ProjectDelta>,
    pub hours: Vec<u64>,
}

/// Compatibility name for existing aggregate callers while the cache moves
/// to the domain-owned contribution contract.
pub type AggregateDelta = UsageContribution;

/// A bounded source-level replacement. It allows local adapters to describe
/// append, rewrite, and delete without exposing raw records to aggregation.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SourceDeltaChange {
    pub source_id: String,
    pub removed: Option<UsageContribution>,
    pub added: Option<UsageContribution>,
}

impl SourceDeltaChange {
    pub fn replace(
        source_id: impl Into<String>,
        removed: Option<UsageContribution>,
        added: Option<UsageContribution>,
    ) -> Self {
        Self {
            source_id: source_id.into(),
            removed,
            added,
        }
    }
}

/// Pure contribution builder used by local source adapters. The aggregate
/// crate remains responsible for final artifact shaping and pricing.
#[derive(Debug, Clone)]
pub struct UsageContributionBuilder {
    window: CollectionWindow,
    by_day: HashMap<usize, TokenBucket>,
    models_today: HashMap<String, TokenBucket>,
    model_order: Vec<String>,
    projects_today: HashMap<String, u64>,
    project_order: Vec<String>,
    hours: [u64; 24],
}

impl UsageContributionBuilder {
    pub fn new(window: CollectionWindow) -> Self {
        Self {
            window,
            by_day: HashMap::new(),
            models_today: HashMap::new(),
            model_order: Vec::new(),
            projects_today: HashMap::new(),
            project_order: Vec::new(),
            hours: [0; 24],
        }
    }

    pub fn from_contribution(
        window: CollectionWindow,
        contribution: &UsageContribution,
    ) -> Option<Self> {
        let mut builder = Self::new(window);
        builder.merge_contribution(contribution).then_some(builder)
    }

    pub fn record(&mut self, sample: UsageSample<'_>) -> bool {
        let Some(day_index) = self.window.day_index_of_millis(sample.timestamp_millis) else {
            return false;
        };
        self.by_day.entry(day_index).or_default().add(
            sample.input,
            sample.output,
            sample.cache_read,
            sample.cache_creation,
        );
        if day_index + 1 != self.window.day_list.len() {
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

    pub fn merge_contribution(&mut self, contribution: &UsageContribution) -> bool {
        if contribution.hours.len() != self.hours.len() {
            return false;
        }
        let day_indexes = contribution
            .by_day
            .keys()
            .map(|day| {
                self.window
                    .day_list
                    .iter()
                    .position(|candidate| candidate == day)
            })
            .collect::<Option<Vec<_>>>();
        let Some(day_indexes) = day_indexes else {
            return false;
        };
        for ((_, bucket), day_index) in contribution.by_day.iter().zip(day_indexes) {
            self.by_day.entry(day_index).or_default().merge(bucket);
        }
        for model in &contribution.models_today {
            if !self.models_today.contains_key(&model.model) {
                self.model_order.push(model.model.clone());
            }
            self.models_today
                .entry(model.model.clone())
                .or_default()
                .merge(&model.bucket);
        }
        for project in &contribution.projects_today {
            if !self.projects_today.contains_key(&project.name) {
                self.project_order.push(project.name.clone());
            }
            let entry = self.projects_today.entry(project.name.clone()).or_default();
            *entry = entry.saturating_add(project.total);
        }
        for (index, value) in contribution.hours.iter().enumerate() {
            self.hours[index] = self.hours[index].saturating_add(*value);
        }
        true
    }

    pub fn contribution(&self) -> UsageContribution {
        UsageContribution {
            by_day: self
                .by_day
                .iter()
                .filter_map(|(day_index, bucket)| {
                    self.window
                        .day_list
                        .get(*day_index)
                        .cloned()
                        .map(|day| (day, bucket.clone()))
                })
                .collect::<BTreeMap<_, _>>(),
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
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DailyUsage {
    pub date: String,
    pub input: u64,
    pub output: u64,
    pub total: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelUsage {
    pub model: String,
    pub total: u64,
    pub input: u64,
    pub output: u64,
    pub cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectUsage {
    pub name: String,
    pub total: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsage {
    pub id: String,
    pub name: String,
    pub status: String,
    pub note: String,
    pub quota: Option<Value>,
    pub today: TokenBucket,
    pub daily: Vec<DailyUsage>,
    pub models: std::collections::BTreeMap<String, u64>,
    pub today_models: Vec<ModelUsage>,
    pub projects: Vec<ProjectUsage>,
    pub hours: Vec<u64>,
    pub today_cost_usd: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsageArtifact {
    pub schema_version: u8,
    pub module: String,
    pub generated_at: String,
    pub agents: Vec<AgentUsage>,
    pub services: Vec<Value>,
    pub total_cost_usd: Option<f64>,
}

pub fn response_status(has_artifact: bool, diagnostic_count: usize) -> ResponseStatus {
    if !has_artifact {
        ResponseStatus::Error
    } else if diagnostic_count > 0 {
        ResponseStatus::Partial
    } else {
        ResponseStatus::Success
    }
}

pub fn retain_previous_artifact(current: Option<Value>, previous: Option<Value>) -> Option<Value> {
    current.or(previous)
}

impl Diagnostic {
    pub fn new(
        code: impl Into<String>,
        category: impl Into<String>,
        stage: impl Into<String>,
        message: impl Into<String>,
        retryable: bool,
    ) -> Self {
        Self {
            code: code.into(),
            category: category.into(),
            stage: stage.into(),
            message: message.into(),
            retryable,
        }
    }
}

impl BridgeResponse {
    pub fn error(
        run_id: impl Into<String>,
        generated_at: impl Into<String>,
        diagnostic: Diagnostic,
    ) -> Self {
        Self {
            schema_version: BRIDGE_SCHEMA_VERSION,
            run_id: run_id.into(),
            generated_at: generated_at.into(),
            status: ResponseStatus::Error,
            artifact: None,
            credential_updates: Vec::new(),
            credential_challenges: Vec::new(),
            diagnostics: vec![diagnostic],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        response_status, retain_previous_artifact, AgentUsageArtifact, CollectionWindow,
        ResponseStatus, SourceDeltaChange, TokenBucket, UsageContributionBuilder, UsageSample,
    };
    use serde_json::{json, Map, Value};

    #[test]
    fn window_uses_requested_timezone_for_day_and_hour_boundaries() {
        let context: Map<String, Value> = serde_json::from_value(json!({
            "now": "2026-07-28T00:30:00Z",
            "timezone": "Asia/Shanghai",
            "days": 2
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        assert_eq!(window.today, "2026-07-28");
        assert_eq!(window.day_list, ["2026-07-27", "2026-07-28"]);
        assert_eq!(window.hour_of_millis(1_785_198_600_000), Some(8));
    }

    #[test]
    fn status_precedence_and_previous_retention_are_explicit() {
        assert_eq!(response_status(false, 0), ResponseStatus::Error);
        assert_eq!(response_status(true, 0), ResponseStatus::Success);
        assert_eq!(response_status(true, 1), ResponseStatus::Partial);
        let previous = json!({"agents": ["previous"]});
        assert_eq!(
            retain_previous_artifact(None, Some(previous.clone())),
            Some(previous.clone())
        );
        assert_eq!(
            retain_previous_artifact(Some(json!({"agents": ["current"]})), Some(previous)),
            Some(json!({"agents": ["current"]}))
        );
    }

    #[test]
    fn artifact_fields_serialize_with_bridge_camel_case() {
        let bucket = TokenBucket {
            input: 1,
            output: 2,
            cache_read: 3,
            cache_creation: 4,
            total: 10,
        };
        let encoded = serde_json::to_value(&bucket).unwrap();
        assert_eq!(encoded["cacheRead"], 3);
        assert_eq!(encoded["cacheCreation"], 4);
        assert!(encoded.get("cache_read").is_none());

        let artifact: AgentUsageArtifact = serde_json::from_value(json!({
            "schemaVersion": 1,
            "module": "agent-usage",
            "generatedAt": "2026-07-28T12:00:00+08:00",
            "agents": [],
            "services": [],
            "totalCostUsd": null
        }))
        .unwrap();
        assert_eq!(artifact.schema_version, 1);
        assert_eq!(
            serde_json::to_value(artifact).unwrap()["totalCostUsd"],
            Value::Null
        );
    }

    #[test]
    fn contribution_builder_preserves_window_and_round_trip_contract() {
        let context: Map<String, Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let today = chrono::DateTime::parse_from_rfc3339("2026-07-28T10:00:00+08:00")
            .unwrap()
            .timestamp_millis();
        let outside = chrono::DateTime::parse_from_rfc3339("2026-07-20T10:00:00+08:00")
            .unwrap()
            .timestamp_millis();
        let mut builder = UsageContributionBuilder::new(window.clone());
        assert!(builder.record(UsageSample {
            timestamp_millis: today,
            model: Some("gpt-5"),
            input: 10,
            output: 3,
            cache_read: 2,
            cache_creation: 1,
            project: Some("Bruce"),
        }));
        assert!(!builder.record(UsageSample {
            timestamp_millis: outside,
            model: Some("ignored"),
            input: 100,
            output: 100,
            cache_read: 100,
            cache_creation: 100,
            project: Some("ignored"),
        }));
        let contribution = builder.contribution();
        assert_eq!(contribution.by_day[&window.today].total, 16);
        assert_eq!(contribution.models_today[0].model, "gpt-5");
        assert_eq!(contribution.projects_today[0].name, "Bruce");
        assert_eq!(contribution.hours.iter().sum::<u64>(), 16);
        let encoded = serde_json::to_value(&contribution).unwrap();
        assert!(encoded.get("modelsToday").is_some());
        assert!(encoded.get("models_today").is_none());
        let decoded: super::UsageContribution = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded, contribution);

        let invalid = super::UsageContribution {
            hours: vec![1],
            ..contribution.clone()
        };
        assert!(!UsageContributionBuilder::new(window).merge_contribution(&invalid));
    }

    #[test]
    fn source_change_serializes_identity_without_raw_payload_fields() {
        let contribution = super::UsageContribution {
            by_day: Default::default(),
            models_today: Vec::new(),
            projects_today: Vec::new(),
            hours: vec![0; 24],
        };
        let encoded = serde_json::to_value(SourceDeltaChange::replace(
            "source-a",
            None,
            Some(contribution),
        ))
        .unwrap();
        assert_eq!(encoded["sourceId"], "source-a");
        assert!(encoded.get("raw").is_none());
        assert!(encoded.get("credential").is_none());
    }
}
