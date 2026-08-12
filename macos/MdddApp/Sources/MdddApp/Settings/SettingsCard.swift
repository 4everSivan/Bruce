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

private extension Color {
    /// 解析 "#rrggbb" 十六进制颜色; 非法输入回退为黑色.
    init(hex: String) {
        var text = hex
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6,
              let value = UInt64(text, radix: 16) else {
            self = .black
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// 按系统配色模式返回明暗两套颜色 (动态 provider, 跟随外观切换).
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}
