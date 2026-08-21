import Foundation

// MARK: - CodexTokenResolver

/// Codex token 决议实现: 缓存命中、过期判断、账号级 in-flight 去重、
/// 存储重试与 metadata 重试. 纯状态变迁委托 `CredentialStateReducer`.
///
/// 不暴露为公共 façade; 由 `CodexTokenManager` 持有并转发公共 API.
public actor CodexTokenResolver {
    public static let refreshWindow: TimeInterval = CredentialStateReducer.refreshWindow

    private struct AccountCache {
        var state: CredentialAccountState
        var inFlightTask: Task<TokenResolution, Never>?
        var storageRetryTask: Task<Void, Never>?
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

    public func statusSnapshot() -> CodexTokenManagerState {
        let accounts = caches
            .sorted { $0.key < $1.key }
            .map { accountID, cache -> CodexTokenManagerState.AccountState in
                let displayName: String
                if let email = cache.state.email, !email.isEmpty {
                    displayName = "Codex · "
                        + (email.split(separator: "@").first.map(String.init) ?? "")
                } else {
                    displayName = "Codex · " + String(accountID.prefix(8))
                }
                return CodexTokenManagerState.AccountState(
                    accountID: accountID,
                    displayName: displayName,
                    authorizationState: cache.state.authorizationState,
                    credentialOrigin: cache.state.credentialOrigin,
                    storageBlocked: cache.state.storageBlocked,
                    updatedAt: cache.state.updatedAt
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
        let applied = CredentialStateReducer.applyLogin(
            previous: caches[accountID]?.state,
            accountID: accountID,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt,
            now: now
        )
        try store.saveRecord(applied.record)
        metadataLoadRetryTasks[accountID]?.cancel()
        metadataLoadRetryTasks[accountID] = nil
        pendingReauthorizationLoads[accountID] = nil
        // 取消旧存储重试任务, 防止旧任务写入覆盖新记录
        caches[accountID]?.storageRetryTask?.cancel()
        caches[accountID] = AccountCache(
            state: applied.state,
            inFlightTask: caches[accountID]?.inFlightTask,
            storageRetryTask: nil
        )
    }

    // MARK: token 决议

    /// 返回该账号当前有效 access token; 距过期 <= 60 秒时刷新.
    public func validAccessToken(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        let current = now ?? clock()
        if let cache = caches[accountID],
           let reused = CredentialStateReducer.hotPathReuse(
               state: cache.state, now: current, refreshWindow: Self.refreshWindow
           ) {
            return .success(accessToken: reused.accessToken, expiresAt: reused.expiresAt)
        }
        return await refreshIfNeeded(for: accountID, now: current, force: false)
    }

    /// 401 accessRejected 后的定向刷新.
    public func refreshAfterAccessRejected(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        let current = now ?? clock()
        return await refreshIfNeeded(for: accountID, now: current, force: true)
    }

    /// 第二次 401: 把该账号持久化为 needsReauthorization.
    public func markNeedsReauthorization(
        for accountID: String,
        now: Date? = nil
    ) async {
        persistNeedsReauthorization(
            for: accountID, now: now ?? clock()
        )
    }

    // MARK: 统一 needsReauthorization 持久化

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
                caches[accountID] = AccountCache(
                    state: .metadataOnly(from: record),
                    inFlightTask: nil,
                    storageRetryTask: nil
                )
            }
        }
        guard let existing = caches[accountID] else { return }

        let applied = CredentialStateReducer.applyNeedsReauthorization(
            state: existing.state,
            accountID: accountID,
            now: now
        )
        existing.storageRetryTask?.cancel()
        caches[accountID] = AccountCache(
            state: applied.state,
            inFlightTask: existing.inFlightTask,
            storageRetryTask: nil
        )

        do {
            try store.saveRecord(applied.record)
            // 仅当完成 revision 仍是最新 revision 时清除 pending
            if let updated = caches[accountID],
               let cleared = CredentialStateReducer.applyStorageSuccess(
                   state: updated.state,
                   expectedRevision: applied.state.revision
               ) {
                caches[accountID]?.state = cleared
            }
        } catch {
            if var cache = caches[accountID] {
                cache.state = CredentialStateReducer.applyStorageFailure(
                    state: cache.state,
                    record: applied.record,
                    revision: applied.state.revision
                )
                caches[accountID] = cache
            }
            scheduleStorageRetry(for: accountID)
        }
    }

    /// 同账号唯一存储重试: 从 pending record 落盘 (不重放 OAuth).
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
        guard let cache = caches[accountID],
              let pending = CredentialStateReducer.pendingRecordIfCurrent(
                  state: cache.state
              ),
              let expectedRevision = cache.state.pendingRevision else {
            return true
        }
        do {
            try store.saveRecord(pending)
            guard let current = caches[accountID],
                  let cleared = CredentialStateReducer.applyStorageSuccess(
                      state: current.state,
                      expectedRevision: expectedRevision
                  ) else {
                return true
            }
            caches[accountID] = AccountCache(
                state: cleared,
                inFlightTask: current.inFlightTask,
                storageRetryTask: nil
            )
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
        caches[accountID] = AccountCache(
            state: .metadataOnly(from: record),
            inFlightTask: nil,
            storageRetryTask: nil
        )
        persistNeedsReauthorization(for: accountID, now: requestedAt)
        return true
    }

    // MARK: 断开

    /// 断开账号: 取消任务、删除 v2 记录并更新索引.
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
            // 显式 do/catch, 不用 try? 折叠错误: Keychain 读取
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
            caches[accountID] = AccountCache(
                state: .seeded(from: record),
                inFlightTask: nil,
                storageRetryTask: nil
            )
        }
        guard let cache = caches[accountID] else {
            return .failure(.notFound(accountID: accountID))
        }

        // 纯决策: 复用 / 失败 / 需要网络
        switch CredentialStateReducer.resolveGate(
            state: cache.state,
            accountID: accountID,
            now: now,
            force: force,
            refreshWindow: Self.refreshWindow
        ) {
        case .resolved(let resolution):
            return resolution
        case .needsNetworkRefresh:
            break
        }

        // 复用同账号 in-flight task
        if let inFlight = cache.inFlightTask {
            return await inFlight.value
        }

        let task = Task<TokenResolution, Never> { [accountID] in
            await self.performRefresh(accountID: accountID, now: now)
        }
        caches[accountID]?.inFlightTask = task
        let resolution = await task.value
        caches[accountID]?.inFlightTask = nil
        return resolution
    }

    /// 执行一次 refresh 并处理结果 (只由 in-flight task 调用).
    private func performRefresh(
        accountID: String,
        now: Date
    ) async -> TokenResolution {
        guard let cache = caches[accountID],
              let refreshToken = cache.state.refreshToken else {
            return .failure(.needsReauthorization(accountID: accountID))
        }
        let result = await client.perform(
            client.refreshRequest(refreshToken: refreshToken),
            session: nil
        )
        let applied = CredentialStateReducer.applyRefreshResult(
            state: cache.state,
            accountID: accountID,
            result: result,
            now: now
        )
        if applied.requiresNeedsReauthorizationPersist {
            // 统一持久化入口: 保存失败进 storageBlocked + 存储重试,
            // 不恢复 OAuth. revision 只在统一入口递增一次.
            persistNeedsReauthorization(for: accountID, now: now)
            return applied.resolution
        }
        caches[accountID]?.state = applied.state
        if let record = applied.recordToPersist {
            do {
                try store.saveRecord(record)
                if let current = caches[accountID],
                   let cleared = CredentialStateReducer.applyStorageSuccess(
                       state: current.state,
                       expectedRevision: current.state.revision
                   ) {
                    // 成功: 清 pending (若有) 并解除 blocked
                    caches[accountID]?.state = cleared
                } else {
                    caches[accountID]?.state.storageBlocked = false
                    caches[accountID]?.state.pendingRecord = nil
                    caches[accountID]?.state.pendingRevision = nil
                }
            } catch {
                // 保存失败: 保留 pending record, 进 storageBlocked, 存储重试
                let revision = caches[accountID]?.state.revision ?? 0
                if var current = caches[accountID] {
                    current.state = CredentialStateReducer.applyStorageFailure(
                        state: current.state,
                        record: record,
                        revision: revision
                    )
                    caches[accountID] = current
                }
                scheduleStorageRetry(for: accountID)
            }
        }
        return applied.resolution
    }
}
