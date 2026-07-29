import AppKit
import SwiftUI

// MARK: - AppTheme

/// 应用外观主题. rawValue 与持久化配置, Widget 端主题名保持一致.
enum AppTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case classic
    case liquidGlass

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:
            return "经典"
        case .liquidGlass:
            return "液态玻璃"
        }
    }

    /// Widget 端 (host-bootstrap.js / glass-theme.css) 使用的主题名.
    var widgetThemeName: String {
        switch self {
        case .classic:
            return "classic"
        case .liquidGlass:
            return "liquid-glass"
        }
    }
}

// MARK: - GlassTheme

/// 液态玻璃主题的集中入口: 可用性判断与可复用样式.
/// 低系统或 classic 主题时所有辅助方法一律返回现状样式, 布局结构不变.
enum GlassTheme {
    /// 液态玻璃只在 macOS 26 或更高版本生效.
    static var isLiquidGlassAvailable: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }

    /// 实际生效的主题: 低系统选择液态玻璃时回退 classic 展示.
    static func resolved(_ theme: AppTheme) -> AppTheme {
        guard theme == .liquidGlass, isLiquidGlassAvailable else {
            return .classic
        }
        return .liquidGlass
    }

    /// 当前主题是否以玻璃质感渲染.
    static func usesGlass(_ theme: AppTheme) -> Bool {
        resolved(theme) == .liquidGlass
    }
}

// MARK: - 卡片背景

/// 自定义卡片/容器的背景: 液态玻璃 + macOS 26 使用系统 glassEffect,
/// 其余情况保持经典的 controlBackground 实底.
struct GlassCardBackground: ViewModifier {
    let theme: AppTheme
    var cornerRadius: CGFloat = 18

    @ViewBuilder
    func body(content: Content) -> some View {
        if GlassTheme.usesGlass(theme) {
            if #available(macOS 26, *) {
                content.glassEffect(
                    .regular,
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                // 不可达: usesGlass 已在低系统回退 classic, 保留编译兜底
                content.background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(
                        cornerRadius: cornerRadius, style: .continuous
                    )
                )
            }
        } else {
            content.background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(
                    cornerRadius: cornerRadius, style: .continuous
                )
            )
        }
    }
}

extension View {
    /// 按主题应用卡片背景, 只换材质不动布局.
    func glassCardBackground(
        theme: AppTheme,
        cornerRadius: CGFloat = 18
    ) -> some View {
        modifier(GlassCardBackground(theme: theme, cornerRadius: cornerRadius))
    }
}

// MARK: - 按钮样式

/// 液态玻璃 + macOS 26 使用系统 .glass 按钮样式, 其余保持默认.
struct GlassButtonStyleModifier: ViewModifier {
    let theme: AppTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if GlassTheme.usesGlass(theme) {
            if #available(macOS 26, *) {
                content.buttonStyle(.glass)
            } else {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func glassButtonStyle(theme: AppTheme) -> some View {
        modifier(GlassButtonStyleModifier(theme: theme))
    }
}

// MARK: - 状态胶囊

/// 详情区状态 Label 的底色: 玻璃主题 + macOS 26 用 glassEffect 胶囊,
/// 其余情况不加任何背景.
struct GlassStatusPillModifier: ViewModifier {
    let theme: AppTheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if GlassTheme.usesGlass(theme) {
            if #available(macOS 26, *) {
                content.glassEffect(.regular, in: .capsule)
            } else {
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func glassStatusPill(theme: AppTheme) -> some View {
        modifier(GlassStatusPillModifier(theme: theme))
    }

    /// Form 分组行背景: 玻璃主题 + macOS 26 用 glassEffect,
    /// 其余情况保持系统默认 chrome.
    @ViewBuilder
    func glassFormRowBackground(theme: AppTheme) -> some View {
        if GlassTheme.usesGlass(theme) {
            if #available(macOS 26, *) {
                listRowBackground(
                    Color.clear.glassEffect(
                        .regular, in: .rect(cornerRadius: 10)
                    )
                )
            } else {
                self
            }
        } else {
            self
        }
    }
}

// MARK: - Widget 玻璃垫层

/// 垫在透明 WKWebView 下方的背景: 液态玻璃 + macOS 26 使用 NSGlassEffectView,
/// 其余情况为透明 (Widget 自带经典米白底).
struct WidgetGlassBacking: NSViewRepresentable {
    let theme: AppTheme

    func makeNSView(context: Context) -> NSView {
        if GlassTheme.usesGlass(theme) {
            if #available(macOS 26, *) {
                let glassView = NSGlassEffectView()
                glassView.cornerRadius = 18
                return glassView
            }
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
