import Foundation

// 菜单栏液态玻璃面板的 artifact -> view model 映射层.
// 纯逻辑, 不含 SwiftUI 视图代码; 卡片组件只消费这里的 view model.
// 视觉与条件渲染语义以 panel-layout-v8.html 和设计文档 §3 为准.

// MARK: - Agent 配色

/// 面板 agent 配色, 与 mockup 一致的 macOS 系统色.
package enum PanelAgentColor: String, CaseIterable, Equatable, Sendable {
    case blue
    case cyan
    case orange
    case purple

    package var hex: String {
        switch self {
        case .blue:
            return "#0a84ff"
        case .cyan:
            return "#5ac8fa"
        case .orange:
            return "#ff9f0a"
        case .purple:
            return "#bf5af2"
        }
    }

    /// 已知 agent 固定配色; 未知 agent 用 FNV-1a 散列稳定落到调色板.
    package static func resolve(agentID: String) -> PanelAgentColor {
        switch agentID {
        case "kimi-code-cli":
            return .blue
        case "kimi-work":
            return .cyan
        case "claude-code":
            return .orange
        case "codex":
            return .purple
        default:
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in agentID.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            let palette = PanelAgentColor.allCases
            return palette[Int(hash % UInt64(palette.count))]
        }
    }
}

// MARK: - 展示格式化

package enum PanelFormat {
    /// token 计数 K 格式化: 900 -> "900", 9000 -> "9K", 70500 -> "70.5K".
    package static func tokenCount(_ value: Int) -> String {
        if value < 1000 {
            return "\(value)"
        }
        if value < 1_000_000 {
            return trimDecimal(String(format: "%.1f", Double(value) / 1000)) + "K"
        }
        return trimDecimal(String(format: "%.1f", Double(value) / 1_000_000)) + "M"
    }

    /// 美元转人民币汇率; 暂为固定常量, 后续可做成配置项.
    package static let cnyPerUsd: Double = 7.2

    /// 成本文案: 输入 USD, 按 cnyPerUsd 换算为人民币, 至少两位小数, 最多三位 (如 "≈ ¥2.70").
    package static func costText(_ usd: Double) -> String {
        let cny = usd * cnyPerUsd
        var text = String(format: "%.3f", cny)
        while text.hasSuffix("0"), text.components(separatedBy: ".").last.map({ $0.count > 2 }) ?? false {
            text.removeLast()
        }
        return "≈ ¥" + text
    }

    /// 余额文案, 左右排版右侧大数字 (mockup "¥ 38.21").
    package static func balanceText(_ amount: Double, currency: String?) -> String {
        let symbol: String
        switch (currency ?? "CNY").uppercased() {
        case "CNY", "RMB":
            symbol = "¥"
        case "USD":
            symbol = "$"
        case let other:
            symbol = other + " "
        }
        return "\(symbol) \(String(format: "%.2f", amount))"
    }

    /// 余额文案的 Decimal 版 (月度账本金额).
    package static func decimalBalanceText(_ amount: Decimal, currency: String?) -> String {
        balanceText(NSDecimalNumber(decimal: amount).doubleValue, currency: currency)
    }

    /// 窗口措辞映射: windowMinutes 优先, 其次 collector 规范 label, 其余原样.
    package static func windowLabel(rawLabel: String, windowMinutes: Int?) -> String {
        if let minutes = windowMinutes {
            if approximately(minutes, 300) {
                return "每 5 小时"
            }
            if approximately(minutes, 10080) {
                return "每周"
            }
            if approximately(minutes, 43200) {
                return "每月"
            }
        }
        switch rawLabel {
        case "5小时窗口":
            return "每 5 小时"
        case "7天窗口", "每周窗口":
            return "每周"
        case "每月窗口":
            return "每月"
        default:
            return rawLabel
        }
    }

    /// 重置时间文案: 当天显示 "HH:mm", 之后显示 "N 天后", 已过期显示 "已到期".
    package static func resetText(
        resetsAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let resetsAt else {
            return ""
        }
        if resetsAt <= now {
            return "已到期"
        }
        if calendar.isDate(resetsAt, inSameDayAs: now) {
            let hour = calendar.component(.hour, from: resetsAt)
            let minute = calendar.component(.minute, from: resetsAt)
            return String(format: "%d:%02d", hour, minute)
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: resetsAt)
        ).day ?? 0
        return "\(max(days, 1)) 天后"
    }

    private static func approximately(_ value: Int, _ target: Int) -> Bool {
        abs(value - target) <= max(2, target / 50)
    }

    private static func trimDecimal(_ text: String) -> String {
        text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

// MARK: - 诊断

/// 映射过程产生的可诊断状态; 空数据, error/partial 不得静默吞掉.
package enum PanelDiagnostic: Equatable, Sendable {
    /// 模块 artifact 缺失, 对应卡片为 nil.
    case missingArtifact(module: DashboardModule)
    /// agent 条目状态非 ok (error / not_found / partial).
    case agentIssue(agentID: String, status: String, note: String)
    /// service 条目状态非 ok 但仍展示 (保留 note 供 UI).
    case serviceIssue(serviceID: String, status: String, note: String)
    /// 未授权占位或无可渲染内容的 service 被排除出订阅卡.
    case serviceSkipped(serviceID: String, status: String, note: String)
    /// 单个窗口条目解析失败被丢弃.
    case windowDropped(serviceID: String, reason: String)
    /// agent-usage artifact 存在但 agents 为空.
    case emptyUsageAgents
}

// MARK: - 用量卡

package struct UsageChartSegment: Equatable, Sendable {
    package let agentID: String
    package let color: PanelAgentColor
    package let value: Int

    package init(agentID: String, color: PanelAgentColor, value: Int) {
        self.agentID = agentID
        self.color = color
        self.value = value
    }
}

package struct UsageChartDay: Equatable, Sendable {
    package let date: String
    package let total: Int
    package let totalText: String
    /// 按 agent 堆叠分段, 顺序与图例一致 (artifact agent 顺序).
    package let segments: [UsageChartSegment]

    package init(date: String, total: Int, segments: [UsageChartSegment]) {
        self.date = date
        self.total = total
        self.totalText = PanelFormat.tokenCount(total)
        self.segments = segments
    }
}

package struct UsageLegendItem: Equatable, Sendable {
    package let agentID: String
    package let name: String
    package let color: PanelAgentColor

    package init(agentID: String, name: String, color: PanelAgentColor) {
        self.agentID = agentID
        self.name = name
        self.color = color
    }
}

package struct UsageBreakdownItem: Equatable, Sendable {
    package let label: String
    package let value: Int
    package let valueText: String

    package init(label: String, value: Int) {
        self.label = label
        self.value = value
        self.valueText = PanelFormat.tokenCount(value)
    }

    /// 文本型数值 (如百分比命中率), value 仅占位.
    package init(label: String, valueText: String) {
        self.label = label
        self.value = 0
        self.valueText = valueText
    }
}

package struct UsageHeroViewModel: Equatable, Sendable {
    package let totalTokens: Int
    package let totalTokensText: String
    /// 总成本文案, 定价缺失时为 nil (UI 隐藏成本位).
    package let costText: String?
    /// 输入 / 输出 / 缓存读取 / 缓存命中率 四格.
    package let breakdown: [UsageBreakdownItem]
    /// 14 日堆叠柱状图数据, 日期升序, 今天在最后.
    package let days: [UsageChartDay]
    package let legend: [UsageLegendItem]
    /// LIVE 呼吸灯: artifact 生成时间在阈值内视为实时.
    package let isLive: Bool

    package init(
        totalTokens: Int,
        costText: String?,
        breakdown: [UsageBreakdownItem],
        days: [UsageChartDay],
        legend: [UsageLegendItem],
        isLive: Bool
    ) {
        self.totalTokens = totalTokens
        self.totalTokensText = PanelFormat.tokenCount(totalTokens)
        self.costText = costText
        self.breakdown = breakdown
        self.days = days
        self.legend = legend
        self.isLive = isLive
    }
}

// MARK: - 订阅卡

package struct SubscriptionWindowRow: Equatable, Sendable {
    /// 已映射措辞 (每 5 小时 / 每周 / 每月 / 赠送额度 ...).
    package let label: String
    /// 已用百分比 0...100.
    package let usedPercent: Double
    package let percentText: String
    /// 重置时间文案, 无数据为空串.
    package let resetText: String
    /// collector 标记单独占一行的量条 (如赠送额度).
    package let ownRow: Bool

    package init(
        label: String,
        usedPercent: Double,
        resetText: String,
        ownRow: Bool
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.percentText = String(format: "%.0f%%", usedPercent)
        self.resetText = resetText
        self.ownRow = ownRow
    }
}

package struct BalanceRow: Equatable, Sendable {
    package let label: String
    package let amountText: String

    package init(amount: Double, currency: String?) {
        self.label = "账户余额"
        self.amountText = PanelFormat.balanceText(amount, currency: currency)
    }
}

// MARK: - DeepSeek 月度用量

/// DeepSeek 月度统计的展示 view model, 仅由 DeepSeek 的 SubscriptionProviderSection
/// 携带. 其他 provider 恒为 nil.
package struct DeepSeekMonthlyUsageViewModel: Equatable, Sendable {
    /// 展示状态: 正常趋势 / 仅有基线 / 月度统计不可用.
    package enum State: Equatable, Sendable {
        case trend
        case baseline
        case unavailable
    }

    package let state: State
    /// 本月推算消费 (已格式化, 非官方账单).
    package let estimatedConsumptionText: String
    /// 当前余额 (已格式化).
    package let currentBalanceText: String
    /// 覆盖说明, 如 "自 2026-08-03 起".
    package let coverageText: String
    /// 累计趋势点 (已格式化金额), 供图表绘制.
    package let trendPoints: [TrendPoint]
    /// 入账注记; nil 表示无非消费入账.
    package let creditNote: String?

    package init(
        state: State,
        estimatedConsumptionText: String,
        currentBalanceText: String,
        coverageText: String,
        trendPoints: [TrendPoint],
        creditNote: String?
    ) {
        self.state = state
        self.estimatedConsumptionText = estimatedConsumptionText
        self.currentBalanceText = currentBalanceText
        self.coverageText = coverageText
        self.trendPoints = trendPoints
        self.creditNote = creditNote
    }

    /// 是否存在至少两条可显示观察 (可绘制趋势图).
    package var canDrawTrend: Bool {
        state == .trend
    }
}

package struct CodexAccountViewModel: Equatable, Sendable {
    package let id: String
    /// 去掉 "Codex · " 前缀的账号名.
    package let name: String
    package let plan: String?
    package let status: String
    package let note: String?
    package let windows: [SubscriptionWindowRow]
    /// 非 ok 状态时显示的上次成功时间文案 ("上次成功 HH:mm"),
    /// 来自保留的旧 capturedAt; ok 状态为 nil.
    package let lastSuccessText: String?

    package init(
        id: String,
        name: String,
        plan: String?,
        status: String,
        note: String?,
        windows: [SubscriptionWindowRow],
        lastSuccessText: String? = nil
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.status = status
        self.note = note
        self.windows = windows
        self.lastSuccessText = lastSuccessText
    }
}

package struct SubscriptionProviderSection: Equatable, Sendable {
    package let id: String
    package let name: String
    package let plan: String?
    /// ok / error / partial; codex 分组取账号中最差状态.
    package let status: String
    /// error/partial 时保留的说明, UI 直接展示.
    package let note: String?
    /// 附加文案 (如 Kimi 加量包余额).
    package let extraText: String?
    package let windows: [SubscriptionWindowRow]
    /// app=="codex" 时为多账号子卡, 否则为 nil.
    package let codexAccounts: [CodexAccountViewModel]?
    /// 余额型条目 (DeepSeek), 排序沉底, 左右排版.
    package let balance: BalanceRow?
    package let accountCountText: String?
    /// DeepSeek 月度统计展示 view model (仅 DeepSeek 提供, 其他 provider 为 nil).
    package let deepSeekMonthlyUsage: DeepSeekMonthlyUsageViewModel?

    package init(
        id: String,
        name: String,
        plan: String?,
        status: String,
        note: String?,
        extraText: String?,
        windows: [SubscriptionWindowRow],
        codexAccounts: [CodexAccountViewModel]?,
        balance: BalanceRow?,
        accountCountText: String?,
        deepSeekMonthlyUsage: DeepSeekMonthlyUsageViewModel? = nil
    ) {
        self.id = id
        self.name = name
        self.plan = plan
        self.status = status
        self.note = note
        self.extraText = extraText
        self.windows = windows
        self.codexAccounts = codexAccounts
        self.balance = balance
        self.accountCountText = accountCountText
        self.deepSeekMonthlyUsage = deepSeekMonthlyUsage
    }
}

package struct SubscriptionViewModel: Equatable, Sendable {
    /// 余额型 provider 已沉底, 其余保持 artifact 顺序.
    package let sections: [SubscriptionProviderSection]
    /// 卡片右上角最后更新时间 ("最后更新 HH:mm"); generatedAt 解析失败为 nil.
    package let updatedText: String?

    package init(sections: [SubscriptionProviderSection], updatedText: String? = nil) {
        self.sections = sections
        self.updatedText = updatedText
    }
}

// MARK: - 逐小时卡

package struct DistributionBar: Equatable, Sendable {
    package let name: String
    package let total: Int
    package let totalText: String
    /// 占本组总量的比例 0...1, 作为量条宽度.
    package let share: Double

    package init(name: String, total: Int, share: Double) {
        self.name = name
        self.total = total
        self.totalText = PanelFormat.tokenCount(total)
        self.share = share
    }
}

package struct HourlyAgentRow: Equatable, Sendable {
    package let agentID: String
    package let name: String
    package let color: PanelAgentColor
    package let todayTotal: Int
    package let todayTotalText: String
    /// 24 点折线 (0-23 时).
    package let points: [Int]
    /// 有模型或项目明细时可展开.
    package let isExpandable: Bool
    /// 模型占比, Top 3 + 其他.
    package let models: [DistributionBar]
    /// 项目分布, Top 3 + 其他.
    package let projects: [DistributionBar]

    package init(
        agentID: String,
        name: String,
        color: PanelAgentColor,
        todayTotal: Int,
        points: [Int],
        models: [DistributionBar],
        projects: [DistributionBar]
    ) {
        self.agentID = agentID
        self.name = name
        self.color = color
        self.todayTotal = todayTotal
        self.todayTotalText = PanelFormat.tokenCount(todayTotal)
        self.points = points
        self.isExpandable = !models.isEmpty || !projects.isEmpty
        self.models = models
        self.projects = projects
    }
}

package struct HourlyLineViewModel: Equatable, Sendable {
    package let rows: [HourlyAgentRow]

    package init(rows: [HourlyAgentRow]) {
        self.rows = rows
    }
}

// MARK: - 面板容器

package struct PanelViewModel: Equatable, Sendable {
    package let usage: UsageHeroViewModel?
    package let subscription: SubscriptionViewModel?
    package let hourly: HourlyLineViewModel?
    package let diagnostics: [PanelDiagnostic]

    package init(
        usage: UsageHeroViewModel?,
        subscription: SubscriptionViewModel?,
        hourly: HourlyLineViewModel?,
        diagnostics: [PanelDiagnostic]
    ) {
        self.usage = usage
        self.subscription = subscription
        self.hourly = hourly
        self.diagnostics = diagnostics
    }
}

// MARK: - 映射器

package struct PanelViewModelMapper: Sendable {
    /// LIVE 判定阈值, 默认覆盖 30 分钟刷新周期加缓冲.
    package var liveThreshold: TimeInterval
    package var now: @Sendable () -> Date
    package var calendar: Calendar

    package init(
        liveThreshold: TimeInterval = 45 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.liveThreshold = liveThreshold
        self.now = now
        self.calendar = calendar
    }

    package func make(
        agentUsage: AgentUsageArtifact?,
        moduleStatuses: [DashboardModule: ModuleStatus],
        deepSeekMonthlyUsage: DeepSeekMonthlyUsage? = nil,
        providerOrder: [String] = []
    ) -> PanelViewModel {
        var diagnostics: [PanelDiagnostic] = []
        let currentNow = now()

        var usage: UsageHeroViewModel?
        var subscription: SubscriptionViewModel?
        var hourly: HourlyLineViewModel?
        if let agentUsage {
            usage = makeUsage(agentUsage, now: currentNow, diagnostics: &diagnostics)
            subscription = makeSubscription(
                agentUsage,
                now: currentNow,
                deepSeekMonthlyUsage: deepSeekMonthlyUsage,
                providerOrder: providerOrder,
                diagnostics: &diagnostics
            )
            hourly = makeHourly(agentUsage, diagnostics: &diagnostics)
        } else {
            diagnostics.append(.missingArtifact(module: .agentUsage))
        }

        return PanelViewModel(
            usage: usage,
            subscription: subscription,
            hourly: hourly,
            diagnostics: diagnostics
        )
    }

    // MARK: 用量卡

    private func makeUsage(
        _ artifact: AgentUsageArtifact,
        now: Date,
        diagnostics: inout [PanelDiagnostic]
    ) -> UsageHeroViewModel {
        if artifact.agents.isEmpty {
            diagnostics.append(.emptyUsageAgents)
        }
        for agent in artifact.agents where agent.status != "ok" {
            diagnostics.append(.agentIssue(
                agentID: agent.id,
                status: agent.status,
                note: normalizedNote(agent.note) ?? ""
            ))
        }

        let totals = artifact.agents.reduce(into: (input: 0, output: 0, cacheRead: 0, cacheCreation: 0, total: 0)) { acc, agent in
            acc.input += agent.today.input
            acc.output += agent.today.output
            acc.cacheRead += agent.today.cacheRead
            acc.cacheCreation += agent.today.cacheCreation
            acc.total += agent.today.total
        }

        // 14 日日期轴: 取各 agent daily 的日期并集升序, 保留最后 14 天.
        var dateSet = Set<String>()
        for agent in artifact.agents {
            for day in agent.daily {
                dateSet.insert(day.date)
            }
        }
        let dates = dateSet.sorted().suffix(14)
        let days: [UsageChartDay] = dates.map { date in
            var segments: [UsageChartSegment] = []
            var total = 0
            for agent in artifact.agents {
                let value = agent.daily.first(where: { $0.date == date })?.total ?? 0
                total += value
                if value > 0 {
                    segments.append(UsageChartSegment(
                        agentID: agent.id,
                        color: PanelAgentColor.resolve(agentID: agent.id),
                        value: value
                    ))
                }
            }
            return UsageChartDay(date: date, total: total, segments: segments)
        }

        // 图例: 14 日窗口内有量的 agent, 保持 artifact 顺序.
        let legend = artifact.agents
            .filter { $0.daily.suffix(14).contains(where: { $0.total > 0 }) }
            .map {
                UsageLegendItem(
                    agentID: $0.id,
                    name: $0.name,
                    color: PanelAgentColor.resolve(agentID: $0.id)
                )
            }

        let generatedAt = Self.parseISODate(artifact.generatedAt)
        let isLive: Bool
        if let generatedAt {
            let age = now.timeIntervalSince(generatedAt)
            isLive = age >= -300 && age <= liveThreshold
        } else {
            isLive = false
        }

        // 缓存命中率: 缓存读取 / (输入 + 缓存读取 + 缓存创建), 分母为 0 显示占位符.
        let cacheBase = totals.input + totals.cacheRead + totals.cacheCreation
        let cacheHitRateText = cacheBase > 0
            ? String(format: "%.0f%%", Double(totals.cacheRead) / Double(cacheBase) * 100)
            : "—"

        return UsageHeroViewModel(
            totalTokens: totals.total,
            costText: artifact.totalCostUsd.map(PanelFormat.costText),
            breakdown: [
                UsageBreakdownItem(label: "输入", value: totals.input),
                UsageBreakdownItem(label: "输出", value: totals.output),
                UsageBreakdownItem(label: "缓存读取", value: totals.cacheRead),
                UsageBreakdownItem(label: "缓存命中率", valueText: cacheHitRateText),
            ],
            days: days,
            legend: legend,
            isLive: isLive
        )
    }

    /// 领域月度状态 -> 展示 view model.
    /// nil -> nil (映射层未启用账本, 订阅卡不显示月度统计).
    /// unavailable -> 显示"月度统计暂不可用" (不暴露内部错误细节).
    /// baseline -> 只有覆盖说明与"正在建立本月趋势", 不可绘制趋势.
    /// trend -> 推算消费, 余额, 覆盖说明, 趋势点和入账注记.
    private func deepSeekMonthlyUsageViewModel(
        _ usage: DeepSeekMonthlyUsage?
    ) -> DeepSeekMonthlyUsageViewModel? {
        switch usage {
        case .trend(let trend):
            return DeepSeekMonthlyUsageViewModel(
                state: .trend,
                estimatedConsumptionText: PanelFormat.decimalBalanceText(
                    trend.estimatedConsumption, currency: trend.currency
                ),
                currentBalanceText: PanelFormat.decimalBalanceText(
                    trend.currentBalance, currency: trend.currency
                ),
                coverageText: trend.coverageText,
                trendPoints: trend.trendPoints,
                creditNote: trend.recentCreditNote
            )
        case .baseline(let baseline):
            return DeepSeekMonthlyUsageViewModel(
                state: .baseline,
                estimatedConsumptionText: PanelFormat.decimalBalanceText(
                    baseline.currentBalance, currency: baseline.currency
                ),
                currentBalanceText: PanelFormat.decimalBalanceText(
                    baseline.currentBalance, currency: baseline.currency
                ),
                coverageText: baseline.coverageStartText,
                trendPoints: [],
                creditNote: nil
            )
        case .unavailable:
            return DeepSeekMonthlyUsageViewModel(
                state: .unavailable,
                estimatedConsumptionText: "",
                currentBalanceText: "",
                coverageText: "月度统计暂不可用",
                trendPoints: [],
                creditNote: nil
            )
        case nil:
            return nil
        }
    }

    // MARK: 订阅卡

    private func makeSubscription(
        _ artifact: AgentUsageArtifact,
        now: Date,
        deepSeekMonthlyUsage: DeepSeekMonthlyUsage?,
        providerOrder: [String],
        diagnostics: inout [PanelDiagnostic]
    ) -> SubscriptionViewModel? {
        var sections: [SubscriptionProviderSection] = []
        var codexAccounts: [CodexAccountViewModel] = []
        var codexIndex: Int?

        for service in artifact.services {
            let kind = service.kind
            let note = normalizedNote(service.note)
            let isCodex = service.app == "codex"
            let hasWindows = !service.windows.isEmpty
            let hasBalance = service.balance != nil

            // 未授权占位 (status partial, 无窗口无余额) 视为未启用, 排除并留诊断.
            // 仅 partial 是占位; empty 是查询未取到数据的真实诊断状态, 必须渲染,
            // 否则一次瞬时失败会让整个 provider 段消失.
            let isPlaceholder = kind == nil && !hasWindows && !hasBalance
                && service.status == "partial"
            if isPlaceholder {
                diagnostics.append(.serviceSkipped(
                    serviceID: service.id,
                    status: service.status,
                    note: note ?? ""
                ))
                continue
            }

            if service.status != "ok" {
                diagnostics.append(.serviceIssue(
                    serviceID: service.id,
                    status: service.status,
                    note: note ?? ""
                ))
            }

            let windows = service.windows.compactMap { raw -> SubscriptionWindowRow? in
                parseWindow(raw, serviceID: service.id, now: now, diagnostics: &diagnostics)
            }

            if isCodex {
                if codexIndex == nil {
                    codexIndex = sections.count
                }
                codexAccounts.append(CodexAccountViewModel(
                    id: service.id,
                    name: codexAccountShortName(from: service.name),
                    plan: service.plan,
                    status: service.status,
                    note: note,
                    windows: windows,
                    lastSuccessText: lastSuccessText(
                        for: service,
                        now: now
                    )
                ))
                continue
            }

            // 月度统计仅映射到 DeepSeek section; 其他余额型 Provider 不受影响.
            let monthlyUsage = service.id == "deepseek"
                ? deepSeekMonthlyUsageViewModel(deepSeekMonthlyUsage)
                : nil

            sections.append(SubscriptionProviderSection(
                id: service.id,
                name: subscriptionDisplayName(service),
                plan: service.plan,
                status: service.status,
                note: note,
                extraText: subscriptionExtraText(service),
                windows: windows,
                codexAccounts: nil,
                balance: service.balance.map { BalanceRow(amount: $0, currency: service.currency) },
                accountCountText: nil,
                deepSeekMonthlyUsage: monthlyUsage
            ))
        }

        // Codex 多账号分组成一张卡, 位置取第一个 codex 条目处.
        if !codexAccounts.isEmpty {
            let statusRank = ["ok": 0, "partial": 1, "error": 2]
            let worst = codexAccounts
                .map { statusRank[$0.status] ?? 1 }
                .max() ?? 0
            let groupStatus = statusRank.first(where: { $0.value == worst })?.key ?? "partial"
            let group = SubscriptionProviderSection(
                id: "codex",
                name: "ChatGPT",
                plan: nil,
                status: groupStatus,
                note: nil,
                extraText: nil,
                windows: [],
                codexAccounts: codexAccounts,
                balance: nil,
                accountCountText: "\(codexAccounts.count) 个账号",
                deepSeekMonthlyUsage: nil
            )
            let insertion = min(codexIndex ?? sections.count, sections.count)
            sections.insert(group, at: insertion)
        }

        guard !sections.isEmpty else {
            return nil
        }

        // 用户自定义顺序优先; 无自定义顺序时余额型沉底, 其余保持 artifact 顺序.
        let sorted: [SubscriptionProviderSection]
        if providerOrder.isEmpty {
            sorted = sections.enumerated().sorted { lhs, rhs in
                let lhsBalance = lhs.element.balance != nil
                let rhsBalance = rhs.element.balance != nil
                if lhsBalance != rhsBalance {
                    return !lhsBalance
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        } else {
            let orderIndex = Dictionary(
                providerOrder.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { a, _ in a }
            )
            sorted = sections.enumerated().sorted { lhs, rhs in
                let lhsIdx = orderIndex[Self.providerID(forServiceID: lhs.element.id)] ?? Int.max
                let rhsIdx = orderIndex[Self.providerID(forServiceID: rhs.element.id)] ?? Int.max
                if lhsIdx != rhsIdx {
                    return lhsIdx < rhsIdx
                }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }

        return SubscriptionViewModel(
            sections: sorted,
            updatedText: updatedText(from: artifact.generatedAt)
        )
    }

    /// 把 artifact service ID 归一化为 SubscriptionProviderID rawValue,
    /// 供用户自定义顺序查找. Kimi 的 service ID 是 "kimi_coding" 而
    /// provider rawValue 是 "kimi"; 其他 service ID 与 provider rawValue 一致.
    private static func providerID(forServiceID serviceID: String) -> String {
        switch serviceID {
        case "kimi_coding": return "kimi"
        default: return serviceID
        }
    }

    /// 订阅卡右上角更新时间: "最后更新 HH:mm" (24 小时制, 跟随 mapper 时区);
    /// generatedAt 解析失败返回 nil, 卡片不渲染该文案.
    private func updatedText(from generatedAt: String) -> String? {
        guard let date = Self.parseISODate(generatedAt) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = calendar.timeZone
        return "最后更新 " + formatter.string(from: date)
    }

    private func parseWindow(
        _ raw: JSONValue,
        serviceID: String,
        now: Date,
        diagnostics: inout [PanelDiagnostic]
    ) -> SubscriptionWindowRow? {
        guard case .object(let object) = raw else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "窗口条目不是对象"))
            return nil
        }
        guard let label = object["label"]?.stringValue else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "缺少 label"))
            return nil
        }
        guard let usedPercent = object["usedPercent"]?.doubleValue else {
            diagnostics.append(.windowDropped(serviceID: serviceID, reason: "缺少 usedPercent: \(label)"))
            return nil
        }
        let clamped = min(100, max(0, usedPercent))
        let minutes = object["windowMinutes"]?.intValue
        let resetsAt = object["resetsAt"].flatMap(Self.parseResetDate)
        return SubscriptionWindowRow(
            label: PanelFormat.windowLabel(rawLabel: label, windowMinutes: minutes),
            usedPercent: clamped,
            resetText: PanelFormat.resetText(
                resetsAt: resetsAt,
                now: now,
                calendar: calendar
            ),
            ownRow: object["ownRow"]?.boolValue ?? false
        )
    }

    /// 订阅展示名: 火山引擎剥离 collector 名称里的 Coding Plan 后缀, 仅显示层覆盖.
    private func subscriptionDisplayName(_ service: AgentServiceItem) -> String {
        guard service.id == "volcengine" else { return service.name }
        return service.name.replacingOccurrences(of: "（Coding Plan）", with: "")
    }

    /// 附加文案: 「加量包未启用」对用户无信息量, 不展示; 余额等其他文案保留.
    private func subscriptionExtraText(_ service: AgentServiceItem) -> String? {
        let extra = normalizedNote(service.extra)
        return extra == "加量包未启用" ? nil : extra
    }

    /// 从 "Codex · <短名>" 中只删除开头固定前缀, 不用 replacingOccurrences
    /// 全局替换, 避免账号名内部包含相同文本时被误改.
    private func codexAccountShortName(from displayName: String) -> String {
        let prefix = "Codex · "
        if displayName.hasPrefix(prefix) {
            return String(displayName.dropFirst(prefix.count))
        }
        return displayName
    }

    /// freshness=stale 且有 capturedAt 时显示"上次成功 HH:mm";
    /// freshness=fresh/unavailable 或无 capturedAt 时不显示.
    private func lastSuccessText(
        for service: AgentServiceItem,
        now: Date
    ) -> String? {
        guard service.freshness == "stale",
              let capturedAt = service.capturedAt,
              let date = Self.parseISODate(capturedAt) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = calendar.timeZone
        let prefix = "上次成功 "
        return prefix + formatter.string(from: date)
    }

    // MARK: 逐小时卡

    private func makeHourly(
        _ artifact: AgentUsageArtifact,
        diagnostics: inout [PanelDiagnostic]
    ) -> HourlyLineViewModel {
        // 只展示 ok 或今日有量的 agent; not_found 等由用量卡诊断覆盖.
        let rows = artifact.agents
            .filter { $0.status == "ok" || $0.today.total > 0 }
            .map { agent -> HourlyAgentRow in
                let models = Self.topDistribution(
                    entries: (agent.models ?? [:]).sorted { lhs, rhs in
                        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
                    }.map { ($0.key, $0.value) },
                    base: agent.today.total,
                    limit: 3
                )
                let projects = Self.topDistribution(
                    entries: (agent.projects ?? []).map { ($0.name, $0.total) },
                    base: agent.today.total,
                    limit: 3
                )
                return HourlyAgentRow(
                    agentID: agent.id,
                    name: hourlyDisplayName(id: agent.id, fallback: agent.name),
                    color: PanelAgentColor.resolve(agentID: agent.id),
                    todayTotal: agent.today.total,
                    points: agent.hours,
                    models: models,
                    projects: projects
                )
            }
            // 按今日用量从高到低动态排序.
            .sorted { $0.todayTotal > $1.todayTotal }
        return HourlyLineViewModel(rows: rows)
    }

    /// 逐小时卡展示名: 仅显示层覆盖, 不动 artifact 契约名.
    private func hourlyDisplayName(id: String, fallback: String) -> String {
        id == "kimi-code-cli" ? "Kimi Code" : fallback
    }

    /// Top N + 其他聚合; base 为分组总量 (份额分母).
    /// models 的 entries 覆盖全部模型, 其他 = Top N 之外的余量;
    /// projects 的 entries 只有 Top 3, 其他 = 今日总量与已知的差值.
    private static func topDistribution(
        entries: [(name: String, total: Int)],
        base: Int,
        limit: Int
    ) -> [DistributionBar] {
        guard !entries.isEmpty else {
            return []
        }
        let denominator = max(base, entries.reduce(0) { $0 + $1.total })
        guard denominator > 0 else {
            return []
        }
        var bars = entries.prefix(limit).map {
            DistributionBar(
                name: $0.name,
                total: $0.total,
                share: Double($0.total) / Double(denominator)
            )
        }
        let otherTotal = denominator - bars.reduce(0) { $0 + $1.total }
        if otherTotal > 0 {
            bars.append(DistributionBar(
                name: "其他",
                total: otherTotal,
                share: Double(otherTotal) / Double(denominator)
            ))
        }
        return bars
    }

    // MARK: 工具

    private func normalizedNote(_ note: String?) -> String? {
        guard let note, !note.isEmpty else {
            return nil
        }
        return note
    }

    private static func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    private static func parseResetDate(_ value: JSONValue) -> Date? {
        switch value {
        case .integer(let seconds):
            // 非正 epoch (如火山未开始窗口的 ResetTimestamp=-1) 视为无重置时间, 避免解析成 1970.
            return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        case .double(let seconds):
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case .string(let text):
            return parseISODate(text)
        default:
            return nil
        }
    }
}

private extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .integer(let value):
            return Double(value)
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value):
            return value
        case .double(let value):
            return Int(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }
}
