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

        let monthly = makeUsageMonthly(artifact)
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
            isLive: isLive,
            heatmap: makeUsageHeatmap(artifact),
            monthly: monthly.months,
            halfYear: monthly.summary
        )
    }

    // MARK: 按月统计

    /// 按日历月 (yyyy-MM) 聚合全量 daily, 保留最近 6 个月, 末位为当月;
    /// 半年总量为窗口全部 daily 之和, 月均按实际覆盖月数平均.
    func makeUsageMonthly(
        _ artifact: AgentUsageArtifact
    ) -> (months: [UsageMonthlyTotal], summary: UsageHalfYearSummary?) {
        var totalsByMonth: [String: Int] = [:]
        var grandTotal = 0
        for agent in artifact.agents {
            for day in agent.daily {
                let key = String(day.date.prefix(7)) // "yyyy-MM"
                guard key.count == 7 else { continue }
                totalsByMonth[key, default: 0] += day.total
                grandTotal += day.total
            }
        }
        let keys = Array(totalsByMonth.keys.sorted().suffix(6))
        guard let currentKey = keys.last else {
            return ([], nil)
        }
        let months = keys.map { key in
            UsageMonthlyTotal(
                label: Self.monthLabel(key),
                totalText: PanelFormat.tokenCount(totalsByMonth[key] ?? 0),
                isCurrent: key == currentKey
            )
        }
        let summary = UsageHalfYearSummary(
            totalText: PanelFormat.tokenCount(grandTotal),
            averageText: PanelFormat.tokenCount(grandTotal / keys.count)
        )
        return (months, summary)
    }

    /// "2026-07" -> "7月" (去掉年份与前导零, 跨年月份自然区分).
    private static func monthLabel(_ key: String) -> String {
        let month = key.suffix(2)
        let trimmed = month.hasPrefix("0") ? month.suffix(1) : month
        return "\(trimmed)月"
    }

    // MARK: 用量热力图

    /// 全量 daily 窗口 (不 suffix 14) 按周列 × 周日行 (周一起) 组织;
    /// level 按窗口峰值 1/25%/50%/75% 分 0-4 档, 窗口外与未来格为 nil.
    /// 日期解析与网格使用 mapper 注入的 calendar 时区, 保证测试可替换.
    func makeUsageHeatmap(_ artifact: AgentUsageArtifact) -> [UsageHeatmapWeek] {
        var totalsByDate: [String: Int] = [:]
        for agent in artifact.agents {
            for day in agent.daily {
                totalsByDate[day.date, default: 0] += day.total
            }
        }
        let dates = totalsByDate.keys.sorted()
        var gridCalendar = calendar
        gridCalendar.firstWeekday = 2 // 周一
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = gridCalendar.timeZone
        guard let first = dates.first, let last = dates.last,
              let firstDate = formatter.date(from: first),
              let lastDate = formatter.date(from: last) else {
            return []
        }
        let maxTotal = totalsByDate.values.max() ?? 0
        // 首日所在周的周一作为网格起点.
        guard let gridStart = gridCalendar.dateInterval(
            of: .weekOfYear, for: firstDate
        )?.start else {
            return []
        }
        var weeks: [UsageHeatmapWeek] = []
        var weekStart = gridStart
        while weekStart <= lastDate {
            var cells: [UsageHeatmapCell?] = []
            for offset in 0..<7 {
                guard let date = gridCalendar.date(
                    byAdding: .day, value: offset, to: weekStart
                ), date >= firstDate, date <= lastDate else {
                    cells.append(nil)
                    continue
                }
                let key = formatter.string(from: date)
                let total = totalsByDate[key] ?? 0
                cells.append(UsageHeatmapCell(
                    date: key,
                    total: total,
                    level: Self.heatmapLevel(total: total, maxTotal: maxTotal)
                ))
            }
            weeks.append(UsageHeatmapWeek(cells: cells))
            guard let next = gridCalendar.date(byAdding: .day, value: 7, to: weekStart) else {
                break
            }
            weekStart = next
        }
        return weeks
    }

    private static func heatmapLevel(total: Int, maxTotal: Int) -> Int {
        guard total > 0, maxTotal > 0 else { return 0 }
        let ratio = Double(total) / Double(maxTotal)
        if ratio >= 0.75 { return 4 }
        if ratio >= 0.50 { return 3 }
        if ratio >= 0.25 { return 2 }
        return 1
    }

    // MARK: 逐小时卡

    func makeHourly(
        _ artifact: AgentUsageArtifact,
        diagnostics: inout [PanelDiagnostic]
    ) -> HourlyLineViewModel {
        // 柱状图下方只显示今日有量的 agent; 其余 (含 ok 但今日闲置,
        // 或仅窗口内有历史量) 不显示, not_found 等状态由用量卡诊断覆盖.
        let rows = artifact.agents
            .filter { $0.today.total > 0 }
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
