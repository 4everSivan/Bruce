import MdddOnboardingCore
import SwiftUI

// MARK: - 玻璃风格环境

/// 面板与设置页共享的玻璃风格环境键; 默认值与配置回落一致 (标准玻璃).
private struct MdddGlassStyleKey: EnvironmentKey {
    static let defaultValue: GlassStylePreference = .regular
}

extension EnvironmentValues {
    var mdddGlassStyle: GlassStylePreference {
        get { self[MdddGlassStyleKey.self] }
        set { self[MdddGlassStyleKey.self] = newValue }
    }
}

/// 风格 -> 系统 Glass 映射; material 不走 Glass, 由各调用点退化为材质填充.
extension GlassStylePreference {
    var glass: Glass {
        switch self {
        case .regular, .material:
            return .regular
        case .clear:
            return .clear
        }
    }

    /// 是否使用真实液态玻璃 (material 为唯一退化形态).
    var usesGlass: Bool {
        self != .material
    }
}

// MARK: - 设置页玻璃样式

/// 设置页统一液态玻璃样式: 按钮, 状态胶囊与 Form 行背景.
/// 部署目标为 macOS 26, 系统玻璃能力始终可用.

extension View {
    /// 系统 .glass 按钮样式.
    func glassButtonStyle() -> some View {
        buttonStyle(.glass)
    }

    /// 详情区状态 Label 的胶囊底色; 哑光风格退化为材质.
    func glassStatusPill() -> some View {
        modifier(GlassStatusPillModifier())
    }

    /// Form 分组行背景; 哑光风格退化为材质填充.
    func glassFormRowBackground() -> some View {
        modifier(GlassFormRowBackgroundModifier())
    }
}

private struct GlassStatusPillModifier: ViewModifier {
    @Environment(\.mdddGlassStyle) private var style

    func body(content: Content) -> some View {
        if style.usesGlass {
            content.glassEffect(style.glass, in: .capsule)
        } else {
            content
        }
    }
}

private struct GlassFormRowBackgroundModifier: ViewModifier {
    @Environment(\.mdddGlassStyle) private var style

    @ViewBuilder
    private var rowBackground: some View {
        if style.usesGlass {
            Color.clear.glassEffect(style.glass, in: .rect(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    func body(content: Content) -> some View {
        content.listRowBackground(rowBackground)
    }
}
