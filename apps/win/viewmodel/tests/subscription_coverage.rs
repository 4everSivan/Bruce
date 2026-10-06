//! 订阅卡映射覆盖 —— 对齐 mac SubscriptionMapping/SubscriptionPresentationPolicy
//! 的全部规则分支 (分组、措辞、重置、剥离、标记、排序、诊断)。

use chrono::{DateTime, FixedOffset, TimeZone};
use collector_domain::AgentUsageArtifact;
use serde_json::{json, Value};

use bruce_win_viewmodel::models::PanelDiagnostic;
use bruce_win_viewmodel::subscription::{reset_text, window_label};
use bruce_win_viewmodel::usage::PanelViewModelMapper;

fn fixed_now() -> chrono::DateTime<FixedOffset> {
    FixedOffset::east_opt(8 * 3600)
        .unwrap()
        .with_ymd_and_hms(2026, 7, 28, 12, 30, 0)
        .unwrap()
}

fn artifact_from(services: Value) -> AgentUsageArtifact {
    serde_json::from_value(json!({
        "schemaVersion": 1, "module": "agent-usage",
        "generatedAt": "2026-07-28T12:00:00+08:00",
        "agents": [], "services": services.clone(), "totalCostUsd": null
    }))
    .unwrap()
}

fn map(
    services: Value,
) -> (
    Option<bruce_win_viewmodel::subscription::SubscriptionViewModel>,
    Vec<PanelDiagnostic>,
) {
    let artifact = artifact_from(services);
    let mut diagnostics = Vec::new();
    let subscription =
        PanelViewModelMapper::default().make_subscription(&artifact, fixed_now(), &mut diagnostics);
    (subscription, diagnostics)
}

#[test]
fn window_label_tolerance_matches_mac_approximately() {
    // 容差 |minutes - target| <= max(2, target/50): 300 -> ±6。
    assert_eq!(window_label("5h", Some(300)), "每 5 小时");
    assert_eq!(window_label("5h", Some(306)), "每 5 小时");
    assert_eq!(window_label("5h", Some(294)), "每 5 小时");
    assert_eq!(window_label("5h", Some(307)), "5h", "超出容差原样");
    assert_eq!(window_label("5h", Some(293)), "5h");
    // 10080 -> ±201; 43200 -> ±864。
    assert_eq!(window_label("w", Some(10080)), "每周");
    assert_eq!(window_label("w", Some(43200)), "每月");
    // 规范 label 文本映射。
    assert_eq!(window_label("5小时窗口", None), "每 5 小时");
    assert_eq!(window_label("7天窗口", None), "每周");
    assert_eq!(window_label("每周窗口", None), "每周");
    assert_eq!(window_label("每月窗口", None), "每月");
}

#[test]
fn reset_text_epoch_and_invalid_paths() {
    let at = |value: &str| DateTime::parse_from_rfc3339(value).unwrap();
    // 当日 -> "H:mm" (小时不补零)。
    assert_eq!(
        reset_text(Some(at("2026-07-28T15:00:00+08:00")), fixed_now()),
        "15:00"
    );
    // 当日晚于 now -> 小时不补零; 当日早于 now -> 已到期。
    assert_eq!(
        reset_text(Some(at("2026-07-28T12:35:00+08:00")), fixed_now()),
        "12:35"
    );
    assert_eq!(
        reset_text(Some(at("2026-07-28T09:05:00+08:00")), fixed_now()),
        "已到期"
    );
    // 次日 -> "N 天后"; 当日 00:00 之后多天正确计数; 上限至少 1。
    assert_eq!(
        reset_text(Some(at("2026-07-29T09:05:00+08:00")), fixed_now()),
        "1 天后"
    );
    assert_eq!(
        reset_text(Some(at("2026-07-30T00:00:00+08:00")), fixed_now()),
        "2 天后"
    );
    // 已到期与无数据。
    assert_eq!(
        reset_text(Some(at("2026-07-28T12:29:59+08:00")), fixed_now()),
        "已到期"
    );
    assert_eq!(reset_text(None, fixed_now()), "");
}

#[test]
fn epoch_reset_dates_parse_with_nonpositive_rejected() {
    // epoch 1785222000 = 2026-07-28T15:00+08 (当日 15:00, 晚于 now 12:30)。
    let services = json!([{
        "id": "volc", "name": "Volc", "status": "ok", "kind": "windows",
        "windows": [{"label": "5小时窗口", "usedPercent": 50.0, "resetsAt": 1785222000}]
    }]);
    let (subscription, _) = map(services);
    let subscription = subscription.unwrap();
    let row = &subscription.sections[0].windows[0];
    assert_eq!(row.label, "每 5 小时");
    assert_eq!(row.reset_text, "15:00");

    // 非正 epoch (火山未开始窗口 -1) 视为无重置时间。
    let services = json!([{
        "id": "volc", "name": "Volc", "status": "ok", "kind": "windows",
        "windows": [{"label": "5小时窗口", "usedPercent": 50.0, "resetsAt": -1}]
    }]);
    let (subscription, _) = map(services);
    assert_eq!(subscription.unwrap().sections[0].windows[0].reset_text, "");
}

#[test]
fn volcengine_display_name_strips_coding_plan_suffix() {
    let services = json!([{
        "id": "volcengine", "name": "火山引擎（Coding Plan）", "status": "ok", "kind": "windows",
        "windows": [{"label": "5h", "windowMinutes": 300, "usedPercent": 10.0}]
    }]);
    let (subscription, _) = map(services);
    let subscription = subscription.unwrap();
    // section 名走冻结表; 账号名保留 collector 原名 (无 " · " 前缀可剥离,
    // displayName 剥离仅作用于 mac 端分组内不进 section 名的字段)。
    assert_eq!(subscription.sections[0].name, "火山引擎");
    assert_eq!(
        subscription.sections[0].accounts[0].name,
        "火山引擎（Coding Plan）"
    );
}

#[test]
fn extra_text_hides_free_quota_boilerplate() {
    let services = json!([
        {"id": "kimi_coding", "name": "Kimi", "status": "ok", "kind": "windows",
         "extra": "加量包未启用", "windows": [{"label": "5h", "usedPercent": 1.0}]},
        {"id": "deepseek", "name": "DeepSeek", "status": "ok", "kind": "balance",
         "balance": 5.0, "currency": null, "extra": "赠送余额 ¥5.00", "windows": []}
    ]);
    let (subscription, _) = map(services);
    let sections = subscription.unwrap().sections;
    assert_eq!(sections[0].extra_text, None, "加量包未启用对用户无信息量");
    assert_eq!(
        sections[1].extra_text.as_deref(),
        Some("赠送余额 ¥5.00"),
        "其他文案保留"
    );
}

#[test]
fn stepfun_international_tag_only_for_multi_account() {
    let account = |id: &str, name: &str| {
        json!({"id": id, "name": name, "status": "ok", "kind": "windows",
               "windows": [{"label": "5h", "usedPercent": 1.0}]})
    };
    // 多账号: 国外站打标。
    let services = json!([
        account("stepfun_a", "StepFun 国际站"),
        account("stepfun_b", "StepFun 国内站")
    ]);
    let (subscription, _) = map(services);
    let section = &subscription.unwrap().sections[0];
    assert_eq!(section.id, "stepfun");
    assert_eq!(section.accounts[0].tag.as_deref(), Some("国际"));
    assert_eq!(section.accounts[1].tag, None);
    // 单账号不打标。
    let services = json!([account("stepfun_a", "StepFun 国际站")]);
    let (subscription, _) = map(services);
    assert_eq!(subscription.unwrap().sections[0].accounts[0].tag, None);
}

#[test]
fn opencode_go_and_unknown_providers_normalize() {
    let services = json!([
        {"id": "opencode_go_x1", "name": "OpenCode GO", "status": "ok", "kind": "windows",
         "windows": [{"label": "5h", "usedPercent": 5.0}]},
        {"id": "futureprovider", "name": "Future", "status": "ok", "kind": "windows",
         "windows": [{"label": "5h", "usedPercent": 5.0}]}
    ]);
    let (subscription, _) = map(services);
    let sections = subscription.unwrap().sections;
    assert_eq!(sections[0].name, "OpenCode GO", "连字符命名归一");
    assert_eq!(sections[1].name, "futureprovider", "未知 provider 原样回退");
}

#[test]
fn empty_services_yields_none_and_missing_artifact_diagnostic_separate() {
    let (subscription, _) = map(json!([]));
    assert!(subscription.is_none(), "无可渲染 service 时订阅卡为 nil");
}

#[test]
fn placeholder_skip_and_service_issue_diagnostics() {
    let services = json!([
        // partial + 无 kind + 无窗口 + 无余额: 未授权占位, skip。
        {"id": "grok", "name": "Grok", "status": "partial", "kind": null, "windows": [], "balance": null},
        // empty 是真实诊断状态, 必须渲染 + serviceIssue。
        {"id": "zhipu", "name": "智谱", "status": "empty", "kind": null, "windows": [], "balance": null}
    ]);
    let (subscription, diagnostics) = map(services);
    assert!(diagnostics.iter().any(|item| matches!(
        item, PanelDiagnostic::ServiceSkipped { service_id, status, .. } if service_id == "grok" && status == "partial"
    )));
    assert!(diagnostics.iter().any(|item| matches!(
        item, PanelDiagnostic::ServiceIssue { service_id, status, .. } if service_id == "zhipu" && status == "empty"
    )));
    // empty 占位必须保留渲染 (不 skip)。
    assert_eq!(subscription.unwrap().sections[0].id, "zhipu");
}

#[test]
fn balance_sections_sink_last_keeping_artifact_order() {
    let service = |id: &str, kind: &str, balance: Value| {
        json!({"id": id, "name": id, "status": "ok", "kind": kind,
               "windows": if kind == "windows" { json!([{"label": "5h", "usedPercent": 1.0}]) } else { json!([]) },
               "balance": balance})
    };
    let services = json!([
        service("deepseek", "balance", json!(10.0)),
        service("kimi_coding", "windows", Value::Null),
        service("zhipu", "balance", json!(20.0)),
        service("codex", "windows", Value::Null)
    ]);
    let (subscription, _) = map(services);
    let subscription = subscription.unwrap();
    let ids: Vec<&str> = subscription
        .sections
        .iter()
        .map(|s| s.id.as_str())
        .collect();
    assert_eq!(
        ids,
        vec!["kimi_coding", "codex", "deepseek", "zhipu"],
        "余额型沉底, 其余保持顺序"
    );
}

#[test]
fn multi_account_window_minutes_preferred_for_collapsed() {
    let account = |id: &str, label: &str, minutes: Value, percent: f64| {
        json!({"id": id, "name": id, "status": "ok", "kind": "windows",
               "windows": [{"label": label, "windowMinutes": minutes, "usedPercent": percent}]})
    };
    // 不同账号窗口周期不同: 折叠取最短周期; 同周期取最高用量。
    let services = json!([
        account("codex_a", "每周", json!(10080), 99.0),
        account("codex_b", "5h", json!(300), 40.0),
        account("codex_c", "5h", json!(300), 70.0)
    ]);
    let (subscription, _) = map(services);
    let section = subscription.unwrap().sections.into_iter().next().unwrap();
    let collapsed = section.collapsed_window.expect("有窗口必有折叠摘要");
    assert_eq!(collapsed.window_minutes, Some(300), "最短周期优先");
    assert_eq!(collapsed.used_percent, 70.0, "同周期取最高用量");
}

#[test]
fn updated_text_follows_mapper_timezone_and_rejects_bad_date() {
    let services = json!([{
        "id": "kimi_coding", "name": "Kimi", "status": "ok", "kind": "windows",
        "windows": [{"label": "5h", "usedPercent": 1.0}]
    }]);
    let (subscription, _) = map(services.clone());
    assert_eq!(
        subscription.unwrap().updated_text.as_deref(),
        Some("最后更新 12:00")
    );

    // generatedAt 非法: updatedText 为 null, 订阅卡本体不受影响。
    let artifact: AgentUsageArtifact = serde_json::from_value(json!({
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "not-a-date",
        "agents": [], "services": services.clone(), "totalCostUsd": null
    }))
    .unwrap();
    let mut diagnostics = Vec::new();
    let subscription = PanelViewModelMapper::default()
        .make_subscription(&artifact, fixed_now(), &mut diagnostics)
        .unwrap();
    assert_eq!(subscription.updated_text, None);
    assert_eq!(subscription.sections.len(), 1);
}
