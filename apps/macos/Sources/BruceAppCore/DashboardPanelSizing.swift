import CoreGraphics

/// 面板窗口高度与内容高度之间的尺寸裁决 (C147).
///
/// 面板高度由 SwiftUI 侧实测内容高度驱动, 唯一写入点是
/// `MenuBarStatusItemController`. 该策略只做纯计算, 便于在 Harness 中
/// 覆盖 "顶边越屏 / 底部越屏 / 内容超高 / 正常尺寸" 四类边界:
/// - 顶边锚定: 高度变化时面板顶部保持不动, 向下延展;
/// - 屏幕夹取: 顶部不得高于可见区上沿 - `edgeInset`, 底部不得低于下沿 + `edgeInset`;
/// - 超高压缩: 内容高于屏幕可用高度时压缩窗口高度, 优先保证顶栏与底栏留在屏内.
package enum DashboardPanelSizingPolicy {
    /// 面板与屏幕边缘的安全内距 (pt), 与 `DashboardPanelPlacementResolver` 的 `panelEdgeInset` 一致.
    package static let edgeInset: CGFloat = 8

    /// 内容尺寸换算为面板目标尺寸: 宽高均不小于 1pt.
    package static func resolvedContentSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width, 1), height: max(size.height, 1))
    }

    /// 计算顶边锚定并夹取进屏的面板 frame.
    ///
    /// - Parameters:
    ///   - topY: 期望的面板顶边 (AppKit 坐标, 向上为正).
    ///   - contentSize: SwiftUI 上报的内容尺寸.
    ///   - currentX: 面板当前左边 (用于多屏/水平夹取).
    ///   - visibleFrame: 面板所在屏的可见区域.
    /// - Returns: 已夹取进屏的 frame; 内容超高时高度被压缩到可用高度.
    package static func topAnchoredFrame(
        topY: CGFloat,
        contentSize: CGSize,
        currentX: CGFloat,
        visibleFrame: CGRect
    ) -> CGRect {
        let size = resolvedContentSize(contentSize)
        let minimumY = visibleFrame.minY + edgeInset
        let maximumY = visibleFrame.maxY - edgeInset
        let availableHeight = maximumY - minimumY
        let height = availableHeight > 0
            ? min(size.height, availableHeight)
            : size.height
        let minimumX = visibleFrame.minX + edgeInset
        let maximumX = max(minimumX, visibleFrame.maxX - size.width - edgeInset)
        let x = min(max(currentX, minimumX), maximumX)

        // 顶部先按期望值锚定; 面板高于可用区或已越顶时向下收进屏内,
        // 收缩后仍低于下沿时再整体上移, 保证顶栏与底栏都不会被推出屏幕.
        let lowestTop = minimumY + height
        let highestTop = max(maximumY, lowestTop)
        let top = min(max(topY, lowestTop), highestTop)
        return CGRect(x: x, y: top - height, width: size.width, height: height)
    }
}
