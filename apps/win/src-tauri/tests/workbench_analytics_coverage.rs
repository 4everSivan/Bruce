//! 设置页「Agent 用量」工作台 (C070): 快照门控与 CSV 导出列契约。
//! 计算本身由 viewmodel `analytics_parity` 对 mac golden 锁定, 这里只测 Tauri 侧的薄封装。

use bruce_win_lib::runtime_core::{usage_analytics, workbench_csv};
use bruce_win_viewmodel::analytics::AnalyticsRange;
use serde_json::Value;

fn workbench_artifact() -> Value {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../../tests/fixtures/artifacts/agent-usage/workbench.json");
    let raw = std::fs::read_to_string(path).expect("fixture 可读");
    serde_json::from_str::<Value>(&raw).expect("fixture JSON")["artifact"].clone()
}

#[test]
fn analytics_follow_the_same_usage_switch_as_the_dashboard() {
    let artifact = workbench_artifact();
    let live = usage_analytics(Some(&artifact), true, AnalyticsRange::SevenDays);
    assert!(live.kpi.total_tokens > 0);
    assert!(live.kpi.total_cost_usd.is_some());

    // 关闭本机会话读取 / 尚无快照: 空快照而非残留数据
    for snapshot in [
        usage_analytics(Some(&artifact), false, AnalyticsRange::SevenDays),
        usage_analytics(None, true, AnalyticsRange::SevenDays),
    ] {
        assert_eq!(snapshot.kpi.total_tokens, 0);
        assert_eq!(snapshot.kpi.cost_text, "—");
        assert!(snapshot.models.is_empty() && snapshot.agents.is_empty());
        assert_eq!(snapshot.range, "7d");
    }
}

#[test]
fn workbench_csv_lists_canonical_models_and_leaves_unpriced_cost_blank() {
    let snapshot = usage_analytics(Some(&workbench_artifact()), true, AnalyticsRange::AllTime);
    let csv = workbench_csv(&snapshot).expect("有模型明细");
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(
        lines[0],
        "CanonicalModel,Vendor,TotalTokens,EstimatedCostUSD,SharePercent,SourceCount"
    );
    assert_eq!(lines.len(), snapshot.models.len() + 1);
    let top = &snapshot.models[0];
    assert_eq!(
        lines[1],
        format!(
            "\"{}\",\"{}\",{},{:.4},{:.2},{}",
            top.display_name,
            top.vendor,
            top.total_tokens,
            top.cost_usd.unwrap(),
            top.share_percent,
            top.sources.len()
        )
    );
    let unpriced = lines
        .iter()
        .find(|line| line.starts_with("\"deepseek-flash\""))
        .expect("未定价模型在列");
    assert_eq!(unpriced.split(',').nth(3), Some(""), "未定价费用列留空");

    // 无明细 (旧 artifact / 无用量) 不导出空表
    assert!(workbench_csv(&usage_analytics(None, true, AnalyticsRange::Today)).is_none());
}
