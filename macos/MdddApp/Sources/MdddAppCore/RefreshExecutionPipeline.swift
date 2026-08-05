import Foundation
import MdddOnboardingCore

// MARK: - Request / Result

/// 单次刷新执行请求. Scheduler 组装 intent/stale 窗口; Pipeline 不持有 timer 状态.
///
/// 可见性与 `CodexQuotaRecovery` / `RefreshBackoffPolicy` 一致: 模块内 internal,
/// 供 `RefreshScheduler` 与 `@testable` harness 使用. 不提升为 package, 避免
/// 牵连 `CollectorExecuting` / `CollectorRunOutput` / `BridgeResponse` 的级联开放.
struct RefreshPipelineRequest: Sendable {
    let module: CollectorModule
    let intent: RefreshIntent
    let staleAfter: TimeInterval
    let now: Date

    init(
        module: CollectorModule,
        intent: RefreshIntent,
        staleAfter: TimeInterval,
        now: Date
    ) {
        self.module = module
        self.intent = intent
        self.staleAfter = staleAfter
        self.now = now
    }
}

/// 一次刷新成功走完全链路后的可观察结果 (Task 6 填充).
///
/// 类型对齐本仓库真实命名:
/// - 运行产物: `CollectorRunOutput` (`BridgeResponse` + 可选 stderr 诊断)
/// - 凭证写回: `CredentialUpdateApplyResult`
/// - 额度预警候选: `QuotaAlertEvaluator.overThresholdEntries` 返回的
///   `[(key: String, alert: QuotaAlert)]` (无独立 `Entry` 类型)
struct CompletedRun: Sendable {
    let output: CollectorRunOutput
    let credentialApply: CredentialUpdateApplyResult
    let quotaAlertEntries: [(key: String, alert: QuotaAlert)]
    let includesManual: Bool

    init(
        output: CollectorRunOutput,
        credentialApply: CredentialUpdateApplyResult,
        quotaAlertEntries: [(key: String, alert: QuotaAlert)],
        includesManual: Bool
    ) {
        self.output = output
        self.credentialApply = credentialApply
        self.quotaAlertEntries = quotaAlertEntries
        self.includesManual = includesManual
    }
}

/// Pipeline 一次 `run` 的结构化结果. Scheduler 只映射到 phase/timer/回调.
enum RefreshPipelineResult: Sendable {
    case completed(CompletedRun)
    case runInputFailed(CollectorRunInputError)
    case collectorFailed(Error)
    case publishFailed(Error)
    case cancelled
}

// MARK: - Pipeline skeleton

/// 编排单次完整刷新 (run input → collect → Codex recovery → finalize →
/// credential apply → publish → quota entries). 不持有 timer 或 ModuleScheduleState.
///
/// Task 5: 仅骨架, `run` 在 stopped 或未接线时返回 `.cancelled`.
/// Task 6: 迁入 `RefreshScheduler.executeRefresh` 主体.
@MainActor
struct RefreshExecutionPipeline {
    private let executor: any CollectorExecuting
    private let store: ArtifactStore
    private let runInputProvider: (any CollectorRunInputProviding)?
    private let credentialUpdates: CredentialUpdateCoordinator?
    private let codexTokenManager: (any CodexChallengeHandling)?
    private let isStopped: () -> Bool

    init(
        executor: any CollectorExecuting,
        store: ArtifactStore,
        runInputProvider: (any CollectorRunInputProviding)?,
        credentialUpdates: CredentialUpdateCoordinator?,
        codexTokenManager: (any CodexChallengeHandling)?,
        isStopped: @escaping () -> Bool
    ) {
        self.executor = executor
        self.store = store
        self.runInputProvider = runInputProvider
        self.credentialUpdates = credentialUpdates
        self.codexTokenManager = codexTokenManager
        self.isStopped = isStopped
    }

    /// 执行一次刷新. Task 5 骨架: stopped 或未实现路径均返回 `.cancelled`.
    func run(_ request: RefreshPipelineRequest) async -> RefreshPipelineResult {
        // 保留 request 引用, 避免骨架期未使用参数告警; Task 6 使用全部字段.
        _ = request
        _ = executor
        _ = store
        _ = runInputProvider
        _ = credentialUpdates
        _ = codexTokenManager

        if isStopped() {
            return .cancelled
        }
        // 完整链路在 Task 6 迁入; 在 Scheduler 接线前保持无副作用.
        return .cancelled
    }
}
