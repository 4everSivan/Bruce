import AppKit
import Foundation
import MdddAppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: ApplicationLifecycleCoordinator?
    /// 配置窗口控制器: 用于 Dock 点击时重新打开设置.
    private weak var settingsWindowController: SettingsWindowController?

    func configure(
        runtime: ApplicationRuntimeControlling,
        settingsWindowController: SettingsWindowController? = nil
    ) {
        if lifecycle == nil {
            lifecycle = ApplicationLifecycleCoordinator(
                runtime: runtime
            )
        }
        if let settingsWindowController {
            self.settingsWindowController = settingsWindowController
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏优先: 默认不占 Dock; 打开配置窗口时由 SettingsWindowController 切到 .regular.
        _ = NSApp.setActivationPolicy(.accessory)
    }

    /// Dock 图标点击 (配置窗口打开期间): 前置设置窗口, 不另外新建窗口.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        settingsWindowController?.handleDockReopen()
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let lifecycle else {
            return .terminateNow
        }
        lifecycle.beginTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
