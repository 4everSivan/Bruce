import Foundation
@testable import BruceOnboardingCore

// MARK: - 非交互环境守卫

/// 无头 CI runner 无登录会话: 真实 Keychain 读写触发系统授权等待会挂起.
/// 检测 GitHub Actions (`CI=true`) 或进程无代码签名且非 TTY.
enum IsNonInteractiveEnvironment {
    static var runningInCI: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["CI"] != nil && env["CI"] != "" {
            return true
        }
        // 本地终端无签名进程仍走真实 Keychain (登录会话可授权);
        // 仅无 CI 标记时放行, 保守只认 CI 变量, 避免误跳过本地测试.
        return false
    }
}

// MARK: - Harness

@main
@MainActor
struct BruceOnboardingCoreHarness {
    static func main() async throws {
        try egressCountryGroupsTests()
        try gateDeniesAllBeforeConsent()
        try gateDeniesWhenConsentVersionMismatch()
        try gateAllowsAgentReady()
        try gateAllowsAgentPartial()
        try gateDeniesWithoutKeychainAccessConfiguration()
        try gateDeniesUnselectedModule()
        try gateDeniesWhenAppNotAcceptingTasks()
        try gateDeniesPendingAuthorization()
        try evaluatorAgentReady()
        try evaluatorAgentPartial()
        try evaluatorAgentRustDoesNotRequireOtherRuntime()
        try evaluatorAgentRustMissingIsExplicit()
        try evaluatorAgentMissingRust()
        try evaluatorAgentNoSessions()
        try evaluatorAgentCcSwitchAloneNotReady()
        try configStoreRoundTrip()
        try configStoreReturnsEmptyWhenMissing()
        try configStoreReturnsNilForUnknownSchema()
        try configStoreFilePermissions()
        try keychainAccessConfigurationRoundTrip()
        try retiredLegacyKeysStillDecode()
        try atomicStoreBackupRefreshesOnEachWrite()
        try credentialStoreRoundTrip()
        try credentialStoreDelete()
        try credentialStoreIsolatesByAccount()
        try ccSwitchProfileHasExpectedTables()
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
        try keychainAutomaticAccessRequiresConfiguration()
        try keychainAuthenticationQueryPolicies()
        // 真实 Keychain 测试仅在交互环境运行: 无头 CI runner 无登录会话,
        // SecItem* 触发系统授权等待会挂起至超时 (本地已有登录会话, 自动通过).
        if !IsNonInteractiveEnvironment.runningInCI {
            try keychainUpdatePreservesAndOverwrites()
        }
        try await scannerFindsSessionsAndSQLite()
        try standardPathsIncludePiSessions()
        try standardPathsIncludeZcodeDatabase()
        try standardPathsIncludeCodeBuddyProjects()
        try standardPathsIncludeDshSessions()
        try firstLaunchDecisionFlow()
        try configStoreLoadsV1WithSubscriptionDefaults()
        try configStoreRejectsNewerSchemaV4()
        try configStoreSubscriptionProvidersRoundTrip()
        try configRefreshIntervalDecodeAndFallback()
        try customRefreshIntervalInputParsing()
        try keychainAccessPolicyTests()
        try credentialStoreSubscriptionAccountsRoundTrip()
        if !IsNonInteractiveEnvironment.runningInCI {
            try keychainSubscriptionAccountsRoundTrip()
        }
        try protectedFileCredentialStoreRoundTripAndPermissions()
        try protectedFileCredentialStoreCorruptionIsNotSilentlyErased()
        try protectedFileCredentialStoreWriteHardening()
        try protectedFileCredentialStoreDeleteLeavesNoBackupResidue()
        try protectedFileCredentialStoreKeepsOnlyLatestCorruptCopy()
        try await verifierDeepSeekConnectedWithMockSession()
        try await verifierDeepSeekFailClosed()
        try verifierKimiAPIKeyMappings()
        try verifierVolcengineCredentialsMappings()
        try verifierZhipuCredentialsMappings()
        try storedCredentialParserMappings()
        try volcDecoderStopsWhenNotBase64()
        try volcDecoderSingleAndDoubleEncoded()
        try volcFullyDecodedPicksDeepestCandidate()
        try await ccSwitchVolcImportReadsFixtureDatabase()
        try await ccSwitchVolcImportMissingProviderRow()
        try await ccSwitchVolcImportMissingFile()
        try subscriptionConfigApplyingVerificationTransitions()
        try await probeStandardInputPipesToProcess()
        try codexPKCEVerifierFormat()
        try codexDeviceStartRequestAndParse()
        try codexDevicePollAndExchangeParsing()
        try codexIDTokenClaimsParsing()
        try await codexDeviceFullFlowStoresAccount()
        try await codexDeviceErrorPaths()
        try await codexDeviceExpiredSkipsPolling()
        try await codexDeviceFlowPreservesExpiresIn()
        try codexExpiryPriorityExpiresInOverJWTAndFallback()
        try rotationMergeMapsKnownProviders()
        try rotationMergeStepFunSupported()
        try rotationMergeKimiRejected()
        try rotationMergeCodexRejected()
        try rotationMergeFiltersKeysAndRejectsUnknown()
        try rotationMergeClaudeUpdatesNestedOAuthFields()
        try rotationMergeClaudeCreatesNestedOAuthForNewCLIRecord()
        try rotationMergeClaudeMatchesSharedParityFixture()
        try CodexCredentialStoreTests.runAll()
        try await CodexOAuthClientTests.runAll()
        try CredentialStateReducerTests.runAll()
        try await CodexTokenManagerTests.runAll()
        try await codexLoginStoresCompleteV2Record()
        try await ccSwitchDiscoveryKeepsMetadataOnly()
        try cliDiscoveryKeepsMetadataOnly()
        try await discoveryNeverWritesSourceFiles()
        try await reauthorizationReplacesOnlyCurrentAccount()
        try await disconnectRemovesRecordButKeepsOthers()
        try configAppearanceModeDecodeAndFallback()
        try appearancePreferenceCycleOrder()
        try configGlassStyleDecodeAndFallback()
        try configNothingStyleDecodeAndResolution()
        try codexAccountIdentityServiceIDMatchesRustContract()
        try codexAccountIdentityLegacyID()
        try evaluatorGrokExpiredReturnsExpired()
        try evaluatorGrokValidOIDCPreferredOverLegacy()
        try evaluatorGrokMillisTimestamp()
        try evaluatorGrokISOString()
        try evaluatorGrokMissingKeyAndCorrupt()
        try evaluatorClaudeExpiredAndLegacyKey()
        try evaluatorClaudeMissingToken()
        try evaluatorIsExpiredSemanticsMatchRustContract()
        try evaluatorSharedExpiryFixtures()
        try claudePasteParserTokenAndJSON()
        try claudePasteParserRejectsEmpty()
        try claudePasteParserPreservesAccountFields()
        try systemExternalCredentialReaderMockAndFallback()
        try grokPasteParserTokenAndJSON()
        try grokPasteParserRejectsEmpty()
        try claudeCLIImporterReadsFixture()
        try grokCLIImporterReadsFixture()
        try claudeGrokCredentialAccountsReturnNewKeys()
        try configSubscriptionProviderOrderRoundTrip()
        try configuredRuleAllAccountsNonEmpty()
        try configuredRuleCodexRecords()
        try configuredRuleClaudeAppPrefersOverLocal()
        try configuredRuleClaudeFallsBackToLocal()
        try configuredRuleClaudeExpiredAppFallsBackToLocal()
        try configuredRuleGrokAppPrefersOverLocal()
        try configuredRuleGrokFallsBackToLocal()
        try configuredRuleGrokExpiredAppFallsBackToLocal()
        try configuredRuleRegistryMatchesProviders()
        try opencodeGoCredentialAccountsAndRegistry()
        try opencodeGoEvaluatorValidAndMalformed()
        try opencodeGoAccountIDAndLegacyKeys()
        try stepfunCredentialAccountsAndRegistry()
        try stepfunEvaluatorValidAndMalformed()
        try jevCredentialAccountsAndRegistry()
        try jevEvaluatorValidAndMalformed()
        try jevStoredCredentialParserJsonAndRaw()
        try clineCredentialAccountsAndRegistry()
        try clineEvaluatorValidAndMalformed()
        try clineStoredCredentialParserRawKey()
        try pricingCatalogMatchesCollectorRows()
        try pricingOverrideSelectionMatchesCollector()
        try providerAccountNamingDefaultsAndValidation()
        try providerAccountStoreRenameAndUpsertPreservation()
        try codexCustomNameOverridesAndBackwardCompatibility()
        try welcomeOnboardingConfigPersistenceAndUpgradeRules()
        try launchAtLoginConfigPersistenceRoundTrip()
        print("BruceOnboardingCore tests passed: 180")
    }

    static func launchAtLoginConfigPersistenceRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-launch-at-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = try OnboardingConfigurationStore(configDirectory: tempDir)

        // 1. 默认配置: launchAtLogin == nil
        var config = OnboardingConfiguration()
        guard config.launchAtLogin == nil else {
            throw NSError(domain: "LaunchAtLoginTest", code: 1)
        }

        // 2. 开启自启动并保存
        config.launchAtLogin = true
        try store.save(config)
        guard let loaded = store.load(), loaded.launchAtLogin == true else {
            throw NSError(domain: "LaunchAtLoginTest", code: 2)
        }

        // 3. 关闭自启动并保存
        config.launchAtLogin = false
        try store.save(config)
        guard let loadedDisabled = store.load(), loadedDisabled.launchAtLogin == false else {
            throw NSError(domain: "LaunchAtLoginTest", code: 3)
        }

        // 4. 旧版本配置缺键平滑兼容
        let legacyJSON = "{\"schemaVersion\": 3, \"selectedModules\": [\"agent-usage\"]}"
        let decoded = try JSONDecoder().decode(OnboardingConfiguration.self, from: Data(legacyJSON.utf8))
        guard decoded.launchAtLogin == nil else {
            throw NSError(domain: "LaunchAtLoginTest", code: 4)
        }
    }

    static func welcomeOnboardingConfigPersistenceAndUpgradeRules() throws {
        // 1. 全新安装: welcomeCompletedVersion == nil, 两个门禁均未完成 -> true
        let fresh = OnboardingConfiguration()
        guard fresh.welcomeCompletedVersion == nil,
              fresh.shouldPresentWelcomeOnStartup() else {
            throw NSError(domain: "WelcomeTest", code: 1)
        }

        // 2. 仅完成其一的半配置态 -> true
        var onlyConsent = OnboardingConfiguration()
        onlyConsent.consentVersion = 1
        onlyConsent.keychainAccessConfigured = false
        guard onlyConsent.shouldPresentWelcomeOnStartup() else {
            throw NSError(domain: "WelcomeTest", code: 2)
        }

        var onlyKeychain = OnboardingConfiguration()
        onlyKeychain.consentVersion = nil
        onlyKeychain.keychainAccessConfigured = true
        guard onlyKeychain.shouldPresentWelcomeOnStartup() else {
            throw NSError(domain: "WelcomeTest", code: 3)
        }

        // 3. 存量老用户平滑升级 (welcomeCompletedVersion == nil, 但 consentVersion == 1 && keychainAccessConfigured == true) -> false
        var upgraded = OnboardingConfiguration()
        upgraded.consentVersion = 1
        upgraded.keychainAccessConfigured = true
        guard !upgraded.shouldPresentWelcomeOnStartup() else {
            throw NSError(domain: "WelcomeTest", code: 4)
        }

        // 4. 完成向导 (welcomeCompletedVersion = 1) -> false, 且经 OnboardingConfigurationStore 往返持久化
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-welcome-cfg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var completed = OnboardingConfiguration()
        completed.consentVersion = 1
        completed.keychainAccessConfigured = true
        completed.welcomeCompletedVersion = OnboardingConfiguration.currentWelcomeVersion
        try store.save(completed)

        guard let loaded = store.load(),
              loaded.welcomeCompletedVersion == OnboardingConfiguration.currentWelcomeVersion,
              !loaded.shouldPresentWelcomeOnStartup() else {
            throw NSError(domain: "WelcomeTest", code: 5)
        }
    }
}
