import Charts
import Foundation
import BruceAppCore
import SwiftUI

/// Agent 用量卡: 卡片标题 + 14 日按 agent 堆叠柱状图 (从用量卡迁入) + 日期轴 + 图例;
/// 下方「逐小时」区块每个 agent 一行色点 + 名称 + 今日总量, 24 点折线;
/// 有模型或项目明细的行可整行点击展开, 明细 (100% 堆叠占比条 + 图例行) 直接排在折线下方.
/// 视觉与条件渲染以 panel-layout-v8.html 的逐小时卡为准.
struct HourlyLineCard: View {
    let viewModel: HourlyLineViewModel
    /// 14 日柱状图数据 (UsageHeroViewModel.days); 为空时整个顶部区块不渲染.
    let dailyDays: [UsageChartDay]
    /// 柱状图分段图例 (UsageHeroViewModel.legend).
    let dailyLegend: [UsageLegendItem]

    /// 已展开明细的 agent id 集合.
    @State private var expandedAgentIDs: Set<String>
    /// Nothing 点阵柱状图当前悬停的日期列 (触碰列顶才显示当日总量).
    @State private var hoveredDayDate: String?
    /// 已完成生长的列 (按日期); 逐列延迟插入驱动柱状图自下而上生长.
    @State private var grownColumns: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - viewModel: 逐小时卡 view model.
    ///   - dailyDays: 14 日柱状图数据, 默认空 (预览用).
    ///   - dailyLegend: 柱状图分段图例, 默认空 (预览用).
    ///   - initiallyExpandedAgentIDs: 初始展开的 agent id, 默认全收起 (预览用).
    init(
        viewModel: HourlyLineViewModel,
        dailyDays: [UsageChartDay] = [],
        dailyLegend: [UsageLegendItem] = [],
        initiallyExpandedAgentIDs: Set<String> = []
    ) {
        self.viewModel = viewModel
        self.dailyDays = dailyDays
        self.dailyLegend = dailyLegend
        _expandedAgentIDs = State(initialValue: initiallyExpandedAgentIDs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !dailyDays.isEmpty {
                dailySection
                rowDivider
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            titleRow
                .padding(.bottom, 2)

            ForEach(Array(viewModel.rows.enumerated()), id: \.element.agentID) { index, row in
                if index > 0 {
                    rowDivider
                }
                agentRow(row, index: index)
            }
        }
    }

    // MARK: - Nothing 主题判定

    /// Nothing 主题判定: 所有视觉差异必须收拢在该条件内,
    /// classic / liquidGlass 走原有代码路径, 渲染结果逐像素等价.
    private var isNothing: Bool {
        theme.interfaceStyle == .nothing
    }

    /// Nothing 单色文本/表面 token (定稿 CTX 数值, 按外观取值).
    private var nothingTokens: NothingTokens {
        NothingTokens(colorScheme: colorScheme)
    }

    // MARK: - 14 日堆叠柱状图 (自用量卡迁入)

    /// 卡片标题 + 柱状图 + 日期轴 + agent 图例.
    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTitle
            dailyChart
                // 与标题和高柱标注之间留足间距, 避免遮挡;
                // Nothing 列顶悬停标注向上 overlay 11pt, 需要更大上方留白.
                .padding(.top, isNothing ? 20 : 8)
            dailyDateAxis
                .padding(.top, 3)
            if !dailyLegend.isEmpty {
                dailyLegendRow
                    .padding(.top, 4)
            }
        }
    }

    /// 卡片标题: Nothing 用 .label 样式 (mono 10 + 字距 + secondary),
    /// 其余主题保持原样.
    @ViewBuilder
    private var cardTitle: some View {
        if isNothing {
            Text("Agent 用量")
                .font(NothingFont.mono(12))
                .tracking(0.9)
                .foregroundStyle(nothingTokens.secondary)
        } else {
            Text("Agent 用量")
                .font(.system(size: 12.5, weight: .semibold))
        }
    }

    /// 区块小标题: Nothing 用 .label 样式 (mono 10 + 字距 + secondary),
    /// 其余主题保持 10pt 半粗 + 字距.
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(isNothing ? NothingFont.mono(10) : .system(size: 10, weight: .semibold))
            .tracking(isNothing ? 0.9 : 0.4)
            .foregroundStyle(isNothing ? nothingTokens.secondary : Color.primary.opacity(0.55))
    }

    private var maxDayTotal: Int {
        max(dailyDays.map(\.total).max() ?? 0, 1)
    }

    @ViewBuilder
    private var dailyChart: some View {
        if isNothing {
            nothingDailyChart
        } else {
            dailyChartClassic
        }
    }

    private var dailyChartClassic: some View {
        Chart {
            ForEach(dailyDays, id: \.date) { day in
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
        // 面板 hosting view 常驻 (orderOut 不销毁视图层级), 日期轴每天右移一列;
        // 裸 .task 只在首次出现跑一次, 新日期永远进不了 grownColumns,
        // 柱体会停在 0 而标注照常显示 ("有数字无柱状"). 按 日期轴 为 id,
        // 轴变化时重跑: 已生长列的 insert 是 no-op, 只有新列补播生长.
        .task(id: dailyDays.map(\.date)) {
            await growColumns()
        }
    }

    // MARK: Nothing 点阵柱状图

    /// Nothing 点阵柱状图: 每天 3 列 x 8 行 = 24 格 6pt 方格 (圆角 0),
    /// 格间 2pt; 列均分整行宽, 不再用固定列间距 (固定间距要么留右缘空白,
    /// 要么总宽超出卡片内容宽撑爆面板导致左右裁切);
    /// 自下而上按当日总量比例填充 (格子数 = round(v/maxV*24), 至少 1);
    /// 填充格按 agent 绿阶分段堆叠, 段色 = PanelAgentColor.nothingRampHex,
    /// 与下方图例色块一一对应 (F3 定稿).
    /// 列均分整行宽 (每列 flexible slot 居中 22pt 点阵), 左右缘与卡片内容对齐,
    /// 不留右缘空白.
    private var nothingDailyChart: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(dailyDays.enumerated()), id: \.element.date) { _, day in
                nothingDayColumn(day)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 单日点阵列: 8 行分段网格 (高 8*6 + 7*2 = 62pt).
    /// 总量标注以 overlay 挂在网格上方 (不参与布局): fixedSize 文本若作为
    /// VStack 子视图会把每列撑到标注宽度, 进而撑宽整个面板导致裁切;
    /// overlay + offset 只影响绘制. 常态隐藏, 悬停该列才显示 (T2 触碰定稿).
    private func nothingDayColumn(_ day: UsageChartDay) -> some View {
        VStack(spacing: 2) {
            nothingDotGrid(day)
                .overlay(alignment: .top) {
                    Text(day.totalText)
                        .font(NothingFont.mono(7))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(nothingTokens.secondary)
                        .opacity(hoveredDayDate == day.date ? 1 : 0)
                        .offset(y: -11)
                }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                hoveredDayDate = day.date
            } else if hoveredDayDate == day.date {
                hoveredDayDate = nil
            }
        }
    }

    /// 3 列 x 8 行点阵网格, 自下而上填充: 网格序号 (自上而下) 落在
    /// `24 - filled` 之后的格子为填充格, 格色来自 nothingCellSlots 的分段落槽.
    private func nothingDotGrid(_ day: UsageChartDay) -> some View {
        let filled = nothingFilledCells(day.total)
        let cells = nothingCellSlots(day: day, filled: filled)
        return VStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { column in
                        let cellIndex = row * 3 + column
                        Rectangle()
                            .fill(cells[cellIndex] ?? nothingTokens.raised)
                            .frame(width: 6, height: 6)
                    }
                }
            }
        }
    }

    /// 24 格 (自上而下编号) 的分段落槽: 前 `24 - filled` 格为空 (nil),
    /// 之后按 segments 顺序自下而上堆叠, 每个非零段保底 1 格, 末段吃掉取整余量;
    /// 段色 = nothingRampHex 绿阶档, 与图例色块同源.
    /// 无分段数据或格子数少于段数时, 退回 accent 单色填充 (零量日 1 格, 沿用定稿行为).
    private func nothingCellSlots(day: UsageChartDay, filled: Int) -> [Color?] {
        let segments = day.segments.filter { $0.value > 0 }
        guard !segments.isEmpty, filled >= segments.count else {
            return [Color?](repeating: nil, count: 24 - filled)
                + [Color?](repeating: nothingTokens.accent, count: filled)
        }
        let dark = colorScheme == .dark
        var slots = [Color?](repeating: nil, count: 24)
        var index = 24 - filled
        for (offset, segment) in segments.enumerated() {
            let count: Int
            if offset == segments.count - 1 {
                // 末段吃掉剩余格, 保证总填充数恰为 filled.
                count = max(0, 24 - index)
            } else {
                count = max(1, Int((Double(segment.value) / Double(day.total) * Double(filled)).rounded()))
            }
            let color = Color(hex: PanelAgentColor.nothingRampHex(
                agentID: segment.agentID,
                darkMode: dark
            ))
            for _ in 0..<count where index < 24 {
                slots[index] = color
                index += 1
            }
        }
        return slots
    }

    /// 填充格数: round(v/maxV*24), 至少 1 (零量日也保留 1 格, 与定稿一致).
    private func nothingFilledCells(_ total: Int) -> Int {
        max(1, Int((Double(total) / Double(maxDayTotal) * 24).rounded()))
    }

    private func dayTotalLabel(_ day: UsageChartDay) -> some View {
        Text(day.totalText)
            .font(.system(size: 7.5))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    /// 逐列延迟 0.03 秒把列值从 0 推到真实值, 形成自下而上的生长动画;
    /// Reduce Motion 时直接全部就位. 幂等: 已生长的列直接跳过 (含 sleep),
    /// 因此日期轴变化触发重跑时只补播缺失列, 旧列不会重播动画.
    private func growColumns() async {
        if reduceMotion {
            grownColumns = Set(dailyDays.map(\.date))
            return
        }
        for day in dailyDays where !grownColumns.contains(day.date) {
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else {
                return
            }
            withAnimation(.easeOut(duration: 0.5)) {
                _ = grownColumns.insert(day.date)
            }
        }
    }

    /// 日期轴: 左 14 天前, 中 7 天前, 右今天.
    /// Nothing 用 mono 9 + disabled (定稿 .axis).
    private var dailyDateAxis: some View {
        HStack {
            Text("14 天前")
            Spacer()
            Text("7 天前")
            Spacer()
            Text("今天")
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
        .foregroundStyle(isNothing ? nothingTokens.disabled : Color.primary.opacity(0.55))
    }

    /// agent 图例: 色块 + 名称, 描述柱状图分段颜色.
    /// Nothing 不用品牌色, 改图案区分 (8pt swatch), 文本 mono 9 + secondary.
    private var dailyLegendRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(dailyLegend.enumerated()), id: \.element.agentID) { index, item in
                HStack(spacing: 4) {
                    if isNothing {
                        // 图例色块 = 分段点阵的绿阶档色, 与柱状图分段一一对应 (F3 定稿);
                        // 不再用图案 swatch (旧版单色柱与 per-agent 图例对不上).
                        Rectangle()
                            .fill(Color(hex: PanelAgentColor.nothingRampHex(
                                agentID: item.agentID,
                                darkMode: colorScheme == .dark
                            )))
                            .frame(width: 8, height: 8)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hex: item.color.hex))
                            .frame(width: 7, height: 7)
                    }
                    Text(item.name)
                }
            }
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9.5))
        .foregroundStyle(isNothing ? nothingTokens.secondary : Color.primary.opacity(0.75))
    }

    // MARK: - 逐小时小标题

    /// 区块小标题样式的「逐小时」行, 右侧保留时段范围说明.
    /// Nothing 右侧说明用 .meta 样式 (mono 9 + 字距 + disabled).
    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline) {
            sectionTitle("逐小时")
            Spacer()
            if isNothing {
                Text("0 – 23 时")
                    .font(NothingFont.mono(9))
                    .tracking(0.54)
                    .foregroundStyle(nothingTokens.disabled)
            } else {
                Text("0 – 23 时")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - agent 行

    /// 行间 1pt 分隔线, 对应 mockup `border-top: 1px solid rgba(0,0,0,.05)`;
    /// 深色下改为低透明白. Nothing 下用 border token 纯色.
    @ViewBuilder
    private var rowDivider: some View {
        if isNothing {
            nothingTokens.border
                .frame(height: 1)
        } else {
            Color.adaptive(light: Color.black.opacity(0.05), dark: Color.white.opacity(0.10))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func agentRow(_ row: HourlyAgentRow, index: Int) -> some View {
        if row.isExpandable {
            // 可展开行整行可点, 保持按钮语义供辅助功能识别.
            Button {
                toggle(row.agentID)
            } label: {
                agentRowBody(row, index: index)
            }
            .buttonStyle(.plain)
        } else {
            agentRowBody(row, index: index)
        }
    }

    private func agentRowBody(_ row: HourlyAgentRow, index: Int) -> some View {
        let expanded = expandedAgentIDs.contains(row.agentID)
        return VStack(alignment: .leading, spacing: 4) {
            headRow(row, expanded: expanded, index: index)
            hourlyChart(row, index: index)
            if expanded {
                detailSection(row)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    /// 行首: Nothing 用绿阶色点 (7pt) 区分 agent, 与柱状图分段/图例同源;
    /// 其余主题保持品牌色块.
    private func headRow(_ row: HourlyAgentRow, expanded: Bool, index: Int) -> some View {
        HStack(spacing: 7) {
            if isNothing {
                Rectangle()
                    .fill(Color(hex: PanelAgentColor.nothingRampHex(
                        agentID: row.agentID,
                        darkMode: colorScheme == .dark
                    )))
                    .frame(width: 7, height: 7)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(agentColor(row))
                    .frame(width: 7, height: 7)
            }
            if isNothing {
                Text(row.name)
                    .font(NothingFont.ui(12, weight: .medium))
                    .foregroundStyle(nothingTokens.primary)
            } else {
                Text(row.name)
                    .font(.system(size: 11, weight: .semibold))
            }
            if row.isExpandable {
                if isNothing {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(nothingTokens.disabled)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            Spacer(minLength: 7)
            if isNothing {
                Text(row.todayTotalText)
                    .font(NothingFont.mono(12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(nothingTokens.primary)
            } else {
                Text(row.todayTotalText)
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
            }
        }
    }

    /// 24 点折线 (0-23 时): agent 色 1.5pt 线 + 淡渐变面积;
    /// Nothing 用 nothingRampHex 绿阶色描线, 与行首色点/柱状图分段同一身份,
    /// 无面积渐变 (定稿 sparkline 仅描线).
    private func hourlyChart(_ row: HourlyAgentRow, index: Int) -> some View {
        let color = agentColor(row)
        let maxPoint = max(row.points.max() ?? 0, 1)
        return Chart(Array(row.points.enumerated()), id: \.offset) { point in
            if isNothing {
                LineMark(
                    x: .value("时", point.offset),
                    y: .value("量", point.element)
                )
                .foregroundStyle(Color(hex: PanelAgentColor.nothingRampHex(
                    agentID: row.agentID,
                    darkMode: colorScheme == .dark
                )))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            } else {
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
                distributionGroup(
                    title: "模型占比",
                    bars: row.models,
                    colorAt: { Color(hex: row.color.distributionHex(at: $0)) }
                )
            }
            if !row.projects.isEmpty {
                distributionGroup(
                    title: "项目分布",
                    bars: row.projects,
                    colorAt: { Color(hex: Self.projectBarShades[min($0, Self.projectBarShades.count - 1)]) }
                )
                .padding(.top, row.models.isEmpty ? 0 : 7)
            }
        }
        .padding(.leading, 14)
        .padding(.top, 3)
    }

    /// 占比组: 标题 + 通宽 100% 堆叠条 + 图例行 (色点 + 名称 + 百分比 + 数值).
    /// 分段用同色系阶梯色, 而非同一色只降透明度, 避免明细进度条视觉重复.
    /// Nothing 下组标题用 .dist-head .t 样式 (mono 9 + 字距 + secondary).
    private func distributionGroup(
        title: String,
        bars: [DistributionBar],
        colorAt: @escaping (Int) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(isNothing ? NothingFont.mono(9) : .system(size: 9, weight: .semibold))
                .tracking(isNothing ? 0.8 : 0.3)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            stackedShareBar(bars, colorAt: colorAt)
                .padding(.bottom, 3)
            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                shareLegendRow(bar, index: index, color: colorAt(index))
            }
        }
    }

    /// 100% 堆叠占比条: 分段按份额拼接, 各段独立色阶, 份额不足 100% 时余量露出轨道色.
    /// Nothing 下段间 2pt, 分段用同一套图案 (index 循环), 无轨道底色 (与定稿 .dbar 一致).
    private func stackedShareBar(
        _ bars: [DistributionBar],
        colorAt: @escaping (Int) -> Color
    ) -> some View {
        GeometryReader { proxy in
            if isNothing {
                let gap: CGFloat = 2
                let available = proxy.size.width - gap * CGFloat(max(bars.count - 1, 0))
                HStack(spacing: gap) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                        NothingPatternView(pattern: .at(index), color: nothingTokens.display)
                            .frame(width: max(2, available * min(max(bar.share, 0), 1)), height: 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let available = proxy.size.width - CGFloat(max(bars.count - 1, 0))
                HStack(spacing: 1) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                        Rectangle()
                            .fill(colorAt(index))
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
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    /// 图例行: 色点 + 名称 + 右侧「百分比 · 数值」, 百分比为主数值.
    /// Nothing 色点改 6pt 图案 swatch, 文本 mono (定稿 .dkey).
    private func shareLegendRow(_ bar: DistributionBar, index: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            if isNothing {
                NothingPatternView(pattern: .at(index), color: nothingTokens.display)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 5, height: 5)
            }
            Text(bar.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 分两段 Text 保留字重/颜色差异; 避免 macOS 26 弃用的 Text + 拼接.
            HStack(spacing: 0) {
                if isNothing {
                    Text(Self.sharePercentText(bar.share))
                        .font(NothingFont.mono(9.5, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(nothingTokens.primary)
                    Text(" · \(bar.totalText)")
                        .font(NothingFont.mono(9.5))
                        .foregroundStyle(nothingTokens.disabled)
                } else {
                    Text(Self.sharePercentText(bar.share))
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                    Text(" · \(bar.totalText)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9.5))
        .foregroundStyle(isNothing ? nothingTokens.secondary : Color.primary.opacity(0.85))
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

    /// 项目分布同色系阶梯 (青→浅青), 与 agent 主色分离且段间可区分.
    private static let projectBarShades = [
        "#30b0c7",
        "#55c2d4",
        "#7ad4e1",
        "#9fe5ed",
    ]
}

// MARK: - Nothing 主题样式辅助

/// Nothing 主题文本/表面 token (定稿 CTX 数值).
/// 仅在 `theme.interfaceStyle == .nothing` 分支内消费.
private struct NothingTokens {
    let display: Color
    let primary: Color
    let secondary: Color
    let disabled: Color
    /// surface-raised: 点阵空格底色.
    let raised: Color
    /// 1px 分隔线 border.
    let border: Color
    /// 呼吸灯 accent (深绿 #4A9E5C / 浅橘 #D4A843), 与 Token 用量卡 nothingHeroAccent 同源.
    let accent: Color

    init(colorScheme: ColorScheme) {
        switch colorScheme {
        case .dark:
            display = Color(hex: "#FFFFFF")
            primary = Color(hex: "#E8E8E8")
            secondary = Color(hex: "#999999")
            disabled = Color(hex: "#666666")
            raised = Color(hex: "#1A1A1A")
            border = Color(hex: "#222222")
            accent = Color(hex: "#4A9E5C")
        default:
            display = Color(hex: "#000000")
            primary = Color(hex: "#1A1A1A")
            secondary = Color(hex: "#666666")
            disabled = Color(hex: "#999999")
            raised = Color(hex: "#F0F0F0")
            border = Color(hex: "#E8E8E8")
            accent = Color(hex: "#D4A843")
        }
    }
}

/// Nothing 主题 agent 区分图案: 实心 / 45° 斜纹 / 横纹 / 4pt 网点,
/// 按行序循环取用 (定稿 .p1-.p4), 前景一律 display 单色.
private enum NothingPattern: CaseIterable {
    case solid
    case diagonal
    case horizontal
    case dots

    /// 按序号循环取图案, 负数也安全.
    static func at(_ index: Int) -> Self {
        Self.allCases[((index % 4) + 4) % 4]
    }

    /// 折线透明度档位, 与图案序号一一对应 (定稿 OP).
    var lineOpacity: Double {
        switch self {
        case .solid: 1.0
        case .diagonal: 0.66
        case .horizontal: 0.45
        case .dots: 0.80
        }
    }
}

/// Nothing 图案块: Canvas 按 4pt 周期绘制, 尺寸由调用方 frame 决定
/// (图例 swatch 8pt / 行首点 7pt / 占比图例点 6pt / 堆叠条分段).
private struct NothingPatternView: View {
    let pattern: NothingPattern
    let color: Color

    var body: some View {
        Canvas { context, size in
            switch pattern {
            case .solid:
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(color)
                )
            case .diagonal:
                // 平移到中心后旋转 45°, 再铺横条纹覆盖全对角范围.
                var rotated = context
                rotated.translateBy(x: size.width / 2, y: size.height / 2)
                rotated.rotate(by: .degrees(45))
                let reach = CGFloat(sqrt(size.width * size.width + size.height * size.height)) / 2 + 2
                Self.drawStripes(
                    in: &rotated,
                    x: -reach,
                    width: reach * 2,
                    yStart: -reach,
                    yEnd: reach,
                    color: color
                )
            case .horizontal:
                var copied = context
                Self.drawStripes(
                    in: &copied,
                    x: 0,
                    width: size.width,
                    yStart: 0,
                    yEnd: size.height,
                    color: color
                )
            case .dots:
                drawDots(context, size: size)
            }
        }
    }

    /// 2pt 条纹 + 2pt 空隙, 沿 y 轴按 4pt 周期铺满 [yStart, yEnd) (定稿 repeating-linear-gradient).
    private static func drawStripes(
        in context: inout GraphicsContext,
        x: CGFloat,
        width: CGFloat,
        yStart: CGFloat,
        yEnd: CGFloat,
        color: Color
    ) {
        var y = yStart
        while y < yEnd {
            context.fill(
                Path(CGRect(x: x, y: y, width: width, height: 2)),
                with: .color(color)
            )
            y += 4
        }
    }

    /// 4pt 网格上 1.6pt 半径圆点 (定稿 radial-gradient + background-size 4px).
    private func drawDots(_ context: GraphicsContext, size: CGSize) {
        let radius: CGFloat = 1.6
        var y: CGFloat = 0
        while y < size.height {
            var x: CGFloat = 0
            while x < size.width {
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: x + 2 - radius,
                        y: y + 2 - radius,
                        width: radius * 2,
                        height: radius * 2
                    )),
                    with: .color(color)
                )
                x += 4
            }
            y += 4
        }
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
                    DistributionBar(name: "Bruce", total: 56_800, share: 0.58),
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
                    DistributionBar(name: "Bruce", total: 33_300, share: 0.64),
                    DistributionBar(name: "其他", total: 18_700, share: 0.36),
                ]
            ),
            HourlyAgentRow(
                agentID: "claude-code",
                name: "Claude Code",
                color: .coral,
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
// 这里用 PreviewProvider, Xcode 画布同样可直接预览;
// canImport 守住无 Xcode 工具链, 与 UsageHeroCard 的处理一致.
#if DEBUG && canImport(PreviewsMacros)
struct HourlyLineCard_Previews: PreviewProvider {
    /// 14 日柱状图 fixture: 两个 agent 分段, 数值有起伏.
    private static var dailyPreviewDays: [UsageChartDay] {
        let kimi = [12, 18, 9, 22, 30, 26, 15, 33, 28, 20, 36, 24, 31, 27]
        let codex = [4, 6, 3, 8, 10, 7, 5, 11, 9, 6, 12, 8, 10, 9]
        return (0..<14).map { index in
            let k = kimi[index] * 1000
            let c = codex[index] * 1000
            return UsageChartDay(
                date: String(format: "2026-07-%02d", index + 17),
                total: k + c,
                segments: [
                    UsageChartSegment(agentID: "kimi-code-cli", color: .blue, value: k),
                    UsageChartSegment(agentID: "codex", color: .purple, value: c),
                ]
            )
        }
    }

    static var previews: some View {
        HourlyLineCard(
            viewModel: .hourlyLinePreviewFixture,
            dailyDays: dailyPreviewDays,
            dailyLegend: [
                UsageLegendItem(agentID: "kimi-code-cli", name: "Kimi Code", color: .blue),
                UsageLegendItem(agentID: "codex", name: "Codex", color: .purple),
            ],
            initiallyExpandedAgentIDs: ["kimi-code-cli"]
        )
        .padding(12)
        .frame(width: 320)
        .background(Color(white: 0.93))
    }
}
#endif
