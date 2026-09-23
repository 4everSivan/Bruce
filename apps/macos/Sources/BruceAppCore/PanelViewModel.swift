import Foundation

// 菜单栏液态玻璃面板的 artifact -> view model 映射入口.
// 纯逻辑, 不含 SwiftUI 视图代码; 模型见 PanelModels, 规则见 SubscriptionPresentationPolicy,
// 用量/订阅映射见 UsageMapping / SubscriptionMapping.

// MARK: - 映射器

package struct PanelViewModelMapper: Sendable {
    /// LIVE 判定阈值, 默认覆盖 30 分钟刷新周期加缓冲.
    package var liveThreshold: TimeInterval
    package var now: @Sendable () -> Date
    package var calendar: Calendar

    package init(
        liveThreshold: TimeInterval = 45 * 60,
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.liveThreshold = liveThreshold
        self.now = now
        self.calendar = calendar
    }

    package func make(
        agentUsage: AgentUsageArtifact?,
        moduleStatuses: [DashboardModule: ModuleStatus],
        deepSeekMonthlyUsage: DeepSeekMonthlyUsage? = nil,
        providerOrder: [String] = []
    ) -> PanelViewModel {
        var diagnostics: [PanelDiagnostic] = []
        let currentNow = now()

        var usage: UsageHeroViewModel?
        var subscription: SubscriptionViewModel?
        var hourly: HourlyLineViewModel?
        if let agentUsage {
            usage = makeUsage(agentUsage, now: currentNow, diagnostics: &diagnostics)
            subscription = makeSubscription(
                agentUsage,
                now: currentNow,
                deepSeekMonthlyUsage: deepSeekMonthlyUsage,
                providerOrder: providerOrder,
                diagnostics: &diagnostics
            )
            hourly = makeHourly(agentUsage, diagnostics: &diagnostics)
        } else {
            diagnostics.append(.missingArtifact(module: .agentUsage))
        }

        return PanelViewModel(
            usage: usage,
            subscription: subscription,
            hourly: hourly,
            diagnostics: diagnostics
        )
    }

    // MARK: 工具

    func normalizedNote(_ note: String?) -> String? {
        guard let note, !note.isEmpty else {
            return nil
        }
        return note
    }

    static func parseISODate(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    static func parseResetDate(_ value: JSONValue) -> Date? {
        switch value {
        case .integer(let seconds):
            // 非正 epoch (如火山未开始窗口的 ResetTimestamp=-1) 视为无重置时间, 避免解析成 1970.
            return seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
        case .double(let seconds):
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case .string(let text):
            return parseISODate(text)
        default:
            return nil
        }
    }
}
