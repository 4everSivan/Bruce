import AppKit
import BruceAppCore
import SwiftUI

// MARK: - Agent 品牌身份徽章

/// Agent / 模型厂商的身份徽章 (C161), 取代原先的 6–9pt 色点。
///
/// 三档口径 (与 Windows 前端 `.wb-ico` 对齐):
/// - **真彩档** (size ≥ 14pt): 有官方 App 位图用位图, 否则品牌底色 + 品牌图形,
///   外圈 1.2pt 系列色环把图标与图表折线的颜色对上;
/// - **系列色档** (size < 14pt): 系列色瓷砖 + 白色图形, 小尺寸不糊;
/// - **Nothing 档**: 单色 —— 1pt 方角描边 + 绿阶档色图形, 不引入真彩;
/// - 无图形无位图 → 字标 (`π` / 名称首字符), 沿用 C026 的 fail-closed 语义。
///
/// 系列色只承担「数据量」语义 (§PanelAgentColor), 图标只承担「这是谁」。
struct AgentBrandBadge: View {
    let asset: AgentBrandAsset?
    /// Agent / 模型系列色 (图表同源)。
    let seriesHex: String
    /// 徽章边长: 设置行 20 / 仪表盘 14 / 模型 chip 12。
    var size: CGFloat = 14
    /// Nothing 主题下的单色档色; Agent 传 nothingRampHex, 模型传 accent。
    var nothingHex: String = "#4A9E5C"
    /// 是否跟随看板主题。设置窗口恒用 Fluent (C067), 传 false 后即使看板切到
    /// Nothing 也保持品牌真彩, 不出现绿色扁平图标。
    var followsTheme: Bool = true
    /// 无品牌素材时的字标。
    var fallbackMonogram: String = "?"

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isNothing: Bool { followsTheme && theme.interfaceStyle == .nothing }
    private var cornerRadius: CGFloat { max(1, size * 0.27) }
    /// 真彩档: 大尺寸且非 Nothing。
    private var usesBrandStyle: Bool { size >= 14 && !isNothing }
    private var monogram: String {
        let value = asset?.monogram ?? fallbackMonogram
        return value.isEmpty ? "?" : value
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(tileColor, in: tileShape)
            .overlay(tileBorder)
            .overlay(seriesRing)
            .accessibilityHidden(true)
    }

    private var tileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isNothing ? 1 : cornerRadius, style: .continuous)
    }

    @ViewBuilder
    private var content: some View {
        if isNothing {
            glyphOrMonogram(color: Color(hex: nothingHex))
        } else if usesBrandStyle,
                  let imageName = asset?.imageName,
                  let image = AgentBrandIconStore.image(named: imageName) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .clipShape(tileShape)
        } else {
            glyphOrMonogram(color: markColor)
        }
    }

    @ViewBuilder
    private func glyphOrMonogram(color: Color) -> some View {
        if let glyphID = asset?.glyphID,
           let shapes = ProviderBrandGlyph.resolvedShapes(for: glyphID, size: size) {
            ZStack {
                ForEach(Array(shapes.enumerated()), id: \.offset) { _, shape in
                    Path(shape.path)
                        .fill(color)
                        .opacity(shape.opacity)
                }
            }
        } else {
            Text(monogram)
                .font(.system(size: size * 0.54, weight: .bold))
                .foregroundStyle(color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    private var tileColor: Color {
        if isNothing { return .clear }
        if usesBrandStyle, let hex = asset?.tileHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return Color(hex: seriesHex)
    }

    private var markColor: Color {
        if isNothing { return Color(hex: nothingHex) }
        if usesBrandStyle, let hex = asset?.markHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return .white
    }

    @ViewBuilder
    private var tileBorder: some View {
        if isNothing {
            tileShape.strokeBorder(Color(hex: nothingHex), lineWidth: 1)
        } else {
            tileShape.strokeBorder(
                Color.adaptive(
                    light: Color.black.opacity(0.12),
                    dark: Color.white.opacity(0.16)
                ),
                lineWidth: 0.5
            )
        }
    }

    /// 真彩档的系列色环: 图标是品牌色, 环把「谁」与图表里的「哪条线」接上。
    @ViewBuilder
    private var seriesRing: some View {
        if usesBrandStyle {
            RoundedRectangle(cornerRadius: cornerRadius + 1.5, style: .continuous)
                .strokeBorder(Color(hex: seriesHex).opacity(0.7), lineWidth: 1.2)
                .padding(-1.5)
        }
    }
}

// MARK: - 位图缓存

/// 官方 App 位图的运行时加载 (Assets/AgentIcons → Contents/Resources/AgentIcons)。
/// 资源缺失 (dev 直跑裸可执行) 时返回 nil, 徽章自动回退到矢量/字标。
@MainActor
enum AgentBrandIconStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(named name: String) -> NSImage? {
        let key = name as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = iconURL(named: name),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func iconURL(named name: String) -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("AgentIcons/\(name).png"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/AgentIcons/\(name).png"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
