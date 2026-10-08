//! Pure refresh, window and snapshot policies; no GUI, network or user-home access.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use chrono::{DateTime, FixedOffset};
use collector_domain::{AgentUsageArtifact, BridgeResponse, ResponseStatus};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshOutcome {
    Success,
    Failed { rate_limited: bool },
}

/// A retry replaces the normal interval. There is exactly one interruptible wait.
pub fn next_delay(outcome: RefreshOutcome, retries: u32, interval: u64, backoff: u64) -> u64 {
    if matches!(outcome, RefreshOutcome::Failed { .. }) && retries <= 5 {
        backoff
    } else {
        interval
    }
}

/// Backoff retries retain the manual origin; the next normal cycle may notify again.
pub fn manual_alert_reason(input: bool, retries: u32, previous: bool) -> bool {
    input || (retries > 0 && retries <= 5 && previous)
}

pub fn provider_id(service: &Value) -> &str {
    let id = service.get("id").and_then(Value::as_str).unwrap_or("");
    if id.starts_with("codex") {
        "codex"
    } else if id.starts_with("claude") {
        "claude"
    } else if id.starts_with("kimi") {
        "kimi"
    } else if id.starts_with("deepseek") {
        "deepseek"
    } else if id.starts_with("volc") {
        "volcengine"
    } else if id.starts_with("zhipu") || id.starts_with("glm") {
        "zhipu"
    } else if id.starts_with("grok") {
        "grok"
    } else if id.starts_with("opencode") {
        "opencodeGo"
    } else if id.starts_with("step") {
        "stepfun"
    } else {
        id
    }
}

fn qualified(service: &Value) -> bool {
    let captured = service
        .get("capturedAt")
        .and_then(Value::as_str)
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
        .is_some();
    if !captured {
        return false;
    }
    match service.get("freshness").and_then(Value::as_str) {
        Some("fresh" | "stale") => true,
        Some(_) => false,
        None => matches!(
            service.get("status").and_then(Value::as_str),
            Some("ok" | "")
        ),
    }
}

/// Only IDs returned by this collection survive. Removed accounts cannot reappear
/// from history; failed current accounts may borrow qualified old display fields.
pub fn merge_snapshot(previous: Option<&Value>, current: &Value) -> Value {
    let mut result = current.clone();
    let previous_services: BTreeMap<&str, &Value> = previous
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|service| {
            service
                .get("id")
                .and_then(Value::as_str)
                .map(|id| (id, service))
        })
        .collect();
    if let Some(services) = result.get_mut("services").and_then(Value::as_array_mut) {
        for service in services {
            if !service.is_object() {
                continue;
            }
            let status = service.get("status").and_then(Value::as_str).unwrap_or("");
            if matches!(status, "ok" | "empty") {
                service["freshness"] = json!("fresh");
                continue;
            }
            let old = service
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| previous_services.get(id))
                .filter(|old| qualified(old));
            if let Some(old) = old {
                for field in [
                    "windows",
                    "balance",
                    "currency",
                    "plan",
                    "extra",
                    "kind",
                    "capturedAt",
                ] {
                    if let Some(value) = old.get(field) {
                        service[field] = value.clone();
                    }
                }
                service["freshness"] = json!("stale");
            } else {
                service["freshness"] = json!("unavailable");
                if let Some(object) = service.as_object_mut() {
                    object.remove("capturedAt");
                }
            }
        }
    }
    result
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotState {
    artifact: Option<Value>,
    pub phase: String,
    pub last_success_at: Option<String>,
    pub error: Option<String>,
    #[serde(default)]
    diagnostics: Vec<String>,
}

impl Default for SnapshotState {
    fn default() -> Self {
        Self {
            artifact: None,
            phase: "idle".into(),
            last_success_at: None,
            error: None,
            diagnostics: vec![],
        }
    }
}

impl SnapshotState {
    pub fn artifact(&self) -> Option<&Value> {
        self.artifact.as_ref()
    }

    /// Filter restored snapshots against current credentials before publishing.
    pub fn prune_credentials(&mut self, credentials: &BTreeMap<String, Value>) {
        let Some(services) = self
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        else {
            return;
        };
        services.retain(|service| {
            let provider = provider_id(service);
            let accounts = credentials
                .get(&format!("{provider}QuotaAccounts"))
                .and_then(Value::as_object);
            let id = service.get("id").and_then(Value::as_str).unwrap_or("");
            if provider == "codex" {
                return accounts.is_some_and(|accounts| {
                    accounts
                        .keys()
                        .any(|account| collector_provider::codex_service_id(account) == id)
                });
            }
            let prefix = match provider {
                "kimi" => "kimi_coding_".to_owned(),
                "opencodeGo" => "opencode_go_".to_owned(),
                _ => format!("{provider}_"),
            };
            if let Some(account_id) = id.strip_prefix(&prefix) {
                if let Some(accounts) = accounts {
                    return accounts.contains_key(account_id);
                }
                return credentials.contains_key(&format!("{provider}OAuth"));
            }
            accounts.is_some_and(|accounts| !accounts.is_empty())
                || credentials.contains_key(&format!("{provider}OAuth"))
        });
    }

    pub fn load(root: &Path) -> Self {
        match fs::read(root.join("snapshot.json")) {
            Ok(bytes) => match serde_json::from_slice::<Self>(&bytes) {
                Ok(mut state)
                    if state
                        .artifact
                        .as_ref()
                        .map(validate_artifact)
                        .transpose()
                        .is_ok() =>
                {
                    state.fail("SNAPSHOT_RESTORED");
                    state
                }
                _ => Self {
                    phase: "failed".into(),
                    error: Some("SNAPSHOT_INVALID".into()),
                    ..Self::default()
                },
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(_) => Self {
                phase: "failed".into(),
                error: Some("SNAPSHOT_READ_FAILED".into()),
                ..Self::default()
            },
        }
    }

    pub fn save(&self, root: &Path) -> Result<(), String> {
        let bytes = serde_json::to_vec(self).map_err(|_| "SNAPSHOT_WRITE_FAILED".to_owned())?;
        crate::credentials::atomic_private_write(&root.join("snapshot.json"), &bytes)
            .map_err(|_| "SNAPSHOT_WRITE_FAILED".to_owned())
    }

    pub fn begin_refresh(&mut self) {
        self.phase = "refreshing".into();
    }

    pub fn fail(&mut self, code: &str) {
        self.phase = if self.artifact.is_some() {
            "stale"
        } else {
            "failed"
        }
        .into();
        self.error = Some(code.into());
        if let Some(services) = self
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        {
            for service in services {
                if qualified(service) {
                    service["freshness"] = json!("stale");
                }
            }
        }
    }

    /// Validate before mutating the saved snapshot. Bridge error artifacts never
    /// replace a valid previous snapshot, and malformed JSON is a visible failure.
    pub fn apply_response(&mut self, response: &BridgeResponse) -> Result<(), String> {
        self.diagnostics = response
            .diagnostics
            .iter()
            .map(|d| {
                if d.code.len() <= 64
                    && d.code
                        .chars()
                        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
                {
                    d.code.clone()
                } else {
                    "COLLECTOR_DIAGNOSTIC".into()
                }
            })
            .collect();
        if response.status == ResponseStatus::Error {
            self.fail("COLLECTION_FAILED");
            return Err("COLLECTION_FAILED".into());
        }
        let Some(current) = response.artifact.as_ref() else {
            self.fail("ARTIFACT_MISSING");
            return Err("ARTIFACT_MISSING".into());
        };
        if validate_artifact(current).is_err() {
            self.fail("ARTIFACT_INVALID");
            return Err("ARTIFACT_INVALID".into());
        }
        self.artifact = Some(merge_snapshot(self.artifact.as_ref(), current));
        self.phase = if response.status == ResponseStatus::Partial {
            "partial"
        } else {
            "fresh"
        }
        .into();
        self.error = if response.status == ResponseStatus::Partial {
            Some("COLLECTION_PARTIAL".into())
        } else {
            None
        };
        if response.status == ResponseStatus::Success {
            self.last_success_at = Some(response.generated_at.clone());
        }
        Ok(())
    }

    pub fn panel_json(
        &self,
        now: DateTime<FixedOffset>,
        usage_enabled: bool,
        enabled_providers: &[String],
        provider_order: &[String],
    ) -> Value {
        let mut typed = self
            .artifact
            .as_ref()
            .and_then(|a| serde_json::from_value::<AgentUsageArtifact>(a.clone()).ok());
        if let Some(artifact) = typed.as_mut() {
            artifact
                .services
                .retain(|service| enabled_providers.iter().any(|p| p == provider_id(service)));
            artifact.services.sort_by_key(|service| {
                provider_order
                    .iter()
                    .position(|p| p == provider_id(service))
                    .unwrap_or(usize::MAX)
            });
        }
        let mapper = bruce_win_viewmodel::usage::PanelViewModelMapper::default();
        let mut panel =
            serde_json::to_value(mapper.make(typed.as_ref(), now)).unwrap_or_else(|_| json!({}));
        if !usage_enabled {
            panel["usage"] = Value::Null;
            panel["hourly"] = Value::Null;
        }
        // Viewmodel grouping has its own canonical sort, so apply configured order after mapping.
        if let Some(sections) = panel
            .pointer_mut("/subscription/sections")
            .and_then(Value::as_array_mut)
        {
            sections.sort_by_key(|section| {
                provider_order
                    .iter()
                    .position(|p| p == provider_id(section))
                    .unwrap_or(usize::MAX)
            });
        }
        panel["runtime"] = json!({"phase":self.phase,"lastSuccessAt":self.last_success_at,"error":self.error,"diagnosticCodes":self.diagnostics});
        panel
    }
}

fn validate_artifact(value: &Value) -> Result<(), ()> {
    let artifact: AgentUsageArtifact = serde_json::from_value(value.clone()).map_err(|_| ())?;
    DateTime::parse_from_rfc3339(&artifact.generated_at).map_err(|_| ())?;
    if artifact
        .services
        .iter()
        .any(|service| !service.is_object() || service.get("id").and_then(Value::as_str).is_none())
    {
        return Err(());
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowAction {
    None,
    HideDashboardAndPersist,
    HideSettings,
}

pub fn window_action(label: &str, lost_focus: bool, close: bool) -> WindowAction {
    match (label, lost_focus, close) {
        ("dashboard", true, _) | ("dashboard", _, true) => WindowAction::HideDashboardAndPersist,
        ("settings", _, true) => WindowAction::HideSettings,
        _ => WindowAction::None,
    }
}

/// Stage replacement before unregistering the working shortcut; roll back either
/// registration or persistence failure. Empty means explicitly disable shortcuts.
pub fn replace_hotkey<R, U, S>(
    old: &str,
    new: &str,
    mut register: R,
    mut unregister: U,
    save: S,
) -> Result<(), String>
where
    R: FnMut(&str) -> Result<(), String>,
    U: FnMut(&str) -> Result<(), String>,
    S: FnOnce() -> Result<(), String>,
{
    if old == new {
        return save();
    }
    if !new.is_empty() {
        register(new)?;
    }
    if !old.is_empty() {
        if let Err(error) = unregister(old) {
            if !new.is_empty() {
                let _ = unregister(new);
            }
            return Err(error);
        }
    }
    if let Err(error) = save() {
        if !new.is_empty() {
            let _ = unregister(new);
        }
        if !old.is_empty() {
            register(old).map_err(|_| "HOTKEY_ROLLBACK_FAILED".to_owned())?;
        }
        return Err(error);
    }
    Ok(())
}
