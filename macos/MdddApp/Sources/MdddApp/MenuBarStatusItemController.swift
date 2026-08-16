import AppKit
import Combine
import MdddAppCore
import SwiftUI

/// 菜单栏状态项 + 仪表盘弹出面板控制器. 替换 MenuBarExtra, 提供程序化开/关.
///
/// 面板用无边框 `NSPanel` 承载 (而非 `NSPopover`):
/// - `NSPopover` 无公开 API 隐藏箭头, 也无法去掉开合动画; 无边框面板两者皆无.
/// - 面板可成为 key 窗口, 支持 ⌘R 等快捷键; 点击其他应用时经 resignActive 关闭,
///   行为与 `.transient` popover 的点外关闭一致.
/// - toggle 关闭时把前台归还给打开前的应用, 避免焦点留在 mddd.
@MainActor
final class MenuBarStatusItemController: NSObject {
    private let model: AppModel
    private let coordinator: OnboardingCoordinator
    private let openSettings: @MainActor () -> Void
    private let terminateApplication: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private let panel = DashboardPanel(
        contentRect: .zero,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    private var installed = false
    /// 打开面板前的前台应用; toggle 关闭时归还前台. 打开时前台已是 mddd 则为 nil.
    private var previousFrontmostApp: NSRunningApplication?
    /// 模型变化时重绘状态栏标签图像 (指标值, 刷新状态, 警示符号均驱动显示).
    private var labelSubscription: AnyCancellable?
    /// 状态栏图片由 ImageRenderer 生成静态帧, 用主线程定时器推进刷新角度.
    private var refreshAnimationTimer: Timer?
    private var refreshAnimationRotation = 0.0
    /// 仪表盘 AppKit 系统材质宿主; 与业务模型和刷新流程隔离.
    private var dashboardGlassController: DashboardGlassPanelController?

    init(
        model: AppModel,
        coordinator: OnboardingCoordinator,
        openSettings: @escaping @MainActor () -> Void,
        terminateApplication: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.coordinator = coordinator
        self.openSettings = openSettings
        self.terminateApplication = terminateApplication
        super.init()
    }

    /// 创建状态项与仪表盘面板. 幂等; 在 applicationDidFinishLaunching 调用.
    func install() {
        guard !installed else { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // 状态项按钮无 title/image 时, 其内在尺寸只由 button.image/title
            // 决定, 不感知子视图 (实测 hosting 子视图方案按钮折叠为 0 宽, 状态栏
            // 不显示任何内容). 用 ImageRenderer 把 SwiftUI 标签栅格化为按钮图像,
            // 状态栏据此确定按钮宽度, 颜色随菜单栏明暗自适应.
            refreshLabelImage(on: button)
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 模型任何 @Published 变化都重绘标签; objectWillChange 在值应用前
            // 发出, 调度到下一轮 main-actor 取到新值再渲染.
            labelSubscription = model.objectWillChange
                .sink { [weak self] _ in
                    Task { @MainActor in
                        self?.synchronizeRefreshAnimation()
                        self?.refreshLabelImage()
                    }
                }
            synchronizeRefreshAnimation()
        }

        let rootView = MenuBarDashboardView(
            openSettings: { [weak self] in
                // 打开设置前先关面板, 避免 statusBar 层级面板浮在设置窗口之上.
                self?.closeDashboard(restorePreviousFrontmostApp: false)
                self?.openSettings()
            },
            terminateApplication: terminateApplication,
            onContentSizeChange: { [weak self] size in
                // onGeometryChange 回调运行在主线程, 安全.
                MainActor.assumeIsolated { self?.resizePanel(to: size) }
            },
            onSurfaceThemeChange: { [weak self] theme, colorScheme in
                self?.dashboardGlassController?.updateSurface(theme: theme, preferredColorScheme: colorScheme)
            }
        )
        .environmentObject(model)
        .environmentObject(coordinator)
        let glassController = DashboardGlassPanelController(
            rootView: rootView,
            theme: coordinator.resolvedTheme,
            preferredColorScheme: coordinator.appearanceMode.colorScheme
        )
        dashboardGlassController = glassController
        panel.contentViewController = glassController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        // 点击其他应用时关闭面板 (模拟 transient popover 的点外关闭).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        statusItem = item
    }

    // MARK: - 状态栏标签图像

    /// 重绘状态项按钮图像 (当前按钮).
    private func refreshLabelImage() {
        guard let button = statusItem?.button else { return }
        refreshLabelImage(on: button)
    }

    /// 用 ImageRenderer 栅格化 MenuBarLabelView 为按钮图像.
    /// 渲染成白色单色轮廓并标记 isTemplate, 由菜单栏按自身明暗自动着色
    /// (浅色菜单栏黑色, 深色菜单栏白色), 与原生状态项图标同一机制: 不依赖
    /// 外观检测, 外观切换也无需重绘.
    private func refreshLabelImage(on button: NSStatusBarButton) {
        let renderer = ImageRenderer(
            content: MenuBarLabelView(
                model: model,
                refreshRotation: refreshAnimationRotation
            )
                .foregroundStyle(.white)
        )
        renderer.scale = button.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        // 渲染失败时保留旧图, 避免按钮清空回退到不可见.
        guard let image = renderer.nsImage else { return }
        image.isTemplate = true
        button.image = image
        button.setAccessibilityLabel(menuBarAccessibilityLabel)
    }

    private var isRefreshing: Bool {
        model.moduleStatuses.values.contains { $0.state == .refreshing }
    }

    /// 刷新开始/结束时同步状态栏动画. 用显式角度而非 SwiftUI 无限动画,
    /// 这样 ImageRenderer 不会只抓到一个静态首帧或丢失旁边的用量文本.
    private func synchronizeRefreshAnimation() {
        if isRefreshing {
            guard refreshAnimationTimer == nil else { return }
            refreshAnimationRotation = 0
            let timer = Timer(
                timeInterval: 1.0 / 12.0,
                target: self,
                selector: #selector(advanceRefreshAnimation),
                userInfo: nil,
                repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            refreshAnimationTimer = timer
        } else {
            refreshAnimationTimer?.invalidate()
            refreshAnimationTimer = nil
            refreshAnimationRotation = 0
        }
    }

    @objc private func advanceRefreshAnimation() {
        guard isRefreshing else {
            synchronizeRefreshAnimation()
            refreshLabelImage()
            return
        }
        refreshAnimationRotation = (refreshAnimationRotation + 30)
            .truncatingRemainder(dividingBy: 360)
        refreshLabelImage()
    }

    /// 与 MenuBarLabelView 内部一致的辅助功能描述.
    private var menuBarAccessibilityLabel: String {
        let formatter = MenuBarMetricFormatter()
        let summary = model.makeMenuBarSummary()
        let metrics = model.menuBarMetrics.map {
            "\($0.title) \(formatter.string(for: $0, summary: summary))"
        }
        return (["mddd", summary.overallStatus.title] + metrics)
            .joined(separator: ", ")
    }

    /// 切换仪表盘开/关 (全局快捷键与状态项点击共用).
    func toggleDashboard() {
        guard installed, let button = statusItem?.button else { return }
        if panel.isVisible {
            closeDashboard(restorePreviousFrontmostApp: true)
        } else {
            openDashboard(relativeTo: button)
        }
    }

    /// 退出时清理.
    func teardown() {
        NotificationCenter.default.removeObserver(self)
        labelSubscription?.cancel()
        labelSubscription = nil
        refreshAnimationTimer?.invalidate()
        refreshAnimationTimer = nil
        closeDashboard(restorePreviousFrontmostApp: false)
        dashboardGlassController = nil
        panel.contentViewController = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggleDashboard()
    }

    // MARK: - 面板开关

    private func openDashboard(relativeTo button: NSStatusBarButton) {
        // 先记录打开前的前台应用 (打开路径会把 mddd 激活, 前台切到 mddd).
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousFrontmostApp = (frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier)
            ? nil
            : frontmost
        if let size = panel.contentViewController?.view.fittingSize,
           size.width > 0, size.height > 0 {
            panel.setContentSize(size)
        }
        let screenRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? button.convert(button.bounds, to: nil)
        var origin = NSPoint(
            x: screenRect.midX - panel.frame.width / 2,
            y: screenRect.minY - panel.frame.height - 6
        )
        // 窄屏防越界: 面板保持完整可见 (左右各留 8pt 边距).
        if let screen = button.window?.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
        }
        panel.setFrameOrigin(origin)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关闭面板; toggle 关闭时把前台归还给打开前的应用,
    /// 因点击其他应用而关闭 (resignActive) 时不归还 (对方已是前台).
    private func closeDashboard(restorePreviousFrontmostApp: Bool) {
        if panel.isVisible {
            panel.orderOut(nil)
        }
        let previous = previousFrontmostApp
        previousFrontmostApp = nil
        if restorePreviousFrontmostApp, let previous {
            previous.activate(options: [])
        }
    }

    /// SwiftUI 内容理想尺寸变化时跟随调整面板 (顶边固定, 高度变化向下延伸).
    private func resizePanel(to size: CGSize) {
        guard panel.isVisible, size.width > 0, size.height > 0,
              abs(size.height - panel.frame.height) > 1 else {
            return
        }
        let topY = panel.frame.maxY
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: topY - panel.frame.height))
    }

    @objc private func applicationDidResignActive(_ note: Notification) {
        // 用户点击了其他应用 → 关闭面板, 不强制归还前台.
        closeDashboard(restorePreviousFrontmostApp: false)
    }
}

/// 无边框面板默认不能成为 key; 仪表盘需要 key 窗口支持 ⌘R 等快捷键.
private final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
