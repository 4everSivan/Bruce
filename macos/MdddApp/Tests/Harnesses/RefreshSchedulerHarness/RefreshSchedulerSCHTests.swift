import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

// MARK: - SCH-01 ~ SCH-12

extension RefreshSchedulerHarness {
// MARK: - 任务 5: Scheduler 单出口四源合并 (SCH-01 ~ SCH-12)

/// 通用: 读取发布后的最终 artifact (含四源合并结果).
static func publishedArtifact(
    _ store: ArtifactStore
) throws -> JSONValue? {
    try store.load(.agentUsage, now: Date(), staleAfter: 3600).artifact
}

// SCH-01: 无 challenge, 本轮 Codex network fail -> 1 次采集, 1 次发布,
// 最终为 previous + first 四源合并
static func schNoChallengeNetworkFailSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
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
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "无 challenge 只运行一次, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-01 只发布一次")
    // 最终 artifact 是合并器输出 (决策账号按 index 重排后的 currentID)
    let artifact = try publishedArtifact(store)
    let service = try mergerServiceValue(artifact ?? .null, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("unavailable"),
        "无 previous 时 network fail 应为 unavailable"
    )
}

// SCH-05: challenge, token refresh 失败 -> 1 次采集, 1 次发布
static func schRefreshFailureSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = true
    // refresh 全部失败 -> 不重试
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .failure(.refreshFailed(
            accountID: mergerAccount1, reason: .networkError
        )),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: mergerAccount1, outcome: .temporarilyUnavailable(retryAt: nil)),
    ]
    let (scheduler, _, root) = try makeSchedulerWithCodex(
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
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "refresh 失败不得重试, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-05 仍须发布一次 (合并器输出)")
}

// SCH-06: challenge, retry input 为 nil -> 1 次采集, 1 次发布
static func schRetryNilSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexRetryInput = nil
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

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retry nil 不得重试"
    )
    try refreshExpect(publishedCount == 1, "SCH-06 仍须发布一次")
}

// SCH-07: challenge, retry input 抛错 -> 1 次采集, 1 次发布
static func schRetryThrowsSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = ThrowingRetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
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

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retry 抛错不得重试"
    )
    try refreshExpect(publishedCount == 1, "SCH-07 仍须发布一次")
}

// SCH-08: challenge, retry Collector 失败 -> 2 次采集, 1 次发布
static func schRetryCollectorFailureSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.retryError = CodexRunInputFixtureError()
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
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
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: ["codexQuotaAccounts": .object([:])]
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

    var publishedCount = 0
    scheduler.onArtifactChange = { _, _ in publishedCount += 1 }
    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "SCH-08 应执行一次 retry, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(publishedCount == 1, "SCH-08 只发布一次")
}

// SCH-09: challenge, retry 成功 -> 2 次采集, 1 次发布, 四源合并
static func schRetrySuccessSinglePublish(
    repository: URL
) async throws {
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: retry
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
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
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: ["codexQuotaAccounts": .object([:])]
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
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "SCH-09 应执行一次 retry"
    )
    try refreshExpect(publishedCount == 1, "SCH-09 只发布一次")
    // 合并结果: retry 成功 -> fresh + capturedAt
    let artifact = try publishedArtifact(store)
    let service = try mergerServiceValue(artifact ?? .null, id: mergerService1)
    try refreshExpect(
        service["freshness"] == .string("fresh"),
        "SCH-09 最终应为 fresh"
    )
    try refreshExpect(
        service["capturedAt"] == .string("2026-07-28T12:01:00Z"),
        "SCH-09 应保留 retry capturedAt"
    )
}

// SCH-10: first Collector 无 artifact 失败 -> 0 次发布, previous 保留
static func schFirstNoArtifactNoPublish(
    repository: URL
) async throws {
    let executor = AuthFailingExecutor()
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    let (scheduler, _, root) = try makeSchedulerWithCodex(
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
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .authRequired)

    try refreshExpect(publishedCount == 0, "SCH-10 无 artifact 不得发布")
}

// SCH-11: merger 产生 legacy 歧义诊断 -> 诊断进入最终 artifact/状态
static func schMergerDiagnosticPreserved(
    repository: URL
) async throws {
    // 两个账号共享 legacyID -> 歧义诊断 (任务 4 已构造场景)
    let accountA = "shareme-1a"
    let accountB = "shareme-1b"
    let serviceA = CodexAccountIdentity.serviceID(for: accountA)
    let serviceB = CodexAccountIdentity.serviceID(for: accountB)
    let first = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: serviceA, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
            mergerCodexService(
                id: serviceB, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "network", note: "额度查询暂时失败, 请稍后重试"
            ),
        ],
        generatedAt: "2026-07-28T12:00:00Z"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first, retryArtifact: first
    )
    executor.firstHasChallenge = false
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(context: [:], credentials: [:])
    retryProvider.codexTokenDecisions = [
        mergerDecision(index: 0, accountID: accountA, outcome: .available(
            accessToken: "at", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
        mergerDecision(index: 1, accountID: accountB, outcome: .available(
            accessToken: "at2", expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        )),
    ]
    let (scheduler, store, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: executor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }
    // 预置含共享 legacyID 的旧快照: 两个当前账号共享同一 legacyID,
    // 且 previous 中存在该 legacy service -> merger 产生歧义诊断.
    let legacyID = CodexAccountIdentity.legacyServiceID(for: accountA)
    try refreshExpect(
        legacyID == CodexAccountIdentity.legacyServiceID(for: accountB),
        "前置条件: 两个账号必须共享 legacyID"
    )
    try store.publish(
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-28T11:00:00Z"),
            "agents": .array([]),
            "services": .array([
                .object([
                    "id": .string(legacyID),
                    "name": .string("Codex · 旧账号"),
                    "app": .string("codex"),
                    "status": .string("ok"),
                    "capturedAt": .string("2026-07-28T11:00:00Z"),
                    "windows": .array([]),
                ]),
            ]),
            "totalCostUsd": .null,
        ]),
        for: .agentUsage,
        attemptedAt: Date(timeIntervalSince1970: 1_752_000_000)
    )

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)
    // 静态契约: 首轮 + 重试 + merger 诊断都进入最终输出 (任务 5 收敛为
    // 一个 finalizer, 不再有绕过 merger 的独立出口). 由 Scheduler 实现
    // 保证; 此处断言流程完成不崩溃 (实现细节见 handleCodexChallenges).
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "SCH-11 一轮后应 idle"
    )
    // UI-04/05: 合并期诊断 (legacy 歧义) 到达可观察边界, 且按
    // code|stage|message 去重后只保留一条.
    let published = scheduler.lastPublishedDiagnostics
    try refreshExpect(
        published.contains { $0.code == "CODEX_LEGACY_AMBIGUOUS" },
        "merger 歧义诊断必须到达发布诊断边界, got \(published.map(\.code))"
    )
    let ambiguous = published.filter { $0.code == "CODEX_LEGACY_AMBIGUOUS" }
    try refreshExpect(
        ambiguous.count == 1,
        "同类诊断必须去重为一条, got \(ambiguous.count)"
    )
}

/// 任务 11: 迁移 gate 未开放时 retryInput 返回 nil (调度器持有
/// 自定义提供器), 即使刷新成功也不发起定向重试, 首轮结果原样保留.
static func codexRetryInputNilWhenGatedKeepsFirstArtifact(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z",
        note: "登录态已失效, 请重新登录该账号"
    )
    let executor = ChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        "acc-1": .success(
            accessToken: "fresh-at-gated",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    // gate 关闭: 提供器对定向重试返回 nil
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-gated"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = nil
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

    try refreshExpect(
        executor.runCount[.agentUsage] == 1,
        "retryInput 返回 nil 时不得发起重试运行, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount["acc-1"] == 1,
        "challenge 仍应调用 refreshAfterAccessRejected"
    )
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == ["acc-1"],
        "retryInput 应被询问被挑战账号"
    )
    try refreshExpect(
        scheduler.moduleState(for: .agentUsage)?.phase == .idle,
        "无重试时模块保持 idle"
    )
    try refreshExpect(
        lastStatus == .partial,
        "gate 关闭时保留首轮 partial 结果, got \(String(describing: lastStatus))"
    )
}

/// 任务 8: 两个账号同时 401 在同一轮完成刷新和重试 (单次 retry-only 运行),
/// 各自 OAuth 刷新只调用一次.
static func codexTwoAccounts401SingleCycle(
    repository: URL
) async throws {
    let account2 = "acc-2"
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // retry artifact 含两个账号 service (currentID)
    let firstServices = mergerArtifact(
        codexServices: [mergerCodexService(
            id: mergerService1, status: "ok", usedPercent: 40,
            capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
        )],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "ok", usedPercent: 40,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    _ = firstServices
    let executor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry,
        challengedAccounts: [mergerAccount1, account2]
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "fresh-a",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
        account2: .success(
            accessToken: "fresh-b",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                mergerAccount1: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-a"),
                ]),
                account2: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-b"),
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
        mergerDecision(index: 1, accountID: account2, outcome: .available(
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
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    // 单周期最多两次 Collector
    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "两账号 401 必须一轮完成, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    // 两个账号的 OAuth 刷新都只调用一次
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount[mergerAccount1] == 1,
        "acc-1 刷新必须只调用一次"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount[account2] == 1,
        "acc-2 刷新必须只调用一次"
    )
    // retry 输入一次包含两个账号
    try refreshExpect(
        retryProvider.retriedAccountIDs.last == [mergerAccount1, account2],
        "retry 输入必须一次包含两个账号, got \(retryProvider.retriedAccountIDs)"
    )
    // 全轮只发布一次
    try refreshExpect(publishedCount == 1, "全轮只能发布一次, got \(publishedCount)")
    // 两个账号都发布成功数据
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"] else {
        throw RefreshTestFailure.expectation("发布 artifact 结构不符")
    }
    let acc1 = services.first { $0.stringId() == mergerService1 }
    let acc2 = services.first { $0.stringId() == mergerService2 }
    try refreshExpect(acc1 != nil && acc2 != nil, "两个账号 service 都必须发布")
    // 第二次 401 不触发 (两个都成功)
    try refreshExpect(
        tokenManager.markedNeedsReauthorization.isEmpty,
        "重试成功后不得持久化重新授权, got \(tokenManager.markedNeedsReauthorization)"
    )
}

/// 任务 8: 第二次 401 只影响对应账号 (另一账号成功保持 connected).
static func codexSecond401OnlyAffectsItsAccount(
    repository: URL
) async throws {
    let account2 = "acc-2"
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // acc-1 重试仍 401, acc-2 重试成功
    let retry = mergerArtifact(
        codexServices: [
            mergerCodexService(
                id: mergerService1, status: "error", usedPercent: 0,
                capturedAt: nil, freshness: "unavailable",
                failureKind: "auth", note: "登录态已失效, 请重新登录该账号"
            ),
            mergerCodexService(
                id: mergerService2, status: "ok", usedPercent: 55,
                capturedAt: "2026-07-28T12:01:00Z", freshness: "fresh"
            ),
        ],
        generatedAt: "2026-07-28T12:01:00Z"
    )
    let executor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: retry,
        challengedAccounts: [mergerAccount1, account2]
    )
    let tokenManager = StubCodexTokenManager()
    tokenManager.resolutions = [
        mergerAccount1: .success(
            accessToken: "fresh-a2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
        account2: .success(
            accessToken: "fresh-b2",
            expiresAt: Date(timeIntervalSince1970: 1_752_000_000)
        ),
    ]
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                mergerAccount1: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-a2"),
                ]),
                account2: .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-b2"),
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
        mergerDecision(index: 1, accountID: account2, outcome: .available(
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

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        executor.runCount[.agentUsage] == 2,
        "单周期最多两次 Collector, got \(executor.runCount[.agentUsage] ?? 0)"
    )
    // 第二次 401 只持久化 acc-1
    try refreshExpect(
        tokenManager.markedNeedsReauthorization == [mergerAccount1],
        "第二次 401 只影响对应账号, got \(tokenManager.markedNeedsReauthorization)"
    )
    // acc-2 成功数据保留
    let stored = try store.load(.agentUsage, now: Date(), staleAfter: 3600)
    guard case .object(let storedObject) = stored.artifact,
          case .array(let services)? = storedObject["services"],
          case .object(let acc2Object)? = services.first(where: {
              $0.stringId() == mergerService2
          }) else {
        throw RefreshTestFailure.expectation("acc-2 成功 service 必须发布")
    }
    try refreshExpect(
        acc2Object["freshness"] == .string("fresh"),
        "acc-2 重试成功必须为 fresh"
    )
}

/// 任务 8: 非法 challenge (不属于本轮注入账号) 被丢弃, 不触发重试.
static func codexInvalidChallengeIgnored(
    repository: URL
) async throws {
    let first = makeCodexQuotaArtifact(
        status: "error",
        usedPercent: 0,
        generatedAt: "2026-07-28T12:00:00Z"
    )
    // 注入账号是 acc-1, 但 challenge 指向 acc-9 (非法)
    let tokenManager = StubCodexTokenManager()
    let retryProvider = RetryInputProvider()
    retryProvider.firstInput = CollectorRunInput(
        context: ["capabilities": .array([.string("externalQuotas")])],
        credentials: [
            "codexQuotaAccounts": .object([
                "acc-1": .object([
                    "display_name": .string("Codex · user"),
                    "access_token": .string("first-at-legal"),
                ]),
            ]),
        ]
    )
    retryProvider.codexRetryInput = CollectorRunInput(
        context: ["codexQuotaRetryOnly": .boolean(true)],
        credentials: [:]
    )
    // 自定义 executor: challenge 指向未注入账号
    let invalidExecutor = MultiChallengeSequenceExecutor(
        firstArtifact: first,
        retryArtifact: first,
        challengedAccounts: ["acc-9"]
    )
    let (scheduler, _, root) = try makeSchedulerWithCodex(
        repository: repository,
        executor: invalidExecutor,
        tokenManager: tokenManager,
        retryProvider: retryProvider
    )
    defer { try? FileManager.default.removeItem(at: root) }

    scheduler.start()
    scheduler.enableModule(.agentUsage)
    try await triggerFirstRefresh(scheduler: scheduler, repository: repository)
    await waitForPhase(scheduler, module: .agentUsage, phase: .idle)

    try refreshExpect(
        invalidExecutor.runCount[.agentUsage] == 1,
        "非法 challenge 不得触发重试, got \(invalidExecutor.runCount[.agentUsage] ?? 0)"
    )
    try refreshExpect(
        tokenManager.refreshAfterAccessRejectedCount.isEmpty,
        "非法 challenge 不得调用刷新"
    )
}

/// 直接触发一次刷新运行 (start 后 enableModule 会排 0 延迟计时器).
@MainActor
static func triggerFirstRefresh(
    scheduler: RefreshScheduler,
    repository: URL
) async throws {
    scheduler.refresh(.agentUsage)
}

}
