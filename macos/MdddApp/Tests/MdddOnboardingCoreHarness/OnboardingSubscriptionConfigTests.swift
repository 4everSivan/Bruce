import Foundation
@testable import MdddOnboardingCore

// MARK: - First launch / subscription config / credentials / verifier / externalQuotas

extension MdddOnboardingCoreHarness {
    // MARK: - ProviderConnectionVerifier

    /// 可注入的假 URLSession, 记录请求并返回预设响应.
    final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
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
    static func firstLaunchDecisionFlow() throws {
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
    static func configStoreLoadsV1WithSubscriptionDefaults() throws {
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
    static func configStoreRejectsNewerSchemaV3() throws {
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
    static func configStoreSubscriptionProvidersRoundTrip() throws {
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
    static func configRefreshIntervalDecodeAndFallback() throws {
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
    static func configAppearanceModeDecodeAndFallback() throws {
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
    static func configGlassStyleDecodeAndFallback() throws {
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
    static func credentialStoreSubscriptionAccountsRoundTrip() throws {
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
    static func keychainSubscriptionAccountsRoundTrip() throws {
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
    static func verifierDeepSeekConnectedWithMockSession() async throws {
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
    static func verifierDeepSeekFailClosed() async throws {
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

    static func verifierKimiWebTokensJSONMappings() throws {
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

    static func verifierCodexAccountsJSONMappings() throws {
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

    static func verifierAntigravityOAuthJSONMappings() throws {
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

    static func verifierVolcengineCredentialsMappings() throws {
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
    static func gateAgentPolicyGrantsExternalQuotasWhenConfigured() throws {
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
    static func gateEvaluatorPropagatesSubscriptionFlag() throws {
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

}
