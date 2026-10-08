use bruce_win_lib::runtime_core::{merge_snapshot, next_delay, RefreshOutcome};
use serde_json::json;

#[test]
fn failed_collection_retries_after_backoff_without_extra_interval() {
    assert_eq!(
        next_delay(
            RefreshOutcome::Failed {
                rate_limited: false
            },
            1,
            1800,
            30
        ),
        30
    );
    assert_eq!(
        next_delay(RefreshOutcome::Failed { rate_limited: true }, 1, 1800, 300),
        300
    );
    assert_eq!(next_delay(RefreshOutcome::Success, 0, 1800, 30), 1800);
    assert_eq!(
        next_delay(
            RefreshOutcome::Failed {
                rate_limited: false
            },
            6,
            1800,
            30
        ),
        1800
    );
}

#[test]
fn partial_provider_failure_retains_matching_previous_windows_as_stale() {
    let previous = json!({"services":[{"id":"codex_a", "status":"ok", "capturedAt":"2026-10-08T08:00:00Z", "windows":[{"usedPercent":45}]}]});
    let current = json!({"services":[{"id":"codex_a", "status":"error", "windows":[]}]});
    let merged = merge_snapshot(Some(&previous), &current);
    assert_eq!(merged["services"][0]["windows"][0]["usedPercent"], 45);
    assert_eq!(merged["services"][0]["freshness"], "stale");
    assert_eq!(merged["services"][0]["status"], "error");
}

use bruce_win_lib::runtime_core::{replace_hotkey, window_action, SnapshotState, WindowAction};
use bruce_win_lib::scheduler::SchedulerControl;
use collector_domain::{BridgeResponse, Diagnostic, ResponseStatus};
use serde_json::Value;
use std::cell::RefCell;
use std::collections::BTreeSet;

fn valid_artifact() -> Value {
    json!({"schemaVersion":1,"module":"agent-usage","generatedAt":"2026-10-08T08:00:00Z", "agents":[], "services":[{"id":"codex_a", "name":"Codex", "status":"ok", "kind":"windows", "capturedAt":"2026-10-08T08:00:00Z", "windows":[{"label":"5h","usedPercent":45}]}], "totalCostUsd":0.0})
}

fn response(artifact: Value, status: ResponseStatus) -> BridgeResponse {
    BridgeResponse {
        schema_version: 1,
        run_id: "fixture".into(),
        generated_at: "2026-10-08T08:00:00Z".into(),
        status,
        artifact: Some(artifact),
        credential_updates: vec![],
        credential_challenges: vec![],
        diagnostics: vec![],
    }
}

fn root() -> std::path::PathBuf {
    let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo = manifest
        .ancestors()
        .find(|p| p.join("core/collector").is_dir())
        .expect("repository root");
    let path = repo
        .join("local/c009/runtime-tests")
        .join(uuid::Uuid::new_v4().to_string());
    std::fs::create_dir_all(&path).unwrap();
    path
}

#[test]
fn manual_bursts_are_bounded_and_interrupt_long_retry_wait() {
    let control = SchedulerControl::new();
    let receiver = control.connect_manual_refresh();
    for _ in 0..1000 {
        control.request_manual_refresh();
    }
    assert_eq!(
        receiver.try_iter().count(),
        1,
        "a click burst produces one collection"
    );
    control.request_manual_refresh();
    assert!(receiver
        .recv_timeout(std::time::Duration::from_secs(300))
        .is_ok());
    assert!(receiver.try_recv().is_err());
}

#[test]
fn malformed_artifact_preserves_last_good_snapshot_and_reports_failure() {
    let mut state = SnapshotState::default();
    state
        .apply_response(&response(valid_artifact(), ResponseStatus::Success))
        .unwrap();
    assert!(state
        .apply_response(&response(json!({"services":[]}), ResponseStatus::Success))
        .is_err());
    assert_eq!(state.phase, "stale");
    assert_eq!(state.error.as_deref(), Some("ARTIFACT_INVALID"));
    assert_eq!(
        state.artifact().unwrap()["services"][0]["windows"][0]["usedPercent"],
        45
    );
    assert_eq!(
        state.artifact().unwrap()["services"][0]["freshness"],
        "stale"
    );
}

#[test]
fn bridge_failure_preserves_snapshot_without_leaking_diagnostic_message() {
    let mut state = SnapshotState::default();
    state
        .apply_response(&response(valid_artifact(), ResponseStatus::Success))
        .unwrap();
    let failed = BridgeResponse::error(
        "run",
        "2026-10-08T09:00:00Z",
        Diagnostic::new(
            "PROVIDER_AUTH_REJECTED",
            "provider",
            "external",
            "secret-token-fixture",
            true,
        ),
    );
    assert!(state.apply_response(&failed).is_err());
    let panel = state.panel_json(
        chrono::DateTime::parse_from_rfc3339("2026-10-08T09:00:00Z").unwrap(),
        true,
        &["codex".into()],
        &[],
    );
    assert!(!panel.to_string().contains("secret-token-fixture"));
    assert_eq!(
        panel["runtime"]["diagnosticCodes"][0],
        "PROVIDER_AUTH_REJECTED"
    );
    assert_eq!(panel["runtime"]["lastSuccessAt"], "2026-10-08T08:00:00Z");
}

#[test]
fn durable_snapshot_restores_stale_and_corrupt_cache_is_visible() {
    let path = root();
    let mut state = SnapshotState::default();
    state
        .apply_response(&response(valid_artifact(), ResponseStatus::Success))
        .unwrap();
    state.save(&path).unwrap();
    let restored = SnapshotState::load(&path);
    assert_eq!(restored.phase, "stale");
    assert_eq!(
        restored.artifact().unwrap()["services"][0]["freshness"],
        "stale"
    );
    assert_eq!(
        restored.last_success_at.as_deref(),
        Some("2026-10-08T08:00:00Z")
    );
    std::fs::write(path.join("snapshot.json"), b"broken").unwrap();
    let invalid = SnapshotState::load(&path);
    assert_eq!(invalid.error.as_deref(), Some("SNAPSHOT_INVALID"));
    assert!(invalid.artifact().is_none());
}

#[test]
fn absent_account_is_not_resurrected_and_bad_history_not_used() {
    let old = valid_artifact();
    let current = json!({"services":[{"id":"codex_new","status":"error","windows":[]}]});
    let merged = merge_snapshot(Some(&old), &current);
    assert_eq!(merged["services"].as_array().unwrap().len(), 1);
    assert_eq!(merged["services"][0]["id"], "codex_new");
    assert_eq!(merged["services"][0]["freshness"], "unavailable");
    let mut old = old;
    old["services"][0]["capturedAt"] = json!("invalid-time");
    let current = json!({"services":[{"id":"codex_a","status":"error","windows":[]}]});
    assert_eq!(
        merge_snapshot(Some(&old), &current)["services"][0]["freshness"],
        "unavailable"
    );
}

#[test]
fn settings_focus_does_not_hide_or_overwrite_dashboard_position() {
    assert_eq!(window_action("settings", true, false), WindowAction::None);
    assert_eq!(
        window_action("settings", false, true),
        WindowAction::HideSettings
    );
    assert_eq!(
        window_action("dashboard", true, false),
        WindowAction::HideDashboardAndPersist
    );
    assert_eq!(window_action("other", true, true), WindowAction::None);
}

#[test]
fn hotkey_registration_and_persistence_failures_keep_old_shortcut() {
    let keys = RefCell::new(BTreeSet::from(["old".to_owned()]));
    let saved = RefCell::new(false);
    assert!(replace_hotkey(
        "old",
        "bad",
        |_key| Err("registration failure".into()),
        |key| {
            keys.borrow_mut().remove(key);
            Ok(())
        },
        || {
            *saved.borrow_mut() = true;
            Ok(())
        }
    )
    .is_err());
    assert!(keys.borrow().contains("old"));
    assert!(!*saved.borrow());
    assert!(replace_hotkey(
        "old",
        "new",
        |key| {
            keys.borrow_mut().insert(key.to_owned());
            Ok(())
        },
        |key| {
            keys.borrow_mut().remove(key);
            Ok(())
        },
        || Err("disk failure".into())
    )
    .is_err());
    assert_eq!(*keys.borrow(), BTreeSet::from(["old".to_owned()]));
}

#[test]
fn manual_alert_refresh_observes_threshold_without_delivery() {
    let mut state = bruce_win_lib::alerts::AlertDeliveryState::default();
    let alert = bruce_win_lib::alerts::QuotaAlert {
        service_id: "codex".into(),
        service_name: "Codex".into(),
        window_label: "5h".into(),
        used_percent: 90.0,
    };
    assert!(state
        .alerts_for_refresh(std::slice::from_ref(&alert), true, true)
        .is_empty());
    assert!(state
        .alerts_for_refresh(std::slice::from_ref(&alert), false, true)
        .is_empty());
    assert!(state.alerts_for_refresh(&[], false, true).is_empty());
    assert_eq!(state.alerts_for_refresh(&[alert], false, true).len(), 1);
}

#[test]
fn partial_balance_failure_keeps_balance_currency_and_marks_stale() {
    let previous = json!({"services":[{"id":"deepseek_a","kind":"balance","status":"ok","balance":12.5,"currency":"CNY","capturedAt":"2026-10-08T08:00:00Z"}]});
    let current = json!({"services":[{"id":"deepseek_a","kind":"balance","status":"error"}]});
    let merged = merge_snapshot(Some(&previous), &current);
    assert_eq!(merged["services"][0]["balance"], 12.5);
    assert_eq!(merged["services"][0]["currency"], "CNY");
    assert_eq!(merged["services"][0]["freshness"], "stale");
}

#[test]
fn credential_pruning_uses_shared_hashed_codex_service_identity() {
    let mut artifact = valid_artifact();
    artifact["services"][0]["id"] = json!(collector_provider::codex_service_id("a"));
    let mut state = SnapshotState::default();
    state
        .apply_response(&response(artifact, ResponseStatus::Success))
        .unwrap();
    let credentials = std::collections::BTreeMap::from([(
        "codexQuotaAccounts".into(),
        json!({"a":{"display_name":"A","access_token":"fixture"}}),
    )]);
    state.prune_credentials(&credentials);
    assert_eq!(
        state.artifact().unwrap()["services"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    state.prune_credentials(&Default::default());
    assert!(state.artifact().unwrap()["services"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn manual_origin_survives_backoff_without_leaking_into_next_normal_cycle() {
    use bruce_win_lib::runtime_core::manual_alert_reason;
    assert!(manual_alert_reason(true, 0, false));
    assert!(manual_alert_reason(false, 1, true));
    assert!(manual_alert_reason(false, 5, true));
    assert!(!manual_alert_reason(false, 0, true));
    assert!(!manual_alert_reason(false, 6, true));
    assert!(!manual_alert_reason(false, 1, false));
}
