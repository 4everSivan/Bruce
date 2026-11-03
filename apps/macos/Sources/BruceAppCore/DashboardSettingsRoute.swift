import Foundation

// MARK: - 仪表盘/状态气泡 → 设置中心统一跳转 (C187)

/// 从仪表盘（`.statusBar` 层级的 NSPanel）或状态预警气泡跳转设置中心时的固定顺序：
/// 1. 先关闭仪表盘，避免其压在普通层级的设置窗口之上；
/// 2. 再写入目标深链（如出口IP设置）；
/// 3. 最后打开设置窗口。
///
/// 纯逻辑、不持有窗口状态，供菜单栏控制器与单元测试共用，避免各入口各自拼装顺序漂移。
package enum DashboardSettingsRoute {
    package static func open(
        deepLink: () -> Void,
        closeDashboard: () -> Void,
        openSettings: () -> Void
    ) {
        closeDashboard()
        deepLink()
        openSettings()
    }
}

// MARK: - 状态预警气泡互斥门控 (设计 03 §14)

/// 主面板（dashboard）处于可见展开状态时，静默跳过状态预警气泡弹出。
/// 气泡只作为面板关闭时的轻量提醒；面板已打开时其信息已在卡片内呈现。
package enum StatusBubblePresentationPolicy {
    package static func shouldPresent(dashboardOpen: Bool) -> Bool {
        !dashboardOpen
    }
}
