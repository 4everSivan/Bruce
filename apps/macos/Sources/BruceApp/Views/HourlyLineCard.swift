import Charts
import Foundation
import BruceAppCore
import BruceOnboardingCore
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
    /// 卡片收起态 (定稿方案 C 变体 2): 收起时只渲染标题行 + 迷你折线.
    var isCollapsed: Bool = false
    var onToggleCollapse: () -> Void = {}
    /// C212: 卡片内刷新入口 (Agent 用量模块).
    var onRefresh: () -> Void = {}
    /// C212: 刷新中禁用并旋转图标.
    var isRefreshing: Bool = false
    /// 14 日柱当前悬停的日期列 (经典 / 液态玻璃柱顶总量与 Nothing 点阵柱共用).
    @State private var hoveredDayDate: String?
    /// 面板可见性 (C044): 隐藏时不挂载刷新进度环.
    var panelVisible: Bool = true
    @Environment(\.motionSuppressed) private var motionSuppressed
    /// 展开态正文的自然高度 (C148); 折叠时容器按显式高度动画收到 0.
    @State private var expandedHeight: CGFloat = 0
    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// - Parameters:
    ///   - viewModel: 逐小时卡 view model.
    ///   - dailyDays: 14 日柱状图数据, 默认空 (预览用).
    ///   - dailyLegend: 柱状图分段图例, 默认空 (预览用).
    ///   - initiallyExpandedAgentIDs: 初始展开的 agent id; nil 表示按 C212 规则默认打开第一个可展开行.
    ///   - isCollapsed: 卡片收起态.
    ///   - onToggleCollapse: 标题行收放回调.
    ///   - onRefresh: 正文刷新回调.
    ///   - isRefreshing: 刷新中状态.
    ///   - panelVisible: 面板可见性, 用于刷新图标旋转门控.
    init(
        viewModel: HourlyLineViewModel,
        dailyDays: [UsageChartDay] = [],
        dailyLegend: [UsageLegendItem] = [],
        initiallyExpandedAgentIDs: Set<String>? = nil,
        isCollapsed: Bool = false,
        onToggleCollapse: @escaping () -> Void = {},
        onRefresh: @escaping () -> Void = {},
        isRefreshing: Bool = false,
        panelVisible: Bool = true
    ) {
        self.viewModel = viewModel
        self.dailyDays = dailyDays
        self.dailyLegend = dailyLegend
        self.isCollapsed = isCollapsed
        self.onToggleCollapse = onToggleCollapse
        self.onRefresh = onRefresh
        self.isRefreshing = isRefreshing
        self.panelVisible = panelVisible
        let initialExpansion = initiallyExpandedAgentIDs
            ?? Self.defaultExpandedAgentIDs(viewModel.rows, isCollapsed: isCollapsed)
        _expandedAgentIDs = State(initialValue: initialExpansion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleCardHeader(
                title: "Agent 用量",
                isCollapsed: isCollapsed,
                onToggle: onToggleCollapse,
                cardID: .hourly
            ) {
                EmptyView()
            } mini: {
                collapsedMini
            }
            // C148: 正文高度是显式可动画值, 由标题行按钮的同一条 withAnimation 驱动.
            ZStack(alignment: .top) {
                if !isCollapsed {
                    expandedContent
                        .readingNaturalHeight(into: $expandedHeight)
                        // C148: 正文淡出比外框收拢更快收尾, 避免半透明文字在收拢过程中拖成残影.
                        .transition(.opacity.animation(motionSuppressed ? nil : .easeOut(duration: 0.22)))
                }
            }
            .frame(
                height: isCollapsed
                    ? DashboardSwapHeight.collapsed
                    : DashboardSwapHeight.target(measured: expandedHeight),
                alignment: .top
            )
            .clipped()
        }
        .clipped()
        // C212: 每次从收起态展开都重置为第一个有明细的 agent.
        .onChange(of: isCollapsed) { _, collapsed in
            guard !collapsed else { return }
            expandedAgentIDs = Self.defaultExpandedAgentIDs(
                viewModel.rows,
                isCollapsed: false
            )
        }
    }

    /// C212: 默认展开集合; 无可展开行时为空.
    private static func defaultExpandedAgentIDs(
        _ rows: [HourlyAgentRow],
        isCollapsed: Bool
    ) -> Set<String> {
        guard !isCollapsed, let agentID = rows.first(where: \.isExpandable)?.agentID else {
            return []
        }
        return [agentID]
    }

    /// 展开态内容 (标题行由 CollapsibleCardHeader 承担, 全周期唯一不跳动).
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasHistory {
                dailySection
                rowDivider
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }

            if viewModel.rows.isEmpty {
                emptyTodayState
            } else {
                todayTitleRow
                    .padding(.bottom, 2)

                ForEach(Array(viewModel.rows.enumerated()), id: \.element.agentID) { index, row in
                    if index > 0 {
                        rowDivider
                    }
                    agentRow(row, index: index)
                }
            }
        }
    }

    // MARK: - 收起态迷你折线

    /// 收起态: 24 点全 agent 合计迷你折线 (1.5pt 描线 + 淡面积, subdued 色)
    /// + 右侧峰值文案; Nothing 下无面积渐变, 峰值用 Space Mono.
    /// C212: 今日无任何 agent 用量时只显示「暂无用量」.
    @ViewBuilder
    private var collapsedMini: some View {
        if viewModel.isEmptyToday {
            Text("暂无用量")
                .font(isNothing ? NothingFont.mono(9) : .system(size: 9.5))
                .foregroundStyle(isNothing ? nothingTokens.disabled : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.opacity)
        } else {
            let points = viewModel.collapsedPoints
            let maxPoint = max(points.max() ?? 0, 1)
            let lineColor = isNothing
                ? nothingTokens.secondary
                : Color.primary.opacity(0.5)
            HStack(spacing: 15) {
                Chart(Array(points.enumerated()), id: \.offset) { point in
                    LineMark(
                        x: .value("时", point.offset),
                        y: .value("量", point.element)
                    )
                    .foregroundStyle(lineColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    if !isNothing {
                        AreaMark(
                            x: .value("时", point.offset),
                            y: .value("量", point.element)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [lineColor.opacity(0.18), lineColor.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
                .chartYScale(domain: 0...(Double(maxPoint) * 1.1))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                // 阻断继承父级的折叠动画事务，避免迷你折线在进入时执行线条形变或插值拉扯，保持静态保真
                .transaction { $0.animation = nil }
                Text(viewModel.collapsedPeakText)
                    .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(isNothing
                        ? nothingTokens.disabled
                        : Color.primary.opacity(0.5))
                    .fixedSize()
            }
            .transition(.opacity)
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

    /// 柱状图 + 日期轴 + agent 图例; 卡片标题已迁入 CollapsibleCardHeader.
    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                            y: .value("Tokens", segment.value)
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
        // 固定 Y 域, 各列按同一比例尺呈现.
        // C218: 顶部留 20% 余量给最高柱的 .annotation(.top) 总量标注, 避免被
        // chart frame 裁掉上半截; 最高柱约 83% 高.
        .chartYScale(domain: 0...(Double(maxDayTotal) * 1.20))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 68)
        // C222: 总量标注默认隐藏, 悬停该日期列才显示 (与 Nothing 点阵柱同语义).
        // chartOverlay 用 plotFrame + value(atX:) 精确映射日期, 不受图表内边距影响.
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame else {
                                hoveredDayDate = nil
                                return
                            }
                            let frame = geometry[plotFrame]
                            guard frame.contains(location) else {
                                hoveredDayDate = nil
                                return
                            }
                            hoveredDayDate = proxy.value(atX: location.x - frame.minX, as: String.self)
                        case .ended:
                            hoveredDayDate = nil
                        }
                    }
            }
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
            // C222: 默认隐藏, 悬停该日期列才显示; 标注仍参与布局, 显隐不改变柱高.
            .opacity(hoveredDayDate == day.date ? 1 : 0)
            .animation(motionSuppressed ? nil : .easeOut(duration: 0.12), value: hoveredDayDate)
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
                    // Agent 品牌徽章 (C161): Nothing 走绿阶单色, 其余真彩档.
                    AgentBrandBadge(
                        asset: AgentBrandPalette.asset(forAgent: item.agentID),
                        seriesHex: item.color.hex,
                        size: isNothing ? 9 : 12,
                        nothingHex: PanelAgentColor.nothingRampHex(
                            agentID: item.agentID,
                            darkMode: colorScheme == .dark
                        ),
                        fallbackMonogram: String(item.name.prefix(1)).uppercased(),
                        // C218: 图例 12pt 也保留品牌真彩/位图与系列色环, 不退回系列色瓷砖.
                        usesBrandChrome: !isNothing
                    )
                    Text(item.name)
                }
            }
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9.5))
        .foregroundStyle(isNothing ? nothingTokens.secondary : Color.primary.opacity(0.75))
        // C217: 卡片内容由 .clipped() 裁在内容左缘, 徽章 seriesRing 外扩 1.5pt,
        // 首项贴边会缺左边; 留 3pt 让色环与 tile 左圆角完整.
        .padding(.leading, 3)
    }

    // MARK: - 今日小标题与卡内刷新

    /// 有数据时的「今日」小标题行, 右侧为仅图标刷新按钮 (C212).
    private var todayTitleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            sectionTitle("今日")
            Spacer(minLength: 8)
            refreshIconButton
        }
    }

    /// 刷新进度是否可挂载: 面板隐藏时退回静态图标, 避免隐藏窗口持续逐帧布局.
    private var showsRefreshProgress: Bool {
        isRefreshing
            && DashboardPanelAnimationPolicy.allowsRefreshProgress(panelVisible: panelVisible)
    }

    /// 与订阅卡 ProviderRefreshButton 完全同构: 14×14, 无边框/底色, 10pt 半粗
    /// arrow.clockwise, secondary 色; 刷新中显示小型进度环并禁用.
    private var refreshIconButton: some View {
        Button(action: onRefresh) {
            Group {
                if showsRefreshProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .opacity(isRefreshing && !showsRefreshProgress ? 0.45 : 1)
        .disabled(isRefreshing)
        .help("刷新 Agent 用量")
        .accessibilityLabel("刷新 Agent 用量")
    }

    /// 近 14 日是否存在任何非零用量; 无历史时连柱状图一起隐藏 (C212).
    private var hasHistory: Bool {
        dailyDays.contains { $0.total > 0 }
    }

    /// 今日无任何 agent 用量时的空态: 有历史则保留柱状图, 只把今日区置空;
    /// 无历史不渲染柱状图. 刷新按钮在空态图标/文案下方, 与「今日」行互斥 (C212).
    private var emptyTodayState: some View {
        let title = hasHistory ? "今天还没有 Agent 用量" : "暂无 Agent 用量"
        return VStack(spacing: 7) {
            VStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isNothing ? nothingTokens.secondary : Color.secondary)
                    .frame(width: 36, height: 36)
                    .overlay {
                        RoundedRectangle(cornerRadius: isNothing ? 2 : 9, style: .continuous)
                            .strokeBorder(
                                isNothing
                                    ? Color.adaptive(light: Color(hex: "#CCCCCC"), dark: Color(hex: "#333333"))
                                    : Color.primary.opacity(0.18),
                                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                            )
                    }

                Text(title)
                    .font(isNothing
                        ? NothingFont.ui(11.5, weight: .semibold)
                        : .system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isNothing ? nothingTokens.primary : Color.primary)

                Text("检测到 Agent 活动后，这里会显示今日逐小时折线与模型、项目明细。")
                    .font(isNothing ? NothingFont.ui(10) : .system(size: 10.5))
                    .foregroundStyle(isNothing ? nothingTokens.secondary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .frame(maxWidth: 258)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Agent 用量，\(title)。检测到 Agent 活动后，这里会显示今日逐小时折线与模型、项目明细。")

            refreshIconButton
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 3)
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
            // Agent 品牌徽章 (C161): Nothing 走绿阶单色, 其余真彩档.
            AgentBrandBadge(
                asset: AgentBrandPalette.asset(forAgent: row.agentID),
                seriesHex: row.color.hex,
                size: isNothing ? 9 : 14,
                nothingHex: PanelAgentColor.nothingRampHex(
                    agentID: row.agentID,
                    darkMode: colorScheme == .dark
                ),
                fallbackMonogram: String(row.name.prefix(1)).uppercased()
            )
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
        // C217: 行首徽章同样避让 .clipped() 左缘, 3pt 留白保证系列色环完整.
        .padding(.leading, 3)
    }

    /// 24 点折线 (0-23 时): agent 色 1.5pt 线 + 淡渐变面积;
    /// Nothing 主题取外观 accent (深色 #30D158 / 浅色 #D4A843, C221), 与明细条同源.
    private func hourlyChart(_ row: HourlyAgentRow, index: Int) -> some View {
        let color = agentColor(row)
        let maxPoint = max(row.points.max() ?? 0, 1)
        let heroAccent = Color.adaptive(light: Color(hex: "#D4A843"), dark: Color(hex: "#30D158"))
        return Chart(Array(row.points.enumerated()), id: \.offset) { point in
            if isNothing {
                LineMark(
                    x: .value("时", point.offset),
                    y: .value("量", point.element)
                )
                .foregroundStyle(heroAccent)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                AreaMark(
                    x: .value("时", point.offset),
                    y: .value("量", point.element)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            heroAccent.opacity(colorScheme == .dark ? 0.16 : 0.12),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
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
        withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.15)) {
            if expandedAgentIDs.contains(agentID) {
                expandedAgentIDs.remove(agentID)
            } else {
                expandedAgentIDs.insert(agentID)
            }
        }
    }

    /// 明细区 (C216): 模型/项目两组同构紧凑条形, 内容对齐 Nothing:
    /// 段头 (标题 + 数量) + 每行 序号 / 名称 / 内联占比条 / 百分比 / Token.
    /// 不再渲染 100% 堆叠条、点阵导引、6-Tick 或 PRJ.CONSOLE 控制台.
    private func detailSection(_ row: HourlyAgentRow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !row.models.isEmpty {
                compactShareSection(
                    title: "模型占比",
                    countText: isNothing
                        ? "\(row.models.count) MODELS"
                        : "\(row.models.count) 个模型",
                    bars: row.models,
                    colorAt: { modelTierColor(row: row, index: $0) }
                )
            }
            if !row.projects.isEmpty {
                if !row.models.isEmpty {
                    compactSectionDivider
                        .padding(.vertical, 7)
                }
                compactShareSection(
                    title: "项目占比",
                    countText: isNothing
                        ? "\(row.projects.count) WORKSPACES"
                        : "\(row.projects.count) 个工程",
                    bars: row.projects,
                    colorAt: { projectTierColor(index: $0) }
                )
            }
        }
        .padding(.leading, 14)
        .padding(.top, 3)
    }

    /// 段头 + 行列表; 两段共用同一结构与间距.
    private func compactShareSection(
        title: String,
        countText: String,
        bars: [DistributionBar],
        colorAt: @escaping (Int) -> Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(isNothing ? NothingFont.mono(9) : .system(size: 9, weight: .semibold))
                    .tracking(isNothing ? 0.8 : 0.3)
                    .foregroundStyle(isNothing ? nothingTokens.secondary : Color.primary.opacity(0.55))
                Spacer(minLength: 8)
                Text(countText)
                    .font(isNothing ? NothingFont.mono(8.5) : .system(size: 9))
                    .foregroundStyle(isNothing ? nothingTokens.disabled : Color.secondary)
            }
            .padding(.bottom, 5)

            ForEach(Array(bars.enumerated()), id: \.offset) { index, bar in
                compactShareRow(bar, index: index, color: colorAt(index))
            }
        }
    }

    /// 单行: 序号 / 名称 / 内联占比条 / 百分比 / Token.
    /// 经典与 Nothing 只换字体、圆角与色阶, 不改变行结构.
    private func compactShareRow(
        _ bar: DistributionBar,
        index: Int,
        color: Color
    ) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%02d", index + 1))
                .font(isNothing
                    ? NothingFont.mono(8.5, weight: .bold)
                    : .system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: isNothing ? 16 : 18, alignment: .leading)
            Text(bar.name)
                .font(isNothing ? NothingFont.mono(9.5) : .system(size: 9.5))
                .foregroundStyle(isNothing ? nothingTokens.primary : Color.primary.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: isNothing ? 92 : 100, alignment: .leading)
            compactShareBar(share: bar.share, color: color)
                .frame(maxWidth: .infinity)
            Text(Self.sharePercentText(bar.share))
                .font(isNothing
                    ? NothingFont.mono(9.5, weight: .bold)
                    : .system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .frame(width: 28, alignment: .trailing)
            Text(bar.totalText)
                .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
                .monospacedDigit()
                .foregroundStyle(isNothing ? nothingTokens.disabled : Color.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .frame(height: 19)
        .accessibilityElement(children: .combine)
    }

    /// 3pt 内联占比条: 轨道 + 按 share 裁切的前景; 极小非零份额保底 2pt.
    private func compactShareBar(share: Double, color: Color) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: isNothing ? 0 : 2, style: .continuous)
                    .fill(isNothing
                        ? nothingTokens.raised
                        : Color.adaptive(
                            light: Color.black.opacity(0.08),
                            dark: Color.white.opacity(0.12)
                        ))
                RoundedRectangle(cornerRadius: isNothing ? 0 : 2, style: .continuous)
                    .fill(color)
                    .frame(width: max(2, proxy.size.width * min(max(share, 0), 1)))
            }
        }
        .frame(height: 3)
    }

    /// 两段之间的 1px 发丝分隔线.
    private var compactSectionDivider: some View {
        Rectangle()
            .fill(isNothing
                ? nothingTokens.border
                : Color.adaptive(
                    light: Color.black.opacity(0.08),
                    dark: Color.white.opacity(0.12)
                ))
            .frame(height: 1)
    }

    /// 模型档位色: 经典沿用 agent 四档色阶; Nothing 用绿阶.
    private func modelTierColor(row: HourlyAgentRow, index: Int) -> Color {
        if isNothing {
            return nothingTierColor(index: index)
        }
        return Color(hex: row.color.distributionHex(at: index))
    }

    /// 项目档位色: 经典沿用冻结青阶; Nothing 用绿阶.
    private func projectTierColor(index: Int) -> Color {
        if isNothing {
            return nothingTierColor(index: index)
        }
        return Color(hex: Self.projectBarShades[min(index, Self.projectBarShades.count - 1)])
    }

    /// Nothing 档位色 (与 hero accent / agent ramp 同源): 深色亮绿→暗绿, 浅色杏色三档 (C221).
    private func nothingTierColor(index: Int) -> Color {
        switch index {
        case 0:
            return Color.adaptive(light: Color(hex: "#B8860B"), dark: Color(hex: "#30D158"))
        case 1:
            return Color.adaptive(light: Color(hex: "#D4A843"), dark: Color(hex: "#4A9E5C"))
        default:
            return Color.adaptive(light: Color(hex: "#E3BE6B"), dark: Color(hex: "#2B7A42"))
        }
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
    /// 呼吸灯 accent (深绿 #4A9E5C / 浅橘 #D4A843), 与 Token 用量卡 accent 同源.
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
