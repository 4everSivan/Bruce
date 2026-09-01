import Foundation
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// 用量卡: 标题 + LIVE 呼吸灯, hero 总量, 输入/输出/缓存四格细分,
/// 按月 chip 网格与半年热力图; 14 日柱状图与 agent 图例已移至逐小时卡顶部.
/// 视觉以 panel-layout-v8.html 为准; 外层玻璃卡片容器由面板装配层统一提供,
/// 本组件只排内容.
/// Nothing 主题 (dashboard-nothing-prototype.html 定稿): 单色点阵仪器面板,
/// 所有视觉差异包在 theme.interfaceStyle == .nothing 分支内, 其余主题走原路径.
struct UsageHeroCard: View {
    let viewModel: UsageHeroViewModel

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heroBreathing = false
    /// 模型用量: 展开态与周期选择 (窗口档位 或 点击按月卡指定自然月).
    @State private var modelsExpanded = false
    @State private var modelSelection: ModelUsageSelection = .tier(0)

    enum ModelUsageSelection: Equatable {
        case tier(Int)
        case month(String)
    }

    init(viewModel: UsageHeroViewModel) {
        self.viewModel = viewModel
    }

    private var isNothing: Bool {
        theme.interfaceStyle == .nothing
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
            if !viewModel.monthly.isEmpty {
                monthlySection
                    .padding(.top, 12)
            }
            if let models = viewModel.models {
                modelUsageSection(models)
                    .padding(.top, 12)
            }
            if !viewModel.heatmap.isEmpty {
                sectionTitle("热力图 · 近半年")
                    .padding(.top, 12)
                heatmapView
                    .padding(.top, 4)
                heatmapDateAxis
                    .padding(.top, 5)
                heatmapLegend
                    .padding(.top, 5)
            }
        }
        .background {
            if isNothing {
                // Nothing: 16pt 点阵网格替代代码流字符背景, 底部渐隐.
                NothingDotGridBackground(color: Self.nothingSecondary)
            } else {
                CodeStreamBackground(tint: Self.tierTint(viewModel.usageTier))
            }
        }
    }

    // MARK: 标题行

    private var titleRow: some View {
        HStack {
            Text("Token 用量")
                .font(isNothing ? NothingFont.mono(12) : .system(size: 12.5, weight: .semibold))
                .tracking(isNothing ? 0.9 : 0)
                .textCase(isNothing ? Text.Case.uppercase : nil)
                .foregroundStyle(isNothing ? Self.nothingSecondary : Self.ink)
            Spacer()
            if viewModel.isLive {
                LiveIndicator(nothingStyle: isNothing)
            }
        }
    }

    // MARK: Hero 行

    private var heroRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            heroNumber
            Text("tokens")
                .font(isNothing ? NothingFont.mono(11) : .system(size: 13, weight: .medium))
                .tracking(isNothing ? 1.1 : 0)
                .textCase(isNothing ? Text.Case.uppercase : nil)
                .foregroundStyle(isNothing ? Self.nothingSecondary : Self.subdued)
            Spacer()
            if let costText = viewModel.costText {
                Text(costText)
                    .font(isNothing ? NothingFont.mono(17) : .system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isNothing ? Self.nothingPrimary : Self.accent)
            }
        }
    }

    /// Hero 总量数字: Nothing 下拆分整数/小数部分, 小数点用 4x4 实心方块
    /// 压基线呈现 (左右各 4pt), Doto display 纯色; 其余主题保持原文本渲染.
    @ViewBuilder
    private var heroNumber: some View {
        if isNothing {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let dotIndex = viewModel.totalTokensText.firstIndex(of: ".") {
                    Text(String(viewModel.totalTokensText[..<dotIndex]))
                    Rectangle()
                        .fill(Self.nothingHeroAccent)
                        .frame(width: 4, height: 4)
                        .padding(.horizontal, 4)
                    Text(String(viewModel.totalTokensText[viewModel.totalTokensText.index(after: dotIndex)...]))
                } else {
                    Text(viewModel.totalTokensText)
                }
            }
            .font(NothingFont.display(52, weight: .bold))
            .tracking(-1.04)
            .monospacedDigit()
            .foregroundStyle(Self.nothingHeroAccent)
            .opacity(reduceMotion ? 1 : (heroBreathing ? 1 : 0.86))
            .scaleEffect(reduceMotion ? 1 : (heroBreathing ? 1.015 : 1))
            .shadow(color: Self.nothingHeroAccent, radius: reduceMotion ? 0 : (heroBreathing ? 15 : 3))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) {
                    heroBreathing = true
                }
            }
        } else {
            Text(viewModel.totalTokensText)
                .font(.system(size: 40, weight: .bold))
                .tracking(-1.2)
                .monospacedDigit()
                .foregroundStyle(Self.heroGradient(for: viewModel.usageTier))
        }
    }

    // MARK: 分隔线

    private var dividerLine: some View {
        Rectangle()
            .fill(isNothing ? Self.nothingBorder : Self.hairline)
            .frame(height: 1)
    }

    // MARK: 四格细分

    private var breakdownRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(viewModel.breakdown.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Rectangle()
                        .fill(isNothing ? Self.nothingBorder : Self.hairline)
                        .frame(width: 1)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label)
                        .font(isNothing ? NothingFont.mono(10) : .system(size: 8.5))
                        .tracking(isNothing ? 0.9 : 0.85)
                        .textCase(isNothing ? Text.Case.uppercase : nil)
                        .foregroundStyle(isNothing ? Self.nothingSecondary : Self.faint)
                    Text(item.valueText)
                        .font(isNothing ? NothingFont.mono(13, weight: .bold) : .system(size: 13.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isNothing ? Self.nothingPrimary : Self.ink.opacity(0.85))
                }
                .padding(.leading, index == 0 ? 0 : 13)
                .padding(.trailing, index == viewModel.breakdown.count - 1 ? 0 : 13)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 按月统计

    /// 标题行 (右侧并入半年汇总) + 3 列月度 chip 网格 (当月高亮);
    /// 原型 usage-monthly-v2 变体 2.
    private var monthlySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("按月 · 近 6 个月")
                Spacer()
                if let halfYear = viewModel.halfYear {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("近半年 ")
                        Text(halfYear.totalText)
                            .font(isNothing ? NothingFont.mono(9) : .system(size: 10, weight: .bold))
                            .foregroundStyle(isNothing ? Self.nothingDisabled : Self.ink.opacity(0.85))
                        Text(" · 月均 \(halfYear.averageText)")
                    }
                    .font(isNothing ? NothingFont.mono(9) : .system(size: 10))
                    .tracking(isNothing ? 0.54 : 0)
                    .monospacedDigit()
                    .foregroundStyle(isNothing ? Self.nothingDisabled : Self.subdued)
                }
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 6),
                    count: 3
                ),
                spacing: 6
            ) {
                ForEach(Array(viewModel.monthly.enumerated()), id: \.offset) { _, month in
                    monthlyChip(month)
                }
            }
        }
    }

    /// 区块小标题: 10pt 半粗 + 字距, 与原型 .sec 样式一致;
    /// Nothing 下为 Space Mono 10px ALL CAPS (.label).
    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(isNothing ? NothingFont.mono(10) : .system(size: 10, weight: .semibold))
            .tracking(isNothing ? 0.9 : 0.4)
            .textCase(isNothing ? Text.Case.uppercase : nil)
            .foregroundStyle(isNothing ? Self.nothingSecondary : Self.faint)
    }

    /// 月度 chip: 点击联动下方模型用量区块; Nothing 下按定稿为 3pt 圆角 + 1px 边框,
    /// 当月 surface-raised 底与 border-visible 描边, 无当月透明底; 其余主题保持原白透明底样式.
    /// 选中卡 (非当月) 以 accent 描边与标签色标记.
    @ViewBuilder
    private func monthlyChip(_ month: UsageMonthlyTotal) -> some View {
        if viewModel.models != nil && !month.key.isEmpty {
            Button {
                modelSelection = .month(month.key)
            } label: {
                chipContent(month)
            }
            .buttonStyle(.plain)
        } else {
            chipContent(month)
        }
    }

    private func chipContent(_ month: UsageMonthlyTotal) -> some View {
        let isSelected = modelSelection == .month(month.key) && !month.key.isEmpty
        return VStack(alignment: .leading, spacing: 1) {
            Text(month.label)
                .font(isNothing
                    ? NothingFont.mono(9)
                    : .system(size: 8.5, weight: month.isCurrent || isSelected ? .semibold : .regular))
                .tracking(isNothing ? 0.81 : 0.5)
                .foregroundStyle(isNothing
                    ? ((month.isCurrent || isSelected) ? Self.nothingHeroAccent : Self.nothingSecondary)
                    : ((month.isCurrent || isSelected) ? Self.accent : Self.faint))
            Text(month.totalText)
                .font(isNothing ? NothingFont.mono(13) : .system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isNothing ? Self.nothingPrimary : Self.ink.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isNothing
                ? (month.isCurrent ? Self.nothingSurfaceRaised : Color.clear)
                : Color.adaptive(
                    light: Color.white.opacity(month.isCurrent ? 0.6 : 0.4),
                    dark: Color.white.opacity(month.isCurrent ? 0.14 : 0.08)
                ),
            in: RoundedRectangle(cornerRadius: isNothing ? 3 : 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: isNothing ? 3 : 10, style: .continuous)
                .strokeBorder(
                    isSelected && !isNothing ? Self.accent.opacity(0.85) :
                    isSelected ? Self.nothingHeroAccent :
                    (isNothing
                        ? (month.isCurrent ? Self.nothingBorderVisible : Self.nothingBorder)
                        : Color.adaptive(
                            light: Color.white.opacity(0.55),
                            dark: Color.white.opacity(0.1)
                        )),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityHint(viewModel.models != nil ? "点击查看该月模型用量" : "")
    }

    // MARK: 模型用量 (按月下方; 三档窗口 + 月卡联动, 默认本月、前 3 + 展开)

    private var modelRows: [UsageModelRow] {
        guard let models = viewModel.models else { return [] }
        switch modelSelection {
        case .tier(let index):
            guard models.tiers.indices.contains(index) else { return [] }
            let limit = modelsExpanded ? models.tiers[index].rows.count : min(3, models.tiers[index].rows.count)
            return Array(models.tiers[index].rows.prefix(limit))
        case .month(let key):
            guard let period = models.months.first(where: { $0.id == key }) else { return [] }
            let limit = modelsExpanded ? period.rows.count : min(3, period.rows.count)
            return Array(period.rows.prefix(limit))
        }
    }

    private var modelPeriodSuffix: String {
        guard let models = viewModel.models, case .month(let key) = modelSelection,
              let period = models.months.first(where: { $0.id == key }) else {
            return ""
        }
        return " · " + period.label
    }

    private func modelUsageSection(_ models: UsageModelUsageSection) -> some View {
        let rows = modelRows
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    sectionTitle("模型用量" + modelPeriodSuffix)
                    expandButton
                }
                Spacer()
                tierSegment(models)
            }
            .padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                modelRow(row)
            }
            if rows.isEmpty {
                Text("暂无模型数据")
                    .font(.system(size: 10))
                    .foregroundStyle(Self.faint)
                    .padding(.vertical, 6)
            }
        }
    }

    private var expandButton: some View {
        Button {
            modelsExpanded.toggle()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(modelsExpanded ? 180 : 0))
                .frame(width: 17, height: 17)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Self.subdued)
        .accessibilityLabel(modelsExpanded ? "收起全部模型" : "展开全部模型")
        .accessibilityAddTraits(modelsExpanded ? .isSelected : [])
    }

    private func isActiveTier(_ index: Int) -> Bool {
        guard case .tier(let selected) = modelSelection else { return false }
        return selected == index
    }

    private func tierSegment(_ models: UsageModelUsageSection) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(models.tiers.enumerated()), id: \.offset) { index, period in
                Button {
                    modelSelection = .tier(index)
                } label: {
                    Text(period.label)
                        .font(isNothing ? NothingFont.mono(8.5) : .system(size: 9, weight: .semibold))
                        .tracking(isNothing ? 0.5 : 0)
                        .textCase(isNothing ? .uppercase : nil)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: isNothing ? 2 : 6, style: .continuous)
                                .fill(isActiveTier(index)
                                      ? (isNothing ? Self.nothingHeroAccent : Color.primary.opacity(0.12))
                                      : Color.clear)
                        )
                        .foregroundStyle(
                            isActiveTier(index)
                                ? (isNothing
                                   ? (colorScheme == .dark ? Color.white : Color.black)
                                   : Self.ink)
                                : Self.subdued
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: isNothing ? 3 : 8, style: .continuous)
                .fill(isNothing ? Color.clear : Color.primary.opacity(0.06))
        )
        .overlay {
            if isNothing {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Self.nothingBorder, lineWidth: 1)
            }
        }
    }

    private func modelRow(_ row: UsageModelRow) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: isNothing ? 1 : 2)
                .fill(Color(hex: row.colorHex))
                .frame(width: 7, height: 7)
            Text(row.name)
                .font(isNothing ? NothingFont.mono(10) : .system(size: 10.5, weight: .medium))
                .tracking(isNothing ? 0.5 : 0)
                .textCase(isNothing ? .uppercase : nil)
                .foregroundStyle(Self.ink.opacity(0.9))
                .lineLimit(1)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: isNothing ? 0 : 2)
                        .fill(Self.hairline)
                    RoundedRectangle(cornerRadius: isNothing ? 0 : 2)
                        .fill(Color(hex: row.colorHex))
                        .frame(width: max(0, proxy.size.width * row.share))
                }
            }
            .frame(height: 4)
            Text(row.pctText)
                .font(.system(size: 8.5))
                .monospacedDigit()
                .foregroundStyle(Self.faint)
                .frame(width: 30, alignment: .trailing)
            // 数值列按 "10000M" 量级预留宽度并单行显示, 过千数值 (如 5626.4M) 不再折行.
            Text(row.totalText)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Self.ink.opacity(0.9))
                .lineLimit(1)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    // MARK: 用量热力图

    /// 周列 × 周日行 (周一起) 网格: 列等宽撑满卡片, 格子正方形随列宽缩放;
    /// level 0 淡槽, 1-5 沿用 UsageTier 绿色阶 (sage..forest), 窗口外与未来格透明.
    /// Nothing 下全方角, level 0 用 surface-raised, 1-5 为 display 白阶 5 档透明度.
    private var heatmapView: some View {
        HStack(alignment: .top, spacing: 3) {
            ForEach(Array(viewModel.heatmap.enumerated()), id: \.offset) { colIndex, week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { row in
                        HeatmapCellView(cell: week.cells[row], isNothing: isNothing, col: colIndex, row: row)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("用量热力图")
    }

    /// 起止日期轴: 左窗口首日, 右今天, 与网格左右缘对齐.
    private var heatmapDateAxis: some View {
        HStack {
            Text(heatmapBoundaryText(first: true))
            Spacer()
            Text(heatmapBoundaryText(first: false))
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
        .foregroundStyle(isNothing ? Self.nothingDisabled : Self.faint)
    }

    /// "yyyy-MM-dd" -> "yy/MM/dd"; 取窗口首个/末个有效格.
    private func heatmapBoundaryText(first: Bool) -> String {
        let cells = viewModel.heatmap.flatMap(\.cells).compactMap { $0 }
        guard let cell = first ? cells.first : cells.last else {
            return ""
        }
        let parts = cell.date.split(separator: "-")
        guard parts.count == 3 else {
            return cell.date
        }
        return "\(parts[0].suffix(2))/\(parts[1])/\(parts[2])"
    }

    /// 程度图例 (GitHub 风格): 「少」 + level 0-5 格子 + 「多」, 右对齐.
    private var heatmapLegend: some View {
        HStack(spacing: 3) {
            Spacer()
            Text("少")
            heatmapLevelSwatch(0)
            ForEach(1...5, id: \.self) { level in
                heatmapLevelSwatch(level)
            }
            Text("多")
        }
        .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
        .foregroundStyle(isNothing ? Self.nothingDisabled : Self.faint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("热力图程度图例: 颜色从少到多")
    }

    private func heatmapLevelSwatch(_ level: Int) -> some View {
        RoundedRectangle(cornerRadius: isNothing ? 0 : 2, style: .continuous)
            .fill(heatmapLevelColor(level))
            .frame(width: 9, height: 9)
    }

    private func heatmapCellColor(_ cell: UsageHeatmapCell?) -> Color {
        guard let cell else {
            return .clear
        }
        return heatmapLevelColor(cell.level)
    }

    /// 热力图单元格: Nothing 填充格在定稿 display 白阶透明度上做错相位呼吸
    /// (绿/橙仅用于 Hero, 热力图保持 display 白阶); 尊重 accessibilityReduceMotion.
    private struct HeatmapCellView: View {
        let cell: UsageHeatmapCell?
        let isNothing: Bool
        let col: Int
        let row: Int
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var breathe = false

        private var level: Int { cell?.level ?? 0 }
        private var filled: Bool { level > 0 }

        var body: some View {
            let base = HeatmapCellView.baseColor(cell: cell, isNothing: isNothing)
            let baseOpacity: Double = {
                guard isNothing, filled else { return 1 }
                return [0.2, 0.4, 0.6, 0.8, 1.0][min(level, 5) - 1]
            }()
            return RoundedRectangle(cornerRadius: isNothing ? 0 : 2, style: .continuous)
                .fill(base)
                .opacity(reduceMotion || !isNothing || !filled ? 1 : (breathe ? 1 : baseOpacity * 0.42))
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .onAppear {
                    guard isNothing, filled, !reduceMotion else { return }
                    let phase = (Double(col) * 0.12 + Double(row) * 0.05)
                        .truncatingRemainder(dividingBy: 3.2)
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true).delay(phase)) {
                        breathe = true
                    }
                }
        }

        static func baseColor(cell: UsageHeatmapCell?, isNothing: Bool) -> Color {
            guard let cell else { return .clear }
            if isNothing {
                guard cell.level > 0 else { return UsageHeroCard.nothingSurfaceRaised }
                // 填充格与 hero 呼吸灯同 accent (深绿 #4A9E5C / 浅橘 #D4A843), 透明度分档.
                let op = [0.2, 0.4, 0.6, 0.8, 1.0][min(cell.level, 5) - 1]
                return UsageHeroCard.nothingHeroAccent.opacity(op)
            }
            guard cell.level > 0 else { return Color.primary.opacity(0.07) }
            let tier: UsageTier
            switch cell.level {
            case 1: tier = .sage
            case 2: tier = .moss
            case 3: tier = .fern
            case 4: tier = .pine
            default: tier = .forest
            }
            return UsageHeroCard.tierColors(for: tier).0
        }
    }

    private func heatmapLevelColor(_ level: Int) -> Color {
        if isNothing {
            guard level > 0 else {
                return Self.nothingSurfaceRaised
            }
            let opacities: [Double] = [0.2, 0.4, 0.6, 0.8, 1.0]
            // 图例与填充格同 accent (深绿/浅橘), 与 hero 呼吸灯一致.
            return Self.nothingHeroAccent.opacity(opacities[min(level, 5) - 1])
        }
        guard level > 0 else {
            return Color.primary.opacity(0.07)
        }
        let tier: UsageTier
        switch level {
        case 1:
            tier = .sage
        case 2:
            tier = .moss
        case 3:
            tier = .fern
        case 4:
            tier = .pine
        default:
            tier = .forest
        }
        return Self.tierColors(for: tier).0
    }

    // MARK: 颜色常量 (浅色值换算自 mockup CSS, 深色值见 adaptive 调用)

    private static let accent = Color(hex: "#0a84ff")
    private static let ink = Color.primary
    private static let subdued = Color.primary.opacity(0.5)
    private static let faint = Color.primary.opacity(0.55)
    private static let hairline = Color.adaptive(
        light: Color.black.opacity(0.07),
        dark: Color.white.opacity(0.12)
    )

    // MARK: Nothing 颜色 token (dashboard-nothing-prototype.html 定稿, 两模式一致)

    private static let nothingDisplay = Color.adaptive(
        light: Color(hex: "#000000"),
        dark: Color(hex: "#FFFFFF")
    )
    private static let nothingPrimary = Color.adaptive(
        light: Color(hex: "#1A1A1A"),
        dark: Color(hex: "#E8E8E8")
    )
    private static let nothingSecondary = Color.adaptive(
        light: Color(hex: "#666666"),
        dark: Color(hex: "#999999")
    )
    private static let nothingDisabled = Color.adaptive(
        light: Color(hex: "#999999"),
        dark: Color(hex: "#666666")
    )
    private static let nothingBorder = Color.adaptive(
        light: Color(hex: "#E8E8E8"),
        dark: Color(hex: "#222222")
    )
    private static let nothingBorderVisible = Color.adaptive(
        light: Color(hex: "#CCCCCC"),
        dark: Color(hex: "#333333")
    )
    private static let nothingSurfaceRaised = Color.adaptive(
        light: Color(hex: "#F0F0F0"),
        dark: Color(hex: "#1A1A1A")
    )

    /// Nothing hero 强调色: Dark=success 绿, Light=warning 橙 (复用定稿阈值色值, 不新创).
    private static let nothingHeroAccent = Color.adaptive(
        light: Color(hex: "#D4A843"),
        dark: Color(hex: "#4A9E5C")
    )

    /// hero 渐变按今日总量档位在统一绿色阶内变化 (源自 logo 底色):
    /// <100M sage #7D9B76, 此后每 100M 加深一档, >=400M forest #26452A.
    /// 结构沿用 mockup (135deg, 起点 30%, 终点收敛 1.0).
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

    /// 档位配色: 返回 (档位基色, 同族浅色); 基色同时用于热力图格子,
    /// 浅色作为 hero 渐变末端与背景字符 tint. 五色同色相逐级加深.
    private static func tierColors(for tier: UsageTier) -> (Color, Color) {
        switch tier {
        case .sage:
            return (Color(hex: "#7D9B76"), Color(hex: "#9DB597"))
        case .moss:
            return (Color(hex: "#63885E"), Color(hex: "#82A57C"))
        case .fern:
            return (Color(hex: "#4C7249"), Color(hex: "#6A9064"))
        case .pine:
            return (Color(hex: "#385B38"), Color(hex: "#557B52"))
        case .forest:
            return (Color(hex: "#26452A"), Color(hex: "#456B42"))
        }
    }

    /// 背景字符 tint: 档位浅色阶, 低透明度下呼应 hero 渐变.
    private static func tierTint(_ tier: UsageTier) -> Color {
        tierColors(for: tier).1
    }
}

// MARK: - Nothing 点阵背景

/// Nothing 用量卡点阵背景: 16pt 网格 2pt 圆点, text-secondary 色,
/// 整体透明度 0.13, 底部渐隐 mask 避免干扰图表; 零动画零模糊.
private struct NothingDotGridBackground: View {
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 16
            let cols = Int(size.width / spacing) + 1
            let rows = Int(size.height / spacing) + 1
            guard cols > 0, rows > 0 else {
                return
            }
            for col in 0..<cols {
                for row in 0..<rows {
                    let x = spacing / 2 + CGFloat(col) * spacing
                    let y = spacing / 2 + CGFloat(row) * spacing
                    let dot = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: dot), with: .color(color))
                }
            }
        }
        .opacity(0.13)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0.42),
                    .init(color: .clear, location: 0.88),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 代码流背景

/// 用量卡代码流背景: 复刻旧 web widget 的字符密度流场 (.:+*# 网格下流),
/// 按总量档位取 tint, 低透明度叠加在玻璃之上, 底部 mask 渐隐避免干扰图表.
/// 10fps 慢速下流, 每列速度略有差异; Reduce Motion 时静止.
private struct CodeStreamBackground: View {
    let tint: Color

    private let characters: [Character] = [".", ":", "+", "*", "#"]
    private let spacing: CGFloat = 16

    var body: some View {
        // 静态代码流背景: TimelineView 动画在 MenuBarExtra 隐藏窗口时不暂停,
        // 每帧重绘 Canvas (275 次采样命中 body), 实测面板关闭时主线程 CPU ~20%.
        // 纯装饰动画移除, 改静态渲染 (布局不变, 视觉保持密度感).
        Canvas { ctx, size in
            let cycle = size.height + spacing
            let cols = Int(size.width / spacing)
            let rows = Int(size.height / spacing) + 2
            guard cols > 0, rows > 0 else {
                return
            }
            for col in 0...cols {
                // 静态列偏移: 每列错落 0-2 格, 保留流场层次感.
                let colOffset = CGFloat((cellHash(col, 0) % 3))
                let x = spacing / 2 + CGFloat(col) * spacing
                for row in 0...rows {
                    let base = CGFloat(row) * spacing + colOffset * spacing * 0.5
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
/// Nothing 主题: 5pt 实心方点 (success 色), 去光晕, 文本 Space Mono.
private struct LiveIndicator: View {
    let nothingStyle: Bool

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if nothingStyle {
                    Rectangle()
                        .fill(Self.nothingSuccess)
                        .frame(width: 5, height: 5)
                } else {
                    // 光晕: mockup 为 3px 扩散环 (18% 透明度).
                    Circle()
                        .fill(Self.green.opacity(0.18))
                        .frame(width: 12, height: 12)
                    Circle()
                        .fill(Self.green)
                        .frame(width: 6, height: 6)
                }
            }
            Text("LIVE")
                .font(nothingStyle ? NothingFont.mono(9) : .system(size: 9.5, weight: .semibold))
                .tracking(nothingStyle ? 1.08 : 0)
                .foregroundStyle(nothingStyle ? Self.nothingText : Self.textGreen)
        }
    }

    private static let green = Color(hex: "#30d158")
    /// 深绿文字在深色玻璃上对比度不足, 深色下退回亮绿.
    private static let textGreen = Color.adaptive(light: Color(hex: "#0a7d3b"), dark: Color(hex: "#30d158"))
    private static let nothingSuccess = Color(hex: "#4A9E5C")
    private static let nothingText = Color.adaptive(
        light: Color(hex: "#666666"),
        dark: Color(hex: "#999999")
    )
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
