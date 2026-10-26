import Foundation
import BruceOnboardingCore

// MARK: - QuotaRunPolicy

/// 单轮刷新对外部额度查询的决策.
///
/// - `includeExternalQuotas == false`: 本地专用 run, 不发起任何订阅额度请求.
/// - `skipProviders`: 本轮要跳过的 provider (额度仍新鲜或处于 429 冷却).
///   这些 provider 的上一份 service 会由 `QuotaCarryOverMerger` 原样回填.
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

// MARK: - QuotaRefreshPolicy

/// 订阅额度查询节流与 429 冷却 (C062).
///
/// 纯逻辑: 只读取上一份 artifact 的 service 时间戳, 不触碰网络/存储.
/// 关键语义:
/// - 本地采集周期与额度查询周期解耦: 自动 run 中, provider 的
///   `quotaAttemptedAt` 或成功 `capturedAt` 距今不足 `interval` 时跳过查询;
/// - 429 冷却: service 带 `rateLimitedAt` 且距今不足 `cooldownSeconds` 时跳过;
/// - 手动刷新绕过两者; 窗口边界唤醒绕过新鲜度但尊重 429 冷却;
/// - Codex 永不进入 `skipProviders` (其四源合并/重试链路需要完整首轮结果),
///   是否查询由 freshness 决定.
package enum QuotaRefreshPolicy {
    /// 自动额度查询周期 (30 分钟).
    package static let interval: TimeInterval = 30 * 60
    /// 429 后的自动查询冷却 (30 分钟).
    package static let rateLimitCooldown: TimeInterval = 30 * 60

    /// 根据上一份 artifact 计算本轮额度策略.
    ///
    /// - Parameters:
    ///   - previous: 上一份已发布 artifact; nil/无 services 时查询全部.
    ///   - now: 本轮时间.
    ///   - interval: 额度查询周期; <= 0 表示不做新鲜度门禁 (测试兼容).
    ///   - forceRefresh: 手动或窗口边界触发, 绕过新鲜度门禁.
    ///   - bypassCooldown: 手动刷新为 true, 连 429 冷却也绕过.
    ///   - suppressExternalQuotas: 锁屏等场景强制抑制外部额度查询 (C064).
    package static func plan(
        previous: JSONValue?,
        now: Date,
        interval: TimeInterval = interval,
        forceRefresh: Bool,
        bypassCooldown: Bool,
        suppressExternalQuotas: Bool = false
    ) -> QuotaRunPolicy {
        if suppressExternalQuotas {
            // C071: 「本轮被抑制跳过查询」等价于「全部 provider 进入 skip」,
            // 让 QuotaCarryOverMerger 原样回填上一份 services; 若返回空
            // skipProviders 的 localOnly, 抑制运行会发布零 services 的
            // artifact, 仪表盘订阅卡在解锁后被清空。与下方「全部 provider
            // 仍新鲜」路径的 skip = Set(byProvider.keys) 语义同构。
            let carried = previous?.objectValue?["services"]?.arrayValue ?? []
            var suppressed: Set<SubscriptionProviderID> = []
            for service in carried {
                if let provider = provider(of: service) {
                    suppressed.insert(provider)
                }
            }
            return QuotaRunPolicy(
                includeExternalQuotas: false,
                skipProviders: suppressed
            )
        }


        let services = previous?.objectValue?["services"]?.arrayValue ?? []
        guard !services.isEmpty, interval > 0 else {
            return .includeAll
        }

        var byProvider: [SubscriptionProviderID: [JSONValue]] = [:]
        for service in services {
            guard let provider = provider(of: service) else { continue }
            byProvider[provider, default: []].append(service)
        }
        guard !byProvider.isEmpty else {
            return .includeAll
        }

        var skip = Set<SubscriptionProviderID>()
        var rateLimited = Set<SubscriptionProviderID>()
        var due = Set<SubscriptionProviderID>()

        for (provider, providerServices) in byProvider {
            let cooling = !bypassCooldown && isCooling(
                providerServices,
                now: now,
                cooldown: rateLimitCooldown
            )
            if cooling {
                rateLimited.insert(provider)
                if provider != .codex {
                    skip.insert(provider)
                }
                continue
            }

            if forceRefresh {
                due.insert(provider)
                continue
            }

            // C037 兼容: 上次快照之后已有窗口重置, 即使未满 30 分钟也必须重查,
            // 否则 5 分钟本地周期会把重置后的额度拖到下一个额度周期.
            if hasPassedBoundary(providerServices, now: now) {
                due.insert(provider)
                continue
            }

            // 多账号: 只有全部账号都新鲜才跳过; 任一账号过期即重查整个 provider.
            let attempts = providerServices.compactMap { attemptAt($0) }
            let recentAttempt = !providerServices.isEmpty
                && attempts.count == providerServices.count
                && attempts.allSatisfy { now.timeIntervalSince($0) < interval }
            if recentAttempt {
                if provider != .codex {
                    skip.insert(provider)
                }
                continue
            }

            let captures = providerServices.compactMap { capturedAt($0) }
            let recentSuccess = !providerServices.isEmpty
                && captures.count == providerServices.count
                && captures.allSatisfy { now.timeIntervalSince($0) < interval }
            if recentSuccess {
                if provider != .codex {
                    skip.insert(provider)
                }
                continue
            }

            due.insert(provider)
        }

        if forceRefresh && bypassCooldown {
            skip.removeAll()
            rateLimited.removeAll()
        }

        // Codex 不跳过; include 只需判断是否有任何 provider 需要查询.
        let include = forceRefresh || !due.isEmpty || due.contains(.codex)
        if !include {
            // 全部 provider 仍新鲜: 本地专用 run, 回填全部旧 service.
            skip = Set(byProvider.keys)
        }
        return QuotaRunPolicy(
            includeExternalQuotas: include,
            skipProviders: skip,
            rateLimitedProviders: rateLimited
        )
    }

    // MARK: - Artifact inspection

    /// service -> 稳定 provider. 多账号 service ID (`claude_<hash>`) 归一.
    package static func provider(of service: JSONValue) -> SubscriptionProviderID? {
        guard let object = service.objectValue else { return nil }
        if let raw = SubscriptionPresentationPolicy.providerID(forServiceObject: object),
           let provider = SubscriptionProviderID(rawValue: raw) {
            return provider
        }
        if let app = object["app"]?.stringIdValue {
            if let provider = SubscriptionProviderID(rawValue: app) {
                return provider
            }
            if app == "opencode-go" {
                return .opencodeGo
            }
        }
        return nil
    }

    /// 本轮发出过 429 的 provider (仅 status error/partial + 限流文案).
    package static func rateLimitedProviders(in artifact: JSONValue?) -> Set<SubscriptionProviderID> {
        guard let services = artifact?.objectValue?["services"]?.arrayValue else {
            return []
        }
        var result = Set<SubscriptionProviderID>()
        for service in services {
            guard let object = service.objectValue,
                  let provider = provider(of: service) else { continue }
            let status = object["status"]?.stringIdValue
            guard status == "error" || status == "partial" else { continue }
            if isRateLimited(object) {
                result.insert(provider)
            }
        }
        return result
    }

    /// 本轮查询成功的 provider (ok/empty), 供清理由旧版本留下的冷却.
    package static func successfulProviders(in artifact: JSONValue?) -> Set<SubscriptionProviderID> {
        guard let services = artifact?.objectValue?["services"]?.arrayValue else {
            return []
        }
        var result = Set<SubscriptionProviderID>()
        for service in services {
            guard let object = service.objectValue,
                  let provider = provider(of: service) else { continue }
            let status = object["status"]?.stringIdValue
            if status == "ok" || status == "empty" {
                result.insert(provider)
            }
        }
        return result
    }

    /// 服务是否因限流失败 (C118): collector 下发 `failureKind` 时以其为准 (包括显式 null);
    /// 旧 artifact 无该字段时回退匹配 note 文案。
    package static func isRateLimited(_ object: [String: JSONValue]) -> Bool {
        if object.keys.contains("failureKind") {
            return object["failureKind"]?.stringIdValue == "rateLimit"
        }
        return isRateLimitedNote(object["note"]?.stringIdValue ?? "")
    }

    package static func isRateLimitedNote(_ note: String) -> Bool {
        note.contains("429")
            || note.contains("限流")
            || note.contains("RATE_LIMIT")
    }

    package static func capturedAt(_ service: JSONValue) -> Date? {
        parseISODate(service.objectValue?["capturedAt"]?.stringIdValue)
    }

    /// 最近一次真实额度尝试: `quotaAttemptedAt` 优先, 旧 artifact 回退到
    /// capturedAt; 失败 service 无 capturedAt 时回退到 artifact generatedAt.
    package static func attemptAt(_ service: JSONValue) -> Date? {
        guard let object = service.objectValue else { return nil }
        if let value = parseISODate(object["quotaAttemptedAt"]?.stringIdValue) {
            return value
        }
        if let value = parseISODate(object["capturedAt"]?.stringIdValue) {
            return value
        }
        let status = object["status"]?.stringIdValue
        if status == "error" || status == "partial" {
            return parseISODate(object["rateLimitedAt"]?.stringIdValue)
        }
        return nil
    }

    package static func rateLimitedAt(_ service: JSONValue) -> Date? {
        parseISODate(service.objectValue?["rateLimitedAt"]?.stringIdValue)
    }

    package static func timestamp(_ date: Date) -> String {
        ISODate.string(from: date)
    }

    static func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISODate.parseAllowingFractionalSeconds(value)
    }

    private static func isCooling(
        _ services: [JSONValue],
        now: Date,
        cooldown: TimeInterval
    ) -> Bool {
        guard let limitedAt = services.compactMap({ rateLimitedAt($0) }).max() else {
            return false
        }
        return now.timeIntervalSince(limitedAt) < cooldown
    }

    /// 上次快照之后是否有窗口 `resetsAt` 已过去 (epoch 秒).
    private static func hasPassedBoundary(
        _ services: [JSONValue],
        now: Date
    ) -> Bool {
        let nowEpoch = Int64(now.timeIntervalSince1970)
        for service in services {
            guard let object = service.objectValue,
                  object["kind"]?.stringIdValue == "windows",
                  let windows = object["windows"]?.arrayValue,
                  let captured = capturedAt(service) else {
                continue
            }
            let capturedEpoch = Int64(captured.timeIntervalSince1970)
            for window in windows {
                guard let reset = window.objectValue?["resetsAt"]?.intValue else {
                    continue
                }
                if reset <= nowEpoch && reset > capturedEpoch {
                    return true
                }
            }
        }
        return false
    }
}

// MARK: - QuotaCarryOverMerger

/// 额度快照回填与时间戳标注 (C062).
///
/// - 本轮被跳过的 provider: 用上一份 artifact 的同 ID service 回填;
/// - 本轮查询失败 (含 429): 旧数据合格时复制展示字段并标 `stale`;
/// - 本轮真实查询过的 service 写入 `quotaAttemptedAt`; 429 另写
///   `rateLimitedAt`, 成功则清除; 这些字段让节流状态跨 App 重启保留.
package enum QuotaCarryOverMerger {
    package static func merge(
        previous: JSONValue?,
        current: JSONValue,
        policy: QuotaRunPolicy,
        now: Date,
        interval: TimeInterval = QuotaRefreshPolicy.interval
    ) -> JSONValue {
        guard var currentObject = current.objectValue else { return current }
        let currentServices = currentObject["services"]?.arrayValue ?? []
        let previousServices = previous?.objectValue?["services"]?.arrayValue ?? []

        var currentByID: [String: JSONValue] = [:]
        for service in currentServices {
            if let id = service.stringId() {
                currentByID[id] = service
            }
        }

        var output: [JSONValue] = []
        var emitted = Set<String>()
        for previousService in previousServices {
            guard let id = previousService.stringId() else { continue }
            if var currentService = currentByID[id] {
                annotateCurrent(
                    &currentService,
                    previous: previousService,
                    now: now
                )
                output.append(currentService)
            } else if let provider = QuotaRefreshPolicy.provider(of: previousService),
                      policy.skipProviders.contains(provider) {
                var carried = previousService
                carryOver(
                    &carried,
                    provider: provider,
                    policy: policy,
                    now: now,
                    interval: interval
                )
                output.append(carried)
            }
            // 已查询但该 service 缺席: 视为账号删除/不可用, 不复活.
            emitted.insert(id)
        }

        for currentService in currentServices {
            if let id = currentService.stringId(), emitted.contains(id) {
                continue
            }
            var annotated = currentService
            annotateCurrent(&annotated, previous: nil, now: now)
            output.append(annotated)
        }

        currentObject["services"] = .array(output)
        return .object(currentObject)
    }

    /// 定向刷新走后端 `ScopedQuotaSnapshotMerger`; 这里只补本轮真实查询的
    /// 时间戳, 不改动其合并结果.
    package static func annotate(
        artifact: JSONValue,
        currentServiceIDs: Set<String>,
        now: Date
    ) -> JSONValue {
        guard var object = artifact.objectValue,
              let services = object["services"]?.arrayValue else {
            return artifact
        }
        let annotated = services.map { service -> JSONValue in
            guard let id = service.stringId(),
                  currentServiceIDs.contains(id) else {
                return service
            }
            var copy = service
            annotateCurrent(&copy, previous: nil, now: now, applyFailureFreshness: false)
            return copy
        }
        object["services"] = .array(annotated)
        return .object(object)
    }

    // MARK: - Service-level rules

    private static func annotateCurrent(
        _ service: inout JSONValue,
        previous: JSONValue?,
        now: Date,
        applyFailureFreshness: Bool = true
    ) {
        guard var object = service.objectValue else { return }
        object["quotaAttemptedAt"] = .string(QuotaRefreshPolicy.timestamp(now))

        let status = object["status"]?.stringIdValue
        let failed = status == "error" || status == "partial" || status == "unavailable"

        if failed && QuotaRefreshPolicy.isRateLimited(object) {
            object["rateLimitedAt"] = .string(QuotaRefreshPolicy.timestamp(now))
        } else if !failed {
            object.removeValue(forKey: "rateLimitedAt")
        }

        if applyFailureFreshness && failed {
            if let previous,
               qualifiedPreviousSuccess(previous) {
                for key in ["windows", "plan", "extra", "kind", "capturedAt"] {
                    if let value = previous.objectValue?[key] {
                        object[key] = value
                    }
                }
                object["freshness"] = .string("stale")
            } else {
                object["freshness"] = .string("unavailable")
                object.removeValue(forKey: "capturedAt")
            }
        } else if !failed, object["freshness"] == nil {
            object["freshness"] = .string("fresh")
        }

        service = .object(object)
    }

    private static func carryOver(
        _ service: inout JSONValue,
        provider: SubscriptionProviderID,
        policy: QuotaRunPolicy,
        now: Date,
        interval: TimeInterval
    ) {
        guard var object = service.objectValue else { return }
        let status = object["status"]?.stringIdValue
        let failed = status == "error" || status == "partial" || status == "unavailable"
        let cooling = policy.rateLimitedProviders.contains(provider)
        let captured = QuotaRefreshPolicy.capturedAt(service)
        let aged = captured.map { now.timeIntervalSince($0) >= interval } ?? true

        if failed || cooling || aged {
            object["freshness"] = .string("stale")
        } else if object["freshness"] == nil {
            object["freshness"] = .string("fresh")
        }
        service = .object(object)
    }

    private static func qualifiedPreviousSuccess(_ service: JSONValue) -> Bool {
        guard let object = service.objectValue,
              QuotaRefreshPolicy.parseISODate(object["capturedAt"]?.stringIdValue) != nil else {
            return false
        }
        if let freshness = object["freshness"]?.stringIdValue {
            return freshness == "fresh" || freshness == "stale"
        }
        guard let status = object["status"]?.stringIdValue else { return false }
        return status == "ok" || status == "empty"
    }
}

// MARK: - SubscriptionProviderID -> collector app id

package extension SubscriptionProviderID {
    /// Collector service 的 `app` 字段; OpenCode GO 在 Rust 侧使用连字符命名.
    var collectorAppID: String {
        self == .opencodeGo ? "opencode-go" : rawValue
    }
}
