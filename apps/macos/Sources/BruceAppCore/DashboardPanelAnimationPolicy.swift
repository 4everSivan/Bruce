import Foundation

/// Decides whether a decorative dashboard animation may be mounted.
///
/// `orderOut` keeps the hosting view hierarchy alive, so hidden-panel state
/// must remove animation-bearing view branches instead of only resetting their
/// state values.
package enum DashboardPanelAnimationPolicy {
    package static func allowsHero(
        panelVisible: Bool,
        motionSuppressed: Bool
    ) -> Bool {
        panelVisible && !motionSuppressed
    }

    package static func allowsHeatmap(
        panelVisible: Bool,
        isNothing: Bool,
        filled: Bool,
        motionSuppressed: Bool
    ) -> Bool {
        panelVisible && isNothing && filled && !motionSuppressed
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
        motionSuppressed: Bool
    ) -> Bool {
        panelVisible && !motionSuppressed
    }

    /// 滚动条压制是否生效 (TD-012): 面板隐藏时不得改写 NSScrollView
    /// (orderOut 不触发视图离窗), 可见时由 KVO/通知事件驱动而非周期 Timer.
    package static func allowsScrollIndicatorSuppression(panelVisible: Bool) -> Bool {
        panelVisible
    }

    /// 物理卷轴展开过渡时长 (秒, 流派 B).
    package static let curtainOpenDuration: TimeInterval = 0.24
    /// 物理卷轴收起过渡时长 (秒, 流派 B).
    package static let curtainCloseDuration: TimeInterval = 0.14
    /// 卷轴起始与收拢高度 (pt).
    package static let curtainCollapsedHeight: Double = 20.0

    /// 是否允许播放卷轴开合过渡动画 (C137; C141 起由 MotionPreference 裁决通过 motionSuppressed 传入).
    package static func allowsCurtainTransition(motionSuppressed: Bool) -> Bool {
        !motionSuppressed
    }
}
