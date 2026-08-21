import BruceGlassSurfaceCore
import BruceOnboardingCore
import SwiftUI

// 面板装配层共享的卡片容器与底栏按钮样式.

/// 面板卡片容器: 液态玻璃模式下 glassEffect (圆角 16); 经典/哑光退化为材质或半透明填充.
struct PanelCardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.BruceResolvedTheme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    private var surfaceTokens: DashboardGlassSurfaceTokens {
        DashboardGlassSurfaceTokens.resolve(
            theme: theme,
            colorScheme: colorScheme
        )
    }

    var body: some View {
        content
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background { cardBackground }
            .overlay {
                shape.strokeBorder(surfaceTokens.borderColor, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // 低对比度顶部材质高光. 液态玻璃由系统承担主要边缘效果,
                // 此处只保留很弱的结构提示, 避免重复描边.
                Rectangle()
                    .fill(surfaceTokens.highlightColor)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .offset(y: 0.5)
            }
            .clipShape(shape)
            .shadow(
                color: surfaceTokens.shadowColor,
                radius: 5,
                y: 1
            )
    }

    @ViewBuilder
    private var cardBackground: some View {
        dashboardGlassBackground(
            theme: theme,
            shape: shape,
            colorScheme: colorScheme,
            fallback: .card,
            surface: .card
        )
    }

}

extension View {
    /// 面板底栏按钮: 液态玻璃模式使用自适应控件面, 避免白色背景下失去对比度.
    @ViewBuilder
    func panelGlassButtonStyle() -> some View {
        modifier(PanelGlassButtonStyleModifier())
    }
}

private struct PanelGlassButtonStyleModifier: ViewModifier {
    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
        if plan.usesInteractiveGlass {
            if #available(macOS 26, *) {
                content.buttonStyle(
                    DashboardPanelGlassButtonStyle(
                        tokens: DashboardGlassSurfaceTokens.resolve(
                            theme: theme,
                            colorScheme: colorScheme
                        )
                    )
                )
            } else {
                content
            }
        } else {
            content
        }
    }
}

/// 面板底栏使用稳定的低对比度控件面, 避免系统 `.glass` 在
/// 通透背景与 SwiftUI 外观不一致时生成高亮白块. 只作用于底栏按钮,
/// 不改变按钮 action 或尺寸链路.
private struct DashboardPanelGlassButtonStyle: ButtonStyle {
    let tokens: DashboardGlassSurfaceTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // Anchor controls to the same resolved surface matrix as panel and
            // cards. A clear panel must not turn controls into white blocks.
            .foregroundStyle(tokens.controlForegroundColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed
                    ? tokens.controlPressedFillColor
                    : tokens.controlFillColor,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tokens.controlBorderColor, lineWidth: 1)
            }
            .shadow(
                color: tokens.controlShadowColor,
                radius: 3,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
