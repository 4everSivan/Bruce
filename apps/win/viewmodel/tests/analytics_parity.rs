//! 工作台分析双端对拍 (C070): golden 由 mac `PanelParityHarness` 生成
//! (`swift run PanelParityHarness <repoRoot> --update`), 本测试锁住 Windows 侧
//! `analytics::make` 对同一 artifact、全部 5 个时间范围逐字段 (含浮点位) 一致。

use std::path::PathBuf;

use bruce_win_viewmodel::analytics::{self, AnalyticsRange};
use serde_json::Value;

fn repo_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .join(relative)
}

fn read_json(relative: &str) -> Value {
    let raw = std::fs::read_to_string(repo_path(relative)).expect("fixture 可读");
    serde_json::from_str(&raw).expect("fixture JSON 合法")
}

/// 结构化比对并记录路径: 数值按 f64 精确相等 (mac 把 1.0 写成 1, serde_json 写成 1.0),
/// 其余类型严格相等。
fn diff(produced: &Value, golden: &Value, path: &str, errors: &mut Vec<String>) {
    match (produced, golden) {
        (Value::Object(left), Value::Object(right)) => {
            for key in left.keys().filter(|key| !right.contains_key(*key)) {
                errors.push(format!("{path}.{key}: rust 有而 golden 无"));
            }
            for key in right.keys().filter(|key| !left.contains_key(*key)) {
                errors.push(format!("{path}.{key}: golden 有而 rust 无"));
            }
            for (key, value) in left {
                if let Some(other) = right.get(key) {
                    diff(value, other, &format!("{path}.{key}"), errors);
                }
            }
        }
        (Value::Array(left), Value::Array(right)) => {
            if left.len() != right.len() {
                errors.push(format!(
                    "{path}: 数组长度 rust={} golden={}",
                    left.len(),
                    right.len()
                ));
                return;
            }
            for (index, (value, other)) in left.iter().zip(right).enumerate() {
                diff(value, other, &format!("{path}[{index}]"), errors);
            }
        }
        (Value::Number(left), Value::Number(right)) => {
            if left.as_f64() != right.as_f64() {
                errors.push(format!("{path}: 数值 rust={left} golden={right}"));
            }
        }
        (left, right) if left != right => {
            errors.push(format!("{path}: rust={left} golden={right}"));
        }
        _ => {}
    }
}

fn assert_matches_golden(name: &str) {
    let fixture = read_json(&format!("tests/fixtures/artifacts/agent-usage/{name}.json"));
    let golden = read_json(&format!(
        "tests/fixtures/viewmodel-parity/agent-usage-{name}.analytics.json"
    ));
    let produced = Value::Array(
        AnalyticsRange::ALL
            .into_iter()
            .map(|range| {
                serde_json::to_value(analytics::make(&fixture["artifact"], range)).unwrap()
            })
            .collect(),
    );
    let mut errors = Vec::new();
    diff(&produced, &golden, "$", &mut errors);
    assert!(
        errors.is_empty(),
        "{name}: rust 工作台分析与 mac golden 有 {} 处差异:\n{}",
        errors.len(),
        errors
            .iter()
            .take(20)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}

/// 新版 artifact: 含逐日 / 逐月 / 今日逐小时 × 模型明细与采集端计价。
#[test]
fn workbench_fixture_matches_mac_golden_for_every_range() {
    assert_matches_golden("workbench");
}

/// 旧版 artifact (无明细、无缓存拆分): 费用与缓存相关指标必须同为「—」。
#[test]
fn legacy_fixture_matches_mac_golden_for_every_range() {
    assert_matches_golden("valid");
}

/// golden 本身须覆盖关键分支, 防止 fixture 退化后对拍形同虚设。
#[test]
fn golden_exercises_the_branches_it_locks() {
    let golden = read_json("tests/fixtures/viewmodel-parity/agent-usage-workbench.analytics.json");
    let ranges: Vec<&str> = golden
        .as_array()
        .unwrap()
        .iter()
        .map(|snapshot| snapshot["range"].as_str().unwrap())
        .collect();
    assert_eq!(ranges, ["today", "7d", "30d", "month", "all"]);
    let all = &golden[4];
    assert_eq!(all["timeline"]["granularity"], "month");
    assert!(
        all["timeline"]["points"].as_array().unwrap().len() >= 2,
        "跨月"
    );
    assert!(
        all["kpi"]["unpricedTokens"].as_i64().unwrap() > 0,
        "含未定价模型"
    );
    let models = all["models"].as_array().unwrap();
    assert!(
        models
            .iter()
            .any(|model| model["sources"].as_array().unwrap().len() > 1),
        "含跨渠道 / 跨 Agent 归并"
    );
    let legacy = read_json("tests/fixtures/viewmodel-parity/agent-usage-valid.analytics.json");
    assert_eq!(legacy[1]["kpi"]["costText"], "—");
    assert_eq!(legacy[1]["kpi"]["cacheHitRateText"], "—");
}
