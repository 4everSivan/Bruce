import Foundation

// 菜单栏液态玻璃面板的 view model 与展示格式化.
// 纯数据与格式化, 不含映射逻辑; 卡片组件只消费这里的 view model.
// 视觉与条件渲染语义以 panel-layout-v8.html 和设计文档 §3 为准.

// MARK: - Agent 配色

/// 面板 agent 配色: 冷色→暖色相邻渐变, 堆叠柱与图例有连续感且互可区分.
/// 色阶贴近 macOS 系统色, 避免高饱和撞色.
package enum PanelAgentColor: String, CaseIterable, Equatable, Sendable {
    /// Kimi Work — 浅蓝青
    case cyan
    /// Kimi Code CLI — 系统蓝
    case blue
    /// Grok — 靛蓝 (介于蓝与紫, 与 Claude 暖色拉开)
    case indigo
    /// Codex — 紫
    case purple
    /// Claude Code — 暖珊瑚 (原 orange 易与散列碰撞重合)
    case coral
    /// 未知 agent 散列兜底
    case mint
    case rose

    package var hex: String {
        switch self {
        case .cyan:
            return "#5ac8fa"
        case .blue:
            return "#0a84ff"
        case .indigo:
            return "#6c63ff"
        case .purple:
            return "#bf5af2"
        case .coral:
            return "#ff7a59"
        case .mint:
            return "#40c8e0"
        case .rose:
            return "#ff6482"
        }
    }

    /// 同 agent 内模型/项目占比条的相邻色阶 (由主色向浅/邻近色过渡, 避免纯透明度重复).
    /// index 0 为主色, 后续逐级变浅并略偏邻近色相.
    package func distributionHex(at index: Int) -> String {
        let shades = Self.distributionShades(for: self)
        return shades[min(max(index, 0), shades.count - 1)]
    }

    /// 已知 agent 固定配色 (冷→暖: work → code → grok → codex → claude);
    /// 未知 agent 用 FNV-1a 散列稳定落到调色板.
    package static func resolve(agentID: String) -> PanelAgentColor {
        switch agentID {
        case "kimi-work":
            return .cyan
        case "kimi-code-cli":
            return .blue
        case "grok":
            return .indigo
        case "codex":
            return .purple
        case "claude-code":
            return .coral
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

    /// 每色 4 档占比条色阶: 主色 → 中亮 → 浅 → 极浅, 同色系渐变.
    private static func distributionShades(for color: PanelAgentColor) -> [String] {
        switch color {
        case .cyan:
            return ["#5ac8fa", "#7dd4fb", "#a6e2fc", "#c8edfd"]
        case .blue:
            return ["#0a84ff", "#3d9fff", "#70b8ff", "#a3d0ff"]
        case .indigo:
            return ["#6c63ff", "#8b84ff", "#aaa5ff", "#c9c6ff"]
        case .purple:
            return ["#bf5af2", "#cd7cf5", "#db9ef8", "#e9c0fb"]
        case .coral:
            return ["#ff7a59", "#ff9580", "#ffb0a6", "#ffcbcb"]
        case .mint:
            return ["#40c8e0", "#66d4e6", "#8cdfed", "#b2ebf3"]
        case .rose:
            return ["#ff6482", "#ff839c", "#ffa2b6", "#ffc1d0"]
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

// MARK: - 用量档位

/// 总量分档: 驱动用量卡 hero 渐变与背景 tint.
/// < 50M 绿, 50M-150M 橙, 150M-250M 红, >= 250M 紫.
package enum UsageTier: String, Equatable, Sendable {
    case green
    case orange
    case red
    case purple

    package static func forTotal(_ totalTokens: Int) -> UsageTier {
        switch totalTokens {
        case ..<50_000_000:
            return .green
        case ..<150_000_000:
            return .orange
        case ..<250_000_000:
            return .red
        default:
            return .purple
        }
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
    /// 总量档位 (由 totalTokens 推导), 驱动 hero 渐变与背景 tint.
    package var usageTier: UsageTier {
        UsageTier.forTotal(totalTokens)
    }

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
    /// 原始窗口周期 (分钟), 供折叠态排序; 无数据为 nil.
    package let windowMinutes: Int?

    package init(
        label: String,
        usedPercent: Double,
        resetText: String,
        ownRow: Bool,
        windowMinutes: Int? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.percentText = String(format: "%.0f%%", usedPercent)
        self.resetText = resetText
        self.ownRow = ownRow
        self.windowMinutes = windowMinutes
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
    /// 多账号子卡; 单账号为 nil. 适用于所有 provider (不仅限 codex).
    package let accounts: [CodexAccountViewModel]
    /// 多账号折叠态的窗口摘要; 单账号为 nil.
    package let collapsedWindow: SubscriptionWindowRow?
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
        accounts: [CodexAccountViewModel],
        collapsedWindow: SubscriptionWindowRow?,
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
        self.accounts = accounts
        self.collapsedWindow = collapsedWindow
        self.balance = balance
        self.accountCountText = accountCountText
        self.deepSeekMonthlyUsage = deepSeekMonthlyUsage
    }

    /// 是否为多账号 section (>= 2 个账号).
    package var isMultiAccount: Bool {
        accounts.count >= 2
    }

    /// 徽章取色键: 单账号 section 的 id 可能是带账号后缀的 serviceID
    /// (如 "codex_<hash16>" / "deepseek_<accID>"), 必须归一化为 provider rawValue
    /// 再查品牌色, 否则全部落空为默认灰.
    package var badgeProviderID: String {
        SubscriptionPresentationPolicy.providerID(forServiceID: id)
    }

    /// 单账号便捷构造 (无 accounts, 无 collapsedWindow).
    package init(
        id: String,
        name: String,
        plan: String?,
        status: String,
        note: String?,
        extraText: String?,
        windows: [SubscriptionWindowRow],
        balance: BalanceRow?,
        accountCountText: String?,
        deepSeekMonthlyUsage: DeepSeekMonthlyUsageViewModel? = nil
    ) {
        self.init(
            id: id, name: name, plan: plan, status: status,
            note: note, extraText: extraText, windows: windows,
            accounts: [], collapsedWindow: nil,
            balance: balance, accountCountText: accountCountText,
            deepSeekMonthlyUsage: deepSeekMonthlyUsage
        )
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
