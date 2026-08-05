import Foundation

// MARK: - Usage / Hourly mapping

extension PanelViewModelMapper {
    // MARK: 用量卡

    func makeUsage(
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

    // MARK: 逐小时卡

    func makeHourly(
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
    func hourlyDisplayName(id: String, fallback: String) -> String {
        id == "kimi-code-cli" ? "Kimi Code" : fallback
    }

    /// Top N + 其他聚合; base 为分组总量 (份额分母).
    /// models 的 entries 覆盖全部模型, 其他 = Top N 之外的余量;
    /// projects 的 entries 只有 Top 3, 其他 = 今日总量与已知的差值.
    static func topDistribution(
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
}
