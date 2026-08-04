import Foundation

// MARK: - CodexMigrationResult

/// 旧凭证迁移结果. 替换有歧义的 Bool, 区分无旧数据、损坏 JSON、迁移成功、
/// 清理待重试和真实失败.
public enum CodexMigrationResult: Equatable, Sendable {
    /// 无旧键或已迁移过 (幂等 no-op).
    case noLegacyData
    /// 旧 JSON 损坏无法解析 (关闭 Codex quota gate).
    case corruptedJSON
    /// 旧数据结构不受支持 (空对象、缺 accounts、accounts 非对象等);
    /// 不得按空账号迁移或删除, 保留旧 key (关闭 Codex quota gate).
    case incompatibleSchema
    /// 迁移成功, v2 记录已写入并校验, 旧键已删除.
    case migrated(accountCount: Int)
    /// v2 记录已写入并校验, 但旧键删除失败 (下次启动重试清理).
    case cleanupPending
    /// 迁移过程中写入或校验失败 (旧键保留, 可重试).
    case failed
}

// MARK: - CodexCredentialStoreError

public enum CodexCredentialStoreError: Error, Equatable {
    case encodingFailed
    case decodingFailed
    case indexMissing
    /// 旧整体库 JSON 无法解析 (损坏).
    case corruptedJSON
    /// 旧整体库结构不受支持 (root 非对象、缺 accounts、accounts 非对象等).
    case incompatibleSchema
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

    // MARK: 配置判定

    /// 是否存在真实完整的凭证记录 (任务 9): 任一账号的
    /// `resolvedAuthorizationState == .connected` 才算已配置.
    /// 只发现账号元数据 (metadata-only) 或索引标 connected 但 record
    /// 残缺 (token 被清空) 均不算; fail-closed, 不做索引状态代判.
    public func hasConfiguredCredentials() throws -> Bool {
        for entry in try loadIndex().accounts {
            if let record = try loadRecord(for: entry.accountID),
               record.resolvedAuthorizationState == .connected {
                return true
            }
        }
        return false
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

    /// 解析旧整体账号库 JSON, 只保留账号元数据 (不返回任何 token).
    ///
    /// 严格规则 (任务 1):
    /// - root 必须是 JSON object, 否则抛 `.corruptedJSON`.
    /// - root 必须显式包含 `accounts`, 且其值为 object, 否则抛
    ///   `.incompatibleSchema` (未知结构不得按空账号迁移或删除).
    /// - 账号 key 必须是非空字符串.
    /// - 账号 entry 必须可解析为 object (忽略未知字段), 否则抛
    ///   `.incompatibleSchema`.
    /// - 只允许提取 email; 其余字段 (token 等) 一概不读取.
    /// - 旧 active key 读取失败抛 `.migrationFailed` (不降级为无数据).
    public func parseLegacyAccounts(_ json: String) throws -> LegacyAccountsSnapshot {
        guard let data = json.data(using: .utf8) else {
            throw CodexCredentialStoreError.corruptedJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexCredentialStoreError.corruptedJSON
        }
        guard let dict = object as? [String: Any] else {
            throw CodexCredentialStoreError.corruptedJSON
        }
        guard let all = dict["accounts"] else {
            throw CodexCredentialStoreError.incompatibleSchema
        }
        guard let accountEntries = all as? [String: Any] else {
            throw CodexCredentialStoreError.incompatibleSchema
        }
        var accounts: [LegacyAccountsSnapshot.Account] = []
        for (accountID, entry) in accountEntries.sorted(by: { $0.key < $1.key }) {
            let trimmed = accountID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty,
                  let entryObject = entry as? [String: Any] else {
                throw CodexCredentialStoreError.incompatibleSchema
            }
            let email = (entryObject["email"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            accounts.append(LegacyAccountsSnapshot.Account(
                accountID: trimmed,
                email: email.isEmpty ? nil : email
            ))
        }
        // 旧布局 active 账号存在独立的 codex:active-account Keychain 项.
        // key 不存在返回 nil; 读取失败是存储错误, 必须抛错而非降级.
        let active: String?
        do {
            active = try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            )?.nilIfEmpty
        } catch {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "legacyActiveAccount 读取失败"
            )
        }
        return LegacyAccountsSnapshot(
            accounts: accounts,
            activeAccountID: active
        )
    }

    /// 幂等迁移: 旧整体库 -> metadata-only v2 记录.
    ///
    /// 流程 (严格顺序):
    /// 1. 读取旧键; 无旧键 -> `.noLegacyData` (幂等).
    /// 2. 解析旧 JSON; 损坏 -> `.corruptedJSON` (保留旧键).
    /// 3. 逐账号写 v2 记录 -> 重读校验无 token.
    /// 4. 写 v2 索引 + 迁移标记 -> 重读校验.
    /// 5. 删除旧 `codex:accounts` 与旧 active 账号.
    ///
    /// 预提交失败 (步骤 3-4) 返回 `.failed`, 保留旧键 (可重试).
    /// 提交后删除失败 (步骤 5) 返回 `.cleanupPending`, v2 数据已生效,
    /// 下次启动重试清理旧键.
    public func migrateLegacyAccounts(now: Date) -> CodexMigrationResult {
        // marker 已提交时只允许校验 v2 并幂等清理遗留 key. 不重新解析旧库,
        // 不改写 record/index/marker, 避免 cleanupPending 期间的新登录被覆盖.
        let currentIndex: CodexAccountIndex
        do {
            currentIndex = try loadIndex()
        } catch {
            return .failed
        }
        if currentIndex.migrationCompletedAt != nil {
            do {
                let expectation = try expectationForExistingIndex(currentIndex)
                try Self.verifyIndex(currentIndex, expectation: expectation)
                try verifyExpectedRecords(expectation.records)
            } catch {
                return .failed
            }
            return cleanupCommittedLegacyKeys(
                accountCount: currentIndex.accounts.count
            )
        }

        // 1. 显式读取旧 accounts key: 区分「不存在」「读到数据」「读取失败」.
        //    读取失败是存储错误, 必须返回 typed failure, 不得降级为 noLegacyData.
        let legacyJSON: String?
        do {
            legacyJSON = try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyAccounts
            )
        } catch {
            return .failed
        }
        guard let legacyJSON else {
            // 旧 accounts key 不存在: 检查旧 active key 是否孤立残留.
            let activeRaw: String?
            do {
                activeRaw = try store.loadCredential(
                    forAccount: CodexCredentialKeys.legacyActiveAccount
                )
            } catch {
                return .failed
            }
            guard activeRaw != nil else {
                return .noLegacyData
            }
            // 孤立 active key: 只清理它, 不写迁移标记, 不覆盖 v2.
            // 删除后必须复读确认; delete 返回成功但 key 仍存在也是失败.
            do {
                try store.deleteCredential(
                    forAccount: CodexCredentialKeys.legacyActiveAccount
                )
                guard try store.loadCredential(
                    forAccount: CodexCredentialKeys.legacyActiveAccount
                ) == nil else {
                    return .cleanupPending
                }
            } catch {
                return .cleanupPending
            }
            return .migrated(accountCount: currentIndex.accounts.count)
        }
        // key 存在但值为空属于损坏数据, 不能与 key 不存在合并.
        guard !legacyJSON.isEmpty else {
            return .corruptedJSON
        }

        // 2. 严格解析: 损坏 -> corruptedJSON; 未知结构 -> incompatibleSchema.
        let snapshot: LegacyAccountsSnapshot
        do {
            snapshot = try parseLegacyAccounts(legacyJSON)
        } catch CodexCredentialStoreError.corruptedJSON {
            return .corruptedJSON
        } catch CodexCredentialStoreError.migrationFailed {
            // active key 读取失败等存储错误: 不得当作 schema 问题
            return .failed
        } catch {
            return .incompatibleSchema
        }

        // 3. 预提交: 逐账号「保留优先」写入 + 语义校验.
        //    任何写入/校验失败立即返回 .failed, 旧 key 保留.
        let expected: MigrationExpectation
        do {
            expected = try writeMigratedRecords(
                from: snapshot, now: now
            )
        } catch {
            return .failed
        }

        // 4. 写索引 + marker, 重读后做完整语义校验 (集合/顺序/状态/origin).
        do {
            try saveIndex(expected.index)
            let verified = try loadIndex()
            try Self.verifyIndex(verified, expectation: expected)
        } catch {
            return .failed
        }

        // 5. 复读全部 v2 record 并校验 (包含既有 v2-only 账号;
        // 不比较/记录 token 明文).
        do {
            try verifyExpectedRecords(expected.records)
        } catch {
            return .failed
        }

        // 6. 删除旧 key (提交后阶段): active 先删, accounts 主数据最后删.
        //    删除后分别复读确认 key 不存在; 任一删除或复读失败都返回
        //    cleanupPending (v2 已生效, 下次启动幂等重试清理).
        do {
            try store.deleteCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            )
            guard try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            ) == nil else {
                return .cleanupPending
            }
        } catch {
            return .cleanupPending
        }
        do {
            try store.deleteCredential(
                forAccount: CodexCredentialKeys.legacyAccounts
            )
            guard try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyAccounts
            ) == nil else {
                return .cleanupPending
            }
        } catch {
            return .cleanupPending
        }
        return .migrated(accountCount: snapshot.accounts.count)
    }

    // MARK: 迁移辅助

    /// 迁移预期快照: 写入前固定, 校验时逐一比对.
    private struct MigrationExpectation {
        struct RecordExpectation {
            let schemaVersion: Int
            let accountID: String
            let email: String?
            let authorizationState: CodexAuthorizationState
            let credentialOrigin: CodexCredentialOrigin
            let updatedAt: Date
            let isFullCredential: Bool
        }

        var records: [RecordExpectation] = []
        var index: CodexAccountIndex
    }

    /// 逐账号「保留优先」写入, 构造预期索引.
    /// - 已有合法 connected/full Mddd record 时保留现有 record.
    /// - 已有合法 metadata-only record 时按状态合并, 不降低状态质量.
    /// - 缺失时才创建迁移 record.
    /// 任何写入失败立即抛错, 不删除旧 key.
    private func writeMigratedRecords(
        from snapshot: LegacyAccountsSnapshot,
        now: Date
    ) throws -> MigrationExpectation {
        var index = try loadIndex()
        var recordsByID: [String: CodexAccountRecord] = [:]
        var seenIndexIDs = Set<String>()

        // 先把完整现有 v2 index/record 纳入预期. 迁移不能假设 v2 只包含
        // legacy 快照中的账号, 也不能因存在 v2-only 账号而校验失败.
        for entry in index.accounts {
            guard seenIndexIDs.insert(entry.accountID).inserted,
                  let record = try loadStoredRecord(for: entry.accountID) else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "v2 index 含重复或缺失 record"
                )
            }
            _ = try Self.expectation(for: record)
            recordsByID[entry.accountID] = record
        }

        for account in snapshot.accounts {
            // 保留优先: index 内记录或同 hash 的孤立 v2 record 都保留原样,
            // 不用旧 metadata-only 数据覆盖.
            if recordsByID[account.accountID] != nil {
                continue
            }
            if let orphan = try loadStoredRecord(for: account.accountID) {
                _ = try Self.expectation(for: orphan)
                recordsByID[account.accountID] = orphan
                continue
            }
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
            recordsByID[account.accountID] = record
        }

        let records = try recordsByID.values
            .map(Self.expectation(for:))
            .sorted { $0.accountID < $1.accountID }
        index.accounts = records.map { record in
            CodexAccountIndex.Entry(
                credentialKeyHash: CodexCredentialKeys.sha256Hex(record.accountID),
                accountID: record.accountID,
                email: record.email,
                authorizationState: record.authorizationState,
                credentialOrigin: record.credentialOrigin
            )
        }
        if let active = snapshot.activeAccountID,
           index.accounts.contains(where: { $0.accountID == active }) {
            index.activeAccountID = active
        } else if let active = index.activeAccountID,
                  !index.accounts.contains(where: { $0.accountID == active }) {
            index.activeAccountID = nil
        }
        index.migrationCompletedAt = now
        return MigrationExpectation(records: records, index: index)
    }

    /// index 语义校验: 完整账号 ID 集合与顺序必须与预期一致 (禁止只比较 count),
    /// 状态/origin/元数据必须一致, marker 必须已提交.
    private static func verifyIndex(
        _ verified: CodexAccountIndex,
        expectation: MigrationExpectation
    ) throws {
        guard verified.schemaVersion == CodexAccountIndex.schemaVersion,
              verified.accounts == expectation.index.accounts,
              verified.activeAccountID == expectation.index.activeAccountID,
              verified.migrationCompletedAt
                == expectation.index.migrationCompletedAt else {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "index/active/marker 语义不一致"
            )
        }
    }

    /// record 语义校验: accountID/展示元数据/state/origin/token 有无.
    /// 不比较或记录 token 明文, 只校验「有无」语义.
    private static func verifyRecord(
        _ saved: CodexAccountRecord,
        expected: MigrationExpectation.RecordExpectation
    ) throws {
        guard saved.schemaVersion == expected.schemaVersion,
              saved.accountID == expected.accountID,
              saved.email == expected.email,
              saved.authorizationState == expected.authorizationState,
              saved.credentialOrigin == expected.credentialOrigin,
              saved.updatedAt == expected.updatedAt else {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "record 状态或元数据不一致"
            )
        }
        if expected.isFullCredential {
            guard saved.accessToken?.isEmpty == false,
                  saved.refreshToken?.isEmpty == false,
                  saved.accessTokenExpiresAt != nil else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "完整 record token 语义不符"
                )
            }
        } else {
            guard saved.accessToken == nil,
                  saved.refreshToken == nil,
                  saved.idToken == nil,
                  saved.accessTokenExpiresAt == nil else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "metadata-only record 含 token"
                )
            }
        }
    }

    /// 读取具体 v2 record, 不依赖 index 是否已登记. 用于迁移期间保留孤立但
    /// 合法的 v2 record, 避免以旧 metadata-only 数据覆盖.
    private func loadStoredRecord(
        for accountID: String
    ) throws -> CodexAccountRecord? {
        try decode(
            CodexAccountRecord.self,
            from: try store.loadCredential(
                forAccount: CodexCredentialKeys.accountKey(for: accountID)
            )
        )
    }

    /// 从 record 生成不可变语义预期. connected 必须是完整凭证;
    /// needsReauthorization/revoked 必须是 metadata-only.
    private static func expectation(
        for record: CodexAccountRecord
    ) throws -> MigrationExpectation.RecordExpectation {
        guard record.schemaVersion == CodexAccountRecord.schemaVersion,
              !record.accountID.isEmpty else {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "record schema/accountID 无效"
            )
        }
        let isFull = record.authorizationState == .connected
        if isFull {
            guard record.resolvedAuthorizationState == .connected else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "connected record 不完整"
                )
            }
        } else {
            guard record.accessToken == nil,
                  record.refreshToken == nil,
                  record.idToken == nil,
                  record.accessTokenExpiresAt == nil else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "非 connected record 含 token"
                )
            }
        }
        return MigrationExpectation.RecordExpectation(
            schemaVersion: record.schemaVersion,
            accountID: record.accountID,
            email: record.email,
            authorizationState: record.authorizationState,
            credentialOrigin: record.credentialOrigin,
            updatedAt: record.updatedAt,
            isFullCredential: isFull
        )
    }

    /// marker 已提交时根据当前 v2 全量数据重建验证预期, 不读取旧 JSON.
    private func expectationForExistingIndex(
        _ index: CodexAccountIndex
    ) throws -> MigrationExpectation {
        var seen = Set<String>()
        var records: [MigrationExpectation.RecordExpectation] = []
        for entry in index.accounts {
            guard seen.insert(entry.accountID).inserted,
                  entry.credentialKeyHash
                    == CodexCredentialKeys.sha256Hex(entry.accountID),
                  let record = try loadStoredRecord(for: entry.accountID),
                  record.email == entry.email,
                  record.authorizationState == entry.authorizationState,
                  record.credentialOrigin == entry.credentialOrigin else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "已提交 v2 index/record 不一致"
                )
            }
            records.append(try Self.expectation(for: record))
        }
        let sorted = records.sorted { $0.accountID < $1.accountID }
        guard records.map(\.accountID) == sorted.map(\.accountID),
              index.activeAccountID == nil
                || seen.contains(index.activeAccountID ?? "") else {
            throw CodexCredentialStoreError.migrationFailed(
                reason: "已提交 v2 index 顺序或 active 无效"
            )
        }
        return MigrationExpectation(records: records, index: index)
    }

    private func verifyExpectedRecords(
        _ records: [MigrationExpectation.RecordExpectation]
    ) throws {
        for expected in records {
            guard let saved = try loadStoredRecord(for: expected.accountID) else {
                throw CodexCredentialStoreError.migrationFailed(
                    reason: "record 缺失"
                )
            }
            try Self.verifyRecord(saved, expected: expected)
        }
    }

    /// marker 已提交后的幂等清理. 先删 active, accounts 主数据最后删;
    /// 每次删除后复读确认, 任一步失败均保留 cleanupPending.
    private func cleanupCommittedLegacyKeys(
        accountCount: Int
    ) -> CodexMigrationResult {
        let active: String?
        let accounts: String?
        do {
            active = try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyActiveAccount
            )
            accounts = try store.loadCredential(
                forAccount: CodexCredentialKeys.legacyAccounts
            )
        } catch {
            return .cleanupPending
        }
        guard active != nil || accounts != nil else {
            return .noLegacyData
        }
        if active != nil {
            do {
                try store.deleteCredential(
                    forAccount: CodexCredentialKeys.legacyActiveAccount
                )
                guard try store.loadCredential(
                    forAccount: CodexCredentialKeys.legacyActiveAccount
                ) == nil else {
                    return .cleanupPending
                }
            } catch {
                return .cleanupPending
            }
        }
        if accounts != nil {
            do {
                try store.deleteCredential(
                    forAccount: CodexCredentialKeys.legacyAccounts
                )
                guard try store.loadCredential(
                    forAccount: CodexCredentialKeys.legacyAccounts
                ) == nil else {
                    return .cleanupPending
                }
            } catch {
                return .cleanupPending
            }
        }
        return .migrated(accountCount: accountCount)
    }
}
