import Foundation

/// 状态预警单一投递出口 (design/03 规则 14, T30).
///
/// - quota 与 egress 事件由调度器合并为一个批次, 此处只做一次展示;
/// - quota 事件以共享决策内核的 `eventId` 去重 (TTL 10 分钟), 防止重试/双路径重复;
/// - egress 仍由调度器边沿状态机去重, 此处原样放行.
@MainActor
package final class StatusAlertCenter {
    private let dedupeTTL: TimeInterval = 600
    private var seen: [String: Date] = [:]
    private let present: ([StatusBubbleAlertItem]) -> Void

    package init(present: @escaping ([StatusBubbleAlertItem]) -> Void) {
        self.present = present
    }

    package func deliver(_ items: [StatusBubbleAlertItem]) {
        guard !items.isEmpty else { return }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < dedupeTTL }

        var fresh: [StatusBubbleAlertItem] = []
        for item in items {
            if case .quota(let alert) = item, let eventId = alert.eventId {
                if seen[eventId] != nil {
                    continue
                }
                seen[eventId] = now
            }
            fresh.append(item)
        }
        guard !fresh.isEmpty else { return }
        present(fresh)
    }
}
