import Foundation
import BruceOnboardingCore

/// 定向 (Provider-scoped) 额度快照合并 (任务 1.4 / 1.5).
///
/// 把一次定向 Collector 返回的 artifact (agents=[]、totalCostUsd=null、
/// services 仅含目标 Provider) 合并回上一份完整 artifact:
/// - 保留 agents、totalCostUsd 与**非目标** Provider 的 services.
/// - 目标 Provider service 按稳定 `service.id` 合并: 成功标 `fresh`,
///   失败保留合格旧窗口标 `stale`, 无合格历史标 `unavailable`, 不伪造成功.
/// - 已断开账号 (首轮未出现) 不从前一份复活.
/// - Codex 目标复用 `CodexQuotaSnapshotMerger` (legacy ID / order / 一次
///   forced refresh + 一次 retry-only 规则不变), 非 Codex 目标走通用合并.
///
/// 纯逻辑, 不触碰 Keychain 或外部服务; 不持有状态.
struct ScopedQuotaSnapshotMerger: Sendable {
    package init() {}

    package struct Result: Equatable, Sendable {
        package let artifact: JSONValue
        /// 合并后 artifact 的 generatedAt 字符串值 (retry 优先于 first).
        package var generatedAtValue: String? {
            guard case .object(let object) = artifact,
                  case .string(let generatedAt)? = object["generatedAt"] else {
                return nil
            }
            return generatedAt
        }
        package let mergedCount: Int
        /// 合并期生成的脱敏诊断 (不含账号标识与凭证).
        package let diagnostics: [MergerDiagnostic]
        /// 根据最终 artifact 重算的整体状态 (任务 7 同义).
        let recomputedStatus: BridgeStatus
    }

    /// 合并期诊断; 与 BridgeDiagnostic 同构但由 merger 生成, 内容脱敏.
    package struct MergerDiagnostic: Equatable, Sendable {
        package let code: String
        package let category: String
        package let stage: String
        package let message: String
        package let retryable: Bool

        package init(
            code: String,
            category: String,
            stage: String,
            message: String,
            retryable: Bool
        ) {
            self.code = code
            self.category = category
            self.stage = stage
            self.message = message
            self.retryable = retryable
        }
    }

    // MARK: - 合并

    package func merge(
        previous: JSONValue?,
        first: JSONValue,
        retry: JSONValue?,
        targetProviders: Set<SubscriptionProviderID>,
        decisions: [CodexTokenDecision]
    ) -> Result {
        guard case .object(var firstObject) = first else {
            return Result(
                artifact: first,
                mergedCount: 0,
                diagnostics: [],
                recomputedStatus: Self.recomputeStatus(first)
            )
        }
        let firstServices = firstObject["services"]?.arrayValue ?? []
        let previousObject = previous?.objectValue
        let previousServices = previousObject?["services"]?.arrayValue ?? []

        let codexInTargets = targetProviders.contains(.codex)
        let nonCodexTargets = targetProviders.subtracting([.codex])

        var outputServices: [JSONValue] = []
        var diagnostics: [MergerDiagnostic] = []

        // 1. 保留非目标 Provider service (含未作为目标的 Codex).
        for svc in previousServices {
            if let provider = providerOfService(svc),
               targetProviders.contains(provider) {
                continue
            }
            outputServices.append(svc)
        }

        // 2. Codex 目标: 复用既有四源合并 (legacy ID / order / 一次 forced+retry).
        if codexInTargets {
            let codexFirst = makeArtifact(
                services: firstServices.filter { providerOfService($0) == .codex },
                generatedAt: firstObject["generatedAt"]
            )
            let codexPrev = makeArtifact(
                services: previousServices.filter { providerOfService($0) == .codex },
                generatedAt: previousObject?["generatedAt"]
            )
            let merged = CodexQuotaSnapshotMerger().merge(
                previous: codexPrev,
                first: codexFirst,
                retry: retry,
                decisions: decisions
            )
            if case .object(let mergedObject) = merged.artifact,
               let svcs = mergedObject["services"]?.arrayValue {
                outputServices.append(contentsOf: svcs)
            }
            for d in merged.diagnostics {
                diagnostics.append(MergerDiagnostic(
                    code: d.code,
                    category: d.category,
                    stage: d.stage,
                    message: d.message,
                    retryable: d.retryable
                ))
            }
        }

        // 3. 非 Codex 目标: 按稳定 service.id 合并 (成功 fresh / 失败 stale|unavailable).
        let targetFirst = firstServices.filter { svc in
            guard let provider = providerOfService(svc) else { return false }
            return nonCodexTargets.contains(provider)
        }
        let prevByID: [String: JSONValue] = Dictionary(uniqueKeysWithValues: previousServices.compactMap { svc in
            svc.stringId().map { ($0, svc) }
        })
        for svc in targetFirst {
            guard let id = svc.stringId() else {
                outputServices.append(svc)
                continue
            }
            let previous = prevByID[id]?.objectValue
            outputServices.append(mergeTargetService(round: svc, previous: previous))
        }

        firstObject["services"] = .array(outputServices)
        // agents / totalCost 保留上一份完整 artifact; 定向运行不重采本机会话/成本.
        if let previousObject {
            firstObject["agents"] = previousObject["agents"] ?? .array([])
            firstObject["totalCostUsd"] = previousObject["totalCostUsd"] ?? .null
        } else {
            firstObject["agents"] = .array([])
            firstObject["totalCostUsd"] = .null
        }
        // generatedAt 取 retry (更新) 时间戳, 无 retry 时取 first.
        if let retry,
           case .object(let retryObject) = retry,
           let retryGenerated = retryObject["generatedAt"] {
            firstObject["generatedAt"] = retryGenerated
        }

        let artifact = JSONValue.object(firstObject)
        return Result(
            artifact: artifact,
            mergedCount: targetFirst.count + (codexInTargets ? 1 : 0),
            diagnostics: diagnostics,
            recomputedStatus: Self.recomputeStatus(artifact)
        )
    }

    // MARK: - 单 service 通用合并

    private func mergeTargetService(
        round: JSONValue,
        previous: [String: JSONValue]?
    ) -> JSONValue {
        guard case .object(var service) = round else { return round }
        let status = service["status"]?.stringIdValue
        if status == "ok" || status == "empty" {
            if service["freshness"] == nil {
                service["freshness"] = .string("fresh")
            }
            return .object(service)
        }
        // 失败: 有合格旧成功数据 -> stale 并复制展示字段; 否则 unavailable.
        applyFailureState(&service, previous: previous)
        return .object(service)
    }

    private func applyFailureState(
        _ service: inout [String: JSONValue],
        previous: [String: JSONValue]?
    ) {
        if let previous, Self.qualifiedPreviousSuccess(previous) {
            for key in ["windows", "plan", "extra", "kind", "capturedAt"] {
                if let existingValue = previous[key] {
                    service[key] = existingValue
                }
            }
            service["freshness"] = .string("stale")
        } else {
            service["freshness"] = .string("unavailable")
            service.removeValue(forKey: "capturedAt")
        }
    }

    /// 与 `CodexQuotaSnapshotMerger` 同义: previous service 是否具备成功资格
    /// (可作为 stale 来源). 失败状态、缺 capturedAt 或时间无效一律不具备资格.
    private static func qualifiedPreviousSuccess(
        _ service: [String: JSONValue]
    ) -> Bool {
        let capturedAt = service["capturedAt"]?.stringIdValue
        guard let capturedAt,
              ISO8601DateFormatter().date(from: capturedAt) != nil else {
            return false
        }
        if let freshness = service["freshness"]?.stringIdValue {
            return freshness == "fresh" || freshness == "stale"
        }
        guard let status = service["status"]?.stringIdValue else { return false }
        return status == "ok" || status.isEmpty
    }

    // MARK: - 工具

    /// service -> 目标 Provider rawValue (经稳定展示映射; opencode-go 等归一).
    private func providerOfService(_ service: JSONValue) -> SubscriptionProviderID? {
        guard case .object(let object) = service,
              let id = object["id"]?.stringIdValue else {
            return nil
        }
        let raw = SubscriptionPresentationPolicy.providerID(forServiceID: id)
        return SubscriptionProviderID(rawValue: raw)
    }

    private func makeArtifact(
        services: [JSONValue],
        generatedAt: JSONValue?
    ) -> JSONValue {
        .object([
            "generatedAt": generatedAt ?? .string(""),
            "services": .array(services),
        ])
    }

    /// 根据最终 artifact 重算整体状态: 任一 agent/service 为 error/partial
    /// 视为 partial, 否则 success.
    private static func recomputeStatus(_ artifact: JSONValue) -> BridgeStatus {
        guard case .object(let object) = artifact else { return .error }
        for section in ["agents", "services"] {
            guard case .array(let items)? = object[section] else { continue }
            for item in items {
                guard case .object(let entry) = item,
                      case .string(let status)? = entry["status"] else {
                    continue
                }
                if status == "error" || status == "partial" {
                    return .partial
                }
            }
        }
        return .success
    }
}
