//! 用量/热力图/月度/逐小时映射覆盖 —— 对齐 mac UsageMapping 全部规则分支
//! (LIVE 阈值边界、14 日裁剪、周网格、TopN+其他、Tier 五档)。

use chrono::{FixedOffset, TimeZone};
use collector_domain::AgentUsageArtifact;
use serde_json::json;

use bruce_win_viewmodel::models::UsageTier;
use bruce_win_viewmodel::usage::{hourly_display_name, top_distribution, PanelViewModelMapper};

fn fixed_now() -> chrono::DateTime<FixedOffset> {
    FixedOffset::east_opt(8 * 3600)
        .unwrap()
        .with_ymd_and_hms(2026, 7, 28, 12, 30, 0)
        .unwrap()
}

fn artifact_from(value: serde_json::Value) -> AgentUsageArtifact {
    serde_json::from_value(value["artifact"].clone()).expect("artifact 契约解析")
}

fn agent_with_daily(entries: &[(i64, i64)]) -> serde_json::Value {
    let daily: Vec<serde_json::Value> = entries
        .iter()
        .map(|(day_offset, total)| {
            let date = chrono::NaiveDate::from_ymd_opt(2026, 7, 1)
                .unwrap()
                .checked_add_signed(chrono::Duration::days(*day_offset))
                .unwrap()
                .format("%Y-%m-%d")
                .to_string();
            json!({"date": date, "input": total, "output": 0, "total": total})
        })
        .collect();
    json!({
        "id": "claude-code", "name": "Claude Code", "status": "ok", "note": "",
        "quota": null,
        "today": {"input": 0, "output": 0, "cacheRead": 0, "cacheCreation": 0, "total": 0},
        "daily": daily, "models": {}, "todayModels": [], "projects": [], "hours": [],
        "todayCostUsd": null
    })
}

#[test]
fn live_threshold_boundaries_inclusive() {
    let mapper = PanelViewModelMapper::default();
    // age = now - generatedAt; [‑300, 2700] 闭区间内为 LIVE。
    for (generated_at, expected) in [
        ("2026-07-28T11:45:00+08:00", true),  // age = 2700 (上界含)
        ("2026-07-28T11:44:59+08:00", false), // age = 2701
        ("2026-07-28T12:30:00+08:00", true),  // age = 0
        ("2026-07-28T12:35:00+08:00", true),  // age = -300 (下界含)
        ("2026-07-28T12:35:01+08:00", false), // age = -301
    ] {
        let artifact = artifact_from(json!({"artifact": {
            "schemaVersion": 1, "module": "agent-usage", "generatedAt": generated_at,
            "agents": [], "services": [], "totalCostUsd": null
        }}));
        let panel = mapper.make(Some(&artifact), fixed_now());
        assert_eq!(
            panel.usage.as_ref().unwrap().is_live,
            expected,
            "generatedAt={generated_at}"
        );
    }
}

#[test]
fn empty_agents_yields_dash_cache_hit_and_empty_usage_diagnostic() {
    let mapper = PanelViewModelMapper::default();
    let artifact = artifact_from(json!({"artifact": {
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-07-28T12:00:00+08:00",
        "agents": [], "services": [], "totalCostUsd": null
    }}));
    let panel = mapper.make(Some(&artifact), fixed_now());
    let usage = panel.usage.unwrap();
    assert_eq!(usage.breakdown[3].value_text, "—", "分母为 0 显示占位符");
    assert!(usage.days.is_empty());
    assert!(usage.heatmap.is_empty());
    assert!(usage.half_year.is_none());
}

#[test]
fn days_and_legend_clip_to_last_14_entries() {
    let mapper = PanelViewModelMapper::default();
    // 16 天 daily: 视图轴保留最后 14 天。
    let entries: Vec<(i64, i64)> = (0..16).map(|day| (day, 1000)).collect();
    let artifact = artifact_from(json!({"artifact": {
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-07-28T12:00:00+08:00",
        "agents": [agent_with_daily(&entries)], "services": [], "totalCostUsd": null
    }}));
    let panel = mapper.make(Some(&artifact), fixed_now());
    let usage = panel.usage.unwrap();
    assert_eq!(usage.days.len(), 14, "14 日裁剪");
    assert_eq!(usage.days[0].date, "2026-07-03", "丢弃最前 2 天");
    assert_eq!(usage.days[13].date, "2026-07-16");
    // 图例: 14 日窗口内有量即保留。
    assert_eq!(usage.legend.len(), 1);
}

#[test]
fn heatmap_spans_weeks_with_monday_grid_and_nil_padding() {
    let mapper = PanelViewModelMapper::default();
    // 2026-07-20 (周一) .. 2026-08-02 (周日) = 恰好 2 周。
    let entries: Vec<(i64, i64)> = (0..14).map(|day| (19 + day, 50_000_000)).collect();
    let artifact = artifact_from(json!({"artifact": {
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-07-28T12:00:00+08:00",
        "agents": [agent_with_daily(&entries)], "services": [], "totalCostUsd": null
    }}));
    let panel = mapper.make(Some(&artifact), fixed_now());
    let usage = panel.usage.unwrap();
    assert_eq!(usage.heatmap.len(), 2, "恰好两周");
    assert_eq!(usage.heatmap[0].cells.len(), 7);
    assert_eq!(
        usage.heatmap[0].cells[0].as_ref().unwrap().date,
        "2026-07-20"
    );
    assert_eq!(
        usage.heatmap[1].cells[6].as_ref().unwrap().date,
        "2026-08-02"
    );
    // 50M 属 1 档 (<100M)。
    assert_eq!(usage.heatmap[0].cells[0].as_ref().unwrap().level, 1);

    // 首日为周三: 第一周周一/周二为 nil。
    let entries: Vec<(i64, i64)> = (0..3).map(|day| (20 + day, 1)).collect(); // 07-21..07-23
    let artifact = artifact_from(json!({"artifact": {
        "schemaVersion": 1, "module": "agent-usage", "generatedAt": "2026-07-28T12:00:00+08:00",
        "agents": [agent_with_daily(&entries)], "services": [], "totalCostUsd": null
    }}));
    let panel = mapper.make(Some(&artifact), fixed_now());
    let usage = panel.usage.unwrap();
    let cells = &usage.heatmap[0].cells;
    assert!(cells[0].is_none(), "周一 (07-20) 窗口外");
    assert_eq!(cells[1].as_ref().unwrap().date, "2026-07-21", "首日周二");
    assert!(cells[6].is_none(), "未来日为 nil");
}

#[test]
fn usage_tier_five_level_boundaries() {
    assert_eq!(UsageTier::for_total(99_999_999), UsageTier::Sage);
    assert_eq!(UsageTier::for_total(100_000_000), UsageTier::Moss);
    assert_eq!(UsageTier::for_total(199_999_999), UsageTier::Moss);
    assert_eq!(UsageTier::for_total(200_000_000), UsageTier::Fern);
    assert_eq!(UsageTier::for_total(299_999_999), UsageTier::Fern);
    assert_eq!(UsageTier::for_total(300_000_000), UsageTier::Pine);
    assert_eq!(UsageTier::for_total(399_999_999), UsageTier::Pine);
    assert_eq!(UsageTier::for_total(400_000_000), UsageTier::Forest);
    assert_eq!(UsageTier::for_total(i64::MAX), UsageTier::Forest);
}

#[test]
fn top_distribution_limits_and_other_aggregation() {
    let entries: Vec<(String, i64)> = (0..5)
        .map(|index| (format!("m{index}"), 10 * (index + 1)))
        .collect();
    let bars = top_distribution(&entries, 150, 3);
    assert_eq!(bars.len(), 4, "Top3 + 其他");
    assert_eq!(bars[0].name, "m0");
    assert_eq!(bars[2].name, "m2");
    assert_eq!(bars[3].name, "其他");
    assert_eq!(bars[3].total, 150 - (10 + 20 + 30));
    // 分母取 max(base, entries 总和)。
    assert_eq!(bars[0].share, 10.0 / 150.0);

    let bars = top_distribution(&entries, 1000, 3);
    assert_eq!(bars[3].total, 1000 - 60, "base 大于条目和时其他为差额");

    // 零分母与空输入。
    assert!(top_distribution(&[], 0, 3).is_empty());
    assert!(top_distribution(&[("m".to_owned(), 0)], 0, 3).is_empty());
}

#[test]
fn hourly_display_name_only_overrides_kimi_code_cli() {
    assert_eq!(
        hourly_display_name("kimi-code-cli", "Kimi Code CLI"),
        "Kimi Code"
    );
    assert_eq!(hourly_display_name("codex", "Codex CLI"), "Codex CLI");
}

#[test]
fn partial_fixture_produces_consistent_usage() {
    let raw = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../tests/fixtures/artifacts/agent-usage/partial.json"
    ))
    .expect("partial fixture 可读");
    let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let artifact: AgentUsageArtifact = serde_json::from_value(value["artifact"].clone()).unwrap();
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());
    // partial 状态的 agent 必须进诊断, 不得静默吞掉。
    assert!(
        panel.diagnostics.iter().any(|diagnostic| matches!(
            diagnostic,
            bruce_win_viewmodel::models::PanelDiagnostic::AgentIssue { .. }
        )),
        "partial fixture 应产生 agentIssue 诊断"
    );
    // 视图模型内部一致性: 柱状图天数 = 日期轴裁剪结果, 热力图每周 7 格。
    let usage = panel.usage.expect("partial fixture 有用量卡");
    assert!(usage.days.len() <= 14);
    for week in &usage.heatmap {
        assert_eq!(week.cells.len(), 7);
    }
}
