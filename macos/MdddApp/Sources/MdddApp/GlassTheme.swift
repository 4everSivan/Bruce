import SwiftUI

// MARK: - 设置页玻璃样式

/// 设置页统一液态玻璃样式: 按钮, 状态胶囊与 Form 行背景.
/// 面板重写后只有玻璃一种形态, 不再有主题切换;
/// 部署目标为 macOS 26, 系统玻璃能力始终可用.

extension View {
    /// 系统 .glass 按钮样式.
    func glassButtonStyle() -> some View {
        buttonStyle(.glass)
    }

    /// 详情区状态 Label 的胶囊底色.
    func glassStatusPill() -> some View {
        glassEffect(.regular, in: .capsule)
    }

    /// Form 分组行背景.
    func glassFormRowBackground() -> some View {
        listRowBackground(
            Color.clear.glassEffect(
                .regular, in: .rect(cornerRadius: 10)
            )
        )
    }
}
