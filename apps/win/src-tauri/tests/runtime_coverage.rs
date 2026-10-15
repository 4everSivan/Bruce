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
fn panel_json_provider_visibility_covers_cline_and_jev() {
    // C028 的端到端承诺: 「凭证可存 (clineQuotaAccounts 在 allowlist) 即可在看板可见」。
    // 三条链路必须同时正确, 少任一条都会静默丢段:
    //   enabled_providers retain 过滤 / 视图模型 provider 归一化 (cline_<acc> → cline)
    //   / provider_order 排序。jev 则必须被视图模型整组屏蔽 (对齐 mac)。
    let artifact = json!({
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-10-08T08:00:00Z",
        "agents": [], "totalCostUsd": 0.0,
        "services": [
            {"id": "cline_work", "name": "Cline · work", "status": "ok", "kind": "windows",
             "capturedAt": "2026-10-08T08:00:00Z",
             "windows": [{"label": "每 5 小时", "usedPercent": 8.0}]},
            {"id": "cline_personal", "name": "Cline · personal", "status": "ok", "kind": "windows",
             "capturedAt": "2026-10-08T08:00:00Z",
             "windows": [{"label": "每 5 小时", "usedPercent": 12.0}]},
            {"id": "jev", "name": "Jev", "status": "ok", "kind": "windows",
             "capturedAt": "2026-10-08T08:00:00Z",
             "windows": [{"label": "5h", "usedPercent": 5.0}]},
            {"id": "deepseek", "name": "DeepSeek", "status": "ok", "kind": "balance",
             "capturedAt": "2026-10-08T08:00:00Z", "windows": [], "balance": 38.21, "currency": "CNY"}
        ]
    });
    let mut state = SnapshotState::default();
    state
        .apply_response(&response(artifact, ResponseStatus::Success))
        .unwrap();
    let now = chrono::DateTime::parse_from_rfc3339("2026-10-08T08:30:00Z").unwrap();

    // 未启用 provider 被过滤 (deepseek 不在 enabled), provider_order 决定段序。
    let panel = state.panel_json(
        now,
        true,
        &["kimi".into(), "cline".into()],
        &["cline".into()],
    );
    let sections = panel["subscription"]["sections"].as_array().unwrap();
    assert_eq!(
        sections.len(),
        1,
        "只应有 cline 一段: jev 屏蔽 + deepseek 未启用过滤"
    );
    assert_eq!(sections[0]["id"], "cline");
    assert_eq!(
        sections[0]["name"], "Cline",
        "展示名不得回落为原始 service ID"
    );
    assert_eq!(
        sections[0]["accountCountText"], "2 个账号",
        "cline 双账号归一为一段"
    );
    assert_eq!(sections[0]["accounts"].as_array().unwrap().len(), 2);
    assert!(
        !panel.to_string().contains("jev") && !panel.to_string().contains("Jev"),
        "jev 不得出现在面板 JSON 任何字段"
    );

    // 未启用 cline 时整段消失 (与 mac 的 enabled 门控一致), 仅有余额型 deepseek。
    let filtered = state.panel_json(now, true, &["deepseek".into()], &[]);
    let filtered_sections = filtered["subscription"]["sections"].as_array().unwrap();
    assert_eq!(filtered_sections.len(), 1);
    assert_eq!(filtered_sections[0]["id"], "deepseek");
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

#[test]
fn dashboard_geometry_standard_1080p_100_percent() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds, TrayIconBounds};
    let monitor = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 0,
        work_y: 0,
        work_width: 1920,
        work_height: 1040, // 底部 40px 任务栏
        scale_factor: 1.0,
    };
    let tray = TrayIconBounds {
        x: 1800,
        y: 1040,
        width: 40,
        height: 40,
    };
    let geom = compute_dashboard_geometry(&monitor, Some(&tray));
    assert_eq!(geom.width, 440);
    assert_eq!(geom.height, 760);
    // 底部贴靠：1040 - 760 - 10 = 270
    assert_eq!(geom.y, 270);
    assert!(geom.y + geom.height as i32 <= monitor.work_height as i32);
    // 水平对齐：托盘中心 1820 - 220 = 1600，被右边界安全 clamp (1920 - 440 - 12 = 1468)
    assert_eq!(geom.x, 1468);
    assert!(geom.x + geom.width as i32 <= monitor.work_width as i32);
}

#[test]
fn dashboard_geometry_1080p_150_percent_high_dpi_laptop_never_overflows() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds, TrayIconBounds};
    // 典型 15.6 寸 1080p 笔记本 150% 缩放
    let monitor = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 0,
        work_y: 0,
        work_width: 1920,
        work_height: 1032, // 48px 物理任务栏
        scale_factor: 1.5,
    };
    let tray = TrayIconBounds {
        x: 1840,
        y: 1032,
        width: 48,
        height: 48,
    };
    let geom = compute_dashboard_geometry(&monitor, Some(&tray));
    // 逻辑可用高度 1032 / 1.5 = 688，最大逻辑高度 688 - 20 = 668
    // 物理高度 668 * 1.5 = 1002 <= 1032
    assert_eq!(geom.width, 660); // 440 * 1.5
    assert_eq!(geom.height, 1002);
    // y = 1032 - 1002 - 15 = 15
    assert_eq!(geom.y, 15);
    // 绝不溢出屏幕物理工作区底边界！
    assert!(geom.y >= monitor.work_y);
    assert!(geom.y + geom.height as i32 <= monitor.work_height as i32);
}

#[test]
fn dashboard_geometry_compact_laptop_768p_adapts_height() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds, TrayIconBounds};
    let monitor = MonitorBounds {
        x: 0,
        y: 0,
        width: 1366,
        height: 768,
        work_x: 0,
        work_y: 0,
        work_width: 1366,
        work_height: 728, // 40px 任务栏
        scale_factor: 1.0,
    };
    let tray = TrayIconBounds {
        x: 1300,
        y: 728,
        width: 40,
        height: 40,
    };
    let geom = compute_dashboard_geometry(&monitor, Some(&tray));
    // 自动从 760 缩小至 728 - 20 = 708
    assert_eq!(geom.height, 708);
    assert_eq!(geom.width, 440);
    assert_eq!(geom.y, 10);
    assert!(geom.y + geom.height as i32 <= 728);
}

#[test]
fn dashboard_geometry_2k_and_4k_scaling() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds};
    // 2K 125%
    let monitor_2k = MonitorBounds {
        x: 0,
        y: 0,
        width: 2560,
        height: 1440,
        work_x: 0,
        work_y: 0,
        work_width: 2560,
        work_height: 1390,
        scale_factor: 1.25,
    };
    let geom_2k = compute_dashboard_geometry(&monitor_2k, None);
    assert_eq!(geom_2k.width, 550); // 440 * 1.25
    assert_eq!(geom_2k.height, 950); // 760 * 1.25
    assert!(geom_2k.y + geom_2k.height as i32 <= 1390);

    // 4K 200%
    let monitor_4k = MonitorBounds {
        x: 0,
        y: 0,
        width: 3840,
        height: 2160,
        work_x: 0,
        work_y: 0,
        work_width: 3840,
        work_height: 2080,
        scale_factor: 2.0,
    };
    let geom_4k = compute_dashboard_geometry(&monitor_4k, None);
    assert_eq!(geom_4k.width, 880); // 440 * 2.0
    assert_eq!(geom_4k.height, 1520); // 760 * 2.0
    assert!(geom_4k.y + geom_4k.height as i32 <= 2080);
}

#[test]
fn dashboard_geometry_top_taskbar() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds, TrayIconBounds};
    let monitor = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 0,
        work_y: 40, // 顶部 40px 任务栏
        work_width: 1920,
        work_height: 1040,
        scale_factor: 1.0,
    };
    let tray = TrayIconBounds {
        x: 1800,
        y: 0,
        width: 40,
        height: 40,
    };
    let geom = compute_dashboard_geometry(&monitor, Some(&tray));
    assert_eq!(geom.y, 50); // 40 + 10 = 50 贴在顶部任务栏下方
    assert!(geom.y >= monitor.work_y);
    assert!(geom.y + geom.height as i32 <= 1080);
}

#[test]
fn dashboard_geometry_hotkey_fallback_without_tray() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds};
    let monitor = MonitorBounds {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: 0,
        work_y: 0,
        work_width: 1920,
        work_height: 1040,
        scale_factor: 1.0,
    };
    let geom = compute_dashboard_geometry(&monitor, None);
    assert_eq!(geom.width, 440);
    assert_eq!(geom.height, 760);
    assert_eq!(geom.x, 1920 - 440 - 12);
    assert_eq!(geom.y, 1040 - 760 - 10);
}

#[test]
fn dashboard_geometry_multi_monitor_negative_coordinates() {
    use bruce_win_lib::runtime_core::{compute_dashboard_geometry, MonitorBounds, TrayIconBounds};
    // 副屏位于主屏左侧
    let monitor = MonitorBounds {
        x: -1920,
        y: 0,
        width: 1920,
        height: 1080,
        work_x: -1920,
        work_y: 0,
        work_width: 1920,
        work_height: 1040,
        scale_factor: 1.0,
    };
    let tray = TrayIconBounds {
        x: -100,
        y: 1040,
        width: 40,
        height: 40,
    };
    let geom = compute_dashboard_geometry(&monitor, Some(&tray));
    assert!(geom.x >= -1920);
    assert!(geom.x + geom.width as i32 <= 0);
    assert!(geom.y >= 0);
    assert!(geom.y + geom.height as i32 <= 1040);
}
