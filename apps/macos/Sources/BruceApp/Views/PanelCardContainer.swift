import BruceAppCore
import BruceGlassSurfaceCore
import BruceOnboardingCore
import SwiftUI

// 面板装配层共享的卡片容器与底栏按钮样式.

/// 面板卡片容器 (C271): Nothing 纯色卡片 + 1px 边框, 无高光无阴影.
struct PanelCardContainer<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: 8,
            style: .continuous
        )
    }

    private var surfaceTokens: DashboardGlassSurfaceTokens {
        DashboardGlassSurfaceTokens.resolve(colorScheme: colorScheme)
    }

    var body: some View {
        content
            .padding(.horizontal, DashboardCardHeaderLayout.cardHorizontalPadding)
            .padding(.vertical, 13)
            .background { cardBackground }
            .overlay {
                shape.strokeBorder(surfaceTokens.borderColor, lineWidth: 1)
            }
            .clipShape(shape)
    }

    @ViewBuilder
    private var cardBackground: some View {
        dashboardGlassBackground(
            shape: shape,
            colorScheme: colorScheme,
            surface: .card
        )
    }
}

extension View {
    /// 面板底栏按钮: C271 起固定 Nothing 纯色控件面.
    @ViewBuilder
    func panelGlassButtonStyle() -> some View {
        modifier(PanelGlassButtonStyleModifier())
    }
}

private struct PanelGlassButtonStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.buttonStyle(
            NothingPanelButtonStyle(
                tokens: DashboardGlassSurfaceTokens.resolve(colorScheme: colorScheme)
            )
        )
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
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(tokens.controlBorderColor, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 面板内容高度相关动效的统一时长与曲线 (C148).
///
/// 卡片折叠/展开、多账号开合、Tab 单卡切换与面板窗口高度过渡共用同一时长,
/// 保证「外框收放」与「正文收放」是同一条时间线; 各自为政的时长会让两者互相追尾.
enum DashboardMotionTiming {
    /// 内容高度过渡时长 (秒).
    static let contentResize: TimeInterval = 0.30
    /// 内容高度过渡曲线; 窗口层用同名 CAMediaTimingFunction 对齐.
    static var contentResizeCurve: Animation { .easeInOut(duration: contentResize) }
}

// MARK: - 交换态高度测量 (C148)

/// 上报视图的自然高度 (C148).
///
/// 被测内容被外层 `.frame(height:)` 与 `.clipped()` 裁切时仍按自然高度完成布局:
/// 否则容器一收, 测量值就跟着变小, 形成「越量越矮」的回环, 展开动画会在半途失速.
private struct NaturalHeightReader: ViewModifier {
    @Binding var height: CGFloat

    func body(content: Content) -> some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured in
                guard measured > 0, abs(measured - height) > 0.5 else { return }
                height = measured
            }
    }
}

extension View {
    /// 把视图的自然高度写入 `height`, 供外层容器做显式高度动画 (C148).
    func readingNaturalHeight(into height: Binding<CGFloat>) -> some View {
        modifier(NaturalHeightReader(height: height))
    }
}

// MARK: - 可收起卡片标题行

/// 卡片可收起标题行 (定稿: card-collapse-demo.html 方案 C 变体 2).
/// 版式: 左标题 (定宽 92, 三卡图形区左缘齐平) + 中间内容区 + 右 chevron;
/// 收起态内容区渲染迷你可视化 (mini), 展开态渲染卡片状态件 (status, 如 LIVE/更新时间).
/// chevron 常态隐藏, 悬停标题行淡入 (0.15s), 展开时旋转 90°; 整行点击切换.
/// C233: 标题全周期固定在同一位置 —— 拖拽手柄不占标题行布局, 收起态在卡片左边距内淡入;
/// 收起摘要与展开态状态件直接换位, 不做淡入淡出.
struct CollapsibleCardHeader<Status: View, Mini: View>: View {
    let title: String
    let isCollapsed: Bool
    let onToggle: () -> Void
    var cardID: DashboardCardID? = nil
    @ViewBuilder let status: Status
    @ViewBuilder let mini: Mini

    @Environment(\.motionSuppressed) private var motionSuppressed
    @State private var hovering = false

    /// 标题定宽 84 (与 Demo A 严格齐平).
    private var resolvedTitleWidth: CGFloat { 84 }

    var body: some View {
        Button {
            withAnimation(motionSuppressed ? nil : DashboardMotionTiming.contentResizeCurve) {
                onToggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(NothingFont.ui(11.5, weight: .semibold))
                    .foregroundStyle(nothingTitleColor)
                    .frame(width: resolvedTitleWidth, alignment: .leading)
                // 收起摘要与展开态状态件常驻同一个占位盒, 两者都贴右缘;
                // C233: 直接换位, 不随收放事务淡入淡出 (半透明叠在一起读作糊成一团).
                ZStack(alignment: .trailing) {
                    mini
                        .frame(maxWidth: .infinity)
                        .opacity(isCollapsed ? 1 : 0)
                        .allowsHitTesting(false)
                    status
                        .opacity(isCollapsed ? 0 : 1)
                }
                .animation(nil, value: isCollapsed)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .opacity(hovering ? 1 : 0)
                    .animation(
                        motionSuppressed ? nil : .easeInOut(duration: 0.15),
                        value: hovering
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(isCollapsed ? "展开卡片" : "收起卡片")
        .accessibilityValue(isCollapsed ? "已收起" : "已展开")
        // 专职拖拽手柄: 物理独立于展开 Button 之外, 避免拖拽手势被按钮点击捕获.
        .overlay(alignment: .leading) { gutterHandle }
    }

    /// 拖拽手柄 (C233): 落在卡片左边距内, 不参与标题行布局, 标题因此不随收放横移.
    /// 仅收起态可见可交互, 显隐跟随收放的同一条事务.
    private var gutterHandle: some View {
        Group {
            if let cardID {
                DashboardDragHandle()
                    .draggable(cardID.rawValue)
            } else {
                DashboardDragHandle()
            }
        }
        .frame(width: DashboardCardHeaderLayout.cardHorizontalPadding)
        .offset(x: -DashboardCardHeaderLayout.cardHorizontalPadding)
        .opacity(isCollapsed ? 1 : 0)
        .allowsHitTesting(isCollapsed)
    }

    /// Nothing 标题色: secondary (dark #999999 / light #666666), 与定稿 token 一致.
    private var nothingTitleColor: Color {
        Color.adaptive(light: Color(hex: "#666666"), dark: Color(hex: "#999999"))
    }
}

/// Nothing 卡片拖拽手柄: 2x3 方形点阵 (尺寸 10x14), 悬停暗灰背景.
/// 仅在卡片缩小/折叠状态下渲染, 且物理独立于折叠展开 Button 之外.
struct DashboardDragHandle: View {
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2.5) {
            HStack(spacing: DashboardCardHeaderLayout.handleDotSpacing) {
                dot; dot
            }
            HStack(spacing: DashboardCardHeaderLayout.handleDotSpacing) {
                dot; dot
            }
            HStack(spacing: DashboardCardHeaderLayout.handleDotSpacing) {
                dot; dot
            }
        }
        .padding(.horizontal, DashboardCardHeaderLayout.handleHorizontalPadding)
        .padding(.vertical, 4)
        .background(
            hovering
                ? Color.adaptive(light: Color(hex: "#E0E0E0"), dark: Color(hex: "#222222"))
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 2, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("拖拽调整卡片顺序")
    }

    private var dot: some View {
        Rectangle()
            .fill(hovering ? Color.primary : Color.secondary.opacity(0.4))
            .frame(
                width: DashboardCardHeaderLayout.handleDotSize,
                height: DashboardCardHeaderLayout.handleDotSize
            )
    }
}

/// 仪表盘卡片拖拽让位代理: 悬停经过目标卡片时立即平滑交换位置并持久化.
struct DashboardCardDropDelegate: DropDelegate {
    let target: DashboardCardID
    let motionSuppressed: Bool
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
                withAnimation(motionSuppressed ? nil : .easeOut(duration: 0.15)) {
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
