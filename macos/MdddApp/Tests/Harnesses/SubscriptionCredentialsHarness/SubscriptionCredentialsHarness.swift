import Foundation
import MdddOnboardingCore
@testable import MdddAppCore

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
        try coordinatorAppliesKimiToInMemoryStore()
        try coordinatorSkipsBadShapeAndUnknownProvider()
        print("Subscription credentials tests passed: 10")
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
        guard case .object(let claude)? = credentials["claudeOAuth"] else {
            throw CredentialsTestFailure.expectation("claudeOAuth 未注入")
        }
        guard case .object(let meta)? = credentials["providerMeta"],
              case .object(let claudeMeta)? = meta["claude"] else {
            throw CredentialsTestFailure.expectation("providerMeta.claude 缺失")
        }
        try credentialsExpect(
            claude["claudeAiOauth"] != nil,
            "claudeOAuth 应包含 claudeAiOauth 节点"
        )
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
        guard case .object(let grok)? = credentials["grokOAuth"] else {
            throw CredentialsTestFailure.expectation("grokOAuth 未注入")
        }
        try credentialsExpect(
            grok["https://auth.x.ai::injected"] != nil,
            "grokOAuth 应包含 scope 条目"
        )
    }

    private static func claudeFallbackToMetaWhenNoCredential() async throws {
        let (provider, _, _) = try makeProvider(
            enabled: [.claude],
            credentials: [:]
        )
        let (_, credentials) = try await runInput(provider)
        try credentialsExpect(
            credentials["claudeOAuth"] == nil,
            "无应用凭证时不应注入 claudeOAuth"
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
            credentials["grokOAuth"] == nil,
            "无应用凭证时不应注入 grokOAuth"
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
            credentials["claudeOAuth"] == nil && credentials["grokOAuth"] == nil,
            "禁用 provider 时不应注入任何凭证"
        )
        try credentialsExpect(
            credentials["providerMeta"] == nil,
            "禁用 provider 时不应注入 providerMeta"
        )
    }

    private static func nonCredentialProvidersUnaffected() async throws {
        let kimiJSON = #"{"access_token":"a","refresh_token":"r"}"#
        let (provider, _, _) = try makeProvider(
            enabled: [.kimi],
            credentials: [SubscriptionCredentialAccount.kimiWebTokens: kimiJSON]
        )
        let (_, credentials) = try await runInput(provider)
        guard case .object(let kimi)? = credentials["kimiWebTokens"] else {
            throw CredentialsTestFailure.expectation("kimiWebTokens 未注入")
        }
        try credentialsExpect(
            kimi["access_token"] != nil,
            "kimi 注入不受 claude/grok 改动影响"
        )
        try credentialsExpect(
            credentials["claudeOAuth"] == nil && credentials["grokOAuth"] == nil,
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
                provider: "kimi",
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
        try credentialsExpect(failure.provider == "kimi", "failed.provider 应为 kimi")
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

    /// 有效 kimi 更新写入 InMemory store, appliedCount == 1, 可加载合并后令牌.
    private static func coordinatorAppliesKimiToInMemoryStore() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(
            #"{"access_token":"old-a","refresh_token":"old-r"}"#,
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
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
        try credentialsExpect(result.appliedCount == 1, "成功应 applied=1")
        try credentialsExpect(result.skippedCount == 0, "成功不应 skipped")
        try credentialsExpect(result.failed.isEmpty, "成功不应 failed")
        let loaded = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        try credentialsExpect(
            loaded == #"{"access_token":"new-a","refresh_token":"new-r"}"#,
            "合并后 JSON 不符, got \(loaded ?? "nil")"
        )
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
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        try credentialsExpect(kimi == nil, "坏条目不得写入 kimi")
    }
}
