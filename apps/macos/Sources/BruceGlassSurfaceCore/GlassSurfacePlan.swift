import BruceOnboardingCore

/// C271: 界面风格产品级收敛为 Nothing 后, 面板视觉只剩纯色平面一种路由.
public enum DashboardGlassBackend: String, Equatable, Sendable {
    /// 纯色不透明平面渲染, 无模糊 无阴影 无渐变.
    case flatMonochrome
}

public enum DashboardGlassMaterial: String, Equatable, Sendable {
    /// 纯色不透明填充 + 1px 边框分层.
    case nothing
}

public enum DashboardGlassAppearance: String, Equatable, Sendable {
    case light
    case dark
}

/// A serializable color token used by both UI adapters. Keeping RGBA values
/// here makes the visual matrix deterministic and avoids putting SwiftUI Color
/// or AppKit NSColor into the pure core.
public struct DashboardGlassColorToken: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let clear = Self(red: 0, green: 0, blue: 0, alpha: 0)

    public static func black(_ alpha: Double) -> Self {
        Self(red: 0, green: 0, blue: 0, alpha: alpha)
    }

    public static func white(_ alpha: Double) -> Self {
        Self(red: 1, green: 1, blue: 1, alpha: alpha)
    }

    public static func rgb(
        _ red: Double,
        _ green: Double,
        _ blue: Double,
        alpha: Double
    ) -> Self {
        Self(red: red, green: green, blue: blue, alpha: alpha)
    }
}

/// C271: 唯一的 Nothing 视觉路由 (纯色平面 + 1px 边框, 零玻璃零材质).
public struct DashboardGlassSurfacePlan: Equatable, Sendable {
    public let backend: DashboardGlassBackend
    public let panelMaterial: DashboardGlassMaterial
    public let cardMaterial: DashboardGlassMaterial
    public let controlMaterial: DashboardGlassMaterial

    public init(
        backend: DashboardGlassBackend = .flatMonochrome,
        panelMaterial: DashboardGlassMaterial = .nothing,
        cardMaterial: DashboardGlassMaterial = .nothing,
        controlMaterial: DashboardGlassMaterial = .nothing
    ) {
        self.backend = backend
        self.panelMaterial = panelMaterial
        self.cardMaterial = cardMaterial
        self.controlMaterial = controlMaterial
    }

    public static let nothing = Self()
}

/// Appearance-specific surface values consumed by Panel, Card and Control.
public struct DashboardGlassSurfaceStyle: Equatable, Sendable {
    public let panelTint: DashboardGlassColorToken
    public let cardFill: DashboardGlassColorToken
    public let cardBorder: DashboardGlassColorToken
    public let cardHighlight: DashboardGlassColorToken
    public let cardShadow: DashboardGlassColorToken
    public let controlFill: DashboardGlassColorToken
    public let controlPressedFill: DashboardGlassColorToken
    public let controlForeground: DashboardGlassColorToken
    public let controlBorder: DashboardGlassColorToken
    public let controlShadow: DashboardGlassColorToken

    public init(
        panelTint: DashboardGlassColorToken,
        cardFill: DashboardGlassColorToken,
        cardBorder: DashboardGlassColorToken,
        cardHighlight: DashboardGlassColorToken,
        cardShadow: DashboardGlassColorToken,
        controlFill: DashboardGlassColorToken,
        controlPressedFill: DashboardGlassColorToken,
        controlForeground: DashboardGlassColorToken,
        controlBorder: DashboardGlassColorToken,
        controlShadow: DashboardGlassColorToken
    ) {
        self.panelTint = panelTint
        self.cardFill = cardFill
        self.cardBorder = cardBorder
        self.cardHighlight = cardHighlight
        self.cardShadow = cardShadow
        self.controlFill = controlFill
        self.controlPressedFill = controlPressedFill
        self.controlForeground = controlForeground
        self.controlBorder = controlBorder
        self.controlShadow = controlShadow
    }

    /// C271: 只保留 Nothing token, 不再按主题/材质解析矩阵.
    public static func resolve(appearance: DashboardGlassAppearance) -> Self {
        switch appearance {
        case .dark:
            return Self(
                panelTint: .black(1),
                cardFill: .rgb(17 / 255, 17 / 255, 17 / 255, alpha: 1),
                cardBorder: .rgb(34 / 255, 34 / 255, 34 / 255, alpha: 1),
                cardHighlight: .clear,
                cardShadow: .clear,
                controlFill: .rgb(26 / 255, 26 / 255, 26 / 255, alpha: 1),
                controlPressedFill: .rgb(34 / 255, 34 / 255, 34 / 255, alpha: 1),
                controlForeground: .rgb(232 / 255, 232 / 255, 232 / 255, alpha: 1),
                controlBorder: .rgb(51 / 255, 51 / 255, 51 / 255, alpha: 1),
                controlShadow: .clear
            )
        case .light:
            return Self(
                panelTint: .rgb(245 / 255, 245 / 255, 245 / 255, alpha: 1),
                cardFill: .white(1),
                cardBorder: .rgb(232 / 255, 232 / 255, 232 / 255, alpha: 1),
                cardHighlight: .clear,
                cardShadow: .clear,
                controlFill: .rgb(240 / 255, 240 / 255, 240 / 255, alpha: 1),
                controlPressedFill: .rgb(232 / 255, 232 / 255, 232 / 255, alpha: 1),
                controlForeground: .rgb(26 / 255, 26 / 255, 26 / 255, alpha: 1),
                controlBorder: .rgb(204 / 255, 204 / 255, 204 / 255, alpha: 1),
                controlShadow: .clear
            )
        }
    }
}
