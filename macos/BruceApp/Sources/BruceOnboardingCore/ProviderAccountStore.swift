import CryptoKit
import Foundation

// MARK: - ProviderAccountAuthorizationState

/// 账号授权状态. 与 CodexAuthorizationState 保持一致语义.
public enum ProviderAccountAuthorizationState: String, Codable, Sendable, Equatable {
    case needsReauthorization
    case connected
    case revoked
}

// MARK: - ProviderAccountIndex

/// 通用多账号索引 (Keychain item value).
/// 与 CodexAccountIndex 结构对齐, 适用于所有 provider.
/// 不保存 token, 只保存元数据与状态.
public struct ProviderAccountIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public let accountID: String
        /// Keychain per-account 键的 hash 部分: SHA-256(accountID) 前 16 位 hex.
        public let credentialKeyHash: String
        public var displayName: String
        public var authorizationState: ProviderAccountAuthorizationState

        public init(
            accountID: String,
            credentialKeyHash: String,
            displayName: String,
            authorizationState: ProviderAccountAuthorizationState
        ) {
            self.accountID = accountID
            self.credentialKeyHash = credentialKeyHash
            self.displayName = displayName
            self.authorizationState = authorizationState
        }
    }

    public let schemaVersion: Int
    public var accounts: [Entry]

    public init(
        schemaVersion: Int = ProviderAccountIndex.schemaVersion,
        accounts: [Entry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
    }

    public func entry(for accountID: String) -> Entry? {
        accounts.first { $0.accountID == accountID }
    }
}

// MARK: - ProviderAccountRecord

/// 通用单账号凭证记录 (Keychain item value).
/// provider 特定凭证以 JSON 字符串保存在 `credentialJSON` 中,
/// 格式与旧单条 Keychain 条目一致 (Kimi: {"access_token","refresh_token"},
/// DeepSeek: 纯 API key 字符串, 火山: 两条字符串分别保存, 等).
/// 简单凭证 (DeepSeek API key, 火山 AK/SK) 直接用 credentialJSON 存原始值;
/// 复杂凭证 (Kimi/Claude/Grok/Antigravity OAuth JSON) 存 JSON 字符串.
public struct ProviderAccountRecord: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let accountID: String
    public var displayName: String
    /// 凭证本体 (provider 特定格式, 不在此结构内解析).
    public var credentialJSON: String
    public var authorizationState: ProviderAccountAuthorizationState
    public var updatedAt: Date

    public init(
        schemaVersion: Int = ProviderAccountRecord.schemaVersion,
        accountID: String,
        displayName: String,
        credentialJSON: String,
        authorizationState: ProviderAccountAuthorizationState = .needsReauthorization,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.accountID = accountID
        self.displayName = displayName
        self.credentialJSON = credentialJSON
        self.authorizationState = authorizationState
        self.updatedAt = updatedAt
    }
}

// MARK: - ProviderAccountKeys

/// 通用多账号 Keychain 键命名.
/// index:  `<provider>:account-index`
/// record: `<provider>:account:<sha256(accountID)[:16]>`
public enum ProviderAccountKeys {
    /// index 键.
    public static func indexKey(for provider: SubscriptionProviderID) -> String {
        "\(provider.rawValue):account-index"
    }

    /// per-account record 键.
    public static func recordKey(
        for provider: SubscriptionProviderID, accountID: String
    ) -> String {
        "\(provider.rawValue):account:\(sha256Hex(accountID))"
    }

    /// SHA-256 前 16 位 hex.
    public static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 从旧单条 Keychain 键列表中识别 provider.
    /// 返回该 provider 的全部旧键 (供迁移读取).
    public static func legacyKeys(for provider: SubscriptionProviderID) -> [String] {
        switch provider {
        case .kimi:
            return [SubscriptionCredentialAccount.kimiAPIKey]
        case .deepseek:
            return [SubscriptionCredentialAccount.deepseekAPIKey]
        case .volcengine:
            return [
                SubscriptionCredentialAccount.volcengineAccessKey,
                SubscriptionCredentialAccount.volcengineSecretKey,
            ]
        case .zhipu:
            return [
                SubscriptionCredentialAccount.zhipuAPIKey,
                SubscriptionCredentialAccount.zhipuBaseURL,
            ]
        case .codex:
            // Codex 已有独立的多账号体系, 不走通用迁移.
            return []
        case .antigravity:
            return [SubscriptionCredentialAccount.antigravityOAuth]
        case .claude:
            return [SubscriptionCredentialAccount.claudeOAuth]
        case .grok:
            return [SubscriptionCredentialAccount.grokOAuth]
        case .opencodeGo:
            return [SubscriptionCredentialAccount.opencodeGoOAuth]
        }
    }
}

// MARK: - ProviderAccountIDGenerator

/// 各 provider 的 accountID 生成规则.
/// 在同一 provider 内唯一, 用于 index 去重和 Keychain 键命名.
public enum ProviderAccountIDGenerator {
    /// DeepSeek: API key 前 8 位.
    public static func deepseekAccountID(apiKey: String) -> String {
        String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
    }

    /// 火山引擎: AccessKey 前 8 位.
    public static func volcengineAccountID(accessKey: String) -> String {
        String(accessKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
    }

    /// 智谱: API key 前 8 位.
    public static func zhipuAccountID(apiKey: String) -> String {
        String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
    }

    /// Kimi: API key 前 8 位.
    public static func kimiAccountID(apiKey: String) -> String {
        String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8))
    }

    /// Claude: accessToken SHA-256 前 16 位.
    public static func claudeAccountID(accessToken: String) -> String {
        ProviderAccountKeys.sha256Hex(accessToken)
    }

    /// Grok: key SHA-256 前 16 位.
    public static func grokAccountID(key: String) -> String {
        ProviderAccountKeys.sha256Hex(key)
    }

    /// Antigravity: refresh_token SHA-256 前 16 位.
    public static func antigravityAccountID(refreshToken: String) -> String {
        ProviderAccountKeys.sha256Hex(refreshToken)
    }

    /// OpenCode GO: access_token SHA-256 前 16 位 (console OAuth 身份).
    public static func opencodeGoAccountID(accessToken: String) -> String {
        ProviderAccountKeys.sha256Hex(accessToken)
    }
}

// MARK: - ProviderAccountSummary

/// 非敏感账号摘要, 供设置页渲染账号列表. 不携带任何凭证.
public struct ProviderAccountSummary: Codable, Equatable, Sendable {
    public let accountID: String
    public let displayName: String
    public let authorizationState: ProviderAccountAuthorizationState

    public init(
        accountID: String,
        displayName: String,
        authorizationState: ProviderAccountAuthorizationState
    ) {
        self.accountID = accountID
        self.displayName = displayName
        self.authorizationState = authorizationState
    }
}

// MARK: - ProviderAccountStore

/// 通用多账号凭证存储. 按 provider 实例化, 管理 index + per-account record.
///
/// Codex 不使用本类 (已有独立的 CodexCredentialStore).
/// 其余 6 个 provider 共用本类, 凭证格式由调用方按 provider 约定组装.
public final class ProviderAccountStore: @unchecked Sendable {
    public let provider: SubscriptionProviderID
    private let credentialStore: CredentialStore

    public init(
        provider: SubscriptionProviderID,
        credentialStore: CredentialStore
    ) {
        self.provider = provider
        self.credentialStore = credentialStore
    }

    // MARK: - Index

    /// 加载账号索引; 不存在返回空索引.
    public func loadIndex() throws -> ProviderAccountIndex {
        guard let raw = try credentialStore.loadCredential(
            forAccount: ProviderAccountKeys.indexKey(for: provider)
        ), !raw.isEmpty else {
            return ProviderAccountIndex()
        }
        guard let data = raw.data(using: .utf8) else {
            return ProviderAccountIndex()
        }
        return (try? JSONDecoder().decode(ProviderAccountIndex.self, from: data))
            ?? ProviderAccountIndex()
    }

    /// 保存账号索引.
    public func saveIndex(_ index: ProviderAccountIndex) throws {
        let data = try JSONEncoder().encode(index)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try credentialStore.saveCredential(
            json,
            forAccount: ProviderAccountKeys.indexKey(for: provider)
        )
    }

    // MARK: - Record

    /// 加载单账号凭证记录; 不存在返回 nil.
    public func loadRecord(for accountID: String) throws -> ProviderAccountRecord? {
        let key = ProviderAccountKeys.recordKey(for: provider, accountID: accountID)
        guard let raw = try credentialStore.loadCredential(forAccount: key),
              !raw.isEmpty else {
            return nil
        }
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProviderAccountRecord.self, from: data)
    }

    /// 保存单账号凭证记录.
    public func saveRecord(_ record: ProviderAccountRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard let json = String(data: data, encoding: .utf8) else { return }
        let key = ProviderAccountKeys.recordKey(for: provider, accountID: record.accountID)
        try credentialStore.saveCredential(json, forAccount: key)
    }

    /// 删除单账号凭证记录.
    public func deleteRecord(for accountID: String) throws {
        let key = ProviderAccountKeys.recordKey(for: provider, accountID: accountID)
        try credentialStore.deleteCredential(forAccount: key)
    }

    // MARK: - 高层操作

    /// 添加账号: 写入 record, 更新 index. 重复 accountID 返回 false.
    public func addAccount(
        accountID: String,
        displayName: String,
        credentialJSON: String,
        now: Date = Date()
    ) throws -> Bool {
        var index = try loadIndex()
        guard index.entry(for: accountID) == nil else {
            return false
        }
        let record = ProviderAccountRecord(
            accountID: accountID,
            displayName: displayName,
            credentialJSON: credentialJSON,
            authorizationState: .needsReauthorization,
            updatedAt: now
        )
        try saveRecord(record)
        index.accounts.append(ProviderAccountIndex.Entry(
            accountID: accountID,
            credentialKeyHash: ProviderAccountKeys.sha256Hex(accountID),
            displayName: displayName,
            authorizationState: .needsReauthorization
        ))
        try saveIndex(index)
        return true
    }

    /// 移除账号: 删除 record, 从 index 移除条目.
    public func removeAccount(accountID: String) throws {
        try deleteRecord(for: accountID)
        var index = try loadIndex()
        index.accounts.removeAll { $0.accountID == accountID }
        try saveIndex(index)
    }

    /// 新增或更新账号凭证 (upsert).
    /// - 账号不存在: 新增 record + index 条目.
    /// - 账号已存在: 更新 credentialJSON / displayName, 不改变授权状态.
    /// 用于"更换凭证"场景 (重新粘贴 / 重新导入).
    public func upsertAccount(
        accountID: String,
        displayName: String,
        credentialJSON: String,
        now: Date = Date()
    ) throws {
        var index = try loadIndex()
        if let idx = index.accounts.firstIndex(where: { $0.accountID == accountID }) {
            // 已存在: 更新 record 与 index 元数据, 保留授权状态.
            if var record = try loadRecord(for: accountID) {
                record.credentialJSON = credentialJSON
                record.displayName = displayName
                record.updatedAt = now
                try saveRecord(record)
            } else {
                let record = ProviderAccountRecord(
                    accountID: accountID,
                    displayName: displayName,
                    credentialJSON: credentialJSON,
                    authorizationState: index.accounts[idx].authorizationState,
                    updatedAt: now
                )
                try saveRecord(record)
            }
            index.accounts[idx].displayName = displayName
            try saveIndex(index)
        } else {
            // 不存在: 走 addAccount (新增).
            _ = try addAccount(
                accountID: accountID,
                displayName: displayName,
                credentialJSON: credentialJSON,
                now: now
            )
        }
    }

    /// 更新账号状态.
    public func updateAuthorizationState(
        _ state: ProviderAccountAuthorizationState,
        for accountID: String,
        now: Date = Date()
    ) throws {
        var index = try loadIndex()
        guard let idx = index.accounts.firstIndex(where: { $0.accountID == accountID }) else {
            return
        }
        index.accounts[idx].authorizationState = state
        try saveIndex(index)

        if var record = try loadRecord(for: accountID) {
            record.authorizationState = state
            record.updatedAt = now
            try saveRecord(record)
        }
    }

    /// 是否至少有一个 connected 账号.
    public func hasConnectedAccount() throws -> Bool {
        let index = try loadIndex()
        return index.accounts.contains { $0.authorizationState == .connected }
    }

    /// 账号数量.
    public func accountCount() throws -> Int {
        try loadIndex().accounts.count
    }

    /// 全部账号的非敏感摘要 (供设置页渲染).
    public func summaries() throws -> [ProviderAccountSummary] {
        try summaries(from: loadIndex())
    }

    /// 从已加载的 index 构造摘要, 避免重复读 Keychain.
    public func summaries(from index: ProviderAccountIndex) -> [ProviderAccountSummary] {
        index.accounts.map { entry in
            ProviderAccountSummary(
                accountID: entry.accountID,
                displayName: entry.displayName,
                authorizationState: entry.authorizationState
            )
        }
    }

    // MARK: - 旧凭证迁移

    /// 检测旧单条 Keychain 凭证, 迁移为 account-index + record.
    /// 迁移只读取不删除旧键; 调用方在迁移成功后清理旧键.
    /// 已有 index 的 provider 跳过 (用户已手动添加新账号).
    /// 旧键不完整时跳过该 provider, 不创建不完整 index.
    /// 返回是否执行了迁移 (供调用方决定是否清理旧键).
    public func migrateLegacyAccountsIfNeeded(
        legacyKeys: [String]
    ) throws -> Bool {
        guard !legacyKeys.isEmpty else { return false }

        // 已有 index 则跳过 (可能已由其他路径迁移)
        let index = try loadIndex()
        if !index.accounts.isEmpty {
            return false
        }

        // 收集旧键值; 任一缺失则跳过该 provider
        var legacyValues: [String] = []
        for key in legacyKeys {
            guard let value = try credentialStore.loadCredential(forAccount: key),
                  !value.isEmpty else {
                return false
            }
            legacyValues.append(value)
        }

        // 按 provider 格式组装 accountID / displayName / credentialJSON
        let (accountID, displayName, credentialJSON): (String, String, String)
        switch provider {
        case .kimi:
            let key = legacyValues[0]
            accountID = ProviderAccountIDGenerator.kimiAccountID(apiKey: key)
            displayName = "Kimi · \(accountID)"
            credentialJSON = key
        case .deepseek:
            let key = legacyValues[0]
            accountID = ProviderAccountIDGenerator.deepseekAccountID(apiKey: key)
            displayName = "DeepSeek · \(accountID)"
            credentialJSON = key
        case .volcengine:
            let ak = legacyValues[0]
            let sk = legacyValues[1]
            accountID = ProviderAccountIDGenerator.volcengineAccountID(accessKey: ak)
            displayName = "火山引擎 · \(accountID)"
            let dict: [String: String] = ["accessKey": ak, "secretKey": sk]
            let data = (try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys]
            )) ?? Data()
            credentialJSON = String(data: data, encoding: .utf8) ?? "{}"
        case .zhipu:
            let apiKey = legacyValues[0]
            let baseURL = legacyValues[1]
            accountID = ProviderAccountIDGenerator.zhipuAccountID(apiKey: apiKey)
            displayName = "智谱 · \(accountID)"
            let dict: [String: String] = ["api_key": apiKey, "base_url": baseURL]
            let data = (try? JSONSerialization.data(
                withJSONObject: dict, options: [.sortedKeys]
            )) ?? Data()
            credentialJSON = String(data: data, encoding: .utf8) ?? "{}"
        case .antigravity:
            let token = legacyValues[0]
            let refresh = Self.jsonStringField(
                in: token, path: ["token", "refresh_token"]
            ) ?? token
            accountID = ProviderAccountIDGenerator.antigravityAccountID(refreshToken: refresh)
            displayName = "Antigravity · \(String(accountID.prefix(8)))"
            credentialJSON = token
        case .claude:
            let token = legacyValues[0]
            let access = Self.jsonStringField(
                in: token, path: ["claudeAiOauth", "accessToken"]
            ) ?? token
            accountID = ProviderAccountIDGenerator.claudeAccountID(accessToken: access)
            displayName = "Claude · \(String(accountID.prefix(8)))"
            credentialJSON = token
        case .grok:
            let token = legacyValues[0]
            let key = Self.grokKeyFromJSON(token) ?? token
            accountID = ProviderAccountIDGenerator.grokAccountID(key: key)
            displayName = "Grok · \(String(accountID.prefix(8)))"
            credentialJSON = token
        case .opencodeGo:
            let token = legacyValues[0]
            let workspace = Self.jsonStringField(
                in: token, path: ["workspaceId"]
            ) ?? token
            accountID = ProviderAccountIDGenerator.opencodeGoAccountID(accessToken: workspace)
            displayName = "OpenCode GO · \(String(accountID.prefix(8)))"
            credentialJSON = token
        case .codex:
            return false // Codex 已有独立的多账号体系
        }

        let added = try addAccount(
            accountID: accountID,
            displayName: displayName,
            credentialJSON: credentialJSON
        )
        if added {
            try updateAuthorizationState(.connected, for: accountID)
        }
        return true
    }

    /// 从 JSON 字符串按路径提取 String 字段 (含嵌套 dict); 失败返回 nil.
    private static func jsonStringField(in json: String, path: [String]) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              var current = object as? [String: Any] else {
            return nil
        }
        for (index, key) in path.enumerated() {
            if index == path.count - 1 {
                return current[key] as? String
            }
            guard let next = current[key] as? [String: Any] else { return nil }
            current = next
        }
        return nil
    }

    /// Grok auth.json: 任意 scope 条目中的 key 字段.
    private static func grokKeyFromJSON(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        for (_, value) in dict {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty else { continue }
            return key
        }
        return nil
    }
}
