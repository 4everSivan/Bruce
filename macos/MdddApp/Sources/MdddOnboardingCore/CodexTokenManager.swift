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

// MARK: - Protocols

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

// MARK: - CodexTokenManager (façade)

/// Codex access token 的公共 façade: 保持调用方 API 稳定.
///
/// 实现拆到:
/// - `CodexTokenResolver`: 缓存、过期、in-flight 去重、存储/元数据重试
/// - `CredentialStateReducer`: 纯状态变迁 (成功 / 需重新授权 / 存储阻断 / 退避)
///
/// 职责不变:
/// - 距过期 <= 60 秒时刷新, 否则复用.
/// - 同账号并发刷新合并为一次 in-flight 请求.
/// - refresh token 只存在于内存与 Keychain, 永不外传.
/// - 旋转后 Keychain 写失败进入 `storageBlocked`, 内存保留新 token,
///   按退避序列重试落盘, 不重放 OAuth 请求.
/// - `storageBlocked` 优先阻止所有 refresh, 包括 401 强制刷新.
/// - `invalid_grant` 清除 token 并持久化 metadata-only 重新授权状态.
public actor CodexTokenManager: CodexChallengeHandling {
    public static let refreshWindow: TimeInterval = CodexTokenResolver.refreshWindow

    private let resolver: CodexTokenResolver

    public init(
        store: CodexCredentialStore,
        client: any CodexOAuthClientProtocol,
        clock: @escaping @Sendable () -> Date = { Date() },
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.resolver = CodexTokenResolver(
            store: store,
            client: client,
            clock: clock,
            sleeper: sleeper
        )
    }

    /// 测试 / 高级注入: 直接挂载已构造的 resolver.
    public init(resolver: CodexTokenResolver) {
        self.resolver = resolver
    }

    // MARK: 状态观察

    public func statusSnapshot() async -> CodexTokenManagerState {
        await resolver.statusSnapshot()
    }

    // MARK: 登录接入

    public func storeLoginResult(
        accountID: String,
        email: String?,
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        expiresAt: Date?
    ) async throws {
        try await resolver.storeLoginResult(
            accountID: accountID,
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            expiresAt: expiresAt
        )
    }

    // MARK: token 决议

    public func validAccessToken(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        await resolver.validAccessToken(for: accountID, now: now)
    }

    public func refreshAfterAccessRejected(
        for accountID: String,
        now: Date? = nil
    ) async -> TokenResolution {
        await resolver.refreshAfterAccessRejected(for: accountID, now: now)
    }

    public func markNeedsReauthorization(
        for accountID: String,
        now: Date? = nil
    ) async {
        await resolver.markNeedsReauthorization(for: accountID, now: now)
    }

    // MARK: 断开

    public func disconnect(accountID: String) async throws {
        try await resolver.disconnect(accountID: accountID)
    }
}
