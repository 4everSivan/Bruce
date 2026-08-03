import Foundation
import MdddOnboardingCore

/// Codex 额度快照合并 (任务 7): 四源合并 previous / first / retry / decisions.
///
/// 规则 (纯逻辑, 不触碰凭证):
/// - 输入固定为 previous (上一轮已发布快照)、first (本轮首轮)、retry (可选
///   定向重试)、decisions (本轮全部账号 token 决议, 由 CodexTokenBatchResolver
///   按 index 排序产出)。
/// - 对每个当前账号 (decisions) 生成且只生成一个 service, 输出统一使用
///   currentID; legacy ID 惰性迁移: 查找 previous 时依次匹配
///   currentID > 唯一 legacyID > 无旧快照。
/// - 逐账号优先级: retry 中该账号结果 > first 中该账号结果 > token decision
///   生成的失败状态 > 缺失结果诊断。
/// - 成功 (ok/有效 empty) 使用本轮数据, freshness=fresh, capturedAt=本轮成功时间;
///   失败 + 有旧数据复制旧 windows/plan/extra/kind/capturedAt, freshness=stale;
///   失败 + 无旧数据 freshness=unavailable, 不写 capturedAt。不写 service 级
///   lastSuccessAt。
/// - legacy ID 同时匹配多个当前账号时不复用旧额度, 输出 unavailable 并记录诊断。
/// - 已断开账号的旧 service (既不匹配 currentID 也不唯一匹配 legacyID) 不出现在
///   输出中, 不从旧快照复活; 首轮非 Codex 数据与首轮未授权占位条目原样保留。
/// - generatedAt 取 retry (更新) 的生成时间, 无 retry 时取 first; stale 条目
///   由 QuotaAlertEvaluator 排除在阈值预警之外。
package struct CodexQuotaSnapshotMerger: Sendable {
    package init() {}

    package struct Result: Equatable, Sendable {
        package let artifact: JSONValue
        package let mergedCount: Int
        /// 合并期生成的脱敏诊断 (不包含账号标识与凭证).
        package let diagnostics: [MergerDiagnostic]
        /// 根据最终 artifact 重算的整体状态 (任务 7): 任一 agent/service
        /// 条目为 error/partial 时为 partial, 否则 success; 不直接采用
        /// retry response 的状态.
        let recomputedStatus: BridgeStatus

        /// 合并后 artifact 的 generatedAt 字符串值 (更新后的时间戳).
        package var generatedAtValue: String? {
            guard case .object(let object) = artifact,
                  case .string(let generatedAt)? = object["generatedAt"] else {
                return nil
            }
            return generatedAt
        }
    }

    /// 合并期诊断: 与 BridgeDiagnostic 同构但由 merger 生成, 内容脱敏.
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

    // MARK: - 四源合并

    /// 四源合并: previous + first + retry + decisions.
    /// - Parameters:
    ///   - previous: 上一轮已发布快照 (ArtifactStore 中当前快照, 本轮发布前读取);
    ///     nil 表示从未成功发布.
    ///   - first: 本轮首轮 Collector artifact.
    ///   - retry: 可选的 retry-only artifact.
    ///   - decisions: 本轮全部账号 token 决议 (含成功与失败).
    package func merge(
        previous: JSONValue?,
        first: JSONValue,
        retry: JSONValue?,
        decisions: [CodexTokenDecision]
    ) -> Result {
        guard case .object(var firstObject) = first else {
            return Result(
                artifact: first,
                mergedCount: 0,
                diagnostics: [],
                recomputedStatus: Self.recomputedStatus(first)
            )
        }
        let firstServices = firstObject["services"]?.arrayValue ?? []
        let firstByID = servicesByID(firstServices)
        let retryByID: [String: JSONValue]
        if let retry, case .object(let retryObject) = retry {
            retryByID = servicesByID(retryObject["services"]?.arrayValue ?? [])
        } else {
            retryByID = [:]
        }
        let previousByID: [String: JSONValue]
        if let previous, case .object(let previousObject) = previous {
            previousByID = servicesByID(
                previousObject["services"]?.arrayValue ?? []
            )
        } else {
            previousByID = [:]
        }

        // 当前账号: 按 accountID 去重, 保留首次出现的 index 顺序.
        let orderedDecisions = dedupeDecisions(decisions)
        let decisionByCurrentID = Dictionary(
            uniqueKeysWithValues: orderedDecisions.map { ($0.serviceID, $0) }
        )
        // legacyID -> 唯一归属的决策 (多个账号共享同一 legacyID 时视为歧义).
        let legacyOwners = legacyIDOwners(orderedDecisions)

        var diagnostics: [MergerDiagnostic] = []
        // 输出: 首轮非 Codex service 与不属于当前账号的 Codex 条目
        // (如未授权占位) 原位保留; 当前账号的 Codex service 按 index 重排.
        var output: [JSONValue] = []
        var emittedIndices = Set<Int>()
        var orderedCodex: [(index: Int, service: JSONValue)] = []

        for service in firstServices {
            if isCodexService(service),
               let id = service.stringId(),
               let decision = decisionByCurrentID[id] {
                orderedCodex.append((
                    decision.index,
                    mergeAccount(
                        decision: decision,
                        firstByID: firstByID,
                        retryByID: retryByID,
                        previousByID: previousByID,
                        legacyOwners: legacyOwners,
                        diagnostics: &diagnostics
                    )
                ))
                emittedIndices.insert(decision.index)
            } else {
                output.append(service)
            }
        }

        // 未被首轮覆盖的账号 (retry 新增或决议失败合成) 同样按 index 排序.
        let remaining = orderedDecisions
            .filter { !emittedIndices.contains($0.index) }
            .sorted { $0.index < $1.index }
        for decision in remaining {
            orderedCodex.append((
                decision.index,
                mergeAccount(
                    decision: decision,
                    firstByID: firstByID,
                    retryByID: retryByID,
                    previousByID: previousByID,
                    legacyOwners: legacyOwners,
                    diagnostics: &diagnostics
                )
            ))
        }
        orderedCodex.sort { $0.index < $1.index }
        output.append(contentsOf: orderedCodex.map(\.service))

        firstObject["services"] = .array(output)
        if let retry, case .object(let retryObject) = retry,
           let retryGenerated = retryObject["generatedAt"] {
            firstObject["generatedAt"] = retryGenerated
        }
        return Result(
            artifact: .object(firstObject),
            mergedCount: orderedDecisions.count,
            diagnostics: diagnostics,
            recomputedStatus: Self.recomputedStatus(.object(firstObject))
        )
    }

    /// 根据最终 artifact 重算整体状态: 任一 agent/service 为 error/partial
    /// 视为 partial, 否则 success. 不直接采用 retry response 的状态.
    private static func recomputedStatus(_ artifact: JSONValue) -> BridgeStatus {
        guard case .object(let object) = artifact else {
            return .error
        }
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

    // MARK: - 单账号合并

    private func mergeAccount(
        decision: CodexTokenDecision,
        firstByID: [String: JSONValue],
        retryByID: [String: JSONValue],
        previousByID: [String: JSONValue],
        legacyOwners: [String: CodexTokenDecision],
        diagnostics: inout [MergerDiagnostic]
    ) -> JSONValue {
        let currentID = decision.serviceID
        let legacyID = CodexAccountIdentity.legacyServiceID(for: decision.accountID)

        // 本轮结果: retry > first (均按 currentID 匹配).
        let roundResult = retryByID[currentID] ?? firstByID[currentID]

        // previous 匹配: currentID > 唯一 legacyID > 无旧快照.
        var previousService: [String: JSONValue]?
        if let current = previousByID[currentID] {
            previousService = current.objectValue
        } else if let legacy = previousByID[legacyID],
                  legacyOwners[legacyID]?.accountID == decision.accountID {
            // legacyID 唯一归属当前账号才允许惰性迁移复用旧额度.
            previousService = legacy.objectValue
        } else if previousByID[legacyID] != nil {
            // legacyID 同时匹配多个当前账号: 不跨账号复用旧额度.
            previousService = nil
            diagnostics.append(MergerDiagnostic(
                code: "CODEX_LEGACY_AMBIGUOUS",
                category: "collector",
                stage: "merge",
                message: "旧账号标识同时匹配多个账号, 未复用旧额度",
                retryable: false
            ))
        } else {
            previousService = nil
        }
        // 任务 4: 只有具备成功资格的 previous 才能提供 stale 数据.
        // 不合格 previous (unavailable/error/缺 capturedAt/时间无效) 只能提供
        // 安全的非成功元数据兼容, 不得提供额度值、lastSuccessAt 或 stale 状态;
        // 不得回退到 legacy 再次判定 (currentID 存在即以其为准).
        if let resolved = previousService,
           !Self.qualifiedPreviousSuccess(resolved) {
            previousService = nil
        }

        if let roundResult {
            guard case .object(var service) = roundResult else {
                return roundResult
            }
            let status = service["status"]?.stringIdValue
            if status == "ok" || status == "empty" {
                // 成功: 使用本轮数据; 旧 artifact 缺 freshness 时补 fresh.
                if service["freshness"] == nil {
                    service["freshness"] = .string("fresh")
                }
                return .object(service)
            }
            // 失败: 保留本轮 status/note/failureKind, 有旧数据则复制展示字段.
            applyFailureState(&service, previous: previousService)
            return .object(service)
        }

        // 无 collector 结果: 由 token decision 生成失败状态; .available 却
        // 缺失结果为诊断场景 (本轮注入成功但 collector 未返回该账号).
        var service = syntheticBase(for: decision)
        switch decision.outcome {
        case .available:
            diagnostics.append(MergerDiagnostic(
                code: "CODEX_ACCOUNT_RESULT_MISSING",
                category: "collector",
                stage: "merge",
                message: "账号未返回额度结果",
                retryable: true
            ))
            service["note"] = .string("未返回该账号额度结果")
        case .needsReauthorization:
            service["failureKind"] = .string("auth")
            service["note"] = .string("登录态已失效, 请重新登录该账号")
        case .storageBlocked:
            service["failureKind"] = .string("storage")
            service["note"] = .string("本地凭证存储暂时不可用")
        case .temporarilyUnavailable:
            service["failureKind"] = .string("tokenUnavailable")
            service["note"] = .string("额度查询暂时失败, 请稍后重试")
        case .credentialNotFound:
            service["failureKind"] = .string("tokenUnavailable")
            service["note"] = .string("未找到该账号的登录凭证")
        }
        applyFailureState(&service, previous: previousService)
        return .object(service)
    }

    /// 任务 4: previous service 是否具备成功资格 (可作为 stale 来源).
    /// - 新格式: `freshness` 为 `fresh` 或 `stale`, 且 `capturedAt` 是有效时间.
    /// - 旧格式: 不含 `freshness`, `status` 为 `ok` 或空字符串, 且 `capturedAt`
    ///   是有效时间.
    /// - `unavailable`/`error`/`unauthorized` 等失败状态、缺 `capturedAt`
    ///   或时间格式无效一律不具备资格; 失败 service 的 capturedAt 即使由旧版本
    ///   错误写入也不得使用.
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
        // 旧格式 (无 freshness): 必须显式包含 status, 且值为 ok 或空字符串.
        // 缺少 status 不是"空字符串", 不能作为成功快照提供 stale 数据.
        guard let status = service["status"]?.stringIdValue else {
            return false
        }
        return status == "ok" || status.isEmpty
    }

    /// 失败状态写入: 有合格旧成功数据 -> stale 并复制展示字段;
    /// 无旧数据 -> unavailable, 不写 capturedAt.
    private func applyFailureState(
        _ service: inout [String: JSONValue],
        previous: [String: JSONValue]?
    ) {
        if let previous {
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

    /// 无 collector 结果时的合成 service 骨架 (currentID, 无额度数据).
    private func syntheticBase(for decision: CodexTokenDecision) -> [String: JSONValue] {
        [
            "id": .string(decision.serviceID),
            "name": .string(decision.displayName),
            "app": .string("codex"),
            "isCurrent": .boolean(false),
            "status": .string("error"),
            "kind": .null,
            "plan": .null,
            "windows": .array([]),
            "balance": .null,
            "currency": .null,
            "note": .string(""),
        ]
    }

    // MARK: - 账号集合

    /// decisions 按 accountID 去重 (保留首次出现的 index).
    private func dedupeDecisions(_ decisions: [CodexTokenDecision]) -> [CodexTokenDecision] {
        var seen = Set<String>()
        var result: [CodexTokenDecision] = []
        for decision in decisions {
            if seen.insert(decision.accountID).inserted {
                result.append(decision)
            }
        }
        return result
    }

    /// legacyID -> 唯一归属的决策; 多个账号共享同一 legacyID 时不登记
    /// (歧义, 调用方按「无唯一归属」处理, 不跨账号复用旧额度).
    private func legacyIDOwners(
        _ decisions: [CodexTokenDecision]
    ) -> [String: CodexTokenDecision] {
        var groups: [String: [CodexTokenDecision]] = [:]
        for decision in decisions {
            let legacyID = CodexAccountIdentity.legacyServiceID(
                for: decision.accountID
            )
            groups[legacyID, default: []].append(decision)
        }
        var owners: [String: CodexTokenDecision] = [:]
        for (legacyID, group) in groups where group.count == 1 {
            owners[legacyID] = group[0]
        }
        return owners
    }

    private func isCodexService(_ value: JSONValue) -> Bool {
        guard case .object(let object) = value,
              case .string(let app)? = object["app"] else {
            return false
        }
        return app == "codex"
    }

    private func servicesByID(_ services: [JSONValue]) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for service in services {
            if let id = service.stringId() {
                result[id] = service
            }
        }
        return result
    }
}

extension JSONValue {
    var arrayValue: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
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
