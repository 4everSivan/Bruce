import BruceGlassSurfaceCore
import BruceOnboardingCore

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
        try nothingMapsToFlatMonochromePlan()
        try nothingStyleMatrixIsFlatMonochrome()
        try nothingStaysFlatUnderAccessibility()
        print("DashboardGlassSurfaceHarness: 全部通过 (10)")
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

    // MARK: - Nothing 主题

    private static func nothingMapsToFlatMonochromePlan() throws {
        let plan = DashboardGlassSurfacePlan.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            capabilities: nativeCapabilities
        )
        try expect(plan.backend == .flatMonochrome, "nothing 必须使用纯色平面 backend")
        try expect(plan.panelMaterial == .nothing, "nothing panel 必须 nothing 材质")
        try expect(plan.cardMaterial == .nothing, "nothing card 必须 nothing 材质")
        try expect(plan.controlMaterial == .nothing, "nothing control 必须 nothing 材质")
        try expect(!plan.usesInteractiveGlass, "nothing 不得调用交互玻璃")
        try expect(!plan.reduceTransparencyFallback, "nothing 不触发无障碍降级标记")

        // 低版本 (nativeLiquidGlass=false) plan 完全不变
        let unsupported = DashboardGlassSurfacePlan.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            capabilities: DashboardGlassSurfaceCapabilities(
                nativeLiquidGlass: false,
                reduceTransparency: false,
                increaseContrast: false
            )
        )
        try expect(unsupported == plan, "nothing plan 不随玻璃能力变化")
    }

    private static func nothingStyleMatrixIsFlatMonochrome() throws {
        let dark = DashboardGlassSurfaceStyle.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        try expect(dark.panelTint == .black(1), "nothing dark 面板必须纯黑 #000000")
        try expect(
            dark.cardFill == .rgb(17 / 255, 17 / 255, 17 / 255, alpha: 1),
            "nothing dark 卡片必须 #111111"
        )
        try expect(
            dark.cardBorder == .rgb(34 / 255, 34 / 255, 34 / 255, alpha: 1),
            "nothing dark 卡片边框必须 #222222"
        )
        try expect(
            dark.controlForeground == .rgb(232 / 255, 232 / 255, 232 / 255, alpha: 1),
            "nothing dark 控件前景必须 #E8E8E8"
        )

        let light = DashboardGlassSurfaceStyle.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            appearance: .light,
            capabilities: nativeCapabilities
        )
        try expect(
            light.panelTint == .rgb(245 / 255, 245 / 255, 245 / 255, alpha: 1),
            "nothing light 面板必须 #F5F5F5"
        )
        try expect(light.cardFill == .white(1), "nothing light 卡片必须纯白 #FFFFFF")
        try expect(
            light.cardBorder == .rgb(232 / 255, 232 / 255, 232 / 255, alpha: 1),
            "nothing light 卡片边框必须 #E8E8E8"
        )
        try expect(
            light.controlForeground == .rgb(26 / 255, 26 / 255, 26 / 255, alpha: 1),
            "nothing light 控件前景必须 #1A1A1A"
        )

        // 零阴影零高光: 两模式 highlight/shadow 一律清零
        for style in [dark, light] {
            try expect(style.cardHighlight == .clear, "nothing 卡片高光必须清零")
            try expect(style.cardShadow == .clear, "nothing 卡片阴影必须清零")
            try expect(style.controlShadow == .clear, "nothing 控件阴影必须清零")
        }
        try expect(dark != light, "nothing 浅深色必须使用不同 token")
    }

    private static func nothingStaysFlatUnderAccessibility() throws {
        let base = DashboardGlassSurfacePlan.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            capabilities: nativeCapabilities
        )
        let baseStyle = DashboardGlassSurfaceStyle.resolve(
            theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
            appearance: .dark,
            capabilities: nativeCapabilities
        )
        // Nothing 本身纯色不透明零模糊, 天然满足无障碍需求, 不再降级
        for (reduceTransparency, increaseContrast) in [(true, false), (false, true)] {
            let capabilities = DashboardGlassSurfaceCapabilities(
                nativeLiquidGlass: true,
                reduceTransparency: reduceTransparency,
                increaseContrast: increaseContrast
            )
            let plan = DashboardGlassSurfacePlan.resolve(
                theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
                capabilities: capabilities
            )
            try expect(plan == base, "nothing 在无障碍设置下 plan 必须保持不变")
            let style = DashboardGlassSurfaceStyle.resolve(
                theme: theme(interfaceStyle: .nothing, glassStyle: .regular),
                appearance: .dark,
                capabilities: capabilities
            )
            try expect(style == baseStyle, "nothing 在无障碍设置下仍必须走纯色 token")
        }
    }
}
