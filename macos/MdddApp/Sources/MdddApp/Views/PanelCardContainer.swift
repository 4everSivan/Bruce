import SwiftUI

// 面板装配层共享的卡片容器与底栏按钮样式.
// 视觉以 panel-layout-v8.html 的 .g 卡片为准; 不依赖 AppTheme, 只有玻璃一种形态.

/// 面板卡片容器: 白 0.45 底 + 白 0.6 描边 + 圆角 16 + 顶部 1pt 高光线.
/// 深色模式退化为材料质感 (regularMaterial), 描边与高光同步弱化.
struct PanelCardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    var body: some View {
        content
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background {
                if colorScheme == .dark {
                    shape.fill(.regularMaterial)
                } else {
                    shape.fill(Color.white.opacity(0.45))
                }
            }
            .overlay {
                shape.strokeBorder(strokeColor, lineWidth: 1)
            }
            .overlay(alignment: .top) {
                // 内阴影高光: 顶部 1pt 亮线, 对应 mockup inset 0 1px 0.
                Rectangle()
                    .fill(highlightColor)
                    .frame(height: 1)
                    .padding(.horizontal, 10)
                    .offset(y: 0.5)
            }
            .clipShape(shape)
            .shadow(
                color: Self.shadowColor.opacity(colorScheme == .dark ? 0 : 0.07),
                radius: 5,
                y: 1
            )
    }

    private var strokeColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.white.opacity(0.6)
    }

    private var highlightColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.10)
            : Color.white.opacity(0.6)
    }

    /// mockup 投影色 rgba(31,38,56,...); 泛型类型不支持静态存储属性, 用计算属性.
    private static var shadowColor: Color {
        Color(red: 31 / 255, green: 38 / 255, blue: 56 / 255)
    }
}

extension View {
    /// 面板底栏按钮: macOS 26 用系统 .glass 样式, 低系统保持默认.
    @ViewBuilder
    func panelGlassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            self.buttonStyle(.glass)
        } else {
            self
        }
    }
}
