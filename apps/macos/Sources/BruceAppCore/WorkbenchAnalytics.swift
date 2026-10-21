import Foundation
import BruceOnboardingCore

/// Agent 用量工作台的唯一计算入口 (design 06 §4.2, C070).
///
/// 纯函数: 只读 artifact, 不估算 —— 所有数值都可追溯到 artifact 字段或采集端计价结果;
/// 缺数据 (旧 artifact 无明细桶) 时对应指标为 nil / 空, 由视图显示「—」.
/// 排序全部带显式次序键, 结果与字典遍历顺序无关. Windows `apps/win/viewmodel/src/analytics.rs`
/// 逐条镜像, 由 `AnalyticsParityHarness` 产出的 golden 对拍锁定.
package enum WorkbenchAnalytics {
    package struct Snapshot: Equatable, Sendable {
        package let range: AnalyticsTimeRange
        package let kpi: AnalyticsKPISummary
        package let models: [CanonicalModelSummary]
        package let timeline: AnalyticsTimeline
        /// 范围内 token > 0 的 Agent, 按总量降序.
        package let agents: [AnalyticsAgentCardItem]
        /// 今日 24 小时 token 合计 (全部 Agent), 供 24 小时密度条.
        package let todayHourlyTokens: [Int]
    }

    /// 无 artifact 时的空快照 (全部指标为 0 / 「—」).
    package static func empty(range: AnalyticsTimeRange) -> Snapshot {
        Snapshot(
            range: range,
            kpi: makeKPI(agents: [], agentTokens: [], entries: [], detailAvailable: false, cacheSplitAvailable: false),
            models: [],
            timeline: AnalyticsTimeline(granularity: granularity(for: range), points: [], peakSummary: "—", avgSummary: "—"),
            agents: [],
            todayHourlyTokens: Array(repeating: 0, count: 24)
        )
    }

    package static func make(artifact: AgentUsageArtifact, range: AnalyticsTimeRange) -> Snapshot {
        let agents = artifact.agents
        // collector 的 daily 覆盖窗口内每一个自然日 (含 0), 末位即今日
        let windowDates = Array(Set(agents.flatMap { $0.daily.map(\.date) })).sorted()
        let today = windowDates.last ?? String(artifact.generatedAt.prefix(10))
        let rangeDates: [String]
        switch range {
        case .today: rangeDates = [today]
        case .sevenDays: rangeDates = Array(windowDates.suffix(7))
        case .thirtyDays: rangeDates = Array(windowDates.suffix(30))
        case .thisMonth: rangeDates = windowDates.filter { $0.hasPrefix(String(today.prefix(7))) }
        case .allTime: rangeDates = windowDates
        }
        let dateSet = Set(rangeDates)
        // 今日取 today 桶 (恒有拆分); 多日范围要求每个 daily 都带缓存拆分 (旧 artifact 没有)
        let cacheSplitAvailable = range == .today || agents.allSatisfy { agent in
            agent.daily.allSatisfy { !dateSet.contains($0.date) || ($0.cacheRead != nil && $0.cacheCreation != nil) }
        }

        // 1. 各 Agent 范围内 token (原始口径, 四象限之和 = total)
        let agentTokens: [Tokens] = agents.map { agent in
            if range == .today {
                return Tokens(
                    input: agent.today.input,
                    output: agent.today.output,
                    cacheRead: agent.today.cacheRead,
                    cacheCreation: agent.today.cacheCreation,
                    total: agent.today.total
                )
            }
            var tokens = Tokens()
            for day in agent.daily where dateSet.contains(day.date) {
                tokens.add(Tokens(day: day))
            }
            return tokens
        }

        // 2. 范围内明细桶: 今日 / 7·30 天 / 本月取 dailyModels, 全部历史取 monthModels
        let detailAvailable = agents.contains {
            (range == .allTime ? $0.monthModels : $0.dailyModels) != nil
        }
        var entries: [Entry] = []
        for (index, agent) in agents.enumerated() {
            if range == .allTime {
                entries += (agent.monthModels ?? []).map { Entry(agentIndex: index, detail: $0) }
            } else {
                entries += (agent.dailyModels ?? [])
                    .filter { dateSet.contains($0.date ?? "") }
                    .map { Entry(agentIndex: index, detail: $0) }
            }
        }

        let models = canonicalModels(entries: entries, agents: agents)
        return Snapshot(
            range: range,
            kpi: makeKPI(
                agents: agents,
                agentTokens: agentTokens,
                entries: entries,
                detailAvailable: detailAvailable,
                cacheSplitAvailable: cacheSplitAvailable
            ),
            models: models,
            timeline: makeTimeline(
                range: range,
                agents: agents,
                rangeDates: rangeDates,
                topModelKeys: models.prefix(5).map(\.canonicalKey)
            ),
            agents: makeAgentCards(
                range: range,
                agents: agents,
                agentTokens: agentTokens,
                entries: entries,
                detailAvailable: detailAvailable
            ),
            todayHourlyTokens: (0..<24).map { hour in
                agents.reduce(0) { $0 + (hour < $1.hours.count ? $1.hours[hour] : 0) }
            }
        )
    }

    // MARK: - 中间结构

    /// 原始口径 token 合计 (输入不含缓存).
    private struct Tokens {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var total = 0

        init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0, total: Int = 0) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheCreation = cacheCreation
            self.total = total
        }

        /// daily.input 为展示口径 (含缓存读写), 还原为原始输入; 旧 artifact 缺拆分时缓存计 0.
        init(day: AgentDailyUsage) {
            let cacheRead = day.cacheRead ?? 0
            let cacheCreation = day.cacheCreation ?? 0
            self.init(
                input: max(0, day.input - cacheRead - cacheCreation),
                output: day.output,
                cacheRead: cacheRead,
                cacheCreation: cacheCreation,
                total: day.total
            )
        }

        mutating func add(_ other: Tokens) {
            input += other.input
            output += other.output
            cacheRead += other.cacheRead
            cacheCreation += other.cacheCreation
            total += other.total
        }
    }

    /// 范围内一个明细桶 (已绑定所属 Agent 在 artifact 中的下标).
    private struct Entry {
        let agentIndex: Int
        let detail: AgentModelDetail
    }

    /// 一个时序点的原始素材.
    private struct TimelineBucket {
        var total = 0
        var byAgent: [String: Int] = [:]
        /// Token 构成 (输入含缓存写入 / 输出 / 缓存读取); 数据不足时为 nil, 不出构成序列.
        var types: (input: Int, output: Int, cache: Int)?
        var byModel: [String: Int] = [:]
        var cost = 0.0
    }

    // MARK: - KPI

    private static func makeKPI(
        agents: [AgentUsageItem],
        agentTokens: [Tokens],
        entries: [Entry],
        detailAvailable: Bool,
        cacheSplitAvailable: Bool
    ) -> AnalyticsKPISummary {
        var totals = Tokens()
        agentTokens.forEach { totals.add($0) }
        let pricedTokens = entries.filter { $0.detail.costUsd != nil }.reduce(0) { $0 + $1.detail.total }
        let unpricedTokens = entries.filter { $0.detail.costUsd == nil }.reduce(0) { $0 + $1.detail.total }

        // 最活跃 Agent: 总量最大, 并列取 artifact 中靠前者
        var topIndex: Int?
        for (index, tokens) in agentTokens.enumerated() where tokens.total > 0 {
            if let current = topIndex, agentTokens[current].total >= tokens.total { continue }
            topIndex = index
        }
        return AnalyticsKPISummary(
            totalTokens: totals.total,
            inputTokens: totals.input,
            outputTokens: totals.output,
            cacheReadTokens: totals.cacheRead,
            cacheCreationTokens: totals.cacheCreation,
            cacheSplitAvailable: cacheSplitAvailable,
            totalCostUsd: detailAvailable ? pricedSum(entries, \.costUsd) : nil,
            pricedTokens: pricedTokens,
            unpricedTokens: unpricedTokens,
            cacheSavingsUsd: detailAvailable ? pricedSum(entries, \.cacheSavingsUsd) : nil,
            activeAgentsCount: agentTokens.filter { $0.total > 0 }.count,
            topAgentName: topIndex.map { agents[$0].name },
            topAgentSharePercent: topIndex.map { percent(agentTokens[$0].total, of: totals.total) } ?? 0
        )
    }

    /// 已定价桶金额之和: 无桶 (范围内无用量) 为 0; 有桶但全部未定价为 nil (显示「—」, 不估算).
    private static func pricedSum(_ entries: [Entry], _ value: KeyPath<AgentModelDetail, Double?>) -> Double? {
        if entries.isEmpty { return 0 }
        let priced = entries.compactMap { $0.detail[keyPath: value] }
        return priced.isEmpty ? nil : priced.reduce(0, +)
    }

    private static func percent(_ part: Int, of whole: Int) -> Double {
        whole > 0 ? Double(part) / Double(whole) * 100.0 : 0
    }

    // MARK: - 模型归并

    /// 按规范键归并; 来源按 (原始模型名, Agent) 区分. 次序: token 降序 → 规范键 / 原始名 → Agent 下标.
    private static func canonicalModels(entries: [Entry], agents: [AgentUsageItem]) -> [CanonicalModelSummary] {
        struct SourceKey: Hashable {
            let raw: String
            let agentIndex: Int
        }
        struct SourceTotal {
            var tokens = 0
            var cost: Double?
        }
        var modelTotals: [String: Int] = [:]
        var sources: [String: [SourceKey: SourceTotal]] = [:]
        for entry in entries {
            let key = ModelNormalizer.canonicalKey(for: entry.detail.model)
            modelTotals[key, default: 0] += entry.detail.total
            let sourceKey = SourceKey(raw: entry.detail.model, agentIndex: entry.agentIndex)
            var source = sources[key, default: [:]][sourceKey] ?? SourceTotal()
            source.tokens += entry.detail.total
            if let cost = entry.detail.costUsd {
                source.cost = (source.cost ?? 0) + cost
            }
            sources[key, default: [:]][sourceKey] = source
        }
        let grandTotal = modelTotals.values.reduce(0, +)
        let summaries = modelTotals.map { key, total -> CanonicalModelSummary in
            let contributions = (sources[key] ?? [:])
                .sorted { lhs, rhs in
                    if lhs.value.tokens != rhs.value.tokens { return lhs.value.tokens > rhs.value.tokens }
                    if lhs.key.raw != rhs.key.raw { return lhs.key.raw < rhs.key.raw }
                    return lhs.key.agentIndex < rhs.key.agentIndex
                }
                .map { sourceKey, source in
                    let agent = agents[sourceKey.agentIndex]
                    return ModelSourceContribution(
                        rawModelName: sourceKey.raw,
                        agentID: agent.id,
                        agentDisplayName: agent.name,
                        tokens: source.tokens,
                        tokensText: PanelFormat.tokenCount(source.tokens),
                        costUsd: source.cost,
                        costText: source.cost.map(AnalyticsFormat.usd),
                        shareOfModelPercent: percent(source.tokens, of: total)
                    )
                }
            let priced = contributions.compactMap(\.costUsd)
            let cost: Double? = priced.isEmpty ? nil : priced.reduce(0, +)
            return CanonicalModelSummary(
                canonicalKey: key,
                displayName: ModelNormalizer.displayName(for: key),
                vendor: ModelNormalizer.vendor(for: key),
                colorHex: ModelNormalizer.colorHex(for: key),
                totalTokens: total,
                totalTokensText: PanelFormat.tokenCount(total),
                estimatedCostUsd: cost,
                costText: cost.map(AnalyticsFormat.usd),
                sharePercent: percent(total, of: grandTotal),
                sources: contributions
            )
        }
        return summaries.sorted {
            $0.totalTokens != $1.totalTokens ? $0.totalTokens > $1.totalTokens : $0.canonicalKey < $1.canonicalKey
        }
    }

    // MARK: - 时序

    private static func granularity(for range: AnalyticsTimeRange) -> AnalyticsTimelineGranularity {
        switch range {
        case .today: return .hour
        case .sevenDays, .thirtyDays, .thisMonth: return .day
        case .allTime: return .month
        }
    }

    private static func makeTimeline(
        range: AnalyticsTimeRange,
        agents: [AgentUsageItem],
        rangeDates: [String],
        topModelKeys: [String]
    ) -> AnalyticsTimeline {
        /// 模型序列只画范围 Top 5; 费用计全部明细桶 (未定价桶计 0).
        func addModels(_ details: [AgentModelDetail], into bucket: inout TimelineBucket) {
            for detail in details {
                let key = ModelNormalizer.canonicalKey(for: detail.model)
                if topModelKeys.contains(key) {
                    bucket.byModel[key, default: 0] += detail.total
                }
                bucket.cost += detail.costUsd ?? 0
            }
        }

        let granularity = granularity(for: range)
        var labeled: [(label: String, bucket: TimelineBucket)] = []
        switch granularity {
        case .hour:
            let hourDetailAvailable = agents.contains { $0.hourModels != nil }
            for hour in 0..<24 {
                var bucket = TimelineBucket()
                for agent in agents {
                    let value = hour < agent.hours.count ? agent.hours[hour] : 0
                    bucket.total += value
                    if value > 0 { bucket.byAgent[agent.id] = value }
                }
                if hourDetailAvailable {
                    let details = agents.flatMap { ($0.hourModels ?? []).filter { $0.hour == hour } }
                    bucket.types = (
                        input: details.reduce(0) { $0 + $1.input + $1.cacheCreation },
                        output: details.reduce(0) { $0 + $1.output },
                        cache: details.reduce(0) { $0 + $1.cacheRead }
                    )
                    addModels(details, into: &bucket)
                }
                labeled.append((String(format: "%02d:00", hour), bucket))
            }
        case .day:
            for date in rangeDates {
                var bucket = dayBucket(agents: agents, dates: [date])
                addModels(agents.flatMap { ($0.dailyModels ?? []).filter { $0.date == date } }, into: &bucket)
                labeled.append((String(date.suffix(5)), bucket))
            }
        case .month:
            var months: [String] = []
            for date in rangeDates where !months.contains(String(date.prefix(7))) {
                months.append(String(date.prefix(7)))
            }
            for month in months {
                var bucket = dayBucket(agents: agents, dates: rangeDates.filter { $0.hasPrefix(month) })
                addModels(agents.flatMap { ($0.monthModels ?? []).filter { $0.month == month } }, into: &bucket)
                labeled.append((month, bucket))
            }
        }

        let points = labeled.map { label, bucket -> AnalyticsTimelinePoint in
            var series = bucket.byAgent
            if let types = bucket.types {
                series["type_input"] = types.input
                series["type_output"] = types.output
                series["type_cache"] = types.cache
            }
            for (key, value) in bucket.byModel {
                series["model_" + key] = value
            }
            return AnalyticsTimelinePoint(label: label, totalTokens: bucket.total, costUsd: bucket.cost, seriesValues: series)
        }

        // 峰值取首个最大点 (全 0 时无峰值)
        var peak: AnalyticsTimelinePoint?
        for point in points where point.totalTokens > (peak?.totalTokens ?? 0) {
            peak = point
        }
        let sum = points.reduce(0) { $0 + $1.totalTokens }
        let average = points.isEmpty ? 0 : sum / points.count
        let (peakTitle, averageTitle): (String, String) = {
            switch granularity {
            case .hour: return ("峰值时段", "时均")
            case .day: return ("峰值", "日均")
            case .month: return ("峰值月", "月均")
            }
        }()
        return AnalyticsTimeline(
            granularity: granularity,
            points: points,
            peakSummary: peak.map {
                "🔥 \(peakTitle): **\($0.label)** (\(PanelFormat.tokenCount($0.totalTokens)) Tokens)"
            } ?? "—",
            avgSummary: "\(averageTitle): **\(PanelFormat.tokenCount(average))** Tokens"
        )
    }

    /// 若干自然日合计: Agent 序列与 Token 构成取自 `daily`; 任一天缺缓存拆分 (旧 artifact) 时不出构成.
    private static func dayBucket(agents: [AgentUsageItem], dates: [String]) -> TimelineBucket {
        var bucket = TimelineBucket()
        var types = (input: 0, output: 0, cache: 0)
        var typesAvailable = true
        for agent in agents {
            var agentTotal = 0
            for day in agent.daily where dates.contains(day.date) {
                agentTotal += day.total
                if day.cacheRead == nil || day.cacheCreation == nil { typesAvailable = false }
                let tokens = Tokens(day: day)
                types.input += tokens.input + tokens.cacheCreation
                types.output += tokens.output
                types.cache += tokens.cacheRead
            }
            bucket.total += agentTotal
            if agentTotal > 0 { bucket.byAgent[agent.id] = agentTotal }
        }
        bucket.types = typesAvailable ? types : nil
        return bucket
    }

    // MARK: - Agent 对比

    private static func makeAgentCards(
        range: AnalyticsTimeRange,
        agents: [AgentUsageItem],
        agentTokens: [Tokens],
        entries: [Entry],
        detailAvailable: Bool
    ) -> [AnalyticsAgentCardItem] {
        let rangeTotal = agentTokens.reduce(0) { $0 + $1.total }
        let cards = agents.indices.compactMap { index -> (Int, AnalyticsAgentCardItem)? in
            let tokens = agentTokens[index]
            guard tokens.total > 0 else { return nil }
            let agent = agents[index]
            let own = entries.filter { $0.agentIndex == index }
            return (index, AnalyticsAgentCardItem(
                agentID: agent.id,
                name: agent.name,
                status: agent.status,
                note: agent.note,
                totalTokens: tokens.total,
                costUsd: detailAvailable ? pricedSum(own, \.costUsd) : nil,
                sharePercent: percent(tokens.total, of: rangeTotal),
                // 比例条三段 (输入含缓存写入 / 输出 / 缓存读取) 之和 = 总量
                inputTokens: tokens.input + tokens.cacheCreation,
                outputTokens: tokens.output,
                cacheReadTokens: tokens.cacheRead,
                cacheCreationTokens: tokens.cacheCreation,
                colorHex: PanelAgentColor.resolve(agentID: agent.id).hex,
                // collector 只采集今日项目分布, 其他范围不冒用
                topProjects: range == .today ? (agent.projects ?? []) : [],
                topModels: canonicalModels(entries: own, agents: agents)
            ))
        }
        return cards
            .sorted { $0.1.totalTokens != $1.1.totalTokens ? $0.1.totalTokens > $1.1.totalTokens : $0.0 < $1.0 }
            .map(\.1)
    }
}
