import AppKit
import Foundation
import MdddAppCore

enum MainWindow {
    static let identifier = NSUserInterfaceItemIdentifier("mddd.main-window")
}

@MainActor
final class AppKitMainWindowPresenter: MainWindowPresenting {
    func presentMainWindow() {
        guard let window = NSApplication.shared.windows.first(where: {
            $0.identifier == MainWindow.identifier
        }) else {
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: ApplicationLifecycleCoordinator?
    private let dockBadgeController: DockBadgeControlling

    override init() {
        dockBadgeController = AppKitDockBadgeController()
        super.init()
    }

    init(dockBadgeController: DockBadgeControlling) {
        self.dockBadgeController = dockBadgeController
        super.init()
    }

    func configure(runtime: ApplicationRuntimeControlling) {
        guard lifecycle == nil else { return }
        lifecycle = ApplicationLifecycleCoordinator(
            runtime: runtime,
            windowPresenter: AppKitMainWindowPresenter()
        )
    }

    func setDockBadge(_ state: DockBadgeState) {
        dockBadgeController.setBadge(state)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        lifecycle?.reopenMainWindow()
        return false
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
