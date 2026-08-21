import Foundation
@testable import BruceOnboardingCore

// MARK: - Claude/Grok parser importer / ConfiguredRuleEvaluator

extension BruceOnboardingCoreHarness {
    // MARK: - Claude / Grok Parser 与 Importer (Phase 2)

    /// ClaudePasteParser: 纯 token 与 claudeAiOauth JSON 规范化.
    static func claudePasteParserTokenAndJSON() throws {
        // 纯 token -> {"claudeAiOauth":{"accessToken":"tok"}}
        let tokenResult = ClaudePasteParser.parse("tok-123")
        guard case .success(let json) = tokenResult else {
            throw CoreTestFailure.expectation("Claude 纯 token 解析失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: json, now: Date()) == .valid,
            "Claude 解析产物应 valid"
        )
        // 同构 JSON -> 保留 accessToken
        let jsonResult = ClaudePasteParser.parse(
            #"{"claudeAiOauth":{"accessToken":"tok-a","refreshToken":"tok-r"}}"#
        )
        guard case .success(let parsed) = jsonResult else {
            throw CoreTestFailure.expectation("Claude JSON 解析失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: parsed, now: Date()) == .valid,
            "Claude JSON 解析产物应 valid"
        )
        // legacy 键
        let legacyResult = ClaudePasteParser.parse(
            #"{"claude.ai_oauth":{"accessToken":"tok-l"}}"#
        )
        guard case .success(let legacy) = legacyResult else {
            throw CoreTestFailure.expectation("Claude legacy 键解析失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: legacy, now: Date()) == .valid,
            "Claude legacy 键解析产物应 valid"
        )
    }

    /// ClaudePasteParser: 空输入与损坏 JSON 拒绝.
    static func claudePasteParserRejectsEmpty() throws {
        guard case .failure = ClaudePasteParser.parse("   ") else {
            throw CoreTestFailure.expectation("空输入应拒绝")
        }
        guard case .failure = ClaudePasteParser.parse("{broken") else {
            throw CoreTestFailure.expectation("损坏 JSON 应拒绝")
        }
        guard case .failure = ClaudePasteParser.parse(#"{"claudeAiOauth":{"refreshToken":"r"}}"#) else {
            throw CoreTestFailure.expectation("无 accessToken 应拒绝")
        }
    }

    /// GrokPasteParser: 纯 token 与 auth.json 同构 JSON 规范化.
    static func grokPasteParserTokenAndJSON() throws {
        let tokenResult = GrokPasteParser.parse("key-456")
        guard case .success(let json) = tokenResult else {
            throw CoreTestFailure.expectation("Grok 纯 token 解析失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: json, now: Date()) == .valid,
            "Grok 解析产物应 valid"
        )
        // auth.json 同构 -> 提取 OIDC 条目
        let jsonResult = GrokPasteParser.parse(
            #"{"https://auth.x.ai::b1a": {"key": "k1", "expires_at": 1789000000}}"#
        )
        guard case .success(let parsed) = jsonResult else {
            throw CoreTestFailure.expectation("Grok JSON 解析失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(
                of: parsed, now: Date(timeIntervalSince1970: 1_786_000_000)
            ) == .valid,
            "Grok JSON 解析产物应 valid"
        )
    }

    /// GrokPasteParser: 空输入与损坏 JSON 拒绝.
    static func grokPasteParserRejectsEmpty() throws {
        guard case .failure = GrokPasteParser.parse("   ") else {
            throw CoreTestFailure.expectation("空输入应拒绝")
        }
        guard case .failure = GrokPasteParser.parse("{broken") else {
            throw CoreTestFailure.expectation("损坏 JSON 应拒绝")
        }
        guard case .failure = GrokPasteParser.parse(#"{"https://auth.x.ai::a": {"email": "e"}}"#) else {
            throw CoreTestFailure.expectation("无 key 条目应拒绝")
        }
    }

    /// ClaudeCLIImporter: fixture 文件读取并规范化.
    static func claudeCLIImporterReadsFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":"2026-12-31T00:00:00Z"}}"#.utf8)
            .write(to: file)
        let result = ClaudeCLICredentialImporter().importCredentials(fileURL: file)
        guard case .success(let json) = result else {
            throw CoreTestFailure.expectation("Claude fixture 读取失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: json, now: Date()) == .valid,
            "Claude fixture 导入产物应 valid"
        )
    }

    /// GrokCLIImporter: fixture 文件读取并规范化.
    static func grokCLIImporterReadsFixture() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-importer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("auth.json")
        try Data(
            #"{"https://auth.x.ai::b1a": {"key": "k1", "expires_at": "2026-12-31T00:00:00Z"}}"#.utf8
        ).write(to: file)
        let result = GrokCLICredentialImporter().importCredentials(fileURL: file)
        guard case .success(let json) = result else {
            throw CoreTestFailure.expectation("Grok fixture 读取失败")
        }
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: json, now: Date()) == .valid,
            "Grok fixture 导入产物应 valid"
        )
    }

    /// credentialAccounts 对 claude/grok 返回新键 (移除时自动删 Keychain).
    static func claudeGrokCredentialAccountsReturnNewKeys() throws {
        try coreExpect(
            SubscriptionProviderID.claude.credentialAccounts == [
                SubscriptionCredentialAccount.claudeOAuth
            ],
            "claude credentialAccounts 应含 claude:oauth"
        )
        try coreExpect(
            SubscriptionProviderID.grok.credentialAccounts == [
                SubscriptionCredentialAccount.grokOAuth
            ],
            "grok credentialAccounts 应含 grok:oauth"
        )
    }

    // MARK: - ConfiguredRuleEvaluator (Task 8)

    static func configuredRuleAllAccountsNonEmpty() throws {
        let accounts = [
            SubscriptionCredentialAccount.volcengineAccessKey,
            SubscriptionCredentialAccount.volcengineSecretKey,
        ]
        let full = ConfiguredRuleEvaluator.Inputs(accountValues: [
            SubscriptionCredentialAccount.volcengineAccessKey: "ak",
            SubscriptionCredentialAccount.volcengineSecretKey: "sk",
        ])
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .allCredentialAccountsNonEmpty, accounts: accounts, inputs: full
            ),
            "全部非空应 configured"
        )
        let partial = ConfiguredRuleEvaluator.Inputs(accountValues: [
            SubscriptionCredentialAccount.volcengineAccessKey: "ak",
        ])
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .allCredentialAccountsNonEmpty, accounts: accounts, inputs: partial
            ),
            "缺 SK 应未配置"
        )
        let emptyValue = ConfiguredRuleEvaluator.Inputs(accountValues: [
            SubscriptionCredentialAccount.volcengineAccessKey: "ak",
            SubscriptionCredentialAccount.volcengineSecretKey: "",
        ])
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .allCredentialAccountsNonEmpty, accounts: accounts, inputs: emptyValue
            ),
            "空字符串应未配置"
        )
    }

    static func configuredRuleCodexRecords() throws {
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .codexHasConfiguredRecords,
                accounts: [],
                inputs: .init(codexHasConfiguredRecords: true)
            ),
            "codex store true → configured"
        )
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .codexHasConfiguredRecords,
                accounts: [],
                inputs: .init(codexHasConfiguredRecords: false)
            ),
            "codex store false → 未配置 (metadata-only fail-closed)"
        )
    }

    static let validClaudeJSON =
        #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":"2099-01-01T00:00:00Z"}}"#
    static let expiredClaudeJSON =
        #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":"2020-01-01T00:00:00Z"}}"#
    static let validGrokJSON = """
    {"https://auth.x.ai::offline_access":{"key":"k","expires_at":4099680000}}
    """
    static let expiredGrokJSON = """
    {"https://auth.x.ai::offline_access":{"key":"k","expires_at":1}}
    """

    static func configuredRuleClaudeAppPrefersOverLocal() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let inputs = ConfiguredRuleEvaluator.Inputs(
            accountValues: [
                SubscriptionCredentialAccount.claudeOAuth: validClaudeJSON
            ],
            claudeLocalAvailable: false,
            now: now
        )
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .claudeAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.claudeOAuth],
                inputs: inputs
            ),
            "应用有效凭证优先于本机 false"
        )
    }

    static func configuredRuleClaudeFallsBackToLocal() throws {
        let inputs = ConfiguredRuleEvaluator.Inputs(claudeLocalAvailable: true)
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .claudeAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.claudeOAuth],
                inputs: inputs
            ),
            "无应用凭证时本机 true → configured"
        )
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .claudeAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.claudeOAuth],
                inputs: .init(claudeLocalAvailable: false)
            ),
            "无应用凭证且本机 false → 未配置"
        )
    }

    static func configuredRuleClaudeExpiredAppFallsBackToLocal() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        // 应用凭证过期不算 valid, 且不回退本机 (与历史 credentialConfigured 一致:
        // 有非空 raw 时只看 evaluator, 不看 local).
        let expiredOnly = ConfiguredRuleEvaluator.Inputs(
            accountValues: [
                SubscriptionCredentialAccount.claudeOAuth: expiredClaudeJSON
            ],
            claudeLocalAvailable: true,
            now: now
        )
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .claudeAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.claudeOAuth],
                inputs: expiredOnly
            ),
            "应用凭证过期时不回退本机 (fail-closed on app branch)"
        )
    }

    static func configuredRuleGrokAppPrefersOverLocal() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let inputs = ConfiguredRuleEvaluator.Inputs(
            accountValues: [
                SubscriptionCredentialAccount.grokOAuth: validGrokJSON
            ],
            grokLocalAvailable: false,
            now: now
        )
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .grokAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.grokOAuth],
                inputs: inputs
            ),
            "Grok 应用有效凭证优先于本机 false"
        )
    }

    static func configuredRuleGrokFallsBackToLocal() throws {
        try coreExpect(
            ConfiguredRuleEvaluator.evaluate(
                .grokAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.grokOAuth],
                inputs: .init(grokLocalAvailable: true)
            ),
            "无应用凭证时本机 true → configured"
        )
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .grokAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.grokOAuth],
                inputs: .init(grokLocalAvailable: false)
            ),
            "无应用凭证且本机 false → 未配置"
        )
    }

    static func configuredRuleGrokExpiredAppFallsBackToLocal() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let expiredOnly = ConfiguredRuleEvaluator.Inputs(
            accountValues: [
                SubscriptionCredentialAccount.grokOAuth: expiredGrokJSON
            ],
            grokLocalAvailable: true,
            now: now
        )
        try coreExpect(
            !ConfiguredRuleEvaluator.evaluate(
                .grokAppOrLocalProbe,
                accounts: [SubscriptionCredentialAccount.grokOAuth],
                inputs: expiredOnly
            ),
            "Grok 应用凭证过期时不回退本机"
        )
    }

    static func configuredRuleRegistryMatchesProviders() throws {
        let expected: [SubscriptionProviderID: ConfiguredRule] = [
            .kimi: .allCredentialAccountsNonEmpty,
            .deepseek: .allCredentialAccountsNonEmpty,
            .volcengine: .allCredentialAccountsNonEmpty,
            .zhipu: .allCredentialAccountsNonEmpty,
            .codex: .codexHasConfiguredRecords,
            .antigravity: .allCredentialAccountsNonEmpty,
            .claude: .claudeAppOrLocalProbe,
            .grok: .grokAppOrLocalProbe,
            .opencodeGo: .allCredentialAccountsNonEmpty,
        ]
        for id in SubscriptionProviderID.allCases {
            let rule = ProviderRegistry.descriptor(for: id).configuredRule
            try coreExpect(
                rule == expected[id],
                "\(id.rawValue) configuredRule 应为 \(String(describing: expected[id])), 得 \(rule)"
            )
        }
    }

    // MARK: - OpenCode GO (console OAuth)

    static func opencodeGoCredentialAccountsAndRegistry() throws {
        try coreExpect(
            SubscriptionProviderID.opencodeGo.credentialAccounts == [
                SubscriptionCredentialAccount.opencodeGoOAuth
            ],
            "opencodeGo credentialAccounts 应含 opencode-go:oauth"
        )
        try coreExpect(
            ProviderRegistry.descriptor(for: .opencodeGo).injectionKind == .opencodeGoQuotaAccounts,
            "opencodeGo injectionKind 应为 opencodeGoQuotaAccounts"
        )
        try coreExpect(
            SubscriptionProviderID.opencodeGo.displayName == "OpenCode GO",
            "opencodeGo 展示名应为 OpenCode GO"
        )
    }

    static func opencodeGoEvaluatorValidAndMalformed() throws {
        let valid = #"{"auth":"Fe26.2**abc","workspaceId":"wrk_01"}"#
        try coreExpect(
            SubscriptionCredentialEvaluator.opencodeGoStatus(of: valid) == .valid,
            "opencodeGo 双字段应 valid"
        )
        let missingWorkspace = #"{"auth":"Fe26.2**abc"}"#
        try coreExpect(
            SubscriptionCredentialEvaluator.opencodeGoStatus(of: missingWorkspace) == .malformed,
            "opencodeGo 缺 workspaceId 应 malformed"
        )
        let empty = #"{}"#
        try coreExpect(
            SubscriptionCredentialEvaluator.opencodeGoStatus(of: empty) == .missing,
            "opencodeGo 空对象应 missing"
        )
        try coreExpect(
            SubscriptionCredentialEvaluator.opencodeGoStatus(of: "not-json") == .malformed,
            "opencodeGo 损坏 JSON 应 malformed"
        )
    }

    static func opencodeGoAccountIDAndLegacyKeys() throws {
        let accountID = ProviderAccountIDGenerator.opencodeGoAccountID(
            accessToken: "st_same"
        )
        try coreExpect(
            accountID == ProviderAccountIDGenerator.opencodeGoAccountID(
                accessToken: "st_same"
            ),
            "opencodeGo 同 token 应生成同 accountID"
        )
        try coreExpect(
            accountID != ProviderAccountIDGenerator.opencodeGoAccountID(
                accessToken: "st_other"
            ),
            "opencodeGo 不同 token 应生成不同 accountID"
        )
        try coreExpect(
            ProviderAccountKeys.legacyKeys(for: .opencodeGo) == [
                SubscriptionCredentialAccount.opencodeGoOAuth
            ],
            "opencodeGo legacyKeys 应含 opencode-go:oauth"
        )
    }

    // subscriptionProviderOrder 字段编解码往返, 兼容旧配置缺键.
    static func configSubscriptionProviderOrderRoundTrip() throws {
        // 编解码往返
        var config = OnboardingConfiguration()
        config.subscriptionProviderOrder = ["grok", "kimi", "deepseek"]
        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OnboardingConfiguration.self, from: encoded)
        try coreExpect(
            decoded.subscriptionProviderOrder == ["grok", "kimi", "deepseek"],
            "subscriptionProviderOrder 往返不一致: \(decoded.subscriptionProviderOrder ?? [])"
        )

        // 旧配置 (无该键) 解码为 nil
        let oldJSON = """
        {"schemaVersion":2,"selectedModules":[],"connectionStates":{},"lastVerifiedAt":{},"subscriptionProviders":{}}
        """
        let oldData = Data(oldJSON.utf8)
        let oldDecoded = try JSONDecoder().decode(OnboardingConfiguration.self, from: oldData)
        try coreExpect(
            oldDecoded.subscriptionProviderOrder == nil,
            "旧配置缺键应解码为 nil"
        )

        // 显式 null 也解码为 nil
        let nullJSON = """
        {"schemaVersion":2,"selectedModules":[],"connectionStates":{},"lastVerifiedAt":{},"subscriptionProviders":{},"subscriptionProviderOrder":null}
        """
        let nullData = Data(nullJSON.utf8)
        let nullDecoded = try JSONDecoder().decode(OnboardingConfiguration.self, from: nullData)
        try coreExpect(
            nullDecoded.subscriptionProviderOrder == nil,
            "显式 null 应解码为 nil"
        )
    }
}
