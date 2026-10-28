import SwiftUI

import BruceAppCore
import BruceOnboardingCore

// MARK: - 品牌徽章

/// Provider 品牌徽章: 品牌色瓷砖 + 品牌图形 (C026 起取代首字母字母标)。
///
/// - 图形来源与许可证见 docs/assets/provider-icons/SOURCES.json;
///   无图形数据的 provider (如 Jev) 回退首字母, 与刷新按钮同属 fail-closed 语义;
/// - Nothing 主题 (S3 柔彩定稿): 圆角 3pt, 品牌色低透明度底 + 品牌色图形,
///   保留品牌辨识度且彩色面积最小; 深色品牌色 (grok/zhipu/cline) 在深色表面
///   不可读, 退回 secondary 灰。
struct ProviderBrandBadge: View {
    let providerID: String
    let name: String

    /// 徽章边长: 仪表盘 15pt (段头与收起态摘要), 设置中心订阅行 26pt,
    /// 配置弹窗标题 20pt; 圆角与首字母字号按比例缩放, 15pt 保持既有定稿值。
    var size: CGFloat = 15

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    /// 与 Nothing 风格统一紧凑圆角 3pt; 随尺寸等比放大。
    private var cornerRadius: CGFloat {
        max(3, size * 0.2)
    }

    var body: some View {
        content
            .frame(width: size, height: size)
            .background(
                backgroundColor,
                in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
            )
    }

    @ViewBuilder
    private var content: some View {
        if let shapes = ProviderBrandGlyph.resolvedShapes(for: providerID, size: size) {
            ZStack {
                // 图形已按目标尺寸适配; Path 自身即 Shape, 直接按子路径不透明度填充。
                ForEach(Array(shapes.enumerated()), id: \.offset) { _, shape in
                    Path(shape.path)
                        .fill(glyphColor)
                        .opacity(shape.opacity)
                }
            }
        } else {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.6, weight: .bold))
                .foregroundStyle(glyphColor)
        }
    }

    private var glyphColor: Color {
        isNothing ? nothingBrandColor : .white
    }

    private var backgroundColor: Color {
        isNothing
            ? nothingBrandColor.opacity(colorScheme == .dark ? 0.16 : 0.12)
            : brandColor
    }

    private var brandColor: Color {
        Color(hex: ProviderBrandPalette.hex(for: providerID))
    }

    /// Nothing 分支深色兜底: grok #111111 / zhipu #2D2D2D / cline #18181b
    /// 在深色表面不可读, 退回 secondary 灰。
    private var nothingBrandColor: Color {
        ProviderBrandPalette.isDarkBrand(providerID) && colorScheme == .dark
            ? Color(hex: "#999999")
            : brandColor
    }
}
