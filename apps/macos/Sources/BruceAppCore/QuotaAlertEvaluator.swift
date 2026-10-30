import Foundation

/// 后台刷新额度预警的一条报警内容.
package struct QuotaAlert: Equatable, Sendable {
    package let serviceID: String
    package let serviceName: String
    package let windowLabel: String
    package let usedPercent: Double
    package let tier: Int
    package let providerID: String?
    package let resetText: String?
    package let resetsAt: String?

    package init(
        serviceID: String = "",
        serviceName: String,
        windowLabel: String,
        usedPercent: Double,
        tier: Int = 80,
        providerID: String? = nil,
        resetText: String? = nil,
        resetsAt: String? = nil
    ) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.windowLabel = windowLabel
        self.usedPercent = usedPercent
        self.tier = tier
        self.providerID = providerID
        self.resetText = resetText
        self.resetsAt = resetsAt
    }
}

/// 额度预警评估: 从 artifact services 中提取 5h 窗口用量超过三档阶梯阈值 [50%, 80%, 95%] 的条目.
/// 纯逻辑无通知框架依赖; 跨越判定 (阶梯跃迁: 0 -> 50 -> 80 -> 95) 与去重状态
/// 由 RefreshScheduler 按模块持有.
package enum QuotaAlertEvaluator {
    /// 阶梯阈值: [50%, 80%, 95%]
    package static let thresholds: [Double] = [50, 80, 95]
    /// 默认最高阈值参考
    package static let threshold: Double = 80

    /// 计算用量对应的告警档位 (95, 80, 50, 或 nil)
    package static func alertTier(for usedPercent: Double) -> Int? {
        if usedPercent >= 95.0 {
            return 95
        } else if usedPercent > 80.0 {
            return 80
        } else if usedPercent > 50.0 {
            return 50
        }
        return nil
    }

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
            let providerID: String?
            if case .string(let p)? = svc["provider"] {
                providerID = p
            } else {
                providerID = nil
            }
            for window in windows {
                guard case .object(let w) = window,
                      case .string(let label)? = w["label"],
                      isFiveHourWindow(label: label, windowMinutes: w["windowMinutes"]),
                      let used = numericValue(w["usedPercent"]),
                      let tier = alertTier(for: used) else {
                    continue
                }
                let resetsAt: String?
                if case .string(let r)? = w["resetsAt"] {
                    resetsAt = r
                } else {
                    resetsAt = nil
                }
                let resetText: String?
                if case .string(let rt)? = w["resetText"] {
                    resetText = rt
                } else {
                    resetText = nil
                }

                entries.append((
                    key: "\(serviceID)|\(label)",
                    alert: QuotaAlert(
                        serviceID: serviceID,
                        serviceName: name,
                        windowLabel: label,
                        usedPercent: used,
                        tier: tier,
                        providerID: providerID,
                        resetText: resetText,
                        resetsAt: resetsAt
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
