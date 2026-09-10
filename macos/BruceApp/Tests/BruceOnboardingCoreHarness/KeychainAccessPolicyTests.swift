import Foundation
@testable import BruceOnboardingCore

@MainActor
func keychainAccessPolicyTests() throws {
    try keychainAccessPolicyDefaultsClosed()
    try keychainAccessPolicyLegacyBooleanMigration()
    try keychainAccessPolicyMalformedNewObjectDefaultsDeny()
    try keychainAccessPolicyAllowsOnlyConfiguredSources()
    try keychainAccessPolicyBlockedStateDeniesAutomaticAccess()
    try keychainAccessControllerSharesBlockedState()
}

@MainActor
private func keychainAccessPolicyDefaultsClosed() throws {
    let config = OnboardingConfiguration()
    let policy = KeychainAccessPolicy(
        configuration: config.keychainAccess
    )
    try coreExpect(
        policy.state == .notConfigured,
        "default Keychain policy must be notConfigured"
    )
    try coreExpect(
        !policy.allows(source: .bruceStore, intent: .automatic),
        "default policy must deny automatic Bruce Keychain access"
    )
    try coreExpect(
        !policy.allows(
            source: .external(.claudeCLI), intent: .automatic
        ),
        "default policy must deny automatic external Keychain access"
    )
}

@MainActor
private func keychainAccessPolicyLegacyBooleanMigration() throws {
    let legacy = Data("{\"schemaVersion\":2,\"keychainAccessConfigured\":true}".utf8)
    let decoded = try JSONDecoder().decode(
        OnboardingConfiguration.self, from: legacy
    )
    try coreExpect(
        decoded.keychainAccess.bruceStoreConfigured,
        "legacy Keychain boolean must migrate to Bruce Store configuration"
    )
    try coreExpect(
        decoded.keychainAccess.bruceStoreStorageVersion == 0,
        "legacy Keychain boolean must not claim current storage setup"
    )
    try coreExpect(
        !decoded.keychainAccessConfigured,
        "legacy Keychain boolean must not unlock automatic access"
    )
    try coreExpect(
        decoded.keychainAccess.externalSources.isEmpty,
        "legacy configuration must not grant external Keychain sources"
    )
}

@MainActor
private func keychainAccessPolicyMalformedNewObjectDefaultsDeny() throws {
    let malformed = Data(
        "{\"schemaVersion\":2,\"keychainAccess\":\"invalid\",\"keychainAccessConfigured\":true}".utf8
    )
    let decoded = try JSONDecoder().decode(
        OnboardingConfiguration.self, from: malformed
    )
    try coreExpect(
        !decoded.keychainAccess.bruceStoreConfigured,
        "malformed new Keychain configuration must default-deny"
    )
}

@MainActor
private func keychainAccessPolicyAllowsOnlyConfiguredSources() throws {
    let configuration = KeychainAccessConfiguration(
        bruceStoreConfigured: true,
        externalSources: [.claudeCLI]
    )
    let policy = KeychainAccessPolicy(configuration: configuration)
    try coreExpect(policy.state == .allowed, "configured policy must be allowed")
    try coreExpect(
        policy.allows(source: .bruceStore, intent: .automatic),
        "configured policy must allow automatic Bruce access"
    )
    try coreExpect(
        policy.allows(source: .external(.claudeCLI), intent: .automatic),
        "explicitly configured Claude source must be allowed"
    )
    try coreExpect(
        !policy.allows(source: .external(.grokCLI), intent: .automatic),
        "unconfigured Grok source must remain denied"
    )
}

@MainActor
private func keychainAccessPolicyBlockedStateDeniesAutomaticAccess() throws {
    let configuration = KeychainAccessConfiguration(bruceStoreConfigured: true)
    let policy = KeychainAccessPolicy(configuration: configuration, state: .blocked)
    try coreExpect(
        !policy.allows(source: .bruceStore, intent: .automatic),
        "blocked policy must deny automatic Bruce access"
    )
    try coreExpect(
        policy.allows(source: .bruceStore, intent: .userInitiated),
        "blocked policy must allow explicit Bruce reconfiguration"
    )
}

@MainActor
private func keychainAccessControllerSharesBlockedState() throws {
    let configuration = KeychainAccessConfiguration(bruceStoreConfigured: true)
    let controller = KeychainAccessController(
        policy: KeychainAccessPolicy(configuration: configuration)
    )
    controller.markBlocked()
    try coreExpect(
        controller.policy.state == .blocked,
        "controller must publish blocked state"
    )
    try coreExpect(
        !controller.allows(source: .bruceStore, intent: .automatic),
        "controller must deny automatic access after block"
    )
    controller.clearBlocked()
    try coreExpect(
        controller.policy.state == .allowed,
        "controller must clear blocked state after recovery"
    )
}
