import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// 把 C145 的全局动效抑制开关注入 SwiftUI 树的宿主根.
///
/// 观察 `OnboardingCoordinator`: 应用内偏好变更、以及系统「减弱动态效果」
/// 在运行中切换 (coordinator 转发 workspace 通知) 都会重建环境值,
/// 子树无需重启或重新创建。
struct MotionEnvironmentRoot<Content: View>: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    let content: Content

    var body: some View {
        content.environment(\.motionSuppressed, coordinator.motionSuppressed)
    }
}
