import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// 外观偏好 -> SwiftUI colorScheme 覆盖; system 返回 nil 表示跟随系统.
extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    /// 底栏外观按钮的当前态图标: 跟随系统为半明半暗圆, 浅色为太阳, 深色为月亮.
    var symbolName: String {
        switch self {
        case .system:
            return "circle.lefthalf.filled"
        case .light:
            return "sun.max"
        case .dark:
            return "moon"
        }
    }

    /// 外观偏好中文名, 与设置中心「配色模式」分段选择器一致.
    var displayName: String {
        switch self {
        case .system:
            return "跟随系统"
        case .light:
            return "浅色"
        case .dark:
            return "深色"
        }
    }
}

/// 刷新进行中的旋转指示. 仅在刷新时挂载, onAppear 启动无限旋转,
/// 刷新结束视图移除即停止.
private struct SpinningRefreshIcon: View {
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

/// 顶部四色状态灯刷新呼吸脉冲 (C100): 仅在刷新中且面板可见时挂载,
/// 面板隐藏或刷新结束即卸载, 严守 C044 隐藏态零持续动画门控.
private struct PulsingStatusDot: View {
    let dotColor: Color
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(dotColor.opacity(breathing ? 0.35 : 0.12))
                .frame(width: 12, height: 12)
            Circle()
                .fill(dotColor.opacity(breathing ? 1.0 : 0.42))
                .frame(width: 6, height: 6)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }
}

/// 菜单栏原生液态玻璃面板: 纵向卡片 (按 PanelViewModel 非 nil 渲染) + 底栏.
/// 卡片栈包 ScrollView: 内容超出屏幕可用高度时封顶出滚动条, 不足时高度自适应;
/// 底栏在滚动区外固定; 卡片全空时展示未配置引导.
struct MenuBarDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let openSettings: @MainActor () -> Void
    let terminateApplication: @MainActor () -> Void

    /// Nothing 主题判定: 仅影响 token (字体/颜色/圆角/间距), 不改布局结构.
    private var isNothingTheme: Bool {
        coordinator.resolvedTheme.interfaceStyle == .nothing
    }

    /// 面板理想尺寸变化回调 (宿主控制器据此跟随调整承载窗口尺寸).
    var onContentSizeChange: ((CGSize) -> Void)?

    /// 仅通知 AppKit 视觉宿主更新系统材质与配色, 不携带业务模型或统计数据.
    var onSurfaceThemeChange: ((ResolvedTheme, ColorScheme?) -> Void)?

    /// 顶部 Header 实测高度 (Header + 发线); 0 表示尚未测量, 预留 32 兜底.
    @State private var headerHeight: CGFloat = 0

    /// 卡片栈实测理想高度; 0 表示尚未测量到 (首帧), 此时不加高度约束保持自适应.
    @State private var cardStackHeight: CGFloat = 0

    /// 底栏实测高度 (发线+操作行); 0 表示尚未测量, 封顶时用 49 兜底预留, 保证底栏不被挤出屏幕.
    @State private var footerHeight: CGFloat = 0

    /// Tab 模式方案 1 水平定向滑动方向
    @State private var slideDirection: Edge = .trailing
    @Namespace private var tabPillNamespace

    var body: some View {
        let panel = model.makePanelViewModel()
        let panelShape = RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
        return VStack(spacing: 0) {
            // 全局顶部 Header (方案 3: HUD 终端点阵状态栏 · 全风格适配)
            VStack(spacing: 0) {
                dashboardTopHeader(panel)
                headerHairline
            }
            .background {
                if isNothingTheme {
                    Rectangle().fill(nothingFooterBackgroundColor)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                guard height > 0, abs(height - headerHeight) > 0.5 else { return }
                headerHeight = height
            }

            ScrollView {
                VStack(spacing: 0) {
                    // macOS 26 上 scrollIndicators(.hidden) 会被系统重设, 用
                    // AppKit 看门狗持续压制 scroller; 滚轮滚动不受影响.
                    // 看门狗随面板可见性启停 (C044).
                    ScrollIndicatorSuppressor(panelVisible: model.dashboardPanelVisible)
                        .frame(width: 0, height: 0)
                    glassCardStack(panel)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    // 仅变化时更新, 并忽略亚像素抖动, 避免回环引起布局振荡.
                    guard height > 0, abs(height - cardStackHeight) > 0.5 else { return }
                    cardStackHeight = height
                }
            }
            // 窗口自动尺寸时 ScrollView 理想高度塌陷, maxHeight 不解决理想高度;
            // 用 onGeometryChange 实测内容高度驱动 frame: 未测量 (首帧) 不加约束,
            // 测量后取 min(内容高, 屏上限扣除顶底栏), 确保顶底栏始终留在屏幕内.
            .frame(height: cardStackHeight > 0
                ? min(cardStackHeight, Self.maxCardStackHeight - max(footerHeight, 49) - max(headerHeight, 32))
                : nil)
            // 隐藏滚动指示条, 滚轮/触控板滚动不受影响.
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                footerHairline
                actionFooter
            }
            .background {
                // Nothing: 底栏按定稿为整段纯色 (dark 纯黑 / light #F5F5F5),
                // 与发线 (#222222/#E8E8E8) 构成分层; 其余主题不加背景.
                if isNothingTheme {
                    Rectangle().fill(nothingFooterBackgroundColor)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                guard height > 0, abs(height - footerHeight) > 0.5 else { return }
                footerHeight = height
            }
        }
        .frame(width: 440)
        .overlay {
            panelShape.strokeBorder(panelBorderColor, lineWidth: 1)
        }
        .overlay(alignment: .top) {
            // Fluent / macOS 顶部 1px 微发光发线: 提升复杂壁纸下的边缘轮廓与立体悬浮质感
            if !isNothingTheme {
                LinearGradient(
                    colors: [
                        .clear,
                        Color.white.opacity(colorScheme == .dark ? 0.35 : 0.70),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 1)
                .padding(.horizontal, 18)
                .offset(y: 0.5)
            }
        }
        .clipShape(panelShape)
        .preferredColorScheme(coordinator.appearanceMode.colorScheme)
        .environment(\.BruceResolvedTheme, coordinator.resolvedTheme)
        // 垂直方向按理想高度布局 (而非采纳宿主提议尺寸), 使 onGeometryChange
        // 上报真实理想高度; 内容高度变化时宿主据此调整面板尺寸.
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            onContentSizeChange?(size)
        }
        .onChange(of: coordinator.resolvedTheme) { _, theme in
            onSurfaceThemeChange?(theme, coordinator.appearanceMode.colorScheme)
        }
        .onChange(of: coordinator.appearanceMode) { _, _ in
            onSurfaceThemeChange?(coordinator.resolvedTheme, coordinator.appearanceMode.colorScheme)
        }
        .onKeyPress("1") {
            if model.layoutMode == .tabbed {
                selectTab(.usage)
                return .handled
            }
            return .ignored
        }
        .onKeyPress("2") {
            if model.layoutMode == .tabbed {
                selectTab(.subscription)
                return .handled
            }
            return .ignored
        }
        .onKeyPress("3") {
            if model.layoutMode == .tabbed {
                selectTab(.hourly)
                return .handled
            }
            return .ignored
        }
    }

    /// 面板外边框圆角: Nothing 主题 10 (与定稿 token 对齐), 其余主题维持 22.
    private var panelCornerRadius: CGFloat {
        isNothingTheme ? 10 : 22
    }

    /// 面板外边框颜色:
    /// - Nothing 主题: 1px 硬朗发线 (#222222 dark / #E8E8E8 light), 零多余光晕.
    /// - Classic / Liquid Glass: 半透明自适应发线 (dark 14% 白 / light 10% 黑), 兼顾 Windows Fluent 与 Mac 毛玻璃.
    private var panelBorderColor: Color {
        if isNothingTheme {
            return colorScheme == .dark
                ? Color(hex: "#222222")
                : Color(hex: "#E8E8E8")
        }
        return Color.adaptive(
            light: Color.black.opacity(0.10),
            dark: Color.white.opacity(0.14)
        )
    }

    /// 卡片栈高度上限: 铺满面板窗口所在屏 visibleFrame, 只留约 10pt 小边距;
    /// 内容不足时高度自适应不出滚动条, 超出时滚动条自动出现.
    /// 多屏时优先取面板窗口所在屏, 窗口未挂载或取屏失败时兜底 640.
    private static var maxCardStackHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        guard let visibleHeight = screen?.visibleFrame.height else {
            return 640
        }
        return max(visibleHeight - 10, 320)
    }

    // MARK: - 全局顶部 Header (方案 3: HUD 终端点阵状态栏 · 全风格适配)

    @ViewBuilder
    private func dashboardTopHeader(_ panel: PanelViewModel) -> some View {
        let activeCount = panel.hourly?.rows.filter { $0.todayTotal > 0 }.count ?? 0
        let isLive = panel.usage?.isLive ?? false
        let resolvedStatus = DashboardStatusToneResolver.resolve(
            moduleStatus: model.status(for: .agentUsage),
            panel: panel
        )

        HStack(spacing: isNothingTheme ? 8 : 10) {
            // 左侧：四色状态灯 (C100, hover 显示原因) + 统一品牌字 Bruce
            HStack(spacing: 6) {
                topHeaderStatusDot(status: resolvedStatus, isLive: isLive)
                if isNothingTheme {
                    Text("Bruce")
                        .font(NothingFont.ui(11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#1A1A1A"),
                            dark: Color(hex: "#E8E8E8")
                        ))
                } else {
                    Text("Bruce")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                }
            }

            Spacer(minLength: 0)

            // 右侧：Tab 模式下展示三图标分段切换（角标融合），Stack 模式下展示 Agent 运行状态
            if model.layoutMode == .tabbed {
                headerTabSwitcher(activeCount: activeCount)
            } else {
                headerAgentStatusText(activeCount: activeCount)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 顶栏 Tab 分段切换器: 3 个图标 + 方案 1 滑动药丸底 + 第 3 个图标呼吸绿点角标
    @ViewBuilder
    private func headerTabSwitcher(activeCount: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(DashboardCardID.allCases) { cardID in
                let isSelected = model.selectedCardID == cardID
                Button {
                    selectTab(cardID)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: cardID.systemImage)
                            .font(.system(size: isNothingTheme ? 10.5 : 11, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? (isNothingTheme ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                                    : Color.secondary
                            )
                            .frame(width: isNothingTheme ? 24 : 27, height: isNothingTheme ? 20 : 22)
                            .background {
                                if isSelected {
                                    if isNothingTheme {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .fill(Color.primary)
                                    } else {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.10))
                                            .matchedGeometryEffect(id: "activeTabPill", in: tabPillNamespace)
                                    }
                                }
                            }
                            .contentShape(Rectangle())

                        if cardID == .hourly && activeCount > 0 {
                            Circle()
                                .fill(isNothingTheme ? Color(hex: "#4A9E5C") : Color(hex: "#30D158"))
                                .frame(width: 5.5, height: 5.5)
                                .offset(x: 1, y: -1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("\(cardID.title)\(cardID == .hourly && activeCount > 0 ? " (\(activeCount) 个运行中)" : "")")
            }
        }
        .padding(2)
        .background {
            if isNothingTheme {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        Color.adaptive(light: Color(hex: "#CCCCCC"), dark: Color(hex: "#303030")),
                        lineWidth: 1
                    )
            } else {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
            }
        }
    }

    /// 原版纯文本运行状态指示
    @ViewBuilder
    private func headerAgentStatusText(activeCount: Int) -> some View {
        HStack(spacing: 4) {
            if activeCount > 0 {
                if isNothingTheme {
                    Text("\(activeCount) AGENTS RUNNING")
                        .font(NothingFont.mono(9))
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#666666"),
                            dark: Color(hex: "#8A8A8A")
                        ))
                } else {
                    Text("● \(activeCount) AGENTS ACTIVE")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#0A7D3B"),
                            dark: Color(hex: "#30D158")
                        ))
                }
            } else {
                if isNothingTheme {
                    Text("STANDBY")
                        .font(NothingFont.mono(9))
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#999999"),
                            dark: Color(hex: "#666666")
                        ))
                } else {
                    Text("STANDBY")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 顶部四色状态灯 (C100): 绿 (ok) / 黄 (warn) / 红 (error) / 中性灰 (neutral),
    /// 刷新中且面板可见时呼吸脉冲, 触碰显示状态原因 (.help + .accessibilityLabel).
    @ViewBuilder
    private func topHeaderStatusDot(status: DashboardStatusResolution, isLive: Bool) -> some View {
        let dotColor = statusDotColor(for: status.tone)
        let shouldPulse = status.isRefreshing
            && DashboardPanelAnimationPolicy.allowsHero(
                panelVisible: model.dashboardPanelVisible,
                reduceMotion: reduceMotion
            )

        Group {
            if shouldPulse {
                PulsingStatusDot(dotColor: dotColor)
            } else {
                ZStack {
                    if isLive || status.isRefreshing {
                        Circle()
                            .fill(dotColor.opacity(0.25))
                            .frame(width: 12, height: 12)
                    }
                    Circle()
                        .fill(dotColor)
                        .frame(width: 6, height: 6)
                }
                .frame(width: 12, height: 12)
            }
        }
        .contentShape(Rectangle())
        .help(status.reason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.reason)
    }

    private func statusDotColor(for tone: DashboardStatusTone) -> Color {
        switch tone {
        case .ok:
            return isNothingTheme
                ? Color.adaptive(light: Color(hex: "#2E7D32"), dark: Color(hex: "#4A9E5C"))
                : Color.adaptive(light: Color(hex: "#0A7D3B"), dark: Color(hex: "#30D158"))
        case .warn:
            return isNothingTheme
                ? Color.adaptive(light: Color(hex: "#B8860B"), dark: Color(hex: "#D4A843"))
                : Color.adaptive(light: Color(hex: "#B25000"), dark: Color(hex: "#D4A843"))
        case .error:
            return isNothingTheme
                ? Color.adaptive(light: Color(hex: "#C62828"), dark: Color(hex: "#D71921"))
                : Color.adaptive(light: Color(hex: "#C62828"), dark: Color(hex: "#E5534B"))
        case .neutral:
            return isNothingTheme
                ? Color.adaptive(light: Color(hex: "#999999"), dark: Color(hex: "#666666"))
                : Color.adaptive(light: Color(hex: "#8E8E93"), dark: Color(hex: "#8A8A8A"))
        }
    }

    /// 顶部分隔发线: 1px 高度, 与 footerHairline 保持严格分层对称
    private var headerHairline: some View {
        Rectangle()
            .fill(footerHairlineColor)
            .frame(height: 1)
    }

    // MARK: 卡片栈与 Tab 视图

    @ViewBuilder
    private func glassCardStack(_ panel: PanelViewModel) -> some View {
        // The AppKit surface is the single window-level material. Keeping the
        // existing card backgrounds independent avoids blurring dashboard text
        // and charts through a container that spans the full scroll content.
        if model.layoutMode == .tabbed {
            tabbedCardView(panel)
        } else {
            cardStack(panel)
        }
    }

    /// Tab 模式：单卡渲染 + 方案 1 水平定向滑动过渡
    @ViewBuilder
    private func tabbedCardView(_ panel: PanelViewModel) -> some View {
        let hasCards = panel.usage != nil
            || panel.subscription != nil
            || panel.hourly != nil
        Group {
            if hasCards {
                renderSingleTabCard(model.selectedCardID, panel: panel)
                    .id(model.selectedCardID)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: slideDirection).combined(with: .opacity),
                            removal: .move(edge: slideDirection == .trailing ? .leading : .trailing).combined(with: .opacity)
                        )
                    )
            } else {
                emptyPanelState
            }
        }
        .padding(.horizontal, isNothingTheme ? 10 : 12)
        .padding(.top, isNothingTheme ? 8 : 10)
        .padding(.bottom, isNothingTheme ? 10 : 4)
    }

    @ViewBuilder
    private func renderSingleTabCard(_ cardID: DashboardCardID, panel: PanelViewModel) -> some View {
        switch cardID {
        case .usage:
            if let usage = panel.usage {
                PanelCardContainer {
                    UsageHeroCard(
                        viewModel: usage,
                        panelVisible: model.dashboardPanelVisible,
                        isCollapsed: false,
                        onToggleCollapse: {}
                    )
                }
            } else {
                fallbackTabCard(panel)
            }
        case .subscription:
            if let subscription = panel.subscription {
                PanelCardContainer {
                    SubscriptionCard(
                        viewModel: subscription,
                        isCollapsed: false,
                        onToggleCollapse: {},
                        refreshControls: subscriptionRefreshControls(for: subscription),
                        onRefreshProvider: { provider in
                            coordinator.refreshSubscription(provider)
                        },
                        panelVisible: model.dashboardPanelVisible
                    )
                }
            } else {
                fallbackTabCard(panel)
            }
        case .hourly:
            if let hourly = panel.hourly {
                PanelCardContainer {
                    HourlyLineCard(
                        viewModel: hourly,
                        dailyDays: panel.usage?.days ?? [],
                        dailyLegend: panel.usage?.legend ?? [],
                        isCollapsed: false,
                        onToggleCollapse: {},
                        panelVisible: model.dashboardPanelVisible
                    )
                }
            } else {
                fallbackTabCard(panel)
            }
        }
    }

    @ViewBuilder
    private func fallbackTabCard(_ panel: PanelViewModel) -> some View {
        if let usage = panel.usage {
            PanelCardContainer {
                UsageHeroCard(
                    viewModel: usage,
                    panelVisible: model.dashboardPanelVisible,
                    isCollapsed: false,
                    onToggleCollapse: {}
                )
            }
        } else if let subscription = panel.subscription {
            PanelCardContainer {
                SubscriptionCard(
                    viewModel: subscription,
                    isCollapsed: false,
                    onToggleCollapse: {},
                    refreshControls: subscriptionRefreshControls(for: subscription),
                    onRefreshProvider: { provider in
                        coordinator.refreshSubscription(provider)
                    },
                    panelVisible: model.dashboardPanelVisible
                )
            }
        } else if let hourly = panel.hourly {
            PanelCardContainer {
                HourlyLineCard(
                    viewModel: hourly,
                    dailyDays: panel.usage?.days ?? [],
                    dailyLegend: panel.usage?.legend ?? [],
                    isCollapsed: false,
                    onToggleCollapse: {},
                    panelVisible: model.dashboardPanelVisible
                )
            }
        } else {
            emptyPanelState
        }
    }

    /// 切换 Tab 并自动判定水平滑入方向
    private func selectTab(_ target: DashboardCardID) {
        guard target != model.selectedCardID else { return }
        let order: [DashboardCardID] = [.usage, .subscription, .hourly]
        let fromIndex = order.firstIndex(of: model.selectedCardID) ?? 0
        let toIndex = order.firstIndex(of: target) ?? 0
        slideDirection = toIndex > fromIndex ? .trailing : .leading
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            model.selectCard(target)
        }
    }

    @ViewBuilder
    private func cardStack(_ panel: PanelViewModel) -> some View {
        let hasCards = panel.usage != nil
            || panel.subscription != nil
            || panel.hourly != nil
        VStack(spacing: isNothingTheme ? 8 : 10) {
            ForEach(model.cardOrder) { cardID in
                let isCollapsed = model.isCardCollapsed(cardID)
                let card = renderCard(cardID, panel: panel)
                if isCollapsed {
                    card
                        .draggable(cardID.rawValue)
                        .onDrop(
                            of: [.text],
                            delegate: DashboardCardDropDelegate(
                                target: cardID,
                                move: { model.moveCard(from: $0, to: $1) }
                            )
                        )
                } else {
                    card
                }
            }
            if !hasCards {
                emptyPanelState
            }
        }
        .padding(.horizontal, isNothingTheme ? 10 : 12)
        .padding(.top, isNothingTheme ? 8 : 10)
        .padding(.bottom, isNothingTheme ? 10 : 4)
    }

    @ViewBuilder
    private func renderCard(_ cardID: DashboardCardID, panel: PanelViewModel) -> some View {
        switch cardID {
        case .usage:
            if let usage = panel.usage {
                PanelCardContainer {
                    UsageHeroCard(
                        viewModel: usage,
                        panelVisible: model.dashboardPanelVisible,
                        isCollapsed: model.isCardCollapsed(.usage),
                        onToggleCollapse: { model.toggleCardCollapsed(.usage) }
                    )
                }
            }
        case .subscription:
            if let subscription = panel.subscription {
                PanelCardContainer {
                    SubscriptionCard(
                        viewModel: subscription,
                        isCollapsed: model.isCardCollapsed(.subscription),
                        onToggleCollapse: { model.toggleCardCollapsed(.subscription) },
                        refreshControls: subscriptionRefreshControls(for: subscription),
                        onRefreshProvider: { provider in
                            coordinator.refreshSubscription(provider)
                        },
                        panelVisible: model.dashboardPanelVisible
                    )
                }
            }
        case .hourly:
            if let hourly = panel.hourly {
                PanelCardContainer {
                    HourlyLineCard(
                        viewModel: hourly,
                        dailyDays: panel.usage?.days ?? [],
                        dailyLegend: panel.usage?.legend ?? [],
                        isCollapsed: model.isCardCollapsed(.hourly),
                        onToggleCollapse: { model.toggleCardCollapsed(.hourly) },
                        panelVisible: model.dashboardPanelVisible
                    )
                }
            }
        }
    }

    /// 卡片全 nil 时的兜底: 居中玻璃卡 + 设置入口.
    private var emptyPanelState: some View {
        PanelCardContainer {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("未配置模块, 前往设置")
                    .font(isNothingTheme
                        ? NothingFont.ui(13, weight: .semibold)
                        : .headline)
                Button("打开设置", action: openSettings)
                    .font(isNothingTheme ? NothingFont.ui(13) : nil)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    /// 订阅卡各 Provider 的刷新按钮呈现: 按 section ID 解析目标 Provider
    /// (fail-closed, 未知 service 不出按钮), 呈现状态由 AppModel 按契约计算
    /// (目标刷新中 / 全量刷新冲突 / 未配置 / 未启用 / 模块不可运行).
    private func subscriptionRefreshControls(
        for viewModel: SubscriptionViewModel
    ) -> [String: SubscriptionRefreshControlPresentation] {
        var controls: [String: SubscriptionRefreshControlPresentation] = [:]
        for section in viewModel.sections {
            guard let provider = SubscriptionRefreshControlPolicy.providerID(
                forSectionID: section.id
            ) else { continue }
            controls[provider.rawValue] = model.subscriptionRefreshControl(
                for: provider, displayName: section.name
            )
        }
        return controls
    }

    // MARK: 底栏

    /// mockup 底栏顶部分隔: 白 0.5 发线, 深色下弱化为常规分隔色.
    /// Nothing: 按定稿为 1px 边框色 (#222222 dark / #E8E8E8 light).
    private var footerHairline: some View {
        Rectangle()
            .fill(footerHairlineColor)
            .frame(height: 1)
    }

    private var footerHairlineColor: Color {
        if isNothingTheme {
            return colorScheme == .dark
                ? Color(hex: "#222222")
                : Color(hex: "#E8E8E8")
        }
        return colorScheme == .dark
            ? Color.primary.opacity(0.15)
            : Color.white.opacity(0.5)
    }

    /// Nothing 底栏背景色: dark 纯黑 / light #F5F5F5 (定稿 token).
    private var nothingFooterBackgroundColor: Color {
        colorScheme == .dark
            ? Color(hex: "#000000")
            : Color(hex: "#F5F5F5")
    }

    private var actionFooter: some View {
        let refreshableModules = CollectorModule.allCases.filter {
            model.canRunCollector(for: $0)
        }
        let refreshing = model.moduleStatuses.values.contains {
            $0.state == .refreshing
        }
        return HStack(spacing: 8) {
            Button {
                for module in refreshableModules {
                    coordinator.refresh(module)
                }
            } label: {
                Label {
                    Text("刷新")
                } icon: {
                    // 面板隐藏期间不渲染旋转图标: repeatForever 动画在
                    // orderOut 的窗口里仍逐帧驱动 (见 panelVisible 注释).
                    if refreshing, model.dashboardPanelVisible {
                        SpinningRefreshIcon()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshableModules.isEmpty)
            .accessibilityLabel(refreshing ? "正在刷新全部模块" : "刷新全部模块")
            .accessibilityHint("使用当前授权重新采集全部已就绪模块")
            // 外观切换: 单击在「跟随系统 -> 浅色 -> 深色」间循环,
            // 图标即当前态; 与设置中心「配色模式」共用同一持久化偏好.
            Button {
                coordinator.setAppearanceMode(coordinator.appearanceMode.next)
            } label: {
                Label {
                    Text("外观")
                } icon: {
                    Image(systemName: coordinator.appearanceMode.symbolName)
                }
            }
            .accessibilityLabel("外观：\(coordinator.appearanceMode.displayName)")
            .accessibilityHint("点击切换浅色、深色或跟随系统")
            .help("外观：\(coordinator.appearanceMode.displayName)（点击切换）")
            Spacer()
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            Button(action: terminateApplication) {
                Label("退出", systemImage: "power")
            }
        }
        .labelStyle(.iconOnly)
        .help("刷新、外观、设置或退出 Bruce")
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .panelGlassButtonStyle()
    }
}


// MARK: - ScrollIndicatorSuppressor

/// macOS 26 上 `.scrollIndicators(.hidden)` 不生效: HostingScrollView 在
/// 附加后仍被系统重设为 `hasVerticalScroller = true` (本地最小复现实证).
/// 该视图放在 ScrollView 内容内, 附加到窗口后向上找到 NSScrollView 并持续
/// 压制 scroller; 滚动本身经 NSClipView 完成, 滚轮/触控板不受影响.
private struct ScrollIndicatorSuppressor: NSViewRepresentable {
    /// 面板可见性 (C044): 隐藏时看门狗必须停止 —— orderOut 不触发视图离窗,
    /// 否则首次打开面板后 0.3s Timer 会终身运行.
    var panelVisible: Bool = true

    func makeNSView(context: Context) -> SuppressorView {
        let view = SuppressorView()
        view.panelVisible = panelVisible
        return view
    }

    func updateNSView(_ nsView: SuppressorView, context: Context) {
        nsView.panelVisible = panelVisible
        DispatchQueue.main.async { nsView.enforce() }
    }
}

private final class SuppressorView: NSView {
    private var watchdog: Timer?

    /// 由 `DashboardPanelAnimationPolicy.allowsSuppressorWatchdog` 派生:
    /// 隐藏态不跑 0.3s 周期 Timer.
    var panelVisible: Bool = true {
        didSet {
            guard panelVisible != oldValue else { return }
            syncWatchdog()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncWatchdog()
    }

    private func syncWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
        guard window != nil,
              DashboardPanelAnimationPolicy.allowsSuppressorWatchdog(panelVisible: panelVisible)
        else { return }
        enforce()
        // SwiftUI 会在附加后的若干 runloop 及后续布局中反复重设 scroller,
        // 用轻量看门狗持续压制; 面板关闭或隐藏时停止.
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) {
            [weak self] _ in
            // Timer 回调非隔离; 调度回主线程再碰 NSView 层级.
            DispatchQueue.main.async {
                self?.enforce()
            }
        }
    }

    func enforce() {
        var current = superview
        while let view = current {
            if let scrollView = view as? NSScrollView {
                // legacy scroller 即使隐藏也会占约 17pt 布局宽度, 造成左右
                // 内边距不对称; 先切 overlay 样式 (不占布局) 再关闭 scroller.
                if scrollView.scrollerStyle != .overlay {
                    scrollView.scrollerStyle = .overlay
                }
                if scrollView.hasVerticalScroller {
                    scrollView.hasVerticalScroller = false
                }
                if scrollView.hasHorizontalScroller {
                    scrollView.hasHorizontalScroller = false
                }
                return
            }
            current = view.superview
        }
    }
}
