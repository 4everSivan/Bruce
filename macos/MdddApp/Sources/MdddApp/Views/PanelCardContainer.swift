import MdddOnboardingCore
import SwiftUI

// 面板装配层共享的卡片容器与底栏按钮样式.

/// 面板卡片容器: 液态玻璃模式下 glassEffect (圆角 16); 经典/哑光退化为材质或半透明填充.
struct PanelCardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.mdddResolvedTheme) private var theme
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
                color: surfaceTokens.shadowColor.opacity(surfaceTokens.shadowOpacity),
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
    @Environment(\.mdddResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
        if plan.usesInteractiveGlass {
            if #available(macOS 26, *) {
                content.buttonStyle(
                    DashboardPanelGlassButtonStyle(colorScheme: colorScheme)
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
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        let isDark = colorScheme == .dark
        configuration.label
            // Anchor controls to the dashboard appearance. A clear panel can
            // sample a white browser/document window, so a white-only control
            // surface would become white-on-white even in dark dashboard mode.
            .foregroundStyle(isDark ? Color.white : Color.black.opacity(0.82))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                isDark
                    ? Color.black.opacity(configuration.isPressed ? 0.82 : 0.68)
                    : Color.white.opacity(configuration.isPressed ? 0.88 : 0.78),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isDark
                            ? Color.white.opacity(0.42)
                            : Color.black.opacity(0.20),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: Color.black.opacity(isDark ? 0.22 : 0.10),
                radius: 3,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
