//! fixture 对拍测试: 共享 artifact fixture (tests/fixtures) 输入下,
//! Rust 视图模型输出与手工推导的 mac 语义期望逐字段一致。
//!
//! mac 侧 Parity Harness 落地后, 本文件的期望值将由 Swift Harness 的
//! 真实输出快照替代; 字段名契约 (camelCase JSON) 双端一致。

use std::path::PathBuf;

use bruce_win_viewmodel::models::PanelDiagnostic;
use bruce_win_viewmodel::usage::PanelViewModelMapper;
use chrono::{FixedOffset, TimeZone};
use collector_domain::AgentUsageArtifact;

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/fixtures/artifacts/agent-usage")
        .join(name)
}

fn load_valid_artifact() -> AgentUsageArtifact {
    let raw = std::fs::read_to_string(fixture_path("valid.json")).expect("fixture 可读");
    let value: serde_json::Value = serde_json::from_str(&raw).expect("fixture JSON 合法");
    serde_json::from_value(value["artifact"].clone()).expect("artifact 契约解析")
}

fn fixed_now() -> chrono::DateTime<FixedOffset> {
    // 2026-07-28T12:30:00+08:00 (generatedAt 之后 30 分钟, 处于 LIVE 阈值内)
    FixedOffset::east_opt(8 * 3600)
        .unwrap()
        .with_ymd_and_hms(2026, 7, 28, 12, 30, 0)
        .unwrap()
}

#[test]
fn usage_hero_matches_mac_semantics_on_valid_fixture() {
    let artifact = load_valid_artifact();
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());

    // 诊断: claude-code not_found 必须上报, 不得静默吞掉。
    assert_eq!(
        panel.diagnostics,
        vec![PanelDiagnostic::AgentIssue {
            agent_id: "claude-code".to_owned(),
            status: "not_found".to_owned(),
            note: "fixture: 未发现会话".to_owned(),
        }]
    );

    let usage = panel.usage.expect("valid fixture 必有用量卡");
    assert_eq!(usage.total_tokens, 184_000);
    assert_eq!(usage.total_tokens_text, "184K");
    assert_eq!(usage.cost_text.as_deref(), Some("≈ ¥2.702"));
    assert!(usage.is_live);
    assert_eq!(usage.usage_tier, "sage");
    assert_eq!(usage.collapsed_week_levels, vec![1, 1]);

    // 四格 breakdown (数值 + 文案)。
    let texts: Vec<&str> = usage
        .breakdown
        .iter()
        .map(|item| item.value_text.as_str())
        .collect();
    assert_eq!(texts, vec!["125K", "25K", "34K", "21%"]);
    assert_eq!(usage.breakdown[0].value, 125_000);
    assert_eq!(usage.breakdown[3].value, 0, "命中率格为文本型, value 占位");

    // 14 日堆叠柱: 两天, 分段按 artifact agent 顺序, 零量 agent 不出段。
    assert_eq!(usage.days.len(), 2);
    assert_eq!(usage.days[0].date, "2026-07-27");
    assert_eq!(usage.days[0].total, 127_000);
    assert_eq!(usage.days[0].total_text, "127K");
    assert_eq!(usage.days[0].segments.len(), 2);
    assert_eq!(usage.days[0].segments[0].agent_id, "kimi-code-cli");
    assert_eq!(usage.days[0].segments[0].color, "blue");
    assert_eq!(usage.days[0].segments[1].agent_id, "codex");
    assert_eq!(usage.days[1].total, 184_000);
    assert_eq!(usage.days[1].segments.len(), 2);

    // 图例: 有量的 agent, artifact 顺序。
    assert_eq!(usage.legend.len(), 2);
    assert_eq!(usage.legend[0].agent_id, "kimi-code-cli");
    assert_eq!(usage.legend[0].name, "Kimi Code CLI");
    assert_eq!(usage.legend[1].agent_id, "codex");

    // 热力图: 2026-07-27 是周一, 网格恰好 1 周, 周三起为窗口外 null。
    assert_eq!(usage.heatmap.len(), 1);
    let cells = &usage.heatmap[0].cells;
    assert_eq!(cells.len(), 7);
    assert_eq!(cells[0].as_ref().unwrap().date, "2026-07-27");
    assert_eq!(cells[0].as_ref().unwrap().total, 127_000);
    assert_eq!(cells[0].as_ref().unwrap().level, 1);
    assert_eq!(cells[1].as_ref().unwrap().total, 184_000);
    assert!(cells[2].is_none());
    assert!(cells[6].is_none());

    // 按月聚合: 单月, 当月标记, 半年汇总月均整除。
    assert_eq!(usage.monthly.len(), 1);
    assert_eq!(usage.monthly[0].label, "7月");
    assert_eq!(usage.monthly[0].total_text, "311K");
    assert!(usage.monthly[0].is_current);
    assert_eq!(usage.monthly[0].key, "2026-07");
    let half_year = usage.half_year.as_ref().unwrap();
    assert_eq!(half_year.total_text, "311K");
    assert_eq!(half_year.average_text, "311K");

    // 旧版 fixture 无 modelMonths: 模型用量区块隐藏。
    assert!(usage.models.is_none());
}

#[test]
fn hourly_matches_mac_semantics_on_valid_fixture() {
    let artifact = load_valid_artifact();
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());
    let hourly = panel.hourly.expect("valid fixture 必有逐小时卡");

    // 只显示今日有量的 agent, 按今日用量降序。
    assert_eq!(hourly.rows.len(), 2);
    assert_eq!(hourly.rows[0].agent_id, "kimi-code-cli");
    assert_eq!(hourly.rows[0].name, "Kimi Code", "显示层覆盖 kimi-code-cli");
    assert_eq!(hourly.rows[0].today_total, 124_000);
    assert_eq!(hourly.rows[0].today_total_text, "124K");
    assert_eq!(hourly.rows[1].agent_id, "codex");
    assert_eq!(hourly.rows[1].name, "Codex CLI");

    // 模型占比: Top 3 + 其他 (单模型份额 1.0)。
    let kimi_models = &hourly.rows[0].models;
    assert_eq!(kimi_models.len(), 1);
    assert_eq!(kimi_models[0].name, "kimi-k2.5");
    assert_eq!(kimi_models[0].total_text, "124K");
    assert_eq!(kimi_models[0].share, 1.0);

    // 项目分布: artifact 顺序 Top 3, 无其他 (总和恰为今日总量)。
    let kimi_projects = &hourly.rows[0].projects;
    assert_eq!(kimi_projects.len(), 2);
    assert_eq!(kimi_projects[0].name, "fixture/project-a");
    assert_eq!(kimi_projects[0].share, 92_000f64 / 124_000f64);
    assert_eq!(kimi_projects[1].name, "fixture/project-b");
    assert_eq!(kimi_projects[1].share, 32_000f64 / 124_000f64);

    assert!(hourly.rows[0].is_expandable);
    assert!(!hourly.rows[1].projects.is_empty());

    // 收起态: 全 agent 逐小时合计 24 点 + 峰值文案。
    assert_eq!(hourly.collapsed_points.len(), 24);
    assert_eq!(hourly.collapsed_points[8], 12_000);
    assert_eq!(hourly.collapsed_points[9], 22_000);
    assert_eq!(hourly.collapsed_points[10], 59_000, "41000 + 18000");
    assert_eq!(hourly.collapsed_points[11], 71_000, "49000 + 22000");
    assert_eq!(hourly.collapsed_points[12], 20_000);
    assert_eq!(hourly.collapsed_peak_text, "峰值 71K");
}

#[test]
fn empty_fixture_yields_empty_usage_agents_diagnostic() {
    let raw = std::fs::read_to_string(fixture_path("empty.json")).expect("fixture 可读");
    let value: serde_json::Value = serde_json::from_str(&raw).expect("fixture JSON 合法");
    let artifact: AgentUsageArtifact = serde_json::from_value(value["artifact"].clone()).unwrap();

    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());
    assert!(
        panel
            .diagnostics
            .iter()
            .any(|diagnostic| matches!(diagnostic, PanelDiagnostic::EmptyUsageAgents)),
        "agents 为空必须产生 emptyUsageAgents 诊断"
    );
}

#[test]
fn missing_artifact_reports_missing_artifact_diagnostic() {
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(None, fixed_now());
    assert_eq!(
        panel.diagnostics,
        vec![PanelDiagnostic::MissingArtifact {
            module: "agentUsage".to_owned(),
        }]
    );
    assert!(panel.usage.is_none());
    assert!(panel.hourly.is_none());
    assert!(panel.subscription.is_none());
}

/// 数值归一化: JSON 整数与浮点按 f64 语义比较 (mac JSONEncoder 把 1.0 序列化为 1,
/// serde_json 为 1.0, 数值上等价), 其余类型保持严格相等。
fn norm(value: serde_json::Value) -> serde_json::Value {
    use serde_json::Value;
    match value {
        Value::Number(number) => serde_json::json!(number.as_f64().unwrap()),
        Value::Array(items) => Value::Array(items.into_iter().map(norm).collect()),
        Value::Object(map) => Value::Object(map.into_iter().map(|(key, value)| (key, norm(value))).collect()),
        other => other,
    }
}

/// 双端对拍锁: golden 快照由 mac 侧 PanelParityHarness 生成 (swift run
/// PanelParityHarness <repoRoot> --update)。mac 行为变更时先刷新 golden,
/// 本测试随之锁住 Windows 侧行为必须同步对齐。
#[test]
fn mac_parity_golden_matches() {
    let golden_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/fixtures/viewmodel-parity/agent-usage-valid.panel.json");
    let golden_raw = std::fs::read_to_string(golden_path).expect("golden 快照可读");
    let golden: serde_json::Value = serde_json::from_str(&golden_raw).expect("golden JSON 合法");

    let artifact = load_valid_artifact();
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());
    let produced = serde_json::to_value(&panel).expect("视图模型可序列化");

    assert_eq!(
        norm(produced),
        norm(golden),
        "rust 视图模型输出必须与 mac golden 逐字段一致"
    );
}

#[test]
fn serialized_view_model_uses_camel_case_contract() {
    let artifact = load_valid_artifact();
    let mapper = PanelViewModelMapper::default();
    let panel = mapper.make(Some(&artifact), fixed_now());
    let value = serde_json::to_value(&panel).unwrap();

    let usage = &value["usage"];
    for key in [
        "totalTokens",
        "totalTokensText",
        "costText",
        "breakdown",
        "isLive",
        "halfYear",
        "usageTier",
        "collapsedWeekLevels",
    ] {
        assert!(usage.get(key).is_some(), "缺少契约字段 {key}");
    }
    let diagnostic = &value["diagnostics"][0];
    assert_eq!(diagnostic["kind"], "agentIssue");
    assert_eq!(diagnostic["agentId"], "claude-code");
}
