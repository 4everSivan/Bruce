import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - Codex challenge scenarios

extension RefreshSchedulerHarness {
static func codexChallengeTriggersSingleTargetedRetry(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let retry = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 40,
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: [
            "codexQuotaRetryOnly": .boolean(true),
        ],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("fresh-at"),
                ]),
            ]),
        ]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    // 直接触发一次运行 (不依赖计时器)
    let timers = FakeTimerScheduler()
    _ = timers
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)

    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 首轮 + 重试共 2 次运行, 重试上下文只含被挑战账号
    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "应执行首轮 + 一次定向重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    let retryContext = executor.receivedContexts.last ?? [:]
    try refreshExpect(
        retryContext["codexQuotaRetryOnly"] == .boolean(true),
        "重试上下文必须带 codexQuotaRetryOnly=true"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == ["acc-1"],
        "只应重试被挑战账号, got \(retryProvider.retriedAccountIDs)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "每轮最多一次 refreshAfterAccessRejected"
    )
    // 全轮只发布一次 (合并后)
    try refreshExpect(publishedCount == 1, "全轮只能发布一次 artifact, got \(publishedCount)")
    // 重试成功: 发布的是新额度与新 capturedAt, 非 Codex 部分保留
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"] else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    let codexService = services.first { $0.stringId() == mergerService1 }
    guard case .object(let codexObject)? = codexService,
          case .string(let status)? = codexObject["status"],
          case .string(let capturedAt)? = codexObject["capturedAt"] else {
        throw RefreshTestFailure.expectation("codex service 结构不符")
    }
    try refreshExpect(status == "ok", "重试成功应发布 ok 状态")
    try refreshExpect(capturedAt == "2026-07-28T12:01:00Z", "应使用新 capturedAt")
    // agents 保留首轮
    guard case .array(let agents)? = storedObject["agents"],
          case .object(let agent)? = agents.first,
          case .string(let agentID)? = agent["id"] else {
        throw RefreshTestFailure.expectation("agents 结构不符")
    }
    try refreshExpect(agentID == "codex", "agents 必须保留首次结果")
    // 非 codex service 保留首轮
    try refreshExpect(
        services.contains { $0.stringId() == "kimi" },
        "非 codex service 必须保留"
    )
}

/// 12.1.3: 重试响应仍带 challenge 时不再触发第三次 Collector.
static func codexRetryChallengeDoesNotTriggerThirdRun(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    executor.retryHasChallenge = true
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-2"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "重试中的 challenge 不得触发第三次 Collector, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "每轮最多一次 refreshAfterAccessRejected"
    )
    // 重试仍 401 -> 账号持久化为 needsReauthorization (任务 8)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization == ["acc-1"],
        "第二次 401 必须持久化 needsReauthorization, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 12.1.4: 强制刷新失败 (需要重新授权) 不重试, 首次结果原样发布, 不整模块 authRequired.
static func codexForceRefreshFailureKeepsFirstArtifact(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .failure(.needsReauthorization(accountID: "acc-1")),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-3"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(context: [:], credentials: [:])
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var lastStatus: ModuleRunState?
    scheduler.onStatusChange = { _, state, _ in lastStatus = state }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 刷新失败 -> 不重试, 只跑首轮
    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "刷新失败不得发起重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.isEmpty,
        "刷新失败不得请求重试输入"
    )
    // 模块级状态不进入 authRequired (artifact 存在, 部分结果照常发布)
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "部分失败不得使整个模块 authRequired"
    )
    try refreshExpect(
        lastStatus == .partial,
        "部分失败状态应为 partial, got \(String(describing: lastStatus))"
    )
}

/// 12.1.8/12.1.9: 重试 error 保留旧 windows/plan/extra/capturedAt, 只更新 status/note.
/// 旧额度来自上一轮已发布快照 (四源合并的 previous 源).
static func codexRetryErrorPreservesLastGoodQuota(
    repository: URL
) async throws {
    let previous = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 45,
        generatedAt: "2026-07-28T10:00:00Z"
    )
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let retry = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:01:00Z",
        note: "额度查询暂时失败, 请稍后重试",
        failureKind: "network"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-3",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-4"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // 预发布上一轮快照 (previous 源)
    try store.publish(previous, for: .agentUsage, attemptedAt: Date())

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"],
          case .object(let codexObject)? = services.first(where: {
              $0.stringId() == mergerService1
          }) else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    try refreshExpect(
        codexObject["status"] == .string("error"),
        "重试 error 应保留 error 状态"
    )
    // 旧额度数据保留: windows 仍带 45%
    guard case .array(let windows)? = codexObject["windows"],
          let window = windows.first,
          let windowObject = window.objectValue,
          let usedPercent = JSONNumber.double(windowObject["usedPercent"]) else {
        throw RefreshTestFailure.expectation("旧 windows 必须保留")
    }
    try refreshExpect(usedPercent == 45, "暂时失败必须保留旧额度窗口")
    try refreshExpect(
        codexObject["capturedAt"] == .string("2026-07-28T10:00:00Z"),
        "暂时失败必须保留旧 capturedAt"
    )
    try refreshExpect(
        codexObject["plan"] == .string("team"),
        "暂时失败必须保留旧 plan"
    )
    // 四源语义: 失败 + 有旧数据 -> freshness=stale
    try refreshExpect(
        codexObject["freshness"] == .string("stale"),
        "失败 + 有旧数据必须为 stale, got \(codexObject["freshness"] ?? .null)"
    )
    try refreshExpect(
        codexObject["failureKind"] == .string("network"),
        "必须保留本轮 failureKind=network"
    )
    // 网络失败不清除凭证 (第二次 401 才持久化重新授权)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization.isEmpty,
        "网络失败不得持久化重新授权, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 12.1.5/12.1.6: 无 challenge 时单轮发布, 不重试.
static func codexWithoutChallengeRunsOnce(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "ok",
        usedPercent: 10,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager
    )
    defer { try? FileManager.default.removeItem(at: root) }

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "无 challenge 只运行一次, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "无 challenge 只发布一次")
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount.isEmpty,
        "无 challenge 不得调用 refreshAfterAccessRejected"
    )
}

}
