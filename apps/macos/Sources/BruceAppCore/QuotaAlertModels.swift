import Foundation

/// 后台刷新额度预警的一条展示内容 (由共享决策内核的事件转换, T30).
package struct QuotaAlert: Equatable, Sendable {
    package let serviceID: String
    package let serviceName: String
    package let windowLabel: String
    package let usedPercent: Double
    package let tier: Int
    package let providerID: String?
    package let resetText: String?
    package let resetsAt: String?
    /// 窗口重置时刻归一化 token (整数 epoch 秒 / 原始字符串).
    /// 与展示字段 `resetsAt` 分离: 后者只承载可直接渲染的字符串形态.
    package let resetToken: String?
    /// 共享决策内核生成的事件 ID; 旧评估路径为 nil.
    package let eventId: String?

    package init(
        serviceID: String = "",
        serviceName: String,
        windowLabel: String,
        usedPercent: Double,
        tier: Int = 80,
        providerID: String? = nil,
        resetText: String? = nil,
        resetsAt: String? = nil,
        resetToken: String? = nil,
        eventId: String? = nil
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.windowLabel = windowLabel
        self.usedPercent = usedPercent
        self.tier = tier
        self.providerID = providerID
        self.resetText = resetText
        self.resetsAt = resetsAt
        self.resetToken = resetToken
        self.eventId = eventId
    }
}
