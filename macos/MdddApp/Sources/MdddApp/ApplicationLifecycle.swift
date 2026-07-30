import AppKit
import Foundation
import MdddAppCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var lifecycle: ApplicationLifecycleCoordinator?

    func configure(runtime: ApplicationRuntimeControlling) {
        guard lifecycle == nil else { return }
        lifecycle = ApplicationLifecycleCoordinator(
            runtime: runtime
        )
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
