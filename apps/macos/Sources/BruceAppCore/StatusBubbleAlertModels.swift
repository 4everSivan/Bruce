import Foundation

// MARK: - 网络出口阻断微卡展示项

/// 网络出口校验阻断微卡展示项 (方案 A · 280pt 预警微气泡)
package struct EgressAlertItem: Equatable, Sendable {
    package let serviceID: String
    package let serviceName: String
    package let providerID: String?
    package let badgeText: String
    package let explanation: String
    package let reason: String?
    package let expected: String?
    package let observed: String?
    package let maskedIp: String?

    package init(
        serviceID: String,
        serviceName: String,
        providerID: String? = nil,
        badgeText: String,
        explanation: String = "已拦截海外查额以保护账号 · 保持快照",
        reason: String? = nil,
        expected: String? = nil,
        observed: String? = nil,
        maskedIp: String? = nil
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.providerID = providerID
        self.badgeText = badgeText
        self.explanation = explanation
        self.reason = reason
        self.expected = expected
        self.observed = observed
        self.maskedIp = maskedIp
    }
}

// MARK: - 通用状态预警气泡实体 (多态抽象)

/// 通用状态微气泡告警实体，支持额度超限与网络出口阻断多态
package enum StatusBubbleAlertItem: Equatable, Sendable, Identifiable {
    case quota(QuotaAlert)
    case egressIssue(EgressAlertItem)

    package var id: String {
        switch self {
        case .quota(let alert):
            return "quota|\(alert.serviceID)|\(alert.windowLabel)"
        case .egressIssue(let item):
            return "egress|\(item.serviceID)"
        }
    }

    package var serviceName: String {
        switch self {
        case .quota(let alert):
            return alert.serviceName
        case .egressIssue(let item):
            return item.serviceName
        }
    }

    package var providerID: String? {
        switch self {
        case .quota(let alert):
            return alert.providerID ?? alert.serviceID
        case .egressIssue(let item):
            return item.providerID ?? item.serviceID
        }
    }
}
