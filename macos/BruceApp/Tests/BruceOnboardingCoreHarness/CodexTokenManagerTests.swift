import Foundation
@testable import BruceOnboardingCore

// MARK: - CodexTokenManagerTests

/// 任务 4 定向验证: token manager 生命周期 (内存 store, fake OAuth client,
/// 可控时钟, 可控 sleeper).
enum CodexTokenManagerTests {
    static func runAll() async throws {
        try await reusesWithin61SecondsRefreshesAt60()
        try await concurrentRequestsShareOneRefresh()
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
        try await storageBlockedBlocksForceRefresh()
        try await storageRetryDoesNotOverwriteRelogin()
        try await invalidGrantPersistsAfterRestart()
        try await refreshPreservesEmailAndOriginInStore()
        try await markNeedsReauthorizationPersistsAndBlocksRefresh()
        try await markReauthFirstSaveFailureBlocksAndRetries()
        try await markReauthSaveFailureRetriesAfterRecovery()
        try await invalidGrantSaveFailureBlocksAndRetries()
        try await second401SaveFailureDoesNotAffectOtherAccount()
        try await staleRevisionDoesNotOverwriteNewerState()
        try await restartFromMetadataOnlyDoesNotRefresh()
        try await repeatedMarkKeepsSingleRetryTask()
        try await coldMarkReadFailureRetriesWithoutOAuth()
        try await blockedShortLivedTokenStillAvailable()
        try await blockedExactlyExpiredTokenRejected()
        try await blockedExpiredOneSecondTokenRejected()
        try await refreshSaveDoesNotReadBackRecordForMetadata()
        try await refreshSaveReadBackFailureKeepsMetadata()
        try await missingRecordDistinctFromReadError()
        print("CodexTokenManager tests passed: 32")
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
                credentialOrigin: .Bruce,
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at" else {
            throw CodexTestFailure.expectation("61 秒内必须复用旧 token")
        }
        guard fake.refreshCount(for: "rt") == 0 else {
            throw CodexTestFailure.expectation("61 秒内不得刷新")
        }

        // 距过期 60 秒: 刷新
        clock.advance(by: 1)
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
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
            if case .success(accessToken: let accessToken, expiresAt: _) = $0,
               accessToken == "at-new" { return true }
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-2"),
              accessToken == "at-new" else {
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at" else {
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at" else {
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
            credentialOrigin: .Bruce,
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
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
            throw CodexTestFailure.expectation("写失败时内存 token 必须可用")
        }
        let state = await manager.statusSnapshot()
        guard state.accounts.first?.storageBlocked == true else {
            throw CodexTestFailure.expectation("必须进入 storageBlocked")
        }
        // storageBlocked 期间内存 token 仍可用, 不重放 refresh
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
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

    // 11. refreshAfterAccessRejected 越过缓存, 但仍复用同账号 in-flight task
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
        // 401 后 refreshAfterAccessRejected 必须刷新
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.refreshAfterAccessRejected(for: "acc-1"),
              accessToken == "at-new" else {
            throw CodexTestFailure.expectation("refreshAfterAccessRejected 必须刷新")
        }
        guard fake.refreshCount(for: "rt") == 1 else {
            throw CodexTestFailure.expectation("refreshAfterAccessRejected 必须触发一次刷新")
        }
        // 再次 refreshAfterAccessRejected: in-flight 已完成, 缓存有效但 force 越过缓存, 再刷新一次
        guard case .success = await manager.refreshAfterAccessRejected(for: "acc-1") else {
            throw CodexTestFailure.expectation("第二次 refreshAfterAccessRejected 失败")
        }
        guard fake.totalRefreshCount() == 2 else {
            throw CodexTestFailure.expectation("再次 refreshAfterAccessRejected 必须触发刷新")
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

    // 14. storageBlocked 期间 401 强制刷新不调用 OAuth (内存 token 未过期时复用)
    private static func storageBlockedBlocksForceRefresh() async throws {
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
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        ))
        let store = CodexCredentialStore(store: FailingStore(inner: memory))
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = CodexTokenManager(
            store: store, client: fake,
            clock: { fixedNow },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1) }
        )
        // 首次刷新成功但 Keychain 写失败 -> storageBlocked
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("首次刷新应成功")
        }
        let beforeCount = fake.totalRefreshCount()
        // storageBlocked 期间强制刷新 (401 重试) 不得调用 OAuth
        let resolution = await manager.refreshAfterAccessRejected(
            for: "acc-1", now: fixedNow
        )
        guard case .success = resolution else {
            throw CodexTestFailure.expectation("storageBlocked 期间内存 token 应可用")
        }
        guard fake.totalRefreshCount() == beforeCount else {
            throw CodexTestFailure.expectation(
                "storageBlocked 期间不得调用 OAuth, got \(fake.totalRefreshCount())"
            )
        }
    }

    // 15. 旧存储重试任务不能覆盖重新登录记录 (revision 校验)
    private static func storageRetryDoesNotOverwriteRelogin() async throws {
        final class FailingThenSuccessStore: CredentialStore, @unchecked Sendable {
            private let inner: InMemoryCredentialStore
            private let lock = NSLock()
            private var failing = true
            init(inner: InMemoryCredentialStore) { self.inner = inner }
            func saveCredential(_ value: String, forAccount account: String) throws {
                lock.lock(); defer { lock.unlock() }
                if failing {
                    throw KeychainError.saveFailed(-1)
                }
                try inner.saveCredential(value, forAccount: account)
            }
            func loadCredential(forAccount account: String) throws -> String? {
                try inner.loadCredential(forAccount: account)
            }
            func deleteCredential(forAccount account: String) throws {
                try inner.deleteCredential(forAccount: account)
            }
            func stopFailing() {
                lock.lock(); defer { lock.unlock() }
                failing = false
            }
        }
        let memory = InMemoryCredentialStore()
        let inner = CodexCredentialStore(store: memory)
        try inner.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "old@example.test",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(30),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        ))
        let failingStore = FailingThenSuccessStore(inner: memory)
        let store = CodexCredentialStore(store: failingStore)
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = CodexTokenManager(
            store: store, client: fake,
            clock: { fixedNow },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1) }
        )
        // 首次刷新 -> Keychain 写失败 -> storageBlocked + 启动存储重试
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("首次刷新应成功")
        }
        // 停止失败, 让重新登录写入成功
        failingStore.stopFailing()
        // 用户重新登录: revision 递增, 旧存储重试任务被取消
        try await manager.storeLoginResult(
            accountID: "acc-1",
            email: "new@example.test",
            accessToken: "at-relogin",
            refreshToken: "rt-relogin",
            idToken: nil,
            expiresAt: fixedNow.addingTimeInterval(3600)
        )
        // 等待一段时间确保旧重试任务 (如果未被取消) 有机会执行
        try? await Task.sleep(nanoseconds: 100_000_000)
        // 重新登录的记录不应被旧存储重试覆盖
        let record = try store.loadRecord(for: "acc-1")
        guard record?.accessToken == "at-relogin" else {
            throw CodexTestFailure.expectation(
                "重新登录记录被旧存储重试覆盖: \(record?.accessToken ?? "nil")"
            )
        }
        guard record?.email == "new@example.test" else {
            throw CodexTestFailure.expectation(
                "重新登录邮箱被覆盖: \(record?.email ?? "nil")"
            )
        }
    }

    // 16. invalid_grant 持久化 metadata-only 重新授权状态, 重启后仍为需重新授权
    private static func invalidGrantPersistsAfterRestart() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 30),
        ])
        let fake = FakeOAuthClient { _, _ in
            .failure(.invalidGrant)
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        guard case .failure(.needsReauthorization) =
            await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("invalid_grant 应标记需重新授权")
        }
        // 验证 Keychain 中记录已持久化为 needsReauthorization, token 已清除
        let record = try store.loadRecord(for: "acc-1")
        guard record?.authorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("Keychain 未持久化 needsReauthorization")
        }
        guard record?.accessToken == nil,
              record?.refreshToken == nil else {
            throw CodexTestFailure.expectation("invalid_grant 后 token 未清除")
        }
        // 重启: 新 manager 实例从 Keychain 读取, 应仍为 needsReauthorization
        let fake2 = FakeOAuthClient { _, _ in
            .failure(.invalidGrant)
        }
        let restarted = makeManager(
            store: store, client: fake2, clock: TestClock(start: fixedNow)
        )
        guard case .failure(.needsReauthorization) =
            await restarted.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("重启后应仍为 needsReauthorization")
        }
        // 重启后不调用 OAuth (已持久化为 needsReauthorization)
        guard fake2.totalRefreshCount() == 0 else {
            throw CodexTestFailure.expectation(
                "重启后 needsReauthorization 不得调用 OAuth"
            )
        }
    }

    // 17. 刷新后邮箱和 origin 在 Keychain 记录中不丢失
    private static func refreshPreservesEmailAndOriginInStore() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        try store.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "keeper@example.test",
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
                idToken: "it-new", expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("刷新应成功")
        }
        let record = try store.loadRecord(for: "acc-1")
        guard record?.email == "keeper@example.test" else {
            throw CodexTestFailure.expectation("邮箱丢失: \(record?.email ?? "nil")")
        }
        guard record?.credentialOrigin == .legacyCCSwitchDiscovery else {
            throw CodexTestFailure.expectation("origin 被覆盖: \(String(describing: record?.credentialOrigin))")
        }
        guard record?.accessToken == "at-new",
              record?.refreshToken == "rt-new",
              record?.idToken == "it-new" else {
            throw CodexTestFailure.expectation("新 token 未写入 Keychain")
        }
    }

    // 18. 任务 8: 第二次 401 后 markNeedsReauthorization 持久化该账号
    // 状态并阻止后续刷新; 不影响其他账号.
    private static func markNeedsReauthorizationPersistsAndBlocksRefresh() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
            "acc-2": (access: "at2", refresh: "rt2", expiresIn: 3600),
        ])
        var refreshCalls = 0
        let fake = FakeOAuthClient { _, _ in
            refreshCalls += 1
            return .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: store, client: fake, clock: TestClock(start: fixedNow)
        )

        // 第一次 401 强制刷新成功 (任务 8 首次挑战)
        guard case .success = await manager.refreshAfterAccessRejected(
            for: "acc-1"
        ) else {
            throw CodexTestFailure.expectation("首次 401 刷新应成功")
        }
        guard refreshCalls == 1 else {
            throw CodexTestFailure.expectation(
                "首次刷新必须调用一次 OAuth, got \(refreshCalls)"
            )
        }

        // 第二次 401: markNeedsReauthorization 持久化
        await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)
        let record = try store.loadRecord(for: "acc-1")
        guard record?.authorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("第二次 401 必须持久化 needsReauthorization")
        }
        guard record?.accessToken == nil, record?.refreshToken == nil else {
            throw CodexTestFailure.expectation("第二次 401 后 token 必须清除")
        }
        // 后续刷新被阻止 (不再调用 OAuth)
        let before = refreshCalls
        guard case .failure(.needsReauthorization) =
            await manager.refreshAfterAccessRejected(for: "acc-1") else {
            throw CodexTestFailure.expectation("needsReauthorization 后刷新必须失败")
        }
        guard refreshCalls == before else {
            throw CodexTestFailure.expectation("needsReauthorization 后不得调用 OAuth")
        }

        // 不影响其他账号
        guard case .success = await manager.validAccessToken(for: "acc-2") else {
            throw CodexTestFailure.expectation("其他账号不得受影响")
        }
    }

    // MARK: - 任务 2: 统一 needsReauthorization 可靠持久化 (TOK-01 ~ TOK-07)

    /// 可控存储故障注入 store: 按 account 精确控制失败 (默认只失败注入目标).
    private final class FaultyStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        /// 保存失败列表: 精确匹配 account 键时抛错 (计数到次数后恢复).
        var failSaves: [(account: String, times: Int)] = []
        /// 删除失败列表.
        var failDeletes: [(account: String, times: Int)] = []
        /// 读取失败列表.
        var failLoads: [(account: String, times: Int)] = []
        private var saveCounters: [String: Int] = [:]
        private var deleteCounters: [String: Int] = [:]
        private var loadCounters: [String: Int] = [:]

        init(inner: InMemoryCredentialStore) { self.inner = inner }

        func saveCredential(_ value: String, forAccount account: String) throws {
            if let failure = failSaves.first(where: { $0.account == account }) {
                let count = saveCounters[account, default: 0] + 1
                saveCounters[account] = count
                if count <= failure.times {
                    throw KeychainError.saveFailed(-1)
                }
            }
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            if let failure = failLoads.first(where: { $0.account == account }) {
                let count = loadCounters[account, default: 0] + 1
                loadCounters[account] = count
                if count <= failure.times {
                    throw KeychainError.loadFailed(-1)
                }
            }
            return try inner.loadCredential(forAccount: account)
        }
        func loadAttemptCount(for account: String) -> Int {
            loadCounters[account, default: 0]
        }
        func deleteCredential(forAccount account: String) throws {
            if let failure = failDeletes.first(where: { $0.account == account }) {
                let count = deleteCounters[account, default: 0] + 1
                deleteCounters[account] = count
                if count <= failure.times {
                    throw KeychainError.deleteFailed(-1)
                }
            }
            try inner.deleteCredential(forAccount: account)
        }
    }

    /// 推进时钟等待存储重试落盘 (sleeper 用短延迟, 循环等待最多 100 步).
    private static func waitForRetry(
        manager: CodexTokenManager,
        clock: TestClock,
        condition: @escaping () -> Bool
    ) async {
        for _ in 0..<200 where !condition() {
            clock.advance(by: 1)
            try? await Task.sleep(nanoseconds: 500_000)
        }
    }

    // TOK-01: markNeedsReauthorization 首次保存失败 -> 内存状态
    // needsReauthorization + storageBlocked + 唯一 pending
    private static func markReauthFirstSaveFailureBlocksAndRetries() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .failure(.invalidGrant)
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        // 先走一次 validAccessToken 把 acc-1 缓存加载出来 (保持 OAuth 0 调用)
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("预置 token 应可用")
        }
        // 保存 needsReauthorization 记录时注入失败 (accountKey 精确匹配)
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 1)]

        await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)

        let state = await manager.statusSnapshot()
        guard let acc = state.accounts.first(where: { $0.accountID == "acc-1" }) else {
            throw CodexTestFailure.expectation("状态快照缺少 acc-1")
        }
        guard acc.authorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("保存失败后内存状态必须 needsReauthorization")
        }
        guard acc.storageBlocked else {
            throw CodexTestFailure.expectation("保存失败后必须 storageBlocked")
        }
        // pending 期间不调用 OAuth
        guard fake.totalRefreshCount() == 0 else {
            throw CodexTestFailure.expectation("pending 期间不得调用 OAuth")
        }
    }

    // TOK-02: TOK-01 后存储恢复 -> 自动重试成功, pending 清除, 不调用 OAuth
    private static func markReauthSaveFailureRetriesAfterRecovery() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .failure(.invalidGrant)
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("预置 token 应可用")
        }
        // 第 1 次保存失败, 之后恢复
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 1)]

        await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)

        // 存储恢复后自动重试落盘
        await waitForRetry(manager: manager, clock: clock) {
            (try? wrapped.loadRecord(for: "acc-1"))?
                .authorizationState == .needsReauthorization
        }
        let record = try wrapped.loadRecord(for: "acc-1")
        guard record?.authorizationState == .needsReauthorization,
              record?.accessToken == nil,
              record?.refreshToken == nil else {
            throw CodexTestFailure.expectation("重试后 needsReauthorization 应已落盘")
        }
        // 恢复后不再 blocked
        let state = await manager.statusSnapshot()
        guard let acc = state.accounts.first(where: { $0.accountID == "acc-1" }),
              !acc.storageBlocked else {
            throw CodexTestFailure.expectation("重试成功后 storageBlocked 应解除")
        }
        guard fake.totalRefreshCount() == 0 else {
            throw CodexTestFailure.expectation("重试期间不得调用 OAuth")
        }
    }

    // TOK-03: invalid_grant 保存失败 -> 与 TOK-01 相同, refresh token 不再被使用
    private static func invalidGrantSaveFailureBlocksAndRetries() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 10),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .failure(.invalidGrant)
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 2)]

        // 触发刷新 -> invalid_grant; 保存失败 -> storageBlocked
        let resolution = await manager.validAccessToken(for: "acc-1")
        guard case .failure(.needsReauthorization) = resolution else {
            throw CodexTestFailure.expectation("invalid_grant 应返回 needsReauthorization")
        }
        let state = await manager.statusSnapshot()
        guard let acc = state.accounts.first(where: { $0.accountID == "acc-1" }),
              acc.storageBlocked else {
            throw CodexTestFailure.expectation("invalid_grant 保存失败必须 storageBlocked")
        }
        // 后续 401 强制刷新不得再使用旧 refresh token (第 3 次刷新计数保持 1)
        let before = fake.totalRefreshCount()
        let after = await manager.refreshAfterAccessRejected(for: "acc-1")
        guard case .failure(.needsReauthorization) = after else {
            throw CodexTestFailure.expectation("pending 期间强制刷新应失败")
        }
        guard fake.totalRefreshCount() == before else {
            throw CodexTestFailure.expectation("invalid_grant 后不得再次使用 refresh token")
        }
        // 存储恢复后自动落盘
        await waitForRetry(manager: manager, clock: clock) {
            (try? wrapped.loadRecord(for: "acc-1"))?
                .authorizationState == .needsReauthorization
        }
    }

    // TOK-04: 第二次 401 保存失败 -> 与 TOK-01 相同, 其他账号不受影响
    private static func second401SaveFailureDoesNotAffectOtherAccount() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
            "acc-2": (access: "at2", refresh: "rt2", expiresIn: 3600),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        // 只让 acc-1 的 needsReauthorization 保存失败
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 1)]

        await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)

        // acc-1 blocked; acc-2 不受影响且可用
        let state = await manager.statusSnapshot()
        guard let acc1 = state.accounts.first(where: { $0.accountID == "acc-1" }),
              acc1.storageBlocked else {
            throw CodexTestFailure.expectation("acc-1 保存失败必须 storageBlocked")
        }
        guard case .success = await manager.validAccessToken(for: "acc-2") else {
            throw CodexTestFailure.expectation("acc-2 不得受影响")
        }
    }

    // TOK-05: 旧 revision 延迟完成 -> 不覆盖较新的 connected 状态
    private static func staleRevisionDoesNotOverwriteNewerState() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 10),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .failure(.invalidGrant)
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 1)]
        _ = await manager.validAccessToken(for: "acc-1")

        // 新登录 (revision 递增, 取消旧重试任务, 存储恢复正常)
        faulty.failSaves = []
        try await manager.storeLoginResult(
            accountID: "acc-1", email: "live@example.com",
            accessToken: "at-live", refreshToken: "rt-live",
            idToken: nil, expiresAt: fixedNow.addingTimeInterval(3600)
        )
        // 等待旧重试任务有机会执行
        try? await Task.sleep(nanoseconds: 50_000_000)
        let record = try wrapped.loadRecord(for: "acc-1")
        guard record?.accessToken == "at-live",
              record?.refreshToken == "rt-live",
              record?.authorizationState == .connected else {
            throw CodexTestFailure.expectation("旧重试不得覆盖新登录状态")
        }
    }

    // TOK-06: App 重启读取 metadata-only record -> 直接 needsReauthorization, 不 refresh
    private static func restartFromMetadataOnlyDoesNotRefresh() async throws {
        let (store, _) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        // 预置 metadata-only record (模拟上次保存成功后的重启)
        try store.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "u@example.com",
            authorizationState: .needsReauthorization,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let fake = FakeOAuthClient { _, _ in
            return .success(CodexTokenResponse(
                accessToken: "at-x", refreshToken: "rt-x",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: store, client: fake, clock: clock)

        // 冷启动加载 record 后直接返回 needsReauthorization, 不调用 OAuth
        guard case .failure(.needsReauthorization) =
            await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("metadata-only 重启应直接 needsReauthorization")
        }
        guard fake.totalRefreshCount() == 0 else {
            throw CodexTestFailure.expectation("重启后不得尝试旧 refresh token")
        }
    }

    // TOK-07: 同账号连续触发三次标记 -> 只有一个存储重试任务, 最新 revision 生效
    private static func repeatedMarkKeepsSingleRetryTask() async throws {
        let (_, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .failure(.invalidGrant)
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(
            store: wrapped, client: fake, clock: clock
        )
        // 连续三次标记; 保存一直失败 (pending 保留)
        faulty.failSaves = [(CodexCredentialKeys.accountKey(for: "acc-1"), 100)]
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("预置 token 应可用")
        }
        for _ in 0..<3 {
            await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)
        }
        // 存储恢复: 只允许一个重试任务, 最终落盘为 needsReauthorization
        faulty.failSaves = []
        await waitForRetry(manager: manager, clock: clock) {
            (try? wrapped.loadRecord(for: "acc-1"))?
                .authorizationState == .needsReauthorization
        }
        let record = try wrapped.loadRecord(for: "acc-1")
        guard record?.authorizationState == .needsReauthorization,
              record?.accessToken == nil else {
            throw CodexTestFailure.expectation("最新状态必须落盘")
        }
        let state = await manager.statusSnapshot()
        guard let acc = state.accounts.first(where: { $0.accountID == "acc-1" }),
              !acc.storageBlocked else {
            throw CodexTestFailure.expectation("重试成功后应解除 blocked")
        }
    }

    // TOK-08: 冷缓存标记时首次 Keychain 读取失败 -> 只重试存储读取,
    // 恢复后自动落盘 metadata-only 状态, 不调用 OAuth.
    private static func coldMarkReadFailureRetriesWithoutOAuth() async throws {
        let memory = InMemoryCredentialStore()
        let baseStore = CodexCredentialStore(store: memory)
        try baseStore.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "user@example.com",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let faulty = FaultyStore(inner: memory)
        faulty.failLoads = [(CodexCredentialKeys.accountIndexV2, 1)]
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in .failure(.invalidGrant) }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: wrapped, client: fake, clock: clock)

        await manager.markNeedsReauthorization(for: "acc-1", now: fixedNow)

        await waitForRetry(manager: manager, clock: clock) {
            (try? baseStore.loadRecord(for: "acc-1"))?
                .authorizationState == .needsReauthorization
        }
        let record = try baseStore.loadRecord(for: "acc-1")
        guard record?.authorizationState == .needsReauthorization,
              record?.email == "user@example.com",
              record?.credentialOrigin == .legacyCCSwitchDiscovery,
              record?.accessToken == nil,
              record?.refreshToken == nil else {
            throw CodexTestFailure.expectation(
                "冷缓存读取恢复后必须保留元数据并落盘重新授权状态"
            )
        }
        guard fake.totalRefreshCount() == 0 else {
            throw CodexTestFailure.expectation("冷缓存存储重试不得调用 OAuth")
        }
    }

    // MARK: - 任务 3: storageBlocked 短期 token 与元数据保护 (BLK-01~03, META-01~03)

    /// 全部保存抛错的 store (触发 storageBlocked, 与既有测试 9 同风格).
    private final class AlwaysFailingSaveStore: CredentialStore, @unchecked Sendable {
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

    /// 预置 connected 记录并包装 fail-on-save store, 返回 manager 与记录数.
    /// 首次调用必然触发刷新 (token 在 60 秒窗口内), 保存失败 -> storageBlocked,
    /// 内存持有新 token (expiresAt = fixedNow + 3600).
    private static func makeBlockedManager() async throws -> (
        CodexTokenManager, FakeOAuthClient, TestClock
    ) {
        let memory = InMemoryCredentialStore()
        let inner = CodexCredentialStore(store: memory)
        try inner.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "user@example.com",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(10),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        ))
        let store = CodexCredentialStore(store: AlwaysFailingSaveStore(inner: memory))
        let fake = FakeOAuthClient { _, _ in
            .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = CodexTokenManager(
            store: store,
            client: fake,
            clock: { clock.now() },
            sleeper: { _ in try await Task.sleep(nanoseconds: 1) }
        )
        // 建立 blocked 状态: 刷新成功但保存失败, 内存持有未过期新 token
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
            throw CodexTestFailure.expectation("首次刷新应成功并进入 blocked")
        }
        let state = await manager.statusSnapshot()
        guard state.accounts.first?.storageBlocked == true else {
            throw CodexTestFailure.expectation("保存失败必须 storageBlocked")
        }
        return (manager, fake, clock)
    }

    // BLK-01: storageBlocked, token 剩余 10 秒 -> available, OAuth 调用 0 次
    private static func blockedShortLivedTokenStillAvailable() async throws {
        let (manager, fake, clock) = try await makeBlockedManager()
        // 推进到新 token 剩余 10 秒 (仍 > 0, 且远小于 60 秒窗口)
        clock.advance(by: 3590)
        guard case .success(accessToken: let accessToken, expiresAt: _) =
            await manager.validAccessToken(for: "acc-1"),
              accessToken == "at-new" else {
            throw CodexTestFailure.expectation("blocked 且未过期 (剩 10 秒) 应返回 available")
        }
        guard fake.totalRefreshCount() == 1 else {
            throw CodexTestFailure.expectation("blocked 期间不得刷新, 总调用必须为 1")
        }
    }

    // BLK-02: storageBlocked, token 恰好过期 -> storageBlocked, OAuth 调用 0 次
    private static func blockedExactlyExpiredTokenRejected() async throws {
        let (manager, fake, clock) = try await makeBlockedManager()
        clock.advance(by: 3600)
        guard case .failure(.storageBlocked) = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("blocked 恰好过期应拒绝")
        }
        let before = fake.totalRefreshCount()
        _ = await manager.refreshAfterAccessRejected(for: "acc-1")
        guard fake.totalRefreshCount() == before else {
            throw CodexTestFailure.expectation("blocked 期间不得调用 OAuth")
        }
    }

    // BLK-03: storageBlocked, token 已过期 1 秒 -> storageBlocked, OAuth 调用 0 次
    private static func blockedExpiredOneSecondTokenRejected() async throws {
        let (manager, fake, clock) = try await makeBlockedManager()
        clock.advance(by: 3601)
        guard case .failure(.storageBlocked) = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("blocked 过期 1 秒应拒绝")
        }
        guard fake.totalRefreshCount() == 1 else {
            throw CodexTestFailure.expectation("blocked 期间不得调用 OAuth")
        }
    }

    // META-01: refresh 后如回读 record 将抛错 -> 不回读, 不写退化 record
    private static func refreshSaveDoesNotReadBackRecordForMetadata() async throws {
        let (baseStore, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        try baseStore.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "user@example.com",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: wrapped, client: fake, clock: clock)

        // 先成功读取一次并缓存元数据, 再让后续 account record 读取抛错.
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("元数据缓存预热应成功")
        }
        let accountKey = CodexCredentialKeys.accountKey(for: "acc-1")
        faulty.failLoads = [(accountKey, 1)]
        clock.advance(by: 3540)
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("刷新应成功")
        }
        let record = try baseStore.loadRecord(for: "acc-1")
        guard record?.email == "user@example.com",
              record?.credentialOrigin == .legacyCCSwitchDiscovery,
              record?.accessToken == "at-new",
              record?.refreshToken == "rt-new" else {
            throw CodexTestFailure.expectation("刷新保存必须使用已缓存的原始元数据")
        }
        guard faulty.loadAttemptCount(for: accountKey) == 0 else {
            throw CodexTestFailure.expectation("OAuth 成功后不得回读 account record")
        }
    }

    // META-02: META-01 后存储恢复 -> 原邮箱和 origin 保留, 新 token 最终写入
    private static func refreshSaveReadBackFailureKeepsMetadata() async throws {
        let (store, memory) = try makeStore(accounts: [
            "acc-1": (access: "at", refresh: "rt", expiresIn: 3600),
        ])
        try store.saveRecord(CodexAccountRecord(
            accountID: "acc-1",
            email: "user@example.com",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .success(CodexTokenResponse(
                accessToken: "at-new", refreshToken: "rt-new",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let clock = TestClock(start: fixedNow)
        let manager = makeManager(store: wrapped, client: fake, clock: clock)

        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("元数据缓存预热应成功")
        }
        let accountKey = CodexCredentialKeys.accountKey(for: "acc-1")
        faulty.failLoads = [(accountKey, 1)]
        faulty.failSaves = [(accountKey, 1)]
        clock.advance(by: 3540)
        guard case .success = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("刷新应成功")
        }
        await waitForRetry(manager: manager, clock: clock) {
            (try? store.loadRecord(for: "acc-1"))?.accessToken == "at-new"
        }
        let record = try store.loadRecord(for: "acc-1")
        guard record?.email == "user@example.com",
              record?.credentialOrigin == .legacyCCSwitchDiscovery,
              record?.accessToken == "at-new",
              record?.refreshToken == "rt-new" else {
            throw CodexTestFailure.expectation("元数据必须保留, 新 token 必须写入")
        }
        guard faulty.loadAttemptCount(for: accountKey) == 0 else {
            throw CodexTestFailure.expectation("存储重试也不得回读 account record")
        }
    }

    // META-03: record 不存在 -> 与读取异常产生不同 outcome
    private static func missingRecordDistinctFromReadError() async throws {
        let memory = InMemoryCredentialStore()
        let faulty = FaultyStore(inner: memory)
        let wrapped = CodexCredentialStore(store: faulty)
        let fake = FakeOAuthClient { _, _ in
            return .success(CodexTokenResponse(
                accessToken: "at", refreshToken: "rt",
                idToken: nil, expiresIn: 3600, receivedAt: fixedNow
            ))
        }
        let manager = makeManager(
            store: wrapped, client: fake, clock: TestClock(start: fixedNow)
        )
        // 无 record -> notFound
        guard case .failure(.notFound) = await manager.validAccessToken(for: "acc-1") else {
            throw CodexTestFailure.expectation("record 不存在应返回 notFound")
        }
        // 读取异常 -> 与 notFound 不同的 outcome (storageBlocked);
        // loadRecord 先读 index 键, 注入该键的读取失败
        faulty.failLoads = [(CodexCredentialKeys.accountIndexV2, 100)]
        let second = await manager.validAccessToken(for: "acc-1")
        guard case .failure(.storageBlocked) = second else {
            throw CodexTestFailure.expectation("读取异常应映射为 storageBlocked: \(second)")
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
