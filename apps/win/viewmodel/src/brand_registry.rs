//! 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
//!
//! 唯一事实源: `config/brand-registry.json`。修改后运行
//! `node scripts/gen-brand-registry.mjs`; verify-local 以 `--check` 拦截漂移。

/// 注册表版本 (与 JSON `schemaVersion` 一致)。
pub const SCHEMA_VERSION: u32 = 1;

/// Nothing 深色档 (亮→暗)。
pub const NOTHING_RAMP_DARK: [&str; 5] = ["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"];

/// Nothing 浅色档 (杏色, 深→浅)。
pub const NOTHING_RAMP_LIGHT: [&str; 5] = ["#946A08", "#B8860B", "#D4A843", "#E3BE6B", "#F0D69A"];

/// 已知 agent 的固定档位; 未知 agent 由调用方用 FNV-1a 散列落档。
pub fn nothing_agent_tier(agent_id: &str) -> Option<usize> {
    match agent_id {
        "antigravity" => Some(3),
        "claude-code" => Some(1),
        "codebuddy" => Some(2),
        "codex" => Some(2),
        "dsh" => Some(1),
        "grok" => Some(2),
        "kimi-code-cli" => Some(0),
        "kimi-work" => Some(4),
        "opencode" => Some(4),
        "pi" => Some(4),
        "zcode" => Some(3),
        _ => None,
    }
}
