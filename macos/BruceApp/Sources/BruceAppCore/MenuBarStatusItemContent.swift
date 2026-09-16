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

    package init(
        iconName: String,
        metricText: String,
        accessibilityLabel: String
    ) {
        self.iconName = iconName
        self.metricText = metricText
        self.accessibilityLabel = accessibilityLabel
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
        isRefreshing: Bool
    ) -> MenuBarStatusItemContent {
        let formattedMetrics = metrics.map { metric in
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
                isRefreshing: isRefreshing
            )
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
        isRefreshing: Bool
    ) -> String {
        let statusTitle = isRefreshing
            ? ModuleRunState.refreshing.title
            : summary.overallStatus.title
        return (["Bruce", statusTitle] + metrics).joined(separator: ", ")
    }
}
