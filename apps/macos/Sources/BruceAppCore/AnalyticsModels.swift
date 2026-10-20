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

// MARK: - 顶层全局 KPI 与 Agent 对比数据结构

package struct AnalyticsKPISummary: Equatable, Sendable {
    package let totalTokens: Int
    package let totalTokensText: String
    package let equivalentMText: String
    package let totalCostUsd: Double?
    package let costText: String
    package let averageCostPerMillionText: String
    package let cacheReadTokens: Int
    package let cacheReadTokensText: String
    package let cacheHitRateText: String
    package let cacheSavedCostText: String
    package let activeAgentsCount: Int
    package let totalTurns: Int

    package init(
        totalTokens: Int,
        totalCostUsd: Double?,
        cacheReadTokens: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        activeAgentsCount: Int,
        totalTurns: Int
    ) {
        self.totalTokens = totalTokens
        self.totalTokensText = PanelFormat.tokenCount(totalTokens)
        if totalTokens >= 1_000_000_000 {
            self.equivalentMText = String(format: "%.2f B", Double(totalTokens) / 1_000_000_000.0)
        } else if totalTokens >= 1_000_000 {
            self.equivalentMText = String(format: "%.2f M", Double(totalTokens) / 1_000_000.0)
        } else if totalTokens >= 1_000 {
            self.equivalentMText = String(format: "%.1f K", Double(totalTokens) / 1_000.0)
        } else {
            self.equivalentMText = "\(totalTokens)"
        }

        self.totalCostUsd = totalCostUsd
        if let totalCostUsd {
            self.costText = String(format: "$%.2f", totalCostUsd)
            if totalTokens > 0 {
                let perM = (totalCostUsd / Double(totalTokens)) * 1_000_000.0
                self.averageCostPerMillionText = String(format: "$%.2f / 1M", perM)
            } else {
                self.averageCostPerMillionText = "—"
            }
        } else {
            self.costText = "—"
            self.averageCostPerMillionText = "—"
        }

        self.cacheReadTokens = cacheReadTokens
        self.cacheReadTokensText = PanelFormat.tokenCount(cacheReadTokens)

        let cacheBase = inputTokens + cacheReadTokens + cacheCreationTokens
        if cacheBase > 0 {
            let rate = Double(cacheReadTokens) / Double(cacheBase) * 100.0
            self.cacheHitRateText = String(format: "%.1f%%", rate)
            // 估算节省: 缓存通常享受 90% 折扣, 相当于以 10% 单价执行, 节省约 0.9 * cacheReadTokens * 平均单价
            let avgPrice = (totalCostUsd ?? 0.0) > 0 && totalTokens > 0
                ? (totalCostUsd! / Double(totalTokens))
                : 0.000003 // 兜底 $3/1M
            let savedUsd = Double(cacheReadTokens) * avgPrice * 0.9
            self.cacheSavedCostText = String(format: "省 ~$%.2f", savedUsd)
        } else {
            self.cacheHitRateText = "—"
            self.cacheSavedCostText = "—"
        }

        self.activeAgentsCount = activeAgentsCount
        self.totalTurns = totalTurns
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
        self.costText = costUsd.map { String(format: "$%.2f", $0) } ?? "—"
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
