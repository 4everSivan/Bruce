import Foundation

// 仪表盘订阅卡空状态 (C157): 只做「未配置」与「已配置但无数据」两态.
// 明确不引入「待验证 / 已停用」第三态; 有配置但尚未生效的订阅一律归入未配置,
// 避免在仪表盘上暴露半配置状态.
//
// 输入全部来自 AppModel 已有快照, 不读取凭证或 artifact 内容; 缺失 artifact 时
// 返回 nil, 由既有的全局「未配置模块」兜底承接.

package enum SubscriptionEmptyStateReason: Equatable, Sendable {
    /// 没有任何在仪表盘可见的订阅配置 (含从未添加、仅添加未验证、全部停用).
    case notConfigured
    /// 至少一个 Provider 已启用且验证通过, 但本次采集没有返回任何订阅 section.
    case noData
}

package struct SubscriptionEmptyStateViewModel: Equatable, Sendable {
    package let reason: SubscriptionEmptyStateReason
    /// 标题行右槽状态词.
    package let statusText: String
    package let title: String
    package let message: String
    package let actionTitle: String
    package let systemImage: String

    package init(
        reason: SubscriptionEmptyStateReason,
        statusText: String,
        title: String,
        message: String,
        actionTitle: String,
        systemImage: String
    ) {
        self.reason = reason
        self.statusText = statusText
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.systemImage = systemImage
    }
}

package enum SubscriptionEmptyStatePolicy {
    /// - Parameters:
    ///   - hasArtifact: 当前是否存在经门禁过滤后的 agentUsage artifact.
    ///   - hasSubscription: 映射层是否已产出订阅卡.
    ///   - eligibleProviderCount: 已启用 ∧ 验证通过 ∧ 非临时屏蔽 的 Provider 数.
    package static func resolve(
        hasArtifact: Bool,
        hasSubscription: Bool,
        eligibleProviderCount: Int
    ) -> SubscriptionEmptyStateViewModel? {
        guard hasArtifact, !hasSubscription else {
            return nil
        }
        if eligibleProviderCount > 0 {
            return SubscriptionEmptyStateViewModel(
                reason: .noData,
                statusText: "无数据",
                title: "暂未获取到额度",
                message: "这次采集没有返回订阅额度，可手动刷新重试。",
                actionTitle: "刷新额度",
                systemImage: "arrow.clockwise"
            )
        }
        return SubscriptionEmptyStateViewModel(
            reason: .notConfigured,
            statusText: "未配置",
            title: "尚未添加订阅",
            message: "添加并验证账号后，显示 5 小时与每周额度。",
            actionTitle: "添加订阅",
            systemImage: "creditcard"
        )
    }
}
