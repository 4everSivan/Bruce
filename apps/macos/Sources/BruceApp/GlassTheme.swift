import AppKit
import BruceGlassSurfaceCore
import BruceOnboardingCore
import SwiftUI

// MARK: - Shared color helpers

extension Color {
    /// 解析 6 位 #RRGGBB 颜色; 非法输入稳定回退为黑色.
    init(hex: String) {
        var text = hex
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        guard text.count == 6, let value = UInt64(text, radix: 16) else {
            self = .black
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }

    /// 按系统配色模式返回明暗两套颜色.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - 主题环境

/// 面板与设置页共享的已解析主题; C271 起默认即 Nothing.
private struct BruceResolvedThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme.nothing
}

extension EnvironmentValues {
    var BruceResolvedTheme: ResolvedTheme {
        get { self[BruceResolvedThemeKey.self] }
        set { self[BruceResolvedThemeKey.self] = newValue }
    }
}

// MARK: - Dashboard surface tokens

/// SwiftUI adapter for the pure Nothing surface tokens. No layout or
/// business state; all values come from the shared Panel/Card/Control plan.
struct DashboardGlassSurfaceTokens {
    let panelTintColor: Color
    let cardFillColor: Color
    let borderColor: Color
    let highlightColor: Color
    let shadowColor: Color
    let controlFillColor: Color
    let controlPressedFillColor: Color
    let controlForegroundColor: Color
    let controlBorderColor: Color
    let controlShadowColor: Color

    static func resolve(colorScheme: ColorScheme) -> Self {
        let appearance: DashboardGlassAppearance = colorScheme == .dark ? .dark : .light
        return Self(style: DashboardGlassSurfaceStyle.resolve(appearance: appearance))
    }

    private init(style: DashboardGlassSurfaceStyle) {
        panelTintColor = style.panelTint.color
        cardFillColor = style.cardFill.color
        borderColor = style.cardBorder.color
        highlightColor = style.cardHighlight.color
        shadowColor = style.cardShadow.color
        controlFillColor = style.controlFill.color
        controlPressedFillColor = style.controlPressedFill.color
        controlForegroundColor = style.controlForeground.color
        controlBorderColor = style.controlBorder.color
        controlShadowColor = style.controlShadow.color
    }
}

private extension DashboardGlassColorToken {
    var color: Color {
        Color(red: red, green: green, blue: blue).opacity(alpha)
    }
}

enum DashboardGlassFallback {
    case material
    case card
}

enum DashboardGlassSurface {
    case panel
    case card
}

/// 统一面板/卡片背景实现. 几何形状由调用方提供, 本函数不改变布局.
@ViewBuilder
func dashboardGlassBackground(
    shape: RoundedRectangle,
    colorScheme: ColorScheme = .light,
    surface: DashboardGlassSurface = .panel
) -> some View {
    let tokens = DashboardGlassSurfaceTokens.resolve(colorScheme: colorScheme)
    if surface == .card {
        shape.fill(tokens.cardFillColor)
    } else {
        shape.fill(tokens.panelTintColor)
    }
}
