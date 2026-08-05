import AppKit
import MdddAppCore
import MdddOnboardingCore
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

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel

    private var summary: MenuBarSummary {
        MenuBarSummaryBuilder().build(
            agentArtifact: model.moduleArtifacts[.agentUsage],
            moduleStatuses: model.moduleStatuses
        )
    }

    /// 任一模块处于刷新中: 品牌图标替换为旋转刷新指示.
    private var isRefreshing: Bool {
        model.moduleStatuses.values.contains { $0.state == .refreshing }
    }

    /// 需要用户干预的状态才在菜单栏追加警示符号, 常态保持干净.
    private var showsAttention: Bool {
        switch summary.overallStatus {
        case .authRequired, .failed, .offline:
            return true
        default:
            return false
        }
    }

    var body: some View {
        let formatter = MenuBarMetricFormatter()
        HStack(spacing: 5) {
            if isRefreshing {
                SpinningRefreshIcon()
            } else {
                MenuBarBrandIcon()
            }
            ForEach(model.menuBarMetrics) { metric in
                Text(formatter.string(for: metric, summary: summary))
                    .monospacedDigit()
            }
            if showsAttention {
                Image(systemName: summary.overallStatus.symbolName)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(formatter: formatter))
    }

    private func accessibilitySummary(
        formatter: MenuBarMetricFormatter
    ) -> String {
        let metrics = model.menuBarMetrics.map {
            "\($0.title) \(formatter.string(for: $0, summary: summary))"
        }
        return (["mddd", summary.overallStatus.title] + metrics)
            .joined(separator: ", ")
    }
}

/// 菜单栏品牌图标: 仪表盘符号, 模板渲染, 呼应额度与用量仪表.
private struct MenuBarBrandIcon: View {
    var body: some View {
        Image(systemName: "gauge.with.dots.needle.67percent")
            .symbolRenderingMode(.monochrome)
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

    /// 卡片栈实测理想高度; 0 表示尚未测量到 (首帧), 此时不加高度约束保持自适应.
    @State private var cardStackHeight: CGFloat = 0

    /// 底栏实测高度 (发线+操作行); 0 表示尚未测量, 封顶时用 49 兜底预留, 保证底栏不被挤出屏幕.
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        let panel = model.makePanelViewModel()
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    // macOS 26 上 scrollIndicators(.hidden) 会被系统重设, 用
                    // AppKit 看门狗持续压制 scroller; 滚轮滚动不受影响.
                    ScrollIndicatorSuppressor()
                        .frame(width: 0, height: 0)
                    cardStack(panel)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                    // 仅变化时更新, 并忽略亚像素抖动, 避免回环引起布局振荡.
                    guard height > 0, abs(height - cardStackHeight) > 0.5 else { return }
                    cardStackHeight = height
                }
            }
            // 窗口自动尺寸时 ScrollView 理想高度塌陷, maxHeight 不解决理想高度;
            // 用 onGeometryChange 实测内容高度驱动 frame: 未测量 (首帧) 不加约束,
            // 测量后取 min(内容高, 屏上限扣除底栏), 确保底栏始终留在屏幕内.
            .frame(height: cardStackHeight > 0
                ? min(cardStackHeight, Self.maxCardStackHeight - max(footerHeight, 49))
                : nil)
            // 隐藏滚动指示条, 滚轮/触控板滚动不受影响.
            .scrollIndicators(.hidden)
            VStack(spacing: 0) {
                footerHairline
                actionFooter
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                guard height > 0, abs(height - footerHeight) > 0.5 else { return }
                footerHeight = height
            }
        }
        .frame(width: 440)
        .background { panelGlassBackground }
        .preferredColorScheme(coordinator.appearanceMode.colorScheme)
        .environment(\.mdddResolvedTheme, coordinator.resolvedTheme)
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

    // MARK: 面板玻璃背景

    /// 液态玻璃模式用系统 glassEffect; 经典/哑光退化为材料质感; 圆角 22 对齐 mockup.
    @ViewBuilder
    private var panelGlassBackground: some View {
        let theme = coordinator.resolvedTheme
        if theme.usesLiquidGlassEffects {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(
                    theme.glassStyle.liquidGlassAPI, in: .rect(cornerRadius: 22)
                )
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.regularMaterial)
            }
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    // MARK: 卡片栈

    @ViewBuilder
    private func cardStack(_ panel: PanelViewModel) -> some View {
        let hasCards = panel.usage != nil
            || panel.subscription != nil
            || panel.hourly != nil
        VStack(spacing: 10) {
            if let usage = panel.usage {
                PanelCardContainer {
                    UsageHeroCard(viewModel: usage)
                }
            }
            if let subscription = panel.subscription {
                PanelCardContainer {
                    SubscriptionCard(viewModel: subscription)
                }
            }
            if let hourly = panel.hourly {
                PanelCardContainer {
                    HourlyLineCard(viewModel: hourly)
                }
            }
            if !hasCards {
                emptyPanelState
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 卡片全 nil 时的兜底: 居中玻璃卡 + 设置入口.
    private var emptyPanelState: some View {
        PanelCardContainer {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("未配置模块, 前往设置")
                    .font(.headline)
                Button("打开设置", action: openSettings)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    // MARK: 底栏

    /// mockup 底栏顶部分隔: 白 0.5 发线, 深色下弱化为常规分隔色.
    private var footerHairline: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color.primary.opacity(0.15)
                    : Color.white.opacity(0.5)
            )
            .frame(height: 1)
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
                    if refreshing {
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
        .help("刷新、设置或退出 mddd")
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
