import SwiftUI

/// 管理区统一容器: 8pt 垂直间距, 各 provider 管理组共用.
/// P2 配置对话框不再就地展开, 原有的 14pt 左缩进已无意义.
func managementStack<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        content()
    }
}

/// 管理区操作行 (P2 按钮分极): 移除按钮弱化居左, 主操作按钮居右.
@MainActor
func managementActionRow<Primary: View>(
    configured: Bool,
    removeHint: String,
    remove: @escaping () -> Void,
    @ViewBuilder primary: () -> Primary
) -> some View {
    HStack(spacing: 8) {
        if configured {
            Button("移除", role: .destructive, action: remove)
                .buttonStyle(.borderless)
                .accessibilityHint(removeHint)
        }
        Spacer()
        primary()
    }
}
