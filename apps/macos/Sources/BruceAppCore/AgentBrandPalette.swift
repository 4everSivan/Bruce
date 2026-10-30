import Foundation

// MARK: - Agent / 模型品牌身份 (C161)

/// 品牌身份素材: 「谁的图标」这一层的数据, 不含系列色。
///
/// 选择顺序 (与双端约定一致):
/// 1. 有官方 App 位图 → `imageName` (真彩, 大尺寸首选);
/// 2. 否则用矢量图形 `glyphID` + 品牌底色/图形色 (小尺寸、无位图时同样可用);
/// 3. 两者都没有 → `monogram` 字母兜底。
///
/// 系列色 (`PanelAgentColor`) 不在这里: 它承担「数据量」语义, 由调用方传入,
/// 用于小尺寸瓷砖与图表映射。
package struct AgentBrandAsset: Equatable, Sendable {
    /// 运行时 App 位图文件名 (不含扩展名), 见 Assets/AgentIcons 与前端 assets/agent-icons。
    package let imageName: String?
    /// ProviderBrandGlyphData 中的图形键。
    package let glyphID: String?
    /// 品牌底色 (真彩档瓷砖)。
    package let tileHex: String
    /// 品牌图形色 (真彩档图形)。
    package let markHex: String
    /// 无图形时的字标。
    package let monogram: String

    package init(
        imageName: String? = nil,
        glyphID: String? = nil,
        tileHex: String = "#0A0A0A",
        markHex: String = "#FFFFFF",
        monogram: String = "?"
    ) {
        self.imageName = imageName
        self.glyphID = glyphID
        self.tileHex = tileHex
        self.markHex = markHex
        self.monogram = monogram
    }
}

/// 已知 Agent 与模型厂商的品牌身份表。
///
/// 只有**确认过官方来源**的才登记图形/位图 (见 docs/assets/provider-icons/SOURCES.json),
/// 未登记的落到字标, 不猜测品牌。
package enum AgentBrandPalette {
    /// 已知 Agent 固定表; 未登记返回 nil, 由调用方用名称首字符兜底。
    package static func asset(forAgent agentID: String) -> AgentBrandAsset? {
        switch agentID {
        case "zcode":
            return AgentBrandAsset(
                imageName: "agent-zcode", glyphID: "zcode",
                tileHex: "#0A0A0A", markHex: "#FFFFFF", monogram: "Z"
            )
        case "claude-code":
            // CLI 无桌面 App: 官方 clay 标记 + 奶油底 (与 Claude App 图标同观感)。
            return AgentBrandAsset(
                glyphID: "claude", tileHex: "#F2EEE6", markHex: "#D97757", monogram: "C"
            )
        case "codex":
            return AgentBrandAsset(
                imageName: "agent-codex", glyphID: "codex",
                tileHex: "#0A0A0A", markHex: "#FFFFFF", monogram: "X"
            )
        case "kimi-code-cli", "kimi-work":
            return AgentBrandAsset(
                glyphID: "kimi", tileHex: "#0B0B0B", markHex: "#FFFFFF", monogram: "K"
            )
        case "opencode":
            return AgentBrandAsset(
                glyphID: "opencodeGo", tileHex: "#1C1C1E", markHex: "#CFCECD", monogram: "O"
            )
        case "codebuddy":
            return AgentBrandAsset(
                imageName: "agent-codebuddy",
                tileHex: "#5B3DF5", markHex: "#FFFFFF", monogram: "C"
            )
        case "grok":
            return AgentBrandAsset(
                glyphID: "grok", tileHex: "#0B0B0B", markHex: "#FFFFFF", monogram: "G"
            )
        case "pi":
            // Pi 无对外图形 (npm 包内无图片资源), π 即其品牌符号。
            return AgentBrandAsset(tileHex: "", markHex: "", monogram: "π")
        default:
            return nil
        }
    }

    /// 模型厂商图形: 按规范键子串匹配 (与 ModelNormalizer.brandColors 同一口径)。
    /// 返回 nil 表示没有可用图形, 调用方保留原色点。
    package static func asset(forModelKey canonicalKey: String) -> AgentBrandAsset? {
        let key = canonicalKey.lowercased()
        for (needles, asset) in modelAssets where needles.contains(where: { key.contains($0) }) {
            return asset
        }
        return nil
    }

    /// 顺序即优先级, 与 ModelNormalizer 的品牌判定顺序保持一致。
    private static let modelAssets: [([String], AgentBrandAsset)] = [
        (["claude", "sonnet", "opus"], AgentBrandAsset(
            glyphID: "claude", tileHex: "#F2EEE6", markHex: "#D97757", monogram: "C"
        )),
        (["deepseek"], AgentBrandAsset(
            glyphID: "deepseek", tileHex: "#FFFFFF", markHex: "#4D6BFE", monogram: "D"
        )),
        (["glm", "zhipu"], AgentBrandAsset(
            glyphID: "zhipu", tileHex: "#FFFFFF", markHex: "#1F63EC", monogram: "G"
        )),
        (["gpt", "openai", "codex"], AgentBrandAsset(
            glyphID: "codex", tileHex: "#FFFFFF", markHex: "#0B0B0B", monogram: "G"
        )),
        (["kimi", "k3"], AgentBrandAsset(
            glyphID: "kimi", tileHex: "#0B0B0B", markHex: "#FFFFFF", monogram: "K"
        )),
        (["grok", "xai"], AgentBrandAsset(
            glyphID: "grok", tileHex: "#0B0B0B", markHex: "#FFFFFF", monogram: "G"
        )),
        (["cline"], AgentBrandAsset(
            glyphID: "cline", tileHex: "#0B0B0B", markHex: "#FFFFFF", monogram: "C"
        )),
    ]
}
