import Foundation

package struct MenuBarRenderSnapshot: Equatable, Sendable {
    package let summaryKey: String
    package let isRefreshing: Bool

    package init(summaryKey: String, isRefreshing: Bool) {
        self.summaryKey = summaryKey
        self.isRefreshing = isRefreshing
    }
}

@MainActor
package final class MenuBarRenderCoalescer {
    private var pending = false

    package init() {}

    package func request() -> Bool {
        guard !pending else { return false }
        pending = true
        return true
    }

    package func consume() {
        pending = false
    }
}

package enum MenuBarRenderPolicy {
    package static let maximumAnimationFPS = 8.0

    package static var animationIntervalSeconds: Double {
        1.0 / maximumAnimationFPS
    }

    package static func summaryNeedsRender(
        previous: MenuBarRenderSnapshot?,
        current: MenuBarRenderSnapshot
    ) -> Bool {
        previous?.summaryKey != current.summaryKey
    }
}
