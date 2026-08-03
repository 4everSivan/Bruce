import Foundation

// MARK: - CodexTokenError

/// Token 决议的分类错误. description 面向用户, 不含 token 值.
public enum CodexTokenError: Error, Equatable, CustomStringConvertible {
    case needsReauthorization(accountID: String)
    case refreshFailed(accountID: String, reason: String)
    case storageBlocked(accountID: String)
    case notFound(accountID: String)

    public var description: String {
        switch self {
        case .needsReauthorization:
            return "需要在 mddd 内重新授权"
        case .refreshFailed(_, let reason):
            return "续期失败: \(reason)"
        case .storageBlocked:
            return "Keychain 存储异常"
        case .notFound:
            return "账号未连接"
        }
    }
}

// MARK: - TokenResolution

/// 单账号 token 决议结果: 成功携带短期 access token 与过期时刻; 失败携带分类错误.
public enum TokenResolution: Equatable, Sendable {
    case success(accessToken: String, expiresAt: Date)
    case failure(CodexTokenError)
}

// MARK: - CodexTokenManagerState

/// 非敏感状态快照, 供 UI 订阅. 不携带 token 或完整邮箱.
public struct CodexTokenManagerState: Equatable, Sendable {
    public struct AccountState: Equatable, Sendable {
        public let accountID: String
        public let displayName: String
        public let authorizationState: CodexAuthorizationState
        public let credentialOrigin: CodexCredentialOrigin
        public let storageBlocked: Bool
        public let updatedAt: Date?

        public init(
            accountID: String,
            displayName: String,
            authorizationState: CodexAuthorizationState,
            credentialOrigin: CodexCredentialOrigin,
            storageBlocked: Bool,
            updatedAt: Date?
        ) {
            self.accountID = accountID
            self.displayName = displayName
            self.authorizationState = authorizationState
            self.credentialOrigin = credentialOrigin
            self.storageBlocked = storageBlocked
            self.updatedAt = updatedAt
        }
    }

    public var accounts: [AccountState]

    public init(accounts: [AccountState] = []) {
        self.accounts = accounts
    }
}

// MARK: - 存储重试退避

/// 存储失败退避重试的延迟序列: 1s, 5s, 30s, 5m, 之后每 5 分钟.
public enum CodexStorageRetryPolicy {
    public static let delays: [TimeInterval] = [1, 5, 30, 300]
    public static let subsequentDelay: TimeInterval = 300

    public static func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return subsequentDelay }
        if attempt < delays.count {
            return delays[attempt]
        }
        return subsequentDelay
    }
}

// MARK: - CodexTokenManager

/// Codex access token 的唯一所有者: 缓存、按需续期、单账号互斥、轮换持久化.
///
/// 职责:
/// - 距过期 <= 60 秒时刷新, 否则复用.
/// - 同账号并发刷新合并为一次 in-flight 请求.
/// - refresh token 只存在于内存与 Keychain, 永不外传.
/// - 旋转后 Keychain 写失败进入 `storageBlocked`, 内存保留新 token,
///   按退避序列重试落盘, 不重放 OAuth 请求.
// MARK: - CodexTokenManager

/// Scheduler 定向重试使用的 token manager 最小接口 (任务 9):
/// 仅暴露失效、强制刷新等副作用操作, 不暴露存储内部.
/// 方法均为 async (actor 隔离); 协议不加全局 actor, actor 才能 conform.
public protocol CodexTokenManaging: AnyObject, Sendable {
    func invalidateAccessToken(for accountID: String) async
    func forceRefresh(for accountID: String, now: Date?) async -> TokenResolution
}

public actor CodexTokenManager: CodexTokenManaging {
    public static let refreshWindow: TimeInterval = 60
    public static let maxConcurrentAccounts = 4

    private struct AccountCache {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var accessTokenExpiresAt: Date?
        var authorizationState: CodexAuthorizationState = .needsReauthorization
        var storageBlocked = false
        var refreshNotBefore: Date?
        var inFlightTask: Task<TokenResolution, Never>?
        var storageRetryTask: Task<Void, Never>?
        var updatedAt: Date?
    }

    private let store: CodexCredentialStore
    private let client: any CodexOAuthClientProtocol
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private var caches: [String: AccountCache] = [:]

    public init(
        store: CodexCredentialStore,
        client: any CodexOAuthClientProtocol,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.store = store
        self.client = client
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: 状态观察

    /// 非敏感状态快照.
    public func statusSnapshot() -> CodexTokenManagerState {
        let accounts = caches
            .sorted { $0.key < $1.key }
            .compactMap { accountID, cache -> CodexTokenManagerState.AccountState? in
                guard let record = try? store.loadRecord(for: accountID) else {
                    return nil
                }
                return CodexTokenManagerState.AccountState(
                    accountID: accountID,
                    displayName: record.displayName,
                    authorizationState: cache.authorizationState,
                    credentialOrigin: record.credentialOrigin,
                    storageBlocked: cache.storageBlocked,
                    updatedAt: cache.updatedAt
                )
            }
        return CodexTokenManagerState(accounts: accounts)
    }

    // MARK: 登录接入

    /// 登录成功后保存完整 v2 记录并预热缓存.
    public func storeLoginResult(
        accountID: String,
        email: String?,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expiresAt: Date?
    ) throws {
        let now = clock()
        let record = CodexAccountRecord(
            accountID: accountID,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accessTokenExpiresAt: expiresAt,
            authorizationState: .connected,
            credentialOrigin: .mddd,
            updatedAt: now
        )
        try store.saveRecord(record)
        var cache = caches[accountID] ?? AccountCache()
        cache.accessToken = accessToken
        cache.refreshToken = refreshToken
        cache.idToken = idToken
        cache.accessTokenExpiresAt = expiresAt
        cache.authorizationState = .connected
        cache.storageBlocked = false
        cache.refreshNotBefore = nil
        cache.updatedAt = now
        caches[accountID] = cache
    }

    // MARK: token 决议

    /// 返回该账号当前有效 access token; 距过期 <= 60 秒时刷新.
    public func validAccessToken(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        let current = now ?? clock()
        if let cache = caches[accountID],
           cache.authorizationState == .connected,
           let expiresAt = cache.accessTokenExpiresAt,
           expiresAt.timeIntervalSince(current) > Self.refreshWindow,
           let accessToken = cache.accessToken {
            return .success(accessToken: accessToken, expiresAt: expiresAt)
        }
        return await refreshIfNeeded(for: accountID, now: current, force: false)
    }

    /// 解析多个账号 (额度查询前调用). 单账号失败不阻断其他账号;
    /// 需要刷新的账号按并发上限 4 并行处理.
    public func validAccessTokens(
        for accountIDs: [String],
        now: Date? = nil
    ) async -> [String: TokenResolution] {
        let current = now ?? clock()
        var results: [String: TokenResolution] = [:]
        var pending: [String] = []
        for accountID in accountIDs {
            if let cache = caches[accountID],
               cache.authorizationState == .connected,
               let expiresAt = cache.accessTokenExpiresAt,
               expiresAt.timeIntervalSince(current) > Self.refreshWindow,
               let accessToken = cache.accessToken {
                results[accountID] = .success(
                    accessToken: accessToken, expiresAt: expiresAt
                )
            } else {
                pending.append(accountID)
            }
        }
        for chunk in pending.chunked(by: Self.maxConcurrentAccounts) {
            await withTaskGroup(of: (String, TokenResolution).self) { group in
                for accountID in chunk {
                    group.addTask {
                        let resolution = await self.refreshIfNeeded(
                            for: accountID, now: current, force: false
                        )
                        return (accountID, resolution)
                    }
                }
                for await (accountID, resolution) in group {
                    results[accountID] = resolution
                }
            }
        }
        return results
    }

    /// 使缓存中的 access token 失效 (quota 401 后触发强制刷新).
    /// async: 满足 CodexTokenManaging 协议的 actor 隔离要求.
    public func invalidateAccessToken(for accountID: String) async {
        guard var cache = caches[accountID] else { return }
        cache.accessToken = nil
        cache.accessTokenExpiresAt = nil
        cache.refreshNotBefore = nil
        caches[accountID] = cache
    }

    /// 强制刷新单账号: 越过缓存, 但仍复用同账号 in-flight task.
    public func forceRefresh(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        await refreshIfNeeded(for: accountID, now: now ?? clock(), force: true)
    }

    // MARK: 断开

    /// 断开账号: 取消任务、删除 v2 记录并更新索引.
    public func disconnect(accountID: String) throws {
        caches[accountID]?.inFlightTask?.cancel()
        caches[accountID]?.storageRetryTask?.cancel()
        caches[accountID] = nil
        try store.deleteRecord(for: accountID)
    }

    // MARK: 刷新核心

    private func refreshIfNeeded(
        for accountID: String,
        now: Date,
        force: Bool
    ) async -> TokenResolution {
        if caches[accountID] == nil {
            guard let record = try? store.loadRecord(for: accountID) else {
                return .failure(.notFound(accountID: accountID))
            }
            caches[accountID] = AccountCache(
                accessToken: record.accessToken,
                refreshToken: record.refreshToken,
                idToken: record.idToken,
                accessTokenExpiresAt: record.accessTokenExpiresAt,
                authorizationState: record.authorizationState,
                storageBlocked: false,
                refreshNotBefore: nil,
                inFlightTask: nil,
                storageRetryTask: nil,
                updatedAt: record.updatedAt
            )
        }
        guard var cache = caches[accountID] else {
            return .failure(.notFound(accountID: accountID))
        }

        // 需要重新授权: 不尝试刷新
        if cache.authorizationState == .needsReauthorization {
            return .failure(.needsReauthorization(accountID: accountID))
        }
        // 存储失败重试期间内存 token 仍有效: 直接复用, 不重复刷新
        if cache.storageBlocked,
           let accessToken = cache.accessToken,
           let expiresAt = cache.accessTokenExpiresAt,
           expiresAt.timeIntervalSince(now) > Self.refreshWindow {
            return .success(accessToken: accessToken, expiresAt: expiresAt)
        }
        // refresh not-before 退避: 暂时失败后不盲目重放
        if !force,
           let notBefore = cache.refreshNotBefore,
           now < notBefore {
            if let accessToken = cache.accessToken,
               let expiresAt = cache.accessTokenExpiresAt,
               expiresAt.timeIntervalSince(now) > 0 {
                return .success(accessToken: accessToken, expiresAt: expiresAt)
            }
            return .failure(.refreshFailed(accountID: accountID, reason: "暂缓重试"))
        }

        // 复用同账号 in-flight task
        if let inFlight = cache.inFlightTask {
            return await inFlight.value
        }
        // 距过期仍在刷新窗口外: 直接复用, 不刷新 (冷缓存首访也生效)
        if !force,
           let expiresAt = cache.accessTokenExpiresAt,
           expiresAt.timeIntervalSince(now) > Self.refreshWindow,
           let accessToken = cache.accessToken {
            return .success(accessToken: accessToken, expiresAt: expiresAt)
        }
        guard cache.refreshToken != nil else {
            return .failure(.needsReauthorization(accountID: accountID))
        }

        let task = Task<TokenResolution, Never> { [accountID] in
            await self.performRefresh(accountID: accountID, now: now)
        }
        cache.inFlightTask = task
        caches[accountID] = cache
        let resolution = await task.value
        caches[accountID]?.inFlightTask = nil
        return resolution
    }

    /// 执行一次 refresh 并处理结果 (只由 in-flight task 调用).
    private func performRefresh(
        accountID: String,
        now: Date
    ) async -> TokenResolution {
        guard var cache = caches[accountID],
              let refreshToken = cache.refreshToken else {
            return .failure(.needsReauthorization(accountID: accountID))
        }
        let result = await client.perform(
            client.refreshRequest(refreshToken: refreshToken),
            session: nil
        )
        switch result {
        case .failure(let error):
            switch error {
            case .invalidGrant:
                cache.authorizationState = .needsReauthorization
                cache.refreshNotBefore = nil
                caches[accountID] = cache
                return .failure(.needsReauthorization(accountID: accountID))
            case .rateLimit(let retryAfter):
                cache.refreshNotBefore = now.addingTimeInterval(
                    retryAfter ?? 300
                )
                caches[accountID] = cache
                return .failure(.refreshFailed(accountID: accountID, reason: "限流"))
            case .serverError:
                cache.refreshNotBefore = now.addingTimeInterval(300)
                caches[accountID] = cache
                return .failure(.refreshFailed(
                    accountID: accountID, reason: "服务暂时不可用"
                ))
            case .networkUnreachable, .httpStatus:
                cache.refreshNotBefore = now.addingTimeInterval(300)
                caches[accountID] = cache
                return .failure(.refreshFailed(accountID: accountID, reason: "网络错误"))
            case .invalidResponse:
                return .failure(.refreshFailed(accountID: accountID, reason: "响应无效"))
            case .cancelled:
                return .failure(.refreshFailed(accountID: accountID, reason: "已取消"))
            }
        case .success(let token):
            // 先更新内存, 再写 Keychain
            let expiresAt = CodexTokenExpiry.expiresAt(
                from: token,
                jwtExp: CodexTokenExpiry.jwtExp(of: token.idToken)
            )
            let newRefreshToken = token.refreshToken ?? cache.refreshToken
            cache.accessToken = token.accessToken
            cache.refreshToken = newRefreshToken
            cache.idToken = token.idToken ?? cache.idToken
            cache.accessTokenExpiresAt = expiresAt
            cache.authorizationState = .connected
            cache.refreshNotBefore = nil
            cache.updatedAt = now
            do {
                try store.saveRecord(CodexAccountRecord(
                    accountID: accountID,
                    email: nil,
                    accessToken: token.accessToken,
                    refreshToken: newRefreshToken,
                    idToken: cache.idToken,
                    accessTokenExpiresAt: expiresAt,
                    authorizationState: .connected,
                    credentialOrigin: .mddd,
                    updatedAt: now
                ))
                cache.storageBlocked = false
                caches[accountID] = cache
            } catch {
                cache.storageBlocked = true
                caches[accountID] = cache
                startStorageRetry(
                    accountID: accountID,
                    accessToken: token.accessToken,
                    refreshToken: newRefreshToken,
                    idToken: cache.idToken,
                    expiresAt: expiresAt
                )
            }
            return .success(accessToken: token.accessToken, expiresAt: expiresAt)
        }
    }

    /// 旋转后 Keychain 写失败: 按退避序列重试落盘, 直到成功或账号断开.
    /// 不重放 OAuth refresh 请求.
    private func startStorageRetry(
        accountID: String,
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresAt: Date
    ) {
        let task = Task { [sleeper] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = CodexStorageRetryPolicy.delay(forAttempt: attempt)
                try? await sleeper(delay)
                attempt += 1
                guard !Task.isCancelled else { return }
                do {
                    try self.store.saveRecord(CodexAccountRecord(
                        accountID: accountID,
                        email: nil,
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        idToken: idToken,
                        accessTokenExpiresAt: expiresAt,
                        authorizationState: .connected,
                        credentialOrigin: .mddd,
                        updatedAt: self.clock()
                    ))
                    self.caches[accountID]?.storageBlocked = false
                    self.caches[accountID]?.storageRetryTask = nil
                    return
                } catch {
                    continue
                }
            }
        }
        caches[accountID]?.storageRetryTask = task
    }
}

// MARK: - 数组分块

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
