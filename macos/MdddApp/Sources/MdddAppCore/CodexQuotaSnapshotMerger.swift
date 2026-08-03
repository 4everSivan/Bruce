import Foundation
import MdddOnboardingCore

/// Codex 额度快照合并 (任务 9): 定向重试结果与首次结果按 Codex service ID 合并.
///
/// 规则 (纯逻辑, 不触碰凭证):
/// - 以 `services` 中 app=="codex" 的条目为合并单元; 非 Codex service 与
///   agents 全部保留首次结果.
/// - 定向重试条目状态为 error 时保留旧 windows/plan/extra/capturedAt, 只更新
///   status/note (暂时失败或需要重登不丢上次成功数据).
/// - 定向重试条目成功 (ok/empty) 时覆盖旧条目的可展示字段与 capturedAt.
/// - 从未成功的账号不伪造窗口 (保留旧 error 状态, 不注入空 windows).
/// - 合并后 generatedAt 取 retry artifact (更新) 的生成时间, 无 retry 时不变.
package struct CodexQuotaSnapshotMerger: Sendable {
    package init() {}

    package struct Result: Equatable, Sendable {
        package let artifact: JSONValue
        package let mergedCount: Int

        /// 合并后 artifact 的 generatedAt 字符串值 (更新后的时间戳).
        package var generatedAtValue: String? {
            guard case .object(let object) = artifact,
                  case .string(let generatedAt)? = object["generatedAt"] else {
                return nil
            }
            return generatedAt
        }
    }

    package func merge(
        first: JSONValue,
        retry: JSONValue
    ) -> Result {
        guard case .object(var firstObject) = first,
              case .object(var retryObject) = retry else {
            return Result(artifact: first, mergedCount: 0)
        }
        var mergedServices = firstObject["services"]?.arrayValue ?? []
        let retryServices = retryObject["services"]?.arrayValue ?? []

        // 首次结果中 app=="codex" 的条目: 定向重试覆盖或保留旧值.
        var mergedCodexCount = 0
        for (index, service) in mergedServices.enumerated() {
            guard isCodexService(service),
                  case .object(let serviceObject) = service,
                  let id = serviceObject["id"]?.stringIdValue,
                  let replacement = retryServices.first(where: { $0.stringId() == id })
            else {
                continue
            }
            mergedServices[index] = mergeService(
                existing: serviceObject,
                replacement: replacement
            )
            mergedCodexCount += 1
        }

        // 首次没有但定向重试新增的 Codex 条目 (账号首次失败, 本轮才出现).
        let existingIDs = Set(mergedServices.compactMap { $0.stringId() })
        for service in retryServices where isCodexService(service) {
            if let id = service.stringId(), !existingIDs.contains(id) {
                mergedServices.append(service)
            }
        }

        firstObject["services"] = .array(mergedServices)
        if let retryGenerated = retryObject["generatedAt"] {
            firstObject["generatedAt"] = retryGenerated
        }
        return Result(
            artifact: .object(firstObject),
            mergedCount: mergedCodexCount
        )
    }

    /// 单条 Codex service 合并: error 保留旧数据, 其余覆盖.
    private func mergeService(
        existing: [String: JSONValue],
        replacement: JSONValue
    ) -> JSONValue {
        guard case .object(let replacementObject) = replacement,
              case .string(let status)? = replacementObject["status"],
              status == "error" else {
            return replacement
        }
        var merged = replacementObject
        for key in ["windows", "plan", "extra", "capturedAt", "kind"] {
            if let existingValue = existing[key] {
                merged[key] = existingValue
            }
        }
        return .object(merged)
    }

    private func isCodexService(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value,
              case .string(let app)? = object["app"] else {
            return false
        }
        return app == "codex"
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    func stringId() -> String? {
        if case .object(let object) = self,
           case .string(let id)? = object["id"] {
            return id
        }
        return nil
    }

    /// JSONValue 自身是字符串时取值 (与 stringId 区分, 避免重名).
    var stringIdValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// services 中是否存在非 ok 条目 (error/partial 诊断依据).
    var hasFailedEntries: Bool {
        guard case .object(let object) = self,
              case .array(let services)? = object["services"] else {
            return false
        }
        return services.contains { value in
            guard case .object(let service) = value,
                  case .string(let status)? = service["status"] else {
                return false
            }
            return status == "error" || status == "partial"
        }
    }
}

