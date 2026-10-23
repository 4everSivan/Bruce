import Foundation

/// 仪表盘顶部 HUD 四色状态灯语义 (C100 / design 03 FR-7):
/// 绿 (ok) / 黄 (warn) / 红 (error) / 中性灰 (neutral), 严重度优先级 error > warn > ok > neutral.
package enum DashboardStatusTone: String, Codable, Equatable, Sendable, Comparable {
    case neutral
    case ok
    case warn
    case error

    private var severityRank: Int {
        switch self {
        case .neutral: return 0
        case .ok: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    package static func < (lhs: DashboardStatusTone, rhs: DashboardStatusTone) -> Bool {
        lhs.severityRank < rhs.severityRank
    }
}

/// 顶部状态灯单一判定结果: 灯色 + 是否处于刷新呼吸脉冲 + 悬停原因文案.
package struct DashboardStatusResolution: Equatable, Sendable {
    package let tone: DashboardStatusTone
    package let isRefreshing: Bool
    package let reason: String

    package init(tone: DashboardStatusTone, isRefreshing: Bool, reason: String) {
        self.tone = tone
        self.isRefreshing = isRefreshing
        self.reason = reason
    }
}

/// 订阅服务健康度输入: section 状态 + 服务名 (订阅侧最严重时 hover 原因据此点名服务).
package struct DashboardStatusSubscription: Equatable, Sendable {
    package let status: String
    package let name: String

    package init(status: String, name: String) {
        self.status = status
        self.name = name
    }
}

/// 双端同构的顶部状态灯纯函数判定器 (macOS 与 Windows `app.js` 逐字对齐, 由共享 fixture 对拍锁死).
package enum DashboardStatusToneResolver {
    /// 状态码 -> 中文态名 (双端统一词表).
    package static func statusLabel(for state: String) -> String {
        switch state {
        case "ok", "fresh":
            return "正常"
        case "ready":
            return "可刷新"
        case "refreshing", "loading":
            return "刷新中"
        case "partial":
            return "部分失败"
        case "failed":
            return "刷新失败"
        case "error":
            return "失败"
        case "stale":
            return "数据过期"
        case "unavailable":
            return "不可用"
        case "idle":
            return "等待刷新"
        case "empty":
            return "暂无数据"
        case "notConfigured":
            return "未配置"
        case "authRequired":
            return "需要授权"
        default:
            return state
        }
    }

    /// 采集态映射为灯色.
    private static func collectionTone(for moduleState: String, hasData: Bool) -> DashboardStatusTone {
        switch moduleState {
        case "failed", "error", "unavailable":
            return .error
        case "partial", "stale", "authRequired":
            return .warn
        case "fresh", "ready", "ok":
            return .ok
        case "idle", "refreshing", "loading":
            return hasData ? .ok : .neutral
        case "notConfigured", "empty":
            return .neutral
        default:
            return .neutral
        }
    }

    /// 单个订阅 section.status 映射为灯色.
    private static func sectionTone(for status: String) -> DashboardStatusTone {
        switch status {
        case "error", "failed", "unavailable":
            return .error
        case "partial", "stale", "authRequired":
            return .warn
        case "ok", "fresh", "ready":
            return .ok
        case "empty", "notConfigured", "idle":
            return .neutral
        default:
            return .neutral
        }
    }

    /// 聚合「采集健康度」与「订阅服务健康度」, 按最严重态优先 `error > warn > ok > neutral` 取并.
    /// `detail` 只描述采集侧; 订阅侧更严重时原因点名对应服务, 不挂采集侧 detail.
    package static func resolve(
        moduleState: String,
        subscriptions: [DashboardStatusSubscription],
        hasData: Bool = true,
        detail: String? = nil
    ) -> DashboardStatusResolution {
        let isRefreshing = (moduleState == "refreshing" || moduleState == "loading")
        let modTone = collectionTone(for: moduleState, hasData: hasData)

        var subTone: DashboardStatusTone = .neutral
        var worstSubStatus = "empty"
        for subscription in subscriptions {
            let candidate = sectionTone(for: subscription.status)
            if candidate > subTone {
                subTone = candidate
                worstSubStatus = subscription.status
            }
        }

        let tone = max(modTone, subTone)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let reason: String
        if isRefreshing {
            reason = "正在刷新…"
        } else if tone == .ok {
            reason = "运行正常"
        } else if subTone > modTone {
            let label = statusLabel(for: worstSubStatus)
            var names: [String] = []
            for subscription in subscriptions where sectionTone(for: subscription.status) == subTone {
                let name = subscription.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !names.contains(name) {
                    names.append(name)
                }
            }
            reason = names.isEmpty ? label : "\(label) · \(names.joined(separator: "、"))"
        } else {
            let effectiveState = (moduleState == "idle" && !hasData) ? "empty" : moduleState
            let label = statusLabel(for: effectiveState)
            if !trimmedDetail.isEmpty && trimmedDetail != label {
                reason = "\(label) · \(trimmedDetail)"
            } else {
                reason = label
            }
        }

        return DashboardStatusResolution(
            tone: tone,
            isRefreshing: isRefreshing,
            reason: reason
        )
    }

    /// macOS 视图便捷入口: 从 `ModuleStatus` 与 `PanelViewModel` 计算状态灯结果.
    package static func resolve(
        moduleStatus: ModuleStatus,
        panel: PanelViewModel
    ) -> DashboardStatusResolution {
        let hasData = panel.usage != nil || panel.subscription != nil || panel.hourly != nil
        let subscriptions = panel.subscription?.sections.map {
            DashboardStatusSubscription(status: $0.status, name: $0.name)
        } ?? []
        return resolve(
            moduleState: moduleStatus.state.rawValue,
            subscriptions: subscriptions,
            hasData: hasData,
            detail: moduleStatus.detail
        )
    }
}
