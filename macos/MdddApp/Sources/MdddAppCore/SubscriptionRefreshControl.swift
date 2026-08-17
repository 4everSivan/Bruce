import Foundation
import MdddOnboardingCore

// MARK: - 订阅卡 Provider 定向刷新按钮 (UI 契约纯逻辑)
//
// 契约来源: openspec/changes/subscription-provider-refresh/design.md
// 「UI Contract」及父 issue 2026-08-17 发布的最终执行契约 (Haven Shen 已确认):
// - Provider header 行尾独立 arrow.clockwise 按钮, 单/多账号位置统一;
//   多账号名称+chevron 独占展开/折叠, 刷新按钮是兄弟控件, 点击不改变折叠状态.
// - 目标 Provider 刷新中: 小型进度指示 + 禁用, VoiceOver 改「正在刷新 …」.
// - 全量 agentUsage 刷新中: 所有 Provider 刷新按钮禁用, 不重复启动.
// - 未配置 / 未启用 / 当前 module 不可运行: 禁用.
// - accessibilityLabel: 「刷新 <Provider 名称> 订阅额度」;
//   进行中: 「正在刷新 <Provider 名称> 订阅额度」.

/// Provider header 刷新按钮的呈现快照. 纯值, 供 SwiftUI 渲染与 harness 断言.
package struct SubscriptionRefreshControlPresentation: Equatable, Sendable {
    /// 目标 Provider 定向刷新进行中 (显示小型进度指示).
    package let showsProgress: Bool
    /// 按钮是否可点击.
    package let isEnabled: Bool
    /// VoiceOver 标签 (契约锁定文案).
    package let accessibilityLabel: String
    /// VoiceOver 补充说明.
    package let accessibilityHint: String

    package init(
        showsProgress: Bool,
        isEnabled: Bool,
        accessibilityLabel: String,
        accessibilityHint: String
    ) {
        self.showsProgress = showsProgress
        self.isEnabled = isEnabled
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
    }
}

package enum SubscriptionRefreshControlPolicy {
    /// 从订阅卡 section ID 解析定向刷新目标 Provider.
    /// 单账号 section ID 可能是带账号后缀的 serviceID (如 codex_<hash>),
    /// 多账号分组 section ID 即 provider rawValue; 统一经展示策略归一化.
    /// 无法归一为已知 Provider 时返回 nil (fail-closed: 不渲染按钮, 不猜测目标).
    package static func providerID(forSectionID sectionID: String) -> SubscriptionProviderID? {
        SubscriptionProviderID(
            rawValue: SubscriptionPresentationPolicy.providerID(forServiceID: sectionID)
        )
    }

    /// 按契约计算按钮呈现. 目标刷新中优先展示进度; 禁用取
    /// 「目标刷新中 / 全量刷新中 / 不可运行」的并集.
    package static func make(
        displayName: String,
        isProviderRefreshing: Bool,
        isFullRefreshRunning: Bool,
        isRunnable: Bool
    ) -> SubscriptionRefreshControlPresentation {
        SubscriptionRefreshControlPresentation(
            showsProgress: isProviderRefreshing,
            isEnabled: isRunnable && !isProviderRefreshing && !isFullRefreshRunning,
            accessibilityLabel: isProviderRefreshing
                ? "正在刷新 \(displayName) 订阅额度"
                : "刷新 \(displayName) 订阅额度",
            accessibilityHint: "只重新查询 \(displayName) 的订阅额度, 不影响其他订阅与本地统计"
        )
    }
}
