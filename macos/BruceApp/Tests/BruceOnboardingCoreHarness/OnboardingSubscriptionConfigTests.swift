import Foundation
@testable import BruceOnboardingCore

// MARK: - First launch / subscription config / credentials / verifier / externalQuotas

extension BruceOnboardingCoreHarness {
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

        // 阶段 1: 无授权记录, 所有模块 denied
        let initialGate = CollectorActivationGate(
            consentVersion: 1,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        for module in CollectorModule.allCases {
            try coreExpect(
                !initialGate.canActivate(
                    module: module, readiness: .ready,
                    isModuleSelected: true, appIsAcceptingNewTasks: true
                ),
                "无授权时所有模块必须 denied"
            )
        }

        // 阶段 2: 写入授权 (选中 agentUsage), 选中且 ready 的 agentUsage allowed
        var config = store.load() ?? OnboardingConfiguration()
        config.consentVersion = 1
        config.selectedModules = ["agent-usage"]
        try store.save(config)

        let confirmedGate = CollectorActivationGate(
            consentVersion: 1,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        let selectedModules = Set(
            (store.load()?.selectedModules ?? []).compactMap {
                CollectorModule(rawValue: $0)
            }
        )
        try coreExpect(
            confirmedGate.canActivate(
                module: .agentUsage, readiness: .ready,
                isModuleSelected: selectedModules.contains(.agentUsage),
                appIsAcceptingNewTasks: true
            ),
            "选中且 ready 的 agent-usage 必须 allowed"
        )

        // 阶段 3: 授权版本升级后, 已确认版本不再匹配, 全部 denied
        let upgradedGate = CollectorActivationGate(
            consentVersion: 2,
            confirmedConsentVersion: store.load()?.consentVersion
        )
        for module in CollectorModule.allCases {
            try coreExpect(
                !upgradedGate.canActivate(
                    module: module, readiness: .ready,
                    isModuleSelected: true, appIsAcceptingNewTasks: true
                ),
                "授权版本变化后所有模块必须 denied"
            )
        }
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

    /// glassStyle / interfaceStyle: 缺键与非法值回落; 主题解析能力矩阵.
    static func configGlassStyleDecodeAndFallback() throws {
        // 缺键 -> nil -> 标准模糊
        let missing = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(#"{"schemaVersion": 2}"#.utf8)
        )
        try coreExpect(missing.glassStyle == nil, "缺键必须为 nil")
        try coreExpect(
            missing.resolvedGlassStyle == .regular,
            "缺键必须回落标准玻璃"
        )
        try coreExpect(missing.interfaceStyle == nil, "interfaceStyle 缺键为 nil")

        // 非法字符串 -> nil, 不拒绝加载
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

        // 旧配置仅 glassStyle: 支持系统 -> 液态玻璃 + clear
        let legacyTheme = ThemeResolution.resolve(
            interfaceStyle: valid.interfaceStyle,
            glassStyle: valid.glassStyle,
            isSupported: true
        )
        try coreExpect(
            legacyTheme.interfaceStyle == .liquidGlass,
            "旧配置在支持系统上默认液态玻璃"
        )
        try coreExpect(legacyTheme.glassStyle == .clear, "保留 clear 模糊")
        try coreExpect(legacyTheme.usesLiquidGlassEffects, "clear 应使用玻璃 API")

        // 旧配置: 不支持系统 -> classic
        let legacyClassic = ThemeResolution.resolve(
            interfaceStyle: nil,
            glassStyle: .clear,
            isSupported: false
        )
        try coreExpect(
            legacyClassic.interfaceStyle == .classic,
            "不支持系统必须 classic"
        )
        try coreExpect(
            !legacyClassic.usesLiquidGlassEffects,
            "classic 不得使用玻璃 API"
        )

        // 注入: 存储 liquidGlass 但不支持 -> classic
        let forced = ThemeResolution.resolve(
            interfaceStyle: .liquidGlass,
            glassStyle: .regular,
            isSupported: false
        )
        try coreExpect(forced.interfaceStyle == .classic, "注入不支持强制 classic")

        // 注入: 支持 + liquidGlass
        let ok = ThemeResolution.resolve(
            interfaceStyle: .liquidGlass,
            glassStyle: .material,
            isSupported: true
        )
        try coreExpect(ok.interfaceStyle == .liquidGlass, "支持时保留 liquidGlass")
        try coreExpect(
            !ok.usesLiquidGlassEffects,
            "material 不走 glassEffect"
        )

        // interfaceStyle 往返
        let withInterface = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(
                #"{"schemaVersion": 2, "interfaceStyle": "classic", "glassStyle": "clear"}"#
                    .utf8
            )
        )
        try coreExpect(
            withInterface.interfaceStyle == .classic,
            "interfaceStyle classic 解码"
        )
        try coreExpect(
            withInterface.resolvedTheme(isLiquidGlassSupported: true).interfaceStyle
                == .classic,
            "显式 classic 在支持系统上仍为 classic"
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
        config.interfaceStyle = .classic
        try store.save(config)
        try coreExpect(
            store.load()?.glassStyle == .material,
            "glassStyle 往返必须一致"
        )
        try coreExpect(
            store.load()?.interfaceStyle == .classic,
            "interfaceStyle 往返必须一致"
        )
    }

    /// nothing 主题: 解码与相邻字段保全, 旧版本降级模拟, store 往返
    /// 与 ThemeResolution 能力矩阵 (3 x isSupported 共 6 组).
    static func configNothingStyleDecodeAndResolution() throws {
        // 合法值: "nothing" 经 decodeIfPresent 原样生效, 相邻字段不丢失
        let valid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(
                #"{"schemaVersion": 2, "interfaceStyle": "nothing", "appearanceMode": "dark", "refreshIntervalMinutes": 15, "glassStyle": "clear"}"#
                    .utf8
            )
        )
        try coreExpect(
            valid.interfaceStyle == .nothing,
            "interfaceStyle nothing 解码"
        )
        try coreExpect(
            valid.appearanceMode == .dark,
            "interfaceStyle 解码不得丢失相邻 appearanceMode"
        )
        try coreExpect(
            valid.refreshIntervalMinutes == 15,
            "interfaceStyle 解码不得丢失相邻 refreshIntervalMinutes"
        )
        try coreExpect(
            valid.glassStyle == .clear,
            "interfaceStyle 解码不得丢失相邻 glassStyle"
        )
        try coreExpect(
            valid.resolvedTheme(isLiquidGlassSupported: true).interfaceStyle
                == .nothing,
            "nothing 在支持系统上透传"
        )
        try coreExpect(
            valid.resolvedTheme(isLiquidGlassSupported: false).interfaceStyle
                == .nothing,
            "nothing 在低版本系统上仍透传"
        )

        // 旧版本降级模拟: 旧枚举 (无 nothing case) 读到 "nothing" 时
        // decodeIfPresent 抛 typeMismatch 被 try? 吞掉回落 nil.
        enum LegacyInterfaceStyle: String, Codable {
            case classic
            case liquidGlass
        }
        let legacyDecoded = try? JSONDecoder().decode(
            LegacyInterfaceStyle.self,
            from: Data(#""nothing""#.utf8)
        )
        try coreExpect(
            legacyDecoded == nil,
            "旧版本枚举读到 nothing 必须回落 nil"
        )
        let legacyFallback = ThemeResolution.resolve(
            interfaceStyle: nil,
            glassStyle: .clear,
            isSupported: true
        )
        // 旧 app 读不到 nothing 时 interfaceStyle 回落 nil, 沿用旧 app 自身的
        // 现网默认 (26+ -> liquidGlass, 14-25 -> classic), 不得引入回归.
        try coreExpect(
            legacyFallback.interfaceStyle == .liquidGlass,
            "旧版本回落 nil 后必须沿用现网默认 (26+ -> liquidGlass)"
        )
        try coreExpect(
            legacyFallback.usesLiquidGlassEffects,
            "旧版本回落 (26+ 默认 liquidGlass) 走玻璃 API"
        )

        // 同一条 try? decodeIfPresent 路径: 非法字符串回落 nil 且不炸整份 config
        let invalid = try JSONDecoder().decode(
            OnboardingConfiguration.self,
            from: Data(
                #"{"schemaVersion": 2, "interfaceStyle": "neon", "appearanceMode": "dark"}"#
                    .utf8
            )
        )
        try coreExpect(
            invalid.interfaceStyle == nil,
            "非法 interfaceStyle 必须按 nil 处理"
        )
        try coreExpect(
            invalid.appearanceMode == .dark,
            "interfaceStyle 非法值不得丢失相邻字段"
        )

        // ThemeResolution.resolve 矩阵: (.classic/.liquidGlass/.nothing)
        // x (isSupported true/false) 共 6 组
        for isSupported in [true, false] {
            let classic = ThemeResolution.resolve(
                interfaceStyle: .classic,
                glassStyle: .regular,
                isSupported: isSupported
            )
            try coreExpect(
                classic.interfaceStyle == .classic,
                "classic 必须原样透传"
            )
            try coreExpect(
                !classic.usesLiquidGlassEffects,
                "classic 不得使用玻璃 API"
            )

            let liquid = ThemeResolution.resolve(
                interfaceStyle: .liquidGlass,
                glassStyle: .regular,
                isSupported: isSupported
            )
            if isSupported {
                try coreExpect(
                    liquid.interfaceStyle == .liquidGlass,
                    "支持系统时 liquidGlass 透传"
                )
                try coreExpect(
                    liquid.usesLiquidGlassEffects,
                    "支持 + regular 必须走玻璃 API"
                )
            } else {
                try coreExpect(
                    liquid.interfaceStyle == .classic,
                    "不支持系统时 liquidGlass 降级 classic"
                )
                try coreExpect(
                    !liquid.usesLiquidGlassEffects,
                    "降级 classic 后不得使用玻璃 API"
                )
            }

            let nothing = ThemeResolution.resolve(
                interfaceStyle: .nothing,
                glassStyle: .regular,
                isSupported: isSupported
            )
            try coreExpect(
                nothing.interfaceStyle == .nothing,
                "nothing 不随玻璃能力降级, 必须原样透传"
            )
            try coreExpect(
                !nothing.usesLiquidGlassEffects,
                "nothing 不得使用玻璃 API"
            )
        }

        // store 原子读写往返
        let tempDir = makeTempDir("config-nothing")
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        var config = OnboardingConfiguration()
        config.interfaceStyle = .nothing
        config.glassStyle = .material
        try store.save(config)
        try coreExpect(
            store.load()?.interfaceStyle == .nothing,
            "interfaceStyle nothing 往返必须一致"
        )
        try coreExpect(
            store.load()?.glassStyle == .material,
            "nothing 往返不得影响 glassStyle"
        )
    }

    // MARK: - 订阅凭证 account 键 (内存实现)

    /// 七个订阅 provider account 键的增删改查与隔离.
    static func credentialStoreSubscriptionAccountsRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let accounts = [
            SubscriptionCredentialAccount.kimiAPIKey,
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
            "kimi-key-updated",
            forAccount: SubscriptionCredentialAccount.kimiAPIKey
        )
        let updated = try store.loadCredential(
            forAccount: SubscriptionCredentialAccount.kimiAPIKey
        )
        try coreExpect(
            updated == "kimi-key-updated",
            "kimi:api-key 覆盖写失败"
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
        let kimiAccount = SubscriptionCredentialAccount.kimiAPIKey
        let volcAK = SubscriptionCredentialAccount.volcengineAccessKey
        defer {
            try? store.deleteCredential(forAccount: kimiAccount)
            try? store.deleteCredential(forAccount: volcAK)
        }

        let keyV1 = "kimi-key-\(suffix)"
        try store.saveCredential(keyV1, forAccount: kimiAccount)
        let first = try store.loadCredential(forAccount: kimiAccount)
        try coreExpect(first == keyV1, "kimi:api-key 初次写入失败")

        let keyV2 = "kimi-key-2-\(suffix)"
        try store.saveCredential(keyV2, forAccount: kimiAccount)
        let updated = try store.loadCredential(forAccount: kimiAccount)
        try coreExpect(
            updated == keyV2,
            "kimi:api-key update 覆盖失败, got \(String(describing: updated))"
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

    static func verifierZhipuCredentialsMappings() throws {
        try coreExpect(
            ProviderConnectionVerifier.verifyZhipuCredentials(
                apiKey: "id.secret",
                baseURL: "https://open.bigmodel.cn/api/paas/v4"
            ) == .ok,
            "合理 api_key/国内站 base_url 必须 ok"
        )
        try coreExpect(
            ProviderConnectionVerifier.verifyZhipuCredentials(
                apiKey: "id.secret",
                baseURL: "https://api.z.ai/api/paas/v4"
            ) == .ok,
            "国外站 base_url 必须 ok"
        )
        let cases: [(String, String)] = [
            ("", "https://open.bigmodel.cn/api/paas/v4"),
            ("id.secret", ""),
            ("no dot key", "https://open.bigmodel.cn/api/paas/v4"),
            ("id.secret", "https://example.com/api/paas/v4"),
        ]
        for (key, base) in cases {
            guard case .failed = ProviderConnectionVerifier
                .verifyZhipuCredentials(apiKey: key, baseURL: base) else {
                throw CoreTestFailure.expectation(
                    "key=\(key) base=\(base) 必须 failed"
                )
            }
        }
    }

    // MARK: - StoredCredentialParser

    /// 解析 ProviderAccountStore 的 credentialJSON, 覆盖裸 key / AK-SK / 智谱
    /// 以及 OAuth 形态返回 nil 与非法输入的各种边界.
    static func storedCredentialParserMappings() throws {
        // Kimi / DeepSeek: 裸 key 字符串
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .kimi, credentialJSON: "  sk-abc123  "
            ) == .apiKey("sk-abc123"),
            "Kimi 裸 key 应去空白回传 apiKey"
        )
        try coreExpect(
            StoredCredentialParser.parse(provider: .deepseek, credentialJSON: "sk-xyz")
                == .apiKey("sk-xyz"),
            "DeepSeek 裸 key 应回传 apiKey"
        )
        try coreExpect(
            StoredCredentialParser.parse(provider: .kimi, credentialJSON: "   ")
                == nil,
            "空 key 应返回 nil"
        )

        // 火山引擎: {"accessKey","secretKey"}
        let volcJSON = """
        {"accessKey":"AKIDxxxx","secretKey":"SECRETyyyy"}
        """
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .volcengine, credentialJSON: volcJSON
            ) == .akSk(accessKey: "AKIDxxxx", secretKey: "SECRETyyyy"),
            "火山 AK/SK JSON 应回传 akSk"
        )
        // 多余字段容忍
        let volcExtra = """
        {"accessKey":"AK","secretKey":"SK","region":"cn-north-1"}
        """
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .volcengine, credentialJSON: volcExtra
            ) == .akSk(accessKey: "AK", secretKey: "SK"),
            "火山 AK/SK 多余字段应容忍"
        )
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .volcengine, credentialJSON: "{\"secretKey\":\"SK\"}"
            ) == nil,
            "火山缺 accessKey 应返回 nil"
        )
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .volcengine, credentialJSON: "not json"
            ) == nil,
            "火山非法 JSON 应返回 nil"
        )

        // 智谱: {"api_key","base_url"}
        let zhipuJSON = """
        {"api_key":"id.secret","base_url":"https://open.bigmodel.cn/api/paas/v4"}
        """
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .zhipu, credentialJSON: zhipuJSON
            ) == .zhipu(apiKey: "id.secret", baseURL: "https://open.bigmodel.cn/api/paas/v4"),
            "智谱 api_key/base_url 应回传 zhipu"
        )
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .zhipu, credentialJSON: "{\"api_key\":\"id.secret\"}"
            ) == nil,
            "智谱缺 base_url 应返回 nil"
        )

        // OAuth 形态 (Claude / Grok / OpenCode GO): 重新验证走 Evaluator, 不解析
        let oauthJSON = """
        {"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}
        """
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .claude, credentialJSON: oauthJSON
            ) == nil,
            "Claude OAuth JSON 应返回 nil"
        )
        try coreExpect(
            StoredCredentialParser.parse(
                provider: .opencodeGo, credentialJSON: "{\"auth\":\"x\",\"workspaceId\":\"wrk\"}"
            ) == nil,
            "OpenCode GO 凭证应返回 nil"
        )
    }

    // MARK: - AtomicJSONStore

    /// 备份滚动刷新: 每次 backupPrevious 写入都把备份刷成「本次写入前」的状态,
    /// 回滚还原的是上一次内容, 而不是 write-once 的陈旧快照.
    static func atomicStoreBackupRefreshesOnEachWrite() throws {
        let tempDir = makeTempDir("atomic-backup")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = AtomicJSONStore()
        let target = tempDir.appendingPathComponent("state.json")

        try store.write(Data("v1".utf8), to: target)
        try store.write(Data("v2".utf8), to: target, backupPrevious: true)
        let firstBackup = try String(
            contentsOf: store.backupURL(for: target), encoding: .utf8
        )
        try coreExpect(firstBackup == "v1", "首次备份备份的应是写入前的 v1")

        try store.write(Data("v3".utf8), to: target, backupPrevious: true)
        let refreshedBackup = try String(
            contentsOf: store.backupURL(for: target), encoding: .utf8
        )
        try coreExpect(refreshedBackup == "v2", "再次写入后备份应刷新为 v2 (滚动深度 1)")

        try coreExpect(store.rollback(target) == .rolledBack, "回滚应成功")
        let rolledBack = try String(contentsOf: target, encoding: .utf8)
        try coreExpect(rolledBack == "v2", "回滚应还原上一次写入前的 v2")
    }
}
