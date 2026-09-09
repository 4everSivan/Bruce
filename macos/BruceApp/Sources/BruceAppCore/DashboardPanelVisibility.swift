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
