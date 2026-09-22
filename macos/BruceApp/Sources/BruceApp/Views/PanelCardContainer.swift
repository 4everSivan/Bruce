import BruceAppCore
import BruceGlassSurfaceCore
import BruceOnboardingCore
import SwiftUI

// 面板装配层共享的卡片容器与底栏按钮样式.

/// 面板卡片容器: 液态玻璃模式下 glassEffect (圆角 16); 经典/哑光退化为材质或半透明填充;
/// Nothing 主题按定稿为纯色卡片 (圆角 5) + 1px 边框, 无高光无阴影.
struct PanelCardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.BruceResolvedTheme) private var theme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var isNothingSurface: Bool {
        theme.interfaceStyle == .nothing
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: isNothingSurface ? 4 : 16,
            style: .continuous
        )
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
                // Nothing: 1px 边框已承担分层, 高光矩形不渲染.
                if !isNothingSurface {
                    Rectangle()
                        .fill(surfaceTokens.highlightColor)
                        .frame(height: 1)
                        .padding(.horizontal, 10)
                        .offset(y: 0.5)
                }
            }
            .clipShape(shape)
            .shadow(
                color: surfaceTokens.shadowColor,
                radius: isNothingSurface ? 0 : 5,
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
        } else if theme.interfaceStyle == .nothing {
            content.buttonStyle(
                NothingPanelButtonStyle(
                    tokens: DashboardGlassSurfaceTokens.resolve(
                        theme: theme,
                        colorScheme: colorScheme
                    )
                )
            )
        } else {
            content
        }
    }
}

/// Nothing 主题底栏按钮: 定稿为 Space Mono 11pt 大写 + 0.06em 字距,
/// 1px 描边 (#333333/#CCCCCC), 小圆角 5, 纯色填充无阴影. 仅 nothing 分支挂载.
private struct NothingPanelButtonStyle: ButtonStyle {
    let tokens: DashboardGlassSurfaceTokens

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NothingFont.mono(11))
            .tracking(0.66)
            .textCase(.uppercase)
            .foregroundStyle(tokens.controlForegroundColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                configuration.isPressed
                    ? tokens.controlPressedFillColor
                    : tokens.controlFillColor,
                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(tokens.controlBorderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
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

// MARK: - 可收起卡片标题行

/// 卡片可收起标题行 (定稿: card-collapse-demo.html 方案 C 变体 2).
/// 版式: 左标题 (定宽 92, 三卡图形区左缘齐平) + 中间内容区 + 右 chevron;
/// 收起态内容区渲染迷你可视化 (mini), 展开态渲染卡片状态件 (status, 如 LIVE/更新时间).
/// chevron 常态隐藏, 悬停标题行淡入 (0.15s), 展开时旋转 90°;
/// 整行点击切换, 高度过渡 0.25s. 标题全周期唯一, 收起/展开不跳动.
struct CollapsibleCardHeader<Status: View, Mini: View>: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void
    var cardID: DashboardCardID? = nil
    @ViewBuilder let status: Status
    @ViewBuilder let mini: Mini

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var isNothing: Bool {
        theme.interfaceStyle == .nothing
    }

    /// 标题定宽: 在 Nothing 主题下定宽 84 (与 Demo A 严格齐平); 经典主题维持 92.
    private var resolvedTitleWidth: CGFloat {
        isNothing ? 84 : 92
    }

    var body: some View {
        HStack(spacing: isNothing ? 8 : 10) {
            // 专职拖拽手柄: 仅在卡片缩小/折叠状态下展示, 且物理独立于展开 Button 之外,
            // 彻底避免拖拽手势被 Button 的点击捕获或误触发展开.
            if isCollapsed {
                if let cardID {
                    DashboardDragHandle(isNothing: isNothing)
                        .draggable(cardID.rawValue)
                } else {
                    DashboardDragHandle(isNothing: isNothing)
                }
            }

            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: isNothing ? 8 : 15) {
                    Text(title)
                        .font(isNothing
                            ? NothingFont.ui(11.5, weight: .semibold)
                            : .system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isNothing ? nothingTitleColor : Color.primary)
                        .frame(width: resolvedTitleWidth, alignment: .leading)
                    if isCollapsed {
                        mini
                            .frame(maxWidth: .infinity)
                    } else {
                        Spacer(minLength: 0)
                        status
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .opacity(hovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.15), value: hovering)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel(title)
            .accessibilityHint(isCollapsed ? "展开卡片" : "收起卡片")
            .accessibilityValue(isCollapsed ? "已收起" : "已展开")
        }
    }

    /// Nothing 标题色: secondary (dark #999999 / light #666666), 与定稿 token 一致.
    private var nothingTitleColor: Color {
        Color.adaptive(light: Color(hex: "#666666"), dark: Color(hex: "#999999"))
    }

    private var nothingSecondaryColor: Color {
        Color.adaptive(light: Color(hex: "#666666"), dark: Color(hex: "#8A8A8A"))
    }

    private var nothingBorderColor: Color {
        Color.adaptive(light: Color(hex: "#CCCCCC"), dark: Color(hex: "#303030"))
    }
}

/// 全风格卡片拖拽手柄: 仅在卡片缩小/折叠状态下渲染, 且物理独立于折叠展开 Button 之外.
/// - Nothing 主题: 经典 2x3 方形点阵 (尺寸 10x14), 悬停暗灰背景.
/// - Classic / Liquid 主题: 极简 6 点圆形点阵, 自适应次级文本色, 悬停轻质微光背景.
struct DashboardDragHandle: View {
    let isNothing: Bool
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 3) {
                dot; dot
            }
            HStack(spacing: 3) {
                dot; dot
            }
            HStack(spacing: 3) {
                dot; dot
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
        .background(
            hovering
                ? (isNothing
                    ? Color.adaptive(light: Color(hex: "#E0E0E0"), dark: Color(hex: "#222222"))
                    : Color.primary.opacity(0.08))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 2, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("拖拽调整卡片顺序")
    }

    @ViewBuilder
    private var dot: some View {
        if isNothing {
            Rectangle()
                .fill(hovering ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 2, height: 2)
        } else {
            Circle()
                .fill(hovering ? Color.primary : Color.secondary.opacity(0.45))
                .frame(width: 2.2, height: 2.2)
        }
    }
}

/// Nothing 风格拖拽手柄向后兼容结构
struct NothingDragHandle: View {
    var body: some View {
        DashboardDragHandle(isNothing: true)
    }
}

/// 仪表盘卡片拖拽让位代理: 悬停经过目标卡片时立即平滑交换位置并持久化.
struct DashboardCardDropDelegate: DropDelegate {
    let target: DashboardCardID
    let move: (DashboardCardID, DashboardCardID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        let target = self.target
        _ = provider.loadObject(ofClass: String.self) { raw, _ in
            guard let raw else { return }
            Task { @MainActor in
                guard let dragged = DashboardCardID(rawValue: raw), dragged != target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    move(dragged, target)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
