import Foundation
@testable import BruceOnboardingCore

// MARK: - Credential rotation merge / login discovery

extension BruceOnboardingCoreHarness {
    // MARK: - Credential rotation merge

    /// 仅支持有多账号 record 的 provider 走轮换写回.
    static func rotationMergeMapsKnownProviders() throws {
        try coreExpect(
            CredentialRotationMerge.supportsAccountScopedRotation(forProvider: "claude"),
            "claude 必须支持按账号轮换"
        )
        try coreExpect(
            CredentialRotationMerge.supportsAccountScopedRotation(forProvider: "grok"),
            "grok 必须支持按账号轮换"
        )
        try coreExpect(
            !CredentialRotationMerge.supportsAccountScopedRotation(forProvider: "kimi"),
            "kimi 不参与 OAuth 轮换"
        )
        try coreExpect(
            !CredentialRotationMerge.supportsAccountScopedRotation(forProvider: "unknown"),
            "未知 provider 不得轮换"
        )
    }

    /// kimi: API key 不参与 OAuth 轮换.
    static func rotationMergeKimiRejected() throws {
        let merged = CredentialRotationMerge.mergedAccountJSON(
            existingCredentialJSON: #"{"access_token":"old-a"}"#,
            update: CredentialRotationUpdate(
                provider: "kimi",
                accountId: "default",
                tokens: ["access_token": "new-a", "refresh_token": "new-r"]
            ),
            providerID: .kimi
        )
        try coreExpect(merged == nil, "kimi 不轮换必须返回 nil, got \(merged ?? "nil")")
    }

    /// Codex 令牌链由 CodexTokenManager 独占, rotation 条目被明确拒绝.
    static func rotationMergeCodexRejected() throws {
        let merged = CredentialRotationMerge.mergedAccountJSON(
            existingCredentialJSON: nil,
            update: CredentialRotationUpdate(
                provider: "codex",
                accountId: "acc-1",
                tokens: ["access_token": "na", "refresh_token": "nr"]
            ),
            providerID: .codex
        )
        try coreExpect(
            merged == nil,
            "codex 轮换写回必须被拒绝, got \(merged ?? "nil")"
        )
    }

    /// 白名单外键被过滤; 空令牌返回 nil.
    static func rotationMergeFiltersKeysAndRejectsUnknown() throws {
        let merged = CredentialRotationMerge.mergedAccountJSON(
            existingCredentialJSON: #"{"keep":"yes"}"#,
            update: CredentialRotationUpdate(
                provider: "claude",
                accountId: "default",
                tokens: ["access_token": "a", "evil": "x"]
            ),
            providerID: .claude
        )
        try coreExpect(
            merged == #"{"access_token":"a","keep":"yes"}"#,
            "白名单外键必须过滤, got \(merged ?? "nil")"
        )
        try coreExpect(
            CredentialRotationMerge.mergedAccountJSON(
                existingCredentialJSON: nil,
                update: CredentialRotationUpdate(
                    provider: "claude", accountId: "default",
                    tokens: ["access_token": "a"]
                ),
                providerID: .claude
            ) != nil,
            "有效令牌必须生成新 JSON"
        )
        try coreExpect(
            CredentialRotationMerge.mergedAccountJSON(
                existingCredentialJSON: nil,
                update: CredentialRotationUpdate(
                    provider: "claude", accountId: "default",
                    tokens: ["access_token": ""]
                ),
                providerID: .claude
            ) == nil,
            "空令牌必须返回 nil"
        )
    }

    // MARK: - 任务 5: 登录接入与账号发现

    /// 永不触发的 stub OAuth 客户端 (登录测试只验证入库, 不发起网络).
    final class StubOAuthClient: CodexOAuthClientProtocol {
        func refreshRequest(refreshToken: String) -> URLRequest {
            URLRequest(url: URL(string: "https://example.invalid/token")!)
        }
        func perform(
            _ request: URLRequest,
            session: (any URLSessionProtocol)?
        ) async -> Result<CodexTokenResponse, CodexOAuthClientError> {
            .failure(.networkUnreachable)
        }
    }

    /// 1. Bruce 设备码登录成功后写入 credentialOrigin=Bruce 的完整 v2 记录.
    static func codexLoginStoresCompleteV2Record() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let client = StubOAuthClient()
        let manager = CodexTokenManager(store: store, client: client)
        let idToken = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-7"],
            "email": "login@example.com",
        ])
        let tokens = CodexDeviceFlow.TokenSet(
            idToken: idToken,
            accessToken: "at-login",
            refreshToken: "rt-login",
            expiresIn: 3600,
            receivedAt: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let accountID = CodexIDTokenParser.accountID(of: tokens.idToken)
        try coreExpect(accountID == "acct-7", "账号 id 解析失败")
        try await manager.storeLoginResult(
            accountID: accountID!,
            email: "login@example.com",
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            expiresAt: tokens.receivedAt.addingTimeInterval(tokens.expiresIn ?? 0)
        )
        let record = try store.loadRecord(for: "acct-7")
        try coreExpect(record != nil, "v2 记录必须存在")
        try coreExpect(record?.credentialOrigin == .Bruce, "来源必须为 Bruce")
        try coreExpect(record?.authorizationState == .connected, "必须为已连接")
        try coreExpect(record?.accessToken == "at-login", "access token 不符")
        try coreExpect(record?.refreshToken == "rt-login", "refresh token 不符")
        try coreExpect(record?.email == "login@example.com", "email 不符")
        // 旧整体账号库键不得写入
        let legacy = try memory.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try coreExpect(legacy == nil, "登录不得写旧整体账号库")
        // 完整令牌不进入 v2 索引
        let index = try store.loadIndex()
        try coreExpect(index.accounts.count == 1, "索引账号数不符")
        try coreExpect(
            index.accounts.first?.email == "login@example.com",
            "索引 email 不符"
        )
    }

    /// 2. CC Switch 发现只保存账号元数据, 状态为 needsReauthorization.
    static func ccSwitchDiscoveryKeepsMetadataOnly() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let json = """
            {"accounts": {
              "acct-a": {"email": "a@example.com",
                         "refresh_token": "rt-a", "access_token": "at-a"},
              "acct-b": {"email": "b@example.com",
                         "refresh_token": "rt-b", "access_token": "at-b"}
            }}
            """
        let discovered = try CodexDiscovery.fromCCSwitchAccountsJSON(json)
        try coreExpect(discovered.count == 2, "CC Switch 账号数不符")
        try coreExpect(
            discovered.allSatisfy { $0.authorizationState == .needsReauthorization },
            "发现账号必须为 needsReauthorization"
        )
        try coreExpect(
            discovered.allSatisfy { $0.credentialOrigin == .legacyCCSwitchDiscovery },
            "发现账号来源必须为 legacyCCSwitchDiscovery"
        )
        try store.saveDiscoveredAccounts(discovered, now: Date(timeIntervalSince1970: 1_752_000_000))
        let record = try store.loadRecord(for: "acct-a")
        try coreExpect(record != nil, "记录必须存在")
        try coreExpect(record?.email == "a@example.com", "email 不符")
        try coreExpect(record?.accessToken == nil, "不得保存 access token")
        try coreExpect(record?.refreshToken == nil, "不得保存 refresh token")
        try coreExpect(record?.authorizationState == .needsReauthorization, "状态不符")
        // 旧整体账号库键不得写入
        let legacy = try memory.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try coreExpect(legacy == nil, "发现不得写旧整体账号库")
        let index = try store.loadIndex()
        try coreExpect(index.accounts.count == 2, "索引账号数不符")
    }

    /// 3. Codex CLI 发现同样只保存元数据, 不导入 token.
    static func cliDiscoveryKeepsMetadataOnly() throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let json = """
            {"tokens": {
              "account_id": "acct-c",
              "refresh_token": "rt-c",
              "access_token": "at-c",
              "id_token": "id-c",
              "email": "c@example.com"
            }}
            """
        let discovered = try CodexDiscovery.fromCLIAuthJSON(json)
        try coreExpect(discovered.count == 1, "CLI 账号数不符")
        try coreExpect(
            discovered.allSatisfy { $0.authorizationState == .needsReauthorization },
            "CLI 发现账号必须为 needsReauthorization"
        )
        try coreExpect(
            discovered.allSatisfy { $0.credentialOrigin == .legacyCCSwitchDiscovery },
            "CLI 发现来源不符"
        )
        try store.saveDiscoveredAccounts(discovered, now: Date(timeIntervalSince1970: 1_752_000_000))
        let record = try store.loadRecord(for: "acct-c")
        try coreExpect(record?.email == "c@example.com", "email 不符")
        try coreExpect(record?.accessToken == nil, "不得保存 access token")
        try coreExpect(record?.refreshToken == nil, "不得保存 refresh token")
        try coreExpect(record?.idToken == nil, "不得保存 id token")
        // CLI 认证文件键不得写入 Keychain
        let legacy = try memory.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try coreExpect(legacy == nil, "CLI 发现不得写旧整体账号库")
    }

    /// 4. “发现”不会修改被读取文件的内容哈希、大小和修改时间.
    static func discoveryNeverWritesSourceFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let ccURL = tempDir.appendingPathComponent("codex_oauth_auth.json")
        let ccJSON = """
            {"accounts": {
              "acct-a": {"email": "a@example.com",
                         "refresh_token": "rt-a", "access_token": "at-a"}
            }}
            """
        try Data(ccJSON.utf8).write(to: ccURL)
        let cliURL = tempDir.appendingPathComponent("auth.json")
        let cliJSON = """
            {"tokens": {
              "account_id": "acct-c",
              "refresh_token": "rt-c",
              "access_token": "at-c"
            }}
            """
        try Data(cliJSON.utf8).write(to: cliURL)

        let ccBefore = try snapshot(of: ccURL)
        let cliBefore = try snapshot(of: cliURL)
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        _ = try store.discoverAccountsFromFiles(
            ccSwitchURL: ccURL, cliAuthURL: cliURL, now: Date(timeIntervalSince1970: 1_752_000_000)
        )
        let ccAfter = try snapshot(of: ccURL)
        let cliAfter = try snapshot(of: cliURL)
        try coreExpect(ccAfter == ccBefore, "CC Switch 文件被修改")
        try coreExpect(cliAfter == cliBefore, "CLI 认证文件被修改")
    }

    static func snapshot(of url: URL) throws -> (Data, UInt64, Date) {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (
            data,
            (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            (attributes[.modificationDate] as? Date) ?? Date.distantPast
        )
    }

    /// 5. 重新授权只替换当前账号记录, 不覆盖其他账号.
    static func reauthorizationReplacesOnlyCurrentAccount() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        try store.saveDiscoveredAccounts(
            [CodexDiscovery.Account(
                accountID: "acct-a", email: "a@example.com",
                authorizationState: .needsReauthorization,
                credentialOrigin: .legacyCCSwitchDiscovery
            )],
            now: now
        )
        try store.saveRecord(CodexAccountRecord(
            accountID: "acct-b",
            email: "b@example.com",
            accessToken: "at-b",
            refreshToken: "rt-b",
            accessTokenExpiresAt: now.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: now
        ))
        // 重新授权 acct-a: 替换该账号记录
        try store.saveRecord(CodexAccountRecord(
            accountID: "acct-a",
            email: "a@example.com",
            accessToken: "at-a-new",
            refreshToken: "rt-a-new",
            accessTokenExpiresAt: now.addingTimeInterval(3600),
            authorizationState: .connected,
            credentialOrigin: .Bruce,
            updatedAt: now
        ))
        let recordA = try store.loadRecord(for: "acct-a")
        try coreExpect(recordA?.accessToken == "at-a-new", "acct-a 未被替换")
        try coreExpect(recordA?.credentialOrigin == .Bruce, "acct-a 来源未更新")
        let recordB = try store.loadRecord(for: "acct-b")
        try coreExpect(recordB?.accessToken == "at-b", "acct-b 被覆盖")
        try coreExpect(recordB?.refreshToken == "rt-b", "acct-b 被覆盖")
        let index = try store.loadIndex()
        try coreExpect(index.accounts.count == 2, "索引账号数不符")
    }

    /// 6. 断开账号删除 Bruce Keychain 记录, 不写第三方文件.
    static func disconnectRemovesRecordButKeepsOthers() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let now = Date(timeIntervalSince1970: 1_752_000_000)
        for (id, email) in ["acct-a": "a@example.com", "acct-b": "b@example.com"] {
            try store.saveRecord(CodexAccountRecord(
                accountID: id,
                email: email,
                accessToken: "at-\(id)",
                refreshToken: "rt-\(id)",
                accessTokenExpiresAt: now.addingTimeInterval(3600),
                authorizationState: .connected,
                credentialOrigin: .Bruce,
                updatedAt: now
            ))
        }
        try store.deleteRecord(for: "acct-a")
        let recordA = try store.loadRecord(for: "acct-a")
        try coreExpect(recordA == nil, "acct-a 记录必须删除")
        let recordB = try store.loadRecord(for: "acct-b")
        try coreExpect(recordB?.accessToken == "at-acct-b", "acct-b 必须保留")
        let keychainKeyA = CodexCredentialKeys.accountKey(for: "acct-a")
        let keychainValueA = try memory.loadCredential(forAccount: keychainKeyA)
        try coreExpect(keychainValueA == nil, "Keychain 项必须删除")
        let index = try store.loadIndex()
        try coreExpect(index.accounts.count == 1, "索引必须只保留 acct-b")
        try coreExpect(index.accounts.first?.accountID == "acct-b", "索引剩余账号不符")
    }

}
