import BruceOnboardingCore

/// Dashboard visual backend. This module intentionally has no AppKit/SwiftUI
/// dependency so the style matrix can be tested without creating UI objects.
public enum DashboardGlassBackend: String, Equatable, Sendable {
    case nativeLiquidGlass
    case appKitMaterial
    case swiftUIFallback
}

public enum DashboardGlassMaterial: String, Equatable, Sendable {
    case standard
    case clear
    case matte
    case classic
}

public struct DashboardGlassSurfaceCapabilities: Equatable, Sendable {
    public let nativeLiquidGlass: Bool
    public let reduceTransparency: Bool
    public let increaseContrast: Bool

    public init(
        nativeLiquidGlass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) {
        self.nativeLiquidGlass = nativeLiquidGlass
        self.reduceTransparency = reduceTransparency
        self.increaseContrast = increaseContrast
    }
}

/// Single visual routing decision shared by the AppKit panel and SwiftUI
/// content. Business state, layout and persistence are deliberately absent.
public struct DashboardGlassSurfacePlan: Equatable, Sendable {
    public let backend: DashboardGlassBackend
    public let panelMaterial: DashboardGlassMaterial
    public let cardMaterial: DashboardGlassMaterial
    public let controlMaterial: DashboardGlassMaterial
    public let usesInteractiveGlass: Bool
    public let reduceTransparencyFallback: Bool

    public init(
        backend: DashboardGlassBackend,
        panelMaterial: DashboardGlassMaterial,
        cardMaterial: DashboardGlassMaterial,
        controlMaterial: DashboardGlassMaterial,
        usesInteractiveGlass: Bool,
        reduceTransparencyFallback: Bool
    ) {
        self.backend = backend
        self.panelMaterial = panelMaterial
        self.cardMaterial = cardMaterial
        self.controlMaterial = controlMaterial
        self.usesInteractiveGlass = usesInteractiveGlass
        self.reduceTransparencyFallback = reduceTransparencyFallback
    }

    public static func resolve(
        theme: ResolvedTheme,
        capabilities: DashboardGlassSurfaceCapabilities
    ) -> Self {
        if capabilities.reduceTransparency || capabilities.increaseContrast {
            return fallback(reduceTransparency: true)
        }

        guard theme.interfaceStyle == .liquidGlass else {
            return fallback(reduceTransparency: false)
        }

        guard capabilities.nativeLiquidGlass else {
            return fallback(reduceTransparency: false)
        }

        switch theme.glassStyle {
        case .regular:
            return Self(
                backend: .nativeLiquidGlass,
                panelMaterial: .standard,
                cardMaterial: .clear,
                controlMaterial: .standard,
                usesInteractiveGlass: true,
                reduceTransparencyFallback: false
            )
        case .clear:
            return Self(
                backend: .nativeLiquidGlass,
                panelMaterial: .clear,
                cardMaterial: .clear,
                controlMaterial: .clear,
                usesInteractiveGlass: true,
                reduceTransparencyFallback: false
            )
        case .material:
            return Self(
                backend: .appKitMaterial,
                panelMaterial: .matte,
                cardMaterial: .matte,
                controlMaterial: .classic,
                usesInteractiveGlass: false,
                reduceTransparencyFallback: false
            )
        }
    }

    private static func fallback(reduceTransparency: Bool) -> Self {
        Self(
            backend: .appKitMaterial,
            panelMaterial: .classic,
            cardMaterial: .classic,
            controlMaterial: .classic,
            usesInteractiveGlass: false,
            reduceTransparencyFallback: reduceTransparency
        )
    }
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

/// Appearance-specific surface values consumed by Panel, Card and Control.
/// The values mirror the approved v2 matrix: regular has more environmental
/// presence, clear lowers fill and boundary contrast, and matte prioritizes
/// stable opaque separation.
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

    public static func resolve(
        theme: ResolvedTheme,
        appearance: DashboardGlassAppearance,
        capabilities: DashboardGlassSurfaceCapabilities
    ) -> Self {
        let plan = DashboardGlassSurfacePlan.resolve(
            theme: theme,
            capabilities: capabilities
        )
        switch plan.panelMaterial {
        case .standard:
            return nativeRegular(for: appearance)
        case .clear:
            return nativeClear(for: appearance)
        case .matte:
            return matte(for: appearance)
        case .classic:
            return classic(for: appearance)
        }
    }

    private static func nativeRegular(for appearance: DashboardGlassAppearance) -> Self {
        switch appearance {
        case .dark:
            return Self(
                panelTint: .black(0.30),
                cardFill: .white(0.09),
                cardBorder: .white(0.16),
                cardHighlight: .white(0.10),
                cardShadow: .black(0.14),
                controlFill: .black(0.63),
                controlPressedFill: .black(0.82),
                controlForeground: .white(1),
                controlBorder: .white(0.22),
                controlShadow: .black(0.22)
            )
        case .light:
            return Self(
                panelTint: .white(0.46),
                cardFill: .white(0.36),
                cardBorder: .white(0.65),
                cardHighlight: .white(0.18),
                cardShadow: .rgb(44 / 255, 58 / 255, 82 / 255, alpha: 0.08),
                controlFill: .white(0.76),
                controlPressedFill: .white(0.88),
                controlForeground: .black(0.82),
                controlBorder: .black(0.18),
                controlShadow: .rgb(50 / 255, 63 / 255, 90 / 255, alpha: 0.12)
            )
        }
    }

    private static func nativeClear(for appearance: DashboardGlassAppearance) -> Self {
        switch appearance {
        case .dark:
            return Self(
                panelTint: .black(0.42),
                cardFill: .white(0.055),
                cardBorder: .white(0.13),
                cardHighlight: .white(0.06),
                cardShadow: .black(0.08),
                controlFill: .black(0.56),
                controlPressedFill: .black(0.74),
                controlForeground: .white(1),
                controlBorder: .white(0.18),
                controlShadow: .black(0.14)
            )
        case .light:
            return Self(
                panelTint: .white(0.34),
                cardFill: .white(0.19),
                cardBorder: .white(0.48),
                cardHighlight: .white(0.10),
                cardShadow: .rgb(44 / 255, 58 / 255, 82 / 255, alpha: 0.04),
                controlFill: .white(0.62),
                controlPressedFill: .white(0.78),
                controlForeground: .black(0.82),
                controlBorder: .black(0.14),
                controlShadow: .rgb(50 / 255, 63 / 255, 90 / 255, alpha: 0.08)
            )
        }
    }

    private static func matte(for appearance: DashboardGlassAppearance) -> Self {
        switch appearance {
        case .dark:
            return Self(
                panelTint: .black(0.16),
                cardFill: .white(0.075),
                cardBorder: .white(0.21),
                cardHighlight: .white(0.12),
                cardShadow: .black(0.20),
                controlFill: .black(0.82),
                controlPressedFill: .black(0.90),
                controlForeground: .white(1),
                controlBorder: .white(0.26),
                controlShadow: .black(0.28)
            )
        case .light:
            return Self(
                panelTint: .white(0.20),
                cardFill: .white(0.62),
                cardBorder: .black(0.13),
                cardHighlight: .white(0.12),
                cardShadow: .rgb(44 / 255, 58 / 255, 82 / 255, alpha: 0.09),
                controlFill: .white(0.94),
                controlPressedFill: .white(0.98),
                controlForeground: .black(0.82),
                controlBorder: .black(0.17),
                controlShadow: .rgb(44 / 255, 58 / 255, 82 / 255, alpha: 0.12)
            )
        }
    }

    private static func classic(for appearance: DashboardGlassAppearance) -> Self {
        switch appearance {
        case .dark:
            return Self(
                panelTint: .clear,
                cardFill: .clear,
                cardBorder: .white(0.24),
                cardHighlight: .clear,
                cardShadow: .black(0.08),
                controlFill: .clear,
                controlPressedFill: .clear,
                controlForeground: .white(1),
                controlBorder: .white(0.24),
                controlShadow: .black(0.08)
            )
        case .light:
            return Self(
                panelTint: .clear,
                cardFill: .clear,
                cardBorder: .black(0.16),
                cardHighlight: .clear,
                cardShadow: .black(0.08),
                controlFill: .clear,
                controlPressedFill: .clear,
                controlForeground: .black(0.82),
                controlBorder: .black(0.16),
                controlShadow: .black(0.08)
            )
        }
    }
}
