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

/// 菜单栏原生液态玻璃面板: 纵向卡片 (按 PanelViewModel 非 nil 渲染) + 底栏.
/// 卡片栈包 ScrollView: 内容超出屏幕可用高度时封顶出滚动条, 不足时高度自适应;
/// 底栏在滚动区外固定; 卡片全空时展示未配置引导.
struct MenuBarDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.colorScheme) private var colorScheme

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
                    ScrollIndicatorSuppressor()
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

        HStack(spacing: isNothingTheme ? 8 : 10) {
            // 左侧：呼吸指示灯 + 品牌与终端标识
            HStack(spacing: 6) {
                topHeaderStatusDot(isLive: isLive)
                if isNothingTheme {
                    Text("BRUCE // HUD")
                        .font(NothingFont.ui(11, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#1A1A1A"),
                            dark: Color(hex: "#E8E8E8")
                        ))
                    Text("SYS.OK")
                        .font(NothingFont.mono(8.5))
                        .foregroundStyle(Color.adaptive(
                            light: Color(hex: "#666666"),
                            dark: Color(hex: "#8A8A8A")
                        ))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(
                                    Color.adaptive(light: Color(hex: "#CCCCCC"), dark: Color(hex: "#303030")),
                                    lineWidth: 1
                                )
                        }
                } else {
                    Text("Bruce // HUD")
                        .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.primary)
                    Text("SYS.OK")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        }
                }
            }

            Spacer(minLength: 0)

            // 右侧：全局 AI / Agent 状态指示
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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// 顶部状态呼吸灯: 实时态微弱脉冲, 待机态常亮小点
    @ViewBuilder
    private func topHeaderStatusDot(isLive: Bool) -> some View {
        let dotColor: Color = isNothingTheme
            ? Color.adaptive(light: Color(hex: "#D4A843"), dark: Color(hex: "#4A9E5C"))
            : Color.adaptive(light: Color(hex: "#0A7D3B"), dark: Color(hex: "#30D158"))

        ZStack {
            if isLive {
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

    /// 顶部分隔发线: 1px 高度, 与 footerHairline 保持严格分层对称
    private var headerHairline: some View {
        Rectangle()
            .fill(footerHairlineColor)
            .frame(height: 1)
    }

    // MARK: 卡片栈

    @ViewBuilder
    private func glassCardStack(_ panel: PanelViewModel) -> some View {
        // The AppKit surface is the single window-level material. Keeping the
        // existing card backgrounds independent avoids blurring dashboard text
        // and charts through a container that spans the full scroll content.
        cardStack(panel)
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
                        }
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
                        onToggleCollapse: { model.toggleCardCollapsed(.hourly) }
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
            Spacer()
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            Button(action: terminateApplication) {
                Label("退出", systemImage: "power")
            }
        }
        .labelStyle(.iconOnly)
        .help("刷新、设置或退出 Bruce")
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
    func makeNSView(context: Context) -> SuppressorView {
        SuppressorView()
    }

    func updateNSView(_ nsView: SuppressorView, context: Context) {
        DispatchQueue.main.async { nsView.enforce() }
    }
}

private final class SuppressorView: NSView {
    private var watchdog: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchdog?.invalidate()
        watchdog = nil
        guard window != nil else { return }
        enforce()
        // SwiftUI 会在附加后的若干 runloop 及后续布局中反复重设 scroller,
        // 用轻量看门狗持续压制; 面板关闭 (离窗) 时停止.
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
