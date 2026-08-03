import Foundation

/// 后台刷新额度预警的一条报警内容.
package struct QuotaAlert: Equatable, Sendable {
    package let serviceName: String
    package let windowLabel: String
    package let usedPercent: Double
}

/// 额度预警评估: 从 artifact services 中提取 5h 窗口用量超过阈值的条目.
/// 纯逻辑无通知框架依赖; 跨越判定 (上次未超 -> 本次超) 与去重状态
/// 由 RefreshScheduler 按模块持有.
package enum QuotaAlertEvaluator {
    /// 预警阈值: 5h 窗口用量 > 80% 触发.
    package static let threshold: Double = 80

    /// 返回当前 artifact 全部超阈值条目, key 为 "serviceID|windowLabel" 用于去重.
    package static func overThresholdEntries(
        artifact: JSONValue
    ) -> [(key: String, alert: QuotaAlert)] {
        guard case .object(let root) = artifact,
              case .array(let services)? = root["services"] else {
            return []
        }
        var entries: [(key: String, alert: QuotaAlert)] = []
        for service in services {
            guard case .object(let svc) = service,
                  case .string(let serviceID)? = svc["id"],
                  case .array(let windows)? = svc["windows"] else {
                continue
            }
            // 任务 7: stale 条目 (本轮失败保留旧额度) 不得重复触发阈值通知.
            if case .string(let freshness)? = svc["freshness"],
               freshness == "stale" {
                continue
            }
            let name: String
            if case .string(let serviceName)? = svc["name"] {
                name = serviceName
            } else {
                name = serviceID
            }
            for window in windows {
                guard case .object(let w) = window,
                      case .string(let label)? = w["label"],
                      isFiveHourWindow(label: label, windowMinutes: w["windowMinutes"]),
                      let used = numericValue(w["usedPercent"]),
                      used > threshold else {
                    continue
                }
                entries.append((
                    key: "\(serviceID)|\(label)",
                    alert: QuotaAlert(
                        serviceName: name,
                        windowLabel: label,
                        usedPercent: used
                    )
                ))
            }
        }
        return entries
    }

    /// 5h 窗口判定: windowMinutes == 300 优先, 其次标签文本
    /// (火山引擎等接口 windowMinutes 为空, 只有 "5小时窗口" 标签).
    private static func isFiveHourWindow(
        label: String,
        windowMinutes: JSONValue?
    ) -> Bool {
        if case .integer(let minutes)? = windowMinutes {
            return minutes == 300
        }
        let lowered = label.lowercased()
        return lowered.contains("5h")
            || label.contains("5小时")
            || label.contains("5 小时")
    }

    private static func numericValue(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .integer(let number): return Double(number)
        default: return nil
        }
    }
}
