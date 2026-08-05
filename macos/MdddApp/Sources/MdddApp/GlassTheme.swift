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

private struct GlassButtonStyleModifier: ViewModifier {
    @Environment(\.mdddResolvedTheme) private var theme

    func body(content: Content) -> some View {
        if theme.usesLiquidGlassEffects {
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
        if theme.usesLiquidGlassEffects {
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
