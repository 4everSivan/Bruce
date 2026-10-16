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

    /// 定向刷新进度指示 (系统 `ProgressView` 为不确定进度, 逐帧驱动).
    /// 面板隐藏时不得挂载 —— 定向刷新最长 90s, 期间隐藏面板会持续逐帧布局 (C044).
    package static func allowsRefreshProgress(panelVisible: Bool) -> Bool {
        panelVisible
    }

    /// 小时卡柱体生长动画 (随日期轴变化重跑).
    /// 隐藏态直接落定终值, 不播动画 (C044).
    package static func allowsHourlyGrowth(
        panelVisible: Bool,
        reduceMotion: Bool
    ) -> Bool {
        panelVisible && !reduceMotion
    }

    /// 抑制滚动条看门狗 (0.3s 周期 Timer). 面板 orderOut 不触发视图离窗,
    /// 必须由面板可见性显式驱动启停 (C044).
    package static func allowsSuppressorWatchdog(panelVisible: Bool) -> Bool {
        panelVisible
    }
}
