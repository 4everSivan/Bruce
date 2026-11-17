import Foundation
import BruceOnboardingCore

// MARK: - 网络出口阻断预警评估器

/// 从 artifact services 中提取出口校验处于 blocked 状态的条目
package enum EgressAlertEvaluator {
    /// 按刷新作用域收敛阻断条目 (C185): 定向刷新只保留目标 Provider 的告警;
    /// 全量刷新保持原样。serviceID -> Provider 归一走稳定展示映射, 未知归属的条目
    /// 在定向刷新下丢弃 (fail-closed, 不猜测目标)。
    package static func scopedEntries(
        _ entries: [(serviceID: String, alert: EgressAlertItem)],
        scope: RefreshScope
    ) -> [(serviceID: String, alert: EgressAlertItem)] {
        guard scope.isTargeted else { return entries }
        let targets = scope.targetProviders
        return entries.filter { entry in
            let raw = SubscriptionPresentationPolicy.providerID(forServiceID: entry.serviceID)
            guard let provider = SubscriptionProviderID(rawValue: raw) else { return false }
            return targets.contains(provider)
        }
    }

    /// 瞬态探测失败原因: 只有这些失败由 collector-policy 写入 egressRetryAt 并值得提前唤醒。
    /// 必须与 collector-policy `TRANSIENT_EGRESS_REASONS` 一致 (RefreshSchedulerHarness 源码守卫);
    /// 代理需认证与配置无效需用户修改配置, 不进入自动重试 (C241)。
    package static let transientProbeReasons: Set<String> = [
        "EGRESS_PROBE_TIMEOUT",
        "EGRESS_PROXY_UNREACHABLE",
        "EGRESS_BAD_STATUS",
        "EGRESS_COUNTRY_UNKNOWN",
    ]

    /// artifact 中最早的瞬态探测失败重试时间; 无则返回 nil。
    package static func earliestTransientRetryAt(artifact: JSONValue) -> Date? {
        guard case .object(let root) = artifact,
              case .array(let services)? = root["services"] else {
            return nil
        }
        var earliest: Date?
        for service in services {
            guard case .object(let svc) = service,
                  case .object(let egress)? = svc["egress"],
                  case .string(let status)? = egress["status"],
                  status == "blocked",
                  case .string(let reason)? = egress["reason"],
                  transientProbeReasons.contains(reason),
                  case .string(let retryAt)? = svc["egressRetryAt"],
                  let date = ISODate.parse(retryAt) else {
                continue
            }
            if let current = earliest {
                earliest = min(current, date)
            } else {
                earliest = date
            }
        }
        return earliest
    }

    /// 返回当前 artifact 中所有被出口拦截的 serviceID 与 EgressAlertItem
    package static func blockedEntries(
        artifact: JSONValue
    ) -> [(serviceID: String, alert: EgressAlertItem)] {
        guard case .object(let root) = artifact,
              case .array(let services)? = root["services"] else {
            return []
        }
        var entries: [(serviceID: String, alert: EgressAlertItem)] = []
        for service in services {
            guard case .object(let svc) = service,
                  case .string(let serviceID)? = svc["id"] else {
                continue
            }
            guard case .object(let egressObj)? = svc["egress"],
                  case .string(let statusStr)? = egressObj["status"],
                  statusStr == "blocked" else {
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

            let reason: String? = {
                if case .string(let r)? = egressObj["reason"] { return r }
                return nil
            }()
            let expected: String? = {
                if case .string(let e)? = egressObj["expected"] { return e }
                return nil
            }()
            let observed: String? = {
                if case .string(let o)? = egressObj["observed"] { return o }
                return nil
            }()
            let maskedIp: String? = {
                if case .string(let ip)? = egressObj["maskedIp"] { return ip }
                return nil
            }()

            let badgeText: String = {
                switch reason {
                case "EGRESS_CN_DIRECT":
                    return "⚠️ 国内直连"
                case "EGRESS_COUNTRY_MISMATCH":
                    let obs = observed ?? "?"
                    let exp = expected ?? "?"
                    return "⚠️ \(obs) ≠ \(exp)"
                case "EGRESS_PROBE_TIMEOUT":
                    return "⚠️ 探测失败"
                case "EGRESS_PROXY_UNREACHABLE":
                    return "⚠️ 代理不可达"
                case "EGRESS_PROXY_AUTH":
                    return "⚠️ 代理需认证"
                case "EGRESS_BAD_STATUS":
                    return "⚠️ 信标异常"
                case "EGRESS_COUNTRY_UNKNOWN":
                    return "⚠️ 出口未知"
                default:
                    return "⚠️ 出口异常"
                }
            }()

            let alert = EgressAlertItem(
                serviceID: serviceID,
                serviceName: name,
                providerID: providerID,
                badgeText: badgeText,
                explanation: "已拦截海外查额以保护账号 · 保持快照",
                reason: reason,
                expected: expected,
                observed: observed,
                maskedIp: maskedIp
            )
            entries.append((serviceID: serviceID, alert: alert))
        }
        return entries
    }
}
