//! 共享 fixture: `tests/fixtures/quota-alert-state-parity/cases.json` (T29)。
//!
//! mac RefreshSchedulerHarness 与 Windows 测试消费同一份 cases; 本测试锁定
//! collector-policy 的状态机输出, 作为双端对拍的裁判基线。

use collector_policy::alerts::{decide, AlertState};
use serde::Deserialize;
use serde_json::Value;

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
    event_tiers: Vec<u8>,
    delivered_tier: u8,
    window_id: String,
}

#[test]
fn alert_state_machine_matches_shared_fixture() {
    let fixture: Fixture = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../../tests/fixtures/quota-alert-state-parity/cases.json"
    )))
    .expect("fixture json");
    assert_eq!(fixture.version, 1);

    for case in fixture.cases {
        let mut state = case.previous_state;
        for (index, step) in case.steps.iter().enumerate() {
            let (next, events) = decide(&step.services, state, case.deliverable, None, step.now_ms);
            let tiers: Vec<u8> = events.iter().map(|event| event.tier).collect();
            assert_eq!(
                tiers, step.expected.event_tiers,
                "case {} step {} event tiers",
                case.name, index
            );
            let key = events
                .first()
                .map(|event| event.key.clone())
                .or_else(|| {
                    next.windows
                        .keys()
                        .find(|key| key.ends_with("|five_hour"))
                        .cloned()
                })
                .expect("state key");
            let entry = &next.windows[&key];
            assert_eq!(
                entry.delivered_tier, step.expected.delivered_tier,
                "case {} step {} deliveredTier",
                case.name, index
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
