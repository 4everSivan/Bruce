import Foundation

package enum MenuBarMetric: String, CaseIterable, Codable, Identifiable, Sendable {
    case minimumRemainingQuota
    case averageRemainingQuota
    case todayTokens
    case todayCost
    case overallStatus

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .minimumRemainingQuota:
            return "最低剩余额度"
        case .averageRemainingQuota:
            return "平均剩余额度"
        case .todayTokens:
            return "今日 Token"
        case .todayCost:
            return "今日费用"
        case .overallStatus:
            return "综合状态"
        }
    }

    package var systemImage: String {
        switch self {
        case .minimumRemainingQuota:
            return "gauge.with.dots.needle.33percent"
        case .averageRemainingQuota:
            return "chart.bar.xaxis"
        case .todayTokens:
            return "number"
        case .todayCost:
            return "dollarsign.circle"
        case .overallStatus:
            return "waveform.path.ecg"
        }
    }
}

package struct MenuBarMetricConfiguration: Equatable, Sendable {
    package static let maximumCount = 3
    package static let defaultMetrics: [MenuBarMetric] = [
        .minimumRemainingQuota,
        .todayTokens,
        .todayCost,
    ]

    package let metrics: [MenuBarMetric]

    package init(rawValues: [String]?) {
        let decoded = (rawValues ?? []).compactMap(MenuBarMetric.init(rawValue:))
        self.metrics = Self.normalize(decoded)
    }

    package init(metrics: [MenuBarMetric]) {
        self.metrics = Self.normalize(metrics)
    }

    package static func normalize(
        _ metrics: [MenuBarMetric]
    ) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        let unique = metrics.filter { seen.insert($0).inserted }
        let limited = Array(unique.prefix(maximumCount))
        return limited.isEmpty ? defaultMetrics : limited
    }
}

package struct MenuBarSummary: Equatable, Sendable {
    package let minimumRemainingQuota: Double?
    package let averageRemainingQuota: Double?
    package let todayTokens: Int?
    package let todayCostUsd: Double?
    package let overallStatus: ModuleRunState
}

package struct MenuBarSummaryBuilder {
    package init() {}

    package func build(
        agentArtifact: JSONValue?,
        moduleStatuses: [DashboardModule: ModuleStatus]
    ) -> MenuBarSummary {
        let decoded = decodedAgentUsage(agentArtifact)
        let remainingPercentages = decoded.map(validRemainingPercentages) ?? []
        let minimum = remainingPercentages.min()
        let average = remainingPercentages.isEmpty
            ? nil
            : remainingPercentages.reduce(0, +)
                / Double(remainingPercentages.count)
        let tokens = decoded.map {
            $0.agents.reduce(0) { $0 + $1.today.total }
        }

        return MenuBarSummary(
            minimumRemainingQuota: minimum,
            averageRemainingQuota: average,
            todayTokens: tokens,
            todayCostUsd: decoded?.totalCostUsd,
            overallStatus: overallStatus(moduleStatuses)
        )
    }

    private func decodedAgentUsage(
        _ artifact: JSONValue?
    ) -> AgentUsageArtifact? {
        guard let artifact,
              case .agentUsage(let decoded) = try? ArtifactValidator().validate(
                  artifact,
                  for: .agentUsage
              ) else {
            return nil
        }
        return decoded
    }

    private func validRemainingPercentages(
        _ artifact: AgentUsageArtifact
    ) -> [Double] {
        artifact.services.flatMap { service -> [Double] in
            guard !["error", "failed"].contains(service.status.lowercased()) else {
                return []
            }
            return service.windows.compactMap { window in
                guard case .object(let object) = window,
                      let used = numericValue(object["usedPercent"]),
                      used.isFinite,
                      (0...100).contains(used) else {
                    return nil
                }
                return 100 - used
            }
        }
    }

    private func numericValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .integer(let number):
            return Double(number)
        case .double(let number):
            return number
        default:
            return nil
        }
    }

    private func overallStatus(
        _ statuses: [DashboardModule: ModuleStatus]
    ) -> ModuleRunState {
        DashboardModule.allCases
            .filter { $0 != .settings }
            .compactMap { statuses[$0]?.state }
            .max { statusPriority($0) < statusPriority($1) }
            ?? .notConfigured
    }

    private func statusPriority(_ state: ModuleRunState) -> Int {
        switch state {
        case .fresh:
            return 0
        case .ready:
            return 1
        case .notConfigured:
            return 2
        case .refreshing:
            return 3
        case .stale:
            return 4
        case .partial:
            return 5
        case .offline:
            return 6
        case .authRequired:
            return 7
        case .failed:
            return 8
        }
    }
}

package struct MenuBarMetricFormatter {
    package init() {}

    package func string(
        for metric: MenuBarMetric,
        summary: MenuBarSummary
    ) -> String {
        switch metric {
        case .minimumRemainingQuota:
            return percentage(summary.minimumRemainingQuota)
        case .averageRemainingQuota:
            return percentage(summary.averageRemainingQuota)
        case .todayTokens:
            return compactCount(summary.todayTokens)
        case .todayCost:
            return currency(summary.todayCostUsd)
        case .overallStatus:
            return summary.overallStatus.title
        }
    }

    private func percentage(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    private func compactCount(_ value: Int?) -> String {
        guard let value else { return "--" }
        if value < 1_000 {
            return "\(value)"
        }
        if value < 1_000_000 {
            return compact(Double(value) / 1_000) + "k"
        }
        return compact(Double(value) / 1_000_000) + "M"
    }

    private func currency(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        let fractionDigits = value > 0 && value < 0.01 ? 3 : 2
        return String(format: "$%.*f", fractionDigits, value)
    }

    private func compact(_ value: Double) -> String {
        if value >= 100 || value.rounded() == value {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}
