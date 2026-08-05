import Foundation

// MARK: - CredentialAccountState

/// 单账号凭证纯状态 (无 Task / 无 I/O). 由 `CredentialStateReducer` 归一.
/// 与 Keychain record 字段对齐, 额外携带 storageBlocked / 退避 / revision / pending.
public struct CredentialAccountState: Equatable, Sendable {
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var accessTokenExpiresAt: Date?
    public var authorizationState: CodexAuthorizationState
    public var storageBlocked: Bool
    public var refreshNotBefore: Date?
    public var updatedAt: Date?
    public var revision: Int
    public var email: String?
    public var credentialOrigin: CodexCredentialOrigin
    /// 待持久化 record; 仅当 `pendingRevision == revision` 时可落盘.
    public var pendingRecord: CodexAccountRecord?
    public var pendingRevision: Int?

    public init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        authorizationState: CodexAuthorizationState = .needsReauthorization,
        storageBlocked: Bool = false,
        refreshNotBefore: Date? = nil,
        updatedAt: Date? = nil,
        revision: Int = 0,
        email: String? = nil,
        credentialOrigin: CodexCredentialOrigin = .mddd,
        pendingRecord: CodexAccountRecord? = nil,
        pendingRevision: Int? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.authorizationState = authorizationState
        self.storageBlocked = storageBlocked
        self.refreshNotBefore = refreshNotBefore
        self.updatedAt = updatedAt
        self.revision = revision
        self.email = email
        self.credentialOrigin = credentialOrigin
        self.pendingRecord = pendingRecord
        self.pendingRevision = pendingRevision
    }

    /// 从 Keychain record 初始化内存缓存 (fail-closed authorization).
    public static func seeded(from record: CodexAccountRecord) -> CredentialAccountState {
        CredentialAccountState(
            accessToken: record.accessToken,
            refreshToken: record.refreshToken,
            idToken: record.idToken,
            accessTokenExpiresAt: record.accessTokenExpiresAt,
            authorizationState: record.resolvedAuthorizationState,
            storageBlocked: false,
            refreshNotBefore: nil,
            updatedAt: record.updatedAt,
            revision: 0,
            email: record.email,
            credentialOrigin: record.credentialOrigin,
            pendingRecord: nil,
            pendingRevision: nil
        )
    }

    /// 仅元数据 (冷缓存 mark reauth 读取成功后).
    public static func metadataOnly(from record: CodexAccountRecord) -> CredentialAccountState {
        CredentialAccountState(
            accessToken: nil,
            refreshToken: nil,
            idToken: nil,
            accessTokenExpiresAt: nil,
            authorizationState: record.resolvedAuthorizationState,
            storageBlocked: false,
            refreshNotBefore: nil,
            updatedAt: record.updatedAt,
            revision: 0,
            email: record.email,
            credentialOrigin: record.credentialOrigin,
            pendingRecord: nil,
            pendingRevision: nil
        )
    }
}

// MARK: - CredentialResolveGate

/// 缓存层决议: 直接返回 TokenResolution, 或需要网络 refresh.
public enum CredentialResolveGate: Equatable, Sendable {
    case resolved(TokenResolution)
    case needsNetworkRefresh(refreshToken: String)
}

// MARK: - CredentialRefreshApplyResult

/// 应用 OAuth 刷新结果后的纯输出.
public struct CredentialRefreshApplyResult: Equatable, Sendable {
    public var state: CredentialAccountState
    public var resolution: TokenResolution
    /// 非 nil 时 resolver 应尝试 `saveRecord`; 失败再走 storageBlocked.
    public var recordToPersist: CodexAccountRecord?
    /// `invalid_grant` 走统一 needsReauthorization 持久化入口 (不在此直接清 token 两次).
    public var requiresNeedsReauthorizationPersist: Bool

    public init(
        state: CredentialAccountState,
        resolution: TokenResolution,
        recordToPersist: CodexAccountRecord? = nil,
        requiresNeedsReauthorizationPersist: Bool = false
    ) {
        self.state = state
        self.resolution = resolution
        self.recordToPersist = recordToPersist
        self.requiresNeedsReauthorizationPersist = requiresNeedsReauthorizationPersist
    }
}

// MARK: - CredentialLoginApplyResult

/// 登录成功后的纯状态与待写 record.
public struct CredentialLoginApplyResult: Equatable, Sendable {
    public var state: CredentialAccountState
    public var record: CodexAccountRecord

    public init(state: CredentialAccountState, record: CodexAccountRecord) {
        self.state = state
        self.record = record
    }
}

// MARK: - CredentialNeedsReauthApplyResult

/// needsReauthorization 统一入口的纯输出.
public struct CredentialNeedsReauthApplyResult: Equatable, Sendable {
    public var state: CredentialAccountState
    public var record: CodexAccountRecord

    public init(state: CredentialAccountState, record: CodexAccountRecord) {
        self.state = state
        self.record = record
    }
}

// MARK: - CredentialStateReducer

/// 凭证状态纯函数归一层 (S5c): 成功 / 需重新授权 / 存储阻断 / 退避归一为枚举,
/// 禁止调用方做字符串散落比较. 无 I/O, 无 Task, 无时钟副作用.
public enum CredentialStateReducer: Sendable {
    public static let refreshWindow: TimeInterval = 60

    // MARK: Resolve gate

    /// 在已有缓存上决定是否可直接返回, 还是需要网络刷新.
    /// 不处理冷缓存加载 (resolver 先 seed); 不处理 in-flight 合并.
    public static func resolveGate(
        state: CredentialAccountState,
        accountID: String,
        now: Date,
        force: Bool,
        refreshWindow: TimeInterval = refreshWindow
    ) -> CredentialResolveGate {
        // 需要重新授权: 不尝试刷新 (包括 401 强制刷新)
        if state.authorizationState == .needsReauthorization {
            return .resolved(.failure(.needsReauthorization(accountID: accountID)))
        }
        // storageBlocked 优先阻止所有 refresh, 包括 401 强制刷新:
        // 内存 token 未过期 (expiresAt > now, 即使只剩 1 秒) 时直接返回;
        // 已过期时返回 .storageBlocked (不再复用 60 秒预刷新窗口)
        if state.storageBlocked {
            if let accessToken = state.accessToken,
               let expiresAt = state.accessTokenExpiresAt,
               expiresAt > now {
                return .resolved(.success(accessToken: accessToken, expiresAt: expiresAt))
            }
            return .resolved(.failure(.storageBlocked(accountID: accountID)))
        }
        // refresh not-before 退避: 暂时失败后不盲目重放 (force 也受退避约束...
        // 但 force 时原逻辑仍检查 notBefore 仅在 !force 分支)
        if !force,
           let notBefore = state.refreshNotBefore,
           now < notBefore {
            if let accessToken = state.accessToken,
               let expiresAt = state.accessTokenExpiresAt,
               expiresAt.timeIntervalSince(now) > 0 {
                return .resolved(.success(accessToken: accessToken, expiresAt: expiresAt))
            }
            return .resolved(.failure(
                .refreshFailed(accountID: accountID, reason: .deferred)
            ))
        }
        // 距过期仍在刷新窗口外: 直接复用, 不刷新
        if !force,
           let expiresAt = state.accessTokenExpiresAt,
           expiresAt.timeIntervalSince(now) > refreshWindow,
           let accessToken = state.accessToken {
            return .resolved(.success(accessToken: accessToken, expiresAt: expiresAt))
        }
        guard let refreshToken = state.refreshToken else {
            return .resolved(.failure(.needsReauthorization(accountID: accountID)))
        }
        return .needsNetworkRefresh(refreshToken: refreshToken)
    }

    /// `validAccessToken` 热路径: connected 且距过期 > 窗口时直接复用.
    public static func hotPathReuse(
        state: CredentialAccountState,
        now: Date,
        refreshWindow: TimeInterval = refreshWindow
    ) -> (accessToken: String, expiresAt: Date)? {
        guard state.authorizationState == .connected,
              let expiresAt = state.accessTokenExpiresAt,
              expiresAt.timeIntervalSince(now) > refreshWindow,
              let accessToken = state.accessToken else {
            return nil
        }
        return (accessToken, expiresAt)
    }

    // MARK: Login

    /// 登录成功: 递增 revision, 清 pending / blocked, 写入完整 connected 状态.
    public static func applyLogin(
        previous: CredentialAccountState?,
        accountID: String,
        email: String?,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expiresAt: Date?,
        now: Date
    ) -> CredentialLoginApplyResult {
        var state = previous ?? CredentialAccountState()
        state.revision += 1
        state.accessToken = accessToken
        state.refreshToken = refreshToken
        state.idToken = idToken
        state.accessTokenExpiresAt = expiresAt
        state.authorizationState = .connected
        state.storageBlocked = false
        state.refreshNotBefore = nil
        state.updatedAt = now
        state.email = email
        state.credentialOrigin = .mddd
        state.pendingRecord = nil
        state.pendingRevision = nil
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
        return CredentialLoginApplyResult(state: state, record: record)
    }

    // MARK: Needs reauthorization

    /// 三个授权失效入口的唯一状态归一: 清空 token, 递增 revision, 置 pending.
    public static func applyNeedsReauthorization(
        state: CredentialAccountState,
        accountID: String,
        now: Date
    ) -> CredentialNeedsReauthApplyResult {
        var next = state
        next.authorizationState = .needsReauthorization
        next.accessToken = nil
        next.refreshToken = nil
        next.idToken = nil
        next.accessTokenExpiresAt = nil
        next.refreshNotBefore = nil
        next.updatedAt = now
        next.revision += 1
        let record = CodexAccountRecord(
            accountID: accountID,
            email: next.email,
            accessToken: nil,
            refreshToken: nil,
            idToken: nil,
            accessTokenExpiresAt: nil,
            authorizationState: .needsReauthorization,
            credentialOrigin: next.credentialOrigin,
            updatedAt: now
        )
        next.pendingRecord = record
        next.pendingRevision = next.revision
        return CredentialNeedsReauthApplyResult(state: next, record: record)
    }

    // MARK: OAuth refresh result

    /// 将 OAuth 客户端结果归一为状态 + 决议 + 可选持久化.
    public static func applyRefreshResult(
        state: CredentialAccountState,
        accountID: String,
        result: Result<CodexTokenResponse, CodexOAuthClientError>,
        now: Date
    ) -> CredentialRefreshApplyResult {
        switch result {
        case .failure(let error):
            return applyRefreshFailure(
                state: state, accountID: accountID, error: error, now: now
            )
        case .success(let token):
            return applyRefreshSuccess(
                state: state, accountID: accountID, token: token, now: now
            )
        }
    }

    private static func applyRefreshFailure(
        state: CredentialAccountState,
        accountID: String,
        error: CodexOAuthClientError,
        now: Date
    ) -> CredentialRefreshApplyResult {
        var next = state
        switch error {
        case .invalidGrant:
            // 统一 needsReauth 入口由 resolver 再调 applyNeedsReauthorization,
            // 避免一次 invalid_grant 产生两次 revision 递增.
            return CredentialRefreshApplyResult(
                state: state,
                resolution: .failure(.needsReauthorization(accountID: accountID)),
                requiresNeedsReauthorizationPersist: true
            )
        case .rateLimit(let retryAfter):
            next.refreshNotBefore = now.addingTimeInterval(retryAfter ?? 300)
            return CredentialRefreshApplyResult(
                state: next,
                resolution: .failure(
                    .refreshFailed(accountID: accountID, reason: .rateLimited)
                )
            )
        case .serverError:
            next.refreshNotBefore = now.addingTimeInterval(300)
            return CredentialRefreshApplyResult(
                state: next,
                resolution: .failure(
                    .refreshFailed(accountID: accountID, reason: .serviceUnavailable)
                )
            )
        case .networkUnreachable, .httpStatus:
            next.refreshNotBefore = now.addingTimeInterval(300)
            return CredentialRefreshApplyResult(
                state: next,
                resolution: .failure(
                    .refreshFailed(accountID: accountID, reason: .networkError)
                )
            )
        case .invalidResponse:
            return CredentialRefreshApplyResult(
                state: state,
                resolution: .failure(
                    .refreshFailed(accountID: accountID, reason: .invalidResponse)
                )
            )
        case .cancelled:
            return CredentialRefreshApplyResult(
                state: state,
                resolution: .failure(
                    .refreshFailed(accountID: accountID, reason: .cancelled)
                )
            )
        }
    }

    private static func applyRefreshSuccess(
        state: CredentialAccountState,
        accountID: String,
        token: CodexTokenResponse,
        now: Date
    ) -> CredentialRefreshApplyResult {
        let expiresAt = CodexTokenExpiry.expiresAt(
            from: token,
            jwtExp: CodexTokenExpiry.jwtExp(of: token.idToken)
        )
        let newRefreshToken = token.refreshToken ?? state.refreshToken
        var next = state
        next.accessToken = token.accessToken
        next.refreshToken = newRefreshToken
        next.idToken = token.idToken ?? state.idToken
        next.accessTokenExpiresAt = expiresAt
        next.authorizationState = .connected
        next.refreshNotBefore = nil
        next.updatedAt = now
        let record = CodexAccountRecord(
            accountID: accountID,
            email: next.email,
            accessToken: token.accessToken,
            refreshToken: newRefreshToken,
            idToken: next.idToken,
            accessTokenExpiresAt: expiresAt,
            authorizationState: .connected,
            credentialOrigin: next.credentialOrigin,
            updatedAt: now
        )
        return CredentialRefreshApplyResult(
            state: next,
            resolution: .success(accessToken: token.accessToken, expiresAt: expiresAt),
            recordToPersist: record
        )
    }

    // MARK: Storage outcomes

    /// 持久化成功且 revision 仍是最新: 清 pending, 解除 storageBlocked.
    /// revision 已前进时保持状态不动 (防旧重试覆盖).
    public static func applyStorageSuccess(
        state: CredentialAccountState,
        expectedRevision: Int
    ) -> CredentialAccountState? {
        guard state.revision == expectedRevision else { return nil }
        var next = state
        next.pendingRecord = nil
        next.pendingRevision = nil
        next.storageBlocked = false
        return next
    }

    /// 持久化失败: 置 storageBlocked 并保留 pending.
    public static func applyStorageFailure(
        state: CredentialAccountState,
        record: CodexAccountRecord,
        revision: Int
    ) -> CredentialAccountState {
        var next = state
        next.storageBlocked = true
        next.pendingRecord = record
        next.pendingRevision = revision
        return next
    }

    /// 存储重试前校验: pending 与 revision 是否仍匹配.
    public static func pendingRecordIfCurrent(
        state: CredentialAccountState
    ) -> CodexAccountRecord? {
        guard let pending = state.pendingRecord,
              let pendingRevision = state.pendingRevision,
              state.revision == pendingRevision else {
            return nil
        }
        return pending
    }
}
