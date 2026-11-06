//! 双端共享 fixture: `tests/fixtures/quota-alert-state-parity/cases.json` (T31)。
//!
//! Windows 宿主适配层必须与 collector-policy / mac 对同一序列输出一致的
//! state / events; 本测试是双端对拍的 Windows 侧裁判。

use bruce_win_lib::alerts::{decide, AlertState};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Fixture {
    version: u32,
    cases: Vec<Case>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    name: String,
    deliverable: bool,
    #[serde(default)]
    previous_state: Option<AlertState>,
    steps: Vec<Step>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Step {
    now_ms: i64,
    services: Vec<Value>,
    expected: Expected,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Expected {
    event_tiers: Vec<u32>,
    delivered_tier: u32,
    window_id: String,
}

#[test]
fn alert_state_machine_matches_shared_fixture() {
    let fixture: Fixture = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../tests/fixtures/quota-alert-state-parity/cases.json"
    )))
    .expect("fixture json");
    assert_eq!(fixture.version, 1);

    for case in fixture.cases {
        let mut state = case.previous_state;
        for (index, step) in case.steps.iter().enumerate() {
            let (next, alerts) = decide(
                &json!({"services": step.services}),
                state,
                case.deliverable,
                None,
                step.now_ms,
            );
            let tiers: Vec<u32> = alerts.iter().map(|alert| alert.tier).collect();
            assert_eq!(
                tiers, step.expected.event_tiers,
                "case {} step {} event tiers",
                case.name, index
            );
            let key = alerts
                .first()
                .map(|alert| format!("{}|five_hour", alert.service_id))
                .or_else(|| next.windows.keys().next().cloned())
                .expect("state key");
            let entry = &next.windows[&key];
            assert_eq!(
                u32::from(entry.delivered_tier),
                step.expected.delivered_tier,
                "case {} step {} deliveredTier",
                case.name,
                index
            );
            assert_eq!(
                entry.window_id, step.expected.window_id,
                "case {} step {} windowId",
                case.name, index
            );
            state = Some(next);
        }
    }
}
