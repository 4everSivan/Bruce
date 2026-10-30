import Charts
import SwiftUI
import BruceAppCore

/// 时序趋势折线/面积分析卡片 (基于 Swift Charts 原生渲染)
struct TimelineChartCard: View {
    let points: [AnalyticsTimelinePoint]
    let peakSummary: String
    let avgSummary: String
    let availableAgents: [AnalyticsAgentCardItem]
    let availableModels: [CanonicalModelSummary]

    @State private var mode: AnalyticsChartSeriesMode = .byAgent
    @State private var displayType: AnalyticsChartDisplayType = .line
    @State private var selectedLabel: String? = nil

    private struct ChartDataPoint: Identifiable {
        var id: String { "\(date)_\(seriesKey)" }
        let date: String
        let seriesKey: String
        let seriesName: String
        let seriesColor: Color
        let value: Double
    }

    var body: some View {
        FluentCard {
            // 顶部标题与控制栏
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("时序趋势")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)
                            .lineLimit(1)
                        Text("多维度用量走势与峰值下钻分析")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDemoTokens.text2)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 形态切换: 折线 vs 面积
                    FluentSegmentedPicker(
                        options: [
                            ("折线", AnalyticsChartDisplayType.line),
                            ("面积", AnalyticsChartDisplayType.area)
                        ],
                        selection: $displayType
                    )

                    // 维度选择器
                    FluentSegmentedPicker(
                        options: AnalyticsChartSeriesMode.allCases.map { ($0.displayName, $0) },
                        selection: $mode
                    )
                }

                // 图例条
                legendStrip

                // Swift Charts 画布
                if chartPoints.isEmpty {
                    emptyChartPlaceholder
                } else {
                    chartView
                        .frame(height: 220)
                }

                // 悬停数据探针 / 底部均线概览
                bottomSummaryStrip
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 图例条

    private var legendStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(activeSeriesMeta) { meta in
                    HStack(spacing: 5) {
                        // 有品牌素材才换徽章; token 类型 / 未知系列保留原色点。
                        if let asset = seriesAsset(for: meta.key) {
                            AgentBrandBadge(asset: asset, seriesHex: meta.colorHex, size: 13, followsTheme: false)
                        } else {
                            Circle()
                                .fill(Color(hex: meta.colorHex))
                                .frame(width: 7, height: 7)
                        }
                        Text(meta.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Swift Charts 主图

    private var chartView: some View {
        Chart {
            ForEach(chartPoints) { item in
                if displayType == .area {
                    AreaMark(
                        x: .value("Time", item.date),
                        y: .value(yAxisTitle, item.value),
                        series: .value("Series", item.seriesName)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [item.seriesColor.opacity(0.35), item.seriesColor.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                }

                LineMark(
                    x: .value("Time", item.date),
                    y: .value(yAxisTitle, item.value),
                    series: .value("Series", item.seriesName)
                )
                .foregroundStyle(item.seriesColor)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.catmullRom)

                if points.count <= 14 {
                    PointMark(
                        x: .value("Time", item.date),
                        y: .value(yAxisTitle, item.value)
                    )
                    .foregroundStyle(item.seriesColor)
                    .symbolSize(18)
                }
            }

            if let selected = selectedPoint {
                RuleMark(x: .value("Time", selected.label))
                    .foregroundStyle(SettingsDemoTokens.separator.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXSelection(value: $selectedLabel)
        .chartXAxis {
            AxisMarks(values: xAxisTicks.map(\.label)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(SettingsDemoTokens.separator.opacity(0.6))
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        if label == peakTickLabel {
                            Text("🔥 \(label)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(peakHighlightColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(peakHighlightColor.opacity(0.16))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(peakHighlightColor.opacity(0.42), lineWidth: 1)
                                )
                                .fixedSize()
                        } else {
                            Text(label)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text3)
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(SettingsDemoTokens.separator.opacity(0.6))
                if let str = yAxisValue(from: value) {
                    AxisValueLabel(str)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
        }
    }

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 26))
                .foregroundStyle(SettingsDemoTokens.text3)
            Text("当前时间跨度暂无活跃用量点")
                .font(.system(size: 12))
                .foregroundStyle(SettingsDemoTokens.text3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
        .background(
            SettingsDemoTokens.bg.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    // MARK: - 底部探针 / 均线条

    private var bottomSummaryStrip: some View {
        HStack(spacing: 12) {
            if let selected = selectedPoint {
                HStack(spacing: 8) {
                    Text("📍 \(selected.label)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.accent)

                    if mode == .cost {
                        Text(String(format: "$%.4f", selected.costUsd))
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.ok)
                    } else {
                        Text("\(PanelFormat.tokenCount(selected.totalTokens)) Tokens")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text)
                    }

                    // 展示当前模式下的细分数据泡
                    selectedBreakdownSummary(selected)
                }
            } else {
                Text(parseMarkdownSnippet(peakSummary))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)

                Spacer()

                Text(parseMarkdownSnippet(avgSummary))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsDemoTokens.bg.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
    }

    @ViewBuilder
    private func selectedBreakdownSummary(_ point: AnalyticsTimelinePoint) -> some View {
        HStack(spacing: 8) {
            switch mode {
            case .byAgent:
                ForEach(availableAgents.prefix(3)) { agent in
                    if let val = point.seriesValues[agent.agentID], val > 0 {
                        Text("\(agent.name): \(PanelFormat.tokenCount(val))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(hex: agent.colorHex))
                    }
                }
            case .byModel:
                ForEach(availableModels.prefix(3)) { model in
                    if let val = point.seriesValues["model_" + model.canonicalKey], val > 0 {
                        Text("\(model.displayName): \(PanelFormat.tokenCount(val))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(hex: model.colorHex))
                    }
                }
            case .byTokenType:
                if let input = point.seriesValues["type_input"], input > 0 {
                    Text("输入: \(PanelFormat.tokenCount(input))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: "4C9CFF"))
                }
                if let output = point.seriesValues["type_output"], output > 0 {
                    Text("输出: \(PanelFormat.tokenCount(output))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: "A855F7"))
                }
                if let cache = point.seriesValues["type_cache"], cache > 0 {
                    Text("缓存: \(PanelFormat.tokenCount(cache))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(hex: "10B981"))
                }
            case .cost:
                EmptyView()
            }
        }
    }

    // MARK: - 数据转换与元数据

    private var selectedPoint: AnalyticsTimelinePoint? {
        guard let label = selectedLabel else { return nil }
        return points.first { $0.label == label }
    }

    private var xAxisTicks: [AnalyticsTimelineAxisTick] {
        WorkbenchAnalytics.timelineAxisTicks(for: points)
    }

    private var peakTickLabel: String? {
        xAxisTicks.first(where: \.isPeak)?.label
    }

    private var peakHighlightColor: Color {
        Color(hex: WorkbenchAnalytics.peakDominantColorHex(points: points, series: activeSeriesMeta))
    }

    private var yAxisTitle: String {
        mode == .cost ? "费用 ($)" : "Tokens"
    }

    private func yAxisValue(from axisValue: AxisValue) -> String? {
        if mode == .cost {
            guard let val = axisValue.as(Double.self) else { return nil }
            return String(format: "$%.2f", val)
        } else {
            guard let val = axisValue.as(Double.self) else { return nil }
            let intVal = Int(val)
            if intVal >= 1_000_000 {
                return String(format: "%.1fM", Double(intVal) / 1_000_000.0)
            } else if intVal >= 1_000 {
                return String(format: "%.0fK", Double(intVal) / 1_000.0)
            } else {
                return "\(intVal)"
            }
        }
    }

    /// 图例键 → 品牌素材: byModel 的键带 model_ 前缀, byAgent 直接用 agentID。
    private func seriesAsset(for key: String) -> AgentBrandAsset? {
        if key.hasPrefix("model_") {
            return AgentBrandPalette.asset(forModelKey: String(key.dropFirst(6)))
        }
        return AgentBrandPalette.asset(forAgent: key)
    }

    private var activeSeriesMeta: [AnalyticsChartSeriesMeta] {
        switch mode {
        case .byAgent:
            return availableAgents.map {
                AnalyticsChartSeriesMeta(key: $0.agentID, name: $0.name, colorHex: $0.colorHex)
            }
        case .byModel:
            return availableModels.prefix(5).map {
                AnalyticsChartSeriesMeta(key: "model_" + $0.canonicalKey, name: $0.displayName, colorHex: $0.colorHex)
            }
        case .byTokenType:
            return [
                AnalyticsChartSeriesMeta(key: "type_input", name: "输入 Prompt", colorHex: "4C9CFF"),
                AnalyticsChartSeriesMeta(key: "type_output", name: "输出 Output", colorHex: "A855F7"),
                AnalyticsChartSeriesMeta(key: "type_cache", name: "缓存命中 Read", colorHex: "10B981")
            ]
        case .cost:
            return [
                AnalyticsChartSeriesMeta(key: "cost", name: "折算总费用 ($)", colorHex: "10B981")
            ]
        }
    }

    private var chartPoints: [ChartDataPoint] {
        var result: [ChartDataPoint] = []
        for p in points {
            switch mode {
            case .byAgent:
                for agent in availableAgents {
                    let val = Double(p.seriesValues[agent.agentID] ?? 0)
                    result.append(ChartDataPoint(
                        date: p.label,
                        seriesKey: agent.agentID,
                        seriesName: agent.name,
                        seriesColor: Color(hex: agent.colorHex),
                        value: val
                    ))
                }
            case .byModel:
                for m in availableModels.prefix(5) {
                    let key = "model_" + m.canonicalKey
                    let val = Double(p.seriesValues[key] ?? 0)
                    result.append(ChartDataPoint(
                        date: p.label,
                        seriesKey: key,
                        seriesName: m.displayName,
                        seriesColor: Color(hex: m.colorHex),
                        value: val
                    ))
                }
            case .byTokenType:
                let input = Double(p.seriesValues["type_input"] ?? 0)
                let output = Double(p.seriesValues["type_output"] ?? 0)
                let cache = Double(p.seriesValues["type_cache"] ?? 0)
                result.append(ChartDataPoint(date: p.label, seriesKey: "type_input", seriesName: "输入 Prompt", seriesColor: Color(hex: "4C9CFF"), value: input))
                result.append(ChartDataPoint(date: p.label, seriesKey: "type_output", seriesName: "输出 Output", seriesColor: Color(hex: "A855F7"), value: output))
                result.append(ChartDataPoint(date: p.label, seriesKey: "type_cache", seriesName: "缓存命中 Read", seriesColor: Color(hex: "10B981"), value: cache))
            case .cost:
                result.append(ChartDataPoint(
                    date: p.label,
                    seriesKey: "cost",
                    seriesName: "费用 ($)",
                    seriesColor: Color(hex: "10B981"),
                    value: p.costUsd
                ))
            }
        }
        return result
    }

    private func parseMarkdownSnippet(_ text: String) -> AttributedString {
        let normalized = text
            .replacingOccurrences(of: "<strong>", with: "**")
            .replacingOccurrences(of: "</strong>", with: "**")
            .replacingOccurrences(of: "<b>", with: "**")
            .replacingOccurrences(of: "</b>", with: "**")
        return (try? AttributedString(markdown: normalized)) ?? AttributedString(text)
    }
}
