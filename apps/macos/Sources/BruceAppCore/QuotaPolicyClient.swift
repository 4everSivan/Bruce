import Foundation
import BruceOnboardingCore
import BrucePolicyFFI

// MARK: - QuotaRunPolicy

/// 单轮刷新对外部额度查询的决策.
///
/// - `includeExternalQuotas == false`: 本地专用 run, 不发起任何订阅额度请求.
/// - `skipProviders`: 本轮要跳过的 provider (额度仍新鲜、处于 429 冷却或被锁屏抑制).
///   这些 provider 的上一份 service 由回填原样保留.
/// - `rateLimitedProviders`: 跳过原因是 429 冷却; 回填时强制标 `stale`.
package struct QuotaRunPolicy: Equatable, Sendable {
    package let includeExternalQuotas: Bool
    package let skipProviders: Set<SubscriptionProviderID>
    package let rateLimitedProviders: Set<SubscriptionProviderID>

    package init(
        includeExternalQuotas: Bool,
        skipProviders: Set<SubscriptionProviderID> = [],
        rateLimitedProviders: Set<SubscriptionProviderID> = []
    ) {
        self.includeExternalQuotas = includeExternalQuotas
        self.skipProviders = skipProviders
        self.rateLimitedProviders = rateLimitedProviders
    }

    package static let includeAll = QuotaRunPolicy(includeExternalQuotas: true)
    package static let localOnly = QuotaRunPolicy(includeExternalQuotas: false)
}

// MARK: - SubscriptionProviderID -> collector app id

package extension SubscriptionProviderID {
    /// Collector service 的 `app` 字段; OpenCode GO 在 Rust 侧使用连字符命名.
    var collectorAppID: String {
        self == .opencodeGo ? "opencode-go" : rawValue
    }
}

// MARK: - Shared policy entry (T15, design/08)

/// 策略入口传输: policy-request-v1 字节进、policy-response-v1 字节出.
/// 生产为进程内静态库调用 (`InProcessQuotaPolicyTransport`, T16); 测试可注入脚本化传输.
package typealias QuotaPolicyTransport = @MainActor (Data) async throws -> Data

/// 进程内传输 (T16, design/08 第二期): 经静态链接的共享策略 C ABI
/// (`collector-policy-ffi`) 计算, 不启动进程; 返回的缓冲区当场复制并释放.
package enum InProcessQuotaPolicyTransport {
    package static func call(_ input: Data) -> Data {
        var outputLength = 0
        let buffer = input.withUnsafeBytes { raw in
            bruce_policy_call(
                raw.bindMemory(to: UInt8.self).baseAddress,
                raw.count,
                &outputLength
            )
        }
        guard let buffer else { return Data() }
        defer { bruce_policy_free(buffer, outputLength) }
        return Data(bytes: buffer, count: outputLength)
    }
}

package enum QuotaPolicyError: Error, Equatable {
    /// 输出不是合法的 policy-response-v1 信封.
    case invalidResponse
    /// 入口返回 error 信封 (诊断码见 policy-response-v1).
    case rejected(code: String)
}

/// 额度门禁输入 (纯数据; 不含凭据).
package struct QuotaPlanInput: Sendable {
    package let previous: JSONValue?
    package let now: Date
    /// 额度查询周期; <= 0 表示不做新鲜度门禁 (测试兼容).
    package let interval: TimeInterval
    /// 手动或窗口边界触发, 绕过新鲜度门禁.
    package let forceRefresh: Bool
    /// 手动刷新为 true, 连 429 冷却也绕过.
    package let bypassCooldown: Bool
    /// 锁屏等场景强制抑制外部额度查询 (C064 / C071).
    package let suppressExternalQuotas: Bool
    /// 本轮启用的 provider (C120); nil 表示未知 (测试桩), 沿用上一份中出现的 provider.
    package let enabledProviders: Set<SubscriptionProviderID>?

    package init(
        previous: JSONValue?,
        now: Date,
        interval: TimeInterval,
        forceRefresh: Bool,
        bypassCooldown: Bool,
        suppressExternalQuotas: Bool = false,
        enabledProviders: Set<SubscriptionProviderID>? = nil
    ) {
        self.previous = previous
        self.now = now
        self.interval = interval
        self.forceRefresh = forceRefresh
        self.bypassCooldown = bypassCooldown
        self.suppressExternalQuotas = suppressExternalQuotas
        self.enabledProviders = enabledProviders
    }
}

/// 订阅额度门禁与回填 (C062 / C071 / C118 / C120). 规则只在共享 Rust crate
/// `collector-policy` 中实现一份 (design/08 SharedPolicyCore, design/02 规则 12),
/// mac 侧只负责组装纯数据请求并应用结果.
@MainActor
package protocol QuotaPolicyComputing: AnyObject {
    /// 本轮额度门禁.
    func plan(_ input: QuotaPlanInput) async throws -> QuotaRunPolicy

    /// 回填: 返回 `current` 并替换其 services (本轮 service 写尝试时间戳并按失败口径借用
    /// 合格旧值, 被跳过 provider 原样回填, 输出沿用上一份顺序).
    func merge(
        previous: JSONValue?,
        current: JSONValue,
        policy: QuotaRunPolicy,
        now: Date,
        interval: TimeInterval
    ) async throws -> JSONValue

    /// 定向刷新: 只给本轮真实查询到的 service 写尝试时间戳.
    func annotate(
        artifact: JSONValue,
        serviceIDs: Set<String>,
        now: Date
    ) async throws -> JSONValue
}

/// 经策略入口 (policy-request-v1) 调用共享实现. 请求只含 services 与时间、间隔、意图,
/// 不含整份 artifact 与任何凭据.
@MainActor
package final class CollectorQuotaPolicy: QuotaPolicyComputing {
    private let transport: QuotaPolicyTransport

    package init(transport: @escaping QuotaPolicyTransport) {
        self.transport = transport
    }

    /// 生产入口: 进程内调用共享策略 (T16).
    package static func inProcess() -> CollectorQuotaPolicy {
        CollectorQuotaPolicy { input in InProcessQuotaPolicyTransport.call(input) }
    }

    package func plan(_ input: QuotaPlanInput) async throws -> QuotaRunPolicy {
        let enabled: JSONValue = input.enabledProviders.map { providers in
            .array(providers.map(\.rawValue).sorted().map(JSONValue.string))
        } ?? .null
        let result = try await call("quotaPlan", [
            "now": .string(ISODate.string(from: input.now)),
            "previousServices": Self.services(of: input.previous),
            "enabledProviders": enabled,
            "intervalSeconds": .integer(Int(input.interval)),
            "forceRefresh": .boolean(input.forceRefresh),
            "bypassCooldown": .boolean(input.bypassCooldown),
            "suppressExternalQuotas": .boolean(input.suppressExternalQuotas),
        ])
        guard let policy = result["policy"]?.objectValue,
              let include = policy["includeExternalQuotas"]?.boolValue,
              let skip = policy["skipProviders"]?.arrayValue,
              let rateLimited = policy["rateLimitedProviders"]?.arrayValue else {
            throw QuotaPolicyError.invalidResponse
        }
        // 无法识别的 provider (旧 artifact 中的未知 service) 不参与本端凭证装配与回填.
        func providers(_ values: [JSONValue]) -> Set<SubscriptionProviderID> {
            Set(values.compactMap { $0.stringIdValue.flatMap(SubscriptionProviderID.init(rawValue:)) })
        }
        return QuotaRunPolicy(
            includeExternalQuotas: include,
            skipProviders: providers(skip),
            rateLimitedProviders: providers(rateLimited)
        )
    }

    package func merge(
        previous: JSONValue?,
        current: JSONValue,
        policy: QuotaRunPolicy,
        now: Date,
        interval: TimeInterval
    ) async throws -> JSONValue {
        guard var object = current.objectValue else { return current }
        func names(_ providers: Set<SubscriptionProviderID>) -> JSONValue {
            .array(providers.map(\.rawValue).sorted().map(JSONValue.string))
        }
        let result = try await call("quotaMerge", [
            "now": .string(ISODate.string(from: now)),
            "previousServices": Self.services(of: previous),
            "currentServices": .array(object["services"]?.arrayValue ?? []),
            "policy": .object([
                "includeExternalQuotas": .boolean(policy.includeExternalQuotas),
                "skipProviders": names(policy.skipProviders),
                "rateLimitedProviders": names(policy.rateLimitedProviders),
            ]),
            "intervalSeconds": .integer(Int(interval)),
        ])
        guard let services = result["services"]?.arrayValue else {
            throw QuotaPolicyError.invalidResponse
        }
        object["services"] = .array(services)
        return .object(object)
    }

    package func annotate(
        artifact: JSONValue,
        serviceIDs: Set<String>,
        now: Date
    ) async throws -> JSONValue {
        guard var object = artifact.objectValue,
              let services = object["services"]?.arrayValue else {
            return artifact
        }
        let result = try await call("quotaAnnotate", [
            "now": .string(ISODate.string(from: now)),
            "services": .array(services),
            "serviceIds": .array(serviceIDs.sorted().map(JSONValue.string)),
        ])
        guard let annotated = result["services"]?.arrayValue else {
            throw QuotaPolicyError.invalidResponse
        }
        object["services"] = .array(annotated)
        return .object(object)
    }

    private static func services(of artifact: JSONValue?) -> JSONValue {
        guard let services = artifact?.objectValue?["services"]?.arrayValue else {
            return .null
        }
        return .array(services)
    }

    private func call(
        _ operation: String,
        _ fields: [String: JSONValue]
    ) async throws -> [String: JSONValue] {
        var request = fields
        request["schemaVersion"] = .integer(1)
        request["operation"] = .string(operation)
        let output = try await transport(try JSONEncoder().encode(JSONValue.object(request)))
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: output).objectValue,
              response["schemaVersion"]?.intValue == 1 else {
            throw QuotaPolicyError.invalidResponse
        }
        guard response["status"]?.stringIdValue == "success",
              let result = response["result"]?.objectValue else {
            let code = response["diagnostics"]?.arrayValue?.first?.objectValue?["code"]?
                .stringIdValue
            guard let code else { throw QuotaPolicyError.invalidResponse }
            throw QuotaPolicyError.rejected(code: code)
        }
        return result
    }
}
