import Foundation

/// 状态栏按钮需要的原生 AppKit 内容.
///
/// 这里故意只保留图标名、紧凑指标文本和辅助功能文案, 不依赖 AppKit 或
/// SwiftUI. 状态项控制器可以直接把这些值交给 `NSStatusBarButton`, 避免
/// 用 SwiftUI `ImageRenderer` 生成一个可能是透明或零宽的状态项图像.
package struct MenuBarStatusItemContent: Equatable, Sendable {
    package let iconName: String
    package let metricText: String
    package let accessibilityLabel: String
    package let remainingQuotaRatio: Double?

    package init(
        iconName: String,
        metricText: String,
        accessibilityLabel: String,
        remainingQuotaRatio: Double? = nil
    ) {
        self.iconName = iconName
        self.metricText = metricText
        self.accessibilityLabel = accessibilityLabel
        self.remainingQuotaRatio = remainingQuotaRatio
    }
}

package struct MenuBarStatusItemContentBuilder {
    private let formatter: MenuBarMetricFormatter

    package init() {
        formatter = MenuBarMetricFormatter()
    }

    package func build(
        metrics: [MenuBarMetric],
        summary: MenuBarSummary,
        isRefreshing: Bool,
        iconOnly: Bool = false
    ) -> MenuBarStatusItemContent {
        // 环规配额取数逻辑:
        // 1. 若配置中显式包含“最低剩余额度”, 遵从用户偏好取最低额度;
        // 2. 其余情况 (包含未选额度、仅图标模式、或选了平均额度), 取“总订阅配额”平均值,
        //    避免单一耗尽子窗口将整个菜单栏环规置空.
        let quotaPercentage: Double?
        if metrics.contains(.minimumRemainingQuota) {
            quotaPercentage = summary.minimumRemainingQuota ?? summary.averageRemainingQuota
        } else {
            quotaPercentage = summary.averageRemainingQuota ?? summary.minimumRemainingQuota
        }
        let quotaRatio = quotaPercentage.map { max(0.0, min(100.0, $0)) / 100.0 }

        let formattedMetrics = iconOnly ? [] : metrics.map { metric in
            (metric, formatter.string(for: metric, summary: summary))
        }
        let metricText = formattedMetrics
            .map { "\($0.1)" }
            .joined(separator: "  ")
        let accessibilityMetrics = formattedMetrics
            .map { "\($0.0.title) \($0.1)" }

        return MenuBarStatusItemContent(
            iconName: iconName(
                for: summary.overallStatus,
                isRefreshing: isRefreshing
            ),
            metricText: metricText,
            accessibilityLabel: accessibilityLabel(
                for: summary,
                metrics: accessibilityMetrics,
                isRefreshing: isRefreshing,
                quotaPercentage: quotaPercentage
            ),
            remainingQuotaRatio: quotaRatio
        )
    }

    private func iconName(
        for status: ModuleRunState,
        isRefreshing: Bool
    ) -> String {
        if isRefreshing {
            return "arrow.clockwise"
        }

        switch status {
        case .fresh, .ready:
            return "gauge"
        case .refreshing:
            return "arrow.clockwise"
        case .partial, .stale, .authRequired:
            return "exclamationmark.triangle"
        case .failed:
            return "xmark.circle"
        case .notConfigured:
            return "circle.dashed"
        }
    }

    private func accessibilityLabel(
        for summary: MenuBarSummary,
        metrics: [String],
        isRefreshing: Bool,
        quotaPercentage: Double?
    ) -> String {
        let statusTitle = isRefreshing
            ? ModuleRunState.refreshing.title
            : summary.overallStatus.title
        var parts = ["Bruce", statusTitle]
        if let quota = quotaPercentage {
            parts.append("总配额 \(Int(quota.rounded()))%")
        }
        parts.append(contentsOf: metrics)
        return parts.joined(separator: ", ")
    }
}
