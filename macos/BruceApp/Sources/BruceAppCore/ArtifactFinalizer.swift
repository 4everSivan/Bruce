import Foundation
import BruceOnboardingCore

// MARK: - ArtifactFinalizer

/// Agent usage 四源合并 finalizer (阶段 C: 从 RefreshScheduler 拆出).
///
/// 职责: 接收首轮输出、retry phase、previous artifact, 执行一次
/// `CodexQuotaSnapshotMerger` 四源合并, 合并 first/retry/merger 诊断
/// 并按 `code|stage|message` 稳定去重, 生成最终 `CollectorRunOutput`.
///
/// 纯逻辑, 不触碰 Keychain 或外部服务; 不持有状态.
struct ArtifactFinalizer: Sendable {
    init() {}

    /// 四源合并并生成最终输出.
    /// - Parameters:
    ///   - firstOutput: 首轮 Collector 输出.
    ///   - retryPhase: Codex 恢复阶段结果 (retry artifact + decisions + diagnostics).
    ///   - previousArtifact: 上一轮已发布 artifact (nil 表示从未成功发布).
    ///   - fallbackDecisions: retry phase 无 decisions 时的回退决议来源
    ///     (来自 runInputProvider.codexTokenDecisions).
    /// - Returns: 合并后的最终输出; 首轮无 artifact 时原样返回首轮输出.
    func finalize(
        firstOutput: CollectorRunOutput,
        retryPhase: CodexRetryPhaseResult,
        previousArtifact: JSONValue?,
        fallbackDecisions: [CodexTokenDecision]
    ) -> CollectorRunOutput {
        guard let firstArtifact = firstOutput.response.artifact else {
            // 首轮无 artifact (异常响应): 维持原响应, 不发布半成品
            return firstOutput
        }
        let decisions = retryPhase.tokenDecisions.isEmpty
            ? fallbackDecisions
            : retryPhase.tokenDecisions
        let merged = CodexQuotaSnapshotMerger().merge(
            previous: previousArtifact,
            first: firstArtifact,
            retry: retryPhase.retryArtifact,
            decisions: decisions
        )
        // 合并 first/retry/token 与 merger 诊断, 按稳定 key 去重
        var collected: [BridgeDiagnostic] = []
        var seen = Set<String>()
        func appendDiagnostics(_ diagnostics: [BridgeDiagnostic]) {
            for diagnostic in diagnostics {
                let key = "\(diagnostic.code)|\(diagnostic.stage)|\(diagnostic.message)"
                if seen.insert(key).inserted {
                    collected.append(diagnostic)
                }
            }
        }
        // 首轮与重试诊断: 仅当最终 artifact 有失败条目时保留 (自愈成功不残留)
        if merged.artifact.hasFailedEntries {
            appendDiagnostics(firstOutput.response.diagnostics)
            appendDiagnostics(retryPhase.diagnostics)
        }
        for diagnostic in merged.diagnostics {
            appendDiagnostics([BridgeDiagnostic(
                code: diagnostic.code,
                category: diagnostic.category,
                stage: diagnostic.stage,
                message: diagnostic.message,
                retryable: diagnostic.retryable
            )])
        }
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: firstOutput.response.runId,
                generatedAt: merged.generatedAtValue
                    ?? firstOutput.response.generatedAt,
                status: merged.recomputedStatus,
                artifact: merged.artifact,
                credentialUpdates: firstOutput.response.credentialUpdates,
                diagnostics: collected,
                credentialChallenges: []
            ),
            stderrDiagnostic: firstOutput.stderrDiagnostic
        )
    }
}
