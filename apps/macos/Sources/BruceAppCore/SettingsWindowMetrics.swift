import CoreGraphics

/// 设置窗口左右比例的单一裁决源 (C152).
///
/// 侧栏宽度按窗口内容宽度等比计算, 窗口缩放时左右比例保持不变,
/// 不再写死像素宽度。1000pt 默认内容宽度下侧栏为 176pt、右侧面板 823pt,
/// 与设计稿比例一致 (04-设置中心与价格校准交互 §5.1)。
package enum SettingsWindowMetrics {
    /// 侧栏宽度占窗口内容宽度的比例 (1000pt 窗口下为 176pt).
    package static let sidebarWidthRatio: CGFloat = 0.176

    /// 侧栏可读性下限: 导航项本身约需 143pt, 再收会挤压「授权与隐私」等长标签.
    package static let sidebarMinimumWidth: CGFloat = 160

    /// 侧栏与内容区之间的 1pt 平面分隔线, 计算面板宽度时需扣除.
    package static let separatorWidth: CGFloat = 1

    /// 默认内容区尺寸: 收窄侧栏后窗口同步变窄, 右侧面板保持 823pt 观感.
    package static let defaultContentWidth: CGFloat = 1000
    package static let defaultContentHeight: CGFloat = 680

    /// 最小内容区尺寸: 窄于此时通用页的分段选择器开始挤压.
    package static let minimumContentWidth: CGFloat = 980
    package static let minimumContentHeight: CGFloat = 620

    /// 按窗口内容宽度换算侧栏宽度; 非有限宽度或极窄窗口落在可读性下限.
    package static func sidebarWidth(forContentWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return sidebarMinimumWidth }
        return max(sidebarMinimumWidth, (width * sidebarWidthRatio).rounded())
    }

    /// 按窗口内容宽度换算右侧面板宽度 (扣除侧栏与分隔线).
    package static func paneWidth(forContentWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return max(0, width - sidebarWidth(forContentWidth: width) - separatorWidth)
    }
}
