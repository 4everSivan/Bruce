import BruceGlassSurfaceCore

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

@main
struct DashboardGlassSurfaceHarness {
    static func main() throws {
        try planIsFlatMonochromeOnly()
        try styleMatrixIsFlatMonochrome()
        print("DashboardGlassSurfaceHarness: 全部通过 (2)")
    }

    /// C271: 玻璃 / 材质矩阵整体退役, 只剩 Nothing 纯色平面 plan.
    private static func planIsFlatMonochromeOnly() throws {
        let plan = DashboardGlassSurfacePlan.nothing
        try expect(plan.backend == .flatMonochrome, "C271: backend 必须纯色平面")
        try expect(plan.panelMaterial == .nothing, "C271: panel 必须 nothing 材质")
        try expect(plan.cardMaterial == .nothing, "C271: card 必须 nothing 材质")
        try expect(plan.controlMaterial == .nothing, "C271: control 必须 nothing 材质")
    }

    private static func styleMatrixIsFlatMonochrome() throws {
        let dark = DashboardGlassSurfaceStyle.resolve(appearance: .dark)
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

        let light = DashboardGlassSurfaceStyle.resolve(appearance: .light)
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

        // 零阴影零高光: 两模式 highlight/shadow 一律清零.
        for style in [dark, light] {
            try expect(style.cardHighlight == .clear, "nothing 卡片高光必须清零")
            try expect(style.cardShadow == .clear, "nothing 卡片阴影必须清零")
            try expect(style.controlShadow == .clear, "nothing 控件阴影必须清零")
        }
        try expect(dark != light, "nothing 浅深色必须使用不同 token")
    }
}
