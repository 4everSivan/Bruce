import Foundation
import BruceOnboardingCore

// MARK: - CodexChallenge

/// Codex accessRejected challenge 的结构化解析 (阶段 B: 从 RefreshScheduler 提取).
/// 只接受 provider == "codex" 且 reason == "accessRejected" 的 challenge.
struct CodexChallenge: Equatable, Sendable {
    let accountID: String

    init?(json: JSONValue) {
        guard case .object(let object) = json,
              case .string(let provider)? = object["provider"],
              provider == "codex",
              case .string(let reason)? = object["reason"],
              reason == "accessRejected",
              case .string(let accountID)? = object["accountId"],
              !accountID.isEmpty else {
            return nil
        }
        self.accountID = accountID
    }
}

// MARK: - CodexRetryPhaseResult

/// Codex 挑战处理阶段的结果 (阶段 B: 从 RefreshScheduler 提取).
/// 三类数据显式表达, 不用异常或提前 return 隐式表达.
struct CodexRetryPhaseResult: Sendable {
    let retryArtifact: JSONValue?
    let tokenDecisions: [CodexTokenDecision]
    let diagnostics: [BridgeDiagnostic]

    init(
        retryArtifact: JSONValue?,
        tokenDecisions: [CodexTokenDecision],
        diagnostics: [BridgeDiagnostic]
    ) {
        self.retryArtifact = retryArtifact
        self.tokenDecisions = tokenDecisions
        self.diagnostics = diagnostics
    }
}

// MARK: - CodexQuotaRecovery

/// Codex 额度恢复管线 (阶段 B: 从 RefreshScheduler 拆出).
///
/// 职责: 解析 accessRejected challenge、按本轮 index 排序账号、
/// 最多 4 账号并行强制刷新 (refreshAfterAccessRejected)、
/// 生成 retry-only 输入并执行唯一一次重试 Collector、
/// 把重试仍 401 的账号持久化为 needsReauthorization.
///
/// 不持有长期状态; 每次调用接收本轮所需的全部依赖. 调用方 (RefreshScheduler)
/// 负责在调用前后检查 stopped 状态.
@MainActor
struct CodexQuotaRecovery {
    init() {}

    /// 执行一轮 Codex 定向重试.
    /// - Parameters:
    ///   - firstOutput: 首轮 Collector 输出 (含 credentialChallenges).
    ///   - firstCredentials: 首轮注入凭证 (含 codexQuotaAccounts 用于过滤).
    ///   - module: Collector 模块 (仅 agentUsage 进入恢复).
    ///   - runInputProvider: 提供 codexTokenDecisions 和 retryInput.
    ///   - challengeHandler: token manager, 提供 refreshAfterAccessRejected
    ///     和 markNeedsReauthorization.
    ///   - isStopped: 调用方 stopped 状态闭包.
    ///   - runCollector: 执行 retry-only Collector 的闭包.
    /// - Returns: retry phase result; 任何失败分支返回空/诊断结果, 由 finalizer 合并.
    func handle(
        firstOutput: CollectorRunOutput,
        firstCredentials: [String: JSONValue],
        module: CollectorModule,
        runInputProvider: (any CollectorRunInputProviding)?,
        challengeHandler: (any CodexChallengeHandling)?,
        isStopped: () -> Bool,
        runCollector: (
            _ module: CollectorModule,
            _ context: [String: JSONValue],
            _ credentials: [String: JSONValue]
        ) async -> Result<CollectorRunOutput, Error>
    ) async -> CodexRetryPhaseResult {
        let empty = CodexRetryPhaseResult(
            retryArtifact: nil,
            tokenDecisions: [],
            diagnostics: []
        )
        guard !isStopped() else { return empty }
        guard !firstOutput.response.credentialChallenges.isEmpty else {
            return empty
        }

        // 本轮已注入账号: 只接受属于注入账号的 challenge.
        let injectedAccounts: Set<String>
        if case .object(let codexAccounts)? = firstCredentials["codexQuotaAccounts"] {
            injectedAccounts = Set(codexAccounts.keys)
        } else {
            injectedAccounts = []
        }
        let challenges = firstOutput.response.credentialChallenges
            .compactMap(CodexChallenge.init(json:))
        let accountedChallenges = challenges
            .filter { injectedAccounts.contains($0.accountID) }
        guard !accountedChallenges.isEmpty else {
            // 非法/不属于本轮的 challenge: 不重试, 空 retry phase
            return empty
        }

        // 按账号去重并排序 (本轮 index 顺序; 未出现在决议中的账号按
        // accountID 排序, 保证确定性).
        let orderedAccounts = Self.orderedChallengeAccounts(
            accountedChallenges,
            decisions: runInputProvider?.codexTokenDecisions ?? []
        )
        guard !orderedAccounts.isEmpty, let runInputProvider else {
            return empty
        }

        // 最多 4 账号并行 refreshAfterAccessRejected (OAuth 调用不重复).
        var refreshedAccounts: [String] = []
        if let challengeHandler {
            let chunks = stride(
                from: 0,
                to: orderedAccounts.count,
                by: CodexTokenBatchResolver.maxConcurrency
            ).map {
                Array(orderedAccounts[$0..<min($0 + CodexTokenBatchResolver.maxConcurrency, orderedAccounts.count)])
            }
            for chunk in chunks {
                let results = await withTaskGroup(
                    of: (String, TokenResolution).self
                ) { group in
                    for accountID in chunk {
                        group.addTask {
                            let resolution = await challengeHandler
                                .refreshAfterAccessRejected(
                                    for: accountID, now: nil
                                )
                            return (accountID, resolution)
                        }
                    }
                    var collected: [(String, TokenResolution)] = []
                    for await result in group {
                        collected.append(result)
                    }
                    return collected
                }
                for (accountID, resolution) in results {
                    if case .success = resolution {
                        refreshedAccounts.append(accountID)
                    }
                }
            }
        }
        guard !isStopped() else { return empty }
        var diagnostics: [BridgeDiagnostic] = []
        guard !refreshedAccounts.isEmpty else {
            // 全部刷新失败: 保留 decisions 与诊断, retryArtifact=nil
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_REFRESH_FAILED",
                category: "collector",
                stage: "challenge",
                message: "全部账号令牌刷新失败, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }

        let retryInput: CollectorRunInput?
        do {
            retryInput = try await runInputProvider.retryInput(
                for: module,
                accountIDs: refreshedAccounts
            )
        } catch {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_INPUT_FAILED",
                category: "collector",
                stage: "challenge",
                message: "重试输入组装失败, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        guard let retryInput else {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_INPUT_MISSING",
                category: "collector",
                stage: "challenge",
                message: "重试输入为空, 未发起定向重试",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        let retryResult = await runCollector(
            module,
            retryInput.context,
            retryInput.credentials
        )
        guard !isStopped() else { return empty }
        guard case .success(let retryOutput) = retryResult else {
            diagnostics.append(BridgeDiagnostic(
                code: "CODEX_RETRY_COLLECTOR_FAILED",
                category: "collector",
                stage: "retry",
                message: "定向重试采集失败",
                retryable: true
            ))
            return CodexRetryPhaseResult(
                retryArtifact: nil,
                tokenDecisions: runInputProvider.codexTokenDecisions,
                diagnostics: diagnostics
            )
        }
        let decisions = runInputProvider.codexTokenDecisions
        let retryArtifact = retryOutput.response.artifact

        // 重试仍 401 (freshness=unavailable + failureKind=auth) 的账号
        // 持久化为 needsReauthorization (任务 8, 只影响对应账号).
        if let challengeHandler, let retryArtifact {
            let services: [JSONValue] = {
                guard case .object(let object) = retryArtifact else {
                    return []
                }
                return object["services"]?.arrayValue ?? []
            }()
            let refreshedSet = Set(refreshedAccounts)
            for service in services {
                guard let account = retryAccountID(
                    service: service,
                    decisions: decisions
                ),
                    refreshedSet.contains(account),
                    isAuthFailure(service: service) else {
                    continue
                }
                await challengeHandler.markNeedsReauthorization(
                    for: account,
                    now: nil
                )
            }
        }
        // 任务 7 (UI-05): 重试输出自身的诊断也进入最终合并 (finalizer 去重),
        // 与首轮/merger 诊断统一呈现, 不单独丢弃.
        return CodexRetryPhaseResult(
            retryArtifact: retryArtifact,
            tokenDecisions: decisions,
            diagnostics: retryOutput.response.diagnostics
        )
    }

    /// challenge 账号去重并按本轮决议 index 排序; 决议中不存在的账号
    /// 按 accountID 字典序排尾 (确定性强).
    private static func orderedChallengeAccounts(
        _ challenges: [CodexChallenge],
        decisions: [CodexTokenDecision]
    ) -> [String] {
        var indexByAccount: [String: Int] = [:]
        for decision in decisions {
            if indexByAccount[decision.accountID] == nil {
                indexByAccount[decision.accountID] = decision.index
            }
        }
        let unique = Array(Set(challenges.map(\.accountID)))
        return unique.sorted {
            let left = indexByAccount[$0] ?? Int.max
            let right = indexByAccount[$1] ?? Int.max
            if left != right { return left < right }
            return $0 < $1
        }
    }

    /// 从合并后 service 反查账号: 优先按 currentID 匹配决议,
    /// 失败时按 legacy ID 唯一匹配 (与合并器同规则).
    private func retryAccountID(
        service: JSONValue,
        decisions: [CodexTokenDecision]
    ) -> String? {
        guard case .object(let object) = service,
              case .string(let id)? = object["id"] else {
            return nil
        }
        for decision in decisions where decision.serviceID == id {
            return decision.accountID
        }
        var matched: String?
        for decision in decisions {
            if CodexAccountIdentity.legacyServiceID(for: decision.accountID) == id {
                if matched != nil { return nil }
                matched = decision.accountID
            }
        }
        return matched
    }

    /// 该 service 是否仍为授权失败 (unavailable + auth, 或 legacy 无
    /// freshness 的 error + auth note). 403/429/网络等不视为授权失效.
    private func isAuthFailure(service: JSONValue) -> Bool {
        guard case .object(let object) = service,
              case .string(let status)? = object["status"],
              status == "error" else {
            return false
        }
        if case .string(let failureKind)? = object["failureKind"] {
            return failureKind == "auth"
        }
        // 旧 artifact 无 failureKind: 按 note 文案判断
        if case .string(let note)? = object["note"] {
            return note.contains("登录态已失效")
        }
        return false
    }
}
