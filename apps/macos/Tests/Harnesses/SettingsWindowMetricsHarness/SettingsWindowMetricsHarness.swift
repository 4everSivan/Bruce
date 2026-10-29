import CoreGraphics
import Foundation

import BruceAppCore

/// 设置窗口比例锁定规则 (C152) 的边界测试:
/// 默认尺寸下的侧栏/面板宽度, 缩放时比例恒定, 长标签不挤压的下限兜底,
/// 以及非法宽度输入。
private enum SettingsWindowMetricsFailure: Error, CustomStringConvertible {
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
        throw SettingsWindowMetricsFailure.expectation(message)
    }
}

@main
struct SettingsWindowMetricsHarness {
    static func main() throws {
        try defaultSize()
        try lockedRatio()
        try narrowerThanLegacy()
        try monotonicGrowth()
        try degenerateInputs()
        print("SettingsWindowMetrics tests passed: 5")
    }

    /// 默认 1000pt 内容宽度: 侧栏 176pt, 右侧面板保持 823pt.
    private static func defaultSize() throws {
        let width = SettingsWindowMetrics.defaultContentWidth
        try expect(width == 1000, "默认内容宽度应保持 1000pt, 实际 \(width)")
        try expect(
            SettingsWindowMetrics.defaultContentHeight == 680,
            "默认内容高度应保持 680pt"
        )
        try expect(
            SettingsWindowMetrics.sidebarWidth(forContentWidth: width) == 176,
            "1000pt 下侧栏应为 176pt, 实际 \(SettingsWindowMetrics.sidebarWidth(forContentWidth: width))"
        )
        try expect(
            SettingsWindowMetrics.paneWidth(forContentWidth: width) == 823,
            "1000pt 下右侧面板应为 823pt, 实际 \(SettingsWindowMetrics.paneWidth(forContentWidth: width))"
        )
    }

    /// 任意支持宽度下侧栏占比都锁定在 17.6% (±1px 取整误差).
    private static func lockedRatio() throws {
        for width in [980, 1000, 1040, 1160, 1280, 1440, 1680, 2048] as [CGFloat] {
            let sidebar = SettingsWindowMetrics.sidebarWidth(forContentWidth: width)
            let deviation = abs(sidebar - width * SettingsWindowMetrics.sidebarWidthRatio)
            try expect(
                deviation <= 0.5,
                "\(width)pt 下侧栏偏离比例 \(deviation)pt (侧栏 \(sidebar))"
            )
            try expect(
                SettingsWindowMetrics.paneWidth(forContentWidth: width) == width - sidebar - 1,
                "\(width)pt 下面板宽度未扣除侧栏与 1pt 分隔线"
            )
        }
        // 逐点核对取整结果, 防止比例常数被静默改动.
        try expect(SettingsWindowMetrics.sidebarWidth(forContentWidth: 1040) == 183, "1040pt 侧栏应为 183pt")
        try expect(SettingsWindowMetrics.sidebarWidth(forContentWidth: 1200) == 211, "1200pt 侧栏应为 211pt")
        try expect(SettingsWindowMetrics.sidebarWidth(forContentWidth: 1500) == 264, "1500pt 侧栏应为 264pt")
    }

    /// 同样是 1040pt 窗口, 侧栏必须比旧固定值 216pt 明显收窄, 右侧面板相应变宽.
    private static func narrowerThanLegacy() throws {
        let sidebar = SettingsWindowMetrics.sidebarWidth(forContentWidth: 1040)
        try expect(sidebar < 216, "1040pt 下侧栏应窄于旧的固定 216pt, 实际 \(sidebar)")
        try expect(
            SettingsWindowMetrics.paneWidth(forContentWidth: 1040) > 823,
            "收窄侧栏后 1040pt 窗口的右侧面板应宽于 823pt"
        )
    }

    /// 窗口放大时侧栏只增不减, 且不与面板宽度相加溢出窗口.
    private static func monotonicGrowth() throws {
        var previous: CGFloat = 0
        for width in stride(from: 900 as CGFloat, through: 2200, by: 40) {
            let sidebar = SettingsWindowMetrics.sidebarWidth(forContentWidth: width)
            try expect(sidebar >= previous, "\(width)pt 下侧栏宽度出现回退")
            try expect(
                sidebar + SettingsWindowMetrics.paneWidth(forContentWidth: width) + 1 == width,
                "\(width)pt 下侧栏与面板之和未填满窗口"
            )
            previous = sidebar
        }
    }

    /// 零宽/负宽/非有限宽度落在可读性下限, 面板宽度归零而不产生负值.
    private static func degenerateInputs() throws {
        let minimum = SettingsWindowMetrics.sidebarMinimumWidth
        for width in [0, -100, CGFloat.nan, CGFloat.infinity] {
            try expect(
                SettingsWindowMetrics.sidebarWidth(forContentWidth: width) == minimum,
                "非法宽度 \(width) 应兜底为 \(minimum)pt"
            )
        }
        try expect(
            SettingsWindowMetrics.paneWidth(forContentWidth: 0) == 0,
            "零宽窗口的面板宽度应为 0"
        )
        try expect(
            SettingsWindowMetrics.paneWidth(forContentWidth: 100) == 0,
            "窄于侧栏下限时面板宽度不应为负"
        )
    }
}
