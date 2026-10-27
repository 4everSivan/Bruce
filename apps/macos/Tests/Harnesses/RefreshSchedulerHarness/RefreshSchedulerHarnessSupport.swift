import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

enum RefreshTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
func refreshExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw RefreshTestFailure.expectation(message)
    }
}

// MARK: - Manual clock

@MainActor
final class ManualClock: RefreshClock {
    private(set) var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_786_000_000)) {
        current = start
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Fake timer

@MainActor
final class FakeTimerToken: RunnerTimerToken {
    var isCancelled = false
    let action: @MainActor () -> Void
    let delay: Double

    init(delay: Double, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() { isCancelled = true }

    func fire() {
        guard !isCancelled else { return }
        action()
    }
}

@MainActor
final class FakeTimerScheduler: RunnerTimerScheduling {
    private(set) var tokens: [FakeTimerToken] = []

    func schedule(
        after seconds: Double,
        action: @escaping @MainActor () -> Void
    ) -> RunnerTimerToken {
        let token = FakeTimerToken(delay: seconds, action: action)
        tokens.append(token)
        return token
    }

    var pendingCount: Int { tokens.filter { !$0.isCancelled }.count }

    var lastDelay: Double? { tokens.last?.delay }

    func fireFirst() {
        guard let first = tokens.first(where: { !$0.isCancelled }) else { return }
        first.fire()
    }

    func fireAll() {
        for token in tokens { token.fire() }
    }
}

// MARK: - Mock collector executor

@MainActor
final class MockCollectorExecutor: CollectorExecuting {
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var cancelModuleCount: [CollectorModule: Int] = [:]
    private(set) var cancelAllCount = 0
    var blocksUntilReleased = false
    var repository: URL?
    /// 非 nil 时优先于 fixture, 供额度预警等需要定制 services 的用例.
    var artifactOverride: JSONValue?
    /// 每次调用收到的 context, 供 C062 额度节流用例断言.
    private(set) var receivedContexts: [[String: JSONValue]] = []

    private var pending: [CollectorModule: [CheckedContinuation<CollectorRunOutput, Error>]] = [:]
    /// C062: 记录本轮是否为 localUsageOnly, 供 release 返回本地专用 artifact.
    private var pendingLocalOnly: [CollectorModule: Bool] = [:]

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        receivedContexts.append(context)
        let localOnly = isLocalOnlyContext(context)
        pendingLocalOnly[module] = localOnly

        if blocksUntilReleased {
            return try await withCheckedThrowingContinuation { continuation in
                pending[module, default: []].append(continuation)
            }
        }
        return try makeOutput(for: module, localOnly: localOnly)
    }

    func release(module: CollectorModule) {
        let continuations = pending[module] ?? []
        pending[module] = []
        let localOnly = pendingLocalOnly[module] ?? false
        for c in continuations {
            do {
                let output = try makeOutput(for: module, localOnly: localOnly)
                c.resume(returning: output)
            } catch {
                c.resume(throwing: error)
            }
        }
    }

    func release(module: CollectorModule, throwing error: Error) {
        let continuations = pending[module] ?? []
        pending[module] = []
        for c in continuations { c.resume(throwing: error) }
    }

    func cancel(module: CollectorModule) {
        cancelModuleCount[module, default: 0] += 1
        let continuations = pending[module] ?? []
        pending[module] = []
        for c in continuations { c.resume(throwing: CancellationError()) }
    }

    func cancelAll() {
        cancelAllCount += 1
        for (module, continuations) in pending {
            for c in continuations { c.resume(throwing: CancellationError()) }
            pending[module] = []
        }
    }

    var hasPending: Bool {
        pending.values.contains { !$0.isEmpty }
    }

    private func makeOutput(
        for module: CollectorModule,
        localOnly: Bool
    ) throws -> CollectorRunOutput {
        guard let repository else {
            throw RefreshTestFailure.expectation(
                "mock collector has no fixture repository"
            )
        }
        var artifact = try artifactOverride ?? loadFixture(
            repository: repository,
            module: module
        )
        if localOnly, var object = artifact.objectValue {
            // 生产 collector 在 localUsageOnly 下返回空 services; mock 保持一致,
            // 否则本地 run 会伪造一笔「刚查询成功」的额度时间戳.
            object["services"] = .array([])
            artifact = .object(object)
        }
        let response = BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .success,
            artifact: artifact,
            credentialUpdates: [],
            diagnostics: [],
        credentialChallenges: []
        )
        return CollectorRunOutput(response: response, stderrDiagnostic: nil)
    }

    private func isLocalOnlyContext(_ context: [String: JSONValue]) -> Bool {
        if case .boolean(true)? = context["localUsageOnly"] {
            return true
        }
        return false
    }
}

// MARK: - Quota alert capture

@MainActor
final class AlertCapture {
    var items: [QuotaAlert] = []
}

// MARK: - Fixture loader

@MainActor
func loadFixture(
    repository: URL,
    module: CollectorModule,
    variant: String = "valid"
) throws -> JSONValue {
    let url = repository
        .appendingPathComponent("tests/fixtures/artifacts")
        .appendingPathComponent(module.rawValue)
        .appendingPathComponent("\(variant).json")
    let root = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as? [String: Any]
    guard var artifact = root?["artifact"] as? [String: Any] else {
        throw RefreshTestFailure.expectation("fixture has no artifact")
    }
    artifact["schemaVersion"] = 1
    artifact["module"] = module.rawValue
    return try JSONDecoder().decode(
        JSONValue.self,
        from: JSONSerialization.data(withJSONObject: artifact, options: [.sortedKeys])
    )
}

@MainActor
func makeSuccessOutput(artifact: JSONValue) -> CollectorRunOutput {
    CollectorRunOutput(
        response: BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .success,
            artifact: artifact,
            credentialUpdates: [],
            diagnostics: [],
        credentialChallenges: []
        ),
        stderrDiagnostic: nil
    )
}

@MainActor
func makeErrorOutput(
    category: String,
    code: String = "COLLECTOR_FAILED"
) -> CollectorRunOutput {
    CollectorRunOutput(
        response: BridgeResponse(
            schemaVersion: 1,
            runId: UUID().uuidString.lowercased(),
            generatedAt: "2026-07-28T12:00:00Z",
            status: .error,
            artifact: nil,
            credentialUpdates: [],
            diagnostics: [BridgeDiagnostic(
                code: code,
                category: category,
                stage: "collect",
                message: "fixture error",
                retryable: true
            )],
        credentialChallenges: []
        ),
        stderrDiagnostic: nil
    )
}

// MARK: - Shared quota policy (T15)

/// 额度门禁 / 回填经进程内静态库 (共享 collector-policy) 计算, 与生产同一路径 (T16).
@MainActor
enum HarnessQuotaPolicy {
    static let shared = CollectorQuotaPolicy.inProcess()

    /// 原始传输 (policy-request-v1 → policy-response-v1), 供脚本化传输透传.
    static func transport(_ input: Data) async throws -> Data {
        InProcessQuotaPolicyTransport.call(input)
    }

    static func plan(
        previous: JSONValue?,
        now: Date,
        interval: TimeInterval,
        forceRefresh: Bool,
        bypassCooldown: Bool,
        suppressExternalQuotas: Bool = false,
        enabledProviders: Set<SubscriptionProviderID>? = nil
    ) async throws -> QuotaRunPolicy {
        try await shared.plan(QuotaPlanInput(
            previous: previous,
            now: now,
            interval: interval,
            forceRefresh: forceRefresh,
            bypassCooldown: bypassCooldown,
            suppressExternalQuotas: suppressExternalQuotas,
            enabledProviders: enabledProviders
        ))
    }

    static func merge(
        previous: JSONValue?,
        current: JSONValue,
        policy: QuotaRunPolicy,
        now: Date,
        interval: TimeInterval
    ) async throws -> JSONValue {
        try await shared.merge(
            previous: previous,
            current: current,
            policy: policy,
            now: now,
            interval: interval
        )
    }
}

// MARK: - Test factory

@MainActor
func makeScheduler(
    repository: URL,
    executor: MockCollectorExecutor,
    clock: ManualClock,
    timers: FakeTimerScheduler,
    reachability: (any NetworkReachabilityProviding)? = nil,
    screenLock: (any ScreenLockStateProviding)? = nil,
    refreshInterval: TimeInterval = 1800,
    quotaRefreshInterval: TimeInterval = 0,
    wakeDedupSeconds: TimeInterval = 0
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    executor.repository = repository
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Bruce-sched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ArtifactStore(rootURL: root)
    let config = SchedulerConfiguration(
        refreshInterval: refreshInterval,
        staleAfter: 3600,
        maxBackoffRetries: 3,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2,
        quotaRefreshInterval: quotaRefreshInterval,
        wakeDedupSeconds: wakeDedupSeconds
    )
    let scheduler = RefreshScheduler(
        executor: executor,
        store: store,
        clock: clock,
        timerScheduler: timers,
        configuration: config,
        jitterProvider: { 0 },
        registerWakeNotifications: false,
        networkReachability: reachability,
        screenLockState: screenLock
    )
    return (scheduler, store, root)
}

/// 确定性网络可达性桩: 测试驱动 `setAvailable` 触发与生产相同的主线程回调.
@MainActor
final class StubNetworkReachability: NetworkReachabilityProviding {
    private(set) var isNetworkAvailable: Bool
    var onReachabilityChange: ((Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isAvailable: Bool) {
        self.isNetworkAvailable = isAvailable
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setAvailable(_ available: Bool) {
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        onReachabilityChange?(available)
    }
}

/// 确定性屏幕锁定状态桩 (C064): 测试驱动 `setLocked` 触发与生产相同的主线程回调.
@MainActor
final class StubScreenLockState: ScreenLockStateProviding {
    private(set) var isScreenLocked: Bool
    var onScreenLockStateChange: ((Bool) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(isLocked: Bool) {
        self.isScreenLocked = isLocked
    }

    func start() {
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    func setLocked(_ locked: Bool) {
        guard locked != isScreenLocked else { return }
        isScreenLocked = locked
        onScreenLockStateChange?(locked)
    }
}

@MainActor
func waitForRunCount(
    _ provider: @escaping @MainActor () -> Int,
    count: Int
) async {
    for _ in 0..<1_000 {
        if provider() >= count { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
func waitForPhase(
    _ scheduler: RefreshScheduler,
    module: CollectorModule,
    phase: ModuleScheduleState.Phase
) async {
    for _ in 0..<1_000 {
        if scheduler.moduleState(for: module)?.phase == phase { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// MARK: - Custom executors for specific test scenarios

/// 按调用轮次返回不同响应: 首轮含 Codex accessRejected challenge,
/// 后续轮次由脚本控制. 记录每次收到的 context/credentials.
@MainActor
final class ChallengeSequenceExecutor: CollectorExecuting {
    private let firstArtifact: JSONValue
    private let retryArtifact: JSONValue
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var receivedContexts: [[String: JSONValue]] = []
    private(set) var receivedCredentials: [[String: JSONValue]] = []
    /// 第二轮 (重试) 是否带 challenge (默认 false -> 不触发第三轮).
    var retryHasChallenge = false
    /// 首轮是否带 challenge (默认 true; 无 challenge 场景置 false).
    var firstHasChallenge = true
    /// 重试轮抛错 (SCH-08: retry Collector 失败).
    var retryError: Error?

    init(firstArtifact: JSONValue, retryArtifact: JSONValue) {
        self.firstArtifact = firstArtifact
        self.retryArtifact = retryArtifact
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        receivedContexts.append(context)
        receivedCredentials.append(credentials)
        let isRetry = (runCount[module] ?? 0) > 1
        if isRetry, let retryError {
            throw retryError
        }
        let artifact = isRetry ? retryArtifact : firstArtifact
        let challengeJSON: JSONValue = .object([
            "provider": .string("codex"),
            "accountId": .string("acc-1"),
            "reason": .string("accessRejected"),
        ])
        let challenges: [JSONValue]
        if isRetry {
            challenges = retryHasChallenge ? [challengeJSON] : []
        } else {
            challenges = firstHasChallenge ? [challengeJSON] : []
        }
        let diagnostics: [BridgeDiagnostic] = isRetry ? [] : [
            BridgeDiagnostic(
                code: "COLLECTOR_PARTIAL_RESULT",
                category: "collector",
                stage: "collect",
                message: "部分数据源采集失败",
                retryable: true
            ),
        ]
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                // 首轮带 challenge 时按 Bridge 契约整体为 partial
                status: isRetry ? .success : .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: isRetry ? [] : diagnostics,
                credentialChallenges: challenges
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

/// 多账号 challenge executor (任务 8): 首轮对指定账号列表发 accessRejected
/// challenge, 重试轮返回各账号独立结果.
@MainActor
final class MultiChallengeSequenceExecutor: CollectorExecuting {
    private let firstArtifact: JSONValue
    private let retryArtifact: JSONValue
    private let challengedAccounts: [String]
    private(set) var runCount: [CollectorModule: Int] = [:]
    private(set) var receivedContexts: [[String: JSONValue]] = []
    private(set) var receivedCredentials: [[String: JSONValue]] = []

    init(
        firstArtifact: JSONValue,
        retryArtifact: JSONValue,
        challengedAccounts: [String]
    ) {
        self.firstArtifact = firstArtifact
        self.retryArtifact = retryArtifact
        self.challengedAccounts = challengedAccounts
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        receivedContexts.append(context)
        receivedCredentials.append(credentials)
        let isRetry = (runCount[module] ?? 0) > 1
        let artifact = isRetry ? retryArtifact : firstArtifact
        let challenges: [JSONValue] = isRetry ? [] : challengedAccounts.map {
            .object([
                "provider": .string("codex"),
                "accountId": .string($0),
                "reason": .string("accessRejected"),
            ])
        }
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: isRetry ? .success : .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: [],
                credentialChallenges: challenges
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

/// 记录刷新调用但默认拒绝的 token manager fake (任务 9).
@MainActor
final class StubCodexTokenManager: CodexChallengeHandling {
    var resolutions: [String: TokenResolution] = [:]
    private(set) var refreshAfterAccessRejectedCount: [String: Int] = [:]
    private(set) var markedNeedsReauthorization: [String] = []

    func refreshAfterAccessRejected(
        for accountID: String,
        now: Date?
    ) async -> TokenResolution {
        refreshAfterAccessRejectedCount[accountID, default: 0] += 1
        return resolutions[accountID]
            ?? .failure(.notFound(accountID: accountID))
    }

    func markNeedsReauthorization(
        for accountID: String,
        now: Date?
    ) async {
        if !markedNeedsReauthorization.contains(accountID) {
            markedNeedsReauthorization.append(accountID)
        }
    }
}

/// 定向重试输入提供器 (任务 9): 记录首轮与重试调用.
@MainActor
final class RetryInputProvider: CollectorRunInputProviding {
    var codexRetryInput: CollectorRunInput?
    var firstInput = CollectorRunInput(context: [:], credentials: [:])
    var codexTokenDecisions: [CodexTokenDecision] = []
    private(set) var retriedAccountIDs: [[String]] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        firstInput
    }

    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        retriedAccountIDs.append(accountIDs)
        return codexRetryInput
    }
}

/// retryInput 抛错的提供器 (SCH-07).
@MainActor
final class ThrowingRetryInputProvider: CollectorRunInputProviding {
    var firstInput = CollectorRunInput(context: [:], credentials: [:])
    var codexTokenDecisions: [CodexTokenDecision] = []
    private(set) var retriedAccountIDs: [[String]] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        firstInput
    }

    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        retriedAccountIDs.append(accountIDs)
        throw CodexRunInputFixtureError()
    }
}

/// retryInput 抛错专用错误 (SCH-07).
struct CodexRunInputFixtureError: Error {}

/// 构造带 codex token manager 的调度器.
@MainActor
func makeSchedulerWithCodex(
    repository: URL,
    executor: CollectorExecuting,
    tokenManager: StubCodexTokenManager,
    retryProvider: (any CollectorRunInputProviding)? = nil
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    let (scheduler, store, root) = try makeSchedulerWithError(
        repository: repository,
        executor: executor,
        clock: ManualClock(),
        timers: FakeTimerScheduler()
    )
    scheduler.codexTokenManager = tokenManager
    if let retryProvider {
        scheduler.setRunInputProviderForTesting(retryProvider)
    }
    return (scheduler, store, root)
}


// MARK: - Merger test vectors (shared with merger suite)
let mergerAccount1 = "acc-1"
let mergerAccount2 = "acc-2"
let mergerService1 = "codex_cf9df9b99fc0a24b"
let mergerService2 = "codex_a75990ab7ebfd8a9"
let mergerLegacy1 = "codex_acc-1"
let mergerLegacy2 = "codex_acc-2"

/// Codex 额度 artifact 构造: 一个 codex 账号 + 一个非 codex service + agents.
/// 服务 ID 使用任务 1 契约 currentID (codex_ + SHA256(accountID).hexPrefix(16)).
@MainActor
func makeCodexQuotaArtifact(
    status: String,
    usedPercent: Double,
    generatedAt: String,
    note: String? = nil,
    failureKind: String = "auth"
) -> JSONValue {
    var serviceObject: [String: JSONValue] = [
        "id": .string(mergerService1),
        "name": .string("Codex · user"),
        "app": .string("codex"),
        "status": .string(status),
        "kind": .string("windows"),
        "plan": .string("team"),
        "capturedAt": .string(generatedAt),
        "windows": .array([
            .object([
                "label": .string("5小时窗口"),
                "usedPercent": .double(usedPercent),
                "windowMinutes": .integer(300),
                "resetsAt": .null,
            ]),
        ]),
    ]
    if let note {
        serviceObject["note"] = .string(note)
    }
    if status == "error" {
        // 失败条目: 不写 capturedAt (不伪造成功时间), 标记
        // freshness=unavailable + failureKind
        serviceObject.removeValue(forKey: "capturedAt")
        serviceObject["freshness"] = .string("unavailable")
        serviceObject["failureKind"] = .string(failureKind)
    } else {
        serviceObject["freshness"] = .string("fresh")
    }
    return .object([
        "schemaVersion": .integer(1),
        "module": .string("agent-usage"),
        "generatedAt": .string(generatedAt),
        "agents": .array([
            .object([
                "id": .string("codex"),
                "name": .string("Codex"),
                "status": .string("ok"),
                "today": .object([
                    "input": .integer(100), "output": .integer(50),
                    "cacheRead": .integer(0), "cacheCreation": .integer(0),
                    "total": .integer(150),
                ]),
                "daily": .array([]),
                "hours": .array(Array(repeating: .integer(0), count: 24)),
            ]),
        ]),
        "services": .array([
            .object(serviceObject),
            .object([
                "id": .string("kimi"),
                "name": .string("Kimi"),
                "status": .string("ok"),
                "kind": .string("windows"),
                "windows": .array([]),
            ]),
        ]),
        "totalCostUsd": .null,
    ])
}

/// 12.1.1: 首轮 challenge 触发一次定向重试 (强制刷新 + retry-only), 全轮只发布一次.

/// JSON 数值宽容取值: JSONValue 解码时整数优先 (45.0 -> .integer(45)).
enum JSONNumber {
    static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number):
            return number
        case .integer(let number):
            return Double(number)
        default:
            return nil
        }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

@MainActor
final class FailingExecutor: CollectorExecuting {
    let error: Error
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(error: Error) { self.error = error }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        throw error
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

@MainActor
final class AuthFailingExecutor: CollectorExecuting {
    private(set) var runCount: [CollectorModule: Int] = [:]

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return makeErrorOutput(category: "auth", code: "AUTH_FAILED")
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

@MainActor
final class PartialSuccessExecutor: CollectorExecuting {
    let artifact: JSONValue
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(artifact: JSONValue) { self.artifact = artifact }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: .partial,
                artifact: artifact,
                credentialUpdates: [],
                diagnostics: [BridgeDiagnostic(
                    code: "COLLECTOR_PARTIAL_RESULT",
                    category: "collector",
                    stage: "collect",
                    message: "部分数据源采集失败",
                    retryable: true
                )],
            credentialChallenges: []
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}

// MARK: - Factory for custom executors

@MainActor
func makeSchedulerWithError(
    repository: URL,
    executor: CollectorExecuting,
    clock: ManualClock,
    timers: FakeTimerScheduler,
    credentialUpdateCoordinator: CredentialUpdateCoordinator? = nil,
    reachability: (any NetworkReachabilityProviding)? = nil
) throws -> (RefreshScheduler, ArtifactStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Bruce-sched-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = try ArtifactStore(rootURL: root)
    let config = SchedulerConfiguration(
        refreshInterval: 1800,
        staleAfter: 3600,
        maxBackoffRetries: 3,
        baseBackoffSeconds: 30,
        maxBackoffSeconds: 1800,
        rateLimitBackoffSeconds: 300,
        capacityLimit: 2,
        quotaRefreshInterval: 0,
        wakeDedupSeconds: 0
    )
    let scheduler = RefreshScheduler(
        executor: executor,
        store: store,
        clock: clock,
        timerScheduler: timers,
        configuration: config,
        jitterProvider: { 0 },
        registerWakeNotifications: false,
        credentialUpdateCoordinator: credentialUpdateCoordinator,
        networkReachability: reachability
    )
    return (scheduler, store, root)
}

/// saveCredential 恒抛错, 用于验证 Scheduler 写回失败 → partial 路径.
final class ThrowingCredentialStoreForScheduler: CredentialStore, @unchecked Sendable {
    private let backing: CredentialStore

    init(backing: CredentialStore) {
        self.backing = backing
    }

    func loadCredential(forAccount account: String) throws -> String? {
        try backing.loadCredential(forAccount: account)
    }

    func saveCredential(_ value: String, forAccount account: String) throws {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "keychain denied",
        ])
    }

    func deleteCredential(forAccount account: String) throws {
        try backing.deleteCredential(forAccount: account)
    }
}

/// 成功响应携带 credentialUpdates 的执行器, 用于验证 Scheduler 写回路径.
@MainActor
final class CredentialUpdateExecutor: CollectorExecuting {
    let artifact: JSONValue
    let updates: [JSONValue]
    private(set) var runCount: [CollectorModule: Int] = [:]

    init(artifact: JSONValue, updates: [JSONValue]) {
        self.artifact = artifact
        self.updates = updates
    }

    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        runCount[module, default: 0] += 1
        return CollectorRunOutput(
            response: BridgeResponse(
                schemaVersion: 1,
                runId: UUID().uuidString.lowercased(),
                generatedAt: "2026-07-28T12:00:00Z",
                status: .success,
                artifact: artifact,
                credentialUpdates: updates,
                diagnostics: [],
            credentialChallenges: []
            ),
            stderrDiagnostic: nil
        )
    }

    func cancel(module: CollectorModule) {}
    func cancelAll() {}
}
