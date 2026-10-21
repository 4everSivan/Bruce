import Foundation
import BruceOnboardingCore

// MARK: - 归一化模型与跨源合并模型

/// 单个规范主模型的归并汇总 (包含合并后的总 Tokens、费用以及各原始渠道明细).
package struct CanonicalModelSummary: Identifiable, Equatable, Sendable {
    package var id: String { canonicalKey }
    package let canonicalKey: String
    package let displayName: String
    package let vendor: String
    package let colorHex: String
    package let totalTokens: Int
    package let totalTokensText: String
    package let estimatedCostUsd: Double?
    package let costText: String?
    package let sharePercent: Double
    /// 各原始渠道的细分贡献 (如 zhipu/glm-5.3, cline-pass/glm-5.3)
    package let sources: [ModelSourceContribution]

    package init(
        canonicalKey: String,
        displayName: String,
        vendor: String,
        colorHex: String,
        totalTokens: Int,
        totalTokensText: String,
        estimatedCostUsd: Double?,
        costText: String?,
        sharePercent: Double,
        sources: [ModelSourceContribution]
    ) {
        self.canonicalKey = canonicalKey
        self.displayName = displayName
        self.vendor = vendor
        self.colorHex = colorHex
        self.totalTokens = totalTokens
        self.totalTokensText = totalTokensText
        self.estimatedCostUsd = estimatedCostUsd
        self.costText = costText
        self.sharePercent = sharePercent
        self.sources = sources
    }
}

/// 原始渠道来源贡献明细
package struct ModelSourceContribution: Identifiable, Equatable, Sendable {
    package var id: String { rawModelName + "@" + agentID }
    package let rawModelName: String
    package let agentID: String
    package let agentDisplayName: String
    package let tokens: Int
    package let tokensText: String
    package let costUsd: Double?
    package let costText: String?
    package let shareOfModelPercent: Double

    package init(
        rawModelName: String,
        agentID: String,
        agentDisplayName: String,
        tokens: Int,
        tokensText: String,
        costUsd: Double?,
        costText: String?,
        shareOfModelPercent: Double
    ) {
        self.rawModelName = rawModelName
        self.agentID = agentID
        self.agentDisplayName = agentDisplayName
        self.tokens = tokens
        self.tokensText = tokensText
        self.costUsd = costUsd
        self.costText = costText
        self.shareOfModelPercent = shareOfModelPercent
    }
}

// MARK: - 时间与图表维度定义

package enum AnalyticsTimeRange: String, CaseIterable, Identifiable, Sendable {
    case today = "today"
    case sevenDays = "7d"
    case thirtyDays = "30d"
    case thisMonth = "month"
    case allTime = "all"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .today: return "今日"
        case .sevenDays: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        case .thisMonth: return "本月"
        case .allTime: return "全部历史"
        }
    }
}

package enum AnalyticsChartSeriesMode: String, CaseIterable, Identifiable, Sendable {
    case byAgent = "agent"
    case byModel = "model"
    case byTokenType = "tokenType"
    case cost = "cost"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .byAgent: return "Agent"
        case .byModel: return "模型"
        case .byTokenType: return "Token 构成"
        case .cost: return "费用"
        }
    }
}

package enum AnalyticsChartDisplayType: String, CaseIterable, Identifiable, Sendable {
    case line = "line"
    case area = "area"

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .line: return "折线"
        case .area: return "面积"
        }
    }
}

// MARK: - 时序图表点与系列元数据

package struct AnalyticsChartSeriesMeta: Identifiable, Equatable, Sendable {
    package var id: String { key }
    package let key: String
    package let name: String
    package let colorHex: String

    package init(key: String, name: String, colorHex: String) {
        self.key = key
        self.name = name
        self.colorHex = colorHex
    }
}

package struct AnalyticsTimelinePoint: Identifiable, Equatable, Sendable {
    package var id: String { label }
    package let label: String
    package let totalTokens: Int
    package let costUsd: Double
    package let seriesValues: [String: Int]

    package init(label: String, totalTokens: Int, costUsd: Double, seriesValues: [String: Int]) {
        self.label = label
        self.totalTokens = totalTokens
        self.costUsd = costUsd
        self.seriesValues = seriesValues
    }
}

// MARK: - 时序数据

/// 时序点粒度: 今日逐小时 / 近 7·30 天与本月逐日 / 全部历史逐月 (C070).
package enum AnalyticsTimelineGranularity: String, Equatable, Sendable {
    case hour
    case day
    case month
}

package struct AnalyticsTimeline: Equatable, Sendable {
    package let granularity: AnalyticsTimelineGranularity
    package let points: [AnalyticsTimelinePoint]
    package let peakSummary: String
    package let avgSummary: String

    package init(
        granularity: AnalyticsTimelineGranularity,
        points: [AnalyticsTimelinePoint],
        peakSummary: String,
        avgSummary: String
    ) {
        self.granularity = granularity
        self.points = points
        self.peakSummary = peakSummary
        self.avgSummary = avgSummary
    }
}

// MARK: - 顶层全局 KPI 与 Agent 对比数据结构

/// 工作台 KPI (C070): 全部取自采集端真实聚合与计价, 缺数据时文案为「—」, 不做任何估算.
/// token 四象限为原始口径: 输入 (不含缓存) / 输出 / 缓存读取 / 缓存写入, 四者之和 = 总量.
/// 旧 artifact 的多日数据缺缓存拆分 (`cacheSplitAvailable == false`) 时, 输入与缓存相关文案为「—」.
package struct AnalyticsKPISummary: Equatable, Sendable {
    package let totalTokens: Int
    package let totalTokensText: String
    package let equivalentMText: String
    package let inputTokens: Int
    package let outputTokens: Int
    package let cacheReadTokens: Int
    package let cacheCreationTokens: Int
    package let cacheSplitAvailable: Bool
    package let inputTokensText: String
    package let outputTokensText: String
    package let cacheReadTokensText: String
    package let cacheCreationTokensText: String
    /// 范围内已定价模型桶费用之和; 无明细或全部未定价时为 nil.
    package let totalCostUsd: Double?
    package let costText: String
    package let pricedTokens: Int
    package let unpricedTokens: Int
    /// 每 1M 均价 = 费用 ÷ 已定价 tokens.
    package let averageCostPerMillionText: String
    /// 费用口径标签: 全部已定价为「单价表计价」, 否则标出未计入费用的 token 量.
    package let costTagText: String
    package let cacheHitRateText: String
    package let cacheSavingsUsd: Double?
    package let cacheSavedCostText: String
    package let activeAgentsCount: Int
    /// 最活跃 Agent 及其占比 (取代无数据来源的「轮交互」).
    package let topAgentText: String

    package init(
        totalTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        cacheSplitAvailable: Bool,
        totalCostUsd: Double?,
        pricedTokens: Int,
        unpricedTokens: Int,
        cacheSavingsUsd: Double?,
        activeAgentsCount: Int,
        topAgentName: String?,
        topAgentSharePercent: Double
    ) {
        self.totalTokens = totalTokens
        self.totalTokensText = PanelFormat.tokenCount(totalTokens)
        self.equivalentMText = AnalyticsFormat.scaledTokens(totalTokens)
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheSplitAvailable = cacheSplitAvailable
        let splitText: (Int) -> String = { cacheSplitAvailable ? PanelFormat.tokenCount($0) : "—" }
        self.inputTokensText = splitText(inputTokens)
        self.outputTokensText = PanelFormat.tokenCount(outputTokens)
        self.cacheReadTokensText = splitText(cacheReadTokens)
        self.cacheCreationTokensText = splitText(cacheCreationTokens)
        self.totalCostUsd = totalCostUsd
        self.costText = totalCostUsd.map(AnalyticsFormat.usd) ?? "—"
        self.pricedTokens = pricedTokens
        self.unpricedTokens = unpricedTokens
        if let totalCostUsd, pricedTokens > 0 {
            self.averageCostPerMillionText = AnalyticsFormat.usd(totalCostUsd / Double(pricedTokens) * 1_000_000.0) + " / 1M"
        } else {
            self.averageCostPerMillionText = "—"
        }
        if unpricedTokens > 0 {
            self.costTagText = PanelFormat.tokenCount(unpricedTokens) + " 未定价"
        } else {
            self.costTagText = totalCostUsd == nil ? "无明细" : "单价表计价"
        }
        let cacheBase = inputTokens + cacheReadTokens + cacheCreationTokens
        self.cacheHitRateText = cacheSplitAvailable && cacheBase > 0
            ? AnalyticsFormat.percent(Double(cacheReadTokens) / Double(cacheBase) * 100.0)
            : "—"
        self.cacheSavingsUsd = cacheSavingsUsd
        self.cacheSavedCostText = cacheSavingsUsd.map { "省 " + AnalyticsFormat.usd($0) } ?? "—"
        self.activeAgentsCount = activeAgentsCount
        if let topAgentName {
            self.topAgentText = "最活跃 \(topAgentName) · " + AnalyticsFormat.percent(topAgentSharePercent)
        } else {
            self.topAgentText = "—"
        }
    }
}

/// 工作台文案格式 (C070): 双端逐字符一致的唯一实现, Windows Rust 侧镜像同一规则.
package enum AnalyticsFormat {
    /// "$12.34"
    package static func usd(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    /// "12.3%"
    package static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// 「等价」量级文案: "1.23 B" / "45.67 M" / "8.9 K" / "123".
    package static func scaledTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2f B", Double(value) / 1_000_000_000.0)
        }
        if value >= 1_000_000 {
            return String(format: "%.2f M", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1f K", Double(value) / 1_000.0)
        }
        return "\(value)"
    }
}

package struct AnalyticsAgentCardItem: Identifiable, Equatable, Sendable {
    package var id: String { agentID }
    package let agentID: String
    package let name: String
    package let status: String
    package let note: String?
    package let totalTokens: Int
    package let totalTokensText: String
    package let costUsd: Double?
    package let costText: String
    package let sharePercent: Double
    package let inputTokens: Int
    package let outputTokens: Int
    package let cacheReadTokens: Int
    package let cacheCreationTokens: Int
    package let colorHex: String
    package let topProjects: [AgentProjectUsage]
    package let topModels: [CanonicalModelSummary]

    package init(
        agentID: String,
        name: String,
        status: String,
        note: String?,
        totalTokens: Int,
        costUsd: Double?,
        sharePercent: Double,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        colorHex: String,
        topProjects: [AgentProjectUsage],
        topModels: [CanonicalModelSummary]
    ) {
        self.agentID = agentID
        self.name = name
        self.status = status
        self.note = note
        self.totalTokens = totalTokens
        self.totalTokensText = PanelFormat.tokenCount(totalTokens)
        self.costUsd = costUsd
        self.costText = costUsd.map(AnalyticsFormat.usd) ?? "—"
        self.sharePercent = sharePercent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.colorHex = colorHex
        self.topProjects = topProjects
        self.topModels = topModels
    }
}
