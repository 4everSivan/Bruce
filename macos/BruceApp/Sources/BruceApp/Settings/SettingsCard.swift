import AppKit
import SwiftUI

/// 设置分区卡片容器: 圆角 12 + 细边框 + 浅阴影, 统一样式不随主题.
/// 内容行保留调用方布局 (LabeledContent / Divider / 按钮等), 仅容器外观变化.
struct SettingsCard<Content: View>: View {    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        // 注意必须用 VStack 包一层再挂容器样式:
        // 直接对 ViewBuilder 元组挂 background 会让每行各自成卡.
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.adaptive(
                light: Color.white,
                dark: Color(hex: "#1c1c1e")
            ))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.adaptive(
                        light: Color(hex: "#e3e5e8"),
                        dark: Color(hex: "#3a3a3c")
                    ), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 3, x: 0, y: 1)
    }
}
