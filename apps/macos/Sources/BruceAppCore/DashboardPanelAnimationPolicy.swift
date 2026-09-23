/// Decides whether a decorative dashboard animation may be mounted.
///
/// `orderOut` keeps the hosting view hierarchy alive, so hidden-panel state
/// must remove animation-bearing view branches instead of only resetting their
/// state values.
package enum DashboardPanelAnimationPolicy {
    package static func allowsHero(
        panelVisible: Bool,
        reduceMotion: Bool
    ) -> Bool {
        panelVisible && !reduceMotion
    }

    package static func allowsHeatmap(
        panelVisible: Bool,
        isNothing: Bool,
        filled: Bool,
        reduceMotion: Bool
    ) -> Bool {
        panelVisible && isNothing && filled && !reduceMotion
    }
}
