import AppKit
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
            let hostingView = NSHostingView(rootView: MenuBarLabelView(model: model))
            // 状态项按钮无 title/image, 默认 sizingOptions 不提供内在尺寸,
            // 按钮会折叠为 0 宽导致标签不可见; preferredContentSize 让 hosting
            // view 报告 SwiftUI 内容的理想尺寸, 按钮随之取宽.
            hostingView.sizingOptions = .preferredContentSize
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: button.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            ])
            button.target = self
            button.action = #selector(statusItemClicked(_:))
        }

        panel.contentViewController = NSHostingController(
            rootView: MenuBarDashboardView(
                openSettings: { [weak self] in
                    // 打开设置前先关面板, 避免 statusBar 层级面板浮在设置窗口之上.
                    self?.closeDashboard(restorePreviousFrontmostApp: false)
                    self?.openSettings()
                },
                terminateApplication: terminateApplication,
                onContentSizeChange: { [weak self] size in
                    // onGeometryChange 回调运行在主线程, 安全.
                    MainActor.assumeIsolated { self?.resizePanel(to: size) }
                }
            )
            .environmentObject(model)
            .environmentObject(coordinator)
        )
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
        closeDashboard(restorePreviousFrontmostApp: false)
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
