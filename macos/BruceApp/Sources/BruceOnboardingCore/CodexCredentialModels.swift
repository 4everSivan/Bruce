import CryptoKit
import Foundation

// MARK: - CodexAuthorizationState

/// 单账号授权状态. 只有 `connected` 允许把 access token 交给额度查询.
public enum CodexAuthorizationState: String, Codable, Sendable, Equatable {
    case needsReauthorization
    case connected
    case revoked
}

// MARK: - CodexCredentialOrigin

/// 账号凭证来源. `Bruce` 表示 Bruce 内设备码登录产生的独立凭证链;
/// `legacyCCSwitchDiscovery` 表示旧迁移只发现账号元数据, 不含 token.
public enum CodexCredentialOrigin: String, Codable, Sendable, Equatable {
    case Bruce
    case legacyCCSwitchDiscovery
}

// MARK: - CodexAccountRecord

/// 单账号凭证记录 (Keychain item value).
/// `connected` 必须同时具备非空 access token、refresh token 和可解析的过期时间;
/// 读取到不完整记录时按 `needsReauthorization` 处理 (fail-closed).
public struct CodexAccountRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let accountID: String
    public var email: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var accessTokenExpiresAt: Date?
    public var authorizationState: CodexAuthorizationState
    public var credentialOrigin: CodexCredentialOrigin
    public var updatedAt: Date

    public init(
        schemaVersion: Int = CodexAccountRecord.schemaVersion,
        accountID: String,
        email: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accessTokenExpiresAt: Date? = nil,
        authorizationState: CodexAuthorizationState = .needsReauthorization,
        credentialOrigin: CodexCredentialOrigin,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.accountID = accountID
        self.email = email
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accessTokenExpiresAt = accessTokenExpiresAt
        self.authorizationState = authorizationState
        self.credentialOrigin = credentialOrigin
        self.updatedAt = updatedAt
    }

    /// fail-closed 读取: 缺少 access token、refresh token 或有效过期时间
    /// 一律视为需要重新授权, 不使用残缺 token.
    public var resolvedAuthorizationState: CodexAuthorizationState {
        guard authorizationState == .connected,
              let accessToken, !accessToken.isEmpty,
              let refreshToken, !refreshToken.isEmpty,
              let accessTokenExpiresAt,
              accessTokenExpiresAt > Date(timeIntervalSince1970: 0) else {
            return .needsReauthorization
        }
        return .connected
    }

    /// 脱敏展示值: 邮箱只保留 @ 前缀, 无邮箱时回落 account ID 前 8 位.
    public var displayName: String {
        if let email, !email.isEmpty {
            return "Codex · " + (email.split(separator: "@").first.map(String.init) ?? "")
        }
        return "Codex · " + String(accountID.prefix(8))
    }
}

// MARK: - CodexAccountIndex

/// 账号索引 (Keychain item value). 不保存 token, 只保存元数据与状态.
public struct CodexAccountIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public struct Entry: Codable, Equatable, Sendable {
        public let credentialKeyHash: String
        public let accountID: String
        public var email: String?
        public var authorizationState: CodexAuthorizationState
        public var credentialOrigin: CodexCredentialOrigin

        public init(
            credentialKeyHash: String,
            accountID: String,
            email: String? = nil,
            authorizationState: CodexAuthorizationState,
            credentialOrigin: CodexCredentialOrigin
        ) {
            self.credentialKeyHash = credentialKeyHash
            self.accountID = accountID
            self.email = email
            self.authorizationState = authorizationState
            self.credentialOrigin = credentialOrigin
        }
    }

    public let schemaVersion: Int
    public var accounts: [Entry]
    public var activeAccountID: String?
    public var migrationCompletedAt: Date?

    public init(
        schemaVersion: Int = CodexAccountIndex.schemaVersion,
        accounts: [Entry] = [],
        activeAccountID: String? = nil,
        migrationCompletedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.activeAccountID = activeAccountID
        self.migrationCompletedAt = migrationCompletedAt
    }

    public func entry(for accountID: String) -> Entry? {
        accounts.first { $0.accountID == accountID }
    }
}

// MARK: - CodexAccountStatus

/// 非敏感账号状态快照, 供 UI/AppModel 订阅. 不携带任何 token 或完整邮箱.
public struct CodexAccountStatus: Equatable, Sendable {
    public let accountID: String
    public let displayName: String
    public let authorizationState: CodexAuthorizationState
    public let credentialOrigin: CodexCredentialOrigin
    /// Keychain 写失败重试中 (内存 token 仍有效, UI 提示存储异常).
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

// MARK: - 键常量

/// Codex v2 Keychain 键. 旧键只供迁移读取, 不再供运行时额度查询.
public enum CodexCredentialKeys {
    /// v2 账号索引项.
    public static let accountIndexV2 = "codex:account-index:v2"
    /// v2 单账号项前缀; 完整键为 `codex:account:v2:<sha256(accountID)>`.
    public static let accountV2Prefix = "codex:account:v2:"
    /// 旧整体账号库 (迁移读取, 成功后删除).
    public static let legacyAccounts = "codex:accounts"
    /// 旧 active 账号 (迁移读取, 成功后删除).
    public static let legacyActiveAccount = "codex:active-account"

    /// 单账号 v2 Keychain 键: 只用 account ID 的完整 SHA-256, 不在键名暴露原始 ID.
    public static func accountKey(for accountID: String) -> String {
        accountV2Prefix + sha256Hex(accountID)
    }

    /// 完整 SHA-256 hex.
    public static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
