import Foundation
@testable import BruceOnboardingCore

// MARK: - CodexCredentialStoreTests

/// 任务 2 定向验证: v2 凭证模型、分账号存储和迁移器.
enum CodexCredentialStoreTests {
    static func runAll() throws {
        try indexKeyIsFixedV2()
        try accountKeyUsesFullSHA256()
        try incompleteRecordReadsAsNeedsReauthorization()
        try saveOneAccountDoesNotOverwriteOthers()
        try legacyMigrationKeepsOnlyMetadata()
        try migrationWritesThenVerifiesThenDeletes()
        try migrationFailureReturnsFailedAndKeepsLegacyKeys()
        try repeatedMigrationIsIdempotent()
        try deleteRecordRemovesAccountAndUpdatesIndex()
        try emptyLegacyLibraryMigratesCleanly()
        try corruptedLegacyJSONReturnsCorruptedJSON()
        try migrationWriteFailureReturnsFailed()
        try migrationCleanupPendingKeepsLegacyKeys()
        try metadataOnlyAccountIsNotCredentialConfigured()
        try configuredFlagRequiresCompleteRecord()
        try unknownLegacySchemaIsNotEmptyMigration()
        try emptyAccountsObjectIsValidEmptyMigration()
        try legacyArrayNullOrMissingAccountsKeepsKeys()
        try legacyAccountsKeyReadFailureIsTypedFailure()
        try legacyActiveKeyReadFailureKeepsAccountsKey()
        try indexCountEqualButAccountsDifferentFails()
        try recordStateOrOriginMismatchFails()
        try activeDeleteFailureReturnsCleanupPending()
        try markerCommittedRetriesOnlyCleanup()
        try fullBruceRecordNotOverwrittenByMigration()
        try emptyLegacyValueIsNotMissingData()
        try migrationPreservesUnrelatedV2Account()
        try orphanActiveCleanupVerifiesDeletion()
        print("CodexCredentialStore tests passed: 28")
    }

    private static func makeStore() -> (CodexCredentialStore, InMemoryCredentialStore) {
        let memory = InMemoryCredentialStore()
        return (CodexCredentialStore(store: memory), memory)
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_752_000_000)

    // 1. 索引键固定为 codex:account-index:v2
    private static func indexKeyIsFixedV2() throws {
        let (store, memory) = makeStore()
        let record = CodexAccountRecord(
            accountID: "acc-1",
            email: "u@example.com",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        try store.saveRecord(record)
        let indexJSON = try memory.loadCredential(
            forAccount: CodexCredentialKeys.accountIndexV2
        )
        guard let indexJSON else {
            throw CodexTestFailure.expectation("v2 索引未写入 Keychain")
        }
        let index = try JSONDecoder().decode(
            CodexAccountIndex.self, from: Data(indexJSON.utf8)
        )
        guard index.accounts.count == 1,
              index.accounts[0].accountID == "acc-1" else {
            throw CodexTestFailure.expectation("v2 索引内容不符")
        }
    }

    // 2. 单账号键使用完整 SHA-256, 不暴露原始 account ID
    private static func accountKeyUsesFullSHA256() throws {
        let (store, memory) = makeStore()
        let record = CodexAccountRecord(
            accountID: "sensitive-account-id-12345",
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        try store.saveRecord(record)
        let expected = "codex:account:v2:"
            + CodexCredentialKeys.sha256Hex("sensitive-account-id-12345")
        let raw = try memory.loadCredential(forAccount: expected)
        guard let raw else {
            throw CodexTestFailure.expectation("SHA-256 键未写入记录")
        }
        let recordText = try memory.loadCredential(
            forAccount: CodexCredentialKeys.accountV2Prefix
                + "sensitive-account-id-12345"
        )
        guard recordText == nil else {
            throw CodexTestFailure.expectation("键名泄露了原始 account ID")
        }
        guard raw.contains("sensitive-account-id-12345") else {
            throw CodexTestFailure.expectation("记录内必须包含真实 account ID")
        }
    }

    // 3. connected 记录缺少 token 或过期时间时按 needsReauthorization 读取
    private static func incompleteRecordReadsAsNeedsReauthorization() throws {
        let missingRefresh = CodexAccountRecord(
            accountID: "acc-a",
            accessToken: "at",
            refreshToken: nil,
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        guard missingRefresh.resolvedAuthorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("缺 refresh token 必须 fail-closed")
        }

        let missingExpiry = CodexAccountRecord(
            accountID: "acc-b",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: nil,
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        guard missingExpiry.resolvedAuthorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("缺过期时间必须 fail-closed")
        }

        let emptyAccess = CodexAccountRecord(
            accountID: "acc-c",
            accessToken: "",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        guard emptyAccess.resolvedAuthorizationState == .needsReauthorization else {
            throw CodexTestFailure.expectation("空 access token 必须 fail-closed")
        }

        let complete = CodexAccountRecord(
            accountID: "acc-d",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        guard complete.resolvedAuthorizationState == .connected else {
            throw CodexTestFailure.expectation("完整记录必须保持 connected")
        }
    }

    // 4. 单账号保存不会覆盖其他账号
    private static func saveOneAccountDoesNotOverwriteOthers() throws {
        let (store, memory) = makeStore()
        let first = CodexAccountRecord(
            accountID: "acc-1",
            accessToken: "at-1",
            refreshToken: "rt-1",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        let second = CodexAccountRecord(
            accountID: "acc-2",
            accessToken: "at-2",
            refreshToken: "rt-2",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        )
        try store.saveRecord(first)
        try store.saveRecord(second)

        // 旋转 acc-1 的 token, acc-2 必须不受影响
        let rotated = CodexAccountRecord(
            accountID: "acc-1",
            accessToken: "at-1-new",
            refreshToken: "rt-1-new",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(7200),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow.addingTimeInterval(10)
        )
        try store.saveRecord(rotated)

        let acc1 = try store.loadRecord(for: "acc-1")
        guard acc1?.accessToken == "at-1-new",
              acc1?.refreshToken == "rt-1-new" else {
            throw CodexTestFailure.expectation("acc-1 旋转未生效")
        }
        let acc2 = try store.loadRecord(for: "acc-2")
        guard acc2?.accessToken == "at-2",
              acc2?.refreshToken == "rt-2" else {
            throw CodexTestFailure.expectation("acc-2 被 acc-1 覆盖")
        }
        guard try memory.loadCredential(
            forAccount: CodexCredentialKeys.accountKey(for: "acc-2")
        ) != nil else {
            throw CodexTestFailure.expectation("acc-2 记录丢失")
        }
    }

    // 5. 旧迁移只保留 account ID 与 email, 不复制任何 token
    private static func legacyMigrationKeepsOnlyMetadata() throws {
        let (store, memory) = makeStore()
        let legacyJSON = """
        {"accounts":{"acc-1":{"email":"u1@example.com",\
        "refresh_token":"rt-1","access_token":"at-1","id_token":"it-1"},\
        "acc-2":{"refresh_token":"rt-2"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated(let count) = result, count == 2 else {
            throw CodexTestFailure.expectation("迁移应返回 migrated(2): \(result)")
        }
        let index = try store.loadIndex()
        guard index.accounts.count == 2 else {
            throw CodexTestFailure.expectation("迁移账号数不符")
        }
        for accountID in ["acc-1", "acc-2"] {
            let record = try store.loadRecord(for: accountID)
            guard let record else {
                throw CodexTestFailure.expectation("账号 \(accountID) 记录缺失")
            }
            guard record.accessToken == nil,
                  record.refreshToken == nil,
                  record.idToken == nil else {
                throw CodexTestFailure.expectation("迁移复制了 token")
            }
            guard record.authorizationState == .needsReauthorization,
                  record.credentialOrigin == .legacyCCSwitchDiscovery else {
                throw CodexTestFailure.expectation("迁移记录状态/来源不符")
            }
        }
        guard index.accounts[0].email == "u1@example.com" else {
            throw CodexTestFailure.expectation("迁移丢失 email 元数据")
        }
    }

    // 6. 迁移严格先写 v2、重读校验、再删除旧键
    private static func migrationWritesThenVerifiesThenDeletes() throws {
        let (store, memory) = makeStore()
        let legacyJSON = """
        {"accounts":{"acc-1":{"email":"u@example.com","refresh_token":"rt"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        try memory.saveCredential(
            "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
        )

        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated = result else {
            throw CodexTestFailure.expectation("迁移应成功: \(result)")
        }

        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy == nil else {
            throw CodexTestFailure.expectation("旧整体库未被删除")
        }
        let active = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyActiveAccount
        )
        guard active == nil else {
            throw CodexTestFailure.expectation("旧 active 项未被删除")
        }
        let index = try store.loadIndex()
        guard index.activeAccountID == "acc-1",
              index.migrationCompletedAt != nil else {
            throw CodexTestFailure.expectation("迁移完成标记/active 未写入")
        }
    }

    // 7. 迁移写入失败返回 .failed, 保留旧键, v2 读取 fail-closed, 迁移可重试
    private static func migrationFailureReturnsFailedAndKeepsLegacyKeys() throws {
        final class FailingStore: CredentialStore, @unchecked Sendable {
            private let inner: InMemoryCredentialStore
            var failNextSave = false
            init(inner: InMemoryCredentialStore) { self.inner = inner }
            func saveCredential(_ value: String, forAccount account: String) throws {
                if failNextSave {
                    failNextSave = false
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
        }

        let memory = InMemoryCredentialStore()
        let failing = FailingStore(inner: memory)
        let store = CodexCredentialStore(store: failing)
        let legacyJSON = """
        {"accounts":{"acc-1":{"refresh_token":"rt"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )

        failing.failNextSave = true
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .failed = result else {
            throw CodexTestFailure.expectation("写入失败应返回 .failed: \(result)")
        }
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy != nil else {
            throw CodexTestFailure.expectation("失败迁移删除了旧键")
        }

        // 重试成功
        let retried = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated = retried else {
            throw CodexTestFailure.expectation("重试迁移应成功: \(retried)")
        }
        let index = try store.loadIndex()
        guard index.accounts.count == 1 else {
            throw CodexTestFailure.expectation("重试后账号数不符")
        }
    }

    // 8. 重复迁移幂等, 不产生重复账号
    private static func repeatedMigrationIsIdempotent() throws {
        let (store, memory) = makeStore()
        let legacyJSON = """
        {"accounts":{"acc-1":{"refresh_token":"rt"},"acc-2":{"refresh_token":"rt2"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        let first = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated = first else {
            throw CodexTestFailure.expectation("首次迁移应成功: \(first)")
        }
        // 旧键已删除, 再次迁移应 no-op 返回 .noLegacyData
        let second = store.migrateLegacyAccounts(now: fixedNow)
        guard case .noLegacyData = second else {
            throw CodexTestFailure.expectation("第二次迁移应幂等 noLegacyData: \(second)")
        }
        let index = try store.loadIndex()
        guard index.accounts.count == 2 else {
            throw CodexTestFailure.expectation("重复迁移产生重复账号")
        }
    }

    // 9. 删除账号只删除对应记录并更新索引
    private static func deleteRecordRemovesAccountAndUpdatesIndex() throws {
        let (store, memory) = makeStore()
        for accountID in ["acc-1", "acc-2"] {
            try store.saveRecord(CodexAccountRecord(
                accountID: accountID,
                accessToken: "at",
                refreshToken: "rt",
                accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
                authorizationState: .connected,
                credentialOrigin: .Bruce,
                updatedAt: fixedNow
            ))
        }
        try store.deleteRecord(for: "acc-1")

        let index = try store.loadIndex()
        guard index.accounts.count == 1, index.accounts[0].accountID == "acc-2" else {
            throw CodexTestFailure.expectation("删除后索引未更新")
        }
        let acc1 = try memory.loadCredential(
            forAccount: CodexCredentialKeys.accountKey(for: "acc-1")
        )
        guard acc1 == nil else {
            throw CodexTestFailure.expectation("acc-1 记录未被删除")
        }
        let acc2 = try store.loadRecord(for: "acc-2")
        guard acc2 != nil else {
            throw CodexTestFailure.expectation("acc-2 记录被误删")
        }
    }

    // 10. 空旧库迁移: 删除旧键并打迁移标记
    private static func emptyLegacyLibraryMigratesCleanly() throws {
        let (store, memory) = makeStore()
        try memory.saveCredential(
            "{\"accounts\":{}}", forAccount: CodexCredentialKeys.legacyAccounts
        )
        try memory.saveCredential(
            "", forAccount: CodexCredentialKeys.legacyActiveAccount
        )
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated(let count) = result, count == 0 else {
            throw CodexTestFailure.expectation("空库迁移应返回 migrated(0): \(result)")
        }
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy == nil else {
            throw CodexTestFailure.expectation("空库旧键未删除")
        }
        let index = try store.loadIndex()
        guard index.accounts.isEmpty,
              index.migrationCompletedAt != nil else {
            throw CodexTestFailure.expectation("空库迁移标记未写入")
        }
    }

    // 11. 损坏旧 JSON 返回 .corruptedJSON, 保留旧键
    private static func corruptedLegacyJSONReturnsCorruptedJSON() throws {
        let (store, memory) = makeStore()
        try memory.saveCredential(
            "not-valid-json{{", forAccount: CodexCredentialKeys.legacyAccounts
        )
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .corruptedJSON = result else {
            throw CodexTestFailure.expectation("损坏 JSON 应返回 .corruptedJSON: \(result)")
        }
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy != nil else {
            throw CodexTestFailure.expectation("corruptedJSON 不应删除旧键")
        }
    }

    // 12. 迁移写入失败返回 .failed (预提交失败保留旧键)
    private static func migrationWriteFailureReturnsFailed() throws {
        final class FailingStore: CredentialStore, @unchecked Sendable {
            private let inner: InMemoryCredentialStore
            var failSaves = false
            init(inner: InMemoryCredentialStore) { self.inner = inner }
            func saveCredential(_ value: String, forAccount account: String) throws {
                if failSaves {
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
        }

        let memory = InMemoryCredentialStore()
        let failing = FailingStore(inner: memory)
        let store = CodexCredentialStore(store: failing)
        let legacyJSON = """
        {"accounts":{"acc-1":{"refresh_token":"rt"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        failing.failSaves = true
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .failed = result else {
            throw CodexTestFailure.expectation("持续写入失败应返回 .failed: \(result)")
        }
        // 旧键保留 (预提交失败不删除主数据)
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy != nil else {
            throw CodexTestFailure.expectation(".failed 不应删除旧键")
        }
    }

    // 13. v2 记录已提交但旧键删除失败 -> .cleanupPending (旧键保留)
    private static func migrationCleanupPendingKeepsLegacyKeys() throws {
        final class FailingDeleteStore: CredentialStore, @unchecked Sendable {
            private let inner: InMemoryCredentialStore
            var failDelete = false
            init(inner: InMemoryCredentialStore) { self.inner = inner }
            func saveCredential(_ value: String, forAccount account: String) throws {
                try inner.saveCredential(value, forAccount: account)
            }
            func loadCredential(forAccount account: String) throws -> String? {
                try inner.loadCredential(forAccount: account)
            }
            func deleteCredential(forAccount account: String) throws {
                if failDelete {
                    throw KeychainError.deleteFailed(-1)
                }
                try inner.deleteCredential(forAccount: account)
            }
        }

        let memory = InMemoryCredentialStore()
        let failing = FailingDeleteStore(inner: memory)
        let store = CodexCredentialStore(store: failing)
        let legacyJSON = """
        {"accounts":{"acc-1":{"refresh_token":"rt"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        failing.failDelete = true
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .cleanupPending = result else {
            throw CodexTestFailure.expectation("删除失败应返回 .cleanupPending: \(result)")
        }
        // v2 记录已写入
        let record = try store.loadRecord(for: "acc-1")
        guard record != nil else {
            throw CodexTestFailure.expectation("cleanupPending 时 v2 记录应已写入")
        }
        // 旧键保留 (待下次启动清理)
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy != nil else {
            throw CodexTestFailure.expectation("cleanupPending 旧键应保留")
        }
    }

    // 14. metadata-only 发现账号不算"已配置凭证"
    private static func metadataOnlyAccountIsNotCredentialConfigured() throws {
        let (store, _) = makeStore()
        // 写入 metadata-only 账号 (needsReauthorization, 无 token)
        try store.saveRecord(CodexAccountRecord(
            accountID: "discovered-1",
            email: "user@example.com",
            authorizationState: .needsReauthorization,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        let index = try store.loadIndex()
        // 索引非空但无 connected 账号
        guard !index.accounts.isEmpty else {
            throw CodexTestFailure.expectation("账号应已写入索引")
        }
        let hasConnected = index.accounts.contains {
            $0.authorizationState == .connected
        }
        guard !hasConnected else {
            throw CodexTestFailure.expectation("metadata-only 账号不应是 connected")
        }
    }

    // 15. 任务 9: "已配置"必须按真实完整 record 判定 (fail-closed),
    // 索引里的 connected 状态不能单独作数.
    // 设置页与 Scheduler 都以 hasConfiguredCredentials 为准:
    // - metadata-only 发现账号 (索引 needsReauthorization) 不算已配置.
    // - 完整 connected record (access token + refresh token + 可解析过期时间)
    //   才算已配置.
    // - 索引标 connected 但 record 残缺 (如 token 被清空) 时按未配置处理.
    private static func configuredFlagRequiresCompleteRecord() throws {
        let (store, _) = makeStore()

        // 场景 1: 只有 metadata-only 发现账号 -> 未配置.
        try store.saveRecord(CodexAccountRecord(
            accountID: "discovered-1",
            email: "user@example.com",
            authorizationState: .needsReauthorization,
            credentialOrigin: .legacyCCSwitchDiscovery,
            updatedAt: fixedNow
        ))
        guard try !store.hasConfiguredCredentials() else {
            throw CodexTestFailure.expectation(
                "metadata-only 账号不应算已配置"
            )
        }

        // 场景 2: 补上完整 connected record -> 已配置.
        try store.saveRecord(CodexAccountRecord(
            accountID: "connected-1",
            accessToken: "at",
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        ))
        guard try store.hasConfiguredCredentials() else {
            throw CodexTestFailure.expectation(
                "完整 connected record 应算已配置"
            )
        }

        // 场景 3: 索引标 connected 但 record 残缺 (token 被清空)
        // -> resolvedAuthorizationState 降级为 needsReauthorization -> 未配置.
        // 独立 store, 避免场景 2 的完整记录干扰.
        let (tornStore, _) = makeStore()
        try tornStore.saveRecord(CodexAccountRecord(
            accountID: "torn-1",
            accessToken: nil,
            refreshToken: "rt",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: fixedNow
        ))
        guard try !tornStore.hasConfiguredCredentials() else {
            throw CodexTestFailure.expectation(
                "record 残缺 (token 被清空) 不应算已配置"
            )
        }
    }

    // MARK: - 任务 1: 旧凭证迁移解析/删除/校验闭环 (MIG-01 ~ MIG-12)

// MIG-01: 旧值为 `{}` -> incompatible/corrupted, 两个旧 key 均保留
private static func unknownLegacySchemaIsNotEmptyMigration() throws {
    for raw in ["{}", "{\"foo\": {}}"] {
        let (store, memory) = makeStore()
        try memory.saveCredential(
            raw, forAccount: CodexCredentialKeys.legacyAccounts
        )
        try memory.saveCredential(
            "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
        )
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard case .incompatibleSchema = result else {
            throw CodexTestFailure.expectation(
                "未知 schema \(raw) 应返回 .incompatibleSchema: \(result)"
            )
        }
        guard try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        ) != nil else {
            throw CodexTestFailure.expectation("未知 schema 不应删除旧 accounts key")
        }
        guard try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyActiveAccount
        ) != nil else {
            throw CodexTestFailure.expectation("未知 schema 不应删除旧 active key")
        }
        let index = try store.loadIndex()
        guard index.accounts.isEmpty, index.migrationCompletedAt == nil else {
            throw CodexTestFailure.expectation("未知 schema 不应写入迁移标记")
        }
    }
}

// MIG-02/MIG-03: accounts 为数组/字符串/null -> 迁移失败, 旧 key 保留
private static func legacyArrayNullOrMissingAccountsKeepsKeys() throws {
    for raw in ["{\"accounts\": []}", "{\"accounts\": \"x\"}",
                "{\"accounts\": null}", "{\"foo\": {}}"] {
        let (store, memory) = makeStore()
        try memory.saveCredential(
            raw, forAccount: CodexCredentialKeys.legacyAccounts
        )
        let result = store.migrateLegacyAccounts(now: fixedNow)
        guard result == .incompatibleSchema else {
            throw CodexTestFailure.expectation(
                "accounts 非对象 \(raw) 应返回 .incompatibleSchema: \(result)"
            )
        }
        guard try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        ) != nil else {
            throw CodexTestFailure.expectation("失败迁移不应删除旧 key")
        }
    }
}

// MIG-04: `{"accounts": {}}` 是合法空迁移
private static func emptyAccountsObjectIsValidEmptyMigration() throws {
    let (store, memory) = makeStore()
    try memory.saveCredential(
        "{\"accounts\": {}}", forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .migrated(let count) = result, count == 0 else {
        throw CodexTestFailure.expectation(
            "明确空 accounts 应 migrated(0): \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) == nil else {
        throw CodexTestFailure.expectation("空迁移应删除旧 accounts key")
    }
    guard try store.loadIndex().migrationCompletedAt != nil else {
        throw CodexTestFailure.expectation("空迁移应写入 marker")
    }
}

// MIG-05: 读取 accounts key 抛 Keychain 错误 -> typed failure, 不返回 noLegacyData
private static func legacyAccountsKeyReadFailureIsTypedFailure() throws {
    final class FailingLoadStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        var failAccountsLoad = false
        init(inner: InMemoryCredentialStore) { self.inner = inner }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            if failAccountsLoad,
               account == CodexCredentialKeys.legacyAccounts {
                throw KeychainError.loadFailed(-1)
            }
            return try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let failing = FailingLoadStore(inner: memory)
    let store = CodexCredentialStore(store: failing)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    failing.failAccountsLoad = true
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .failed = result else {
        throw CodexTestFailure.expectation(
            "读取失败应返回 .failed, 不降级 noLegacyData: \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("读取失败不应删除旧 key")
    }
}

// MIG-06: 读取 active key 抛错误 -> typed failure, 不删除 accounts key
private static func legacyActiveKeyReadFailureKeepsAccountsKey() throws {
    final class FailingLoadStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        var failActiveLoad = false
        init(inner: InMemoryCredentialStore) { self.inner = inner }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            if failActiveLoad,
               account == CodexCredentialKeys.legacyActiveAccount {
                throw KeychainError.loadFailed(-1)
            }
            return try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let failing = FailingLoadStore(inner: memory)
    let store = CodexCredentialStore(store: failing)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"u@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    try memory.saveCredential(
        "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
    )
    failing.failActiveLoad = true
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .failed = result else {
        throw CodexTestFailure.expectation(
            "active 读取失败应返回 .failed: \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("active 读取失败不应删除 accounts key")
    }
}

// MIG-07: index 数量相同但账号 ID 不同 -> 校验失败, 旧 key 保留
private static func indexCountEqualButAccountsDifferentFails() throws {
    final class SabotagingIndexStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        /// 第 3 次 indexV2 读取 (写入后的重读校验) 返回篡改 index.
        /// 读取序列: 1) marker 检查 2) 迁移事务读 index 3) 写后重读校验.
        private var indexReadCount = 0
        init(inner: InMemoryCredentialStore) { self.inner = inner }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            if account == CodexCredentialKeys.accountIndexV2 {
                indexReadCount += 1
                if indexReadCount == 3 {
                    // 同 count 但账号 ID 不同; marker 用数字时间戳 (deferredToDate)
                    return "{\"schemaVersion\":2,\"accounts\":[{"
                        + "\"credentialKeyHash\":\"hash-x\",\"accountID\":\"acc-X\","
                        + "\"email\":null,\"authorizationState\":\"needsReauthorization\","
                        + "\"credentialOrigin\":\"legacyCCSwitchDiscovery\"}],"
                        + "\"activeAccountID\":null,\"migrationCompletedAt\":1752000000.0}"
                }
            }
            return try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let sabotage = SabotagingIndexStore(inner: memory)
    let store = CodexCredentialStore(store: sabotage)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"u@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .failed = result else {
        throw CodexTestFailure.expectation(
            "index 集合不一致应返回 .failed: \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("校验失败不应删除旧 accounts key")
    }
}

// MIG-08: record state/origin/元数据不一致 -> 校验失败, 旧 key 保留
private static func recordStateOrOriginMismatchFails() throws {
    final class SabotagingRecordStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        var tampered = false
        init(inner: InMemoryCredentialStore) { self.inner = inner }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            if !tampered,
               account.hasPrefix(CodexCredentialKeys.accountV2Prefix) {
                tampered = true
                // state/origin/email 与迁移预期不符, 但 token 全空 (旧实现
                // 只查 token 字段会通过); updatedAt 用数字时间戳保证解码成功
                return "{\"schemaVersion\":2,\"accountID\":\"acc-1\",\"email\":null,"
                    + "\"accessToken\":null,\"refreshToken\":null,\"idToken\":null,"
                    + "\"accessTokenExpiresAt\":null,\"authorizationState\":\"connected\","
                    + "\"credentialOrigin\":\"Bruce\",\"updatedAt\":1752000000.0}"
            }
            return try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let sabotage = SabotagingRecordStore(inner: memory)
    let store = CodexCredentialStore(store: sabotage)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"u@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .failed = result else {
        throw CodexTestFailure.expectation(
            "record 状态/来源不一致应返回 .failed: \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("校验失败不应删除旧 accounts key")
    }
}

// MIG-09: active 删除失败 -> cleanupPending; 删除顺序 active 先删,
// accounts 最后删, 失败时 accounts 保留且结果明确
private static func activeDeleteFailureReturnsCleanupPending() throws {
    final class FailingActiveDeleteStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        var failActiveDelete = false
        init(inner: InMemoryCredentialStore) { self.inner = inner }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            if failActiveDelete,
               account == CodexCredentialKeys.legacyActiveAccount {
                throw KeychainError.deleteFailed(-1)
            }
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let failing = FailingActiveDeleteStore(inner: memory)
    let store = CodexCredentialStore(store: failing)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"u@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    try memory.saveCredential(
        "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
    )
    failing.failActiveDelete = true
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .cleanupPending = result else {
        throw CodexTestFailure.expectation(
            "active 删除失败应返回 .cleanupPending: \(result)"
        )
    }
    // 删除顺序: active 先删, accounts 主数据最后删; active 失败时 accounts 未删
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("cleanupPending 时 accounts 应保留")
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyActiveAccount
    ) != nil else {
        throw CodexTestFailure.expectation("active 删除失败应保留 active key")
    }
}

// MIG-10/MIG-12: marker 已提交但 accounts 主数据清理失败. 重启后只清理
// 遗留 key, 不重放迁移或覆盖期间已经重新登录的 v2 record.
private static func markerCommittedRetriesOnlyCleanup() throws {
    final class FailingAccountsDeleteStore: CredentialStore, @unchecked Sendable {
        private let inner: InMemoryCredentialStore
        var failAccountsDelete: Bool
        init(inner: InMemoryCredentialStore, failAccountsDelete: Bool) {
            self.inner = inner
            self.failAccountsDelete = failAccountsDelete
        }
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            if failAccountsDelete,
               account == CodexCredentialKeys.legacyAccounts {
                throw KeychainError.deleteFailed(-1)
            }
            try inner.deleteCredential(forAccount: account)
        }
    }
    let memory = InMemoryCredentialStore()
    let failing = FailingAccountsDeleteStore(
        inner: memory,
        failAccountsDelete: true
    )
    let store = CodexCredentialStore(store: failing)
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"u@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    try memory.saveCredential(
        "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
    )
    let first = store.migrateLegacyAccounts(now: fixedNow)
    guard case .cleanupPending = first else {
        throw CodexTestFailure.expectation("首次应 cleanupPending: \(first)")
    }
    let marker = try store.loadIndex().migrationCompletedAt
    // cleanupPending 期间用户完成 Bruce 重新登录. 下次启动只清理旧 key,
    // 不能再按旧 metadata-only 数据覆盖登录结果或改写 marker.
    let reloginAt = fixedNow.addingTimeInterval(60)
    try store.saveRecord(CodexAccountRecord(
        accountID: "acc-1",
        email: "live@example.com",
        accessToken: "at-live",
        refreshToken: "rt-live",
        accessTokenExpiresAt: reloginAt.addingTimeInterval(3600),
        authorizationState: .connected,
        credentialOrigin: .Bruce,
        updatedAt: reloginAt
    ))

    failing.failAccountsDelete = false
    let second = store.migrateLegacyAccounts(
        now: fixedNow.addingTimeInterval(120)
    )
    guard case .migrated(let count) = second, count == 1 else {
        throw CodexTestFailure.expectation(
            "重启清理应返回 migrated(1): \(second)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) == nil else {
        throw CodexTestFailure.expectation("重启应清理 accounts key")
    }
    let after = try store.loadRecord(for: "acc-1")
    guard after?.email == "live@example.com",
          after?.credentialOrigin == .Bruce,
          after?.accessToken == "at-live",
          after?.refreshToken == "rt-live",
          after?.updatedAt == reloginAt else {
        throw CodexTestFailure.expectation("marker 清理不得覆盖 v2 record")
    }
    guard try store.loadIndex().migrationCompletedAt == marker else {
        throw CodexTestFailure.expectation("marker 清理不得改写提交时间")
    }
}

// MIG-11: 已有完整 Bruce record 不被 metadata-only 迁移数据覆盖
private static func fullBruceRecordNotOverwrittenByMigration() throws {
    let (store, memory) = makeStore()
    // 先有完整 connected record (Bruce 登录)
    try store.saveRecord(CodexAccountRecord(
        accountID: "acc-1",
        email: "live@example.com",
        accessToken: "at-live",
        refreshToken: "rt-live",
        accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
        authorizationState: .connected,
        credentialOrigin: .Bruce,
        updatedAt: fixedNow
    ))
    // 旧库存在同账号 metadata-only 数据
    try memory.saveCredential(
        "{\"accounts\": {\"acc-1\": {\"email\": \"legacy@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard case .migrated(let count) = result, count == 1 else {
        throw CodexTestFailure.expectation("迁移应成功: \(result)")
    }
    let record = try store.loadRecord(for: "acc-1")
    guard let record else {
        throw CodexTestFailure.expectation("完整 record 应保留")
    }
    guard record.accessToken == "at-live",
          record.refreshToken == "rt-live",
          record.credentialOrigin == .Bruce,
          record.email == "live@example.com" else {
        throw CodexTestFailure.expectation(
            "迁移不得覆盖完整 connected record"
        )
    }
}

// 空字符串表示 key 存在但内容损坏, 不能与 key 不存在合并为 noLegacyData.
private static func emptyLegacyValueIsNotMissingData() throws {
    let (store, memory) = makeStore()
    try memory.saveCredential(
        "", forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard result == .corruptedJSON else {
        throw CodexTestFailure.expectation(
            "空旧值应按损坏数据保留, got \(result)"
        )
    }
    guard try memory.loadCredential(
        forAccount: CodexCredentialKeys.legacyAccounts
    ) != nil else {
        throw CodexTestFailure.expectation("空旧值不得被删除")
    }
}

// 迁移 legacy 账号时必须把既有 v2-only 账号一起纳入预期快照和校验,
// 不得因 index 账号数大于 legacy 快照而失败或覆盖既有账号.
private static func migrationPreservesUnrelatedV2Account() throws {
    let (store, memory) = makeStore()
    try store.saveRecord(CodexAccountRecord(
        accountID: "v2-only",
        email: "current@example.com",
        accessToken: "at-current",
        refreshToken: "rt-current",
        accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
        authorizationState: .connected,
        credentialOrigin: .Bruce,
        updatedAt: fixedNow
    ))
    try memory.saveCredential(
        "{\"accounts\": {\"legacy-1\": {\"email\": \"old@example.com\"}}}",
        forAccount: CodexCredentialKeys.legacyAccounts
    )
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard result == .migrated(accountCount: 1) else {
        throw CodexTestFailure.expectation(
            "既有 v2 账号不应阻断 legacy 迁移: \(result)"
        )
    }
    let existing = try store.loadRecord(for: "v2-only")
    guard existing?.accessToken == "at-current",
          existing?.refreshToken == "rt-current",
          existing?.credentialOrigin == .Bruce else {
        throw CodexTestFailure.expectation("v2-only 账号被迁移覆盖")
    }
    let index = try store.loadIndex()
    guard index.accounts.map(\.accountID) == ["legacy-1", "v2-only"] else {
        throw CodexTestFailure.expectation("迁移后的完整 index 集合不符")
    }
}

// accounts 不存在但 active 孤立残留时, 删除后必须复读确认. delete 返回成功
// 但实际未删除仍应 cleanupPending.
private static func orphanActiveCleanupVerifiesDeletion() throws {
    final class NoopActiveDeleteStore: CredentialStore, @unchecked Sendable {
        let inner = InMemoryCredentialStore()
        func saveCredential(_ value: String, forAccount account: String) throws {
            try inner.saveCredential(value, forAccount: account)
        }
        func loadCredential(forAccount account: String) throws -> String? {
            try inner.loadCredential(forAccount: account)
        }
        func deleteCredential(forAccount account: String) throws {
            if account != CodexCredentialKeys.legacyActiveAccount {
                try inner.deleteCredential(forAccount: account)
            }
        }
    }
    let storage = NoopActiveDeleteStore()
    try storage.inner.saveCredential(
        "acc-orphan", forAccount: CodexCredentialKeys.legacyActiveAccount
    )
    let store = CodexCredentialStore(store: storage)
    let result = store.migrateLegacyAccounts(now: fixedNow)
    guard result == .cleanupPending else {
        throw CodexTestFailure.expectation(
            "孤立 active 删除未生效应 cleanupPending: \(result)"
        )
    }
}
}

// MARK: - CodexTestFailure

private enum CodexTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}
