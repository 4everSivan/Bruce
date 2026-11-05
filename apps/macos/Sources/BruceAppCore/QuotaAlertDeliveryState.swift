import Foundation

/// 单个判定键 (serviceID|windowLabel) 的最近一次观察快照.
/// 用于识别「窗口在两次刷新之间被重置」: 只看已告警档位无法区分
/// 「同一窗口持续超标」与「新周期重新爬升」(design/02 规则 15).
package struct QuotaAlertObservation: Equatable, Sendable {
    /// 上次观察到的窗口用量.
    package var usedPercent: Double
    /// 上次观察到的窗口重置时刻归一化 token (整数 epoch 秒 / 原始字符串).
    package var resetToken: String?
}

/// 订阅额度预警去重状态: 记录每个判定键已提示过的最高阶梯档位,
/// 并在窗口重置时清空档位记忆, 为下一周期的 50/80/95 阶梯重新放行.
///
/// 窗口重置判定 (design/02 规则 15) 命中任一信号即视为新窗口:
/// - 用量较上次观察下降超过 20 个百分点 (重置后未采到低点、直接重新爬升);
/// - 窗口重置时刻更新 (前后两次采样均带非空 resetsAt 且取值不同).
package struct QuotaAlertDeliveryState: Equatable, Sendable {
    /// 每个判定键已成功提示过的最高阶梯档位.
    package private(set) var deliveredTiers: [String: Int] = [:]
    /// 每个判定键最近一次观察快照, 用于识别窗口重置.
    package private(set) var observations: [String: QuotaAlertObservation] = [:]

    package init() {}

    /// 用缓存快照回填状态: 已超阈值的窗口视为已提示 (重启后不重复报警),
    /// 同时回填观察快照, 保留跨重启的窗口重置识别能力.
    package mutating func seed(from entries: [(key: String, alert: QuotaAlert)]) {
        for entry in entries {
            let previous = deliveredTiers[entry.key] ?? 0
            deliveredTiers[entry.key] = max(previous, entry.alert.tier)
            observations[entry.key] = QuotaAlertObservation(
                usedPercent: entry.alert.usedPercent,
                resetToken: entry.alert.resetToken
            )
        }
    }

    /// 输入本轮超阈值条目, 返回需要真正发出气泡的跨档预警.
    /// `deliver == false` (手动刷新) 时只同步状态, 不投递通知.
    package mutating func alerts(
        for entries: [(key: String, alert: QuotaAlert)],
        deliver: Bool
    ) -> [QuotaAlert] {
        var fresh: [QuotaAlert] = []
        var currentKeys = Set<String>()
        for entry in entries {
            let key = entry.key
            currentKeys.insert(key)

            let current = QuotaAlertObservation(
                usedPercent: entry.alert.usedPercent,
                resetToken: entry.alert.resetToken
            )
            if let previous = observations[key],
               Self.windowDidReset(previous: previous, current: current) {
                // 新窗口: 清空旧档位记忆, 当前档位重新算作首次跨越.
                deliveredTiers.removeValue(forKey: key)
            }

            let highest = deliveredTiers[key] ?? 0
            if entry.alert.tier > highest {
                deliveredTiers[key] = entry.alert.tier
                if deliver {
                    fresh.append(entry.alert)
                }
            }
            observations[key] = current
        }

        // 回落至阈值以下 (本轮不再是候选) 的键整体清理.
        deliveredTiers = deliveredTiers.filter { currentKeys.contains($0.key) }
        observations = observations.filter { currentKeys.contains($0.key) }
        return fresh
    }

    /// 窗口重置判定 (design/02 规则 15).
    package static func windowDidReset(
        previous: QuotaAlertObservation,
        current: QuotaAlertObservation
    ) -> Bool {
        // ① 用量较上次观察下降超过 20 个百分点.
        if previous.usedPercent - current.usedPercent > 20.0 {
            return true
        }
        // ② 窗口重置时刻更新 (两端均有值时比较; nil → 有值不算换窗).
        if let previousToken = previous.resetToken,
           let currentToken = current.resetToken,
           previousToken != currentToken {
            return true
        }
        return false
    }
}
