import AppKit
import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// 菜单栏状态项 + 仪表盘弹出面板控制器. 替换 MenuBarExtra, 提供程序化开/关.
@MainActor
final class MenuBarStatusItemController: NSObject {
    private let model: AppModel
    private let coordinator: OnboardingCoordinator
    private let openSettings: @MainActor () -> Void
    private let terminateApplication: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var installed = false

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

    /// 创建状态项与弹出面板. 幂等; 在 applicationDidFinishLaunching 调用.
    func install() {
        guard !installed else { return }
        installed = true

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let hostingView = NSHostingView(rootView: MenuBarLabelView(model: model))
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

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarDashboardView(
                openSettings: openSettings,
                terminateApplication: terminateApplication
            )
            .environmentObject(model)
            .environmentObject(coordinator)
        )
        statusItem = item
    }

    /// 切换仪表盘面板开/关 (全局快捷键与状态项点击共用).
    func toggleDashboard() {
        guard installed, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: false)
        }
    }

    /// 退出时清理.
    func teardown() {
        if popover.isShown {
            popover.performClose(nil)
        }
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        toggleDashboard()
    }
}
