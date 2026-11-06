import Foundation
@testable import BruceAppCore

// MARK: - 单一投递出口去重 (T30)

extension RefreshSchedulerHarness {
    static func statusAlertCenterDeduplicatesQuotaEvents() throws {
        var shown: [[StatusBubbleAlertItem]] = []
        let center = StatusAlertCenter { shown.append($0) }

        func quota(eventId: String, tier: Int) -> StatusBubbleAlertItem {
            .quota(QuotaAlert(
                serviceID: "claude_acc",
                serviceName: "Claude",
                windowLabel: "每 5 小时",
                usedPercent: 64,
                tier: tier,
                eventId: eventId
            ))
        }

        let first = quota(eventId: "claude_acc|five_hour|epoch:1000|50", tier: 50)
        center.deliver([first])
        center.deliver([first])
        try refreshExpect(shown.count == 1, "相同 eventId 只能展示一次")

        center.deliver([quota(eventId: "claude_acc|five_hour|epoch:1000|80", tier: 80)])
        try refreshExpect(shown.count == 2, "不同 eventId 应放行")

        // egress 不在中心去重, 由调度器边沿状态机负责.
        let egress = StatusBubbleAlertItem.egressIssue(EgressAlertItem(
            serviceID: "codex",
            serviceName: "Codex",
            badgeText: "⚠️ 国内直连"
        ))
        center.deliver([egress])
        center.deliver([egress])
        try refreshExpect(shown.count == 4, "egress 由调度器去重, 中心不拦截")
    }
}
