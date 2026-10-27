import Foundation
import BruceOnboardingCore
import BrucePolicyFFI

/// 共享刷新策略入口 (T17, design/08): 窗口边界唤醒与退避经进程内 C ABI 计算,
/// 规则只在 `collector-policy::refresh` 中实现一份。
///
/// 请求走 policy-request-v1, 只含时间 / 间隔 / 边界等纯数据, 不携带凭据。
/// 返回 nil 表示共享入口不可用 (调用方回退到安全值: 边界唤醒=原间隔, 退避=上限)。
package enum SharedRefreshPolicy {
    /// 从 artifact 提取窗口重置时刻 (epoch 秒)。
    package static func boundaries(in artifact: JSONValue) -> [Int64]? {
        guard let services = artifact.objectValue?["services"]?.arrayValue else {
            return []
        }
        let request: JSONValue = .object([
            "schemaVersion": .integer(1),
            "operation": .string("boundaryIds"),
            "services": .array(services),
        ])
        guard let result = call(request),
              let values = result["boundaries"]?.arrayValue else {
            return nil
        }
        return values.compactMap { $0.intValue.map(Int64.init) }
    }

    /// 下次唤醒间隔 (秒): 共享实现返回 delay 与更新后的 consumed 集合。
    package static func delay(
        intervalRemaining: TimeInterval,
        boundaries: [Int64],
        now: Date,
        slack: TimeInterval,
        consumed: inout Set<Int64>
    ) -> TimeInterval? {
        let request: JSONValue = .object([
            "schemaVersion": .integer(1),
            "operation": .string("boundaryWake"),
            "interval": .double(intervalRemaining),
            "boundaries": .array(boundaries.map { .integer(Int($0)) }),
            "now": .double(now.timeIntervalSince1970),
            "slack": .double(slack),
            "consumed": .array(consumed.sorted().map { .integer(Int($0)) }),
        ])
        guard let result = call(request),
              let delay = result["delay"]?.doubleValue,
              let values = result["consumed"]?.arrayValue else {
            return nil
        }
        consumed = Set(values.compactMap { $0.intValue.map(Int64.init) })
        return delay
    }

    /// 一个重试档的退避秒数; `jitterFraction` 为 capped 的 0...0.1。
    package static func backoff(
        retryCount: Int,
        rateLimited: Bool,
        base: TimeInterval,
        max: TimeInterval,
        rateLimit: TimeInterval,
        jitterFraction: Double
    ) -> TimeInterval? {
        let request: JSONValue = .object([
            "schemaVersion": .integer(1),
            "operation": .string("backoff"),
            "retryCount": .integer(retryCount),
            "rateLimited": .boolean(rateLimited),
            "base": .double(base),
            "max": .double(max),
            "rateLimit": .double(rateLimit),
            "jitterFraction": .double(jitterFraction),
        ])
        guard let result = call(request),
              let seconds = result["seconds"]?.doubleValue else {
            return nil
        }
        return seconds
    }

    private static func call(_ request: JSONValue) -> [String: JSONValue]? {
        guard let input = try? JSONEncoder().encode(request) else { return nil }
        let output = InProcessQuotaPolicyTransport.call(input)
        guard let response = try? JSONDecoder().decode(
            JSONValue.self,
            from: output
        ).objectValue,
            response["status"]?.stringIdValue == "success" else {
            return nil
        }
        return response["result"]?.objectValue
    }
}
