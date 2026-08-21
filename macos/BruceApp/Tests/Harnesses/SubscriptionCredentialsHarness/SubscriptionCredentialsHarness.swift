import Foundation
import BruceOnboardingCore
@testable import BruceAppCore

private enum CredentialsTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func credentialsExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw CredentialsTestFailure.expectation(message)
    }
}

/// saveCredential 恒抛错的 fake store, 用于验证 Coordinator 失败路径.
private final class ThrowingCredentialStore: CredentialStore, @unchecked Sendable {
    func loadCredential(forAccount account: String) throws -> String? { nil }

    func saveCredential(_ value: String, forAccount account: String) throws {
        throw NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "keychain denied",
        ])
    }

    func deleteCredential(forAccount account: String) throws {}
}

/// 订阅凭证注入链路测试 (Phase 5) + CredentialUpdateCoordinator (Task 3):
/// OnboardingRunInputProvider 对 claude/grok 的凭证注入语义.
/// - 应用持有 claude:oauth/grok:oauth 时注入 claudeOAuth/grokOAuth
/// - 无应用凭证时仅注入 providerMeta enabled 标记 (collector 回退本机)
/// - 禁用 provider 时两者皆无
/// - Coordinator: save 失败记 failed; codex 跳过; 成功写回可加载
@main
@MainActor
struct SubscriptionCredentialsHarness {
    static func main() async throws {
        try await claudeInjectedWhenCredentialPresent()
        try await grokInjectedWhenCredentialPresent()
        try await claudeFallbackToMetaWhenNoCredential()
        try await grokFallbackToMetaWhenNoCredential()
        try await noInjectionWhenProviderDisabled()
        try await nonCredentialProvidersUnaffected()
        try coordinatorSaveFailureRecordsFailed()
        try coordinatorSkipsCodexWithoutSave()
        try coordinatorSkipsKimiRotation()
        try coordinatorSkipsBadShapeAndUnknownProvider()
        try providerAccountStoreAddRemoveAndIndex()
        try providerAccountStoreDuplicateRejected()
        try providerAccountStoreUpdateAuthorizationState()
        try providerAccountStoreHasConnectedAndCount()
        try providerAccountStoreLegacyKeyMigration()
        try providerAccountStoreMigrationSkipsWithExistingIndex()
        try providerAccountStoreCleanupAfterMigration()
        try coordinatorRotationMultiAccountWritesPerAccountRecord()
        try coordinatorRotationMultiAccountUnknownAccountFallsBack()
        try providerAccountSummariesExposeNonSensitiveInfo()
        try providerAccountStoreRemoveLastAccountKeepsEmptyIndex()
        try providerAccountStoreUpsertUpdatesExisting()
        try providerAccountStoreWriteThenConnected()
        try await opencodeGoInjectedWhenCredentialPresent()
        try await opencodeGoNotInjectedWithoutCredential()
        try coordinatorRotationOpenCodeGo()
        try await zhipuInjectedWhenCredentialPresent()
        try await zhipuNotInjectedWithoutCredential()
        print("Subscription credentials tests passed: 28")
    }

    /// 构造 OnboardingRunInputProvider: 配置 claude 启用 + Keychain 持有 claude:oauth.
    private static func makeProvider(
        enabled: [SubscriptionProviderID],
        credentials: [String: String]
    ) throws -> (OnboardingRunInputProvider, InMemoryCredentialStore, OnboardingConfigurationStore) {
        let store = InMemoryCredentialStore()
        for (account, value) in credentials {
            try store.saveCredential(value, forAccount: account)
        }
        let configStore = try OnboardingConfigurationStore(
            configDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("cred-harness-\(UUID().uuidString)", isDirectory: true)
        )
        var config = OnboardingConfiguration()
        config.consentVersion = 1
        for id in enabled {
            var entry = SubscriptionProviderConfiguration()
            entry.enabled = true
            config.subscriptionProviders[id.rawValue] = entry
        }
        try configStore.save(config)
        let provider = OnboardingRunInputProvider(
            configStore: configStore,
            credentialStore: store
        )
        return (provider, store, configStore)
    }

    /// 执行 agentUsageInput, 返回 (context, credentials).
    private static func runInput(
        _ provider: OnboardingRunInputProvider
    ) async throws -> ([String: JSONValue], [String: JSONValue]) {
        let input = try await provider.runInput(for: .agentUsage)
        return (input.context, input.credentials)
    }

    private static func claudeInjectedWhenCredentialPresent() async throws {
        let claudeJSON = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        let (provider, _, _) = try makeProvider(
            enabled: [.claude],
            credentials: [SubscriptionCredentialAccount.claudeOAuth: claudeJSON]
        )
        let (_, credentials) = try await runInput(provider)
        // 多账号注入格式: claudeQuotaAccounts 字典
        guard case .object(let accounts)? = credentials["claudeQuotaAccounts"] else {
            throw CredentialsTestFailure.expectation("claudeQuotaAccounts 未注入: \(credentials.keys.sorted())")
        }
        try credentialsExpect(accounts.count == 1, "claude 应有 1 个账号")
        guard case .object(let payload)? = accounts.values.first,
              case .object(let oauth)? = payload["oauth"] else {
            throw CredentialsTestFailure.expectation("claude oauth 结构不符")
        }
        try credentialsExpect(
            oauth["claudeAiOauth"] != nil,
            "claudeQuotaAccounts 应包含 claudeAiOauth 节点"
        )
        guard case .object(let meta)? = credentials["providerMeta"],
              case .object(let claudeMeta)? = meta["claude"] else {
            throw CredentialsTestFailure.expectation("providerMeta.claude 缺失")
        }
        try credentialsExpect(
            claudeMeta["enabled"] != nil,
            "providerMeta.claude.enabled 应保留"
        )
    }

    private static func grokInjectedWhenCredentialPresent() async throws {
        let grokJSON = #"{"https://auth.x.ai::injected":{"key":"gk"}}"#
        let (provider, _, _) = try makeProvider(
            enabled: [.grok],
            credentials: [SubscriptionCredentialAccount.grokOAuth: grokJSON]
        )
        let (_, credentials) = try await runInput(provider)
        guard case .object(let accounts)? = credentials["grokQuotaAccounts"] else {
            throw CredentialsTestFailure.expectation("grokQuotaAccounts 未注入: \(credentials.keys.sorted())")
        }
        try credentialsExpect(accounts.count == 1, "grok 应有 1 个账号")
        guard case .object(let payload)? = accounts.values.first,
              case .object(let oauth)? = payload["oauth"] else {
            throw CredentialsTestFailure.expectation("grok oauth 结构不符")
        }
        try credentialsExpect(
            oauth["https://auth.x.ai::injected"] != nil,
            "grokQuotaAccounts 应包含 scope 条目"
        )
    }

    private static func opencodeGoInjectedWhenCredentialPresent() async throws {
        let goJSON = #"{"auth":"Fe26.2**abc","workspaceId":"wrk_01"}"#
        let (provider, _, _) = try makeProvider(
            enabled: [.opencodeGo],
            credentials: [SubscriptionCredentialAccount.opencodeGoOAuth: goJSON]
        )
        let (_, credentials) = try await runInput(provider)
        guard case .object(let accounts)? = credentials["opencodeGoQuotaAccounts"] else {
            throw CredentialsTestFailure.expectation("opencodeGoQuotaAccounts 未注入: \(credentials.keys.sorted())")
        }
        try credentialsExpect(accounts.count == 1, "opencodeGo 应有 1 个账号")
        guard case .object(let payload)? = accounts.values.first,
              case .object(let oauth)? = payload["oauth"] else {
            throw CredentialsTestFailure.expectation("opencodeGo oauth 结构不符")
        }
        try credentialsExpect(
            oauth["auth"] != nil && oauth["workspaceId"] != nil,
            "opencodeGoQuotaAccounts 应包含 auth/workspaceId"
        )
    }

    private static func opencodeGoNotInjectedWithoutCredential() async throws {
        let (provider, _, _) = try makeProvider(
            enabled: [.opencodeGo],
            credentials: [:]
        )
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["opencodeGoQuotaAccounts"] == nil,
            "无应用凭证时不应注入 opencodeGoQuotaAccounts"
        )
    }

    private static func zhipuInjectedWhenCredentialPresent() async throws {
        let (provider, _, _) = try makeProvider(
            enabled: [.zhipu],
            credentials: [
                SubscriptionCredentialAccount.zhipuAPIKey: "id.secret",
                SubscriptionCredentialAccount.zhipuBaseURL: "https://open.bigmodel.cn/api/paas/v4",
            ]
        )
        let (_, credentials) = try await runInput(provider)
        guard case .object(let accounts)? = credentials["zhipuQuotaAccounts"] else {
            throw CredentialsTestFailure.expectation("zhipuQuotaAccounts 未注入: \(credentials.keys.sorted())")
        }
        try credentialsExpect(accounts.count == 1, "zhipu 应有 1 个账号")
        guard case .object(let payload)? = accounts.values.first else {
            throw CredentialsTestFailure.expectation("zhipu 账号 payload 结构不符")
        }
        try credentialsExpect(
            payload["api_key"] != nil && payload["base_url"] != nil,
            "zhipuQuotaAccounts 应包含 api_key/base_url"
        )
        if case .string(let key)? = payload["api_key"] {
            try credentialsExpect(key == "id.secret", "api_key 应透传")
        } else {
            throw CredentialsTestFailure.expectation("api_key 应为字符串")
        }
        if case .string(let base)? = payload["base_url"] {
            try credentialsExpect(
                base == "https://open.bigmodel.cn/api/paas/v4",
                "base_url 应透传"
            )
        } else {
            throw CredentialsTestFailure.expectation("base_url 应为字符串")
        }
    }

    private static func zhipuNotInjectedWithoutCredential() async throws {
        let (provider, _, _) = try makeProvider(enabled: [.zhipu], credentials: [:])
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["zhipuQuotaAccounts"] == nil,
            "无凭证时不应注入 zhipuQuotaAccounts"
        )
    }

    private static func claudeFallbackToMetaWhenNoCredential() async throws {
        let (provider, _, _) = try makeProvider(
            enabled: [.claude],
            credentials: [:]
        )
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["claudeQuotaAccounts"] == nil,
            "无应用凭证时不应注入 claudeQuotaAccounts"
        )
        guard case .object(let meta)? = credentials["providerMeta"],
              case .object(let claudeMeta)? = meta["claude"] else {
            throw CredentialsTestFailure.expectation("providerMeta.claude 缺失")
        }
        try credentialsExpect(
            claudeMeta["enabled"] != nil,
            "无凭证时仍应注入 enabled 标记 (collector 回退本机)"
        )
    }

    private static func grokFallbackToMetaWhenNoCredential() async throws {
        let (provider, _, _) = try makeProvider(
            enabled: [.grok],
            credentials: [:]
        )
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["grokQuotaAccounts"] == nil,
            "无应用凭证时不应注入 grokQuotaAccounts"
        )
        guard case .object(let meta)? = credentials["providerMeta"],
              case .object(let grokMeta)? = meta["grok"] else {
            throw CredentialsTestFailure.expectation("providerMeta.grok 缺失")
        }
        try credentialsExpect(
            grokMeta["enabled"] != nil,
            "无凭证时仍应注入 enabled 标记 (collector 回退本机)"
        )
    }

    private static func noInjectionWhenProviderDisabled() async throws {
        let claudeJSON = #"{"claudeAiOauth":{"accessToken":"tok"}}"#
        let grokJSON = #"{"https://auth.x.ai::injected":{"key":"gk"}}"#
        let (provider, _, _) = try makeProvider(
            enabled: [],
            credentials: [
                SubscriptionCredentialAccount.claudeOAuth: claudeJSON,
                SubscriptionCredentialAccount.grokOAuth: grokJSON,
            ]
        )
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["claudeQuotaAccounts"] == nil && credentials["grokQuotaAccounts"] == nil,
            "禁用 provider 时不应注入任何凭证"
        )
        try credentialsExpect(
            credentials["providerMeta"] == nil,
            "禁用 provider 时不应注入 providerMeta"
        )
    }

    private static func nonCredentialProvidersUnaffected() async throws {
        let kimiKey = "kimi-fixture-key"
        let (provider, _, _) = try makeProvider(
            enabled: [.kimi],
            credentials: [SubscriptionCredentialAccount.kimiAPIKey: kimiKey]
        )
        let (_, credentials) = try await runInput(provider)
        guard case .object(let accounts)? = credentials["kimiQuotaAccounts"] else {
            throw CredentialsTestFailure.expectation("kimiQuotaAccounts 未注入: \(credentials.keys.sorted())")
        }
        try credentialsExpect(accounts.count == 1, "kimi 应有 1 个账号")
        try credentialsExpect(
            credentials["claudeQuotaAccounts"] == nil && credentials["grokQuotaAccounts"] == nil,
            "kimi 启用时不应注入 claude/grok 凭证"
        )
    }

    // MARK: - CredentialUpdateCoordinator (Task 3)

    /// 构造 oauthTokens/replace 条目.
    private static func oauthUpdate(
        provider: String,
        accountId: String = "default",
        tokens: [String: String]
    ) -> JSONValue {
        .object([
            "provider": .string(provider),
            "kind": .string("oauthTokens"),
            "operation": .string("replace"),
            "accountId": .string(accountId),
            "credentials": .object(
                Dictionary(uniqueKeysWithValues: tokens.map { ($0.key, .string($0.value)) })
            ),
        ])
    }

    /// saveCredential 抛错 → failed 计数, applied 为 0; reason 不含 token 明文.
    private static func coordinatorSaveFailureRecordsFailed() throws {
        let secretToken = "rotated-secret-token-value-xyz"
        let coordinator = CredentialUpdateCoordinator(
            credentialStore: ThrowingCredentialStore()
        )
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "antigravity",
                accountId: "acc-kimi-1",
                tokens: [
                    "access_token": secretToken,
                    "refresh_token": "rt-\(secretToken)",
                ]
            ),
        ])
        try credentialsExpect(result.appliedCount == 0, "抛错时 applied 应为 0")
        try credentialsExpect(result.skippedCount == 0, "有效条目不应记 skipped")
        try credentialsExpect(result.failed.count == 1, "应记录 1 条 failed")
        let failure = result.failed[0]
        try credentialsExpect(failure.provider == "antigravity", "failed.provider 应为 antigravity")
        try credentialsExpect(
            failure.accountId == "acc-kimi-1",
            "failed.accountId 应保留"
        )
        try credentialsExpect(
            failure.reason == "keychain denied",
            "reason 应为错误描述, got \(failure.reason)"
        )
        try credentialsExpect(
            !failure.reason.contains(secretToken),
            "failure.reason 不得包含 token 明文"
        )
    }

    /// codex rotation 明确跳过, 不写 Keychain.
    private static func coordinatorSkipsCodexWithoutSave() throws {
        let store = InMemoryCredentialStore()
        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "codex",
                accountId: "acc-1",
                tokens: [
                    "refresh_token": "rotated-rt",
                    "access_token": "rotated-at",
                ]
            ),
        ])
        try credentialsExpect(result.appliedCount == 0, "codex 不得 applied")
        try credentialsExpect(result.skippedCount == 1, "codex 应记 skipped")
        try credentialsExpect(result.failed.isEmpty, "codex 不是 failed")
        let stored = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try credentialsExpect(stored == nil, "Codex rotation 不得写回 Keychain")
        let legacy = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexLegacyAccounts
        )
        try credentialsExpect(legacy == nil, "Codex rotation 不得写旧库")
    }

    /// kimi 不参与 OAuth 轮换, 更新必须被跳过.
    private static func coordinatorSkipsKimiRotation() throws {
        let store = InMemoryCredentialStore()
        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "kimi",
                tokens: [
                    "access_token": "new-a",
                    "refresh_token": "new-r",
                ]
            ),
        ])
        try credentialsExpect(result.appliedCount == 0, "kimi 轮换必须跳过")
        try credentialsExpect(result.skippedCount == 1, "kimi 轮换应 skipped=1")
        try credentialsExpect(result.failed.isEmpty, "kimi 轮换不是 failed")
    }

    /// 坏形状与未知 provider 记 skipped, 不写 store.
    private static func coordinatorSkipsBadShapeAndUnknownProvider() throws {
        let store = InMemoryCredentialStore()
        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            .string("not-an-object"),
            .object([
                "provider": .string("kimi"),
                "kind": .string("other"),
                "operation": .string("replace"),
                "credentials": .object(["access_token": .string("a")]),
            ]),
            oauthUpdate(
                provider: "deepseek",
                tokens: ["access_token": "ds-token"]
            ),
        ])
        try credentialsExpect(result.appliedCount == 0, "坏条目不得 applied")
        try credentialsExpect(
            result.skippedCount == 3,
            "坏形状/未知 provider 应全记 skipped, got \(result.skippedCount)"
        )
        try credentialsExpect(result.failed.isEmpty, "坏条目不是 failed")
        let kimi = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.kimiAPIKey
        )
        try credentialsExpect(kimi == nil, "坏条目不得写入 kimi")
    }

    // MARK: - ProviderAccountStore 测试

    /// 添加、移除账号, 验证 index 和 record 读写.
    private static func providerAccountStoreAddRemoveAndIndex() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .kimi, credentialStore: credStore)

        // 空索引
        let emptyIndex = try store.loadIndex()
        try credentialsExpect(emptyIndex.accounts.isEmpty, "初始索引应为空")

        // 添加账号
        let added = try store.addAccount(
            accountID: "abc123",
            displayName: "Kimi · personal",
            credentialJSON: "{\"access_token\":\"tok_a\",\"refresh_token\":\"tok_b\"}"
        )
        try credentialsExpect(added, "添加新账号应返回 true")

        // 验证 index
        let index = try store.loadIndex()
        try credentialsExpect(index.accounts.count == 1, "索引应有 1 条: \(index.accounts.count)")
        try credentialsExpect(index.accounts[0].accountID == "abc123", "accountID 不匹配")
        try credentialsExpect(index.accounts[0].displayName == "Kimi · personal", "displayName 不匹配")

        // 验证 record
        let record = try store.loadRecord(for: "abc123")
        try credentialsExpect(record != nil, "record 应存在")
        try credentialsExpect(record?.credentialJSON.contains("tok_a") == true, "凭证内容不匹配")
        try credentialsExpect(record?.authorizationState == .needsReauthorization, "初始状态应为 needsReauthorization")

        // 添加第二个账号
        _ = try store.addAccount(
            accountID: "def456",
            displayName: "Kimi · work",
            credentialJSON: "{\"access_token\":\"tok_c\",\"refresh_token\":\"tok_d\"}"
        )
        let count2 = try store.accountCount(); try credentialsExpect(count2 == 2, "应有 2 个账号")

        // 移除第一个账号
        try store.removeAccount(accountID: "abc123")
        let count1 = try store.accountCount(); try credentialsExpect(count1 == 1, "移除后应有 1 个账号")
        let afterRemove = try store.loadIndex()
        try credentialsExpect(afterRemove.accounts[0].accountID == "def456", "剩余账号应为 def456")
        let removedRecord = try store.loadRecord(for: "abc123")
        try credentialsExpect(removedRecord == nil, "移除的账号 record 应不存在")
    }

    /// 重复 accountID 被拒绝.
    private static func providerAccountStoreDuplicateRejected() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .deepseek, credentialStore: credStore)

        _ = try store.addAccount(
            accountID: "sk-12345",
            displayName: "DeepSeek · 1",
            credentialJSON: "sk-1234567890"
        )
        let duplicate = try store.addAccount(
            accountID: "sk-12345",
            displayName: "DeepSeek · 2",
            credentialJSON: "sk-different"
        )
        try credentialsExpect(!duplicate, "重复 accountID 应返回 false")
        let dupCount = try store.accountCount(); try credentialsExpect(dupCount == 1, "重复添加后仍应只有 1 个账号")

        // 原始凭证未被覆盖
        let record = try store.loadRecord(for: "sk-12345")
        try credentialsExpect(record?.credentialJSON == "sk-1234567890", "原始凭证不应被覆盖")
    }

    /// 更新账号授权状态.
    private static func providerAccountStoreUpdateAuthorizationState() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .claude, credentialStore: credStore)

        _ = try store.addAccount(
            accountID: "a1b2c3d4e5f6g7h8",
            displayName: "Claude · personal",
            credentialJSON: "{\"claudeAiOauth\":{\"accessToken\":\"tok\"}}"
        )

        try store.updateAuthorizationState(.connected, for: "a1b2c3d4e5f6g7h8")
        let index = try store.loadIndex()
        try credentialsExpect(
            index.accounts[0].authorizationState == .connected,
            "index 状态应为 connected"
        )
        let record = try store.loadRecord(for: "a1b2c3d4e5f6g7h8")
        try credentialsExpect(
            record?.authorizationState == .connected,
            "record 状态应为 connected"
        )

        // hasConnectedAccount
        let hasConnected = try store.hasConnectedAccount()
        try credentialsExpect(hasConnected == true, "应有 connected 账号")

        // 改回 needsReauthorization
        try store.updateAuthorizationState(.needsReauthorization, for: "a1b2c3d4e5f6g7h8")
        let hasConnectedAfter = try store.hasConnectedAccount()
        try credentialsExpect(hasConnectedAfter == false, "无 connected 账号时应返回 false")
    }

    /// hasConnectedAccount 和 accountCount.
    private static func providerAccountStoreHasConnectedAndCount() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .grok, credentialStore: credStore)

        let emptyCount = try store.accountCount(); try credentialsExpect(emptyCount == 0, "空 store count 应为 0")
        let emptyHasConnected = try store.hasConnectedAccount()
        try credentialsExpect(emptyHasConnected == false, "空 store 无 connected")

        _ = try store.addAccount(
            accountID: "grok-001",
            displayName: "Grok · 1",
            credentialJSON: "{\"key\":\"k1\"}"
        )
        _ = try store.addAccount(
            accountID: "grok-002",
            displayName: "Grok · 2",
            credentialJSON: "{\"key\":\"k2\"}"
        )

        let count2 = try store.accountCount(); try credentialsExpect(count2 == 2, "应有 2 个账号")
        try store.updateAuthorizationState(.connected, for: "grok-002")
        let grokHasConnected = try store.hasConnectedAccount()
        try credentialsExpect(grokHasConnected == true, "应有 connected 账号")
    }

    /// 旧单条凭证迁移: 读取旧 Keychain 键, 写入 account-index + record.
    private static func providerAccountStoreLegacyKeyMigration() throws {
        let credStore = InMemoryCredentialStore()

        // 模拟旧 DeepSeek 单条凭证
        let oldKey = SubscriptionCredentialAccount.deepseekAPIKey
        try credStore.saveCredential("sk-legacy1234", forAccount: oldKey)

        // 迁移: 用旧键值创建 account + record
        let store = ProviderAccountStore(provider: .deepseek, credentialStore: credStore)
        let accountID = ProviderAccountIDGenerator.deepseekAccountID(apiKey: "sk-legacy1234")
        let migrated = try store.addAccount(
            accountID: accountID,
            displayName: "DeepSeek · \(accountID)",
            credentialJSON: "sk-legacy1234"
        )
        try credentialsExpect(migrated, "迁移应成功添加账号")

        // 验证新 record
        let record = try store.loadRecord(for: accountID)
        try credentialsExpect(record?.credentialJSON == "sk-legacy1234", "迁移后凭证应匹配")

        // 验证旧键仍存在 (迁移后下次启动才删除)
        let oldVal = try credStore.loadCredential(forAccount: oldKey)
        try credentialsExpect(oldVal == "sk-legacy1234", "旧键在迁移后应仍存在")

        // 迁移后删除旧键
        try credStore.deleteCredential(forAccount: oldKey)
        let oldAfterDelete = try credStore.loadCredential(forAccount: oldKey)
        try credentialsExpect(oldAfterDelete == nil, "旧键删除后应为 nil")

        // 新 record 仍可用
        let recordAfterCleanup = try store.loadRecord(for: accountID)
        try credentialsExpect(recordAfterCleanup != nil, "删除旧键后新 record 应仍可用")
    }

    /// 已有 index 的 provider 不重复迁移.
    private static func providerAccountStoreMigrationSkipsWithExistingIndex() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .deepseek, credentialStore: credStore)

        // 先手动添加一个账号
        _ = try store.addAccount(
            accountID: "manual01",
            displayName: "DeepSeek · manual",
            credentialJSON: "sk-manualkey1"
        )

        // 模拟旧键存在
        let oldKey = SubscriptionCredentialAccount.deepseekAPIKey
        try credStore.saveCredential("sk-legacy999", forAccount: oldKey)

        // 迁移应跳过 (index 已有账号)
        let index = try store.loadIndex()
        try credentialsExpect(index.accounts.count == 1, "不应重复迁移: \(index.accounts.count)")
        try credentialsExpect(index.accounts[0].accountID == "manual01", "应保留手动添加的账号")

        // 旧键仍存在 (未被迁移消费)
        let oldVal = try credStore.loadCredential(forAccount: oldKey)
        try credentialsExpect(oldVal == "sk-legacy999", "旧键应未被迁移消费")
    }

    /// 迁移成功后清理旧键.
    private static func providerAccountStoreCleanupAfterMigration() throws {
        let credStore = InMemoryCredentialStore()

        // 模拟旧 Kimi 凭证
        let oldKey = SubscriptionCredentialAccount.kimiAPIKey
        let kimiKey = "kimi-legacy-key"
        try credStore.saveCredential(kimiKey, forAccount: oldKey)

        let store = ProviderAccountStore(provider: .kimi, credentialStore: credStore)

        // 迁移: 读取旧键, 添加账号
        let accountID = ProviderAccountIDGenerator.kimiAccountID(apiKey: kimiKey)
        _ = try store.addAccount(
            accountID: accountID,
            displayName: "Kimi · \(accountID)",
            credentialJSON: kimiKey
        )
        try store.updateAuthorizationState(.connected, for: accountID)

        // 验证迁移成功
        let index = try store.loadIndex()
        try credentialsExpect(index.accounts.count == 1, "迁移后应有 1 个账号")
        try credentialsExpect(
            index.accounts[0].authorizationState == .connected,
            "迁移后状态应为 connected"
        )

        // 清理旧键 (模拟 cleanupLegacyCredentials)
        try credStore.deleteCredential(forAccount: oldKey)
        let oldAfterCleanup = try credStore.loadCredential(forAccount: oldKey)
        try credentialsExpect(oldAfterCleanup == nil, "清理后旧键应为 nil")

        // 新 record 仍可用
        let record = try store.loadRecord(for: accountID)
        try credentialsExpect(record?.credentialJSON == kimiKey, "清理后 record 应仍可用")
        try credentialsExpect(
            record?.authorizationState == .connected,
            "清理后状态应仍为 connected"
        )
    }

    /// 多账号轮换: 按 accountId 写回 per-account record, 不影响其他账号.
    private static func coordinatorRotationMultiAccountWritesPerAccountRecord() throws {
        let store = InMemoryCredentialStore()
        let accountStore = ProviderAccountStore(provider: .claude, credentialStore: store)
        _ = try accountStore.addAccount(
            accountID: "acct-a",
            displayName: "Claude · a",
            credentialJSON: "{\"claudeAiOauth\":{\"accessToken\":\"old-a\"}}"
        )
        _ = try accountStore.addAccount(
            accountID: "acct-b",
            displayName: "Claude · b",
            credentialJSON: "{\"claudeAiOauth\":{\"accessToken\":\"keep-b\"}}"
        )

        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "claude",
                accountId: "acct-a",
                tokens: ["access_token": "new-a", "refresh_token": "new-ra"]
            ),
        ])
        try credentialsExpect(result.appliedCount == 1, "多账号轮换应 applied=1")
        try credentialsExpect(result.failed.isEmpty, "多账号轮换不应 failed")

        // acct-a 已轮换
        let recordA = try accountStore.loadRecord(for: "acct-a")
        try credentialsExpect(
            recordA?.credentialJSON.contains("new-a") == true,
            "acct-a 应含新 access_token"
        )
        try credentialsExpect(
            recordA?.authorizationState == .connected,
            "轮换后 acct-a 应为 connected"
        )
        // acct-b 不受影响
        let recordB = try accountStore.loadRecord(for: "acct-b")
        try credentialsExpect(
            recordB?.credentialJSON.contains("keep-b") == true,
            "acct-b 凭证不应被轮换影响"
        )
    }

    /// OpenCode GO 网页会话无轮换语义: 轮换条目应被跳过
    /// (会话过期需用户重新登录, 不自动续期).
    private static func coordinatorRotationOpenCodeGo() throws {
        let store = InMemoryCredentialStore()
        let accountStore = ProviderAccountStore(provider: .opencodeGo, credentialStore: store)
        _ = try accountStore.addAccount(
            accountID: "go-acct",
            displayName: "OpenCode GO · a",
            credentialJSON: "{\"auth\":\"Fe26.2**old\",\"workspaceId\":\"wrk_01\"}"
        )

        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "opencode-go",
                accountId: "go-acct",
                tokens: ["access_token": "st_new", "refresh_token": "rt_new"]
            ),
        ])
        try credentialsExpect(result.appliedCount == 0, "opencode-go 不应接受轮换 (skipped)")
        try credentialsExpect(result.skippedCount == 1, "opencode-go 轮换应 skipped=1")

        let record = try accountStore.loadRecord(for: "go-acct")
        try credentialsExpect(
            record?.credentialJSON.contains("Fe26.2**old") == true,
            "opencodeGo record 不应被轮换修改"
        )
    }

    /// 多账号轮换: 未知 accountId 回退旧键路径 (兼容未迁移单账号).
    private static func coordinatorRotationMultiAccountUnknownAccountFallsBack() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(
            #"{"token":{"access_token":"old-a","refresh_token":"old-r"}}"#,
            forAccount: SubscriptionCredentialAccount.antigravityOAuth
        )
        let coordinator = CredentialUpdateCoordinator(credentialStore: store)
        let result = coordinator.apply(credentialUpdates: [
            oauthUpdate(
                provider: "antigravity",
                accountId: "unknown-acct",
                tokens: ["access_token": "new-a", "refresh_token": "new-r"]
            ),
        ])
        try credentialsExpect(result.appliedCount == 1, "未知账号回退旧键应 applied=1")
        let loaded = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.antigravityOAuth
        )
        try credentialsExpect(
            loaded?.contains("new-a") == true,
            "旧键应写入轮换后的 token"
        )
    }

    /// 账号摘要只暴露非敏感信息 (displayName + 状态), 不含凭证.
    private static func providerAccountSummariesExposeNonSensitiveInfo() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .deepseek, credentialStore: credStore)
        _ = try store.addAccount(
            accountID: "sk-12345",
            displayName: "DeepSeek · sk-12345",
            credentialJSON: "sk-secret-key-here"
        )
        try store.updateAuthorizationState(.connected, for: "sk-12345")

        let summaries = try store.summaries()
        try credentialsExpect(summaries.count == 1, "应有 1 条摘要")
        try credentialsExpect(
            summaries[0].accountID == "sk-12345",
            "摘要应含 accountID"
        )
        try credentialsExpect(
            summaries[0].displayName == "DeepSeek · sk-12345",
            "摘要应含 displayName"
        )
        try credentialsExpect(
            summaries[0].authorizationState == .connected,
            "摘要应含授权状态"
        )
        // 序列化后不得含凭证明文
        let encoded = try JSONEncoder().encode(summaries)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        try credentialsExpect(
            !json.contains("sk-secret-key-here"),
            "摘要不得含凭证明文"
        )
    }

    /// 移除最后一个账号后 index 为空 (provider 仍保留, 可再添加).
    private static func providerAccountStoreRemoveLastAccountKeepsEmptyIndex() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .claude, credentialStore: credStore)
        _ = try store.addAccount(
            accountID: "claude-001",
            displayName: "Claude · 1",
            credentialJSON: "{\"claudeAiOauth\":{\"accessToken\":\"tok\"}}"
        )

        try store.removeAccount(accountID: "claude-001")

        let index = try store.loadIndex()
        try credentialsExpect(index.accounts.isEmpty, "移除后 index 应为空")
        let count = try store.accountCount()
        try credentialsExpect(count == 0, "账号数应为 0")
        let record = try store.loadRecord(for: "claude-001")
        try credentialsExpect(record == nil, "record 应已删除")
    }

    /// upsert: 已存在账号更新凭证 (更换场景), 不存在则新增.
    private static func providerAccountStoreUpsertUpdatesExisting() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .deepseek, credentialStore: credStore)

        // 新增
        try store.upsertAccount(
            accountID: "sk-abc123",
            displayName: "DeepSeek · sk-abc123",
            credentialJSON: "sk-old-key"
        )
        let countAfterAdd = try store.accountCount()
        try credentialsExpect(countAfterAdd == 1, "upsert 新增后应有 1 个账号")
        let record1 = try store.loadRecord(for: "sk-abc123")
        try credentialsExpect(record1?.credentialJSON == "sk-old-key", "新增凭证不匹配")

        // 更新 (更换 API key)
        try store.upsertAccount(
            accountID: "sk-abc123",
            displayName: "DeepSeek · sk-abc123",
            credentialJSON: "sk-new-key"
        )
        let countAfterUpdate = try store.accountCount()
        try credentialsExpect(countAfterUpdate == 1, "upsert 更新不应新增账号")
        let record2 = try store.loadRecord(for: "sk-abc123")
        try credentialsExpect(record2?.credentialJSON == "sk-new-key", "更新凭证不匹配")

        // 更新后 index 状态保留 (connected 不被重置)
        try store.updateAuthorizationState(.connected, for: "sk-abc123")
        try store.upsertAccount(
            accountID: "sk-abc123",
            displayName: "DeepSeek · sk-abc123",
            credentialJSON: "sk-newer-key"
        )
        let record3 = try store.loadRecord(for: "sk-abc123")
        try credentialsExpect(record3?.credentialJSON == "sk-newer-key", "二次更新凭证不匹配")
        try credentialsExpect(
            record3?.authorizationState == .connected,
            "更新凭证不应重置 connected 状态"
        )
    }

    /// 模拟 saveProviderAccountCredential 流程: upsert 后显式标记 connected.
    /// 回归: 只 upsert 不置 connected 会让账号列表一直显示"需要重新登录".
    private static func providerAccountStoreWriteThenConnected() throws {
        let credStore = InMemoryCredentialStore()
        let store = ProviderAccountStore(provider: .kimi, credentialStore: credStore)

        // 模拟导入流程: upsert 新增 + 标记 connected
        try store.upsertAccount(
            accountID: "kimi-001",
            displayName: "Kimi · kimi-001",
            credentialJSON: "{\"access_token\":\"at\",\"refresh_token\":\"rt\"}"
        )
        try store.updateAuthorizationState(.connected, for: "kimi-001")

        let summaries = try store.summaries()
        try credentialsExpect(summaries.count == 1, "应有 1 个账号")
        try credentialsExpect(
            summaries[0].authorizationState == .connected,
            "导入后账号应为 connected, 而不是 needsReauthorization"
        )
    }
}
