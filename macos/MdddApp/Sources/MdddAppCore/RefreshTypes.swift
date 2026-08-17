import Foundation
import MdddOnboardingCore

/// 刷新触发原因; 与 `RefreshScope` 正交, 描述"为什么刷新"而非"刷新什么".
package enum RefreshTriggerReason: Equatable, Sendable {
    case timer
    case manual
    case wake
}

/// 刷新范围: 全量 (`all`) 或定向到一组订阅 Provider (`subscriptionProviders`).
///
/// 定向范围把刷新目标从隐含的「整个 agentUsage」提升为显式集合; 定向运行
/// 仍走同一条调度/执行/发布链路, 只在 Collector 输入与快照合并阶段缩窄到目标.
package enum RefreshScope: Equatable, Sendable {
    /// 整个 agentUsage 模块 (默认, 与历史全量刷新语义一致).
    case all
    /// 定向到指定订阅 Provider 集合 (去重, 非空).
    case subscriptionProviders(Set<SubscriptionProviderID>)
}

extension RefreshScope {
    /// 定向目标 Provider 集合 (`.all` 返回空集).
    package var targetProviders: Set<SubscriptionProviderID> {
        switch self {
        case .all:
            return []
        case .subscriptionProviders(let providers):
            return providers
        }
    }

    /// 是否定向刷新 (仅含一个或一组 Provider, 不含整个模块).
    package var isTargeted: Bool {
        switch self {
        case .all:
            return false
        case .subscriptionProviders:
            return true
        }
    }
}

/// 单个订阅 Provider 的定向刷新状态回调 (独立于模块级 run state).
///
/// 设计: 定向刷新仍走模块级 `refreshing` 状态, 但按钮只消费目标 Provider 的
/// 该状态, 不消费 `busySubscriptionProviders` (凭证导入 busy), 避免凭证导入
/// 进行中被误显示为额度刷新.
package enum SubscriptionRefreshState: Equatable, Sendable {
    case started
    case finished
    case failed
    case cancelled
}

package struct RefreshIntent: Equatable, Sendable {
    package var reason: RefreshTriggerReason
    package var includesManual: Bool
    /// 刷新范围; 默认 `.all` 保持历史全量调用方源码兼容.
    package var scope: RefreshScope

    package init(
        reason: RefreshTriggerReason,
        includesManual: Bool,
        scope: RefreshScope = .all
    ) {
        self.reason = reason
        self.includesManual = includesManual
        self.scope = scope
    }

    package static func manual() -> RefreshIntent {
        RefreshIntent(reason: .manual, includesManual: true)
    }

    package static func timer() -> RefreshIntent {
        RefreshIntent(reason: .timer, includesManual: false)
    }

    package static func wake() -> RefreshIntent {
        RefreshIntent(reason: .wake, includesManual: false)
    }

    /// 构造定向刷新意图 (单 Provider 按钮点击入口).
    package static func subscription(_ provider: SubscriptionProviderID) -> RefreshIntent {
        RefreshIntent(
            reason: .manual,
            includesManual: true,
            scope: .subscriptionProviders([provider])
        )
    }
}

package enum RefreshIntentMerge {
    package static func merge(existing: RefreshIntent?, incoming: RefreshIntent) -> RefreshIntent {
        guard let existing else { return incoming }
        let includesManual = existing.includesManual
            || incoming.includesManual
            || existing.reason == .manual
            || incoming.reason == .manual
        let reason: RefreshTriggerReason
        if includesManual {
            reason = .manual
        } else {
            reason = existing.reason
        }
        // 范围合并契约:
        // - 任一全量意图优先: 一次全量刷新不被局部请求削弱.
        // - 两个定向意图按 Provider 集合取并集 (去重).
        // - 全量 + 定向 = 全量.
        let scope: RefreshScope
        switch (existing.scope, incoming.scope) {
        case (.all, _), (_, .all):
            scope = .all
        case let (.subscriptionProviders(a), .subscriptionProviders(b)):
            scope = .subscriptionProviders(a.union(b))
        }
        return RefreshIntent(
            reason: reason,
            includesManual: includesManual,
            scope: scope
        )
    }
}
