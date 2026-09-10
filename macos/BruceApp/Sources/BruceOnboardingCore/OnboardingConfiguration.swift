import Foundation
import LocalAuthentication
import Security

// MARK: - SubscriptionProviderID

/// 订阅额度 provider 标识. 持久化为配置字典键和 Keychain account 前缀.
public enum SubscriptionProviderID: String, Codable, Sendable, CaseIterable {
    case kimi
    case deepseek
    case volcengine
    case zhipu
    case codex
    case claude
    case grok
    case opencodeGo
}

// MARK: - SubscriptionVerificationStatus

/// 订阅 provider 的验证状态. failed 携带可诊断原因.
public enum SubscriptionVerificationStatus: Codable, Equatable, Sendable {
    case none
    case ok
    case failed(reason: String)
    case needsRelogin
}

// MARK: - SubscriptionProviderConfiguration

/// 单个订阅 provider 的非敏感配置. 凭证本体存 Keychain, 不进入此结构.
public struct SubscriptionProviderConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var lastVerifiedAt: String?
    public var verificationStatus: SubscriptionVerificationStatus
    /// 账本追踪边界 (仅 DeepSeek 使用). 值为随机 UUID, 非敏感;
    /// 保存或更换 DeepSeek API key 时生成新值, 用于隔离新旧账户的月度账本.
    /// 其他 provider 一律为 nil. 旧配置缺该键时解码为 nil, 无需 schema 升级.
    public var usageTrackingID: String?

    public init(
        enabled: Bool = false,
        lastVerifiedAt: String? = nil,
        verificationStatus: SubscriptionVerificationStatus = .none,
        usageTrackingID: String? = nil
    ) {
        self.enabled = enabled
        self.lastVerifiedAt = lastVerifiedAt
        self.verificationStatus = verificationStatus
        self.usageTrackingID = usageTrackingID
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case lastVerifiedAt
        case verificationStatus
        case usageTrackingID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
        verificationStatus = try container.decodeIfPresent(
            SubscriptionVerificationStatus.self, forKey: .verificationStatus
        ) ?? .none
        // 旧配置缺该键或显式 null 一律按 nil, 不因新增字段拒绝加载.
        usageTrackingID = try container.decodeIfPresent(
            String.self, forKey: .usageTrackingID
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encode(verificationStatus, forKey: .verificationStatus)
        try container.encodeIfPresent(usageTrackingID, forKey: .usageTrackingID)
    }
}

// MARK: - OnboardingConfiguration

/// 应用外观偏好. system 跟随系统; 持久化为 rawValue 字符串.
public enum AppearancePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

/// 模糊风格偏好 (仅液态玻璃模式下展示). regular 标准, clear 通透,
/// material 哑光/材质; 持久化为 rawValue 字符串.
public enum GlassStylePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case regular
    case clear
    case material
}

/// 非敏感配置. 持久化到 Application Support/Bruce/config/onboarding-v1.json.
public struct OnboardingConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var selectedModules: Set<String>
    public var consentVersion: Int?
    /// 菜单栏指标 rawValue 有序列表. nil 使用应用默认值.
    public var menuBarMetrics: [String]?
    /// 订阅 provider 配置, 键为 SubscriptionProviderID rawValue.
    /// v1 配置文件无此键, 加载时按缺省 (全部未配置) 处理.
    public var subscriptionProviders: [String: SubscriptionProviderConfiguration]
    /// 自动刷新间隔 (分钟). nil (含 JSON 显式 null) 表示使用默认 30 分钟.
    public var refreshIntervalMinutes: Int?
    /// 外观偏好. nil (含 JSON 显式 null 或非法值) 表示跟随系统.
    public var appearanceMode: AppearancePreference?
    /// 界面风格. nil 表示缺键: 由 ThemeResolution 按能力回落.
    public var interfaceStyle: InterfaceStylePreference?
    /// 模糊风格 (液态玻璃子选项). nil 表示标准玻璃.
    public var glassStyle: GlassStylePreference?
    /// 订阅 provider 展示顺序 (rawValue 列表). nil 表示使用 CaseIterable 默认顺序;
    /// 用户在设置页调整顺序后写入. 仅包含已添加的 provider.
    public var subscriptionProviderOrder: [String]?
    /// 全局快捷键 (打开/关闭仪表盘). nil (含 JSON 显式 null) 表示未设置, 不劫持任何键.
    public var dashboardHotkey: GlobalHotkey?
    /// 统一的 Keychain 访问配置.
    /// 只保存授权状态和外部来源白名单, 不保存系统密码或任何凭证内容.
    public var keychainAccess: KeychainAccessConfiguration
    /// 旧调用方兼容属性. 生产逻辑应使用 KeychainAccessPolicy.
    public var keychainAccessConfigured: Bool {
        get { keychainAccess.bruceStoreReady }
        set {
            keychainAccess.bruceStoreConfigured = newValue
            keychainAccess.bruceStoreStorageVersion = newValue
                ? KeychainAccessConfiguration.currentBruceStoreStorageVersion : 0
        }
    }
    /// 是否允许 Bruce 投递系统通知. 这是应用层开关, 不会修改 macOS 的系统授权状态.
    public var systemNotificationsEnabled: Bool

    /// 默认自动刷新间隔 (分钟).
    public static let defaultRefreshIntervalMinutes = 30
    /// 设置页可选的刷新间隔 (分钟).
    public static let allowedRefreshIntervalMinutes: [Int] = [5, 15, 30, 60]

    /// 解析后的刷新间隔: nil 或非法值一律回落默认 30 分钟.
    public var resolvedRefreshIntervalMinutes: Int {
        guard let value = refreshIntervalMinutes,
              Self.allowedRefreshIntervalMinutes.contains(value) else {
            return Self.defaultRefreshIntervalMinutes
        }
        return value
    }

    /// 解析后的外观偏好: nil 一律回落跟随系统.
    public var resolvedAppearanceMode: AppearancePreference {
        appearanceMode ?? .system
    }

    /// 解析后的模糊风格: nil 一律回落标准.
    public var resolvedGlassStyle: GlassStylePreference {
        glassStyle ?? .regular
    }

    /// 解析后的全局快捷键: nil 一律回落未设置.
    public var resolvedDashboardHotkey: GlobalHotkey? {
        dashboardHotkey
    }

    /// 按当前进程能力解析完整主题 (界面风格 + 模糊 + 是否用玻璃 API).
    public func resolvedTheme(
        isLiquidGlassSupported: Bool = LiquidGlassCapability.isSupported
    ) -> ResolvedTheme {
        ThemeResolution.resolve(
            interfaceStyle: interfaceStyle,
            glassStyle: glassStyle,
            isSupported: isLiquidGlassSupported
        )
    }

    /// 解析后的界面风格 (依赖当前系统能力) 由 resolvedTheme 提供;
    /// 无独立计算属性, 避免绕过能力回落逻辑.

    public init(
        schemaVersion: Int = OnboardingConfiguration.currentSchemaVersion,
        selectedModules: Set<String> = [],
        consentVersion: Int? = nil,
        menuBarMetrics: [String]? = nil,
        subscriptionProviders: [String: SubscriptionProviderConfiguration] = [:],
        refreshIntervalMinutes: Int? = nil,
        appearanceMode: AppearancePreference? = nil,
        interfaceStyle: InterfaceStylePreference? = nil,
        glassStyle: GlassStylePreference? = nil,
        subscriptionProviderOrder: [String]? = nil,
        dashboardHotkey: GlobalHotkey? = nil,
        keychainAccessConfigured: Bool = false,
        keychainAccess: KeychainAccessConfiguration? = nil,
        systemNotificationsEnabled: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.selectedModules = selectedModules
        self.consentVersion = consentVersion
        self.menuBarMetrics = menuBarMetrics
        self.subscriptionProviders = subscriptionProviders
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.appearanceMode = appearanceMode
        self.interfaceStyle = interfaceStyle
        self.glassStyle = glassStyle
        self.subscriptionProviderOrder = subscriptionProviderOrder
        self.dashboardHotkey = dashboardHotkey
        self.keychainAccess = keychainAccess ?? KeychainAccessConfiguration(
            bruceStoreConfigured: keychainAccessConfigured
        )
        self.systemNotificationsEnabled = systemNotificationsEnabled
    }

    /// 自定义解码: 旧版本配置缺失的键一律回落缺省, 不因新增字段拒绝加载.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedModules = try container.decodeIfPresent(Set<String>.self, forKey: .selectedModules) ?? []
        consentVersion = try container.decodeIfPresent(Int.self, forKey: .consentVersion)
        menuBarMetrics = try container.decodeIfPresent([String].self, forKey: .menuBarMetrics)
        subscriptionProviders = try container.decodeIfPresent(
            [String: SubscriptionProviderConfiguration].self,
            forKey: .subscriptionProviders
        ) ?? [:]
        // 显式 null 与缺键一样按 nil (默认 30 分钟) 处理
        refreshIntervalMinutes = try container.decodeIfPresent(
            Int.self, forKey: .refreshIntervalMinutes
        )
        // 非法字符串与缺键一样按 nil (跟随系统) 处理
        appearanceMode = try? container.decodeIfPresent(
            AppearancePreference.self, forKey: .appearanceMode
        )
        // 非法字符串与缺键一样按 nil (由 ThemeResolution 回落)
        interfaceStyle = try? container.decodeIfPresent(
            InterfaceStylePreference.self, forKey: .interfaceStyle
        )
        // 非法字符串与缺键一样按 nil (标准模糊)
        glassStyle = try? container.decodeIfPresent(
            GlassStylePreference.self, forKey: .glassStyle
        )
        // 旧配置缺该键或显式 null 一律按 nil, 不因新增字段拒绝加载
        subscriptionProviderOrder = try container.decodeIfPresent(
            [String].self, forKey: .subscriptionProviderOrder
        )
        // 旧配置缺该键或显式 null 一律按 nil, 不因新增字段拒绝加载
        dashboardHotkey = try container.decodeIfPresent(
            GlobalHotkey.self, forKey: .dashboardHotkey
        )
        // 新配置存在但损坏时必须 default-deny, 不回退到旧布尔值.
        if container.contains(.keychainAccess) {
            keychainAccess = (try? container.decodeIfPresent(
                KeychainAccessConfiguration.self, forKey: .keychainAccess
            )) ?? KeychainAccessConfiguration()
        } else {
            // 兼容旧配置: 保留旧布尔值供迁移/展示, 但缺少 setup marker 时
            // 不开放自动 Bruce Store 访问.
            keychainAccess = KeychainAccessConfiguration(
                bruceStoreConfigured: try container.decodeIfPresent(
                    Bool.self, forKey: .keychainAccessConfigured
                ) ?? false,
                // The legacy boolean predates the explicit setup marker.
                bruceStoreStorageVersion: 0
            )
        }
        // 旧配置缺该键时保持历史行为: 系统通知功能默认开启.
        systemNotificationsEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .systemNotificationsEnabled
        ) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedModules
        case consentVersion
        case menuBarMetrics
        case subscriptionProviders
        case refreshIntervalMinutes
        case appearanceMode
        case interfaceStyle
        case glassStyle
        case subscriptionProviderOrder
        case dashboardHotkey
        case keychainAccess
        case keychainAccessConfigured
        case systemNotificationsEnabled
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(selectedModules, forKey: .selectedModules)
        try container.encodeIfPresent(consentVersion, forKey: .consentVersion)
        try container.encodeIfPresent(menuBarMetrics, forKey: .menuBarMetrics)
        try container.encode(subscriptionProviders, forKey: .subscriptionProviders)
        try container.encodeIfPresent(
            refreshIntervalMinutes, forKey: .refreshIntervalMinutes
        )
        try container.encodeIfPresent(appearanceMode, forKey: .appearanceMode)
        try container.encodeIfPresent(interfaceStyle, forKey: .interfaceStyle)
        try container.encodeIfPresent(glassStyle, forKey: .glassStyle)
        try container.encodeIfPresent(
            subscriptionProviderOrder, forKey: .subscriptionProviderOrder
        )
        try container.encodeIfPresent(dashboardHotkey, forKey: .dashboardHotkey)
        try container.encode(keychainAccess, forKey: .keychainAccess)
        try container.encode(systemNotificationsEnabled, forKey: .systemNotificationsEnabled)
    }
}

// MARK: - OnboardingConfigurationStore

/// 非敏感配置的原子读写. 文件权限 0600. 落到统一的 `AtomicJSONStore`.
public final class OnboardingConfigurationStore: @unchecked Sendable {
    private let configURL: URL
    private let fileManager: FileManager
    private let atomicStore: AtomicJSONStore
    private let queue = DispatchQueue(label: "Bruce.onboarding-config")

    public init(configDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.configURL = configDirectory
            .appendingPathComponent("onboarding-v1.json")
        self.atomicStore = AtomicJSONStore(
            fileManager: fileManager,
            filePermissions: 0o600,
            dirPermissions: 0o700
        )
        try ensureDirectory(at: configDirectory)
    }

    public convenience init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let configDir = appSupport
            .appendingPathComponent("Bruce", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try self.init(configDirectory: configDir)
    }

    /// 读取配置. 文件不存在返回空配置. schema 版本不匹配返回 nil.
    public func load() -> OnboardingConfiguration? {
        queue.sync {
            let result = atomicStore.read(
                OnboardingConfiguration.self,
                from: configURL
            )
            switch result {
            case .loaded(let config):
                // 未知新 schema -> 安全拒绝 (不回滚, 避免降回旧结构).
                guard config.schemaVersion <= OnboardingConfiguration.currentSchemaVersion else {
                    return nil
                }
                return config
            case .missing:
                return OnboardingConfiguration()
            case .incompatible:
                // 高版本 schema: 保守拒绝, 不回滚 (避免降回旧结构).
                return nil
            case .unreadable:
                // 读取失败 (权限/IO): 文件内容未知, 保守不回滚, 视为缺失.
                return OnboardingConfiguration()
            case .corrupt:
                // 损坏: 尝试从备份回滚一次; 回滚结果与直读同样执行 schema 校验,
                // 高版本备份保守拒绝 (App 降级场景), 仍不可用则视为缺失.
                if atomicStore.rollback(configURL) == .rolledBack,
                   case .loaded(let rolled) = atomicStore.read(
                       OnboardingConfiguration.self, from: configURL
                   ),
                   rolled.schemaVersion <= OnboardingConfiguration.currentSchemaVersion {
                    return rolled
                }
                return OnboardingConfiguration()
            }
        }
    }

    /// 原子写入配置: 由 `AtomicJSONStore` 统一临时文件 -> 同步 -> 重读校验 ->
    /// 原子替换, 并备份上一版本以支持回滚.
    public func save(_ config: OnboardingConfiguration) throws {
        try queue.sync {
            try atomicStore.write(
                config,
                to: configURL,
                validate: { reread in
                    guard reread == config else {
                        throw AtomicJSONStore.AtomicJSONStoreError.storageFailure
                    }
                },
                backupPrevious: true
            )
        }
    }

    private func ensureDirectory(at url: URL) throws {
        try atomicStore.prepareDirectory(at: url)
    }
}

// MARK: - OnboardingConfigError

public enum OnboardingConfigError: Error, Equatable {
    case storageFailure
}

// MARK: - SubscriptionCredentialAccount

/// 订阅 provider 的 Keychain account 键. 当前 service 为
/// com.bruce.dashboard.credentials.v2; 无配置时只在用户主动迁移中读取旧 service.
public enum SubscriptionCredentialAccount {
    /// Kimi For Coding API key 字符串
    public static let kimiAPIKey = "kimi:api-key"
    /// DeepSeek API key 字符串
    public static let deepseekAPIKey = "deepseek:api-key"
    /// 火山引擎 AccessKey 字符串
    public static let volcengineAccessKey = "volcengine:ak"
    /// 火山引擎 SecretKey 字符串
    public static let volcengineSecretKey = "volcengine:sk"
    /// 智谱 API key 字符串 (id.secret 形式)
    public static let zhipuAPIKey = "zhipu:api-key"
    /// 智谱推理 Base URL (国内站 open.bigmodel.cn 或国外站 api.z.ai)
    public static let zhipuBaseURL = "zhipu:base-url"
    /// CC Switch 同构 JSON {"accounts": {id: {email, refresh_token, access_token, id_token}}}
    public static let codexAccounts = "codex:accounts"
    /// Codex 当前账号 id 字符串
    public static let codexActiveAccount = "codex:active-account"
    /// Claude 手动导入凭证: claudeAiOauth 同构 JSON (Phase 2)
    public static let claudeOAuth = "claude:oauth"
    /// Grok 手动导入凭证: scope 映射同构 JSON (Phase 2)
    public static let grokOAuth = "grok:oauth"
    /// OpenCode GO 手动导入凭证: {"access_token", "refresh_token", "expiry"} JSON
    public static let opencodeGoOAuth = "opencode-go:oauth"
}

/// Codex v2 Keychain 键别名 (供既有调用方引用; 旧键只供迁移读取).
extension SubscriptionCredentialAccount {
    public static let codexAccountIndexV2 = CodexCredentialKeys.accountIndexV2
    public static let codexAccountV2Prefix = CodexCredentialKeys.accountV2Prefix
    public static let codexLegacyAccounts = CodexCredentialKeys.legacyAccounts
    public static let codexLegacyActiveAccount = CodexCredentialKeys.legacyActiveAccount
}

// MARK: - CredentialStore

/// 凭证存储协议. 系统实现使用 macOS Keychain, 测试使用内存 fake.
public protocol CredentialStore: Sendable {
    /// 通用 account 读写, 供订阅 provider 凭证使用.
    func saveCredential(_ value: String, forAccount account: String) throws
    func loadCredential(forAccount account: String) throws -> String?
    func deleteCredential(forAccount account: String) throws
    /// 配置该 store 管理的 Keychain 项目访问 ACL, 返回处理的项目数.
    /// 非 macOS Keychain fake 默认无副作用, 便于纯逻辑测试.
    func configureKeychainAccess() throws -> Int
}

/// 支持区分自动访问和用户主动操作的凭证存储.
/// 保留 `CredentialStore` 的旧方法, 让测试 fake 和外部调用方可以渐进迁移.
public protocol IntentAwareCredentialStore: CredentialStore {
    func saveCredential(
        _ value: String,
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws
    func loadCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws -> String?
    func deleteCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws
}

public extension CredentialStore {
    func configureKeychainAccess() throws -> Int {
        0
    }

    func saveCredential(
        _ value: String,
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws {
        if let intentAware = self as? any IntentAwareCredentialStore {
            try intentAware.saveCredential(value, forAccount: account, intent: intent)
        } else {
            try saveCredential(value, forAccount: account)
        }
    }

    func loadCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws -> String? {
        if let intentAware = self as? any IntentAwareCredentialStore {
            return try intentAware.loadCredential(forAccount: account, intent: intent)
        }
        return try loadCredential(forAccount: account)
    }

    func deleteCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws {
        if let intentAware = self as? any IntentAwareCredentialStore {
            try intentAware.deleteCredential(forAccount: account, intent: intent)
        } else {
            try deleteCredential(forAccount: account)
        }
    }
}

// MARK: - InMemoryCredentialStore

/// 内存 fake, 用于测试.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func saveCredential(_ value: String, forAccount account: String) throws {
        lock.lock()
        storage[account] = value
        lock.unlock()
    }

    public func loadCredential(forAccount account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func deleteCredential(forAccount account: String) throws {
        lock.lock()
        storage[account] = nil
        lock.unlock()
    }
}

// MARK: - KeychainCredentialStore

enum KeychainQueryOperation: Equatable {
    case copyMatching
    case mutation
}

/// macOS Keychain 实现.
/// 保存为 update 优先的原子语义: 不先删后加, 添加失败不会丢失原凭证.
public final class KeychainCredentialStore: IntentAwareCredentialStore, @unchecked Sendable {
    public static let legacyService = "com.bruce.dashboard.credentials"
    public static let defaultService = "com.bruce.dashboard.credentials.v2"

    private let service: String
    private let accessController: KeychainAccessController

    public init(
        service: String = KeychainCredentialStore.defaultService,
        accessController: KeychainAccessController = KeychainAccessController()
    ) {
        self.service = service
        self.accessController = accessController
    }

    static func currentQuery(
        service: String,
        account: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    /// User-triggered setup first enumerates metadata. Requesting all item data
    /// together with `kSecMatchLimitAll` is rejected by macOS Keychain with
    /// `errSecParam` on legacy login-Keychain items.
    static func legacyListQuery(context: LAContext) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        Self.applyAuthenticationPolicy(
            to: &query,
            intent: .userInitiated,
            operation: .copyMatching,
            context: context
        )
        return query
    }

    /// Read one legacy item at a time so macOS can authenticate the protected
    /// data while reusing the single setup LAContext.
    static func legacyDataQuery(
        account: String,
        context: LAContext
    ) -> [String: Any] {
        var query = Self.currentQuery(
            service: Self.legacyService,
            account: account
        )
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        Self.applyAuthenticationPolicy(
            to: &query,
            intent: .userInitiated,
            operation: .copyMatching,
            context: context
        )
        return query
    }

    private func currentQuery(forAccount account: String) -> [String: Any] {
        Self.currentQuery(service: service, account: account)
    }

    public func saveCredential(_ value: String, forAccount account: String) throws {
        try saveCredential(value, forAccount: account, intent: .automatic)
    }

    public func saveCredential(
        _ value: String,
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws {
        try requireAccess(intent)
        let data = Data(value.utf8)

        let baseQuery = currentQuery(forAccount: account)

        if intent == .automatic {
            try saveAutomatically(
                data: data,
                baseQuery: baseQuery
            )
            return
        }

        var interactiveQuery = baseQuery
        Self.applyAuthenticationPolicy(
            to: &interactiveQuery,
            intent: intent,
            operation: .mutation
        )
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // 优先 SecItemUpdate: 已存在则就地更新, 不经过删除窗口
        var status = SecItemUpdate(
            interactiveQuery as CFDictionary, updateAttributes as CFDictionary
        )
        if status == errSecItemNotFound {
            // 不存在才添加; 并发下撞见重复项则回退 update
            var addQuery = interactiveQuery
            addQuery[kSecValueData as String] = data
            // 新 namespace 只由当前 App 创建和读取; Collector 只消费 stdin
            // 注入值, 不直接读取该 service.
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    interactiveQuery as CFDictionary, updateAttributes as CFDictionary
                )
            }
        }
        guard status == errSecSuccess else {
            throw saveError(status: status, intent: intent)
        }
    }

    private func saveAutomatically(
        data: Data,
        baseQuery: [String: Any]
    ) throws {
        var probeQuery = baseQuery
        probeQuery[kSecReturnAttributes as String] = true
        probeQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        Self.applyAuthenticationPolicy(
            to: &probeQuery,
            intent: .automatic,
            operation: .copyMatching
        )

        var probeResult: CFTypeRef?
        let probeStatus = SecItemCopyMatching(
            probeQuery as CFDictionary,
            &probeResult
        )
        switch probeStatus {
        case errSecSuccess:
            var updateQuery = baseQuery
            Self.applyAuthenticationPolicy(
                to: &updateQuery,
                intent: .automatic,
                operation: .mutation
            )
            let status = SecItemUpdate(
                updateQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard status == errSecSuccess else {
                throw saveError(status: status, intent: .automatic)
            }
        case errSecItemNotFound:
            // `UISkip` also hides legacy items that need UI. Add first in this
            // branch; duplicate means an inaccessible legacy item exists, so
            // fail closed instead of letting SecItemUpdate open a prompt.
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                accessController.markBlocked()
                throw KeychainError.accessBlocked(
                    .bruceStore,
                    errSecInteractionNotAllowed
                )
            }
            guard status == errSecSuccess else {
                throw saveError(status: status, intent: .automatic)
            }
        default:
            throw saveError(status: probeStatus, intent: .automatic)
        }
    }

    /// 把旧 login Keychain 中的 Bruce 项目迁移到新的 Bruce namespace.
    /// 只在用户主动配置时读取旧项目, 并复用同一个认证上下文; 后台永远
    /// 不再触碰 legacy item. 旧项目不删除, 作为失败回滚副本保留.
    public func configureKeychainAccess() throws -> Int {
        // 一个上下文覆盖旧项目枚举和数据迁移. 旧 login Keychain 项目如果
        // 每次读取都创建新上下文, 会把一次配置放大成按项目重复认证.
        let authenticationContext = LAContext()
        authenticationContext.localizedReason =
            "Bruce 需要一次性配置钥匙串访问权限"

        let query = Self.legacyListQuery(context: authenticationContext)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return 0
        }
        guard status == errSecSuccess else {
            throw KeychainAccessError.listFailed(status)
        }

        let items: [[String: Any]]
        if let array = result as? [[String: Any]] {
            items = array
        } else if let item = result as? [String: Any] {
            items = [item]
        } else {
            return 0
        }

        guard !items.isEmpty else {
            return 0
        }

        var migrated = 0
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else {
                continue
            }

            let dataQuery = Self.legacyDataQuery(
                account: account,
                context: authenticationContext
            )
            var dataResult: CFTypeRef?
            let dataStatus = SecItemCopyMatching(
                dataQuery as CFDictionary,
                &dataResult
            )
            if dataStatus == errSecItemNotFound {
                continue
            }
            guard dataStatus == errSecSuccess,
                  let data = dataResult as? Data else {
                throw KeychainAccessError.listFailed(dataStatus)
            }

            var addQuery = Self.currentQuery(
                service: service,
                account: account
            )
            addQuery[kSecValueData as String] = data

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                var updateQuery = Self.currentQuery(
                    service: service,
                    account: account
                )
                Self.applyAuthenticationPolicy(
                    to: &updateQuery,
                    intent: .userInitiated,
                    operation: .mutation,
                    context: authenticationContext
                )
                let updateStatus = SecItemUpdate(
                    updateQuery as CFDictionary,
                    [kSecValueData as String: data] as CFDictionary
                )
                guard updateStatus == errSecSuccess else {
                    throw KeychainAccessError.updateFailed(updateStatus)
                }
            } else if addStatus != errSecSuccess {
                throw KeychainAccessError.updateFailed(addStatus)
            }
            migrated += 1
        }
        return migrated
    }

    public func loadCredential(forAccount account: String) throws -> String? {
        try loadCredential(forAccount: account, intent: .automatic)
    }

    public func loadCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws -> String? {
        try requireAccess(intent)
        var query = currentQuery(forAccount: account)
        query.merge([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]) { _, new in new }
        Self.applyAuthenticationPolicy(
            to: &query,
            intent: intent,
            operation: .copyMatching
        )

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw loadError(status: status, intent: intent)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteCredential(forAccount account: String) throws {
        try deleteCredential(forAccount: account, intent: .automatic)
    }

    public func deleteCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws {
        try requireAccess(intent)
        let baseQuery = currentQuery(forAccount: account)

        if intent == .automatic {
            var probeQuery = baseQuery
            probeQuery[kSecReturnAttributes as String] = true
            probeQuery[kSecMatchLimit as String] = kSecMatchLimitOne
            Self.applyAuthenticationPolicy(
                to: &probeQuery,
                intent: .automatic,
                operation: .copyMatching
            )
            var probeResult: CFTypeRef?
            let probeStatus = SecItemCopyMatching(
                probeQuery as CFDictionary,
                &probeResult
            )
            // UISkip 会把需要 UI 的项目视为不可见. 此时不再调用
            // mutation API, 避免自动清理重新唤起系统授权.
            guard probeStatus == errSecSuccess else {
                if probeStatus == errSecItemNotFound {
                    return
                }
                throw deleteError(status: probeStatus, intent: intent)
            }
        }

        var query = baseQuery
        Self.applyAuthenticationPolicy(
            to: &query,
            intent: intent,
            operation: .mutation
        )

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw deleteError(status: status, intent: intent)
        }
    }

    private func requireAccess(_ intent: KeychainAccessIntent) throws {
        guard accessController.allows(
            source: .bruceStore,
            intent: intent
        ) else {
            if accessController.policy.state == .blocked {
                throw KeychainError.accessBlocked(
                    .bruceStore,
                    errSecInteractionNotAllowed
                )
            }
            throw KeychainError.notConfigured(.bruceStore)
        }
    }

    static func applyAuthenticationPolicy(
        to query: inout [String: Any],
        intent: KeychainAccessIntent,
        operation: KeychainQueryOperation,
        context: LAContext? = nil
    ) {
        switch intent {
        case .automatic:
            // 后台读取只允许立即返回, 绝不让 Security.framework 拉起
            // 认证 UI. UISkip 只对 SecItemCopyMatching 有效, mutation
            // 不得携带它.
            let context = context ?? LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            if operation == .copyMatching {
                query[kSecUseAuthenticationUI as String] =
                    kSecUseAuthenticationUISkip
            }
        case .userInitiated:
            if let context {
                // Keep the system authentication UI available for an explicit
                // user action. Automatic operations set this to true above.
                context.interactionNotAllowed = false
                query[kSecUseAuthenticationContext as String] = context
            }
        }
    }

    private static func isAccessBlockedStatus(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    private func saveError(
        status: OSStatus,
        intent: KeychainAccessIntent
    ) -> KeychainError {
        if intent == .automatic && Self.isAccessBlockedStatus(status) {
            accessController.markBlocked()
            return .accessBlocked(.bruceStore, status)
        }
        return .saveFailed(status)
    }

    private func loadError(
        status: OSStatus,
        intent: KeychainAccessIntent
    ) -> KeychainError {
        if intent == .automatic && Self.isAccessBlockedStatus(status) {
            accessController.markBlocked()
            return .accessBlocked(.bruceStore, status)
        }
        return .loadFailed(status)
    }

    private func deleteError(
        status: OSStatus,
        intent: KeychainAccessIntent
    ) -> KeychainError {
        if intent == .automatic && Self.isAccessBlockedStatus(status) {
            accessController.markBlocked()
            return .accessBlocked(.bruceStore, status)
        }
        return .deleteFailed(status)
    }
}

// MARK: - KeychainError

public enum KeychainError: Error, Equatable {
    case notConfigured(KeychainAccessSource)
    case accessBlocked(KeychainAccessSource, OSStatus)
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}

public enum KeychainAccessError: Error, Equatable {
    case accessControlCreationFailed
    case listFailed(OSStatus)
    case updateFailed(OSStatus)
}
