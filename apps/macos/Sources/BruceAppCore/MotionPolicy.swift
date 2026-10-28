import SwiftUI

/// 全局动效抑制开关的可写环境键 (C145).
///
/// SwiftUI 的 `\.accessibilityReduceMotion` 是**只读**环境值 (赋值需要
/// `WritableKeyPath`, 直接 `.environment(\.accessibilityReduceMotion, _)` 无法编译),
/// 因此应用内无法覆盖系统判定。这里自建可写键: 由两个 SwiftUI 宿主根
/// (仪表盘面板 / 设置窗口) 各注入一次, 视图一律读此键决定是否把动画传成 nil,
/// 不得再直连系统 API。
package struct MotionSuppressedKey: EnvironmentKey {
    package static let defaultValue = false
}

extension EnvironmentValues {
    /// true 表示抑制全部显式动效 (一次性过渡直接落定终值, 循环动效不挂载).
    package var motionSuppressed: Bool {
        get { self[MotionSuppressedKey.self] }
        set { self[MotionSuppressedKey.self] = newValue }
    }
}
