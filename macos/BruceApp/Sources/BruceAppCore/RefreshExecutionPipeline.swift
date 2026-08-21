import Foundation
import BruceOnboardingCore

// MARK: - Request / Result

/// 单次刷新执行请求. Scheduler 组装 intent/stale 窗口; Pipeline 不持有 timer 状态.
///
/// 可见性与 `CodexQuotaRecovery` / `RefreshBackoffPolicy` 一致: 模块内 internal,
/// 供 `RefreshScheduler` 与 `@testable` harness 使用. 不提升为 package, 避免
/// 牵连 `CollectorExecuting` / `CollectorRunOutput` / `BridgeResponse` 的级联开放.
struct RefreshPipelineRequest: Sendable {
    let module: CollectorModule
    let intent: RefreshIntent
    /// 刷新范围; 定向运行据此向运行输入提供器索取收窄输入, 并由
    /// `ScopedQuotaSnapshotMerger` 合并回上一份完整 artifact.
    let scope: RefreshScope
    let staleAfter: TimeInterval
    let now: Date

    init(
        module: CollectorModule,
        intent: RefreshIntent,
        scope: RefreshScope = .all,
        staleAfter: TimeInterval,
        now: Date
    ) {
        self.module = module
        self.intent = intent
        self.scope = scope
        self.staleAfter = staleAfter
        self.now = now
    }
}

/// 一次刷新走完可发布链路 (或明确的不可发布 bridge 结果) 后的可观察结果.
///
/// 类型对齐本仓库真实命名:
/// - 运行产物: `CollectorRunOutput` (`BridgeResponse` + 可选 stderr 诊断)
/// - 凭证写回: `CredentialUpdateApplyResult`
/// - 额度预警候选: `QuotaAlertEvaluator.overThresholdEntries` 返回的
///   `[(key: String, alert: QuotaAlert)]` (无独立 `Entry` 类型)
/// - `publishedArtifact`: 非 nil 表示 Pipeline 已 `store.publish`; nil 表示
///   auth/error/无 artifact 等未写入路径, Scheduler 只做 phase 映射
struct CompletedRun: Sendable {
    let output: CollectorRunOutput
    let credentialApply: CredentialUpdateApplyResult
    let quotaAlertEntries: [(key: String, alert: QuotaAlert)]
    let includesManual: Bool
    /// 已成功 publish 的 artifact; nil = 本轮未写 store.
    let publishedArtifact: JSONValue?

    init(
        output: CollectorRunOutput,
        credentialApply: CredentialUpdateApplyResult,
        quotaAlertEntries: [(key: String, alert: QuotaAlert)],
        includesManual: Bool,
        publishedArtifact: JSONValue?
    ) {
        self.output = output
        self.credentialApply = credentialApply
        self.quotaAlertEntries = quotaAlertEntries
        self.includesManual = includesManual
        self.publishedArtifact = publishedArtifact
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

// MARK: - Pipeline

/// 编排单次完整刷新 (run input → collect → Codex recovery → finalize →
/// credential apply → publish → quota entries). 不持有 timer 或 ModuleScheduleState.
///
/// 固定顺序 (S2 / Task 6):
/// 1. resolveRunInput
/// 2. loadPreviousArtifact (一轮只读一次)
/// 3. firstCollect
/// 4. optionalCodexRecovery (仅 agentUsage)
/// 5. finalize (ArtifactFinalizer)
/// 6. applyCredentialUpdates
/// 7. publish + 合并 credential 失败诊断 / success→partial 降级
/// 8. evaluateQuotaAlerts (纯候选; 是否弹由 Scheduler 结合 includesManual)
/// 9. return `.completed`
@MainActor
struct RefreshExecutionPipeline {
    private let executor: any CollectorExecuting
    private let store: ArtifactStore
    private let runInputProvider: (any CollectorRunInputProviding)?
    private let credentialUpdates: CredentialUpdateCoordinator?
    private let codexTokenManager: (any CodexChallengeHandling)?
    private let isStopped: () -> Bool
    /// Publish-time clock. `request.now` is entry-time (load-previous / stale);
    /// store metadata must use end-of-run time so lastSuccessAt matches Scheduler.
    private let now: () -> Date

    init(
        executor: any CollectorExecuting,
        store: ArtifactStore,
        runInputProvider: (any CollectorRunInputProviding)?,
        credentialUpdates: CredentialUpdateCoordinator?,
        codexTokenManager: (any CodexChallengeHandling)?,
        isStopped: @escaping () -> Bool,
        now: @escaping () -> Date = { Date() }
    ) {
        self.executor = executor
        self.store = store
        self.runInputProvider = runInputProvider
        self.credentialUpdates = credentialUpdates
        self.codexTokenManager = codexTokenManager
        self.isStopped = isStopped
        self.now = now
    }

    /// 执行一次完整刷新生命周期. 不触碰 ModuleScheduleState / timer.
    func run(_ request: RefreshPipelineRequest) async -> RefreshPipelineResult {
        if isStopped() {
            return .cancelled
        }

        // 1. resolveRunInput — 取不到时不启动进程
        var context: [String: JSONValue] = [:]
        var credentials: [String: JSONValue] = [:]
        if let runInputProvider {
            do {
                if request.scope.isTargeted {
                    let input = try await runInputProvider.scopedRunInput(
                        for: request.module,
                        providers: request.scope.targetProviders
                    )
                    context = input.context
                    credentials = input.credentials
                } else {
                    let input = try await runInputProvider.runInput(for: request.module)
                    context = input.context
                    credentials = input.credentials
                }
            } catch let inputError as CollectorRunInputError {
                return .runInputFailed(inputError)
            } catch {
                // 凭证存储读取等未知错误按依赖缺失走 backoff
                return .runInputFailed(
                    .missingDependency(
                        module: request.module,
                        reason: "读取运行输入失败"
                    )
                )
            }
        }
        if isStopped() {
            return .cancelled
        }

        // 2. loadPreviousArtifact — 同一轮内只读一次, 避免读到本轮 publish 覆盖
        let previousArtifact: JSONValue?
        do {
            previousArtifact = try store.load(
                request.module,
                now: request.now,
                staleAfter: request.staleAfter
            ).artifact
        } catch {
            previousArtifact = nil
        }

        // 3. firstCollect
        let firstResult = await runCollector(
            module: request.module,
            context: context,
            credentials: credentials
        )
        if isStopped() {
            return .cancelled
        }
        let firstOutput: CollectorRunOutput
        switch firstResult {
        case .success(let output):
            firstOutput = output
        case .failure(let error):
            return .collectorFailed(error)
        }

        // 4-5. Codex recovery (agentUsage only) + finalize
        // 无论 challenge/决议/retry 结果如何, first artifact 存在时都四源合并后一次发布.
        let output: CollectorRunOutput
        if request.scope.isTargeted {
            // 定向刷新: 仍允许 Codex 恢复 (仅当目标含 Codex 且首轮带 challenge),
            // 再由 ScopedQuotaSnapshotMerger 把目标结果合并回上一份完整 artifact.
            let recovery = CodexQuotaRecovery()
            let retryPhase = await recovery.handle(
                firstOutput: firstOutput,
                firstCredentials: credentials,
                module: request.module,
                runInputProvider: runInputProvider,
                challengeHandler: codexTokenManager,
                isStopped: isStopped,
                runCollector: { [self] module, context, credentials in
                    await self.runCollector(
                        module: module,
                        context: context,
                        credentials: credentials
                    )
                }
            )
            if isStopped() {
                return .cancelled
            }
            let decisions = retryPhase.tokenDecisions.isEmpty
                ? (runInputProvider?.codexTokenDecisions ?? [])
                : retryPhase.tokenDecisions
            let firstArtifact = firstOutput.response.artifact ?? .object([:])
            let merged = ScopedQuotaSnapshotMerger().merge(
                previous: previousArtifact,
                first: firstArtifact,
                retry: retryPhase.retryArtifact,
                targetProviders: request.scope.targetProviders,
                decisions: decisions
            )
            var collected: [BridgeDiagnostic] = []
            var seen = Set<String>()
            for diagnostic in merged.diagnostics {
                let key = "\(diagnostic.code)|\(diagnostic.stage)|\(diagnostic.message)"
                if seen.insert(key).inserted {
                    collected.append(BridgeDiagnostic(
                        code: diagnostic.code,
                        category: diagnostic.category,
                        stage: diagnostic.stage,
                        message: diagnostic.message,
                        retryable: diagnostic.retryable
                    ))
                }
            }
            output = CollectorRunOutput(
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
        } else if request.module == .agentUsage {
            let recovery = CodexQuotaRecovery()
            let retryPhase = await recovery.handle(
                firstOutput: firstOutput,
                firstCredentials: credentials,
                module: request.module,
                runInputProvider: runInputProvider,
                challengeHandler: codexTokenManager,
                isStopped: isStopped,
                runCollector: { [self] module, context, credentials in
                    await self.runCollector(
                        module: module,
                        context: context,
                        credentials: credentials
                    )
                }
            )
            if isStopped() {
                return .cancelled
            }
            output = ArtifactFinalizer().finalize(
                firstOutput: firstOutput,
                retryPhase: retryPhase,
                previousArtifact: previousArtifact,
                fallbackDecisions: runInputProvider?.codexTokenDecisions ?? []
            )
        } else {
            output = firstOutput
        }

        // 6-8. credential apply → publish → quota (仅可发布路径)
        return finishPublishablePath(output: output, request: request)
    }

    // MARK: - Publishable path

    /// 对齐原 handleResult success 分支: auth-no-artifact / status.error 不写回不发布;
    /// 其余路径先 apply 凭证, 再 publish, 失败诊断与 partial 降级在 Pipeline 落地.
    private func finishPublishablePath(
        output: CollectorRunOutput,
        request: RefreshPipelineRequest
    ) -> RefreshPipelineResult {
        let response = output.response
        let includesManual = request.intent.includesManual
        let emptyApply = CredentialUpdateApplyResult()

        let hasAuthError = response.diagnostics.contains { $0.category == "auth" }
        // 任务 9: auth diagnostic 只在拿不到 artifact 时整模块 authRequired.
        if hasAuthError && response.artifact == nil {
            return .completed(CompletedRun(
                output: output,
                credentialApply: emptyApply,
                quotaAlertEntries: [],
                includesManual: includesManual,
                publishedArtifact: nil
            ))
        }
        if response.status == .error {
            return .completed(CompletedRun(
                output: output,
                credentialApply: emptyApply,
                quotaAlertEntries: [],
                includesManual: includesManual,
                publishedArtifact: nil
            ))
        }

        // 6. applyCredentialUpdates — 轮换令牌先于 artifact 发布写回
        var publishedDiagnostics = response.diagnostics
        var effectiveStatus = response.status
        var applyResult = emptyApply
        if !response.credentialUpdates.isEmpty {
            applyResult = credentialUpdates?.apply(
                credentialUpdates: response.credentialUpdates
            ) ?? emptyApply
            if !applyResult.failed.isEmpty {
                for failure in applyResult.failed {
                    publishedDiagnostics.append(BridgeDiagnostic(
                        code: "CREDENTIAL_PERSIST_FAILED",
                        category: "storage",
                        stage: "credentialUpdate",
                        message: "\(failure.provider) 凭证写回失败",
                        retryable: true
                    ))
                }
                // 有 artifact 时将 success 降级为 partial (在 Pipeline 落地)
                if effectiveStatus == .success, response.artifact != nil {
                    effectiveStatus = .partial
                }
            }
        }

        let finalOutput = CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: response.schemaVersion,
                runId: response.runId,
                generatedAt: response.generatedAt,
                status: effectiveStatus,
                artifact: response.artifact,
                credentialUpdates: response.credentialUpdates,
                diagnostics: publishedDiagnostics,
                credentialChallenges: response.credentialChallenges
            ),
            stderrDiagnostic: output.stderrDiagnostic
        )

        guard let artifact = response.artifact else {
            // 凭证可能已写回; 无 artifact → Scheduler 走 schema backoff
            return .completed(CompletedRun(
                output: finalOutput,
                credentialApply: applyResult,
                quotaAlertEntries: [],
                includesManual: includesManual,
                publishedArtifact: nil
            ))
        }

        // 7. publish — attemptedAt 取发布时刻 (非 request.now / 入口时刻),
        // 与迁出前 handleResult 使用 clock.now() 的语义一致, 避免 collect/recovery
        // 耗时导致 store lastSuccessAt 与 Scheduler lastSuccessAt 分叉.
        do {
            try store.publish(artifact, for: request.module, attemptedAt: now())
        } catch {
            // 凭证已 apply; 发布失败不更新 lastPublishedDiagnostics
            return .publishFailed(error)
        }

        // 8. evaluateQuotaAlerts — 纯候选; 是否弹由 Scheduler 结合 includesManual
        let entries = QuotaAlertEvaluator.overThresholdEntries(artifact: artifact)
        return .completed(CompletedRun(
            output: finalOutput,
            credentialApply: applyResult,
            quotaAlertEntries: entries,
            includesManual: includesManual,
            publishedArtifact: artifact
        ))
    }

    // MARK: - Collector

    private func runCollector(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async -> Result<CollectorRunOutput, Error> {
        do {
            let output = try await executor.run(
                module: module,
                context: context,
                credentials: credentials
            )
            return .success(output)
        } catch is CancellationError {
            return .failure(CancellationError())
        } catch {
            return .failure(error)
        }
    }
}
