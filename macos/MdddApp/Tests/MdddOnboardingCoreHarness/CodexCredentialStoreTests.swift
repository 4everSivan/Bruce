import Foundation
@testable import MdddOnboardingCore

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
        try migrationFailureKeepsLegacyKeys()
        try repeatedMigrationIsIdempotent()
        try deleteRecordRemovesAccountAndUpdatesIndex()
        try emptyLegacyLibraryMigratesCleanly()
        print("CodexCredentialStore tests passed: 10")
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
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
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
        let (store, _) = makeStore()

        let missingRefresh = CodexAccountRecord(
            accountID: "acc-a",
            accessToken: "at",
            refreshToken: nil,
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
            updatedAt: fixedNow
        )
        let second = CodexAccountRecord(
            accountID: "acc-2",
            accessToken: "at-2",
            refreshToken: "rt-2",
            accessTokenExpiresAt: fixedNow.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
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
        let migrated = try store.migrateLegacyAccounts(now: fixedNow)
        guard migrated else {
            throw CodexTestFailure.expectation("迁移应实际执行")
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

        _ = try store.migrateLegacyAccounts(now: fixedNow)

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

    // 7. 迁移失败保留旧键, v2 读取 fail-closed, 迁移可重试
    private static func migrationFailureKeepsLegacyKeys() throws {
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
        var failed = false
        do {
            _ = try store.migrateLegacyAccounts(now: fixedNow)
        } catch {
            failed = true
        }
        guard failed else {
            throw CodexTestFailure.expectation("迁移应在写入失败时抛错")
        }
        let legacy = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        guard legacy != nil else {
            throw CodexTestFailure.expectation("失败迁移删除了旧键")
        }

        // 重试成功
        let retried = try store.migrateLegacyAccounts(now: fixedNow)
        guard retried else {
            throw CodexTestFailure.expectation("重试迁移应执行")
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
        _ = try store.migrateLegacyAccounts(now: fixedNow)
        // 旧键已删除, 再次迁移应 no-op 且不报错
        let second = try store.migrateLegacyAccounts(now: fixedNow)
        guard !second else {
            throw CodexTestFailure.expectation("第二次迁移应幂等 no-op")
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
                credentialOrigin: .mddd,
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
        let migrated = try store.migrateLegacyAccounts(now: fixedNow)
        guard migrated else {
            throw CodexTestFailure.expectation("空库迁移应执行")
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
