import Charts
import Foundation
import MdddAppCore
import SwiftUI

/// 用量卡: 标题 + LIVE 呼吸灯, hero 总量, 输入/输出/缓存四格细分,
/// 14 日按 agent 堆叠柱状图与图例.
/// 视觉以 panel-layout-v8.html 为准; 外层玻璃卡片容器由面板装配层统一提供,
/// 本组件只排内容.
struct UsageHeroCard: View {
    let viewModel: UsageHeroViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 已完成生长的列 (按日期); 逐列延迟插入驱动柱状图自下而上生长.
    @State private var grownColumns: Set<String> = []

    init(viewModel: UsageHeroViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            heroRow
                .padding(.top, 8)
            dividerLine
                .padding(.top, 12)
            breakdownRow
                .padding(.top, 10)
            usageChart
                // 与上方输入/输出指标之间留足间距, 避免高柱标注遮挡.
                .padding(.top, 16)
            dateAxis
                .padding(.top, 3)
            legendRow
                .padding(.top, 4)
        }
        .background {
            CodeStreamBackground(tint: Self.tierTint(viewModel.usageTier))
        }
    }

    // MARK: 标题行

    private var titleRow: some View {
        HStack {
            Text("用量")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Self.ink)
            Spacer()
            if viewModel.isLive {
                LiveIndicator()
            }
        }
    }

    // MARK: Hero 行

    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(viewModel.totalTokensText)
                .font(.system(size: 40, weight: .bold))
                .tracking(-1.2)
                .monospacedDigit()
                .foregroundStyle(Self.heroGradient(for: viewModel.usageTier))
            Text("tokens")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.subdued)
            Spacer()
            if let costText = viewModel.costText {
                Text(costText)
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Self.accent)
            }
        }
    }

    // MARK: 分隔线

    private var dividerLine: some View {
        Rectangle()
            .fill(Self.hairline)
            .frame(height: 1)
    }

    // MARK: 四格细分

    private var breakdownRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(viewModel.breakdown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(Self.hairline)
                        .frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(.system(size: 8.5))
                        .tracking(0.85)
                        .foregroundStyle(Self.faint)
                    Text(item.valueText)
                        .font(.system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Self.ink.opacity(0.85))
                }
                .padding(.leading, index == 0 ? 0 : 13)
                .padding(.trailing, index == viewModel.breakdown.count - 1 ? 0 : 13)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 14 日堆叠柱状图

    private var maxDayTotal: Int {
        max(viewModel.days.map(\.total).max() ?? 0, 1)
    }

    private var usageChart: some View {
        Chart {
            ForEach(viewModel.days, id: \.date) { day in
                if day.segments.isEmpty {
                    // 无量日保留零值占位, 让总量标注和列位不塌掉.
                    BarMark(
                        x: .value("日期", day.date),
                        y: .value("Tokens", 0)
                    )
                    .foregroundStyle(.clear)
                    .annotation(position: .top) {
                        dayTotalLabel(day)
                    }
                } else {
                    ForEach(day.segments, id: \.agentID) { segment in
                        BarMark(
                            x: .value("日期", day.date),
                            y: .value("Tokens", grownColumns.contains(day.date) ? segment.value : 0)
                        )
                        .foregroundStyle(Color(hex: segment.color.hex))
                        .cornerRadius(1.5)
                        .annotation(position: .top) {
                            // 只在每列最顶端分段上标注当日总量.
                            if segment.agentID == day.segments.last?.agentID {
                                dayTotalLabel(day)
                            }
                        }
                    }
                }
            }
        }
        // 固定 Y 域, 生长动画期间已出现的列不会因新列出现而重新缩放.
        .chartYScale(domain: 0...maxDayTotal)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 68)
        .task {
            await growColumns()
        }
    }

    private func dayTotalLabel(_ day: UsageChartDay) -> some View {
        Text(day.totalText)
            .font(.system(size: 7.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// 逐列延迟 0.03 秒把列值从 0 推到真实值, 形成自下而上的生长动画;
    /// Reduce Motion 时直接全部就位.
    private func growColumns() async {
        if reduceMotion {
            grownColumns = Set(viewModel.days.map(\.date))
            return
        }
        for day in viewModel.days {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeOut(duration: 0.5)) {
                _ = grownColumns.insert(day.date)
            }
        }
    }

    // MARK: 日期轴

    private var dateAxis: some View {
        HStack {
            Text("14 天前")
            Spacer()
            Text("7 天前")
            Spacer()
            Text("今天")
        }
        .font(.system(size: 9))
        .foregroundStyle(Self.faint)
    }

    // MARK: 图例

    private var legendRow: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.legend, id: \.agentID) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: item.color.hex))
                        .frame(width: 7, height: 7)
                    Text(item.name)
                }
            }
        }
        .font(.system(size: 9.5))
        .foregroundStyle(Self.legendInk)
    }

    // MARK: 颜色常量 (浅色值换算自 mockup CSS, 深色值见 adaptive 调用)

    private static let accent = Color(hex: "#0a84ff")
    private static let ink = Color.primary
    private static let subdued = Color.primary.opacity(0.5)
    private static let faint = Color.primary.opacity(0.55)
    private static let legendInk = Color.primary.opacity(0.75)
    private static let hairline = Color.adaptive(
        light: Color.black.opacity(0.07),
        dark: Color.white.opacity(0.12)
    )
    /// hero 渐变按总量档位变化: < 50M 绿, 50M-150M 橙, 150M-250M 红,
    /// >= 250M 紫. 结构沿用 mockup (135deg, 起点 30%, 终点收敛 1.0),
    /// 深浅色各自适配玻璃可见性.
    private static func heroGradient(for tier: UsageTier) -> LinearGradient {
        let (start, end) = tierColors(for: tier)
        return LinearGradient(
            stops: [
                .init(color: start, location: 0.3),
                .init(color: end, location: 1.0),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 档位配色: 返回 (深色阶, 浅色阶); 浅色阶同时作为背景字符 tint.
    private static func tierColors(for tier: UsageTier) -> (Color, Color) {
        switch tier {
        case .green:
            return (
                Color.adaptive(light: Color(hex: "#0f8a43"), dark: Color(hex: "#30d158")),
                Color.adaptive(light: Color(hex: "#2fb35f"), dark: Color(hex: "#7ce79b"))
            )
        case .orange:
            return (
                Color.adaptive(light: Color(hex: "#c26a00"), dark: Color(hex: "#ffb340")),
                Color.adaptive(light: Color(hex: "#ff9f0a"), dark: Color(hex: "#ffd60a"))
            )
        case .red:
            return (
                Color.adaptive(light: Color(hex: "#c41e1e"), dark: Color(hex: "#ff6961")),
                Color.adaptive(light: Color(hex: "#ff453a"), dark: Color(hex: "#ff9f97"))
            )
        case .purple:
            return (
                Color.adaptive(light: Color(hex: "#7d2ae8"), dark: Color(hex: "#bf5af2")),
                Color.adaptive(light: Color(hex: "#a94df5"), dark: Color(hex: "#d8a7ff"))
            )
        }
    }

    /// 背景字符 tint: 档位浅色阶, 低透明度下呼应 hero 渐变.
    private static func tierTint(_ tier: UsageTier) -> Color {
        tierColors(for: tier).1
    }
}

// MARK: - 代码流背景

/// 用量卡代码流背景: 复刻旧 web widget 的字符密度流场 (.:+*# 网格下流),
/// 按总量档位取 tint, 低透明度叠加在玻璃之上, 底部 mask 渐隐避免干扰图表.
/// 10fps 慢速下流, 每列速度略有差异; Reduce Motion 时静止.
private struct CodeStreamBackground: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let characters: [Character] = [".", ":", "+", "*", "#"]
    private let spacing: CGFloat = 16
    /// 基准流速 (pt/s), 远慢于常规动画, 保持液态玻璃的安静感.
    private let speed: CGFloat = 9

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            Canvas { ctx, size in
                let drift = reduceMotion
                    ? 0
                    : CGFloat(context.date.timeIntervalSinceReferenceDate) * speed
                let cycle = size.height + spacing
                let cols = Int(size.width / spacing)
                let rows = Int(size.height / spacing) + 2
                guard cols > 0, rows > 0 else {
                    return
                }
                for col in 0...cols {
                    // 每列 0.6-1.2 倍速, 形成错落的流场层次.
                    let columnFactor = 0.6 + 0.6 * Double(cellHash(col, 0) % 101) / 100.0
                    let x = spacing / 2 + CGFloat(col) * spacing
                    for row in 0...rows {
                        let base = CGFloat(row) * spacing + drift * columnFactor
                        let y = base.truncatingRemainder(dividingBy: cycle) - spacing / 2
                        let hash = cellHash(col, row)
                        let char = characters[Int(hash % UInt64(characters.count))]
                        ctx.opacity = 0.05 + 0.09 * Double((hash >> 8) % 101) / 100.0
                        ctx.draw(
                            Text(String(char))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(tint),
                            at: CGPoint(x: x, y: y),
                            anchor: .center
                        )
                    }
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.45),
                    .init(color: .clear, location: 0.95),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 稳定伪随机 (按网格坐标), 保证每帧布局与字符一致, 仅位置随时间漂移.
    private func cellHash(_ col: Int, _ row: Int) -> UInt64 {
        var hash = UInt64(bitPattern: Int64(col)) &* 2_654_435_761
            &+ UInt64(bitPattern: Int64(row)) &* 4_053_739
        hash ^= hash >> 13
        return hash
    }
}

// MARK: - LIVE 呼吸灯

/// 绿点 + 光晕, 2.4 秒一周期的透明度呼吸; Reduce Motion 时静止常亮.
private struct LiveIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                // 光晕: mockup 为 3px 扩散环 (18% 透明度).
                Circle()
                    .fill(Self.green.opacity(0.18))
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(Self.green)
                    .frame(width: 6, height: 6)
            }
            .opacity(breathing ? 0.25 : 1)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                value: breathing
            )
            .onAppear {
                guard !reduceMotion else {
                    return
                }
                breathing = true
            }
            Text("LIVE")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Self.textGreen)
        }
    }

    private static let green = Color(hex: "#30d158")
    /// 深绿文字在深色玻璃上对比度不足, 深色下退回亮绿.
    private static let textGreen = Color.adaptive(light: Color(hex: "#0a7d3b"), dark: Color(hex: "#30d158"))
}

// MARK: - 十六进制颜色

private extension Color {
    /// 解析 "#rrggbb" 十六进制颜色; 非法输入回退为黑色.
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

// 命令行工具链 (无 Xcode) 缺少 PreviewsMacros 插件, 用 canImport 守住,
// 保证 swift build 在两种工具链下都能通过; Xcode 下预览照常生效.
#if DEBUG && canImport(PreviewsMacros)
/// 预览 fixture: 以 artifact JSON 经 PanelViewModelMapper 生成真实 view model,
/// 覆盖 4 个 agent, 2-4 段堆叠, 成本文案, LIVE 态和完整四格细分.
/// (UsageHeroViewModel 暂无 package 级构造器, 不能直接 memberwise 构造.)
private enum UsageHeroPreviewFixture {
    static func makeViewModel() -> UsageHeroViewModel {
        let artifact = try! JSONDecoder().decode(
            AgentUsageArtifact.self,
            from: Data(artifactJSON.utf8)
        )
        let panel = PanelViewModelMapper().make(
            agentUsage: artifact,
            moduleStatuses: [:]
        )
        guard let usage = panel.usage else {
            preconditionFailure("fixture artifact 应映射出用量卡 view model")
        }
        return usage
    }

    /// 14 日总量形态对齐 mockup (首尾低, 中间起伏, 今天最高).
    private static let kimiCodeTotals = [6000, 10000, 8000, 16000, 13000, 9000, 19000, 15000, 22000, 18000, 11000, 25000, 20000, 30000]
    private static let kimiWorkTotals = [3000, 5000, 5000, 9000, 7000, 6000, 12000, 8000, 13000, 10000, 8000, 16000, 11000, 19000]
    private static let claudeTotals = [0, 3000, 0, 4000, 4000, 0, 5000, 4000, 6000, 5000, 0, 7000, 5000, 9000]
    private static let codexTotals = [0, 0, 0, 2000, 0, 0, 2000, 0, 3000, 0, 0, 4000, 0, 6000]

    private static var artifactJSON: String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        let today = Date()

        func dailyJSON(_ totals: [Int]) -> String {
            totals.enumerated().compactMap { index, total in
                guard total > 0,
                      let date = calendar.date(byAdding: .day, value: index - 13, to: today)
                else {
                    return nil
                }
                let dateText = dayFormatter.string(from: date)
                return #"{"date":"\#(dateText)","input":\#(total * 3 / 4),"output":\#(total / 4),"total":\#(total)}"#
            }
            .joined(separator: ",")
        }

        func agentJSON(
            id: String,
            name: String,
            totals: [Int],
            today: (input: Int, output: Int, cacheRead: Int, cacheCreation: Int, total: Int)
        ) -> String {
            """
            {"id":"\(id)","name":"\(name)","status":"ok",\
            "today":{"input":\(today.input),"output":\(today.output),\
            "cacheRead":\(today.cacheRead),"cacheCreation":\(today.cacheCreation),"total":\(today.total)},\
            "daily":[\(dailyJSON(totals))],"hours":\(Array(repeating: 0, count: 24))}
            """
        }

        let generatedAt = ISO8601DateFormatter().string(from: today)
        return """
        {"schemaVersion":1,"module":"agent-usage","generatedAt":"\(generatedAt)",\
        "agents":[
        \(agentJSON(id: "kimi-code-cli", name: "Kimi Code CLI", totals: kimiCodeTotals,
                    today: (98000, 14000, 20000, 7000, 98000))),
        \(agentJSON(id: "kimi-work", name: "Kimi Work", totals: kimiWorkTotals,
                    today: (34000, 6000, 8000, 3000, 52000))),
        \(agentJSON(id: "claude-code", name: "Claude Code", totals: claudeTotals,
                    today: (18000, 3000, 4000, 1200, 21000))),
        \(agentJSON(id: "codex", name: "Codex", totals: codexTotals,
                    today: (9000, 2000, 2000, 800, 13000)))
        ],"services":[],"totalCostUsd":0.375}
        """
    }
}

#Preview("用量卡 · 完整数据") {
    UsageHeroCard(viewModel: UsageHeroPreviewFixture.makeViewModel())
        .padding(15)
        .frame(width: 400)
        .background(Color(hex: "#e9e4ef"))
}
#endif
