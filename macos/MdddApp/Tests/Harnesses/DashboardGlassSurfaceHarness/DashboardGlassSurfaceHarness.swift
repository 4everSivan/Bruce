import MdddGlassSurfaceCore
import MdddOnboardingCore

private enum SurfaceTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw SurfaceTestFailure.expectation(message)
    }
}

private let nativeCapabilities = DashboardGlassSurfaceCapabilities(
    nativeLiquidGlass: true,
    reduceTransparency: false,
    increaseContrast: false
)

private func theme(
    interfaceStyle: InterfaceStylePreference = .liquidGlass,
    glassStyle: GlassStylePreference
) -> ResolvedTheme {
    ResolvedTheme(
        interfaceStyle: interfaceStyle,
        glassStyle: glassStyle,
        usesLiquidGlassEffects: interfaceStyle == .liquidGlass
            && glassStyle.usesGlassMaterial
    )
}

@main
struct DashboardGlassSurfaceHarness {
    static func main() throws {
        try regularMapsToThreeLayerPlan()
        try clearMapsToLowerContrastPlan()
        try matteMapsToAppKitFallback()
        try classicAndUnsupportedUseSafeFallback()
        try accessibilityOverridesLiquidGlass()
        try matrixChangesWithAppearance()
        try matrixKeepsCardAndControlDistinct()
        print("DashboardGlassSurfaceHarness: 全部通过 (7)")
    }

    private static func regularMapsToThreeLayerPlan() throws {
        let plan = DashboardGlassSurfacePlan.resolve(
            theme: theme(glassStyle: .regular),
            capabilities: nativeCapabilities
        )
        try expect(plan.backend == .nativeLiquidGlass, "regular 必须使用原生玻璃")
        try expect(plan.panelMaterial == .standard, "regular panel 必须 standard")
        try expect(plan.cardMaterial == .clear, "regular card 必须 clear")
        try expect(plan.controlMaterial == .standard, "regular control 必须 adaptive standard")
        try expect(plan.usesInteractiveGlass, "regular control 必须保留交互玻璃能力")
    }

    private static func clearMapsToLowerContrastPlan() throws {
        let plan = DashboardGlassSurfacePlan.resolve(
            theme: theme(glassStyle: .clear),
            capabilities: nativeCapabilities
        )
        try expect(plan.backend == .nativeLiquidGlass, "clear 必须使用原生玻璃")
        try expect(plan.panelMaterial == .clear, "clear panel 必须 clear")
        try expect(plan.cardMaterial == .clear, "clear card 必须 clear")
        try expect(plan.controlMaterial == .clear, "clear control 必须 anchored clear")
        try expect(plan.usesInteractiveGlass, "clear control 必须保留交互玻璃能力")
    }

    private static func matteMapsToAppKitFallback() throws {
        let plan = DashboardGlassSurfacePlan.resolve(
            theme: theme(glassStyle: .material),
            capabilities: nativeCapabilities
        )
        try expect(plan.backend == .appKitMaterial, "material 必须使用 AppKit fallback")
        try expect(plan.panelMaterial == .matte, "material panel 必须 matte")
        try expect(plan.cardMaterial == .matte, "material card 必须 matte")
        try expect(plan.controlMaterial == .classic, "material control 必须实体控件")
        try expect(!plan.usesInteractiveGlass, "material 不得调用交互玻璃")
    }

    private static func classicAndUnsupportedUseSafeFallback() throws {
        let classic = DashboardGlassSurfacePlan.resolve(
            theme: theme(interfaceStyle: .classic, glassStyle: .regular),
            capabilities: nativeCapabilities
        )
        let unsupported = DashboardGlassSurfacePlan.resolve(
            theme: theme(glassStyle: .regular),
            capabilities: DashboardGlassSurfaceCapabilities(
                nativeLiquidGlass: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
        for plan in [classic, unsupported] {
            try expect(plan.backend == .appKitMaterial, "classic/低版本必须 AppKit fallback")
            try expect(plan.panelMaterial == .classic, "classic/低版本 panel 必须 classic")
            try expect(plan.cardMaterial == .classic, "classic/低版本 card 必须 classic")
            try expect(!plan.usesInteractiveGlass, "classic/低版本不得调用 glass")
        }
    }

    private static func accessibilityOverridesLiquidGlass() throws {
        for reduceTransparency in [true, false] {
            let plan = DashboardGlassSurfacePlan.resolve(
                theme: theme(glassStyle: .regular),
                capabilities: DashboardGlassSurfaceCapabilities(
                    nativeLiquidGlass: true,
                    reduceTransparency: reduceTransparency,
                    increaseContrast: !reduceTransparency
                )
            )
            try expect(plan.reduceTransparencyFallback, "无障碍设置必须触发实体回退")
            try expect(!plan.usesInteractiveGlass, "无障碍回退不得调用 glass")
        }
    }

    private static func matrixChangesWithAppearance() throws {
        let regularLight = DashboardGlassSurfaceStyle.resolve(
            theme: theme(glassStyle: .regular),
            appearance: .light,
            capabilities: nativeCapabilities
        )
        let regularDark = DashboardGlassSurfaceStyle.resolve(
            theme: theme(glassStyle: .regular),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        try expect(regularLight.cardFill != regularDark.cardFill, "浅深色必须使用不同 card fill")
        try expect(regularLight.controlFill != regularDark.controlFill, "浅深色必须使用不同 control fill")
        try expect(regularLight.panelTint != regularDark.panelTint, "浅深色必须使用不同 panel tint")
    }

    private static func matrixKeepsCardAndControlDistinct() throws {
        let regular = DashboardGlassSurfaceStyle.resolve(
            theme: theme(glassStyle: .regular),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        let clear = DashboardGlassSurfaceStyle.resolve(
            theme: theme(glassStyle: .clear),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        let matte = DashboardGlassSurfaceStyle.resolve(
            theme: theme(glassStyle: .material),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        try expect(regular.cardFill.alpha > clear.cardFill.alpha, "regular card 应比 clear 更有存在感")
        try expect(matte.cardFill.alpha > clear.cardFill.alpha, "matte card 应比 clear 更实体")
        try expect(regular.controlFill.alpha > clear.controlFill.alpha, "regular control 应比 clear 更有对比")
        try expect(matte.controlFill.alpha > regular.controlFill.alpha, "matte control 应最实体")
    }
}
