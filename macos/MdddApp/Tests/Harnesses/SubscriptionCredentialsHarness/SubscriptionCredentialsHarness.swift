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

/// 订阅凭证注入链路测试 (Phase 5):
/// OnboardingRunInputProvider 对 claude/grok 的凭证注入语义.
/// - 应用持有 claude:oauth/grok:oauth 时注入 claudeOAuth/grokOAuth
/// - 无应用凭证时仅注入 providerMeta enabled 标记 (collector 回退本机)
/// - 禁用 provider 时两者皆无
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
        print("Subscription credentials tests passed: 6")
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
}
