import SwiftUI

/// 管理区统一容器: 左缩进 14pt + 8pt 垂直间距, 各 provider 管理组共用.
func managementStack<Content: View>(
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        content()
    }
    .padding(.leading, 14)
}

/// 管理区操作行: 主操作按钮在左, 移除按钮统一居右 (destructive).
func managementActionRow<Primary: View>(
    configured: Bool,
    removeHint: String,
    remove: @escaping () -> Void,
    @ViewBuilder primary: () -> Primary
) -> some View {
    HStack(spacing: 8) {
        primary()
        Spacer()
        if configured {
            Button("移除", role: .destructive, action: remove)
                .accessibilityHint(removeHint)
        }
    }
}
