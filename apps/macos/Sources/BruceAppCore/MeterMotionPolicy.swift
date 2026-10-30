import SwiftUI

/// 订阅卡更新动效的单一裁决源 (C158, design/03 规则 13).
///
/// 量条、百分比、余额数字与档位色的时长 / 曲线 / 是否播放全部由这里给出;
/// 视图只读 `animation(for:panelVisible:motionSuppressed:)`, 不得各自内联判定。
/// 面板隐藏 (C044) 或动效被抑制 (C145) 时一律返回 nil, 数值直接落定终值。

/// 可表驱动断言的曲线描述; 弹簧的 bounce 恒为 0 (零过冲, 数值是真值).
package enum MeterMotionCurve: Equatable, Sendable {
    case spring(duration: Double, bounce: Double)
    case easeOut(duration: Double)
    case timingCurve(c0x: Double, c0y: Double, c1x: Double, c1y: Double, duration: Double)

    package var duration: Double {
        switch self {
        case let .spring(duration, _), let .easeOut(duration):
            return duration
        case let .timingCurve(_, _, _, _, duration):
            return duration
        }
    }

    package var animation: Animation {
        switch self {
        case let .spring(duration, bounce):
            return .spring(duration: duration, bounce: bounce)
        case let .easeOut(duration):
            return .easeOut(duration: duration)
        case let .timingCurve(c0x, c0y, c1x, c1y, duration):
            return .timingCurve(c0x, c0y, c1x, c1y, duration: duration)
        }
    }
}

package enum MeterMotionKind: CaseIterable, Sendable {
    /// 量条宽度与 Nothing 分段插值分数 (MeterBar / MiniMeterBar).
    case fill
    /// 百分比数字滚动, 与 fill 同一事务.
    case percent
    /// 余额数字滚动 (BalanceDualSlotView / BalanceChip).
    case balance
    /// classic / glass 三档渐变交叉淡入.
    case levelCrossfade
    /// Nothing 阈值色 (分段填充与百分比文字).
    case thresholdColor
    /// 右缘高光 / Nothing 前沿段提亮的淡入淡出.
    case highlight
    /// 增长扫光 (仅增长, 不循环).
    case sheen
}

package enum MeterMotionPolicy {
    /// 分数差不超过该值视为同值: 不启动高光 / 扫光 (不空转).
    package static let minimumFractionDelta = 0.0005
    /// 高光保持时长: 覆盖整段 fill 动画后再淡出.
    package static let highlightHoldSeconds = 0.95

    package static func curve(
        for kind: MeterMotionKind,
        panelVisible: Bool,
        motionSuppressed: Bool
    ) -> MeterMotionCurve? {
        guard panelVisible, !motionSuppressed else { return nil }
        switch kind {
        case .fill, .percent:
            return .spring(duration: 0.85, bounce: 0)
        case .balance:
            return .spring(duration: 0.6, bounce: 0)
        case .levelCrossfade:
            return .easeOut(duration: 0.34)
        case .thresholdColor:
            return .easeOut(duration: 0.25)
        case .highlight:
            return .easeOut(duration: 0.2)
        case .sheen:
            return .timingCurve(c0x: 0.33, c0y: 0, c1x: 0.2, c1y: 1, duration: 0.85)
        }
    }

    package static func animation(
        for kind: MeterMotionKind,
        panelVisible: Bool,
        motionSuppressed: Bool
    ) -> Animation? {
        curve(for: kind, panelVisible: panelVisible, motionSuppressed: motionSuppressed)?.animation
    }

    /// 一次数值变化是否当作「刚更新」播放高光 / 扫光.
    package static func shouldPlayUpdate(
        from oldValue: Double,
        to newValue: Double,
        panelVisible: Bool,
        motionSuppressed: Bool
    ) -> Bool {
        guard panelVisible, !motionSuppressed, oldValue.isFinite, newValue.isFinite else {
            return false
        }
        return abs(newValue - oldValue) > minimumFractionDelta
    }
}
