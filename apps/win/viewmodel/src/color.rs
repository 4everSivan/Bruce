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
    /// DSH (DeepSeek Harness) — 品牌蓝 #4d6bfe (第 10 个已知 agent; C189)
    Azure,
    /// Antigravity — Google 蓝 #4285f4 (第 11 个已知 agent; 取品牌图标主色)
    Sky,
}

pub const PANEL_AGENT_COLORS: [PanelAgentColor; 11] = [
    PanelAgentColor::Cyan,
    PanelAgentColor::Blue,
    PanelAgentColor::Indigo,
    PanelAgentColor::Purple,
    PanelAgentColor::Coral,
    PanelAgentColor::Mint,
    PanelAgentColor::Rose,
    PanelAgentColor::Green,
    PanelAgentColor::Orange,
    PanelAgentColor::Azure,
    PanelAgentColor::Sky,
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
            PanelAgentColor::Azure => "azure",
            PanelAgentColor::Sky => "sky",
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
            PanelAgentColor::Azure => "#4d6bfe",
            PanelAgentColor::Sky => "#4285f4",
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
            PanelAgentColor::Azure => &["#4d6bfe", "#7089ff", "#9aabff", "#c3ccff"],
            PanelAgentColor::Sky => &["#4285f4", "#6ba1f7", "#94befa", "#bddafc"],
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
            // DSH (DeepSeek Harness) 品牌蓝; C189 第 10 个已知 agent。
            "dsh" => PanelAgentColor::Azure,
            "antigravity" => PanelAgentColor::Sky,
            other => {
                let hash = fnv1a64(other);
                PANEL_AGENT_COLORS[(hash % PANEL_AGENT_COLORS.len() as u64) as usize]
            }
        }
    }

    /// Nothing 主题系列色: 深色为呼吸灯绿 (#4A9E5C) 基色 5 档, 浅色为杏色 5 档 (C221/C263),
    /// 档位与色值来自 `config/brand-registry.json` (三端代码生成);
    /// 已知 agent 固定档位, 未知 agent 用 FNV-1a 散列稳定落档。
    pub fn nothing_ramp_hex(agent_id: &str, dark_mode: bool) -> &'static str {
        let ramp: &[&str] = if dark_mode {
            &crate::brand_registry::NOTHING_RAMP_DARK
        } else {
            &crate::brand_registry::NOTHING_RAMP_LIGHT
        };
        let index = crate::brand_registry::nothing_agent_tier(agent_id)
            .unwrap_or_else(|| (fnv1a64(agent_id) % ramp.len() as u64) as usize);
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
        // C189: dsh 落到新增的 Azure 系列色, 且 hex 与 mac 口径逐字一致。
        assert_eq!(PanelAgentColor::resolve("dsh"), PanelAgentColor::Azure);
        assert_eq!(PanelAgentColor::Azure.name(), "azure");
        assert_eq!(PanelAgentColor::Azure.hex(), "#4d6bfe");
        assert_eq!(
            PanelAgentColor::Azure.distribution_hex(0),
            "#4d6bfe",
            "index 0 即主色"
        );
        assert_eq!(PanelAgentColor::Azure.distribution_hex(3), "#c3ccff");
        // 第 11 个已知 agent: Antigravity 落到新增 Sky 系列色。
        assert_eq!(
            PanelAgentColor::resolve("antigravity"),
            PanelAgentColor::Sky
        );
        assert_eq!(PanelAgentColor::Sky.name(), "sky");
        assert_eq!(PanelAgentColor::Sky.hex(), "#4285f4");
        assert_eq!(PANEL_AGENT_COLORS.len(), 11, "第 11 档系列色已登记");
    }

    #[test]
    fn nothing_ramp_pins_dsh_to_tier_one() {
        // dsh 固定 1 档: 深色为绿阶第 2 色, 浅色为杏色阶第 2 色 (C221/C263 对齐 mac)。
        assert_eq!(PanelAgentColor::nothing_ramp_hex("dsh", true), "#5FAF6E");
        assert_eq!(PanelAgentColor::nothing_ramp_hex("dsh", false), "#B8860B");
    }

    #[test]
    fn resolve_unknown_agent_is_deterministic_fnv1a() {
        let a = PanelAgentColor::resolve("totally-unknown-agent");
        let b = PanelAgentColor::resolve("totally-unknown-agent");
        assert_eq!(a, b);
        assert!(a.hex().starts_with('#'));
        // C263: UTF-8 64-bit FNV-1a 与 Swift/JS 逐字节一致 (含多字节字符)。
        assert_eq!(fnv1a64("codex"), 0x2ffb_778d_fae5_4384);
        assert_eq!(fnv1a64("模型"), 0x641e_9277_a326_2aca);
    }

    #[test]
    fn nothing_ramp_uses_generated_registry_values() {
        // 深色档: 高频 agent 更亮; 浅色档为杏色 (C221), 不再是绿阶反转。
        assert_eq!(
            PanelAgentColor::nothing_ramp_hex("kimi-code-cli", true),
            "#8CCB98"
        );
        assert_eq!(
            PanelAgentColor::nothing_ramp_hex("kimi-code-cli", false),
            "#946A08"
        );
        assert_eq!(
            crate::brand_registry::NOTHING_RAMP_DARK,
            ["#8CCB98", "#5FAF6E", "#4A9E5C", "#35854A", "#2A6B3C"]
        );
        assert_eq!(
            crate::brand_registry::NOTHING_RAMP_LIGHT,
            ["#946A08", "#B8860B", "#D4A843", "#E3BE6B", "#F0D69A"]
        );
    }
}
