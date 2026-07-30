import AppKit
import MdddAppCore

@MainActor
protocol DockBadgeControlling: AnyObject {
    func setBadge(_ state: DockBadgeState)
}

@MainActor
final class AppKitDockBadgeController: DockBadgeControlling {
    func setBadge(_ state: DockBadgeState) {
        NSApplication.shared.dockTile.badgeLabel = state.label
        NSApplication.shared.dockTile.display()
    }
}
