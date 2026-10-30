import Charts
import SwiftUI
import BruceAppCore

/// 时序趋势折线/面积分析卡片 (基于 Swift Charts 原生渲染)
struct TimelineChartCard: View {
    let points: [AnalyticsTimelinePoint]
    let granularity: AnalyticsTimelineGranularity
    let peakSummary: String
    let avgSummary: String
    let availableAgents: [AnalyticsAgentCardItem]
    let availableModels: [CanonicalModelSummary]

    @State private var mode: AnalyticsChartSeriesMode = .byAgent
    @State private var displayType: AnalyticsChartDisplayType = .line
    @State private var selectedLabel: String? = nil

    // C163 / C165: 视口状态只存倍率与起点, 计算见 AnalyticsTimelineViewport (Windows timelineViewport 同口径)
    @State private var zoomLevel: Double = 1.0
    @State private var startIndex: Int = 0
    /// 拖拽 / 捏合开始时的视口: 手势给的是累计位移 / 累计倍率, 必须相对起点计算 (C165).
    @State private var dragBase: AnalyticsTimelineViewport? = nil
    @State private var pinchBase: AnalyticsTimelineViewport? = nil
    @State private var chartWidth: CGFloat = 0
    @State private var scrollPanRemainder: CGFloat = 0
    @State private var isHoveringChart: Bool = false
    @State private var scrollMonitor: Any? = nil

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

                    // 缩放控制条 (C163)
                    zoomControls

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

                    if viewport.isZoomedOrPanned {
                        minimapIndicator
                    }
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
        let ticks = xAxisTicks
        let peakLabel = ticks.first(where: \.isPeak)?.label
        let peakColor = peakHighlightColor
        return Chart {
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

                if visiblePoints.count <= 14 {
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
        .chartXSelection(value: isDragging ? .constant(nil) : $selectedLabel)
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let base = dragBase ?? viewport
                    if dragBase == nil {
                        dragBase = base
                        selectedLabel = nil
                    }
                    apply(base.dragged(translation: value.translation.width, pointWidth: pointWidth))
                }
                .onEnded { _ in
                    dragBase = nil
                }
        )
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        resetViewport()
                    }
                }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = pinchBase ?? viewport
                    if pinchBase == nil {
                        pinchBase = base
                    }
                    apply(base.pinched(magnification: value.magnification))
                }
                .onEnded { _ in
                    pinchBase = nil
                }
        )
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { chartWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, width in chartWidth = width }
            }
        )
        .onHover { hovering in
            isHoveringChart = hovering
            if hovering {
                setupScrollMonitor()
            } else {
                tearDownScrollMonitor()
            }
        }
        .onDisappear {
            tearDownScrollMonitor()
        }
        // 换范围 (标签序列变化) 才复位视口; 同一范围的后台刷新保留缩放 (C165)
        .onChange(of: points.map(\.label)) { _, _ in
            resetViewport()
            // 滚轮监听捕获的是安装时的视图副本 (含 points), 数据换代后重装
            if scrollMonitor != nil {
                tearDownScrollMonitor()
                setupScrollMonitor()
            }
        }
        .chartXAxis {
            AxisMarks(values: ticks.map(\.label)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(SettingsDemoTokens.separator.opacity(0.6))
                if let label = value.as(String.self) {
                    AxisValueLabel {
                        if label == peakLabel {
                            Text("🔥 \(label)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(peakColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(peakColor.opacity(0.16))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .strokeBorder(peakColor.opacity(0.42), lineWidth: 1)
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
                let summaries = summaryTexts
                Text(parseMarkdownSnippet(summaries.peak))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)

                Spacer()

                Text(parseMarkdownSnippet(summaries.average))
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

    // MARK: - 视口与缩放计算 (C163 视口切片 / C165 纯值视口与锚定 LOD)

    private var viewport: AnalyticsTimelineViewport {
        AnalyticsTimelineViewport(count: points.count, zoom: zoomLevel, start: startIndex)
    }

    private func apply(_ next: AnalyticsTimelineViewport) {
        zoomLevel = next.zoom
        startIndex = next.start
    }

    private func resetViewport() {
        apply(AnalyticsTimelineViewport(count: points.count))
    }

    private var isDragging: Bool { dragBase != nil }

    /// 每个数据点在图上的宽度, 拖拽与水平滑动据此换算平移点数; 未测得宽度前按 500pt 估算.
    private var pointWidth: CGFloat {
        (chartWidth > 0 ? chartWidth : 500) / CGFloat(max(1, viewport.visibleCount))
    }

    private var visiblePoints: [AnalyticsTimelinePoint] {
        Array(points[viewport.visibleRange])
    }

    /// 当前维度的全局峰值: 费用维度按费用, 其余按 token (C165).
    private var peakIndex: Int? {
        WorkbenchAnalytics.timelinePeakIndex(in: points, metric: mode == .cost ? .cost : .tokens)
    }

    // MARK: - 数据转换与元数据

    private var selectedPoint: AnalyticsTimelinePoint? {
        guard let label = selectedLabel else { return nil }
        return visiblePoints.first { $0.label == label }
    }

    private var xAxisTicks: [AnalyticsTimelineAxisTick] {
        WorkbenchAnalytics.timelineAxisTicks(for: points, visible: viewport.visibleRange, peakIndex: peakIndex)
    }

    private var peakHighlightColor: Color {
        Color(hex: WorkbenchAnalytics.peakDominantColorHex(
            point: peakIndex.map { points[$0] },
            series: activeSeriesMeta
        ))
    }

    /// 未选点时的峰值 / 均值摘要: 费用维度换成费用口径 (C165), 其余沿用快照下发的 token 摘要.
    private var summaryTexts: (peak: String, average: String) {
        mode == .cost
            ? WorkbenchAnalytics.costSummaries(points: points, granularity: granularity)
            : (peakSummary, avgSummary)
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
        for p in visiblePoints {
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

    // MARK: - 缩放平移辅助组件与事件监听 (C163)

    private var zoomControls: some View {
        HStack(spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    apply(viewport.zoomed(to: (zoomLevel * 10).rounded() / 10 - 0.5))
                }
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(zoomLevel > 1.0 ? SettingsDemoTokens.text : SettingsDemoTokens.text3)
                    .background(SettingsDemoTokens.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel <= 1.0)
            .help("缩小 (亦可 ⌘ + 滚轮向下 / 双指捏合)")

            Text(String(format: "%.1fx", zoomLevel))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(zoomLevel > 1.0 ? SettingsDemoTokens.accent : SettingsDemoTokens.text2)
                .frame(minWidth: 30)

            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    apply(viewport.zoomed(to: (zoomLevel * 10).rounded() / 10 + 0.5))
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9.5, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(zoomLevel < 4.0 ? SettingsDemoTokens.text : SettingsDemoTokens.text3)
                    .background(SettingsDemoTokens.bg.opacity(0.6), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(zoomLevel >= 4.0)
            .help("放大 (亦可 ⌘ + 滚轮向上 / 双指张开)")

            if viewport.isZoomedOrPanned {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        resetViewport()
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 8.5, weight: .semibold))
                        Text("全景")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .foregroundStyle(SettingsDemoTokens.text)
                    .background(SettingsDemoTokens.separator.opacity(0.4), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("复位全景 (亦可双击图表区域)")
            }
        }
        .padding(2)
        .background(
            SettingsDemoTokens.bg.opacity(0.4),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
    }

    private var minimapIndicator: some View {
        GeometryReader { geo in
            let total = CGFloat(viewport.count)
            let visible = CGFloat(viewport.visibleCount)
            let start = CGFloat(viewport.start)
            let thumbWidth = max(24, (visible / max(1, total)) * geo.size.width)
            let maxTravel = max(0, geo.size.width - thumbWidth)
            let thumbX = total > visible ? (start / max(1, total - visible)) * maxTravel : 0

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(SettingsDemoTokens.separator.opacity(0.3))
                    .frame(height: 2)

                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(SettingsDemoTokens.accent.opacity(0.8))
                    .frame(width: thumbWidth, height: 2)
                    .offset(x: thumbX)
            }
        }
        .frame(height: 2)
        .padding(.horizontal, 2)
    }

    private func setupScrollMonitor() {
        guard scrollMonitor == nil else { return }
        // C165: 普通纵向滚动一律放行给设置页 ScrollView; ⌘ + 滚轮缩放, 放大后水平滑动平移.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard isHoveringChart else { return event }
            if event.modifierFlags.contains(.command) {
                // 按设备方向取值: 滚轮向上 (远离用户) 放大, 与「自然滚动」设置无关
                let raw = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
                // 触控板为像素级增量, 约 60pt 计一格; 鼠标滚轮按行计, 一行一格
                let notches = event.hasPreciseScrollingDeltas ? raw / 60 : raw
                if notches != 0 {
                    apply(viewport.zoomed(byWheelNotches: notches))
                }
                return nil
            }
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 10
            guard viewport.maxStart > 0, abs(dx) > abs(event.scrollingDeltaY) else { return event }
            // 累计位移按点宽换算, 不再每个事件固定移 1 点 (触控板一次滑动有几十个事件)
            scrollPanRemainder += dx
            let steps = Int((scrollPanRemainder / pointWidth).rounded(.towardZero))
            if steps != 0 {
                scrollPanRemainder -= CGFloat(steps) * pointWidth
                apply(viewport.panned(by: -steps))
            }
            return nil
        }
    }

    private func tearDownScrollMonitor() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
    }
}
