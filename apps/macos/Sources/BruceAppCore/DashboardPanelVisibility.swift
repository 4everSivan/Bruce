/// The state transition for closing the dashboard panel.
///
/// AppKit may have already hidden the panel when the close path runs. The
/// SwiftUI visibility state must still become false in that case, while an
/// additional order-out is only needed for a currently visible panel.
package struct DashboardPanelVisibilityTransition: Equatable, Sendable {
    package let shouldOrderOut: Bool
    package let visible: Bool

    package static func close(panelIsVisible: Bool) -> Self {
        Self(shouldOrderOut: panelIsVisible, visible: false)
    }

    package static func isActuallyVisible(
        panelIsVisible: Bool,
        occlusionStateIsVisible: Bool
    ) -> Bool {
        panelIsVisible && occlusionStateIsVisible
    }
}

/// Logical state for the status-item toggle. This is kept separate from
/// AppKit's asynchronous `NSPanel.isVisible` property.
package enum DashboardPanelToggleState: Equatable, Sendable {
    case closed
    case open

    package var toggled: Self {
        switch self {
        case .closed:
            .open
        case .open:
            .closed
        }
    }
}

/// Decides whether losing application active state means that the dashboard
/// was dismissed by clicking another application.
///
/// Clicking Bruce's own status item can also make AppKit send
/// `didResignActive` while dispatching the button action. That notification
/// must not close the panel before the action gets a chance to perform the
/// second half of the toggle.
package enum DashboardPanelDismissalPolicy {
    package static func shouldDismissOnApplicationResign(
        panelIsVisible: Bool,
        pointerIsInsideStatusItem: Bool,
        statusItemActionInProgress: Bool
    ) -> Bool {
        panelIsVisible
            && !pointerIsInsideStatusItem
            && !statusItemActionInProgress
    }
}
