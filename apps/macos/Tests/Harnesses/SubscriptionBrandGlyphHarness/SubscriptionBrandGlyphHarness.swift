import AppKit
import CoreGraphics
import Foundation

import BruceAppCore
import BruceOnboardingCore

/// 订阅品牌图形徽章 (C026) 的边界测试:
/// 全 provider 图形覆盖与兜底 (fail-closed), 生成数据的命令集纪律,
/// 画布适配的包围盒收敛, 以及品牌色板/深色集合的完整性。
private enum SubscriptionBrandGlyphFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw SubscriptionBrandGlyphFailure.expectation(message)
    }
}

@main
@MainActor
struct SubscriptionBrandGlyphHarness {
    static func main() throws {
        try glyphCoverage()
        try failClosedFallback()
        try paintingBounds()
        try commandSetDiscipline()
        try paletteCoverage()
        try darkBrandSet()
        try opacityPreservation()
        try menuIcons()
        try menuSpacingEffect()
        try agentBrandPaletteCoverage()
        try agentBrandAssetFiles()
        if let directory = exportDirectory() {
            try exportMenuIcons(to: directory)
        }
        print("SubscriptionBrandGlyph tests passed: 11")
    }

    /// 开发期导出开关 (不参与断言): `--write-icons <dir>` 把菜单图标导出为 PNG,
    /// 供人工核对图形方向与配色 (菜单项方向错误是肉眼才可见的缺陷)。
    private static func exportDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--write-icons"),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return URL(fileURLWithPath: arguments[arguments.index(after: index)])
    }

    private static func exportMenuIcons(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for provider in SubscriptionProviderID.allCases where provider != .jev {
            for size in [16, 64] as [CGFloat] {
                guard let image = ProviderBrandGlyph.menuImage(for: provider.rawValue, size: size),
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    throw SubscriptionBrandGlyphFailure.expectation(
                        "\(provider.rawValue) 菜单图标导出失败"
                    )
                }
                let url = directory.appendingPathComponent("\(provider.rawValue)-\(Int(size)).png")
                try png.write(to: url)
            }
        }
        try exportPickerSamples(to: directory)
        print("菜单图标已导出: \(directory.path)")
    }

    /// 导出不同 trailingGap 下的下拉按钮面 (与菜单项同一 cell 绘制逻辑), 供量测图标与标题间距。
    private static func exportPickerSamples(to directory: URL) throws {
        for gap in [0, 6] as [CGFloat] {
            let button = NSPopUpButton(
                frame: NSRect(x: 0, y: 0, width: 240, height: 25),
                pullsDown: false
            )
            button.addItem(withTitle: "占位")
            for provider in [SubscriptionProviderID.kimi, .volcengine, .claude, .grok] {
                let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
                item.image = ProviderBrandGlyph.menuImage(for: provider.rawValue, trailingGap: gap)
                button.menu?.addItem(item)
            }
            button.selectItem(at: 2)
            guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
                throw SubscriptionBrandGlyphFailure.expectation("下拉样例位图创建失败 (gap=\(gap))")
            }
            button.cacheDisplay(in: button.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SubscriptionBrandGlyphFailure.expectation("下拉样例编码失败 (gap=\(gap))")
            }
            try png.write(to: directory.appendingPathComponent("picker-gap\(Int(gap)).png"))
        }
    }

    /// 全 provider (11 家) 除 Jev (界面暂时隐藏, 且全部图标库无覆盖) 外
    /// 必须都有图形数据。
    private static func glyphCoverage() throws {
        for provider in SubscriptionProviderID.allCases {
            let hasGlyph = ProviderBrandGlyphData.glyphs[provider.rawValue] != nil
            if provider == .jev {
                try expect(!hasGlyph, "jev 无图形数据, 应保持首字母兜底")
            } else {
                try expect(hasGlyph, "\(provider.rawValue) 缺少品牌图形数据")
                try expect(
                    !ProviderBrandGlyphData.glyphs[provider.rawValue]!.source.isEmpty,
                    "\(provider.rawValue) 图形必须登记来源 (指示性使用审计)"
                )
            }
        }
    }

    /// 未知 provider 与非法尺寸必须 fail-closed 返回 nil, 由视图回退首字母。
    private static func failClosedFallback() throws {
        try expect(
            ProviderBrandGlyph.resolvedShapes(for: "unknown-provider", size: 15) == nil,
            "未知 provider 必须返回 nil"
        )
        try expect(
            ProviderBrandGlyph.resolvedShapes(for: "kimi", size: 0) == nil,
            "非法尺寸必须返回 nil"
        )
    }

    /// 适配后的图形必须落在徽章画布内且非退化 (观感包围盒约 58% 瓷砖)。
    private static func paintingBounds() throws {
        let size: CGFloat = 15
        for provider in SubscriptionProviderID.allCases where provider != .jev {
            guard let shapes = ProviderBrandGlyph.resolvedShapes(
                for: provider.rawValue, size: size
            ) else {
                throw SubscriptionBrandGlyphFailure.expectation(
                    "\(provider.rawValue) 图形解析失败"
                )
            }
            try expect(!shapes.isEmpty, "\(provider.rawValue) 图形不应为空")

            let union = shapes.reduce(CGRect.null) { partial, shape in
                partial.union(shape.path.boundingBoxOfPath)
            }
            try expect(
                union.width > 2 && union.height > 2,
                "\(provider.rawValue) 图形退化 (bbox \(union))"
            )
            try expect(
                union.minX >= -0.001 && union.minY >= -0.001
                    && union.maxX <= size + 0.001 && union.maxY <= size + 0.001,
                "\(provider.rawValue) 图形越出徽章画布 (bbox \(union))"
            )
            let box = size * ProviderBrandGlyph.glyphBoxFraction
            try expect(
                union.width <= box + 0.001 && union.height <= box + 0.001,
                "\(provider.rawValue) 图形超出设计占位 (bbox \(union), box \(box))"
            )
        }
    }

    /// 生成数据只允许绝对 M/L/C/Z —— 这是 SVGPathBuilder 的唯一支持集,
    /// 防止后续手工修改源文件引入圆弧/相对命令后静默渲染错误。
    private static func commandSetDiscipline() throws {
        let allowed = Set("MLCZ0123456789 .,-+")
        for (provider, glyph) in ProviderBrandGlyphData.glyphs {
            for shape in glyph.shapes {
                try expect(
                    shape.path.allSatisfy { allowed.contains($0) },
                    "\(provider) 路径含非法命令字符 (仅支持绝对 M/L/C/Z)"
                )
                try expect(!shape.path.isEmpty, "\(provider) 路径不得为空")
                try expect(
                    (0...1).contains(shape.opacity),
                    "\(provider) 不透明度必须在 [0, 1]"
                )
            }
        }
    }

    /// 全部 provider 都有品牌色; 未知 provider 返回中性灰。
    private static func paletteCoverage() throws {
        let fallback = ProviderBrandPalette.hex(for: "unknown-provider")
        for provider in SubscriptionProviderID.allCases {
            let hex = ProviderBrandPalette.hex(for: provider.rawValue)
            try expect(
                hex != fallback,
                "\(provider.rawValue) 缺少品牌色 (落回默认灰 \(fallback))"
            )
            try expect(
                hex.hasPrefix("#") && hex.count == 7,
                "\(provider.rawValue) 品牌色格式非法: \(hex)"
            )
        }
        // C026 定稿: Z.ai 改用官方锁版深色, Cline 补齐品牌色。
        try expect(
            ProviderBrandPalette.hex(for: "zhipu") == "#2D2D2D",
            "zhipu 应为 Z.ai 官方锁版深色 #2D2D2D"
        )
        try expect(
            ProviderBrandPalette.hex(for: "cline") == "#18181b",
            "cline 品牌色应为 #18181b"
        )
    }

    /// 深色品牌色集合: Nothing 主题下退回 secondary 灰的唯一依据。
    private static func darkBrandSet() throws {
        for provider in ["grok", "zhipu", "cline"] {
            try expect(
                ProviderBrandPalette.isDarkBrand(provider),
                "\(provider) 属于深色品牌色, 必须进兜底集合"
            )
        }
        for provider in ["kimi", "deepseek", "volcengine", "codex", "claude", "opencodeGo", "stepfun", "jev"] {
            try expect(
                !ProviderBrandPalette.isDarkBrand(provider),
                "\(provider) 不应进深色兜底集合"
            )
        }
    }

    /// volcengine 的多层次品牌图形必须保留 50% 辅助面 (原始 SVG: 2 个 50% + 3 个实心)。
    private static func opacityPreservation() throws {
        guard let shapes = ProviderBrandGlyph.resolvedShapes(for: "volcengine", size: 15) else {
            throw SubscriptionBrandGlyphFailure.expectation("volcengine 图形解析失败")
        }
        try expect(shapes.count == 5, "volcengine 应为 5 个子路径, 实际 \(shapes.count)")
        try expect(
            shapes.filter { $0.opacity == 0.5 }.count == 2,
            "volcengine 应有 2 个 50% 辅助面"
        )
        try expect(
            shapes.filter { $0.opacity == 1 }.count == 3,
            "volcengine 应有 3 个实心面"
        )
    }

    /// 设置中心下拉菜单图标 (C026): 除 Jev 外每家都产出非模板位图并真实绘制;
    /// 未知 provider 返回 nil (菜单项仅显示文字)。
    private static func menuIcons() throws {
        for provider in SubscriptionProviderID.allCases {
            let image = ProviderBrandGlyph.menuImage(for: provider.rawValue, size: 16)
            if provider == .jev {
                try expect(image == nil, "jev 无图形, 菜单图标应为 nil")
                continue
            }
            guard let image else {
                throw SubscriptionBrandGlyphFailure.expectation(
                    "\(provider.rawValue) 菜单图标渲染失败"
                )
            }
            try expect(
                image.size == NSSize(width: 16, height: 16),
                "\(provider.rawValue) 菜单图标尺寸应为 16x16, 实际 \(image.size)"
            )
            try expect(
                !image.isTemplate,
                "\(provider.rawValue) 菜单图标不得为模板 (否则菜单渲染会丢失品牌色)"
            )
            // 真实绘制校验: 中心像素必须着色 (瓷砖 + 图形), 左上角圆角外必须透明。
            guard let rep = tiffBitmap(of: image) else {
                throw SubscriptionBrandGlyphFailure.expectation(
                    "\(provider.rawValue) 菜单图标无法位图化"
                )
            }
            let center = rep.colorAt(x: 8, y: 8)
            try expect(
                (center?.alphaComponent ?? 0) > 0.9,
                "\(provider.rawValue) 菜单图标中心未绘制"
            )
            let corner = rep.colorAt(x: 0, y: 0)
            try expect(
                (corner?.alphaComponent ?? 1) < 0.1,
                "\(provider.rawValue) 菜单图标圆角外应透明"
            )
        }
        try expect(
            ProviderBrandGlyph.menuImage(for: "unknown-provider", size: 16) == nil,
            "未知 provider 菜单图标应为 nil"
        )
    }

    private static func tiffBitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// 菜单项图标右侧留白必须真正把标题右移: AppKit 菜单标题位置由图像列宽决定
    /// (NSMenuItemCell.titleRect), 这是「图标与名称不挤在一起」的实现契约。
    private static func menuSpacingEffect() throws {
        let bounds = NSRect(x: 0, y: 0, width: 240, height: 25)

        func titleOrigin(trailingGap: CGFloat) -> CGFloat? {
            guard let image = ProviderBrandGlyph.menuImage(
                for: "kimi", trailingGap: trailingGap
            ) else { return nil }
            let item = NSMenuItem(title: "Kimi", action: nil, keyEquivalent: "")
            item.image = image
            let cell = NSMenuItemCell(textCell: "Kimi")
            cell.menuItem = item
            cell.imagePosition = .imageLeft
            return cell.titleRect(forBounds: bounds).origin.x
        }

        guard let base = titleOrigin(trailingGap: 0),
              let spaced = titleOrigin(trailingGap: 6) else {
            throw SubscriptionBrandGlyphFailure.expectation("菜单项 cell 布局取值失败")
        }
        let delta = spaced - base
        try expect(
            delta >= 4,
            "图标留白 6pt 应把标题右移至少 4pt, 实际 \(delta) (base=\(base), spaced=\(spaced))"
        )
        print("菜单标题位移量测: 无留白 x=\(base) -> 留白 6pt x=\(spaced) (右移 \(delta)pt)")
    }
// MARK: - C161 Agent 品牌身份

    /// 已知 Agent / 模型厂商的身份表必须完整: 图形键真实存在, 字标非空,
    /// 未知 Agent 返回 nil 由调用方兜底 (fail-closed)。
    private static func agentBrandPaletteCoverage() throws {
        let knownAgents = [
            "zcode", "claude-code", "codex", "kimi-code-cli", "kimi-work",
            "opencode", "codebuddy", "grok", "pi",
        ]
        for agentID in knownAgents {
            guard let asset = AgentBrandPalette.asset(forAgent: agentID) else {
                throw SubscriptionBrandGlyphFailure.expectation("\(agentID) 缺少品牌身份登记")
            }
            try expect(!asset.monogram.isEmpty, "\(agentID) 字标为空")
            if let glyphID = asset.glyphID {
                try expect(
                    ProviderBrandGlyphData.glyphs[glyphID] != nil,
                    "\(agentID) 引用了不存在的图形键 \(glyphID)"
                )
            }
            try expect(
                asset.imageName != nil || asset.glyphID != nil || !asset.monogram.isEmpty,
                "\(agentID) 三档素材全缺"
            )
        }
        try expect(
            AgentBrandPalette.asset(forAgent: "unknown-agent") == nil,
            "未知 Agent 不应凭空造品牌图形"
        )

        let modelCases: [(String, String)] = [
            ("claude-opus-5-5", "claude"),
            ("deepseek-v4.1-flash", "deepseek"),
            ("glm-5.3", "zhipu"),
            ("gpt-6.1-terra", "codex"),
            ("kimi-k3", "kimi"),
        ]
        for (key, expectedGlyph) in modelCases {
            guard let asset = AgentBrandPalette.asset(forModelKey: key) else {
                throw SubscriptionBrandGlyphFailure.expectation("\(key) 缺少模型品牌图形")
            }
            try expect(
                asset.glyphID == expectedGlyph,
                "\(key) 应映射到 \(expectedGlyph), 实际 \(asset.glyphID ?? "nil")"
            )
        }
        try expect(
            AgentBrandPalette.asset(forModelKey: "gemini-3-pro") == nil,
            "未登记厂商应返回 nil, 由调用方保留原色点"
        )
        print("Agent 品牌身份表: \(knownAgents.count) 个 Agent + \(modelCases.count) 个模型厂商通过")
    }

    /// 真彩档引用的位图必须真实入库 (生成器投放目标), 防止改名后运行时静默退回矢量。
    private static func agentBrandAssetFiles() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconDirectory = repoRoot.appendingPathComponent("apps/macos/Assets/AgentIcons")
        let agentIDs = [
            "zcode", "claude-code", "codex", "kimi-code-cli", "kimi-work",
            "opencode", "codebuddy", "grok", "pi",
        ]
        for agentID in agentIDs {
            guard let name = AgentBrandPalette.asset(forAgent: agentID)?.imageName else { continue }
            let file = iconDirectory.appendingPathComponent(name + ".png")
            try expect(
                FileManager.default.fileExists(atPath: file.path),
                "\(agentID) 的位图缺失: \(file.path)"
            )
        }
        print("Agent 位图入库校验通过: \(iconDirectory.path)")
    }
}
