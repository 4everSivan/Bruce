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
    package let outerQuotaRatio: Double?
    package let innerQuotaRatio: Double?
    package let subscriptionQuotaRatio: Double?
    package let isNothingTheme: Bool

    package init(
        iconName: String,
        metricText: String,
        accessibilityLabel: String,
        remainingQuotaRatio: Double? = nil,
        outerQuotaRatio: Double? = nil,
        innerQuotaRatio: Double? = nil,
        subscriptionQuotaRatio: Double? = nil,
        isNothingTheme: Bool = false
    ) {
        self.iconName = iconName
        self.metricText = metricText
        self.accessibilityLabel = accessibilityLabel
        let resolvedSubRatio = subscriptionQuotaRatio ?? outerQuotaRatio ?? remainingQuotaRatio ?? innerQuotaRatio
        self.subscriptionQuotaRatio = resolvedSubRatio
        self.remainingQuotaRatio = remainingQuotaRatio ?? innerQuotaRatio ?? outerQuotaRatio ?? resolvedSubRatio
        self.outerQuotaRatio = outerQuotaRatio ?? resolvedSubRatio
        self.innerQuotaRatio = innerQuotaRatio ?? resolvedSubRatio
        self.isNothingTheme = isNothingTheme
    }
}

/// C183: 德系包豪斯单轨星规三档色阶动力学枚举
package enum MenuBarQuotaTier: Sendable, Equatable {
    case healthy   // > 50% (翡翠绿)
    case warning   // 20%...50% (警示琥珀橙)
    case critical  // < 20% (科技红)

    package static func tier(for ratio: Double?) -> MenuBarQuotaTier {
        guard let ratio else { return .healthy }
        if ratio < 0.20 { return .critical }
        if ratio <= 0.50 { return .warning }
        return .healthy
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
        iconOnly: Bool = false,
        isNothingTheme: Bool = false
    ) -> MenuBarStatusItemContent {
        // C183: 包豪斯单轨星规配额计算:
        // - 单轨与卫星点: 映射整体订阅剩余额度 (summary.averageRemainingQuota ?? summary.minimumRemainingQuota)
        let avgQuotaPercentage = summary.averageRemainingQuota ?? summary.minimumRemainingQuota
        let minQuotaPercentage = summary.minimumRemainingQuota ?? summary.averageRemainingQuota

        let subRatio = avgQuotaPercentage.map { max(0.0, min(100.0, $0)) / 100.0 }
        let outerRatio = subRatio
        let innerRatio = minQuotaPercentage.map { max(0.0, min(100.0, $0)) / 100.0 }

        let formattedMetrics = iconOnly ? [] : metrics.map { metric in
            (metric, formatter.string(for: metric, summary: summary, uppercaseUnit: isNothingTheme))
        }
        let separator = isNothingTheme ? " / " : "  "
        let metricText = formattedMetrics
            .map { "\($0.1)" }
            .joined(separator: separator)
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
                quotaPercentage: minQuotaPercentage ?? avgQuotaPercentage
            ),
            remainingQuotaRatio: subRatio ?? innerRatio,
            outerQuotaRatio: outerRatio,
            innerQuotaRatio: innerRatio,
            subscriptionQuotaRatio: subRatio,
            isNothingTheme: isNothingTheme
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
            parts.append("剩余额度 \(Int(quota.rounded()))%")
        }
        parts.append(contentsOf: metrics)
        return parts.joined(separator: ", ")
    }
}
