import AppKit
import Foundation
import BruceAppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: ApplicationLifecycleCoordinator?
    /// 配置窗口控制器: 用于 Dock 点击时重新打开设置.
    private weak var settingsWindowController: SettingsWindowController?
    private var statusItemController: MenuBarStatusItemController?
    private var hotkeyMonitor: GlobalHotkeyMonitor?
    private var startApplication: (@MainActor () -> Void)?

    func configure(
        runtime: ApplicationRuntimeControlling,
        settingsWindowController: SettingsWindowController? = nil,
        statusItemController: MenuBarStatusItemController? = nil,
        hotkeyMonitor: GlobalHotkeyMonitor? = nil,
        startApplication: (@MainActor () -> Void)? = nil
    ) {
        if lifecycle == nil {
            lifecycle = ApplicationLifecycleCoordinator(
                runtime: runtime
            )
        }
        if let settingsWindowController {
            self.settingsWindowController = settingsWindowController
        }
        if let statusItemController {
            self.statusItemController = statusItemController
        }
        if let hotkeyMonitor {
            self.hotkeyMonitor = hotkeyMonitor
        }
        if let startApplication {
            self.startApplication = startApplication
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏优先: 启动时保持 accessory; 配置窗口打开时由 SettingsWindowController 切换为 regular 显示 Dock.
        _ = NSApp.setActivationPolicy(.accessory)
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame com_apple_SwiftUI_Settings_window")
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        statusItemController?.install()
        startApplication?()

        // 若系统在启动时尝试恢复非托管的系统设置窗口, 异步安全清除, 防止出现双窗口
        DispatchQueue.main.async { [weak self] in
            for window in NSApp.windows where window !== self?.settingsWindowController?.managedWindow {
                if window.title == "Bruce设置" || window.identifier?.rawValue.contains("Settings") == true {
                    window.orderOut(nil)
                    window.close()
                }
            }
        }
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

    /// 用户取消退出 (系统对话框取消 / 再次触发退出前被驳回): 恢复调度,
    /// 使后续手动/自动刷新继续可用. 与 beginTermination 对称.
    func applicationDidCancelTerminate(_ sender: NSApplication) {
        lifecycle?.cancelTermination()
    }

    /// 退出时注销全局快捷键并清理状态项.
    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.unregister()
        statusItemController?.teardown()
    }
}
