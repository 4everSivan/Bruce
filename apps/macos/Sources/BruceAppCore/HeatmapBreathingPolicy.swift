import QuartzCore

/// Nothing 热力图错相位呼吸 (C179, design/03 规则 15).
///
/// 旧实现给每个填充格各挂一条 SwiftUI `repeatForever(autoreverses:).delay(phase)` 动画:
/// 半年网格约 180 条动画逐帧在主线程求值, 卡片展开时又在同一帧集中建树起播,
/// 主线程常驻约四分之一负载并拖慢展开过渡. 现由每格一个 CALayer 承载,
/// 呼吸交给 Core Animation 在渲染服务逐帧插值, 观感与旧逐格动画一致:
/// 每格先停在低谷 `phase` 秒, 再以 easeInEaseOut 1.6s 升到峰值、1.6s 回落, 循环往复.
package enum HeatmapBreathingPolicy {
    /// 单程时长 (低谷 → 峰值); 往返周期为其两倍.
    package static let halfCycle: CFTimeInterval = 1.6
    /// 低谷系数: 低谷透明度 = 档位基准透明度 × 0.42, 峰值为 1.
    package static let troughFactor = 0.42
    /// 格子层上的呼吸动画键.
    package static let animationKey = "bruce.heatmap.breathing"

    /// 每格起播延迟 (秒): 列 0.12s、行 0.05s 斜向错相位, 按往返周期取模.
    package static func phase(column: Int, row: Int) -> CFTimeInterval {
        (Double(column) * 0.12 + Double(row) * 0.05)
            .truncatingRemainder(dividingBy: halfCycle * 2)
    }

    /// 单格呼吸动画: 透明度 `base × 0.42` ↔ 1, 单程 1.6s easeInEaseOut 往返无限循环;
    /// 自 `now` 推迟 `phase` 秒起播, 推迟期间停在低谷 (fillMode backwards).
    package static func animation(
        base: Double,
        column: Int,
        row: Int,
        now: CFTimeInterval
    ) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = base * troughFactor
        animation.toValue = 1.0
        animation.duration = halfCycle
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = now + phase(column: column, row: row)
        animation.fillMode = .backwards
        return animation
    }

    /// 未挂呼吸动画时的透明度, 与旧静态格一致:
    /// 动效被抑制、非 Nothing 或空格为 1; 其余 (面板隐藏) 停在低谷.
    package static func restingOpacity(
        base: Double,
        isNothing: Bool,
        filled: Bool,
        motionSuppressed: Bool
    ) -> Double {
        motionSuppressed || !isNothing || !filled ? 1 : base * troughFactor
    }
}
