import Foundation
@testable import BruceOnboardingCore

// MARK: - Gate / Policy / Evaluator / Config / Credential / Schema

extension BruceOnboardingCoreHarness {
    // MARK: - ActivationGate

    static func gateDeniesAllBeforeConsent() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: nil)
        for module in CollectorModule.allCases {
            let allowed = gate.canActivate(
                module: module, readiness: .ready,
                isModuleSelected: true, appIsAcceptingNewTasks: true
            )
            try coreExpect(!allowed, "\(module) should be denied before consent")
        }
    }

    static func gateDeniesWhenConsentVersionMismatch() throws {
        let gate = CollectorActivationGate(consentVersion: 2, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "version mismatch should deny")
    }

    static func gateAllowsAgentReady() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(allowed, "agent ready should be allowed")
    }

    static func gateAllowsAgentPartial() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .partial,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(allowed, "agent partial should be allowed")
    }

    static func gateDeniesUnselectedModule() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: false, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "unselected should be denied")
    }

    static func gateDeniesWhenAppNotAcceptingTasks() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: false
        )
        try coreExpect(!allowed, "should deny when app not accepting tasks")
    }

    static func gateDeniesPendingAuthorization() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        for module in CollectorModule.allCases {
            let allowed = gate.canActivate(
                module: module, readiness: .pendingAuthorization,
                isModuleSelected: true, appIsAcceptingNewTasks: true
            )
            try coreExpect(!allowed, "\(module) pendingAuth should be denied")
        }
    }

    static func gateDeniesNetworkUnreachable() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        for module in CollectorModule.allCases {
            let allowed = gate.canActivate(
                module: module, readiness: .networkUnreachable,
                isModuleSelected: true, appIsAcceptingNewTasks: true
            )
            try coreExpect(!allowed, "\(module) unreachable should be denied")
        }
    }

    // MARK: - ExecutionPolicy

    static func agentPolicyOnlyLocalCapabilities() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .agentUsage, readiness: .ready)
        try coreExpect(policy != nil, "policy should not be nil")
        try coreExpect(policy?.capabilities.contains(.localSessions) == true, "should have localSessions")
        try coreExpect(policy?.capabilities.contains(.localPricing) == true, "should have localPricing")
        try coreExpect(policy?.capabilities.contains(.externalQuotas) == false, "should NOT have externalQuotas")
    }

    static func policyNilWhenNotReady() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .agentUsage, readiness: .pendingAuthorization)
        try coreExpect(policy == nil, "policy should be nil when not ready")
    }

    // MARK: - ReadinessEvaluator

    static func evaluatorAgentReady() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Kimi Code"),
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Claude Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            sessionSources: sessions,
            ccSwitchStatus: .available, antigravityStatus: .available,
            collectorRuntime: .rustAvailable
        )
        try coreExpect(result.readiness == .ready, "agent should be ready")
    }

    static func evaluatorAgentPartial() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Kimi Code"),
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "Claude Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            sessionSources: sessions,
            ccSwitchStatus: .missing, antigravityStatus: .missing,
            collectorRuntime: .rustAvailable
        )
        try coreExpect(result.readiness == .partial, "agent should be partial")
        try coreExpect(result.warnings.count > 0, "should have warnings")
    }

    static func evaluatorAgentRustDoesNotRequireOtherRuntime() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            sessionSources: [
                DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Codex")
            ],
            ccSwitchStatus: .missing,
            antigravityStatus: .missing,
            collectorRuntime: .rustAvailable
        )
        try coreExpect(result.readiness == .ready, "Rust runtime should be sufficient")
    }

    static func evaluatorAgentRustMissingIsExplicit() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            sessionSources: [
                DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Codex")
            ],
            ccSwitchStatus: .missing,
            antigravityStatus: .missing,
            collectorRuntime: .rustUnavailable
        )
        try coreExpect(result.readiness == .missingDependency, "missing Rust should block readiness")
        try coreExpect(
            result.issues.contains { $0.code == "RUST_COLLECTOR_UNAVAILABLE" },
            "missing Rust should expose an explicit diagnostic"
        )
    }

    static func evaluatorAgentMissingRust() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            sessionSources: [],
            ccSwitchStatus: .missing, antigravityStatus: .missing,
            collectorRuntime: .rustUnavailable
        )
        try coreExpect(result.readiness == .missingDependency, "should be missingDependency")
        try coreExpect(
            result.issues.contains { $0.code == "RUST_COLLECTOR_UNAVAILABLE" },
            "missing Rust should expose an explicit diagnostic"
        )
    }

    static func evaluatorAgentNoSessions() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "Kimi Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            sessionSources: sessions,
            ccSwitchStatus: .missing, antigravityStatus: .missing,
            collectorRuntime: .rustAvailable
        )
        try coreExpect(result.readiness == .missingDependency, "should be missingDependency without sessions")
    }

    static func evaluatorAgentCcSwitchAloneNotReady() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            sessionSources: [],
            ccSwitchStatus: .available, antigravityStatus: .missing,
            collectorRuntime: .rustAvailable
        )
        try coreExpect(result.readiness == .missingDependency, "CC Switch alone should not make ready")
    }

    // MARK: - Config store

    static func configStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        var config = OnboardingConfiguration()
        config.selectedModules = ["agent-usage"]
        config.consentVersion = 1
        config.menuBarMetrics = [
            "minimumRemainingQuota",
            "todayTokens",
        ]

        try store.save(config)
        let loaded = store.load()

        try coreExpect(loaded != nil, "loaded config should not be nil")
        try coreExpect(loaded?.selectedModules == ["agent-usage"], "selectedModules mismatch")
        try coreExpect(loaded?.consentVersion == 1, "consentVersion mismatch")
        try coreExpect(
            loaded?.menuBarMetrics == [
                "minimumRemainingQuota",
                "todayTokens",
            ],
            "menuBarMetrics mismatch"
        )
    }

    static func configStoreReturnsEmptyWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let loaded = store.load()
        try coreExpect(loaded != nil, "should return empty config")
        try coreExpect(loaded?.selectedModules.isEmpty == true, "should have no selected modules")
        try coreExpect(loaded?.consentVersion == nil, "should have no consent")
    }

    static func configStoreReturnsNilForUnknownSchema() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let futureConfig: [String: Any] = [
            "schemaVersion": 99,
            "selectedModules": ["agent-usage"],
        ]
        let data = try JSONSerialization.data(withJSONObject: futureConfig)
        let configURL = tempDir.appendingPathComponent("onboarding-v1.json")
        try data.write(to: configURL)

        let loaded = store.load()
        try coreExpect(loaded == nil, "unknown schema should return nil")
    }

    static func configStoreFilePermissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let config = OnboardingConfiguration(consentVersion: 1)
        try store.save(config)

        let configURL = tempDir.appendingPathComponent("onboarding-v1.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: configURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try coreExpect(perms == 0o600, "config file should have 0600 permissions, got \(String(perms, radix: 8))")
    }

    // MARK: - Credential store

    static func credentialStoreRoundTrip() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(
            "fixture-value", forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let loaded = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try coreExpect(loaded == "fixture-value", "credential roundtrip failed")
    }

    static func credentialStoreDelete() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential(
            "fixture-value", forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try store.deleteCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let loaded = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try coreExpect(loaded == nil, "credential should be deleted")
    }

    static func credentialStoreIsolatesByAccount() throws {
        let store = InMemoryCredentialStore()
        try store.saveCredential("value-a", forAccount: "account-a")
        try store.saveCredential("value-b", forAccount: "account-b")
        let loadedA = try store.loadCredential(forAccount: "account-a")
        let loadedB = try store.loadCredential(forAccount: "account-b")
        try coreExpect(loadedA == "value-a", "account A mismatch")
        try coreExpect(loadedB == "value-b", "account B mismatch")
        try store.deleteCredential(forAccount: "account-a")
        let deletedA = try store.loadCredential(forAccount: "account-a")
        let intactB = try store.loadCredential(forAccount: "account-b")
        try coreExpect(deletedA == nil, "account A should be nil")
        try coreExpect(intactB == "value-b", "account B should be intact")
    }

    // MARK: - Gate evaluator

    static func gateEvaluatorDeniesAllBeforeConsent() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: nil)
        let evaluator = ActivationGateEvaluator(gate: gate)
        let decisions = evaluator.evaluate(
            readinessByModule: [
                .agentUsage: .ready
            ],
            selectedModules: Set(CollectorModule.allCases),
            appIsAcceptingNewTasks: true
        )
        for decision in decisions {
            try coreExpect(!decision.allowed, "\(decision.module) should be denied before consent")
        }
    }

    static func gateEvaluatorEnablesOnlyReadyAndSelected() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let evaluator = ActivationGateEvaluator(gate: gate)
        let decisions = evaluator.evaluate(
            readinessByModule: [
                .agentUsage: .ready
            ],
            selectedModules: [.agentUsage],
            appIsAcceptingNewTasks: true
        )
        let agentDecision = decisions.first { $0.module == .agentUsage }

        try coreExpect(agentDecision?.allowed == true, "agent should be allowed")
    }

    // MARK: - Schema profiles

    static func ccSwitchProfileHasExpectedTables() throws {
        let profile = SQLiteSchemaProfile.ccSwitch
        try coreExpect(profile.tables["providers"] != nil, "providers table missing")
        try coreExpect(profile.tables["model_pricing"] != nil, "model_pricing table missing")
        try coreExpect(profile.tables["providers"]?.contains("id") == true, "id column missing")
        try coreExpect(profile.tables["providers"]?.contains("settings_config") == true, "settings_config missing")
        try coreExpect(profile.tables["model_pricing"]?.contains("model_id") == true, "model_id missing")
    }

    static func antigravityProfileHasExpectedTables() throws {
        let profile = SQLiteSchemaProfile.antigravity
        try coreExpect(profile.tables["conversation_summaries"] != nil, "conversation_summaries table missing")
        try coreExpect(profile.tables["conversation_summaries"]?.contains("step_count") == true, "step_count missing")
        try coreExpect(profile.tables["conversation_summaries"]?.contains("last_modified_time") == true, "last_modified_time missing")
    }

}
