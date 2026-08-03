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
        try gateDeniesAllBeforeConsent()
        try gateDeniesWhenConsentVersionMismatch()
        try gateAllowsAgentReady()
        try gateAllowsAgentPartial()
        try gateDeniesUnselectedModule()
        try gateDeniesWhenAppNotAcceptingTasks()
        try gateDeniesPendingAuthorization()
        try gateDeniesNetworkUnreachable()
        try agentPolicyOnlyLocalCapabilities()
        try policyNilWhenNotReady()
        try evaluatorAgentReady()
        try evaluatorAgentPartial()
        try evaluatorAgentMissingPython()
        try evaluatorAgentNoSessions()
        try evaluatorAgentCcSwitchAloneNotReady()
        try configStoreRoundTrip()
        try configStoreReturnsEmptyWhenMissing()
        try configStoreReturnsNilForUnknownSchema()
        try configStoreFilePermissions()
        try credentialStoreRoundTrip()
        try credentialStoreDelete()
        try credentialStoreIsolatesByAccount()
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
        try await scannerReportsMissingPython()
        try firstLaunchDecisionFlow()
        try configStoreLoadsV1WithSubscriptionDefaults()
        try configStoreRejectsNewerSchemaV3()
        try configStoreSubscriptionProvidersRoundTrip()
        try configRefreshIntervalDecodeAndFallback()
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
        try subscriptionUsageTrackingIDDecodeAndFallback()
        try applyingVerificationPreservesUsageTrackingID()
        try deepSeekSaveTransactionPrewriteDisabled()
        try deepSeekSaveTransactionRestoreOldEntry()
        try deepSeekSaveTransactionRestoreRemovesWhenAbsent()
        try deepSeekSaveTransactionIsolatesEachSave()
        try await probeStandardInputPipesToProcess()
        try codexPKCEVerifierFormat()
        try codexDeviceStartRequestAndParse()
        try codexDevicePollAndExchangeParsing()
        try codexIDTokenClaimsParsing()
        try await codexDeviceFullFlowStoresAccount()
        try await codexDeviceErrorPaths()
        try await codexDeviceExpiredSkipsPolling()
        try rotationMergeMapsKnownProviders()
        try rotationMergeKimiFlatTokens()
        try rotationMergeCodexRejected()
        try rotationMergeAntigravityTokenSubObject()
        try rotationMergeFiltersKeysAndRejectsUnknown()
        try CodexCredentialStoreTests.runAll()
        try await CodexOAuthClientTests.runAll()
        try await CodexTokenManagerTests.runAll()
        try await codexLoginStoresCompleteV2Record()
        try await ccSwitchDiscoveryKeepsMetadataOnly()
        try cliDiscoveryKeepsMetadataOnly()
        try await discoveryNeverWritesSourceFiles()
        try await reauthorizationReplacesOnlyCurrentAccount()
        try await disconnectRemovesRecordButKeepsOthers()
        try configAppearanceModeDecodeAndFallback()
        try configGlassStyleDecodeAndFallback()
        print("MdddOnboardingCore tests passed: 141")
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
            module: .agentUsage, readiness: .ready,
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

    private static func gateDeniesUnselectedModule() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
            isModuleSelected: false, appIsAcceptingNewTasks: true
        )
        try coreExpect(!allowed, "unselected should be denied")
    }

    private static func gateDeniesWhenAppNotAcceptingTasks() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let allowed = gate.canActivate(
            module: .agentUsage, readiness: .ready,
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

    private static func policyNilWhenNotReady() throws {
        let gate = CollectorActivationGate(consentVersion: 1, confirmedConsentVersion: 1)
        let policy = gate.executionPolicy(for: .agentUsage, readiness: .pendingAuthorization)
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

    // MARK: - Config store

    private static func configStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-config-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        var config = OnboardingConfiguration()
        config.pythonPath = "/usr/bin/python3"
        config.selectedModules = ["agent-usage"]
        config.consentVersion = 1
        config.menuBarMetrics = [
            "minimumRemainingQuota",
            "todayTokens",
        ]

        try store.save(config)
        let loaded = store.load()

        try coreExpect(loaded != nil, "loaded config should not be nil")
        try coreExpect(loaded?.pythonPath == "/usr/bin/python3", "pythonPath mismatch")
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
            "selectedModules": ["agent-usage"],
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
        try store.saveCredential(
            "fixture-value", forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let loaded = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try coreExpect(loaded == "fixture-value", "credential roundtrip failed")
    }

    private static func credentialStoreDelete() throws {
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

    private static func credentialStoreIsolatesByAccount() throws {
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

    private static func gateEvaluatorDeniesAllBeforeConsent() throws {
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

    private static func gateEvaluatorEnablesOnlyReadyAndSelected() throws {
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

    /// 验证 update 优先语义: 预置旧值后 saveCredential 是就地更新而非先删后加,
    /// 任何时刻凭证不丢失; 测试结束清理测试项.
    private static func keychainUpdatePreservesAndOverwrites() throws {
        let store = KeychainCredentialStore(service: keychainTestService)
        let account = "harness-\(UUID().uuidString)"
        defer { try? store.deleteCredential(forAccount: account) }

        try store.saveCredential("old-value", forAccount: account)
        let first = try store.loadCredential(forAccount: account)
        try coreExpect(first == "old-value", "initial save failed")

        // 再次保存必须是更新语义: 新值可读, 且过程中不经过"已删除"窗口
        try store.saveCredential("new-value", forAccount: account)
        let updated = try store.loadCredential(forAccount: account)
        try coreExpect(
            updated == "new-value",
            "update should overwrite, got \(String(describing: updated))"
        )

        try store.deleteCredential(forAccount: account)
        let deleted = try store.loadCredential(forAccount: account)
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
        let sessionDir = tempDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: ccSwitchFixtureSQL)

        let paths = LocalDependencyScanPaths(
            userPreferredPythonPath: fakePython,
            pythonCandidates: ["/nonexistent/python3"],
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

    private static func scannerReportsMissingPython() async throws {
        let paths = LocalDependencyScanPaths(
            pythonCandidates: ["/nonexistent/python3-a", "/nonexistent/python3-b"],
            sessionDirectories: [],
            sqliteDatabases: []
        )
        let scanner = LocalDependencyScanner(paths: paths)
        let probes = await scanner.scan()
        let python = probes.first { $0.kind == .python }
        try coreExpect(python?.status == .missing, "python should be missing")
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

        // 阶段 2: 写入授权 (选中 agentUsage), 选中且 ready 的 agentUsage allowed
        var config = store.load() ?? OnboardingConfiguration()
        config.consentVersion = 1
        config.selectedModules = ["agent-usage"]
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
            ],
            selectedModules: Set(
                (store.load()?.selectedModules ?? []).compactMap {
                    CollectorModule(rawValue: $0)
                }
            ),
            appIsAcceptingNewTasks: true
        )
        let agentDecision = confirmedDecisions.first { $0.module == .agentUsage }
        try coreExpect(
            agentDecision?.allowed == true,
            "选中且 ready 的 agent-usage 必须 allowed"
        )
        try coreExpect(
            agentDecision?.policy?.capabilities == [.localSessions, .localPricing],
            "agent 策略只含 localSessions/localPricing"
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
            "selectedModules": ["agent-usage"],
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
            loaded?.selectedModules == ["agent-usage"],
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
            "selectedModules": ["agent-usage"],
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

    /// refreshIntervalMinutes: 缺键, 显式 null 与非法值一律回落默认 30 分钟,
    /// 合法值 (5/15/30/60) 原样保留; 原子读写往返一致.
    private static func configRefreshIntervalDecodeAndFallback() throws {
        // 缺键 -> nil -> 默认 30
        let missing = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2}"#.utf8)
        )
        try coreExpect(missing.refreshIntervalMinutes == nil, "缺键必须为 nil")
        try coreExpect(
            missing.resolvedRefreshIntervalMinutes == 30,
            "缺键必须回落默认 30 分钟"
        )

        // 显式 null (用户真实配置中已存在该键) -> nil -> 默认 30
        let explicitNull = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(
                #"{"schemaVersion": 2, "refreshIntervalMinutes": null}"#.utf8
            )
        )
        try coreExpect(
            explicitNull.refreshIntervalMinutes == nil,
            "显式 null 必须按 nil 处理"
        )
        try coreExpect(
            explicitNull.resolvedRefreshIntervalMinutes == 30,
            "显式 null 必须回落默认 30 分钟"
        )

        // 非法值: 原始值保留可诊断, resolved 回落默认 30
        let invalid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "refreshIntervalMinutes": 7}"#.utf8)
        )
        try coreExpect(
            invalid.refreshIntervalMinutes == 7,
            "非法原始值必须保留"
        )
        try coreExpect(
            invalid.resolvedRefreshIntervalMinutes == 30,
            "非法值必须回落默认 30 分钟"
        )

        // 合法值原样生效
        let valid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(
                #"{"schemaVersion": 2, "refreshIntervalMinutes": 15}"#.utf8
            )
        )
        try coreExpect(
            valid.resolvedRefreshIntervalMinutes == 15,
            "合法值 15 必须原样生效"
        )

        // 原子读写往返
        let tempDir = makeTempDir("config-refresh-interval")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var config = OnboardingConfiguration()
        config.refreshIntervalMinutes = 60
        try store.save(config)
        try coreExpect(
            store.load()?.refreshIntervalMinutes == 60,
            "refreshIntervalMinutes 往返必须一致"
        )
    }

    /// appearanceMode: 缺键, 显式 null 与非法字符串一律回落跟随系统,
    /// 合法值原样保留; 原子读写往返一致.
    private static func configAppearanceModeDecodeAndFallback() throws {
        // 缺键 -> nil -> 跟随系统
        let missing = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2}"#.utf8)
        )
        try coreExpect(missing.appearanceMode == nil, "缺键必须为 nil")
        try coreExpect(
            missing.resolvedAppearanceMode == .system,
            "缺键必须回落跟随系统"
        )

        // 显式 null -> nil -> 跟随系统
        let explicitNull = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "appearanceMode": null}"#.utf8)
        )
        try coreExpect(
            explicitNull.appearanceMode == nil,
            "显式 null 必须按 nil 处理"
        )

        // 非法字符串 -> nil -> 跟随系统, 不拒绝加载
        let invalid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "appearanceMode": "neon"}"#.utf8)
        )
        try coreExpect(
            invalid.appearanceMode == nil,
            "非法字符串必须按 nil 处理"
        )
        try coreExpect(
            invalid.resolvedAppearanceMode == .system,
            "非法值必须回落跟随系统"
        )

        // 合法值原样生效
        let valid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "appearanceMode": "dark"}"#.utf8)
        )
        try coreExpect(
            valid.resolvedAppearanceMode == .dark,
            "合法值 dark 必须原样生效"
        )

        // 原子读写往返
        let tempDir = makeTempDir("config-appearance")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var config = OnboardingConfiguration()
        config.appearanceMode = .light
        try store.save(config)
        try coreExpect(
            store.load()?.appearanceMode == .light,
            "appearanceMode 往返必须一致"
        )
    }

    /// glassStyle: 缺键, 显式 null 与非法字符串一律回落标准玻璃,
    /// 合法值原样保留; 原子读写往返一致.
    private static func configGlassStyleDecodeAndFallback() throws {
        // 缺键 -> nil -> 标准玻璃
        let missing = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2}"#.utf8)
        )
        try coreExpect(missing.glassStyle == nil, "缺键必须为 nil")
        try coreExpect(
            missing.resolvedGlassStyle == .regular,
            "缺键必须回落标准玻璃"
        )

        // 非法字符串 -> nil -> 标准玻璃, 不拒绝加载
        let invalid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "glassStyle": "neon"}"#.utf8)
        )
        try coreExpect(invalid.glassStyle == nil, "非法字符串必须按 nil 处理")
        try coreExpect(
            invalid.resolvedGlassStyle == .regular,
            "非法值必须回落标准玻璃"
        )

        // 合法值原样生效
        let valid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2, "glassStyle": "clear"}"#.utf8)
        )
        try coreExpect(
            valid.resolvedGlassStyle == .clear,
            "合法值 clear 必须原样生效"
        )

        // 原子读写往返
        let tempDir = makeTempDir("config-glass-style")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var config = OnboardingConfiguration()
        config.glassStyle = .material
        try store.save(config)
        try coreExpect(
            store.load()?.glassStyle == .material,
            "glassStyle 往返必须一致"
        )
    }

    // MARK: - 订阅凭证 account 键 (内存实现)

    /// 七个订阅 provider account 键的增删改查与隔离.
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

    // MARK: - 设备码登录 (全部 mock session, 禁真实外网)

    /// 按 URL 分桶计数的假 URLSession, handler 收到该 URL 第 N 次调用序号.
    private final class CountingMockSession: URLSessionProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var recordedRequests: [URLRequest] = []
        let handler: (URLRequest, Int) throws -> (Data, URLResponse)

        init(handler: @escaping (URLRequest, Int) throws -> (Data, URLResponse)) {
            self.handler = handler
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedRequests
        }

        func data(for request: URLRequest) async throws -> (Data, URLResponse) {
            let nth = record(request)
            return try handler(request, nth)
        }

        /// 记录请求并返回该 URL 的调用序号; 同步方法避开 async 上下文锁限制.
        private func record(_ request: URLRequest) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let key = request.url?.absoluteString ?? ""
            counts[key, default: 0] += 1
            recordedRequests.append(request)
            return counts[key] ?? 0
        }
    }

    /// 线程安全的值盒子, 供 @Sendable 回调回传捕获.
    private final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ value: Value) { storage = value }

        func set(_ value: Value) {
            lock.lock()
            storage = value
            lock.unlock()
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static func httpResponse(
        _ request: URLRequest, _ code: Int
    ) -> URLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: code,
            httpVersion: nil, headerFields: nil
        )!
    }

    /// 构造未签名的测试 JWT (仅 payload 有效).
    private static func makeUnsignedJWT(payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(b64)."
    }

    private static func requestBodyString(_ request: URLRequest?) -> String {
        guard let data = request?.httpBody else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// stdin 注入: 凭证经管道传给子进程 (gh --with-token 的依赖能力).
    private static func probeStandardInputPipesToProcess() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/bin/cat",
            arguments: [],
            standardInput: "fixture-token-123\n"
        )
        try coreExpect(
            result == .success(output: "fixture-token-123"),
            "stdin 必须原样到达子进程, got \(result)"
        )
    }

    // MARK: Codex 设备码流程

    /// PKCE code_verifier: 43 字符 base64url, 两次生成不相同.
    private static func codexPKCEVerifierFormat() throws {
        let v1 = CodexPKCE.codeVerifier()
        let v2 = CodexPKCE.codeVerifier()
        try coreExpect(v1.count == 43, "verifier 必须 43 字符, got \(v1.count)")
        let pattern = #"^[A-Za-z0-9\-_]+$"#
        try coreExpect(
            v1.range(of: pattern, options: .regularExpression) != nil,
            "verifier 必须只含 base64url 字符, got \(v1)"
        )
        try coreExpect(v1 != v2, "两次生成必须不同")
    }

    /// Codex 申请请求: POST JSON client_id; 解析 device_auth_id/user_code.
    private static func codexDeviceStartRequestAndParse() throws {
        let request = CodexDeviceFlow.startRequest()
        try coreExpect(request.httpMethod == "POST", "必须是 POST")
        try coreExpect(
            request.url == CodexDeviceFlow.userCodeURL,
            "必须指向 deviceauth/usercode"
        )
        let body = requestBodyString(request)
        try coreExpect(
            body.contains(#""client_id":"app_EMoamEEZ73f0CkXaXp7hrann""#),
            "body 必须带 client_id, got \(body)"
        )
        try coreExpect(
            request.value(forHTTPHeaderField: "Content-Type") == "application/json",
            "Content-Type 必须是 application/json"
        )

        guard case .success(let auth) = CodexDeviceFlow.parseStartResponse(
            Data(#"{"device_auth_id":"da-1","user_code":"WXYZ-00"}"#.utf8),
            statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("合法响应必须解析成功")
        }
        try coreExpect(auth.deviceCode == "da-1", "device_auth_id 不符")
        try coreExpect(auth.userCode == "WXYZ-00", "user_code 不符")
        try coreExpect(
            auth.verificationURL.absoluteString == "https://auth.openai.com/codex/device",
            "验证页 URL 不符: \(auth.verificationURL)"
        )
        try coreExpect(auth.interval == 5, "缺省 interval 必须 5")
        try coreExpect(auth.expiresIn == 900, "缺省 expires_in 必须 900")

        guard case .success(let custom) = CodexDeviceFlow.parseStartResponse(
            Data(
                #"{"device_auth_id":"da","user_code":"uc","interval":2,"expires_in":60}"#
                    .utf8
            ),
            statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("带 interval 响应必须解析成功")
        }
        try coreExpect(
            custom.interval == 2 && custom.expiresIn == 60,
            "服务端 interval/expires_in 必须生效"
        )
        guard case .failure = CodexDeviceFlow.parseStartResponse(
            Data("{}".utf8), statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("缺字段必须失败")
        }
        try coreExpect(
            CodexDeviceFlow.parseStartResponse(Data(), statusCode: 500)
                == .failure(.httpError(statusCode: 500)),
            "500 必须 httpError"
        )
    }

    /// 轮询与换码编解码: 403/404 pending, 200 带 code_verifier,
    /// 缺省回落本地 PKCE; 换码表单带齐 grant_type/redirect_uri/code_verifier.
    private static func codexDevicePollAndExchangeParsing() throws {
        let pollRequest = CodexDeviceFlow.pollRequest(
            deviceAuthID: "da-1", userCode: "WXYZ-00"
        )
        let body = requestBodyString(pollRequest)
        try coreExpect(
            body.contains(#""device_auth_id":"da-1""#),
            "轮询必须带 device_auth_id, got \(body)"
        )
        try coreExpect(
            body.contains(#""user_code":"WXYZ-00""#),
            "轮询必须带 user_code, got \(body)"
        )

        for pendingCode in [403, 404] {
            try coreExpect(
                CodexDeviceFlow.parsePollResponse(Data(), statusCode: pendingCode)
                    == .success(.pending),
                "\(pendingCode) 必须 pending"
            )
        }
        let granted = CodexDeviceFlow.parsePollResponse(
            Data(#"{"authorization_code":"ac-1","code_verifier":"cv-1"}"#.utf8),
            statusCode: 200
        )
        try coreExpect(
            granted == .success(.authorized(
                CodexDeviceFlow.DeviceGrant(
                    authorizationCode: "ac-1", codeVerifier: "cv-1"
                )
            )),
            "200 必须 authorized, got \(granted)"
        )
        // 服务端缺省 code_verifier 时回落本地 PKCE 生成
        guard case .success(.authorized(let fallback)) = CodexDeviceFlow
            .parsePollResponse(
                Data(#"{"authorization_code":"ac-2"}"#.utf8), statusCode: 200
            ) else {
            throw CoreTestFailure.expectation("缺 verifier 必须回落生成")
        }
        try coreExpect(
            fallback.codeVerifier.count == 43,
            "回落 verifier 必须 43 字符"
        )
        guard case .failure(.invalidResponse) = CodexDeviceFlow.parsePollResponse(
            Data("{}".utf8), statusCode: 200
        ) else {
            throw CoreTestFailure.expectation("缺 authorization_code 必须失败")
        }
        try coreExpect(
            CodexDeviceFlow.parsePollResponse(Data(), statusCode: 500)
                == .failure(.httpError(statusCode: 500)),
            "500 必须 httpError"
        )

        let grant = CodexDeviceFlow.DeviceGrant(
            authorizationCode: "ac-1", codeVerifier: "cv-1"
        )
        let exchangeBody = requestBodyString(
            CodexDeviceFlow.exchangeRequest(grant)
        )
        for fragment in [
            "grant_type=authorization_code",
            "client_id=app_EMoamEEZ73f0CkXaXp7hrann",
            "code=ac-1",
            "redirect_uri=https%3A%2F%2Fauth.openai.com%2Fdeviceauth%2Fcallback",
            "code_verifier=cv-1",
        ] {
            try coreExpect(
                exchangeBody.contains(fragment),
                "换码表单缺少 \(fragment), got \(exchangeBody)"
            )
        }
        let tokenJSON = """
            {"id_token":"it","access_token":"at","refresh_token":"rt"}
            """
        let fixedReceived = Date(timeIntervalSince1970: 1_752_000_000)
        try coreExpect(
            CodexDeviceFlow.parseTokenResponse(
                Data(tokenJSON.utf8),
                statusCode: 200,
                receivedAt: fixedReceived
            ) == .success(CodexDeviceFlow.TokenSet(
                idToken: "it",
                accessToken: "at",
                refreshToken: "rt",
                receivedAt: fixedReceived
            )),
            "三令牌齐备必须解析成功"
        )
        guard case .failure(.invalidResponse) = CodexDeviceFlow
            .parseTokenResponse(
                Data(#"{"id_token":"it","access_token":"at"}"#.utf8),
                statusCode: 200
            ) else {
            throw CoreTestFailure.expectation("缺 refresh_token 必须失败")
        }
    }

    /// id_token claim 提取: namespaced 优先, 顶层其次, organizations 兜底.
    private static func codexIDTokenClaimsParsing() throws {
        let namespaced = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-1"],
            "email": "u@example.com",
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: namespaced) == "acct-1",
            "namespaced claim 必须优先"
        )
        try coreExpect(
            CodexIDTokenParser.email(of: namespaced) == "u@example.com",
            "email 必须提取"
        )
        let topLevel = try makeUnsignedJWT(payload: [
            "chatgpt_account_id": "acct-2",
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: topLevel) == "acct-2",
            "顶层 claim 必须兜底"
        )
        let orgs = try makeUnsignedJWT(payload: [
            "organizations": [["id": "org-9"]],
        ])
        try coreExpect(
            CodexIDTokenParser.accountID(of: orgs) == "org-9",
            "organizations 必须兜底"
        )
        let none = try makeUnsignedJWT(payload: ["sub": "x"])
        try coreExpect(
            CodexIDTokenParser.accountID(of: none) == nil,
            "无 claim 必须 nil"
        )
        try coreExpect(
            CodexIDTokenParser.accountID(of: "not-a-jwt") == nil,
            "非法 JWT 必须 nil"
        )
    }

    /// 全流程状态机: usercode -> poll 403 pending -> poll 200 -> 换码 -> 入库.
    private static func codexDeviceFullFlowStoresAccount() async throws {
        let idToken = try makeUnsignedJWT(payload: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-42"],
            "email": "dev@example.com",
        ])
        let session = CountingMockSession { request, nth in
            let url = request.url?.absoluteString ?? ""
            switch url {
            case CodexDeviceFlow.userCodeURL.absoluteString:
                let json = """
                    {"device_auth_id":"da-1","user_code":"WXYZ-00","interval":0}
                    """
                return (Data(json.utf8), httpResponse(request, 200))
            case CodexDeviceFlow.deviceTokenURL.absoluteString:
                if nth == 1 {
                    return (Data(), httpResponse(request, 403))
                }
                let json = #"{"authorization_code":"ac-1","code_verifier":"cv-1"}"#
                return (Data(json.utf8), httpResponse(request, 200))
            default:
                let json = """
                    {"id_token":"\(idToken)","access_token":"at-1",
                     "refresh_token":"rt-1"}
                    """
                return (Data(json.utf8), httpResponse(request, 200))
            }
        }
        let box = LockedBox<DeviceAuthorization?>(nil)
        let result = await CodexDeviceFlow().login(session: session) { auth in
            box.set(auth)
        }
        guard case .success(let account) = result else {
            throw CoreTestFailure.expectation("全流程必须成功, got \(result)")
        }
        try coreExpect(account.accountID == "acct-42", "账号 id 不符")
        try coreExpect(account.email == "dev@example.com", "email 不符")
        try coreExpect(account.refreshToken == "rt-1", "refresh_token 不符")
        try coreExpect(account.accessToken == "at-1", "access_token 不符")
        try coreExpect(account.idToken == idToken, "id_token 不符")
        try coreExpect(
            box.value?.userCode == "WXYZ-00",
            "onAuthorization 必须回传验证码"
        )
        // 换码请求必须带服务端下发的 code_verifier
        let exchangeRequest = session.requests.last {
            $0.url == CodexDeviceFlow.oauthTokenURL
        }
        try coreExpect(
            requestBodyString(exchangeRequest).contains("code_verifier=cv-1"),
            "换码必须带服务端 code_verifier"
        )
        // 入库: 复用账号库合并, 结果必须通过结构校验
        guard case .success(let merged) = CodexAccountsLibrary.merging(
            existingJSON: nil, account: account
        ) else {
            throw CoreTestFailure.expectation("账号库合并必须成功")
        }
        try coreExpect(
            ProviderConnectionVerifier.verifyCodexAccountsJSON(merged) == .ok,
            "入库 JSON 必须通过结构校验"
        )
        try coreExpect(
            CodexAccountsLibrary.accountIDs(of: merged) == ["acct-42"],
            "入库账号列表不符"
        )
        let summary = CodexAccountsLibrary.summary(of: merged)
        try coreExpect(
            summary.count == 1 && summary.emailPrefixes == ["dev"],
            "摘要不符: \(summary)"
        )
    }

    /// 错误路径可诊断: 申请网络失败, 轮询网络失败, 换码 500,
    /// id_token 缺账号 id 均 fail-closed.
    private static func codexDeviceErrorPaths() async throws {
        let flow = CodexDeviceFlow()
        let startNetFail = CountingMockSession { _, _ in
            throw URLError(.timedOut)
        }
        let startResult = await flow.start(session: startNetFail)
        try coreExpect(
            startResult == .failure(.networkUnreachable),
            "申请网络错误必须 networkUnreachable, got \(startResult)"
        )

        let pollNetFail = CountingMockSession { _, _ in
            throw URLError(.secureConnectionFailed)
        }
        let auth = DeviceAuthorization(
            deviceCode: "da-1", userCode: "WXYZ-00",
            verificationURL: CodexDeviceFlow.verificationURL,
            interval: 0, expiresIn: 60
        )
        let pollResult = await flow.pollUntilAuthorized(
            auth, session: pollNetFail
        )
        try coreExpect(
            pollResult == .failure(.networkUnreachable),
            "轮询网络错误必须 networkUnreachable, got \(pollResult)"
        )

        let grant = CodexDeviceFlow.DeviceGrant(
            authorizationCode: "ac-1", codeVerifier: "cv-1"
        )
        let exchange500 = CountingMockSession { request, _ in
            (Data(), httpResponse(request, 500))
        }
        let exchangeResult = await flow.exchange(grant, session: exchange500)
        try coreExpect(
            exchangeResult == .failure(.httpError(statusCode: 500)),
            "换码 500 必须 httpError, got \(exchangeResult)"
        )

        let noAccountJWT = try makeUnsignedJWT(payload: ["sub": "x"])
        let noAccountSession = CountingMockSession { request, _ in
            let json = """
                {"id_token":"\(noAccountJWT)","access_token":"at",
                 "refresh_token":"rt"}
                """
            return (Data(json.utf8), httpResponse(request, 200))
        }
        let noAccount = await flow.exchange(grant, session: noAccountSession)
        guard case .failure(.invalidResponse) = noAccount else {
            throw CoreTestFailure.expectation(
                "id_token 缺账号 id 必须 invalidResponse, got \(noAccount)"
            )
        }
    }

    /// 设备码已过期: 不发任何轮询请求即 authorizationExpired.
    private static func codexDeviceExpiredSkipsPolling() async throws {
        let session = CountingMockSession { request, _ in
            (Data(), httpResponse(request, 200))
        }
        let expired = DeviceAuthorization(
            deviceCode: "da-1", userCode: "WXYZ-00",
            verificationURL: CodexDeviceFlow.verificationURL,
            interval: 0, expiresIn: 0
        )
        let result = await CodexDeviceFlow().pollUntilAuthorized(
            expired, session: session
        )
        try coreExpect(
            result == .failure(.authorizationExpired),
            "过期必须 authorizationExpired, got \(result)"
        )
        try coreExpect(session.requests.isEmpty, "已过期不得发起轮询请求")
    }

    // MARK: - Credential rotation merge

    /// provider -> Keychain account 映射; 未知 provider 返回 nil.
    /// Codex 明确拒绝 (任务 11): 旧 `codex:accounts` 只供迁移读取,
    /// Collector rotation 不写回旧整体库.
    private static func rotationMergeMapsKnownProviders() throws {
        try coreExpect(
            CredentialRotationMerge.keychainAccount(forProvider: "kimi")
                == SubscriptionCredentialAccount.kimiWebTokens,
            "kimi 映射失败"
        )
        try coreExpect(
            CredentialRotationMerge.keychainAccount(forProvider: "codex") == nil,
            "codex 轮换写回必须被拒绝"
        )
        try coreExpect(
            CredentialRotationMerge.keychainAccount(forProvider: "antigravity")
                == SubscriptionCredentialAccount.antigravityOAuth,
            "antigravity 映射失败"
        )
        try coreExpect(
            CredentialRotationMerge.keychainAccount(forProvider: "deepseek") == nil,
            "无轮换的 provider 不得映射"
        )
    }

    /// kimi: 顶层平铺合并, 既有 refresh 被新值覆盖, 缺省时以空结构起步.
    private static func rotationMergeKimiFlatTokens() throws {
        let existing = #"{"access_token":"old-a","refresh_token":"old-r"}"#
        let merged = CredentialRotationMerge.mergedJSON(
            existingJSON: existing,
            update: CredentialRotationUpdate(
                provider: "kimi",
                accountId: "default",
                tokens: ["access_token": "new-a", "refresh_token": "new-r"]
            )
        )
        try coreExpect(
            merged == #"{"access_token":"new-a","refresh_token":"new-r"}"#,
            "kimi 平铺合并错误, got \(merged ?? "nil")"
        )
        let created = CredentialRotationMerge.mergedJSON(
            existingJSON: nil,
            update: CredentialRotationUpdate(
                provider: "kimi",
                accountId: "default",
                tokens: ["access_token": "a", "refresh_token": "r"]
            )
        )
        try coreExpect(
            created == #"{"access_token":"a","refresh_token":"r"}"#,
            "kimi 缺省时必须可创建, got \(created ?? "nil")"
        )
    }

    /// codex: 只合并目标账号, 保留 email 和其他账号.
    /// codex: rotation 条目被明确拒绝, 不写回旧整体库 (任务 11).
    private static func rotationMergeCodexRejected() throws {
        let existing = """
        {"accounts":{"acc-1":{"email":"a@x.com","refresh_token":"r1"},\
        "acc-2":{"email":"b@x.com","refresh_token":"r2"}}}
        """
        let merged = CredentialRotationMerge.mergedJSON(
            existingJSON: existing,
            update: CredentialRotationUpdate(
                provider: "codex",
                accountId: "acc-1",
                tokens: ["access_token": "na", "refresh_token": "nr"]
            )
        )
        try coreExpect(
            merged == nil,
            "codex 轮换写回必须被拒绝, got \(merged ?? "nil")"
        )
    }

    /// antigravity: 合并 token 子对象并保留顶层其他键.
    private static func rotationMergeAntigravityTokenSubObject() throws {
        let existing = #"{"extra":"keep","token":{"access_token":"old","refresh_token":"rr"}}"#
        let merged = CredentialRotationMerge.mergedJSON(
            existingJSON: existing,
            update: CredentialRotationUpdate(
                provider: "antigravity",
                accountId: "default",
                tokens: ["access_token": "new", "expiry": "2026-08-01T00:00:00"]
            )
        )
        try coreExpect(
            merged == #"{"extra":"keep","token":{"access_token":"new","expiry":"2026-08-01T00:00:00","refresh_token":"rr"}}"#,
            "antigravity 合并错误, got \(merged ?? "nil")"
        )
    }

    /// 白名单外键被过滤; 未知 provider 与空令牌返回 nil.
    private static func rotationMergeFiltersKeysAndRejectsUnknown() throws {
        let merged = CredentialRotationMerge.mergedJSON(
            existingJSON: nil,
            update: CredentialRotationUpdate(
                provider: "kimi",
                accountId: "default",
                tokens: ["access_token": "a", "evil": "x"]
            )
        )
        try coreExpect(
            merged == #"{"access_token":"a"}"#,
            "白名单外键必须过滤, got \(merged ?? "nil")"
        )
        try coreExpect(
            CredentialRotationMerge.mergedJSON(
                existingJSON: nil,
                update: CredentialRotationUpdate(
                    provider: "unknown", accountId: "default",
                    tokens: ["access_token": "a"]
                )
            ) == nil,
            "未知 provider 必须返回 nil"
        )
        try coreExpect(
            CredentialRotationMerge.mergedJSON(
                existingJSON: nil,
                update: CredentialRotationUpdate(
                    provider: "kimi", accountId: "default",
                    tokens: ["access_token": ""]
                )
            ) == nil,
            "空令牌必须返回 nil"
        )
    }

    // MARK: - 任务 5: 登录接入与账号发现

    /// 永不触发的 stub OAuth 客户端 (登录测试只验证入库, 不发起网络).
    private final class StubOAuthClient: CodexOAuthClientProtocol {
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

    /// 1. mddd 设备码登录成功后写入 credentialOrigin=mddd 的完整 v2 记录.
    private static func codexLoginStoresCompleteV2Record() async throws {
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
        try coreExpect(record?.credentialOrigin == .mddd, "来源必须为 mddd")
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
    private static func ccSwitchDiscoveryKeepsMetadataOnly() async throws {
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
    private static func cliDiscoveryKeepsMetadataOnly() throws {
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
    private static func discoveryNeverWritesSourceFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mddd-discovery-\(UUID().uuidString)", isDirectory: true)
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

    private static func snapshot(of url: URL) throws -> (Data, UInt64, Date) {
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (
            data,
            (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            (attributes[.modificationDate] as? Date) ?? Date.distantPast
        )
    }

    /// 5. 重新授权只替换当前账号记录, 不覆盖其他账号.
    private static func reauthorizationReplacesOnlyCurrentAccount() async throws {
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
            credentialOrigin: .mddd,
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
            credentialOrigin: .mddd,
            updatedAt: now
        ))
        let recordA = try store.loadRecord(for: "acct-a")
        try coreExpect(recordA?.accessToken == "at-a-new", "acct-a 未被替换")
        try coreExpect(recordA?.credentialOrigin == .mddd, "acct-a 来源未更新")
        let recordB = try store.loadRecord(for: "acct-b")
        try coreExpect(recordB?.accessToken == "at-b", "acct-b 被覆盖")
        try coreExpect(recordB?.refreshToken == "rt-b", "acct-b 被覆盖")
        let index = try store.loadIndex()
        try coreExpect(index.accounts.count == 2, "索引账号数不符")
    }

    /// 6. 断开账号删除 mddd Keychain 记录, 不写第三方文件.
    private static func disconnectRemovesRecordButKeepsOthers() async throws {
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
                credentialOrigin: .mddd,
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

    // MARK: - DeepSeek 月度账本: 配置追踪 ID 与保存事务

    /// usageTrackingID: 旧配置缺键或显式 null 一律解码为 nil (无需 schema 升级);
    /// 新配置 round-trip 保留; 非 deepseek provider 保持 nil.
    private static func subscriptionUsageTrackingIDDecodeAndFallback() throws {
        // 旧 v2 配置 (无 usageTrackingID 键, verificationStatus 缺省为 none) -> nil
        let legacy = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"""
            {"schemaVersion":2,"subscriptionProviders":{"deepseek":{"enabled":true}}}
            """#.utf8)
        )
        try coreExpect(
            legacy.subscriptionProviders[SubscriptionProviderID.deepseek.rawValue]?.usageTrackingID == nil,
            "旧配置缺键必须解码为 nil"
        )

        // 显式 null -> nil
        let explicitNull = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"""
            {"schemaVersion":2,"subscriptionProviders":{"deepseek":{"enabled":false,"usageTrackingID":null}}}
            """#.utf8)
        )
        try coreExpect(
            explicitNull.subscriptionProviders[SubscriptionProviderID.deepseek.rawValue]?.usageTrackingID == nil,
            "显式 null 必须解码为 nil"
        )

        // round-trip 保留
        let tempDir = makeTempDir("config-tracking")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var config = OnboardingConfiguration(consentVersion: 1)
        let trackingID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        config.subscriptionProviders = [
            SubscriptionProviderID.deepseek.rawValue: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok,
                usageTrackingID: trackingID
            ),
            SubscriptionProviderID.kimi.rawValue: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok
            ),
        ]
        try store.save(config)
        let loaded = store.load()
        try coreExpect(
            loaded?.subscriptionProviders[SubscriptionProviderID.deepseek.rawValue]?.usageTrackingID == trackingID,
            "deepseek usageTrackingID round-trip 丢失"
        )
        try coreExpect(
            loaded?.subscriptionProviders[SubscriptionProviderID.kimi.rawValue]?.usageTrackingID == nil,
            "非 deepseek provider 必须 nil"
        )
    }

    /// applyingVerification 状态迁移必须保留既有 usageTrackingID (不重置追踪边界).
    private static func applyingVerificationPreservesUsageTrackingID() throws {
        let trackingID = "11111111-2222-3333-4444-555555555555"
        let entry = SubscriptionProviderConfiguration(
            enabled: false,
            verificationStatus: .none,
            usageTrackingID: trackingID
        )
        let ok = entry.applyingVerification(.ok, verifiedAt: "2026-08-03T00:00:00Z")
        try coreExpect(ok.enabled, "ok 必须启用")
        try coreExpect(
            ok.usageTrackingID == trackingID,
            "ok 迁移不得重置 usageTrackingID"
        )
        let failed = entry.applyingVerification(
            .failed(reason: "凭证无效"), verifiedAt: "2026-08-03T01:00:00Z"
        )
        try coreExpect(!failed.enabled, "failed 必须禁用")
        try coreExpect(
            failed.usageTrackingID == trackingID,
            "failed 迁移不得重置 usageTrackingID"
        )
    }

    /// prewriteDisabled: 写入禁用配置, 生成新 UUID, 返回旧 entry;
    /// 原本不存在 provider 时 oldEntry 为 nil.
    private static func deepSeekSaveTransactionPrewriteDisabled() throws {
        let tempDir = makeTempDir("ds-tx-prewrite")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        // 原本不存在 -> oldEntry nil
        let first = try DeepSeekSaveTransaction.prewriteDisabled(in: store)
        try coreExpect(first.oldEntry == nil, "首次预写 oldEntry 必须为 nil")
        try coreExpect(!first.newTrackingID.isEmpty, "新追踪 ID 不得为空")

        let loadedAfterFirst = store.load()
        let entry = loadedAfterFirst?.subscriptionProviders[
            SubscriptionProviderID.deepseek.rawValue
        ]
        try coreExpect(entry != nil, "预写后必须存在 deepseek 配置")
        try coreExpect(entry?.enabled == false, "预写配置必须禁用")
        try coreExpect(entry?.usageTrackingID == first.newTrackingID, "预写配置追踪 ID 不符")
        try coreExpect(
            entry?.verificationStatus == SubscriptionVerificationStatus.none,
            "预写配置验证状态必须为 none"
        )

        // 已有旧配置 -> oldEntry 携带旧 ID
        let second = try DeepSeekSaveTransaction.prewriteDisabled(in: store)
        try coreExpect(
            second.oldEntry?.usageTrackingID == first.newTrackingID,
            "二次预写 oldEntry 必须携带旧追踪 ID"
        )
        try coreExpect(
            second.newTrackingID != first.newTrackingID,
            "每次预写必须生成新追踪 ID"
        )
    }

    /// restore: Keychain 失败时恢复旧 entry (含旧 usageTrackingID).
    private static func deepSeekSaveTransactionRestoreOldEntry() throws {
        let tempDir = makeTempDir("ds-tx-restore")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        let oldTrackingID = "OLD-TRACKING-ID-AAAA"
        var config = OnboardingConfiguration(consentVersion: 1)
        config.subscriptionProviders = [
            SubscriptionProviderID.deepseek.rawValue: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok,
                usageTrackingID: oldTrackingID
            ),
        ]
        try store.save(config)

        // 预写禁用配置 (模拟即将写 Keychain)
        let prewrite = try DeepSeekSaveTransaction.prewriteDisabled(in: store)
        try coreExpect(
            prewrite.oldEntry?.usageTrackingID == oldTrackingID,
            "oldEntry 必须保留旧追踪 ID"
        )
        // 模拟 Keychain 失败 -> 恢复
        try DeepSeekSaveTransaction.restore(
            oldEntry: prewrite.oldEntry, in: store
        )
        let restored = store.load()?.subscriptionProviders[
            SubscriptionProviderID.deepseek.rawValue
        ]
        try coreExpect(restored?.enabled == true, "恢复后必须还原 enabled")
        try coreExpect(
            restored?.usageTrackingID == oldTrackingID,
            "恢复后必须还原旧 usageTrackingID"
        )
        try coreExpect(
            restored?.verificationStatus == .ok,
            "恢复后必须还原验证状态"
        )
    }

    /// restore: 旧 entry 为 nil 时移除该 provider 键 (恢复到未配置状态).
    private static func deepSeekSaveTransactionRestoreRemovesWhenAbsent() throws {
        let tempDir = makeTempDir("ds-tx-restore-absent")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        // 首次预写 (oldEntry nil), 再恢复 -> deepseek 键被移除
        let prewrite = try DeepSeekSaveTransaction.prewriteDisabled(in: store)
        try coreExpect(prewrite.oldEntry == nil, "首次预写 oldEntry 必须为 nil")
        try DeepSeekSaveTransaction.restore(oldEntry: nil, in: store)
        let loaded = store.load()
        try coreExpect(
            loaded?.subscriptionProviders[SubscriptionProviderID.deepseek.rawValue] == nil,
            "oldEntry nil 时恢复必须移除 deepseek 键"
        )
    }

    /// 每次保存事务生成不同的追踪 ID, 隔离新旧账户的月度账本.
    private static func deepSeekSaveTransactionIsolatesEachSave() throws {
        let tempDir = makeTempDir("ds-tx-isolate")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        var ids: Set<String> = []
        for _ in 0..<5 {
            let result = try DeepSeekSaveTransaction.prewriteDisabled(in: store)
            ids.insert(result.newTrackingID)
        }
        try coreExpect(
            ids.count == 5,
            "5 次保存必须生成 5 个不同追踪 ID, got \(ids.count)"
        )
    }
}
