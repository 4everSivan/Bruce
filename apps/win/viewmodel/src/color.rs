//! 面板 agent 配色 —— 对齐 mac `PanelModels.swift` 的 `PanelAgentColor`。

/// 冷色→暖色相邻渐变调色板 (堆叠柱与图例连续感); 色值与 Swift 端逐项一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PanelAgentColor {
    Cyan,
    Blue,
    Indigo,
    Purple,
    Coral,
    Mint,
    Rose,
    Green,
    Orange,
}

pub const PANEL_AGENT_COLORS: [PanelAgentColor; 9] = [
    PanelAgentColor::Cyan,
    PanelAgentColor::Blue,
    PanelAgentColor::Indigo,
    PanelAgentColor::Purple,
    PanelAgentColor::Coral,
    PanelAgentColor::Mint,
    PanelAgentColor::Rose,
    PanelAgentColor::Green,
    PanelAgentColor::Orange,
];

impl PanelAgentColor {
    pub fn name(&self) -> &'static str {
        match self {
            PanelAgentColor::Cyan => "cyan",
            PanelAgentColor::Blue => "blue",
            PanelAgentColor::Indigo => "indigo",
            PanelAgentColor::Purple => "purple",
            PanelAgentColor::Coral => "coral",
            PanelAgentColor::Mint => "mint",
            PanelAgentColor::Rose => "rose",
            PanelAgentColor::Green => "green",
            PanelAgentColor::Orange => "orange",
        }
    }

    pub fn hex(&self) -> &'static str {
        match self {
            PanelAgentColor::Cyan => "#5ac8fa",
            PanelAgentColor::Blue => "#0a84ff",
            PanelAgentColor::Indigo => "#6c63ff",
            PanelAgentColor::Purple => "#bf5af2",
            PanelAgentColor::Coral => "#ff7a59",
            PanelAgentColor::Mint => "#40c8e0",
            PanelAgentColor::Rose => "#ff6482",
            PanelAgentColor::Green => "#30d158",
            PanelAgentColor::Orange => "#ff9f0a",
        }
    }

    /// 同 agent 内模型/项目占比条的相邻色阶 (主色 → 中亮 → 浅 → 极浅)。
    pub fn distribution_hex(&self, index: usize) -> &'static str {
        let shades: &[&str] = match self {
            PanelAgentColor::Cyan => &["#5ac8fa", "#7dd4fb", "#a6e2fc", "#c8edfd"],
            PanelAgentColor::Blue => &["#0a84ff", "#3d9fff", "#70b8ff", "#a3d0ff"],
            PanelAgentColor::Indigo => &["#6c63ff", "#8b84ff", "#aaa5ff", "#c9c6ff"],
            PanelAgentColor::Purple => &["#bf5af2", "#cd7cf5", "#db9ef8", "#e9c0fb"],
            PanelAgentColor::Coral => &["#ff7a59", "#ff9580", "#ffb0a6", "#ffcbcb"],
            PanelAgentColor::Mint => &["#40c8e0", "#66d4e6", "#8cdfed", "#b2ebf3"],
            PanelAgentColor::Rose => &["#ff6482", "#ff839c", "#ffa2b6", "#ffc1d0"],
            PanelAgentColor::Green => &["#30d158", "#5bda7f", "#8ae6a6", "#b8f1cc"],
            PanelAgentColor::Orange => &["#ff9f0a", "#ffb340", "#ffcc7a", "#ffe5b3"],
        };
        let clamped = index.min(shades.len() - 1);
        shades[clamped]
    }

    /// 已知 agent 固定配色 (冷→暖); 未知 agent 用 FNV-1a 散列稳定落到调色板。
    pub fn resolve(agent_id: &str) -> Self {
        match agent_id {
            "kimi-work" => PanelAgentColor::Cyan,
            "kimi-code-cli" => PanelAgentColor::Blue,
            "grok" => PanelAgentColor::Indigo,
            "codex" => PanelAgentColor::Purple,
            "claude-code" => PanelAgentColor::Coral,
            "pi" => PanelAgentColor::Rose,
            "zcode" => PanelAgentColor::Mint,
            "opencode" => PanelAgentColor::Green,
            "codebuddy" => PanelAgentColor::Orange,
            other => {
                let hash = fnv1a64(other);
                PANEL_AGENT_COLORS[(hash % PANEL_AGENT_COLORS.len() as u64) as usize]
            }
        }
    }

    /// Nothing 主题系列色: 呼吸灯绿 (#4A9E5C) 基色的 5 档绿阶。
    /// 深色模式亮→暗 (高频 agent 更亮), 浅色模式反转保证白底可读;
    /// 已知 agent 固定档位, 未知 agent 沿用 FNV-1a 散列稳定落档。
    pub fn nothing_ramp_hex(agent_id: &str, dark_mode: bool) -> &'static str {
        let ramp: &[&str] = if dark_mode {
            &["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"]
        } else {
            &["#2A6B3C", "#35854A", "#4A9E5C", "#5FAF6E", "#8CCB98"]
        };
        let index = match agent_id {
            "kimi-code-cli" => 0,
            "claude-code" => 1,
            "codex" => 2,
            "zcode" => 3,
            "opencode" => 4,
            "codebuddy" => 2,
            // kimi-work 与 kimi-code-cli 高频同现, 落 4 档避免撞色;
            // 与 opencode 共档是可接受取舍 (同现概率低)。
            "kimi-work" => 4,
            "grok" => 2,
            "pi" => 4,
            other => (fnv1a64(other) % ramp.len() as u64) as usize,
        };
        ramp[index]
    }
}

/// FNV-1a 64 (offset 0xcbf29ce484222325, prime 0x100000001b3), 与 Swift 端散列一致。
fn fnv1a64(value: &str) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolve_maps_known_agents_stably() {
        assert_eq!(
            PanelAgentColor::resolve("kimi-code-cli"),
            PanelAgentColor::Blue
        );
        assert_eq!(
            PanelAgentColor::resolve("claude-code"),
            PanelAgentColor::Coral
        );
        assert_eq!(PanelAgentColor::resolve("codex"), PanelAgentColor::Purple);
        assert_eq!(PanelAgentColor::resolve("opencode"), PanelAgentColor::Green);
    }

    #[test]
    fn resolve_unknown_agent_is_deterministic_fnv1a() {
        let a = PanelAgentColor::resolve("totally-unknown-agent");
        let b = PanelAgentColor::resolve("totally-unknown-agent");
        assert_eq!(a, b);
        assert!(a.hex().starts_with('#'));
    }

    #[test]
    fn nothing_ramp_flips_direction_with_mode() {
        // kimi-code-cli 固定 0 档: 深色模式最亮, 浅色模式最暗。
        assert_eq!(
            PanelAgentColor::nothing_ramp_hex("kimi-code-cli", true),
            "#8CCB98"
        );
        assert_eq!(
            PanelAgentColor::nothing_ramp_hex("kimi-code-cli", false),
            "#2A6B3C"
        );
    }
}
