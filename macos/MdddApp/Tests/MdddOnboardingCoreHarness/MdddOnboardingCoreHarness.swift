import Foundation
@testable import MdddOnboardingCore

private enum CoreTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func coreExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw CoreTestFailure.expectation(message)
    }
}

// MARK: - Test helper

private final class TestFileManager: FileManager {
    let executables: Set<String>
    init(executables: [String]) {
        self.executables = Set(executables)
    }
    override func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }
}

// MARK: - Harness

@main
@MainActor
struct MdddOnboardingCoreHarness {
    static func main() async throws {
        try pythonVersionParses_3_9()
        try pythonVersionParses_3_12()
        try pythonVersionParsesWithWhitespace()
        try pythonVersionParsesMissingPatch()
        try pythonVersionRejects_2_7()
        try pythonVersionRejects_3_8()
        try pythonVersionRejectsGarbage()
        try pythonPathResolvesUserPreferred()
        try pythonPathFallsBackToCandidates()
        try pythonPathReturnsNilWhenNoneFound()
        try ghCliPathResolvesUserPreferred()
        try ghCliPathFallsBackToCandidates()
        try gateDeniesAllBeforeConsent()
        try gateDeniesWhenConsentVersionMismatch()
        try gateAllowsAgentReady()
        try gateAllowsAgentPartial()
        try gateDeniesGitHubPartial()
        try gateDeniesGitLabPartial()
        try gateDeniesUnselectedModule()
        try gateDeniesWhenAppNotAcceptingTasks()
        try gateDeniesPendingAuthorization()
        try gateDeniesNetworkUnreachable()
        try agentPolicyOnlyLocalCapabilities()
        try githubPolicyHasNoCapabilities()
        try policyNilWhenNotReady()
        try evaluatorAgentReady()
        try evaluatorAgentPartial()
        try evaluatorAgentMissingPython()
        try evaluatorAgentNoSessions()
        try evaluatorAgentCcSwitchAloneNotReady()
        try evaluatorGitHubReady()
        try evaluatorGitHubNotLoggedIn()
        try evaluatorGitHubGhMissing()
        try evaluatorGitLabReady()
        try evaluatorGitLabExpired()
        try evaluatorGitLabUnreachable()
        try evaluatorGitLabNoURL()
        try evaluatorGitLabHttpURL()
        try configStoreRoundTrip()
        try configStoreReturnsEmptyWhenMissing()
        try configStoreReturnsNilForUnknownSchema()
        try configStoreFilePermissions()
        try credentialStoreRoundTrip()
        try credentialStoreDelete()
        try credentialStoreIsolatesByHost()
        try gateEvaluatorDeniesAllBeforeConsent()
        try gateEvaluatorEnablesOnlyReadyAndSelected()
        try ccSwitchProfileHasExpectedTables()
        try antigravityProfileHasExpectedTables()
        try await probeSuccessCapturesOutput()
        try await probeLaunchFailedForMissingExecutable()
        try await probeNonZeroExitCapturesStderrSummary()
        try await probeTimeoutForceKillsIgnoringSIGTERM()
        try await probeCallerCancellationTerminatesProcess()
        try await probeOutputCapTruncatesAndDrains()
        try await sqliteProbeAvailableForValidSchema()
        try await sqliteProbeMissingPath()
        try await sqliteProbeIncompatibleWhenMissingTable()
        try await sqliteProbeIncompatibleWhenMissingColumn()
        try await sqliteProbeRejectsSubstringColumnTrap()
        try await sqliteProbeCorruptedForGarbageFile()
        try sqliteLockedDetectionUsesStderr()
        try sqliteTableInfoParsesColumnNames()
        try keychainUpdatePreservesAndOverwrites()
        try await scannerFindsPythonSessionsAndSQLite()
        try await scannerReportsMissingPythonAndGh()
        try gitlabURLNormalizationAcceptsHTTPS()
        try gitlabURLRejectsNonHTTPSAndCredentials()
        try await gitlabVerifyConnectedWithMockSession()
        try await gitlabVerifyExpiredOn401And403()
        try await gitlabVerifyUnreachableOnNetworkError()
        try gitlabRedirectPolicyAllowsSameHostOnly()
        try await githubStatusCheckMappings()
        try firstLaunchDecisionFlow()
        try configStoreLoadsV1WithSubscriptionDefaults()
        try configStoreRejectsNewerSchemaV3()
        try configStoreSubscriptionProvidersRoundTrip()
        try credentialStoreSubscriptionAccountsRoundTrip()
        try keychainSubscriptionAccountsRoundTrip()
        try await verifierDeepSeekConnectedWithMockSession()
        try await verifierDeepSeekFailClosed()
        try verifierKimiWebTokensJSONMappings()
        try verifierCodexAccountsJSONMappings()
        try verifierAntigravityOAuthJSONMappings()
        try verifierVolcengineCredentialsMappings()
        try gateAgentPolicyGrantsExternalQuotasWhenConfigured()
        try gateEvaluatorPropagatesSubscriptionFlag()
        try volcDecoderStopsWhenNotBase64()
        try volcDecoderSingleAndDoubleEncoded()
        try volcFullyDecodedPicksDeepestCandidate()
        try kimiPasteParsesFullJSON()
        try kimiPasteParsesTokenPairs()
        try kimiPasteRejectsEmptyAndBrokenJSON()
        try codexAuthFileParsesValidAccount()
        try codexAuthFileRejectsMissingFields()
        try codexLibraryMergingCreatesPreservesUpdates()
        try codexLibrarySummaryCountAndPrefixes()
        try codexChooseActiveAccountPriority()
        try await ccSwitchVolcImportReadsFixtureDatabase()
        try await ccSwitchVolcImportMissingProviderRow()
        try await ccSwitchVolcImportMissingFile()
        try subscriptionConfigApplyingVerificationTransitions()
        print("MdddOnboardingCore tests passed: 102")
    }

    // MARK: - Python version parsing

    private static func pythonVersionParses_3_9() throws {
        let v = PythonVersionParser.parse("Python 3.9.6")
        try coreExpect(v?.major == 3, "major mismatch")
        try coreExpect(v?.minor == 9, "minor mismatch")
        try coreExpect(PythonVersionParser.isCompatible(v), "3.9 should be compatible")
    }

    private static func pythonVersionParses_3_12() throws {
        let v = PythonVersionParser.parse("Python 3.12.5")
        try coreExpect(v?.major == 3, "major mismatch")
        try coreExpect(v?.minor == 12, "minor mismatch")
        try coreExpect(PythonVersionParser.isCompatible(v), "3.12 should be compatible")
    }

    private static func pythonVersionParsesWithWhitespace() throws {
        let v = PythonVersionParser.parse("  Python 3.9.13  \n")
        try coreExpect(v?.major == 3, "major mismatch")
        try coreExpect(v?.minor == 9, "minor mismatch")
        try coreExpect(PythonVersionParser.isCompatible(v), "3.9 should be compatible")
    }

    private static func pythonVersionParsesMissingPatch() throws {
        let v = PythonVersionParser.parse("Python 3.9")
        try coreExpect(v?.major == 3, "major mismatch")
        try coreExpect(v?.minor == 9, "minor mismatch")
        try coreExpect(PythonVersionParser.isCompatible(v), "3.9 should be compatible")
    }

    private static func pythonVersionRejects_2_7() throws {
        let v = PythonVersionParser.parse("Python 2.7.18")
        try coreExpect(v?.major == 2, "major mismatch")
        try coreExpect(!PythonVersionParser.isCompatible(v), "2.7 should be incompatible")
    }

    private static func pythonVersionRejects_3_8() throws {
        let v = PythonVersionParser.parse("Python 3.8.10")
        try coreExpect(v?.major == 3, "major mismatch")
        try coreExpect(v?.minor == 8, "minor mismatch")
        try coreExpect(!PythonVersionParser.isCompatible(v), "3.8 should be incompatible")
    }

    private static func pythonVersionRejectsGarbage() throws {
        try coreExpect(PythonVersionParser.parse("garbage") == nil, "garbage should be nil")
        try coreExpect(PythonVersionParser.parse("") == nil, "empty should be nil")
        try coreExpect(PythonVersionParser.parse(nil) == nil, "nil should be nil")
        try coreExpect(!PythonVersionParser.isCompatible(nil), "nil should be incompatible")
    }

    // MARK: - Path resolution

    private static func pythonPathResolvesUserPreferred() throws {
        let fm = TestFileManager(executables: ["/custom/python3"])
        let path = PythonPathResolver.resolve(userPreferred: "/custom/python3", fileManager: fm)
        try coreExpect(path == "/custom/python3", "user preferred not resolved")
    }

    private static func pythonPathFallsBackToCandidates() throws {
        let fm = TestFileManager(executables: ["/usr/local/bin/python3"])
        let path = PythonPathResolver.resolve(fileManager: fm)
        try coreExpect(path == "/usr/local/bin/python3", "candidate not resolved")
    }

    private static func pythonPathReturnsNilWhenNoneFound() throws {
        let fm = TestFileManager(executables: [])
        let path = PythonPathResolver.resolve(fileManager: fm)
        try coreExpect(path == nil, "should be nil when no python found")
    }

    private static func ghCliPathResolvesUserPreferred() throws {
        let fm = TestFileManager(executables: ["/custom/gh"])
        let path = GhCliPathResolver.resolve(userPreferred: "/custom/gh", fileManager: fm)
        try coreExpect(path == "/custom/gh", "user preferred not resolved")
    }

    private static func ghCliPathFallsBackToCandidates() throws {
        let fm = TestFileManager(executables: ["/opt/homebrew/bin/gh"])
        let path = GhCliPathResolver.resolve(fileManager: fm)
        try coreExpect(path == "/opt/homebrew/bin/gh", "candidate not resolved")
    }

    // MARK: - ActivationGate

    private static func gateDeniesAllBeforeConsent() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: nil)
        for module in CollectorModule.allCases {
            let allowed = gate.canActivate(
                module: module, readiness: .ready,
                isModuleSelected: true, appIsAcceptingNewTasks: true
            )
            try coreExpect(!allowed, "\(module) should be denied before consent")
        }
    }

    private static func gateDeniesWhenConsentVersionMismatch() throws {
        let gate = CollectorActivationGate(consentVersion: 2, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .github, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "version mismatch should deny")
    }

    private static func gateAllowsAgentReady() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(allowed, "agent ready should be allowed")
    }

    private static func gateAllowsAgentPartial() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .partial,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(allowed, "agent partial should be allowed")
    }

    private static func gateDeniesGitHubPartial() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .github, readiness: .partial,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "github partial should be denied")
    }

    private static func gateDeniesGitLabPartial() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .gitlab, readiness: .partial,
            isModuleSelected: true, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "gitlab partial should be denied")
    }

    private static func gateDeniesUnselectedModule() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .github, readiness: .ready,
            isModuleSelected: false, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "unselected should be denied")
    }

    private static func gateDeniesWhenAppNotAcceptingTasks() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .github, readiness: .ready,
            isModuleSelected: true, appIsAcceptingNewTasks: false
        )
        try coreExpect(!allowed, "should deny when app not accepting tasks")
    }

    private static func gateDeniesPendingAuthorization() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        for module in CollectorModule.allCases {
            let allowed = gate.canActivate(
                module: module, readiness: .pendingAuthorization,
                isModuleSelected: true, appIsAcceptingNewTasks: true
            )
            try coreExpect(!allowed, "\(module) pendingAuth should be denied")
        }
    }

    private static func gateDeniesNetworkUnreachable() throws {
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

    private static func agentPolicyOnlyLocalCapabilities() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .agentUsage, readiness: .ready)
        try coreExpect(policy != nil, "policy should not be nil")
        try coreExpect(policy?.capabilities.contains(.localSessions) == true, "should have localSessions")
        try coreExpect(policy?.capabilities.contains(.localPricing) == true, "should have localPricing")
        try coreExpect(policy?.capabilities.contains(.externalQuotas) == false, "should NOT have externalQuotas")
    }

    private static func githubPolicyHasNoCapabilities() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .github, readiness: .ready)
        try coreExpect(policy != nil, "policy should not be nil")
        try coreExpect(policy?.capabilities.isEmpty == true, "github should have no capabilities")
    }

    private static func policyNilWhenNotReady() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .github, readiness: .pendingAuthorization)
        try coreExpect(policy == nil, "policy should be nil when not ready")
    }

    // MARK: - ReadinessEvaluator

    private static func evaluatorAgentReady() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Kimi Code"),
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Claude Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            sessionSources: sessions,
            ccSwitchStatus: .available, antigravityStatus: .available
        )
        try coreExpect(result.readiness == .ready, "agent should be ready")
    }

    private static func evaluatorAgentPartial() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Kimi Code"),
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "Claude Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            sessionSources: sessions,
            ccSwitchStatus: .missing, antigravityStatus: .missing
        )
        try coreExpect(result.readiness == .partial, "agent should be partial")
        try coreExpect(result.warnings.count > 0, "should have warnings")
    }

    private static func evaluatorAgentMissingPython() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            pythonStatus: .missing, pythonVersion: nil,
            sessionSources: [],
            ccSwitchStatus: .missing, antigravityStatus: .missing
        )
        try coreExpect(result.readiness == .missingDependency, "should be missingDependency")
        try coreExpect(result.blockingReason != nil, "should have blocking reason")
    }

    private static func evaluatorAgentNoSessions() throws {
        let evaluator = ReadinessEvaluator()
        let sessions = [
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "Kimi Code"),
        ]
        let result = evaluator.evaluateAgentUsage(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            sessionSources: sessions,
            ccSwitchStatus: .missing, antigravityStatus: .missing
        )
        try coreExpect(result.readiness == .missingDependency, "should be missingDependency without sessions")
    }

    private static func evaluatorAgentCcSwitchAloneNotReady() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateAgentUsage(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            sessionSources: [],
            ccSwitchStatus: .available, antigravityStatus: .missing
        )
        try coreExpect(result.readiness == .missingDependency, "CC Switch alone should not make ready")
    }

    private static func evaluatorGitHubReady() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateGitHub(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            ghCliStatus: .available, ghVersion: "gh version 2.50.0",
            ghLoggedIn: true
        )
        try coreExpect(result.readiness == .ready, "github should be ready")
        try coreExpect(result.connection == .connected, "should be connected")
    }

    private static func evaluatorGitHubNotLoggedIn() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateGitHub(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            ghCliStatus: .available, ghVersion: "gh version 2.50.0",
            ghLoggedIn: false
        )
        try coreExpect(result.readiness == .pendingAuthorization, "should be pendingAuthorization")
        try coreExpect(result.actions.contains(.loginGitHub), "should suggest loginGitHub")
    }

    private static func evaluatorGitHubGhMissing() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateGitHub(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            ghCliStatus: .missing, ghVersion: nil,
            ghLoggedIn: false
        )
        try coreExpect(result.readiness == .missingDependency, "should be missingDependency")
        try coreExpect(result.actions.contains(.installGitHubCLI), "should suggest installGitHubCLI")
    }

    private static func evaluatorGitLabReady() throws {
        let evaluator = ReadinessEvaluator()
        let url = URL(string: "https://gitlab.example.com")!
        let result = evaluator.evaluateGitLab(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            baseURL: url, connectionStatus: .connected
        )
        try coreExpect(result.readiness == .ready, "gitlab should be ready")
    }

    private static func evaluatorGitLabExpired() throws {
        let evaluator = ReadinessEvaluator()
        let url = URL(string: "https://gitlab.example.com")!
        let result = evaluator.evaluateGitLab(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            baseURL: url, connectionStatus: .expired
        )
        try coreExpect(result.readiness == .authorizationExpired, "should be authorizationExpired")
        try coreExpect(result.actions.contains(.replaceGitLabPAT), "should suggest replaceGitLabPAT")
    }

    private static func evaluatorGitLabUnreachable() throws {
        let evaluator = ReadinessEvaluator()
        let url = URL(string: "https://gitlab.example.com")!
        let result = evaluator.evaluateGitLab(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            baseURL: url, connectionStatus: .unreachable
        )
        try coreExpect(result.readiness == .networkUnreachable, "should be networkUnreachable")
        try coreExpect(result.actions.contains(.retryConnection), "should suggest retryConnection")
    }

    private static func evaluatorGitLabNoURL() throws {
        let evaluator = ReadinessEvaluator()
        let result = evaluator.evaluateGitLab(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            baseURL: nil, connectionStatus: .notChecked
        )
        try coreExpect(result.readiness == .pendingAuthorization, "should be pendingAuthorization")
        try coreExpect(result.actions.contains(.configureGitLab), "should suggest configureGitLab")
    }

    private static func evaluatorGitLabHttpURL() throws {
        let evaluator = ReadinessEvaluator()
        let url = URL(string: "http://gitlab.example.com")!
        let result = evaluator.evaluateGitLab(
            pythonStatus: .available, pythonVersion: "Python 3.9.6",
            baseURL: url, connectionStatus: .notChecked
        )
        try coreExpect(result.readiness == .pendingAuthorization, "HTTP should be pendingAuthorization")
    }

    // MARK: - Config store

    private static func configStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        var config = OnboardingConfiguration()
        config.pythonPath = "/usr/bin/python3"
        config.gitlabBaseURL = "https://gitlab.example.com"
        config.selectedModules = ["github", "gitlab"]
        config.consentVersion = 1
        config.menuBarMetrics = [
            "minimumRemainingQuota",
            "todayTokens",
        ]

        try store.save(config)
        let loaded = store.load()

        try coreExpect(loaded != nil, "loaded config should not be nil")
        try coreExpect(loaded?.pythonPath == "/usr/bin/python3", "pythonPath mismatch")
        try coreExpect(loaded?.gitlabBaseURL == "https://gitlab.example.com", "gitlabBaseURL mismatch")
        try coreExpect(loaded?.selectedModules == ["github", "gitlab"], "selectedModules mismatch")
        try coreExpect(loaded?.consentVersion == 1, "consentVersion mismatch")
        try coreExpect(
            loaded?.menuBarMetrics == [
                "minimumRemainingQuota",
                "todayTokens",
            ],
            "menuBarMetrics mismatch"
        )
    }

    private static func configStoreReturnsEmptyWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let loaded = store.load()
        try coreExpect(loaded != nil, "should return empty config")
        try coreExpect(loaded?.selectedModules.isEmpty == true, "should have no selected modules")
        try coreExpect(loaded?.consentVersion == nil, "should have no consent")
    }

    private static func configStoreReturnsNilForUnknownSchema() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let futureConfig: [String: Any] = [
            "schemaVersion": 99,
            "selectedModules": ["github"],
        ]
        let data = try JSONSerialization.data(withJSONObject: futureConfig)
        let configURL = tempDir.appendingPathComponent("onboarding-v1.json")
        try data.write(to: configURL)

        let loaded = store.load()
        try coreExpect(loaded == nil, "unknown schema should return nil")
    }

    private static func configStoreFilePermissions() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-config-test-\(UUID().uuidString)")
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

    private static func credentialStoreRoundTrip() throws {
        let store = InMemoryCredentialStore()
        try store.savePAT("glpat-xxxxxxxx", forHost: "gitlab.example.com")
        let loaded = try store.loadPAT(forHost: "gitlab.example.com")
        try coreExpect(loaded == "glpat-xxxxxxxx", "PAT roundtrip failed")
    }

    private static func credentialStoreDelete() throws {
        let store = InMemoryCredentialStore()
        try store.savePAT("glpat-xxxxxxxx", forHost: "gitlab.example.com")
        try store.deletePAT(forHost: "gitlab.example.com")
        let loaded = try store.loadPAT(forHost: "gitlab.example.com")
        try coreExpect(loaded == nil, "PAT should be deleted")
    }

    private static func credentialStoreIsolatesByHost() throws {
        let store = InMemoryCredentialStore()
        try store.savePAT("pat-a", forHost: "gitlab-a.com")
        try store.savePAT("pat-b", forHost: "gitlab-b.com")
        let loadedA = try store.loadPAT(forHost: "gitlab-a.com")
        let loadedB = try store.loadPAT(forHost: "gitlab-b.com")
        try coreExpect(loadedA == "pat-a", "host A mismatch")
        try coreExpect(loadedB == "pat-b", "host B mismatch")
        try store.deletePAT(forHost: "gitlab-a.com")
        let deletedA = try store.loadPAT(forHost: "gitlab-a.com")
        let intactB = try store.loadPAT(forHost: "gitlab-b.com")
        try coreExpect(deletedA == nil, "host A should be nil")
        try coreExpect(intactB == "pat-b", "host B should be intact")
    }

    // MARK: - Gate evaluator

    private static func gateEvaluatorDeniesAllBeforeConsent() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: nil)
        let evaluator = ActivationGateEvaluator(gate: gate)
        let decisions = evaluator.evaluate(
            readinessByModule: [
                .agentUsage: .ready, .github: .ready, .gitlab: .ready
            ],
            selectedModules: Set(CollectorModule.allCases),
            appIsAcceptingNewTasks: true
        )
        for decision in decisions {
            try coreExpect(!decision.allowed, "\(decision.module) should be denied before consent")
        }
    }

    private static func gateEvaluatorEnablesOnlyReadyAndSelected() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let evaluator = ActivationGateEvaluator(gate: gate)
        let decisions = evaluator.evaluate(
            readinessByModule: [
                .agentUsage: .ready,
                .github: .pendingAuthorization,
                .gitlab: .ready
            ],
            selectedModules: [.agentUsage, .github],
            appIsAcceptingNewTasks: true
        )
        let agentDecision = decisions.first { $0.module == .agentUsage }
        let githubDecision = decisions.first { $0.module == .github }
        let gitlabDecision = decisions.first { $0.module == .gitlab }

        try coreExpect(agentDecision?.allowed == true, "agent should be allowed")
        try coreExpect(githubDecision?.allowed == false, "github should be denied (pendingAuth)")
        try coreExpect(gitlabDecision?.allowed == false, "gitlab should be denied (not selected)")
    }

    // MARK: - Schema profiles

    private static func ccSwitchProfileHasExpectedTables() throws {
        let profile = SQLiteSchemaProfile.ccSwitch
        try coreExpect(profile.tables["providers"] != nil, "providers table missing")
        try coreExpect(profile.tables["model_pricing"] != nil, "model_pricing table missing")
        try coreExpect(profile.tables["providers"]?.contains("id") == true, "id column missing")
        try coreExpect(profile.tables["providers"]?.contains("settings_config") == true, "settings_config missing")
        try coreExpect(profile.tables["model_pricing"]?.contains("model_id") == true, "model_id missing")
    }

    private static func antigravityProfileHasExpectedTables() throws {
        let profile = SQLiteSchemaProfile.antigravity
        try coreExpect(profile.tables["conversation_summaries"] != nil, "conversation_summaries table missing")
        try coreExpect(profile.tables["conversation_summaries"]?.contains("step_count") == true, "step_count missing")
        try coreExpect(profile.tables["conversation_summaries"]?.contains("last_modified_time") == true, "last_modified_time missing")
    }

    // MARK: - AsyncProcessProbe

    private static func probeSuccessCapturesOutput() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(executablePath: "/bin/echo", arguments: ["hello"])
        guard case .success(let output) = result else {
            throw CoreTestFailure.expectation("echo should succeed, got \(result)")
        }
        try coreExpect(output == "hello", "output mismatch: \(output)")
        try coreExpect(result.firstLine == "hello", "firstLine mismatch")
    }

    private static func probeLaunchFailedForMissingExecutable() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/nonexistent/binary-\(UUID().uuidString)",
            arguments: []
        )
        try coreExpect(result == .launchFailed, "should be launchFailed, got \(result)")
    }

    private static func probeNonZeroExitCapturesStderrSummary() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo database-is-locked-here >&2; exit 3"]
        )
        guard case .nonZeroExit(let code, let stderrSummary) = result else {
            throw CoreTestFailure.expectation("should be nonZeroExit, got \(result)")
        }
        try coreExpect(code == 3, "exit code mismatch: \(code)")
        try coreExpect(
            stderrSummary?.contains("database-is-locked-here") == true,
            "stderr summary missing: \(String(describing: stderrSummary))"
        )
    }

    /// 子进程忽略 SIGTERM, 验证宽限期后 SIGKILL 生效且不遗留等待.
    /// exec 使 sleep 替换 shell 成为直接子进程 (SIG_IGN 跨 exec 保留),
    /// 避免孤儿孙进程干扰验证.
    private static func probeTimeoutForceKillsIgnoringSIGTERM() async throws {
        let probe = AsyncProcessProbe(timeout: 0.3, gracePeriod: 0.2)
        let start = Date()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec sleep 60"]
        )
        let elapsed = Date().timeIntervalSince(start)
        try coreExpect(result == .timedOut, "should be timedOut, got \(result)")
        try coreExpect(
            elapsed < 5,
            "force kill should finish fast, took \(elapsed)s"
        )
    }

    private static func probeCallerCancellationTerminatesProcess() async throws {
        let probe = AsyncProcessProbe(timeout: 30, gracePeriod: 0.2)
        let task = Task {
            await probe.run(executablePath: "/bin/sleep", arguments: ["60"])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)
        try coreExpect(result == .cancelled, "should be cancelled, got \(result)")
        try coreExpect(elapsed < 5, "cancel cleanup should be fast, took \(elapsed)s")
    }

    /// 输出远超管道缓冲区 (200KB > 64KB) 且超过上限:
    /// 验证读取期间强制截断, 且持续排空不阻塞子进程.
    private static func probeOutputCapTruncatesAndDrains() async throws {
        let cap = 1_024
        let probe = AsyncProcessProbe(timeout: 10, maxOutputBytes: cap)
        let start = Date()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "yes X | head -c 200000"]
        )
        let elapsed = Date().timeIntervalSince(start)
        guard case .success(let output) = result else {
            throw CoreTestFailure.expectation("should succeed, got \(result)")
        }
        try coreExpect(
            output.utf8.count <= cap,
            "output should be capped at \(cap), got \(output.utf8.count)"
        )
        try coreExpect(
            elapsed < 8,
            "large output should not block the child, took \(elapsed)s"
        )
    }

    // MARK: - SQLiteSchemaProbe (临时目录 fixture, 不读真实数据库)

    /// 用 /usr/bin/sqlite3 在临时目录构造 fixture 数据库.
    private static func createSQLiteFixture(at url: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CoreTestFailure.expectation(
                "fixture creation failed: \(process.terminationStatus)"
            )
        }
    }

    private static let ccSwitchFixtureSQL = """
        CREATE TABLE providers (
            id TEXT, name TEXT, app_type TEXT,
            settings_config TEXT, meta TEXT, is_current INTEGER
        );
        CREATE TABLE model_pricing (
            model_id TEXT,
            input_cost_per_million REAL,
            output_cost_per_million REAL,
            cache_read_cost_per_million REAL,
            cache_creation_cost_per_million REAL
        );
        """

    private static func makeTempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-\(label)-\(UUID().uuidString)")
    }

    private static func sqliteProbeAvailableForValidSchema() async throws {
        let tempDir = makeTempDir("sqlite-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: ccSwitchFixtureSQL)
        let bytesBefore = try Data(contentsOf: dbURL)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .available, "should be available, got \(result)")

        // 只读探测不得修改数据库文件
        let bytesAfter = try Data(contentsOf: dbURL)
        try coreExpect(bytesBefore == bytesAfter, "probe must not modify the database")
    }

    private static func sqliteProbeMissingPath() async throws {
        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(
            fileURL: URL(fileURLWithPath: "/nonexistent/db-\(UUID().uuidString).db"),
            profile: .ccSwitch
        )
        try coreExpect(result == .missing, "should be missing, got \(result)")
    }

    private static func sqliteProbeIncompatibleWhenMissingTable() async throws {
        let tempDir = makeTempDir("sqlite-notable")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("partial.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            """)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .incompatible, "should be incompatible, got \(result)")
    }

    private static func sqliteProbeIncompatibleWhenMissingColumn() async throws {
        let tempDir = makeTempDir("sqlite-nocol")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("nocol.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (id TEXT, name TEXT);
            CREATE TABLE model_pricing (
                model_id TEXT,
                input_cost_per_million REAL,
                output_cost_per_million REAL,
                cache_read_cost_per_million REAL,
                cache_creation_cost_per_million REAL
            );
            """)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .incompatible, "should be incompatible, got \(result)")
    }

    /// 列名互为子串的误判陷阱: 表里有 meta_extra, 但契约要求 meta.
    /// 旧的 contains 判断会误判为兼容, 逐行精确解析必须拒绝.
    private static func sqliteProbeRejectsSubstringColumnTrap() async throws {
        let tempDir = makeTempDir("sqlite-trap")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("trap.db")
        try createSQLiteFixture(at: dbURL, sql:
            "CREATE TABLE trap (id TEXT, meta_extra TEXT);")

        let profile = SQLiteSchemaProfile(
            displayName: "Trap",
            tables: ["trap": ["id", "meta"]]
        )
        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: profile)
        try coreExpect(
            result == .incompatible,
            "substring column must be rejected, got \(result)"
        )
    }

    private static func sqliteProbeCorruptedForGarbageFile() async throws {
        let tempDir = makeTempDir("sqlite-corrupt")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("garbage.db")
        var garbage = Data()
        for _ in 0..<256 {
            garbage.append(contentsOf: [UInt8](repeating: 0xAB, count: 16))
        }
        try garbage.write(to: dbURL)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .corrupted, "should be corrupted, got \(result)")
    }

    /// locked 判定单元测试: 以 stderr 消息为准, 不把任意非零退出当锁定.
    /// 真实的并发锁定场景依赖时序, 无法确定性构造, 这里只验证分类逻辑.
    private static func sqliteLockedDetectionUsesStderr() throws {
        try coreExpect(
            SQLiteSchemaProbe.isLocked(stderrSummary: "Error: database is locked"),
            "locked message should map to locked"
        )
        try coreExpect(
            SQLiteSchemaProbe.isLocked(stderrSummary: "Error: database is busy"),
            "busy message should map to locked"
        )
        try coreExpect(
            !SQLiteSchemaProbe.isLocked(stderrSummary: "Error: no such table: foo"),
            "other errors must not map to locked"
        )
        try coreExpect(
            !SQLiteSchemaProbe.isLocked(stderrSummary: nil),
            "nil stderr must not map to locked"
        )
    }

    private static func sqliteTableInfoParsesColumnNames() throws {
        let output = """
            0|id|INTEGER|0||1
            1|name|TEXT|1||0
            2|meta|TEXT|0||0
            """
        let names = SQLiteSchemaProbe.tableInfoColumnNames(output)
        try coreExpect(names == ["id", "name", "meta"], "parse mismatch: \(names)")
        try coreExpect(
            !names.contains("nam"), "substring must not match"
        )
    }

    // MARK: - Keychain (独立测试 service, 不触碰正式凭证)

    private static let keychainTestService = "com.mddd.dashboard.credentials.harness"

    /// 验证 update 优先语义: 预置旧值后 savePAT 是就地更新而非先删后加,
    /// 任何时刻凭证不丢失; 测试结束清理测试项.
    private static func keychainUpdatePreservesAndOverwrites() throws {
        let store = KeychainCredentialStore(service: keychainTestService)
        let host = "harness-\(UUID().uuidString).example.com"
        defer { try? store.deletePAT(forHost: host) }

        try store.savePAT("glpat-old-value", forHost: host)
        let first = try store.loadPAT(forHost: host)
        try coreExpect(first == "glpat-old-value", "initial save failed")

        // 再次保存必须是更新语义: 新值可读, 且过程中不经过"已删除"窗口
        try store.savePAT("glpat-new-value", forHost: host)
        let updated = try store.loadPAT(forHost: host)
        try coreExpect(
            updated == "glpat-new-value",
            "update should overwrite, got \(String(describing: updated))"
        )

        try store.deletePAT(forHost: host)
        let deleted = try store.loadPAT(forHost: host)
        try coreExpect(deleted == nil, "delete should remove the item")
    }

    // MARK: - LocalDependencyScanner (全部注入临时路径)

    /// 构造可执行的假脚本并返回路径.
    private static func makeExecutableScript(
        in dir: URL, name: String, body: String
    ) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(
            to: url, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url.path
    }

    private static func scannerFindsPythonSessionsAndSQLite() async throws {
        let tempDir = makeTempDir("scanner-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakePython = try makeExecutableScript(
            in: tempDir, name: "python3",
            body: "echo 'Python 3.11.4'"
        )
        let fakeGh = try makeExecutableScript(
            in: tempDir, name: "gh",
            body: "echo 'gh version 2.50.0 (2024-01-01)'"
        )
        let sessionDir = tempDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: ccSwitchFixtureSQL)

        let paths = LocalDependencyScanPaths(
            userPreferredPythonPath: fakePython,
            pythonCandidates: ["/nonexistent/python3"],
            userPreferredGhPath: fakeGh,
            ghCandidates: ["/nonexistent/gh"],
            sessionDirectories: [
                .init(displayName: "Kimi Code CLI", url: sessionDir),
                .init(displayName: "Claude Code",
                      url: tempDir.appendingPathComponent("absent")),
            ],
            sqliteDatabases: [
                .init(profile: .ccSwitch, url: dbURL),
            ]
        )
        let scanner = LocalDependencyScanner(paths: paths)
        let probes = await scanner.scan()

        let python = probes.first { $0.kind == .python }
        try coreExpect(python?.status == .available, "python should be available")
        try coreExpect(
            python?.detail?.contains("3.11.4") == true,
            "python detail mismatch: \(String(describing: python?.detail))"
        )
        let gh = probes.first { $0.kind == .ghCli }
        try coreExpect(gh?.status == .available, "gh should be available")
        let sessions = probes.filter { $0.kind == .sessionDirectory }
        try coreExpect(sessions.count == 2, "should have 2 session probes")
        try coreExpect(
            sessions.first { $0.detail == "Kimi Code CLI" }?.status == .available,
            "Kimi session dir should be available"
        )
        try coreExpect(
            sessions.first { $0.detail == "Claude Code" }?.status == .missing,
            "Claude session dir should be missing"
        )
        let sqlite = probes.first { $0.kind == .sqliteDatabase }
        try coreExpect(sqlite?.status == .available, "sqlite should be available")
        try coreExpect(sqlite?.detail == "CC Switch", "sqlite detail should be display name")
    }

    private static func scannerReportsMissingPythonAndGh() async throws {
        let paths = LocalDependencyScanPaths(
            pythonCandidates: ["/nonexistent/python3-a", "/nonexistent/python3-b"],
            ghCandidates: ["/nonexistent/gh"],
            sessionDirectories: [],
            sqliteDatabases: []
        )
        let scanner = LocalDependencyScanner(paths: paths)
        let probes = await scanner.scan()
        let python = probes.first { $0.kind == .python }
        let gh = probes.first { $0.kind == .ghCli }
        try coreExpect(python?.status == .missing, "python should be missing")
        try coreExpect(gh?.status == .missing, "gh should be missing")
    }

    // MARK: - ProviderConnectionVerifier

    /// 可注入的假 URLSession, 记录请求并返回预设响应.
    private final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedRequest: URLRequest?
        let handler: (URLRequest) throws -> (Data, URLResponse)

        init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        var lastRequest: URLRequest? {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequest
        }

        private func record(_ request: URLRequest) {
            lock.lock()
            recordedRequest = request
            lock.unlock()
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            record(request)
            return try handler(request)
        }
    }

    private static func gitlabURLNormalizationAcceptsHTTPS() throws {
        let url = ProviderConnectionVerifier.normalizedGitLabBaseURL(
            "  https://GitLab.Example.com/  "
        )
        try coreExpect(url != nil, "valid https URL should parse")
        try coreExpect(url?.host == "gitlab.example.com", "host should be lowercased")
        try coreExpect(
            url?.absoluteString.hasSuffix("/") == false,
            "trailing slash should be stripped"
        )
        let withPort = ProviderConnectionVerifier.normalizedGitLabBaseURL(
            "https://gitlab.example.com:8443"
        )
        try coreExpect(withPort?.port == 8443, "port should be preserved")
    }

    private static func gitlabURLRejectsNonHTTPSAndCredentials() throws {
        let rejected = [
            "http://gitlab.example.com",
            "https://user@gitlab.example.com",
            "https://user:pass@gitlab.example.com",
            "https://gitlab.example.com?foo=bar",
            "https://gitlab.example.com#frag",
            "",
            "not a url",
        ]
        for raw in rejected {
            try coreExpect(
                ProviderConnectionVerifier.normalizedGitLabBaseURL(raw) == nil,
                "\(raw) should be rejected"
            )
        }
    }

    private static func gitlabVerifyConnectedWithMockSession() async throws {
        let baseURL = URL(string: "https://gitlab.example.com")!
        let session = MockURLSession { request in
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
        let verifier = ProviderConnectionVerifier()
        let status = await verifier.verifyGitLab(
            baseURL: baseURL, pat: "fixture-pat-value", session: session
        )
        try coreExpect(status == .connected, "200 should map to connected, got \(status)")
        let request = session.lastRequest
        try coreExpect(
            request?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "fixture-pat-value",
            "PAT must be sent via PRIVATE-TOKEN header"
        )
        try coreExpect(
            request?.url?.absoluteString == "https://gitlab.example.com/api/v4/user",
            "must call same-host /api/v4/user, got \(String(describing: request?.url))"
        )
    }

    private static func gitlabVerifyExpiredOn401And403() async throws {
        let baseURL = URL(string: "https://gitlab.example.com")!
        for code in [401, 403] {
            let session = MockURLSession { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!, statusCode: code,
                        httpVersion: nil, headerFields: nil
                    )!
                )
            }
            let verifier = ProviderConnectionVerifier()
            let status = await verifier.verifyGitLab(
                baseURL: baseURL, pat: "glpat-expired", session: session
            )
            try coreExpect(status == .expired, "\(code) should map to expired, got \(status)")
        }
    }

    private static func gitlabVerifyUnreachableOnNetworkError() async throws {
        let baseURL = URL(string: "https://gitlab.example.com")!
        // DNS, TLS 和超时等 URLError 都映射为 unreachable, 保留可重试语义
        let errors: [URLError.Code] = [.cannotFindHost, .timedOut, .secureConnectionFailed]
        for code in errors {
            let session = MockURLSession { _ in
                throw URLError(code)
            }
            let verifier = ProviderConnectionVerifier()
            let status = await verifier.verifyGitLab(
                baseURL: baseURL, pat: "glpat-any", session: session
            )
            try coreExpect(
                status == .unreachable,
                "\(code) should map to unreachable, got \(status)"
            )
        }
    }

    private static func gitlabRedirectPolicyAllowsSameHostOnly() throws {
        let original = URL(string: "https://gitlab.example.com/api/v4/user")!
        try coreExpect(
            GitLabRedirectPolicy.allowsRedirect(
                from: original,
                to: URL(string: "https://gitlab.example.com/login")!
            ),
            "same host redirect should be allowed"
        )
        try coreExpect(
            !GitLabRedirectPolicy.allowsRedirect(
                from: original,
                to: URL(string: "https://evil.example.net/steal")!
            ),
            "cross host redirect must be rejected"
        )
        try coreExpect(
            !GitLabRedirectPolicy.allowsRedirect(
                from: original,
                to: URL(string: "https://sub.gitlab.example.com/x")!
            ),
            "subdomain must be rejected"
        )
    }

    /// 用假 gh 脚本验证登录态映射, 不调用真实 gh, 不接触真实登录态.
    private static func githubStatusCheckMappings() async throws {
        let tempDir = makeTempDir("gh-fake")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loggedInGh = try makeExecutableScript(in: tempDir, name: "gh-ok", body: "exit 0")
        let loggedOutGh = try makeExecutableScript(in: tempDir, name: "gh-no", body: "exit 1")

        let verifier = ProviderConnectionVerifier()
        let connected = await verifier.checkGitHubStatus(
            ghPath: loggedInGh, hasConnectedBefore: false
        )
        try coreExpect(connected == .connected, "exit 0 should be connected")

        let pending = await verifier.checkGitHubStatus(
            ghPath: loggedOutGh, hasConnectedBefore: false
        )
        try coreExpect(
            pending == .pendingAuthorization,
            "never connected failure should be pendingAuthorization, got \(pending)"
        )
        let expired = await verifier.checkGitHubStatus(
            ghPath: loggedOutGh, hasConnectedBefore: true
        )
        try coreExpect(
            expired == .expired,
            "previously connected failure should be expired, got \(expired)"
        )
    }

    // MARK: - 首次启动决策流 (临时目录配置, 只用 Core 类型)

    /// 完整决策流: 无授权全部 denied -> 写入授权后仅选中且 ready 的模块
    /// allowed -> 授权版本变化后全部 denied.
    private static func firstLaunchDecisionFlow() throws {
        let tempDir = makeTempDir("first-launch")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let readiness: [CollectorModule: ModuleReadiness] = [
            .agentUsage: .ready,
            .github: .ready,
            .gitlab: .ready,
        ]

        // 阶段 1: 无授权记录, 所有模块 denied
        let initialGate = CollectorActivationGate(
            consentVersion: 1,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        let initialDecisions = ActivationGateEvaluator(gate: initialGate).evaluate(
            readinessByModule: readiness,
            selectedModules: Set(CollectorModule.allCases),
            appIsAcceptingNewTasks: true
        )
        try coreExpect(
            initialDecisions.allSatisfy { !$0.allowed },
            "无授权时所有模块必须 denied"
        )
        try coreExpect(
            initialDecisions.allSatisfy { $0.policy == nil },
            "无授权时不得生成执行策略"
        )

        // 阶段 2: 写入授权 (选中 agentUsage 和 github, github 未 ready),
        // 仅选中且 ready 的 agentUsage allowed
        var config = store.load() ?? OnboardingConfiguration()
        config.consentVersion = 1
        config.selectedModules = ["agent-usage", "github"]
        try store.save(config)

        let confirmedGate = CollectorActivationGate(
            consentVersion: 1,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        let confirmedDecisions = ActivationGateEvaluator(
            gate: confirmedGate
        ).evaluate(
            readinessByModule: [
                .agentUsage: .ready,
                .github: .pendingAuthorization,
                .gitlab: .ready,
            ],
            selectedModules: Set(
                (store.load()?.selectedModules ?? []).compactMap {
                    CollectorModule(rawValue: $0)
                }
            ),
            appIsAcceptingNewTasks: true
        )
        let agentDecision = confirmedDecisions.first { $0.module == .agentUsage }
        let githubDecision = confirmedDecisions.first { $0.module == .github }
        let gitlabDecision = confirmedDecisions.first { $0.module == .gitlab }
        try coreExpect(
            agentDecision?.allowed == true,
            "选中且 ready 的 agent-usage 必须 allowed"
        )
        try coreExpect(
            agentDecision?.policy?.capabilities == [.localSessions, .localPricing],
            "agent 策略只含 localSessions/localPricing"
        )
        try coreExpect(
            githubDecision?.allowed == false,
            "github 未 ready 必须 denied"
        )
        try coreExpect(
            gitlabDecision?.allowed == false,
            "未选中的 gitlab 必须 denied"
        )

        // 阶段 3: 授权版本升级后, 已确认版本不再匹配, 全部 denied
        let upgradedGate = CollectorActivationGate(
            consentVersion: 2,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        let upgradedDecisions = ActivationGateEvaluator(gate: upgradedGate).evaluate(
            readinessByModule: readiness,
            selectedModules: Set(CollectorModule.allCases),
            appIsAcceptingNewTasks: true
        )
        try coreExpect(
            upgradedDecisions.allSatisfy { !$0.allowed },
            "授权版本变化后所有模块必须 denied"
        )
    }

    // MARK: - 订阅额度配置 (schema v2)

    /// v1 配置文件没有 subscriptionProviders 键, 加载必须按缺省处理且不崩溃.
    private static func configStoreLoadsV1WithSubscriptionDefaults() throws {
        let tempDir = makeTempDir("config-v1")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let v1Config: [String: Any] = [
            "schemaVersion": 1,
            "selectedModules": ["github"],
            "consentVersion": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: v1Config)
        let configURL = tempDir.appendingPathComponent("onboarding-v1.json")
        try data.write(to: configURL)

        let loaded = store.load()
        try coreExpect(loaded != nil, "v1 配置必须可加载")
        try coreExpect(
            loaded?.subscriptionProviders.isEmpty == true,
            "v1 配置的订阅 provider 必须按缺省 (空) 处理"
        )
        try coreExpect(
            loaded?.selectedModules == ["github"],
            "v1 配置的既有字段必须保留"
        )
        try coreExpect(
            OnboardingConfiguration.currentSchemaVersion == 2,
            "当前 schema 版本必须为 2"
        )
    }

    /// 高于当前版本 (v3) 的配置必须拒绝加载.
    private static func configStoreRejectsNewerSchemaV3() throws {
        let tempDir = makeTempDir("config-v3")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let v3Config: [String: Any] = [
            "schemaVersion": 3,
            "selectedModules": ["github"],
        ]
        let data = try JSONSerialization.data(withJSONObject: v3Config)
        let configURL = tempDir.appendingPathComponent("onboarding-v1.json")
        try data.write(to: configURL)

        try coreExpect(store.load() == nil, "v3 配置必须拒绝加载")
    }

    /// 订阅 provider 配置 (含 failed 原因与 needsRelogin) 原子读写往返一致.
    private static func configStoreSubscriptionProvidersRoundTrip() throws {
        let tempDir = makeTempDir("config-sub")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        var config = OnboardingConfiguration(consentVersion: 1)
        config.subscriptionProviders = [
            SubscriptionProviderID.kimi.rawValue: SubscriptionProviderConfiguration(
                enabled: true,
                lastVerifiedAt: "2026-07-30T12:00:00+08:00",
                verificationStatus: .ok
            ),
            SubscriptionProviderID.deepseek.rawValue: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .failed(reason: "API key 无效或已过期")
            ),
            SubscriptionProviderID.codex.rawValue: SubscriptionProviderConfiguration(
                enabled: false,
                verificationStatus: .needsRelogin
            ),
        ]
        try store.save(config)
        let loaded = store.load()

        try coreExpect(loaded != nil, "配置必须可加载")
        let kimi = loaded?.subscriptionProviders[SubscriptionProviderID.kimi.rawValue]
        try coreExpect(kimi?.enabled == true, "kimi enabled 丢失")
        try coreExpect(
            kimi?.verificationStatus == .ok,
            "kimi 验证状态丢失, got \(String(describing: kimi?.verificationStatus))"
        )
        try coreExpect(
            kimi?.lastVerifiedAt == "2026-07-30T12:00:00+08:00",
            "kimi lastVerifiedAt 丢失"
        )
        let deepseek = loaded?.subscriptionProviders[
            SubscriptionProviderID.deepseek.rawValue
        ]
        try coreExpect(
            deepseek?.verificationStatus == .failed(reason: "API key 无效或已过期"),
            "deepseek failed 原因丢失"
        )
        let codex = loaded?.subscriptionProviders[
            SubscriptionProviderID.codex.rawValue
        ]
        try coreExpect(
            codex?.verificationStatus == .needsRelogin,
            "codex needsRelogin 状态丢失"
        )
    }

    // MARK: - 订阅凭证 account 键 (内存实现)

    /// 七个新 account 键的增删改查与隔离; PAT 键不受影响.
    private static func credentialStoreSubscriptionAccountsRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let accounts = [
            SubscriptionCredentialAccount.kimiWebTokens,
            SubscriptionCredentialAccount.deepseekAPIKey,
            SubscriptionCredentialAccount.volcengineAccessKey,
            SubscriptionCredentialAccount.volcengineSecretKey,
            SubscriptionCredentialAccount.codexAccounts,
            SubscriptionCredentialAccount.codexActiveAccount,
            SubscriptionCredentialAccount.antigravityOAuth,
        ]
        for (index, account) in accounts.enumerated() {
            try store.saveCredential("value-\(index)", forAccount: account)
        }
        for (index, account) in accounts.enumerated() {
            let loaded = try store.loadCredential(forAccount: account)
            try coreExpect(
                loaded == "value-\(index)",
                "\(account) 往返失败, got \(String(describing: loaded))"
            )
        }
        // update 优先语义: 覆盖写不经过删除窗口
        try store.saveCredential(
            "{\"access_token\":\"a2\",\"refresh_token\":\"r2\"}",
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        let updated = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        try coreExpect(
            updated?.contains("\"access_token\":\"a2\"") == true,
            "kimi:web-tokens 覆盖写失败"
        )

        try store.deleteCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let deleted = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try coreExpect(deleted == nil, "deepseek:api-key 删除失败")
        let intact = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.volcengineAccessKey
        )
        try coreExpect(intact == "value-2", "其他 account 键被误删")

        // PAT 与订阅 account 共用存储但键空间隔离
        try store.savePAT("glpat-x", forHost: "gitlab.example.com")
        let pat = try store.loadPAT(forHost: "gitlab.example.com")
        try coreExpect(pat == "glpat-x", "PAT 读写受影响")
    }

    // MARK: - 订阅凭证 account 键 (真实 Keychain, 独立测试 service)

    /// 真实 Keychain 验证新 account 键的 update 优先语义;
    /// 使用独立 harness service, 测试结束清理, 不触碰正式凭证.
    private static func keychainSubscriptionAccountsRoundTrip() throws {
        let store = KeychainCredentialStore(service: keychainTestService)
        let suffix = UUID().uuidString
        let kimiAccount = SubscriptionCredentialAccount.kimiWebTokens
        let volcAK = SubscriptionCredentialAccount.volcengineAccessKey
        defer {
            try? store.deleteCredential(forAccount: kimiAccount)
            try? store.deleteCredential(forAccount: volcAK)
        }

        let tokensV1 = "{\"access_token\":\"a-\(suffix)\",\"refresh_token\":\"r-\(suffix)\"}"
        try store.saveCredential(tokensV1, forAccount: kimiAccount)
        let first = try store.loadCredential(forAccount: kimiAccount)
        try coreExpect(first == tokensV1, "kimi:web-tokens 初次写入失败")

        let tokensV2 = "{\"access_token\":\"a2-\(suffix)\",\"refresh_token\":\"r2-\(suffix)\"}"
        try store.saveCredential(tokensV2, forAccount: kimiAccount)
        let updated = try store.loadCredential(forAccount: kimiAccount)
        try coreExpect(
            updated == tokensV2,
            "kimi:web-tokens update 覆盖失败, got \(String(describing: updated))"
        )

        try store.saveCredential("AK\(suffix.replacingOccurrences(of: "-", with: ""))",
                                 forAccount: volcAK)
        let ak = try store.loadCredential(forAccount: volcAK)
        try coreExpect(ak?.hasPrefix("AK") == true, "volcengine:ak 写入失败")

        try store.deleteCredential(forAccount: kimiAccount)
        let deleted = try store.loadCredential(forAccount: kimiAccount)
        try coreExpect(deleted == nil, "kimi:web-tokens 删除失败")
        let intactAK = try store.loadCredential(forAccount: volcAK)
        try coreExpect(intactAK != nil, "volcengine:ak 被误删")
    }

    // MARK: - 订阅 provider 验证器

    /// DeepSeek 200 -> ok; 请求必须带 Bearer header 且指向 user/balance.
    private static func verifierDeepSeekConnectedWithMockSession() async throws {
        let session = MockURLSession { request in
            (
                Data("{\"balance_infos\":[]}".utf8),
                HTTPURLResponse(
                    url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!
            )
        }
        let verifier = ProviderConnectionVerifier()
        let status = await verifier.verifyDeepSeek(
            apiKey: "sk-fixture-key", session: session
        )
        try coreExpect(status == .ok, "200 必须映射 ok, got \(status)")
        let request = session.lastRequest
        try coreExpect(
            request?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-fixture-key",
            "API key 必须经 Bearer header 发送"
        )
        try coreExpect(
            request?.url?.absoluteString == "https://api.deepseek.com/user/balance",
            "必须请求 user/balance, got \(String(describing: request?.url))"
        )
    }

    /// fail-closed: 401/403, 网络错误和空 key 一律 failed, 不静默通过.
    private static func verifierDeepSeekFailClosed() async throws {
        let verifier = ProviderConnectionVerifier()

        for code in [401, 403] {
            let session = MockURLSession { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!, statusCode: code,
                        httpVersion: nil, headerFields: nil
                    )!
                )
            }
            let status = await verifier.verifyDeepSeek(
                apiKey: "sk-expired", session: session
            )
            guard case .failed = status else {
                throw CoreTestFailure.expectation(
                    "\(code) 必须映射 failed, got \(status)"
                )
            }
        }

        let networkFail = MockURLSession { _ in
            throw URLError(.cannotFindHost)
        }
        let unreachable = await verifier.verifyDeepSeek(
            apiKey: "sk-any", session: networkFail
        )
        guard case .failed = unreachable else {
            throw CoreTestFailure.expectation(
                "网络错误必须映射 failed, got \(unreachable)"
            )
        }

        // 空 key 不得发起网络请求
        let emptyKey = await verifier.verifyDeepSeek(apiKey: "   ")
        guard case .failed(let reason) = emptyKey else {
            throw CoreTestFailure.expectation(
                "空 key 必须映射 failed, got \(emptyKey)"
            )
        }
        try coreExpect(reason == "API key 为空", "空 key 原因不符: \(reason)")
    }

    private static func verifierKimiWebTokensJSONMappings() throws {
        let ok = ProviderConnectionVerifier.verifyKimiWebTokensJSON(
            "{\"access_token\":\"a\",\"refresh_token\":\"r\"}"
        )
        try coreExpect(ok == .ok, "完整令牌必须 ok, got \(ok)")

        let relogin = ProviderConnectionVerifier.verifyKimiWebTokensJSON(
            "{\"access_token\":\"a\"}"
        )
        try coreExpect(
            relogin == .needsRelogin,
            "缺 refresh_token 必须 needsRelogin, got \(relogin)"
        )

        let invalid = ProviderConnectionVerifier.verifyKimiWebTokensJSON("not json")
        guard case .failed = invalid else {
            throw CoreTestFailure.expectation("非法 JSON 必须 failed, got \(invalid)")
        }
        let empty = ProviderConnectionVerifier.verifyKimiWebTokensJSON("{}")
        guard case .failed = empty else {
            throw CoreTestFailure.expectation("空对象必须 failed, got \(empty)")
        }
    }

    private static func verifierCodexAccountsJSONMappings() throws {
        let valid = """
            {"accounts": {"acc-1": {"email": "u@example.com",
             "refresh_token": "rt", "access_token": "at", "id_token": "it"}}}
            """
        try coreExpect(
            ProviderConnectionVerifier.verifyCodexAccountsJSON(valid) == .ok,
            "完整账号库必须 ok"
        )
        let noAccounts = ProviderConnectionVerifier.verifyCodexAccountsJSON(
            "{\"accounts\": {}}"
        )
        guard case .failed = noAccounts else {
            throw CoreTestFailure.expectation("空 accounts 必须 failed")
        }
        let noRefresh = ProviderConnectionVerifier.verifyCodexAccountsJSON(
            "{\"accounts\": {\"acc-1\": {\"access_token\": \"at\"}}}"
        )
        guard case .failed(let reason) = noRefresh else {
            throw CoreTestFailure.expectation("缺 refresh_token 必须 failed")
        }
        try coreExpect(
            reason.contains("refresh_token"),
            "failed 原因必须指出缺失字段, got \(reason)"
        )
        let invalid = ProviderConnectionVerifier.verifyCodexAccountsJSON("[]")
        guard case .failed = invalid else {
            throw CoreTestFailure.expectation("非对象 JSON 必须 failed")
        }
    }

    private static func verifierAntigravityOAuthJSONMappings() throws {
        let valid = """
            {"token": {"access_token": "at", "refresh_token": "rt",
             "expiry": "2026-07-30T12:00:00Z"}}
            """
        try coreExpect(
            ProviderConnectionVerifier.verifyAntigravityOAuthJSON(valid) == .ok,
            "完整令牌文件必须 ok"
        )
        // access_token 可由 collector 刷新恢复, 仅 refresh_token 必备
        let refreshOnly = ProviderConnectionVerifier.verifyAntigravityOAuthJSON(
            "{\"token\": {\"refresh_token\": \"rt\"}}"
        )
        try coreExpect(refreshOnly == .ok, "仅 refresh_token 必须 ok")
        let noToken = ProviderConnectionVerifier.verifyAntigravityOAuthJSON("{}")
        guard case .failed = noToken else {
            throw CoreTestFailure.expectation("缺 token 节点必须 failed")
        }
        let noRefresh = ProviderConnectionVerifier.verifyAntigravityOAuthJSON(
            "{\"token\": {\"access_token\": \"at\"}}"
        )
        guard case .failed = noRefresh else {
            throw CoreTestFailure.expectation("缺 refresh_token 必须 failed")
        }
    }

    private static func verifierVolcengineCredentialsMappings() throws {
        try coreExpect(
            ProviderConnectionVerifier.verifyVolcengineCredentials(
                accessKey: "AKLTfixture-ak",
                secretKey: "fixture-secret-key-0123456789"
            ) == .ok,
            "合理 AK/SK 必须 ok"
        )
        let cases: [(String, String)] = [
            ("", "fixture-secret-key-0123456789"),
            ("AKLTfixture-ak", ""),
            ("AK with space", "fixture-secret-key-0123456789"),
            ("short", "fixture-secret-key-0123456789"),
        ]
        for (ak, sk) in cases {
            guard case .failed = ProviderConnectionVerifier
                .verifyVolcengineCredentials(accessKey: ak, secretKey: sk) else {
                throw CoreTestFailure.expectation(
                    "AK=\(ak) SK=\(sk) 必须 failed"
                )
            }
        }
    }

    // MARK: - externalQuotas 门禁

    /// agent-usage 策略: 订阅 provider 已配置时追加 externalQuotas,
    /// 默认 (未配置) 不授予.
    private static func gateAgentPolicyGrantsExternalQuotasWhenConfigured() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)

        let withoutProvider = gate.executionPolicy(for: .agentUsage, readiness: .ready)
        try coreExpect(
            withoutProvider?.capabilities.contains(.externalQuotas) == false,
            "未配置订阅 provider 时不得授予 externalQuotas"
        )
        let withProvider = gate.executionPolicy(
            for: .agentUsage,
            readiness: .ready,
            hasConfiguredSubscriptionProvider: true
        )
        try coreExpect(
            withProvider?.capabilities.contains(.externalQuotas) == true,
            "订阅 provider 已配置时必须授予 externalQuotas"
        )
        try coreExpect(
            withProvider?.capabilities.contains(.localSessions) == true
                && withProvider?.capabilities.contains(.localPricing) == true,
            "基础能力必须保留"
        )
    }

    /// evaluator 把订阅配置标记透传到策略; 未授权时仍不生成策略.
    private static func gateEvaluatorPropagatesSubscriptionFlag() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let evaluator = ActivationGateEvaluator(gate: gate)
        let decisions = evaluator.evaluate(
            readinessByModule: [.agentUsage: .ready],
            selectedModules: [.agentUsage],
            appIsAcceptingNewTasks: true,
            hasConfiguredSubscriptionProvider: true
        )
        let agent = decisions.first { $0.module == .agentUsage }
        try coreExpect(
            agent?.policy?.capabilities.contains(.externalQuotas) == true,
            "evaluator 必须透传订阅配置标记"
        )

        let deniedGate = CollectorActivationGate(
            consentVersion: 2, confirmedConsentVersion: 1
        )
        let deniedDecisions = ActivationGateEvaluator(gate: deniedGate).evaluate(
            readinessByModule: [.agentUsage: .ready],
            selectedModules: [.agentUsage],
            appIsAcceptingNewTasks: true,
            hasConfiguredSubscriptionProvider: true
        )
        let deniedAgent = deniedDecisions.first { $0.module == .agentUsage }
        try coreExpect(
            deniedAgent?.allowed == false && deniedAgent?.policy == nil,
            "授权不匹配时即使已配置订阅 provider 也必须 deny"
        )
    }

    // MARK: - 订阅凭证导入纯逻辑 (全部临时目录 fixture, 禁真实主目录)

    /// 与 collect_usage.py _volc_decode_secret 对齐: 非 base64 立即停止,
    /// 只保留原始候选. "notbase64!" 去掉非字母表字符后长度 % 4 == 1, 必然解码失败.
    private static func volcDecoderStopsWhenNotBase64() throws {
        let candidates = VolcengineSecretDecoder.decodeCandidates("notbase64!")
        try coreExpect(candidates == ["notbase64!"], "非 base64 必须只保留 raw, got \(candidates)")
    }

    /// 一次编码与两次编码都要完整展开候选链.
    private static func volcDecoderSingleAndDoubleEncoded() throws {
        let plain = "sk-real-secret-0001"
        let single = Data(plain.utf8).base64EncodedString()
        let double = Data(single.utf8).base64EncodedString()
        try coreExpect(
            VolcengineSecretDecoder.decodeCandidates(single) == [single, plain],
            "一次编码候选链不符"
        )
        try coreExpect(
            VolcengineSecretDecoder.decodeCandidates(double) == [double, single, plain],
            "两次编码候选链不符"
        )
    }

    /// 导入 Keychain 取最深成功解码; 不可解码时保留 raw.
    private static func volcFullyDecodedPicksDeepestCandidate() throws {
        let plain = "sk-real-secret-0002"
        let double = Data(Data(plain.utf8).base64EncodedString().utf8)
            .base64EncodedString()
        try coreExpect(
            VolcengineSecretDecoder.fullyDecoded(double) == plain,
            "两次编码必须解到原文"
        )
        try coreExpect(
            VolcengineSecretDecoder.fullyDecoded("notbase64!") == "notbase64!",
            "不可解码必须保留 raw"
        )
    }

    private static func kimiPasteParsesFullJSON() throws {
        let result = KimiPasteParser.parse(
            " {\"access_token\":\"a1\",\"refresh_token\":\"r1\"} "
        )
        guard case .success(let json) = result else {
            throw CoreTestFailure.expectation("整段 JSON 必须解析成功, got \(result)")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(json) == .ok,
            "解析结果必须通过结构校验"
        )
    }

    /// 两段 token (空白或换行分隔) 与单段 token 的映射.
    private static func kimiPasteParsesTokenPairs() throws {
        guard case .success(let pair) = KimiPasteParser.parse("a2\nr2") else {
            throw CoreTestFailure.expectation("两段 token 必须解析成功")
        }
        try coreExpect(
            pair.contains("\"access_token\":\"a2\"")
                && pair.contains("\"refresh_token\":\"r2\""),
            "两段 token 顺序映射不符: \(pair)"
        )
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(pair) == .ok,
            "两段 token 必须 ok"
        )
        // 单段 token 只有 access, 结构校验必须 needsRelogin
        guard case .success(let single) = KimiPasteParser.parse("a-only") else {
            throw CoreTestFailure.expectation("单段 token 必须解析成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyKimiWebTokensJSON(single) == .needsRelogin,
            "单段 token 必须 needsRelogin"
        )
    }

    private static func kimiPasteRejectsEmptyAndBrokenJSON() throws {
        guard case .failure(let empty) = KimiPasteParser.parse("   ") else {
            throw CoreTestFailure.expectation("空输入必须失败")
        }
        guard case .missingField = empty else {
            throw CoreTestFailure.expectation("空输入必须 missingField, got \(empty)")
        }
        guard case .failure(let broken) = KimiPasteParser.parse("{not json") else {
            throw CoreTestFailure.expectation("坏 JSON 必须失败")
        }
        try coreExpect(broken == .invalidJSON, "坏 JSON 必须 invalidJSON, got \(broken)")
        guard case .failure = KimiPasteParser.parse("{}") else {
            throw CoreTestFailure.expectation("空对象必须失败")
        }
    }

    /// 结构与 collect_usage.py:1128-1143 的消费方式对齐.
    private static func codexAuthFileParsesValidAccount() throws {
        let json = """
            {"tokens": {"account_id": "acc-1", "refresh_token": "rt",
             "access_token": "at", "id_token": "it", "email": "u@example.com"}}
            """
        guard case .success(let account) = CodexAuthFileParser.parse(json) else {
            throw CoreTestFailure.expectation("合法 auth.json 必须解析成功")
        }
        try coreExpect(account.accountID == "acc-1", "account_id 不符")
        try coreExpect(account.email == "u@example.com", "email 不符")
        try coreExpect(account.refreshToken == "rt", "refresh_token 不符")
        try coreExpect(account.idToken == "it", "id_token 不符")
    }

    private static func codexAuthFileRejectsMissingFields() throws {
        let cases = [
            ("not json", "非 JSON"),
            ("{}", "缺 tokens"),
            ("{\"tokens\": {}}", "缺 account_id"),
            ("{\"tokens\": {\"account_id\": \"a\"}}", "缺 refresh_token"),
            ("{\"tokens\": {\"account_id\": \"a\", \"refresh_token\": \"rt\"}}",
             "缺 access_token"),
        ]
        for (json, label) in cases {
            guard case .failure = CodexAuthFileParser.parse(json) else {
                throw CoreTestFailure.expectation("\(label) 必须解析失败")
            }
        }
    }

    /// 合并: 空库创建, 异 id 保留, 同 id 覆盖; 合并结果必须通过账号库结构校验.
    private static func codexLibraryMergingCreatesPreservesUpdates() throws {
        let account1 = CodexCLIAuthAccount(
            accountID: "acc-1", email: "u1@example.com",
            refreshToken: "rt1", accessToken: "at1", idToken: nil
        )
        guard case .success(let created) = CodexAccountsLibrary.merging(
            existingJSON: nil, account: account1
        ) else {
            throw CoreTestFailure.expectation("空库合并必须成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyCodexAccountsJSON(created) == .ok,
            "新建账号库必须通过结构校验"
        )

        let account2 = CodexCLIAuthAccount(
            accountID: "acc-2", email: nil,
            refreshToken: "rt2", accessToken: "at2", idToken: "it2"
        )
        guard case .success(let merged) = CodexAccountsLibrary.merging(
            existingJSON: created, account: account2
        ) else {
            throw CoreTestFailure.expectation("追加合并必须成功")
        }
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: merged) == ["acc-1", "acc-2"],
            "异 id 必须保留两个账号"
        )

        let account1Updated = CodexCLIAuthAccount(
            accountID: "acc-1", email: "u1@example.com",
            refreshToken: "rt1-new", accessToken: "at1-new", idToken: nil
        )
        guard case .success(let updated) = CodexAccountsLibrary.merging(
            existingJSON: merged, account: account1Updated
        ) else {
            throw CoreTestFailure.expectation("同 id 合并必须成功")
        }
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: updated) == ["acc-1", "acc-2"],
            "同 id 覆盖不得增加账号数"
        )
        try coreExpect(
            updated.contains("rt1-new"),
            "同 id 必须覆盖为新 token"
        )
    }

    /// 摘要: 邮箱取 @ 前缀, 无 email 回落 id 前 8 位 (collect_usage.py:1148).
    private static func codexLibrarySummaryCountAndPrefixes() throws {
        let json = """
            {"accounts": {
             "acc-aaaaaaaabbbb": {"email": "alice@example.com",
              "refresh_token": "rt", "access_token": "at"},
             "acc-bbbbbbbbcccc": {"refresh_token": "rt", "access_token": "at"}}}
            """
        let summary = CodexAccountsLibrary.summary(of: json)
        try coreExpect(summary.count == 2, "账号数不符: \(summary.count)")
        try coreExpect(
            summary.emailPrefixes == ["alice", "acc-bbbb"],
            "前缀列表不符: \(summary.emailPrefixes)"
        )
        let empty = CodexAccountsLibrary.summary(of: "not json")
        try coreExpect(
            empty.count == 0 && empty.emailPrefixes.isEmpty,
            "非法 JSON 摘要必须为空"
        )
    }

    private static func codexChooseActiveAccountPriority() throws {
        let ids = ["acc-1", "acc-2"]
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: "acc-2", existingActive: "acc-1", accountIDs: ids
            ) == "acc-2",
            "CLI 当前账号必须优先"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: "gone", existingActive: "acc-1", accountIDs: ids
            ) == "acc-1",
            "CLI 不在库中必须保留既有 active"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: nil, existingActive: nil, accountIDs: ids
            ) == "acc-1",
            "都不可用必须回落第一个账号"
        )
        try coreExpect(
            CodexAccountsLibrary.chooseActiveAccount(
                cliAccountID: nil, existingActive: nil, accountIDs: []
            ) == nil,
            "空库必须返回 nil"
        )
    }

    // MARK: - CC Switch 火山导入 (临时目录 fixture, 禁写入)

    /// 构造带火山 provider 行的 CC Switch fixture 数据库.
    private static func createVolcCCSwitchFixture(
        at dbURL: URL, metaJSON: String
    ) throws {
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            INSERT INTO providers VALUES (
                'p1', '火山Codingplan', 'ark', '{}', '\(metaJSON)', 1);
            """)
    }

    /// 只读导入: AK 原样, SK 按 _volc_decode_secret 解码; 数据库字节不得变化.
    private static func ccSwitchVolcImportReadsFixtureDatabase() async throws {
        let tempDir = makeTempDir("ccvolc-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        let plainSK = "sk-real-secret-0003"
        let encodedSK = Data(plainSK.utf8).base64EncodedString()
        try createVolcCCSwitchFixture(
            at: dbURL,
            metaJSON: "{\"usage_script\": {\"accessKeyId\": \"AKLTfixture0000\", \"secretAccessKey\": \"\(encodedSK)\"}}"
        )
        let bytesBefore = try Data(contentsOf: dbURL)

        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(databaseURL: dbURL)
        guard case .success(let credentials) = result else {
            throw CoreTestFailure.expectation("导入必须成功, got \(result)")
        }
        try coreExpect(
            credentials.accessKey == "AKLTfixture0000",
            "AK 不符: \(credentials.accessKey)"
        )
        try coreExpect(
            credentials.secretKey == plainSK,
            "SK 必须解码, got \(credentials.secretKey)"
        )

        // 只读红线: 数据库文件不得被修改
        let bytesAfter = try Data(contentsOf: dbURL)
        try coreExpect(bytesBefore == bytesAfter, "导入不得修改 CC Switch 数据库")
    }

    /// CC 中无火山 provider 行时必须给出可诊断错误, 不静默为空.
    private static func ccSwitchVolcImportMissingProviderRow() async throws {
        let tempDir = makeTempDir("ccvolc-norow")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            INSERT INTO providers VALUES ('p2', 'DeepSeek', 'ds', '{}', '{}', 1);
            """)

        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(databaseURL: dbURL)
        guard case .failure(let error) = result else {
            throw CoreTestFailure.expectation("无火山行必须失败")
        }
        guard case .providerRowNotFound = error else {
            throw CoreTestFailure.expectation(
                "必须 providerRowNotFound, got \(error)"
            )
        }
    }

    private static func ccSwitchVolcImportMissingFile() async throws {
        let importer = CCSwitchVolcengineImporter()
        let result = await importer.importCredentials(
            databaseURL: URL(fileURLWithPath: "/nonexistent/cc-\(UUID().uuidString).db")
        )
        guard case .failure(let error) = result else {
            throw CoreTestFailure.expectation("文件缺失必须失败")
        }
        guard case .fileNotFound = error else {
            throw CoreTestFailure.expectation("必须 fileNotFound, got \(error)")
        }
    }

    // MARK: - 订阅配置状态迁移

    /// applyingVerification: ok 才启用; failed / needsRelogin 即使之前
    /// 已启用也必须回落禁用 (fail-closed).
    private static func subscriptionConfigApplyingVerificationTransitions() throws {
        var entry = SubscriptionProviderConfiguration()
        entry = entry.applyingVerification(.ok, verifiedAt: "2026-07-30T00:00:00Z")
        try coreExpect(entry.enabled, "ok 必须启用")
        try coreExpect(
            entry.lastVerifiedAt == "2026-07-30T00:00:00Z",
            "ok 必须记录验证时间"
        )

        let failed = entry.applyingVerification(
            .failed(reason: "API key 无效或已过期"),
            verifiedAt: "2026-07-30T01:00:00Z"
        )
        try coreExpect(!failed.enabled, "failed 必须禁用")
        try coreExpect(
            failed.verificationStatus == .failed(reason: "API key 无效或已过期"),
            "failed 必须保留原因"
        )
        try coreExpect(
            failed.lastVerifiedAt == "2026-07-30T01:00:00Z",
            "failed 必须更新验证时间"
        )

        let relogin = entry.applyingVerification(
            .needsRelogin, verifiedAt: "2026-07-30T02:00:00Z"
        )
        try coreExpect(!relogin.enabled, "needsRelogin 必须禁用")
        try coreExpect(
            relogin.verificationStatus == .needsRelogin,
            "needsRelogin 状态必须保留"
        )
    }
}
