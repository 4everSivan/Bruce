import Foundation

// MARK: - CodexRefreshFailureReason

/// Codex token 刷新失败的分类原因. 替代旧的字符串 reason,
/// 禁止在调用方做字符串比较. description 面向用户, 不含 token 值.
public enum CodexRefreshFailureReason: String, Equatable, Sendable {
    /// 刷新退避未到, 本轮暂缓 (可复用未过期 token 或返回暂时不可用).
    case deferred
    /// OAuth 服务端限流.
    case rateLimited
    /// OAuth 服务端 5xx 或暂时不可用.
    case serviceUnavailable
    /// 网络/DNS/TLS/超时.
    case networkError
    /// 响应体无法解析或字段缺失.
    case invalidResponse
    /// 任务被取消.
    case cancelled

    public var description: String {
        switch self {
        case .deferred: return "暂缓重试"
        case .rateLimited: return "限流"
        case .serviceUnavailable: return "服务暂时不可用"
        case .networkError: return "网络错误"
        case .invalidResponse: return "响应无效"
        case .cancelled: return "已取消"
        }
    }
}

// MARK: - CodexTokenError

/// Token 决议的分类错误. description 面向用户, 不含 token 值.
public enum CodexTokenError: Error, Equatable, CustomStringConvertible {
    case needsReauthorization(accountID: String)
    case refreshFailed(accountID: String, reason: CodexRefreshFailureReason)
    case storageBlocked(accountID: String)
    case notFound(accountID: String)

    public var description: String {
        switch self {
        case .needsReauthorization:
            return "需要在 mddd 内重新授权"
        case .refreshFailed(_, let reason):
            return "续期失败: \(reason.description)"
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
/// - `storageBlocked` 优先阻止所有 refresh, 包括 401 强制刷新.
/// - `invalid_grant` 清除 token 并持久化 metadata-only 重新授权状态.

/// Scheduler 定向重试使用的 token manager 最小接口:
/// 仅暴露 401 后的 `refreshAfterAccessRejected`, 不暴露存储内部.
/// 方法均为 async (actor 隔离); 协议不加全局 actor, actor 才能 conform.
public protocol CodexTokenManaging: AnyObject, Sendable {
    /// 401 accessRejected 后的定向刷新: storageBlocked 期间不调用 OAuth,
    /// 内存 token 仍有效时直接返回; 需重新授权或无 token 时返回失败.
    func refreshAfterAccessRejected(
        for accountID: String,
        now: Date?
    ) async -> TokenResolution
}

/// Scheduler 多账号 401 闭环使用的 token manager 接口 (任务 8):
/// 在 `CodexTokenManaging` 基础上增加第二次 401 的重新授权持久化.
/// 持久化只写该账号的授权状态, 不影响其他账号凭证.
public protocol CodexChallengeHandling: CodexTokenManaging {
    /// 第二次 401 后把该账号持久化为 needsReauthorization.
    /// 幂等; 账号不存在时静默成功 (无需持久化).
    func markNeedsReauthorization(
        for accountID: String,
        now: Date?
    ) async
}

public actor CodexTokenManager: CodexChallengeHandling {
    public static let refreshWindow: TimeInterval = 60

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
        /// 记录版本: 登录、删除、断开时递增, 存储重试任务写入前校验.
        var revision: Int = 0
        /// 首次成功读取 record 时缓存的非敏感元数据快照 (任务 3):
        /// 与 token 生命周期分离, 刷新/持久化不再依赖 Keychain 回读补齐.
        var email: String?
        var credentialOrigin: CodexCredentialOrigin = .mddd
        /// 待持久化 record (任务 2): 保存失败时保留, 由唯一存储重试落盘.
        var pendingRecord: PendingRecord?
    }

    /// 待持久化的 record 与写入时 revision (任务 2).
    private struct PendingRecord {
        var record: CodexAccountRecord
        var revision: Int
    }

    private let store: CodexCredentialStore
    private let client: any CodexOAuthClientProtocol
    private let clock: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private var caches: [String: AccountCache] = [:]
    /// 冷缓存下标记 needsReauthorization 时若 Keychain 读取失败, 保留请求并
    /// 独立重试元数据读取. 读取成功后再进入统一 metadata-only 持久化入口,
    /// 不伪造 email/origin.
    private var pendingReauthorizationLoads: [String: Date] = [:]
    private var metadataLoadRetryTasks: [String: Task<Void, Never>] = [:]

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

    deinit {
        for cache in caches.values {
            cache.inFlightTask?.cancel()
            cache.storageRetryTask?.cancel()
        }
        for task in metadataLoadRetryTasks.values {
            task.cancel()
        }
    }

    // MARK: 状态观察

    /// 非敏感状态快照.
    public func statusSnapshot() -> CodexTokenManagerState {
        let accounts = caches
            .sorted { $0.key < $1.key }
            .map { accountID, cache -> CodexTokenManagerState.AccountState in
                let displayName: String
                if let email = cache.email, !email.isEmpty {
                    displayName = "Codex · "
                        + (email.split(separator: "@").first.map(String.init) ?? "")
                } else {
                    displayName = "Codex · " + String(accountID.prefix(8))
                }
                return CodexTokenManagerState.AccountState(
                    accountID: accountID,
                    displayName: displayName,
                    authorizationState: cache.authorizationState,
                    credentialOrigin: cache.credentialOrigin,
                    storageBlocked: cache.storageBlocked,
                    updatedAt: cache.updatedAt
                )
            }
        return CodexTokenManagerState(accounts: accounts)
    }

    // MARK: 登录接入

    /// 登录成功后保存完整 v2 记录并预热缓存.
    /// 递增 revision 并取消旧存储重试任务, 防止旧任务覆盖新记录.
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
        metadataLoadRetryTasks[accountID]?.cancel()
        metadataLoadRetryTasks[accountID] = nil
        pendingReauthorizationLoads[accountID] = nil
        var cache = caches[accountID] ?? AccountCache()
        // 取消旧存储重试任务, 递增 revision 防止旧任务写入覆盖新记录
        cache.storageRetryTask?.cancel()
        cache.storageRetryTask = nil
        cache.revision += 1
        cache.accessToken = accessToken
        cache.refreshToken = refreshToken
        cache.idToken = idToken
        cache.accessTokenExpiresAt = expiresAt
        cache.authorizationState = .connected
        cache.storageBlocked = false
        cache.refreshNotBefore = nil
        cache.updatedAt = now
        // 登录本身就是最新元数据来源, 同步缓存 (任务 3)
        cache.email = email
        cache.credentialOrigin = .mddd
        cache.pendingRecord = nil
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

    /// 401 accessRejected 后的定向刷新.
    /// storageBlocked 期间不调用 OAuth: 内存 token 仍有效时直接返回,
    /// 已过期时返回 .storageBlocked 失败 (不恢复 OAuth 请求).
    /// 需重新授权账号返回 .needsReauthorization, 不调用 OAuth.
    public func refreshAfterAccessRejected(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        let current = now ?? clock()
        return await refreshIfNeeded(for: accountID, now: current, force: true)
    }

    /// 第二次 401: 把该账号持久化为 needsReauthorization (任务 8).
    /// 只写该账号授权状态, 不清除其他账号; 账号不存在或已处于
    /// needsReauthorization 时幂等.
    public func markNeedsReauthorization(
        for accountID: String,
        now: Date? = nil
    ) async {
        persistNeedsReauthorization(
            for: accountID, now: now ?? clock()
        )
    }

    // MARK: 统一 needsReauthorization 持久化 (任务 2)

    /// 三个授权失效入口 (手动标记 / 第二次 401 / OAuth invalid_grant)
    /// 的唯一持久化函数:
    /// - 先递增 revision 并替换 pending record, 取消同账号旧存储重试.
    /// - 立即尝试写入; 成功且 revision 最新时清除 pending 并解除 storageBlocked.
    /// - 失败保留 pending, 置 storageBlocked, 安排同账号唯一存储重试
    ///   (不发起 OAuth refresh).
    /// - 持久化前清空 access/refresh/id token, 保留 accountID/displayName/
    ///   邮箱/credentialOrigin.
    /// - 新的 connected record 保存成功 (storeLoginResult) 也递增 revision,
    ///   防止旧的 needsReauthorization 重试反向覆盖新登录.
    private func persistNeedsReauthorization(
        for accountID: String,
        now: Date
    ) {
        // 元数据来源: 内存缓存快照优先, 冷缓存时从 record 读取一次.
        if caches[accountID] == nil {
            let record: CodexAccountRecord?
            do {
                record = try store.loadRecord(for: accountID)
            } catch {
                scheduleNeedsReauthorizationMetadataRetry(
                    for: accountID,
                    requestedAt: now
                )
                return
            }
            if let record {
                var cache = AccountCache()
                cache.email = record.email
                cache.credentialOrigin = record.credentialOrigin
                cache.authorizationState = record.resolvedAuthorizationState
                cache.updatedAt = record.updatedAt
                caches[accountID] = cache
            }
        }
        guard var cache = caches[accountID] else { return }

        cache.authorizationState = .needsReauthorization
        cache.accessToken = nil
        cache.refreshToken = nil
        cache.idToken = nil
        cache.accessTokenExpiresAt = nil
        cache.refreshNotBefore = nil
        cache.updatedAt = now
        cache.revision += 1
        cache.storageRetryTask?.cancel()
        cache.storageRetryTask = nil

        let record = CodexAccountRecord(
            accountID: accountID,
            email: cache.email,
            accessToken: nil,
            refreshToken: nil,
            idToken: nil,
            accessTokenExpiresAt: nil,
            authorizationState: .needsReauthorization,
            credentialOrigin: cache.credentialOrigin,
            updatedAt: now
        )
        let pending = PendingRecord(record: record, revision: cache.revision)
        cache.pendingRecord = pending
        caches[accountID] = cache

        do {
            try store.saveRecord(record)
            // 仅当完成 revision 仍是最新 revision 时清除 pending
            guard caches[accountID]?.revision == pending.revision else { return }
            caches[accountID]?.pendingRecord = nil
            caches[accountID]?.storageBlocked = false
        } catch {
            caches[accountID]?.storageBlocked = true
            scheduleStorageRetry(for: accountID)
        }
    }

    /// 同账号唯一存储重试: 从 pending record 落盘 (不重放 OAuth).
    /// 写入前校验 revision; 成功后解除 storageBlocked 并清除 pending.
    /// 每次仅保留一个重试任务 (已有任务时不再新建).
    private func scheduleStorageRetry(for accountID: String) {
        guard caches[accountID]?.storageRetryTask == nil else { return }
        let task = Task { [weak self, sleeper] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = CodexStorageRetryPolicy.delay(forAttempt: attempt)
                try? await sleeper(delay)
                attempt += 1
                guard !Task.isCancelled, let self else { return }
                if await self.performStorageRetryAttempt(for: accountID) {
                    return
                }
            }
        }
        caches[accountID]?.storageRetryTask = task
    }

    /// 返回 true 表示任务应结束 (已成功、pending 已失效或账号已移除),
    /// false 表示本次仍是存储失败, 继续按退避重试.
    private func performStorageRetryAttempt(for accountID: String) -> Bool {
        guard let pending = caches[accountID]?.pendingRecord,
              caches[accountID]?.revision == pending.revision else {
            return true
        }
        do {
            try store.saveRecord(pending.record)
            guard caches[accountID]?.revision == pending.revision else {
                return true
            }
            caches[accountID]?.pendingRecord = nil
            caches[accountID]?.storageBlocked = false
            caches[accountID]?.storageRetryTask = nil
            return true
        } catch {
            return false
        }
    }

    /// 冷缓存 metadata 读取失败的唯一重试任务. 只重试 Keychain 读取与
    /// metadata-only 持久化, 永远不发起 OAuth refresh.
    private func scheduleNeedsReauthorizationMetadataRetry(
        for accountID: String,
        requestedAt: Date
    ) {
        pendingReauthorizationLoads[accountID] = requestedAt
        guard metadataLoadRetryTasks[accountID] == nil else { return }
        let task = Task { [weak self, sleeper] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = CodexStorageRetryPolicy.delay(forAttempt: attempt)
                try? await sleeper(delay)
                attempt += 1
                guard !Task.isCancelled, let self else { return }
                if await self.performMetadataLoadRetryAttempt(for: accountID) {
                    return
                }
            }
        }
        metadataLoadRetryTasks[accountID] = task
    }

    /// 返回 true 表示任务应结束 (请求已取消、账号不存在或已进入统一持久化),
    /// false 表示 Keychain 读取仍失败, 继续按退避重试.
    private func performMetadataLoadRetryAttempt(for accountID: String) -> Bool {
        guard let requestedAt = pendingReauthorizationLoads[accountID] else {
            return true
        }
        let record: CodexAccountRecord?
        do {
            record = try store.loadRecord(for: accountID)
        } catch {
            return false
        }

        pendingReauthorizationLoads[accountID] = nil
        metadataLoadRetryTasks[accountID] = nil
        guard let record else {
            // 账号确实不存在时维持 mark 的幂等静默语义.
            return true
        }
        var cache = AccountCache()
        cache.email = record.email
        cache.credentialOrigin = record.credentialOrigin
        cache.authorizationState = record.resolvedAuthorizationState
        cache.updatedAt = record.updatedAt
        caches[accountID] = cache
        persistNeedsReauthorization(for: accountID, now: requestedAt)
        return true
    }

    // MARK: 断开

    /// 断开账号: 取消任务、递增 revision、删除 v2 记录并更新索引.
    public func disconnect(accountID: String) throws {
        caches[accountID]?.inFlightTask?.cancel()
        caches[accountID]?.storageRetryTask?.cancel()
        metadataLoadRetryTasks[accountID]?.cancel()
        metadataLoadRetryTasks[accountID] = nil
        pendingReauthorizationLoads[accountID] = nil
        caches[accountID] = nil
        try store.deleteRecord(for: accountID)
    }

    // MARK: 刷新核心

    private func refreshIfNeeded(
        for accountID: String,
        now: Date,
        force: Bool
    ) async -> TokenResolution {
        if pendingReauthorizationLoads[accountID] != nil {
            return .failure(.storageBlocked(accountID: accountID))
        }
        if caches[accountID] == nil {
            // 显式 do/catch, 不用 try? 折叠错误 (任务 3): Keychain 读取
            // 错误是存储失败, 与 record 不存在 (notFound) 严格区分
            let record: CodexAccountRecord?
            do {
                record = try store.loadRecord(for: accountID)
            } catch {
                return .failure(.storageBlocked(accountID: accountID))
            }
            guard let record else {
                return .failure(.notFound(accountID: accountID))
            }
            // 初始化使用 resolvedAuthorizationState (fail-closed);
            // 同时缓存非敏感元数据快照 (任务 3), 刷新保存不再依赖回读
            caches[accountID] = AccountCache(
                accessToken: record.accessToken,
                refreshToken: record.refreshToken,
                idToken: record.idToken,
                accessTokenExpiresAt: record.accessTokenExpiresAt,
                authorizationState: record.resolvedAuthorizationState,
                storageBlocked: false,
                refreshNotBefore: nil,
                inFlightTask: nil,
                storageRetryTask: nil,
                updatedAt: record.updatedAt,
                revision: 0,
                email: record.email,
                credentialOrigin: record.credentialOrigin,
                pendingRecord: nil
            )
        }
        guard var cache = caches[accountID] else {
            return .failure(.notFound(accountID: accountID))
        }

        // 需要重新授权: 不尝试刷新 (包括 401 强制刷新)
        if cache.authorizationState == .needsReauthorization {
            return .failure(.needsReauthorization(accountID: accountID))
        }
        // storageBlocked 优先阻止所有 refresh, 包括 401 强制刷新:
        // 内存 token 未过期 (expiresAt > now, 即使只剩 1 秒) 时直接返回;
        // 已过期时返回 .storageBlocked (任务 3, 不再复用 60 秒预刷新窗口)
        if cache.storageBlocked {
            if let accessToken = cache.accessToken,
               let expiresAt = cache.accessTokenExpiresAt,
               expiresAt > now {
                return .success(accessToken: accessToken, expiresAt: expiresAt)
            }
            return .failure(.storageBlocked(accountID: accountID))
        }
        // refresh not-before 退避: 暂时失败后不盲目重放 (force 也受退避约束)
        if !force,
           let notBefore = cache.refreshNotBefore,
           now < notBefore {
            if let accessToken = cache.accessToken,
               let expiresAt = cache.accessTokenExpiresAt,
               expiresAt.timeIntervalSince(now) > 0 {
                return .success(accessToken: accessToken, expiresAt: expiresAt)
            }
            return .failure(.refreshFailed(accountID: accountID, reason: .deferred))
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
                // 统一持久化入口 (任务 2): 保存失败进 storageBlocked + 存储重试,
                // 不恢复 OAuth, refresh token 不再被使用. revision 只在统一
                // 入口递增一次, 避免一次 invalid_grant 产生两次状态版本.
                persistNeedsReauthorization(for: accountID, now: now)
                return .failure(.needsReauthorization(accountID: accountID))
            case .rateLimit(let retryAfter):
                cache.refreshNotBefore = now.addingTimeInterval(
                    retryAfter ?? 300
                )
                caches[accountID] = cache
                return .failure(.refreshFailed(accountID: accountID, reason: .rateLimited))
            case .serverError:
                cache.refreshNotBefore = now.addingTimeInterval(300)
                caches[accountID] = cache
                return .failure(.refreshFailed(
                    accountID: accountID, reason: .serviceUnavailable
                ))
            case .networkUnreachable, .httpStatus:
                cache.refreshNotBefore = now.addingTimeInterval(300)
                caches[accountID] = cache
                return .failure(.refreshFailed(accountID: accountID, reason: .networkError))
            case .invalidResponse:
                return .failure(.refreshFailed(accountID: accountID, reason: .invalidResponse))
            case .cancelled:
                return .failure(.refreshFailed(accountID: accountID, reason: .cancelled))
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
            caches[accountID] = cache
            do {
                // 任务 3: 用刷新开始前已缓存并保留的 record snapshot 构造新
                // record, 不依赖 Keychain 回读补齐元数据; 不写伪造默认值
                try store.saveRecord(CodexAccountRecord(
                    accountID: accountID,
                    email: cache.email,
                    accessToken: token.accessToken,
                    refreshToken: newRefreshToken,
                    idToken: cache.idToken,
                    accessTokenExpiresAt: expiresAt,
                    authorizationState: .connected,
                    credentialOrigin: cache.credentialOrigin,
                    updatedAt: now
                ))
                caches[accountID]?.storageBlocked = false
                caches[accountID]?.pendingRecord = nil
            } catch {
                // 保存失败: 保留 pending record, 进 storageBlocked, 存储重试
                caches[accountID]?.storageBlocked = true
                caches[accountID]?.pendingRecord = PendingRecord(
                    record: CodexAccountRecord(
                        accountID: accountID,
                        email: cache.email,
                        accessToken: token.accessToken,
                        refreshToken: newRefreshToken,
                        idToken: cache.idToken,
                        accessTokenExpiresAt: expiresAt,
                        authorizationState: .connected,
                        credentialOrigin: cache.credentialOrigin,
                        updatedAt: now
                    ),
                    revision: cache.revision
                )
                scheduleStorageRetry(for: accountID)
            }
            return .success(accessToken: token.accessToken, expiresAt: expiresAt)
        }
    }

}
