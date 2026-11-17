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
    assert_eq!(usage.collapsed_summary.cache_hit_rate_text, "21%");
    assert_eq!(
        usage.collapsed_summary.day_delta_text.as_deref(),
        Some("↑45%")
    );
    assert!(!usage.collapsed_summary.day_delta_negative);
    assert_eq!(usage.collapsed_summary.cache_savings_text, None);
    assert_eq!(
        usage.collapsed_summary.month_total_text.as_deref(),
        Some("311K")
    );

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

    // 热力图 (C223): 连续 7 天块, 末格为今天 07-28, 块首 07-22 (前 5 天补 level 0)。
    assert_eq!(usage.heatmap.len(), 1);
    let cells = &usage.heatmap[0].cells;
    assert_eq!(cells.len(), 7);
    assert!(cells.iter().all(|cell| cell.is_some()), "不得有 nil 缺口");
    assert_eq!(cells[0].as_ref().unwrap().date, "2026-07-22");
    assert_eq!(cells[0].as_ref().unwrap().level, 0);
    assert_eq!(cells[5].as_ref().unwrap().date, "2026-07-27");
    assert_eq!(cells[5].as_ref().unwrap().total, 127_000);
    assert_eq!(cells[5].as_ref().unwrap().level, 1);
    assert_eq!(cells[6].as_ref().unwrap().date, "2026-07-28");
    assert_eq!(cells[6].as_ref().unwrap().total, 184_000);
    assert_eq!(cells[6].as_ref().unwrap().level, 1);

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
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(key, value)| (key, norm(value)))
                .collect(),
        ),
        other => other,
    }
}

/// 双端对拍锁: golden 快照由 mac 侧 PanelParityHarness 生成 (swift run
/// PanelParityHarness <repoRoot> --update)。mac 行为变更时先刷新 golden,
/// 本测试随之锁住 Windows 侧行为必须同步对齐。
#[test]
fn mac_parity_golden_matches() {
    for name in ["valid", "partial", "empty"] {
        let golden_path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(format!(
            "../../../tests/fixtures/viewmodel-parity/agent-usage-{name}.panel.json"
        ));
        let golden_raw = std::fs::read_to_string(&golden_path).expect("mac golden 快照可读");
        let golden: serde_json::Value =
            serde_json::from_str(&golden_raw).expect("golden JSON 合法");
        let raw = std::fs::read_to_string(fixture_path(&format!("{name}.json"))).unwrap();
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let artifact: AgentUsageArtifact =
            serde_json::from_value(value["artifact"].clone()).unwrap();
        let panel = PanelViewModelMapper::default().make(Some(&artifact), fixed_now());
        let produced = serde_json::to_value(&panel).unwrap();
        assert_eq!(
            norm(produced),
            norm(golden),
            "{name}: rust 输出必须与 mac golden 逐字段一致"
        );
    }
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
        "collapsedSummary",
    ] {
        assert!(usage.get(key).is_some(), "缺少契约字段 {key}");
    }
    let summary = &usage["collapsedSummary"];
    for key in [
        "cacheHitRateText",
        "dayDeltaText",
        "dayDeltaNegative",
        "cacheSavingsText",
        "monthTotalText",
    ] {
        assert!(
            summary.get(key).is_some(),
            "collapsedSummary 缺少字段 {key}"
        );
    }
    let diagnostic = &value["diagnostics"][0];
    assert_eq!(diagnostic["kind"], "agentIssue");
    assert_eq!(diagnostic["agentId"], "claude-code");
}

#[test]
fn collapsed_summary_handles_delta_cap_savings_and_missing_fallbacks() {
    let base = load_valid_artifact();
    let mapper = PanelViewModelMapper::default();

    // 1. 下降 / 持平 / >999% 封顶 + 今日 dailyModels 省费累加 (昨日不计入)
    let mut down = base.clone();
    down.agents.truncate(1);
    down.agents[0].today.total = 64;
    down.agents[0].daily = vec![collector_domain::DailyUsage {
        date: "2026-07-27".to_owned(),
        input: 100,
        output: 0,
        cache_read: 0,
        cache_creation: 0,
        total: 100,
    }];
    down.agents[0].daily_models = vec![
        collector_domain::DailyModelUsage {
            date: "2026-07-28".to_owned(),
            model: "claude-sonnet".to_owned(),
            tokens: collector_domain::TokenBucket::default(),
            cost_usd: None,
            cache_savings_usd: Some(0.5),
        },
        collector_domain::DailyModelUsage {
            date: "2026-07-27".to_owned(),
            model: "claude-sonnet".to_owned(),
            tokens: collector_domain::TokenBucket::default(),
            cost_usd: None,
            cache_savings_usd: Some(9.0),
        },
    ];
    let down_summary = mapper
        .make(Some(&down), fixed_now())
        .usage
        .unwrap()
        .collapsed_summary;
    assert_eq!(down_summary.day_delta_text.as_deref(), Some("↓36%"));
    assert!(down_summary.day_delta_negative);
    assert_eq!(down_summary.cache_savings_text.as_deref(), Some("¥3.60"));

    // 2. 持平 & 超 999% 封顶 & 极小省费归零不展示
    let mut capped = down.clone();
    capped.agents[0].today.total = 2_500;
    capped.agents[0].daily_models[0].cache_savings_usd = Some(0.00001);
    let capped_summary = mapper
        .make(Some(&capped), fixed_now())
        .usage
        .unwrap()
        .collapsed_summary;
    assert_eq!(capped_summary.day_delta_text.as_deref(), Some("↑999%+"));
    assert!(!capped_summary.day_delta_negative);
    assert_eq!(capped_summary.cache_savings_text, None);

    let mut flat = down;
    flat.agents[0].today.total = 100;
    let flat_summary = mapper
        .make(Some(&flat), fixed_now())
        .usage
        .unwrap()
        .collapsed_summary;
    assert_eq!(flat_summary.day_delta_text.as_deref(), Some("持平"));
    assert!(!flat_summary.day_delta_negative);
}

/// C240: 「本月」只取 now 所在本地月份的累计; 当月尚无数据 (数据止于上月) 或跨年时为 None,
/// 不能把上一个有数据月份的整月总量标成「本月」 (与 Swift collapsedMonthTotalRequiresCurrentMonth 对拍)。
#[test]
fn collapsed_month_total_requires_current_month() {
    let mapper = PanelViewModelMapper::default();
    let month_total = |now: chrono::DateTime<FixedOffset>, days: &[(&str, u64)]| {
        let mut artifact = load_valid_artifact();
        artifact.agents.truncate(1);
        artifact.agents[0].daily = days
            .iter()
            .map(|(date, total)| collector_domain::DailyUsage {
                date: (*date).to_owned(),
                input: *total,
                output: 0,
                cache_read: 0,
                cache_creation: 0,
                total: *total,
            })
            .collect();
        mapper
            .make(Some(&artifact), now)
            .usage
            .unwrap()
            .collapsed_summary
            .month_total_text
    };
    let utc = FixedOffset::east_opt(0).unwrap();
    assert_eq!(
        month_total(
            utc.with_ymd_and_hms(2026, 12, 1, 9, 0, 0).unwrap(),
            &[("2026-11-20", 300_000), ("2026-11-30", 11_000)]
        ),
        None,
        "当月无数据时不得把 11 月总量标成本月"
    );
    assert_eq!(
        month_total(
            utc.with_ymd_and_hms(2026, 11, 30, 9, 0, 0).unwrap(),
            &[("2026-10-31", 900_000), ("2026-11-30", 11_000)]
        )
        .as_deref(),
        Some("11K"),
        "当月有数据取当月累计"
    );
    assert_eq!(
        month_total(
            utc.with_ymd_and_hms(2027, 1, 2, 9, 0, 0).unwrap(),
            &[("2026-12-31", 4_000)]
        ),
        None,
        "跨年: 数据止于 12 月、now 为 1 月时省略"
    );
}
