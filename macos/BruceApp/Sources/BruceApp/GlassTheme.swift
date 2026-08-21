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

/// 面板与设置页共享的已解析主题; 默认 classic + regular (安全回落).
private struct BruceResolvedThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme(
        interfaceStyle: .classic,
        glassStyle: .regular,
        usesLiquidGlassEffects: false
    )
}

extension EnvironmentValues {
    var BruceResolvedTheme: ResolvedTheme {
        get { self[BruceResolvedThemeKey.self] }
        set { self[BruceResolvedThemeKey.self] = newValue }
    }

    /// 兼容旧调用点: 等价于 resolvedTheme.glassStyle.
    var BruceGlassStyle: GlassStylePreference {
        get { BruceResolvedTheme.glassStyle }
        set {
            let current = BruceResolvedTheme
            BruceResolvedTheme = ResolvedTheme(
                interfaceStyle: current.interfaceStyle,
                glassStyle: newValue,
                usesLiquidGlassEffects: current.interfaceStyle == .liquidGlass
                    && current.usesLiquidGlassEffects
                    && newValue.usesGlassMaterial
            )
        }
    }
}

// MARK: - 设置页 / 面板玻璃样式

extension View {
    /// 按钮样式: 液态玻璃模式下用系统 .glass; 经典或低系统用默认.
    @ViewBuilder
    func glassButtonStyle() -> some View {
        modifier(GlassButtonStyleModifier())
    }

    /// Form 分组行背景; classic / 哑光退化为材质填充.
    func glassFormRowBackground() -> some View {
        modifier(GlassFormRowBackgroundModifier())
    }
}

// MARK: - Dashboard surface tokens

extension DashboardGlassSurfaceCapabilities {
    /// Runtime capability probe stays at the AppKit boundary; the core matrix
    /// receives these values as plain booleans and remains deterministic.
    static var current: Self {
        Self(
            nativeLiquidGlass: LiquidGlassCapability.isSupported,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

extension DashboardGlassSurfacePlan {
    /// Production convenience: tests call the pure overload with injected
    /// capabilities, while UI call sites use the current system capabilities.
    static func resolve(theme: ResolvedTheme) -> Self {
        resolve(theme: theme, capabilities: .current)
    }
}

/// SwiftUI adapter for the pure surface matrix. It contains no layout or
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

    static func resolve(
        theme: ResolvedTheme,
        colorScheme: ColorScheme
    ) -> Self {
        let appearance: DashboardGlassAppearance = colorScheme == .dark ? .dark : .light
        let style = DashboardGlassSurfaceStyle.resolve(
            theme: theme,
            appearance: appearance,
            capabilities: .current
        )
        return Self(style: style)
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
    theme: ResolvedTheme,
    shape: RoundedRectangle,
    colorScheme: ColorScheme = .light,
    fallback: DashboardGlassFallback = .material,
    surface: DashboardGlassSurface = .panel
) -> some View {
    let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
    let tokens = DashboardGlassSurfaceTokens.resolve(
        theme: theme,
        colorScheme: colorScheme
    )
    if plan.backend == .nativeLiquidGlass {
        if #available(macOS 26, *) {
            // The AppKit panel is the single native glass surface. A second
            // SwiftUI glass layer can become an opaque light sheet when the
            // backdrop and SwiftUI color scheme disagree. Native cards use a
            // shared style token instead: it keeps the local content readable
            // while the AppKit panel still supplies the backdrop.
            if surface == .card {
                shape.fill(tokens.cardFillColor)
            } else {
                // else 分支 surface 恒为 .panel: 面板玻璃直接使用用户选择的模糊风格.
                Color.clear.glassEffect(
                    theme.glassStyle.liquidGlassAPI,
                    in: shape
                )
            }
        } else {
            dashboardGlassFallback(
                shape: shape,
                colorScheme: colorScheme,
                fallback: fallback
            )
        }
    } else if surface == .card && plan.cardMaterial == .matte {
        // 哑光(material)档位卡片: 实填充与磨砂面板拉开区分; 经典档位不命中.
        shape.fill(tokens.cardFillColor)
    } else {
        dashboardGlassFallback(
            shape: shape,
            colorScheme: colorScheme,
            fallback: fallback
        )
    }
}

@ViewBuilder
private func dashboardGlassFallback(
    shape: RoundedRectangle,
    colorScheme: ColorScheme,
    fallback: DashboardGlassFallback
) -> some View {
    switch fallback {
    case .material:
        shape.fill(.regularMaterial)
    case .card:
        if colorScheme == .dark {
            shape.fill(.regularMaterial)
        } else {
            shape.fill(Color.white.opacity(0.45))
        }
    }
}

private struct GlassButtonStyleModifier: ViewModifier {
    @Environment(\.BruceResolvedTheme) private var theme

    func body(content: Content) -> some View {
        let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
        if plan.usesInteractiveGlass {
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

private struct GlassFormRowBackgroundModifier: ViewModifier {
    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    private var rowBackground: some View {
        let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
        if plan.backend == .nativeLiquidGlass {
            if #available(macOS 26, *) {
                Color.clear.glassEffect(theme.glassStyle.liquidGlassAPI, in: .rect(cornerRadius: 10))
            } else {
                classicRowFill
            }
        } else {
            classicRowFill
        }
    }

    private var classicRowFill: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.regularMaterial)
    }

    func body(content: Content) -> some View {
        content.listRowBackground(rowBackground)
    }
}

// MARK: - GlassStyle -> 系统 Glass (仅 26+)

extension GlassStylePreference {
    /// 映射到系统 Glass 类型; 调用方必须包在 #available(macOS 26, *).
    @available(macOS 26, *)
    var liquidGlassAPI: Glass {
        switch self {
        case .regular, .material:
            return .regular
        case .clear:
            return .clear
        }
    }

    /// 兼容旧属性名.
    var usesGlass: Bool { usesGlassMaterial }
}
