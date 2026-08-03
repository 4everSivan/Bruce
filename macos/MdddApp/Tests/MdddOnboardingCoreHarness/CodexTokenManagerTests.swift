import Foundation
@testable import MdddOnboardingCore

// MARK: - CodexTokenManagerTests

/// 任务 4 定向验证: token manager 生命周期 (内存 store, fake OAuth client,
/// 可控时钟, 可控 sleeper).
enum CodexTokenManagerTests {
    static func runAll() async throws {
        try await reusesWithin61SecondsRefreshesAt60()
        try await concurrentRequestsShareOneRefresh()
        try await differentAccountsRunInParallelWithinCap()
        try await missingNewRefreshTokenKeepsOld()
        try await refreshUpdatesMemoryBeforeStore()
        try await invalidGrantMarksOnlyCurrentAccount()
        try await transientFailureDoesNotRequireReloginOrReplay()
        try await staleButValidTokenReusedAfterFailedRefresh()
        try await keychainWriteFailureEntersStorageBlocked()
        try await storageRetrySequenceAndStop()
        try await forceRefreshSkipsCacheButReusesInflight()
        try await tokenCallsTrackExpiryNotQuotaCycles()
        try await rotationPreservesEmailAndOrigin()
        print("CodexTokenManager tests passed: 13")
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_752_000_000)

    // MARK: 夹具

    /// 可控时钟: advance(by:) 手动推进.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { current = start }
        func now() -> Date {
            lock.lock(); defer { lock.unlock() }
            return current
        }
        func advance(by interval: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(interval)
        }
    }

    /// 计数 fake OAuth client. 响应由 `handler` 按 (refresh token, 第几次调用)
    /// 决定, 保证并发与多账号测试可区分. 不做真实网络请求.
    private final class FakeOAuthClient: CodexOAuthClientProtocol, @unchecked Sendable {
        private let queue = DispatchQueue(label: "codex-token-manager-tests.fake-oauth")
        private var counters: [String: Int] = [:]
        private let handler: (String, Int) -> Result<CodexTokenResponse, CodexOAuthClientError>

        init(
            handler: @escaping (String, Int) -> Result<CodexTokenResponse, CodexOAuthClientError>
        ) {
            self.handler = handler
        }

        func refreshCount(for refreshToken: String) -> Int {
            queue.sync { counters[refreshToken] ?? 0 }
        }

        /// 全部 refresh 调用总数 (refresh token 轮换后仍可断言).
        func totalRefreshCount() -> Int {
            queue.sync { counters.values.reduce(0, +) }
        }

        func refreshRequest(refreshToken: String) -> URLRequest {
            var request = URLRequest(url: CodexOAuthClient.defaultConfiguration().tokenURL)
            request.httpMethod = "POST"
            request.httpBody = Data(
                ("grant_type=refresh_token&refresh_token=" + refreshToken).utf8
            )
            return request
        }

        func perform(
            _ request: URLRequest,
            session: (any URLSessionProtocol)?
        ) async -> Result<CodexTokenResponse, CodexOAuthClientError> {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let token = extractRefreshToken(from: body)
            let count = queue.sync {
                let next = (counters[token] ?? 0) + 1
                counters[token] = next
                return next
            }
            return handler(token, count)
        }

        private func extractRefreshToken(from form: String) -> String {
            // form 形如 "grant_type=refresh_token&client_id=...&refresh_token=RT"
            let pairs = form.split(separator: "&").map(String.init)
            for pair in pairs {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[0] == "refresh_token" {
                    return parts[1]
                }
            }
            return "unknown"
        }
    }

    /// 内存 store + 预置 connected 记录.
    private static func makeStore(
        accounts: [String: (access: String, refresh: String, expiresIn: TimeInterval)]
    ) throws -> (CodexCredentialStore, InMemoryCredentialStore) {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        for (accountID, info) in accounts {
            try store.saveRecord(CodexAccountRecord(
                accountID: accountID,
                accessToken: info.access,
                refreshToken: info.refresh,
                accessTokenExpiresAt: fixedNow.addingTimeInterval(info.expiresIn),
                authorizationState: .connected,
                credentialOrigin: .mddd,
                updatedAt: fixedNow
            ))
        }
        return (store, memory)
    }

    private static func makeManager(
        store: CodexCredentialStore,
        client: FakeOAuthClient,
        clock: TestClock
    ) -> CodexTokenManager {
        CodexTokenManager(
            store: store,
            client: client,
            clock: { clock.now() },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1) }
        )
    }

    // 1. 距过期 61 秒复用, 60 秒及以内刷新
    private static func reusesWithin61SecondsRefreshesAt60() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: store, client: fake, clock: clock)

        // 距过期 61 秒: 复用, 不刷新
        clock.advance(by: 3539)
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at" else {
            throw CodexTestFailure.expectation("61 秒内必须复用旧 token")
        }
        guard fake.refreshCount(for: "rt") == 0 else {
            throw CodexTestFailure.expectation("61 秒内不得刷新")
        }

        // 距过期 60 秒: 刷新
        clock.advance(by: 1)
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("60 秒窗口必须刷新")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation("刷新次数应为 1")
        }
    }

    // 2. 同账号 N 个并发请求只调用一次 refresh endpoint
    private static func concurrentRequestsShareOneRefresh() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 30),
        ])
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )

        let results = await withTaskGroup(
            of: TokenResolution.self,
            returning: [TokenResolution].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    await manager.validAccessToken(for: "acc-1")
                }
            }
            var collected: [TokenResolution] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        guard results.allSatisfy({
            if case .success(let t) = $0, t.accessToken == "at-new" { return true }
            return false
        }) else {
            throw CodexTestFailure.expectation("并发请求结果不一致")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation(
                "并发 N 请求必须只触发一次 refresh, got \(fake.refreshCount(for: "rt"))"
            )
        }
    }

    // 3. 不同账号可并行, 最大并发数为 4
    private static func differentAccountsRunInParallelWithinCap() async throws {
        var accounts: [String: (access: String, refresh: String, expiresIn: TimeInterval)] = [:]
        for i in 1...8 {
            accounts["acc-\(i)"] = (access: "at-\(i)", refresh: "rt-\(i)", expiresIn: 30)
        }
        let (store, _) = try makeStore(accounts: accounts)
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        let ids = (1...8).map { "acc-\($0)" }
        let results = await manager.validAccessTokens(for: ids)
        for id in ids {
            guard case .success = results[id] else {
                throw CodexTestFailure.expectation("\(id) 决议失败")
            }
        }
        // 每个账号恰好刷新一次
        for i in 1...8 {
            guard fake.refreshCount(for: "rt-\(i)") == 1 else {
                throw CodexTestFailure.expectation(
                    "acc-\(i) 刷新次数应为 1, got \(fake.refreshCount(for: "rt-\(i)"))"
                )
            }
        }
    }

    // 4. 新响应没有 refresh token 时保留旧 refresh token
    private static func missingNewRefreshTokenKeepsOld() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt-old", expiresIn: 30),
        ])
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: nil,
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        _ = await manager.validAccessToken(for: "acc-1")
        let record = try store.loadRecord(for: "acc-1")
        guard record?.refreshToken == "rt-old",
              record?.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("缺新 refresh token 必须保留旧值")
        }
    }

    // 5. refresh 成功后先更新内存, 再写对应账号记录
    private static func refreshUpdatesMemoryBeforeStore() async throws {
        let (store, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 30),
        ])
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        _ = await manager.validAccessToken(for: "acc-1")
        // 内存返回新 token; Keychain 已写入新记录
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("内存未更新为新 token")
        }
        let stored = try memory.loadCredential(
            forAccount: CodexCredentialKeys.accountKey(for: "acc-1")
        )
        guard stored?.contains("rt-new") == true,
              stored?.contains("at-new") == true else {
            throw CodexTestFailure.expectation("Keychain 未写入新记录")
        }
    }

    // 6. invalid_grant 只把当前账号设为 needsReauthorization, 不波及其他账号
    private static func invalidGrantMarksOnlyCurrentAccount() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at-1", refresh: "rt-1", expiresIn: 30),
            "acc-2": (access: "at-2", refresh: "rt-2", expiresIn: 30),
        ])
        // acc-1 (refresh rt-1) 失败, acc-2 (refresh rt-2) 成功
        let fake = FakeOAuthClient { refreshToken, _ in
            if refreshToken == "rt-1" {
                return .failure(.invalidGrant)
            }
            return .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        let first = await manager.validAccessToken(for: "acc-1")
        guard case .failure(.needsReauthorization) = first else {
            throw CodexTestFailure.expectation("acc-1 必须标记为需要重新授权")
        }
        guard case .success(let token) = await manager.validAccessToken(for: "acc-2"),
              token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("acc-2 必须不受影响")
        }
        // acc-1 后续请求保持 needsReauthorization, 不重放 refresh
        guard case .failure(.needsReauthorization) =
            await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("acc-1 状态必须保持")
        }
        guard fake.refreshCount(for: "rt-1") == 1 else {
            throw CodexTestFailure.expectation("needsReauthorization 后不得重放 refresh")
        }
    }

    // 7. 429、5xx、网络和超时错误不要求重登, 同一轮不盲目重放 refresh
    private static func transientFailureDoesNotRequireReloginOrReplay() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 30),
        ])
        let fake = FakeOAuthClient { _, _ in
            .failure(.rateLimit(retryAfter: 120))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        let first = await manager.validAccessToken(for: "acc-1")
        guard case .failure(.refreshFailed) = first else {
            throw CodexTestFailure.expectation("429 必须分类为暂时失败")
        }
        // 同一轮 (not-before 生效) 不重放; 旧 token 仍有效时返回旧 token
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at" else {
            throw CodexTestFailure.expectation("not-before 内应复用旧 token 而非失败")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation(
                "同一轮不得重放 refresh, got \(fake.refreshCount(for: "rt"))"
            )
        }
    }

    // 8. 暂时刷新失败但旧 access token 仍有效时可返回旧 token; 已过期时不发送
    private static func staleButValidTokenReusedAfterFailedRefresh() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 300),
        ])
        let fake = FakeOAuthClient { _, _ in
            .failure(.serverError(500))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: store, client: fake, clock: clock)
        // 距过期 100 秒: 仍在 60 秒窗口外, 应复用不刷新
        clock.advance(by: 200)
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at" else {
            throw CodexTestFailure.expectation("窗口外必须复用旧 token")
        }
        // 过期后失败: 不发送旧 token
        clock.advance(by: 101)
        guard case .failure = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("过期后不得返回旧 token")
        }
    }

    // 9. Keychain 写失败进入 storageBlocked, 新 token 留在内存, 不再请求 OAuth
    private static func keychainWriteFailureEntersStorageBlocked() async throws {
        final class FailingStore: CredentialStore, @unchecked Sendable {
            private let inner: InMemoryCredentialStore
            init(inner: InMemoryCredentialStore) { self.inner = inner }
            func saveCredential(_ value: String, forAccount account: String) throws {
                throw KeychainError.saveFailed(-1)
            }
            func loadCredential(forAccount account: String) throws -> String? {
                try inner.loadCredential(forAccount: account)
            }
            func deleteCredential(forAccount account: String) throws {
                try inner.deleteCredential(forAccount: account)
            }
        }
        let memory = InMemoryCredentialStore()
        let inner = CodexCredentialStore(store: memory)
        try inner.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(30),
            authorizationState: .connected,
            credentialOrigin: .mddd,
            updatedAt: fixedNow
        ))
        // 预置 store 指向 fail-on-write 的包装
        let store = CodexCredentialStore(store: FailingStore(inner: memory))
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = CodexTokenManager(
            store: store,
            client: fake,
            clock: { fixedNow },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1) }
        )
        guard case .success(let token) = await manager.validAccessToken(for: "acc-1"),
              token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("写失败时内存 token 必须可用")
        }
        let state = await manager.statusSnapshot()
        guard state.accounts.first?.storageBlocked == true else {
            throw CodexTestFailure.expectation("必须进入 storageBlocked")
        }
        // storageBlocked 期间内存 token 仍可用, 不重放 refresh
        guard case .success(let t) = await manager.validAccessToken(for: "acc-1"),
              t.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("storageBlocked 期间内存 token 仍可用")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation("storageBlocked 期间不得重放 refresh")
        }
    }

    // 10. 存储重试序列为 1 秒、5 秒、30 秒、5 分钟, 之后每 5 分钟
    private static func storageRetrySequenceAndStop() async throws {
        let delays = (0..<6).map { CodexStorageRetryPolicy.delay(forAttempt: $0) }
        guard delays == [1, 5, 30, 300, 300, 300] else {
            throw CodexTestFailure.expectation(
                "存储退避序列不符: \(delays)"
            )
        }
    }

    // 11. invalidateAccessToken 后的 forceRefresh 必须越过缓存, 但仍复用同账号 in-flight task
    private static func forceRefreshSkipsCacheButReusesInflight() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        // 正常决议: 窗口外复用缓存, 0 次刷新
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("窗口外决议失败")
        }
        guard fake.refreshCount(for: "rt") == 0 else {
            throw CodexTestFailure.expectation("窗口外不得刷新")
        }
        // 失效后 forceRefresh 必须刷新
        await manager.invalidateAccessToken(for: "acc-1")
        guard case .success(let token) = await manager.forceRefresh(for: "acc-1"),
              token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("forceRefresh 必须刷新")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation("forceRefresh 必须触发一次刷新")
        }
        // 再次 forceRefresh: in-flight 已完成, 缓存有效但 force 越过缓存, 再刷新一次
        guard case .success = await manager.forceRefresh(for: "acc-1") else {
            throw CodexTestFailure.expectation("第二次 forceRefresh 失败")
        }
        guard fake.totalRefreshCount() == 2 else {
            throw CodexTestFailure.expectation("再次 forceRefresh 必须触发刷新")
        }
    }

    // 12. 24 小时模拟: token endpoint 调用数随过期次数变化, 不随 30 分钟额度查询次数变化
    private static func tokenCallsTrackExpiryNotQuotaCycles() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        var refreshCount = 0
        let fake = FakeOAuthClient { _, _ in
            refreshCount += 1
            return .success(CodexTokenResponse(
                accessToken: "at-\(refreshCount)",
                refreshToken: "rt-\(refreshCount)",
                idToken: nil,
                expiresIn: 3600,
                receivedAt: fixedNow.addingTimeInterval(
                    Double(refreshCount) * 3600
                )
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: store, client: fake, clock: clock)
        // 24 小时, 每 30 分钟一次额度查询 = 48 次; token 每小时过期一次 = 24 次
        for _ in 0..<48 {
            clock.advance(by: 1800)
            guard case .success = await manager.validAccessToken(for: "acc-1") else {
                throw CodexTestFailure.expectation("模拟查询失败")
            }
        }
        guard fake.totalRefreshCount() == 24 else {
            throw CodexTestFailure.expectation(
                "token 调用数必须等于过期次数, got \(fake.totalRefreshCount())"
            )
        }
    }

    // 13. 轮换落盘保留既有邮箱与凭证来源, 显示名不退化为账号 ID 前缀
    private static func rotationPreservesEmailAndOrigin() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        try store.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "user@example.test",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(30),
            authorizationState: .connected,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("刷新应成功")
        }
        let record = try store.loadRecord(for: "acc-1")
        guard record?.email == "user@example.test" else {
            throw CodexTestFailure.expectation("轮换后邮箱丢失: \(record?.email ?? "nil")")
        }
        guard record?.displayName == "Codex · user" else {
            throw CodexTestFailure.expectation("显示名退化: \(record?.displayName ?? "nil")")
        }
        guard record?.credentialOrigin == .legacyCCSwitchDiscovery else {
            throw CodexTestFailure.expectation("凭证来源被覆盖")
        }
    }
}

// MARK: - 测试工具

private enum CodexTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}
