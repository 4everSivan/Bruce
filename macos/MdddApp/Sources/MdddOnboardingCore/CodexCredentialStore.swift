import Foundation

// MARK: - CodexCredentialStoreError

public enum CodexCredentialStoreError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case indexMissing
    case migrationFailed(reason: String)
}

// MARK: - CodexDiscovery

/// 本机 Codex 账号发现 (CC Switch / CLI 认证文件), 只提取账号元数据,
/// 不导入任何 token. 发现的账号一律 `needsReauthorization`, 由用户在
/// mddd 内重新授权后成为运行时凭证链.
public enum CodexDiscovery {
    public struct Account: Equatable, Sendable {
        public let accountID: String
        public let email: String?
        public let authorizationState: CodexAuthorizationState
        public let credentialOrigin: CodexCredentialOrigin

        public init(
            accountID: String,
            email: String?,
            authorizationState: CodexAuthorizationState,
            credentialOrigin: CodexCredentialOrigin
        ) {
            self.accountID = accountID
            self.email = email
            self.authorizationState = authorizationState
            self.credentialOrigin = credentialOrigin
        }
    }

    /// 解析 CC Switch `codex_oauth_auth.json` 账号库: 只提取 accountID + email.
    /// 结构非法时抛错 (fail-closed), 不静默伪装为空结果.
    public static func fromCCSwitchAccountsJSON(
        _ json: String
    ) throws -> [Account] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let all = dict["accounts"] as? [String: Any] else {
            throw CodexCredentialStoreError.decodingFailed
        }
        return all.sorted(by: { $0.key < $1.key }).map { accountID, entry in
            let email = (entry as? [String: Any])?["email"] as? String ?? ""
            return Account(
                accountID: accountID,
                email: email.isEmpty ? nil : email,
                authorizationState: .needsReauthorization,
                credentialOrigin: .legacyCCSwitchDiscovery
            )
        }
    }

    /// 解析 Codex CLI `~/.codex/auth.json`: 只提取 tokens.account_id + email.
    /// 缺失 account_id 或结构非法时抛错 (fail-closed).
    public static func fromCLIAuthJSON(_ json: String) throws -> [Account] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let tokens = dict["tokens"] as? [String: Any] else {
            throw CodexCredentialStoreError.decodingFailed
        }
        let accountID = (tokens["account_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            throw CodexCredentialStoreError.decodingFailed
        }
        let email = (tokens["email"] as? String ?? dict["email"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [Account(
            accountID: accountID,
            email: email.isEmpty ? nil : email,
            authorizationState: .needsReauthorization,
            credentialOrigin: .legacyCCSwitchDiscovery
        )]
    }
}

// MARK: - CodexCredentialStore 账号发现扩展

public extension CodexCredentialStore {
    /// 把发现的账号以 metadata-only 记录写入 (needsReauthorization,
    /// legacyCCSwitchDiscovery). 已存在记录的账号保留原状, 不覆盖.
    func saveDiscoveredAccounts(
        _ accounts: [CodexDiscovery.Account],
        now: Date
    ) throws {
        for account in accounts {
            guard try loadRecord(for: account.accountID) == nil else { continue }
            try saveRecord(CodexAccountRecord(
                accountID: account.accountID,
                email: account.email,
                authorizationState: .needsReauthorization,
                credentialOrigin: .legacyCCSwitchDiscovery,
                updatedAt: now
            ))
        }
    }

    /// 从 CC Switch 与 CLI 认证文件做只读发现, 写 metadata-only v2 记录.
    /// 文件缺失时忽略对应来源; 读取失败抛错 (fail-closed), 不静默为空.
    func discoverAccountsFromFiles(
        ccSwitchURL: URL,
        cliAuthURL: URL,
        now: Date
    ) throws -> Int {
        var discovered: [CodexDiscovery.Account] = []
        if FileManager.default.fileExists(atPath: ccSwitchURL.path) {
            let json = try String(contentsOf: ccSwitchURL, encoding: .utf8)
            discovered.append(contentsOf: try CodexDiscovery
                .fromCCSwitchAccountsJSON(json))
        }
        if FileManager.default.fileExists(atPath: cliAuthURL.path) {
            let json = try String(contentsOf: cliAuthURL, encoding: .utf8)
            discovered.append(contentsOf: try CodexDiscovery
                .fromCLIAuthJSON(json))
        }
        try saveDiscoveredAccounts(discovered, now: now)
        return discovered.count
    }
}

private extension String {
    /// 空字符串按 nil 处理, 用于 Keychain 旧项的容错读取.
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - CodexCredentialStore

/// Codex 凭证的 Keychain 类型化封装: 账号索引 + 分账号记录分离存储.
///
/// 存储布局:
/// - `codex:account-index:v2`: 账号索引 (元数据, 无 token).
/// - `codex:account:v2:<sha256(accountID)>`: 单账号凭证记录.
///
/// 单账号刷新只更新该账号项, 不会覆盖其他账号. 旧 `codex:accounts`
/// 整体 JSON 只在迁移时读取, 迁移成功校验后才删除.
public final class CodexCredentialStore: Sendable {
    private let store: any CredentialStore

    public init(store: any CredentialStore) {
        self.store = store
    }

    // MARK: 编解码

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw CodexCredentialStoreError.encodingFailed
        }
        return json
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String?) throws -> T? {
        guard let json, !json.isEmpty,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: 索引

    /// 读取 v2 账号索引. 缺失返回空索引.
    public func loadIndex() throws -> CodexAccountIndex {
        try decode(CodexAccountIndex.self, from: try store.loadCredential(
            forAccount: CodexCredentialKeys.accountIndexV2
        )) ?? CodexAccountIndex()
    }

    public func saveIndex(_ index: CodexAccountIndex) throws {
        try store.saveCredential(try encode(index), forAccount: CodexCredentialKeys.accountIndexV2)
    }

    // MARK: 单账号记录

    /// 读取单账号记录. 索引缺失该账号返回 nil.
    public func loadRecord(for accountID: String) throws -> CodexAccountRecord? {
        let index = try loadIndex()
        guard index.entry(for: accountID) != nil else { return nil }
        return try decode(
            CodexAccountRecord.self,
            from: try store.loadCredential(
                forAccount: CodexCredentialKeys.accountKey(for: accountID)
            )
        )
    }

    /// 保存单账号记录并同步索引. 只影响该账号, 不覆盖其他账号.
    /// authorizationState 由调用方决定; fail-closed 语义由
    /// `resolvedAuthorizationState` 在读取侧兜底.
    public func saveRecord(_ record: CodexAccountRecord) throws {
        var index = try loadIndex()
        let hash = CodexCredentialKeys.sha256Hex(record.accountID)
        index.accounts.removeAll { $0.accountID == record.accountID }
        index.accounts.append(CodexAccountIndex.Entry(
            credentialKeyHash: hash,
            accountID: record.accountID,
            email: record.email,
            authorizationState: record.authorizationState,
            credentialOrigin: record.credentialOrigin
        ))
        index.accounts.sort { $0.accountID < $1.accountID }
        try store.saveCredential(
            try encode(record),
            forAccount: CodexCredentialKeys.accountKey(for: record.accountID)
        )
        try saveIndex(index)
    }

    /// 删除单账号记录并更新索引.
    public func deleteRecord(for accountID: String) throws {
        var index = try loadIndex()
        index.accounts.removeAll { $0.accountID == accountID }
        if index.activeAccountID == accountID {
            index.activeAccountID = nil
        }
        try store.deleteCredential(
            forAccount: CodexCredentialKeys.accountKey(for: accountID)
        )
        try saveIndex(index)
    }

    /// 更新单账号授权状态 (保留凭证字段).
    public func updateAuthorizationState(
        _ state: CodexAuthorizationState,
        for accountID: String,
        now: Date
    ) throws {
        guard var record = try loadRecord(for: accountID) else { return }
        record.authorizationState = state
        record.updatedAt = now
        try saveRecord(record)
    }

    // MARK: 旧库迁移

    /// 旧 `codex:accounts` 整体 JSON 的只读解析: 只提取 account ID 和 email,
    /// 不返回任何 token.
    public struct LegacyAccountsSnapshot: Equatable, Sendable {
        public struct Account: Equatable, Sendable {
            public let accountID: String
            public let email: String?
        }
        public let accounts: [Account]
        public let activeAccountID: String?
    }

    /// 解析旧整体账号库 JSON, 只保留账号元数据. 解析失败返回 nil.
    public func parseLegacyAccounts(_ json: String) -> LegacyAccountsSnapshot? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        var accounts: [LegacyAccountsSnapshot.Account] = []
        if let all = dict["accounts"] as? [String: Any] {
            for (accountID, entry) in all.sorted(by: { $0.key < $1.key }) {
                let email = (entry as? [String: Any])?["email"] as? String ?? ""
                accounts.append(LegacyAccountsSnapshot.Account(
                    accountID: accountID,
                    email: email.isEmpty ? nil : email
                ))
            }
        }
        // 旧布局 active 账号存在独立的 codex:active-account Keychain 项
        return LegacyAccountsSnapshot(
            accounts: accounts,
            activeAccountID: (try? store.loadCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            ))?.nilIfEmpty
        )
    }

    /// 幂等迁移: 旧整体库 -> metadata-only v2 记录, 先写后校验再删旧键.
    ///
    /// - 为每个旧账号写入不含 token 的 v2 记录 (needsReauthorization,
    ///   legacyCCSwitchDiscovery).
    /// - 写入索引与迁移完成标记.
    /// - 重读校验 v2 索引与账号数量.
    /// - 校验成功后删除旧 `codex:accounts` 与旧 active 账号.
    ///
    /// 任一步失败保留旧键 (迁移可重试); 已迁移 (无旧键) 时幂等返回.
    /// 返回本次是否实际执行了迁移 (true 表示旧库存在且被转换).
    public func migrateLegacyAccounts(now: Date) throws -> Bool {
        guard let legacyJSON = try store.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        ), !legacyJSON.isEmpty,
              let snapshot = parseLegacyAccounts(legacyJSON) else {
            return false
        }
        guard !snapshot.accounts.isEmpty else {
            // 空旧库: 直接删除旧键并打迁移标记
            try store.deleteCredential(
                forAccount: CodexCredentialKeys.legacyAccounts
            )
            try store.deleteCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            )
            var index = try loadIndex()
            index.migrationCompletedAt = now
            try saveIndex(index)
            return true
        }

        var index = try loadIndex()
        for account in snapshot.accounts {
            guard index.entry(for: account.accountID) == nil else { continue }
            let record = CodexAccountRecord(
                accountID: account.accountID,
                email: account.email,
                authorizationState: .needsReauthorization,
                credentialOrigin: .legacyCCSwitchDiscovery,
                updatedAt: now
            )
            try store.saveCredential(
                try encode(record),
                forAccount: CodexCredentialKeys.accountKey(for: account.accountID)
            )
            index.accounts.append(CodexAccountIndex.Entry(
                credentialKeyHash: CodexCredentialKeys.sha256Hex(account.accountID),
                accountID: account.accountID,
                email: account.email,
                authorizationState: .needsReauthorization,
                credentialOrigin: .legacyCCSwitchDiscovery
            ))
        }
        index.accounts.sort { $0.accountID < $1.accountID }
        if let active = snapshot.activeAccountID,
           index.accounts.contains(where: { $0.accountID == active }) {
            index.activeAccountID = active
        }
        index.migrationCompletedAt = now
        try saveIndex(index)

        // 重读校验
        let verified = try loadIndex()
        guard verified.accounts.count == index.accounts.count,
              verified.migrationCompletedAt != nil else {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "v2 索引校验失败"
            )
        }

        // 校验成功后删除旧键
        try store.deleteCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        try store.deleteCredential(
            forAccount: CodexCredentialKeys.legacyActiveAccount
        )
        return true
    }
}
