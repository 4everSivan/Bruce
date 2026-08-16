import AppKit
import MdddOnboardingCore
import SwiftUI

// MARK: - 主题环境

/// 面板与设置页共享的已解析主题; 默认 classic + regular (安全回落).
private struct MdddResolvedThemeKey: EnvironmentKey {
    static let defaultValue = ResolvedTheme(
        interfaceStyle: .classic,
        glassStyle: .regular,
        usesLiquidGlassEffects: false
    )
}

extension EnvironmentValues {
    var mdddResolvedTheme: ResolvedTheme {
        get { self[MdddResolvedThemeKey.self] }
        set { self[MdddResolvedThemeKey.self] = newValue }
    }

    /// 兼容旧调用点: 等价于 resolvedTheme.glassStyle.
    var mdddGlassStyle: GlassStylePreference {
        get { mdddResolvedTheme.glassStyle }
        set {
            let current = mdddResolvedTheme
            mdddResolvedTheme = ResolvedTheme(
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

/// 仪表盘材质 token: 只描述表面装饰, 不参与内容布局或数据渲染.
///
/// 液态玻璃模式下由系统 `glassEffect` 提供主要材质, 这里仅保留低对比度
/// 边缘、高光和阴影, 避免重复绘制出“塑料卡片”效果. 经典/低版本回退
/// 保留独立的一组 token, 防止视觉改造改变旧系统路径.
struct DashboardGlassSurfaceTokens {
    let borderColor: Color
    let highlightColor: Color
    let shadowColor: Color
    let shadowOpacity: Double

    static func resolve(
        theme: ResolvedTheme,
        colorScheme: ColorScheme
    ) -> Self {
        let plan = DashboardGlassSurfacePlan.resolve(theme: theme)
        if plan.backend == .nativeLiquidGlass {
            return Self(
                borderColor: Color.white.opacity(colorScheme == .dark ? 0.14 : 0.28),
                highlightColor: Color.white.opacity(colorScheme == .dark ? 0.10 : 0.18),
                shadowColor: Color(red: 31 / 255, green: 38 / 255, blue: 56 / 255),
                shadowOpacity: colorScheme == .dark ? 0.0 : 0.02
            )
        }

        if plan.reduceTransparencyFallback {
            return Self(
                borderColor: colorScheme == .dark
                    ? Color.white.opacity(0.24)
                    : Color.black.opacity(0.16),
                highlightColor: Color.clear,
                shadowColor: Color.black,
                shadowOpacity: 0.08
            )
        }

        // 哑光(material)档位: 边框/高光比经典略实, 让卡片在磨砂面板上可辨;
        // 仅 material 档位命中, classic 仍走下方默认 token.
        if plan.cardMaterial == .matte {
            return Self(
                borderColor: colorScheme == .dark
                    ? Color.white.opacity(0.24)
                    : Color.white.opacity(0.70),
                highlightColor: colorScheme == .dark
                    ? Color.white.opacity(0.16)
                    : Color.white.opacity(0.70),
                shadowColor: Color(red: 31 / 255, green: 38 / 255, blue: 56 / 255),
                shadowOpacity: colorScheme == .dark ? 0.0 : 0.07
            )
        }

        return Self(
            borderColor: colorScheme == .dark
                ? Color.white.opacity(0.16)
                : Color.white.opacity(0.6),
            highlightColor: colorScheme == .dark
                ? Color.white.opacity(0.10)
                : Color.white.opacity(0.6),
            shadowColor: Color(red: 31 / 255, green: 38 / 255, blue: 56 / 255),
            shadowOpacity: colorScheme == .dark ? 0.0 : 0.07
        )
    }
}

// MARK: - Dashboard native surface plan

enum DashboardGlassBackend: Equatable {
    case nativeLiquidGlass
    case appKitMaterial
    case swiftUIFallback
}

enum DashboardGlassMaterial: Equatable {
    case standard
    case clear
    case matte
    case classic
}

struct DashboardGlassSurfaceCapabilities: Equatable {
    let nativeLiquidGlass: Bool
    let reduceTransparency: Bool
    let increaseContrast: Bool

    static var current: Self {
        Self(
            nativeLiquidGlass: LiquidGlassCapability.isSupported,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }
}

struct DashboardGlassSurfacePlan: Equatable {
    let backend: DashboardGlassBackend
    let panelMaterial: DashboardGlassMaterial
    let cardMaterial: DashboardGlassMaterial
    let usesInteractiveGlass: Bool
    let reduceTransparencyFallback: Bool

    static func resolve(
        theme: ResolvedTheme,
        capabilities: DashboardGlassSurfaceCapabilities = .current
    ) -> Self {
        if capabilities.reduceTransparency || capabilities.increaseContrast {
            return Self(
                backend: .appKitMaterial,
                panelMaterial: .classic,
                cardMaterial: .classic,
                usesInteractiveGlass: false,
                reduceTransparencyFallback: true
            )
        }

        // `material` is intentionally a valid liquid-glass interface choice
        // that disables the SwiftUI Glass API.  Branch on the interface
        // preference itself so it still reaches the AppKit matte surface
        // instead of being collapsed into the classic fallback below.
        guard theme.interfaceStyle == .liquidGlass else {
            return Self(
                backend: .appKitMaterial,
                panelMaterial: .classic,
                cardMaterial: .classic,
                usesInteractiveGlass: false,
                reduceTransparencyFallback: false
            )
        }

        guard capabilities.nativeLiquidGlass else {
            return Self(
                backend: .appKitMaterial,
                panelMaterial: .classic,
                cardMaterial: .classic,
                usesInteractiveGlass: false,
                reduceTransparencyFallback: false
            )
        }

        switch theme.glassStyle {
        case .regular:
            return Self(
                backend: .nativeLiquidGlass,
                panelMaterial: .standard,
                cardMaterial: .clear,
                usesInteractiveGlass: true,
                reduceTransparencyFallback: false
            )
        case .clear:
            return Self(
                backend: .nativeLiquidGlass,
                panelMaterial: .clear,
                cardMaterial: .clear,
                usesInteractiveGlass: true,
                reduceTransparencyFallback: false
            )
        case .material:
            return Self(
                backend: .appKitMaterial,
                panelMaterial: .matte,
                cardMaterial: .matte,
                usesInteractiveGlass: false,
                reduceTransparencyFallback: false
            )
        }
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
    if plan.backend == .nativeLiquidGlass {
        if #available(macOS 26, *) {
            // The AppKit panel is the single native glass surface. A second
            // SwiftUI glass layer can become an opaque light sheet when the
            // backdrop and SwiftUI color scheme disagree. Native cards use a
            // stable dynamic surface instead: it keeps the local content
            // readable while the AppKit panel still supplies the backdrop.
            if surface == .card {
                shape.fill(dashboardCardSurfaceColor())
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
        shape.fill(dashboardMatteCardSurfaceColor(colorScheme: colorScheme))
    } else {
        dashboardGlassFallback(
            shape: shape,
            colorScheme: colorScheme,
            fallback: fallback
        )
    }
}

/// 卡片局部对比度层. 使用动态 NSColor 而不是 SwiftUI `ColorScheme`, 因为
/// 通透面板可能采样到与 SwiftUI 环境不同的桌面/窗口亮度.
private func dashboardCardSurfaceColor() -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark
            ? NSColor.black.withAlphaComponent(0.38)
            : NSColor.white.withAlphaComponent(0.34)
    })
}

/// 哑光(material)档位卡片填充: 深色更实的黑、浅色更实的白, 与 .windowBackground
/// 磨砂面板拉开区分度. 磨砂面板不采样桌面亮度, 直接用 colorScheme 即可.
private func dashboardMatteCardSurfaceColor(colorScheme: ColorScheme) -> Color {
    colorScheme == .dark
        ? Color.black.opacity(0.30)
        : Color.white.opacity(0.55)
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
    @Environment(\.mdddResolvedTheme) private var theme

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
    @Environment(\.mdddResolvedTheme) private var theme
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
