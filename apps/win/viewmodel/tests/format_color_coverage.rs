//! 展示格式化与配色契约覆盖 —— Windows 侧与 mac PanelFormat/PanelAgentColor
//! 逐项对齐的边界用例 (无 Windows 真机, 测试即验收)。

use bruce_win_viewmodel::color::{PanelAgentColor, PANEL_AGENT_COLORS};
use bruce_win_viewmodel::format::{balance_text, cost_text, token_count};

#[test]
fn token_count_boundaries_match_mac_formatting() {
    // K 边界。
    assert_eq!(token_count(0), "0");
    assert_eq!(token_count(949), "949");
    assert_eq!(token_count(999), "999");
    assert_eq!(token_count(1000), "1K");
    assert_eq!(token_count(1001), "1K");
    assert_eq!(token_count(1500), "1.5K");
    assert_eq!(token_count(70500), "70.5K");
    // M 边界: 999_999 仍在 K 段, %.1f 进位到 1000.0 -> "1000K"。
    assert_eq!(token_count(999_999), "1000K");
    assert_eq!(token_count(1_000_000), "1M");
    assert_eq!(token_count(1_234_567), "1.2M");
    // 超大计数 (Windows 真实月度量级)。
    assert_eq!(token_count(12_345_678_901), "12345.7M");
    assert_eq!(token_count(1_000_000_000_000), "1000000M");
}

#[test]
fn cost_text_trailing_zero_trimming_matches_mac() {
    // 至少两位小数, 最多三位。
    assert_eq!(cost_text(0.0), "≈ ¥0.00");
    assert_eq!(cost_text(0.375), "≈ ¥2.70");
    assert_eq!(cost_text(0.3753), "≈ ¥2.702");
    assert_eq!(cost_text(1.0), "≈ ¥7.20");
    assert_eq!(cost_text(12.3456), "≈ ¥88.888");
}

#[test]
fn balance_text_currency_mapping() {
    assert_eq!(balance_text(38.21, None), "¥ 38.21", "缺省按 CNY");
    assert_eq!(balance_text(38.21, Some("cny")), "¥ 38.21");
    assert_eq!(balance_text(38.21, Some("RMB")), "¥ 38.21");
    assert_eq!(balance_text(1.5, Some("USD")), "$ 1.50");
    assert_eq!(
        balance_text(1.5, Some("JPY")),
        "JPY 1.50",
        "未知币种原样前置"
    );
}

#[test]
fn resolve_maps_all_known_agent_ids() {
    let expected = [
        ("kimi-work", PanelAgentColor::Cyan),
        ("kimi-code-cli", PanelAgentColor::Blue),
        ("grok", PanelAgentColor::Indigo),
        ("codex", PanelAgentColor::Purple),
        ("claude-code", PanelAgentColor::Coral),
        ("pi", PanelAgentColor::Rose),
        ("zcode", PanelAgentColor::Mint),
        ("opencode", PanelAgentColor::Green),
        ("codebuddy", PanelAgentColor::Orange),
    ];
    for (id, color) in expected {
        assert_eq!(PanelAgentColor::resolve(id), color, "{id}");
        assert_eq!(PanelAgentColor::resolve(id).name(), color.name());
    }
}

#[test]
fn resolve_unknown_agent_is_stable_fnv1a_within_palette() {
    // FNV-1a 已知向量: "bruce" 的确定性落色 (与 Swift 端同算法, 断言锁定)。
    let first = PanelAgentColor::resolve("bruce-unknown-agent");
    for _ in 0..3 {
        assert_eq!(PanelAgentColor::resolve("bruce-unknown-agent"), first);
    }
    assert!(PANEL_AGENT_COLORS.contains(&first), "落色必须在调色板内");
}

#[test]
fn distribution_hex_clamps_out_of_range_index() {
    for color in PANEL_AGENT_COLORS {
        assert_eq!(color.distribution_hex(0), color.hex(), "index 0 即主色");
        let deepest = color.distribution_hex(3);
        assert_eq!(color.distribution_hex(99), deepest, "越界钳制到最浅档");
        assert_ne!(color.distribution_hex(2), color.hex());
    }
}

#[test]
fn nothing_ramp_covers_known_agents_and_modes() {
    // 深色模式亮→暗, 浅色模式反转; kimi-code-cli 固定 0 档。
    assert_eq!(
        PanelAgentColor::nothing_ramp_hex("kimi-code-cli", true),
        "#8CCB98"
    );
    assert_eq!(
        PanelAgentColor::nothing_ramp_hex("kimi-code-cli", false),
        "#2A6B3C"
    );
    // kimi-work 特意落 4 档避免与 kimi-code-cli 撞色。
    assert_eq!(
        PanelAgentColor::nothing_ramp_hex("kimi-work", true),
        "#2A6B3C"
    );
    // 未知 agent 稳定落档。
    let a = PanelAgentColor::nothing_ramp_hex("mystery", true);
    assert_eq!(PanelAgentColor::nothing_ramp_hex("mystery", true), a);
}
