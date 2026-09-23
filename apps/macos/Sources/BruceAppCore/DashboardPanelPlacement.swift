import Foundation

/// Resolves a dashboard panel origin from a status-item anchor.
///
/// On macOS 27, an NSStatusItem button can report a screen-converted rect
/// outside the screen (for example y=-14). In that case the panel must use a
/// screen-edge fallback instead of trusting the invalid anchor.
package struct DashboardPanelPlacement: Equatable, Sendable {
    package let origin: CGPoint
    package let usedFallbackAnchor: Bool

    package init(origin: CGPoint, usedFallbackAnchor: Bool) {
        self.origin = origin
        self.usedFallbackAnchor = usedFallbackAnchor
    }
}

package enum DashboardPanelPlacementResolver {
    private static let panelEdgeInset: CGFloat = 8
    private static let panelAnchorGap: CGFloat = 6
    private static let menuBarBandHeight: CGFloat = 64

    package static func resolve(
        anchorRect: CGRect?,
        panelSize: CGSize,
        visibleFrame: CGRect,
        screenFrame: CGRect
    ) -> DashboardPanelPlacement {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return DashboardPanelPlacement(
                origin: .zero,
                usedFallbackAnchor: true
            )
        }

        let anchor = anchorRect.flatMap { rect in
            isUsableStatusItemAnchor(
                rect,
                visibleFrame: visibleFrame,
                screenFrame: screenFrame
            ) ? rect : nil
        }
        let width = max(panelSize.width, 1)
        let height = max(panelSize.height, 1)
        let anchorX = anchor?.midX ?? visibleFrame.maxX - panelEdgeInset
        let anchorY = anchor.map { min($0.minY, visibleFrame.maxY) }
            ?? visibleFrame.maxY

        let minimumX = visibleFrame.minX + panelEdgeInset
        let maximumX = max(
            minimumX,
            visibleFrame.maxX - width - panelEdgeInset
        )
        let minimumY = visibleFrame.minY + panelEdgeInset
        let maximumY = max(
            minimumY,
            visibleFrame.maxY - height - panelEdgeInset
        )
        let unclampedOrigin = CGPoint(
            x: anchorX - width / 2,
            y: anchorY - height - panelAnchorGap
        )
        let origin = CGPoint(
            x: min(max(unclampedOrigin.x, minimumX), maximumX),
            y: min(max(unclampedOrigin.y, minimumY), maximumY)
        )
        return DashboardPanelPlacement(
            origin: origin,
            usedFallbackAnchor: anchor == nil
        )
    }

    private static func isUsableStatusItemAnchor(
        _ rect: CGRect,
        visibleFrame: CGRect,
        screenFrame: CGRect
    ) -> Bool {
        guard rect.width > 0, rect.height > 0 else { return false }
        let expandedScreenFrame = screenFrame.insetBy(dx: -1, dy: -1)
        guard expandedScreenFrame.contains(
            CGPoint(x: rect.midX, y: rect.midY)
        ) else {
            return false
        }
        // A status item belongs to the top menu-bar band. Reject anchors that
        // convert below the usable screen area, which is the macOS 27 failure
        // mode this resolver is designed to cover.
        return rect.maxY >= visibleFrame.maxY - menuBarBandHeight
            && rect.minY <= screenFrame.maxY + 1
    }
}
