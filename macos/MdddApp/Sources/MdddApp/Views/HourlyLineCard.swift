import Charts
import Foundation
import MdddAppCore
import SwiftUI

/// 逐小时卡: 每个 agent 一行色点 + 名称 + 今日总量, 下方 24 点折线;
/// 有模型或项目明细的行可整行点击展开, 明细 (100% 堆叠占比条 + 图例行) 直接排在折线下方.
/// 视觉与条件渲染以 panel-layout-v8.html 的逐小时卡为准.
struct HourlyLineCard: View {
    let viewModel: HourlyLineViewModel

    /// 已展开明细的 agent id 集合.
    @State private var expandedAgentIDs: Set<String>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - viewModel: 逐小时卡 view model.
    ///   - initiallyExpandedAgentIDs: 初始展开的 agent id, 默认全收起 (预览用).
    init(viewModel: HourlyLineViewModel, initiallyExpandedAgentIDs: Set<String> = []) {
        self.viewModel = viewModel
        _expandedAgentIDs = State(initialValue: initiallyExpandedAgentIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .padding(.bottom, 2)

            ForEach(Array(viewModel.rows.enumerated()), id: \.element.agentID) { index, row in
                if index > 0 {
                    rowDivider
                }
                agentRow(row)
            }
        }
    }

    // MARK: - 标题行

    private var titleRow: some View {
        HStack {
            Text("逐小时")
                .font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text("0 – 23 时")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - agent 行

    /// 行间 1pt 分隔线, 对应 mockup `border-top: 1px solid rgba(0,0,0,.05)`;
    /// 深色下改为低透明白.
    private var rowDivider: some View {
        Color.adaptive(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.10))
            .frame(height: 1)
    }

    @ViewBuilder
    private func agentRow(_ row: HourlyAgentRow) -> some View {
        if row.isExpandable {
            // 可展开行整行可点, 保持按钮语义供辅助功能识别.
            Button {
                toggle(row.agentID)
            } label: {
                agentRowBody(row)
            }
            .buttonStyle(.plain)
        } else {
            agentRowBody(row)
        }
    }

    private func agentRowBody(_ row: HourlyAgentRow) -> some View {
        let expanded = expandedAgentIDs.contains(row.agentID)
        return VStack(alignment: .leading, spacing: 4) {
            headRow(row, expanded: expanded)
            hourlyChart(row)
            if expanded {
                detailSection(row)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func headRow(_ row: HourlyAgentRow, expanded: Bool) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2)
                .fill(agentColor(row))
                .frame(width: 7, height: 7)
            Text(row.name)
                .font(.system(size: 11, weight: .semibold))
            if row.isExpandable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            Spacer(minLength: 7)
            Text(row.todayTotalText)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
    }

    /// 24 点折线 (0-23 时), agent 色 1.5pt 线 + 淡渐变面积.
    private func hourlyChart(_ row: HourlyAgentRow) -> some View {
        let color = agentColor(row)
        let maxPoint = max(row.points.max() ?? 0, 1)
        return Chart(Array(row.points.enumerated()), id: \.offset) { point in
            LineMark(
                x: .value("时", point.offset),
                y: .value("量", point.element)
            )
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
            AreaMark(
                x: .value("时", point.offset),
                y: .value("量", point.element)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [color.opacity(0.18), color.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        // 顶部留一点余量, 避免峰值线被裁掉.
        .chartYScale(domain: 0...(Double(maxPoint) * 1.1))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 26)
    }

    // MARK: - 展开明细

    private func toggle(_ agentID: String) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            if expandedAgentIDs.contains(agentID) {
                expandedAgentIDs.remove(agentID)
            } else {
                expandedAgentIDs.insert(agentID)
            }
        }
    }

    /// 明细区: 模型占比 + 项目分布两组 DistributionBar, 直接排在折线下方, 无内层卡片容器.
    private func detailSection(_ row: HourlyAgentRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !row.models.isEmpty {
                distributionGroup(title: "模型占比", bars: row.models, color: agentColor(row))
            }
            if !row.projects.isEmpty {
                distributionGroup(title: "项目分布", bars: row.projects, color: Self.projectBarColor)
                    .padding(.top, row.models.isEmpty ? 0 : 7)
            }
        }
        .padding(.leading, 14)
        .padding(.top, 3)
    }

    /// 占比组: 标题 + 通宽 100% 堆叠条 + 图例行 (色点 + 名称 + 百分比 + 数值).
    private func distributionGroup(title: String, bars: [DistributionBar], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            stackedShareBar(bars, color: color)
                .padding(.bottom, 3)
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                shareLegendRow(bar, color: color, opacity: Self.barOpacity(at: index))
            }
        }
    }

    /// 100% 堆叠占比条: 分段按份额拼接, 同组按位次降透明度, 份额不足 100% 时余量露出轨道色.
    private func stackedShareBar(_ bars: [DistributionBar], color: Color) -> some View {
        GeometryReader { proxy in
            let available = proxy.size.width - CGFloat(max(bars.count - 1, 0))
            HStack(spacing: 1) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                    Rectangle()
                        .fill(color.opacity(Self.barOpacity(at: index)))
                        .frame(width: max(2, available * min(max(bar.share, 0), 1)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.adaptive(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.12)))
            )
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// 图例行: 色点 + 名称 + 右侧「百分比 · 数值」, 百分比为主数值.
    private func shareLegendRow(_ bar: DistributionBar, color: Color, opacity: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.opacity(opacity))
                .frame(width: 5, height: 5)
            Text(bar.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.sharePercentText(bar.share))
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
            + Text(" · \(bar.totalText)")
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Color.primary.opacity(0.85))
        .accessibilityElement(children: .combine)
    }

    /// 份额文案: 0 到 0.5% 之间显示 <1%, 避免四舍五入成误导性的 0%.
    private static func sharePercentText(_ share: Double) -> String {
        if share > 0, share < 0.005 {
            return "<1%"
        }
        return String(format: "%.0f%%", share * 100)
    }

    // MARK: - 颜色

    private func agentColor(_ row: HourlyAgentRow) -> Color {
        Color(hex: row.color.hex)
    }

    /// 项目分布量条色, 对应 mockup 的 teal (#30b0c7), 与 agent 色无关.
    private static let projectBarColor = Color(hex: "#30b0c7")

    /// 同组量条按位次降透明度, 对应 mockup 的 1.0 / .65 / .4.
    private static func barOpacity(at index: Int) -> Double {
        let steps: [Double] = [1.0, 0.65, 0.4]
        return steps[min(index, steps.count - 1)]
    }
}

// MARK: - 私有 hex 颜色初始化

private extension Color {
    /// 从 "#rrggbb" 形式构造颜色, 仅本文件使用.
    init(hex: String) {
        var text = hex
        if text.hasPrefix("#") {
            text.removeFirst()
        }
        var value: UInt64 = 0
        Scanner(string: text).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    /// 深浅色自适应: 浅色外观用 light, 深色外观用 dark.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Preview

/// 内容丰富的预览 fixture: 两行可展开 (模型 + 项目), 两行无明细不可展开.
private extension HourlyLineViewModel {
    static var hourlyLinePreviewFixture: HourlyLineViewModel {
        HourlyLineViewModel(rows: [
            HourlyAgentRow(
                agentID: "kimi-code-cli",
                name: "Kimi Code",
                color: .blue,
                todayTotal: 98_000,
                points: [900, 1400, 2100, 2600, 3200, 4100, 3800, 5200, 6100, 5800, 7200, 6600,
                         5400, 4900, 6300, 7800, 7100, 5900, 4700, 4300, 3600, 2800, 1900, 1200],
                models: [
                    DistributionBar(name: "kimi-k2", total: 70_500, share: 0.72),
                    DistributionBar(name: "kimi-k1.5", total: 20_600, share: 0.21),
                    DistributionBar(name: "其他", total: 6900, share: 0.07),
                ],
                projects: [
                    DistributionBar(name: "mddd", total: 56_800, share: 0.58),
                    DistributionBar(name: "app_project", total: 30_400, share: 0.31),
                    DistributionBar(name: "其他", total: 10_800, share: 0.11),
                ]
            ),
            HourlyAgentRow(
                agentID: "kimi-work",
                name: "Kimi Work",
                color: .cyan,
                todayTotal: 52_000,
                points: [1800, 2600, 2400, 3300, 3000, 3900, 3600, 4400, 4100, 4800, 4500, 5200,
                         4700, 4100, 3800, 3400, 3900, 3300, 2900, 2600, 2300, 2000, 1700, 1500],
                models: [
                    DistributionBar(name: "kimi-k2", total: 44_200, share: 0.85),
                    DistributionBar(name: "其他", total: 7800, share: 0.15),
                ],
                projects: [
                    DistributionBar(name: "mddd", total: 33_300, share: 0.64),
                    DistributionBar(name: "其他", total: 18_700, share: 0.36),
                ]
            ),
            HourlyAgentRow(
                agentID: "claude-code",
                name: "Claude Code",
                color: .orange,
                todayTotal: 21_000,
                points: [300, 500, 800, 700, 1100, 1400, 1200, 1600, 1900, 1700, 2100, 1800,
                         1500, 1300, 1000, 900, 700, 600, 500, 400, 350, 300, 250, 200],
                models: [],
                projects: []
            ),
            HourlyAgentRow(
                agentID: "codex",
                name: "Codex",
                color: .purple,
                todayTotal: 13_000,
                points: [100, 200, 300, 250, 500, 800, 650, 1100, 1400, 1200, 1500, 1300,
                         1000, 900, 700, 550, 450, 400, 300, 250, 200, 150, 100, 50],
                models: [],
                projects: []
            ),
        ])
    }
}

// 命令行 swift build 无法解析 #Preview 宏插件 (PreviewsMacros),
// 这里用 PreviewProvider, Xcode 画布同样可直接预览.
struct HourlyLineCard_Previews: PreviewProvider {
    static var previews: some View {
        HourlyLineCard(
            viewModel: .hourlyLinePreviewFixture,
            initiallyExpandedAgentIDs: ["kimi-code-cli"]
        )
        .padding(12)
        .frame(width: 320)
        .background(Color(white: 0.93))
    }
}
