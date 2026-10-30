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
    case stepfun
    case jev
    case cline
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

    public init(
        enabled: Bool = false,
        lastVerifiedAt: String? = nil,
        verificationStatus: SubscriptionVerificationStatus = .none
    ) {
        self.enabled = enabled
        self.lastVerifiedAt = lastVerifiedAt
        self.verificationStatus = verificationStatus
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case lastVerifiedAt
        case verificationStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
        verificationStatus = try container.decodeIfPresent(
            SubscriptionVerificationStatus.self, forKey: .verificationStatus
        ) ?? .none
        // 旧配置遗留的 usageTrackingID (账本追踪边界, C020 已移除) 由
        // JSONDecoder 忽略未知键, 无需迁移代码.
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(lastVerifiedAt, forKey: .lastVerifiedAt)
        try container.encode(verificationStatus, forKey: .verificationStatus)
    }
}

// MARK: - ModelPricingOverride

/// 模型单价人工校准项. 未设置的单价项自动继承内置基准.
public struct ModelPricingOverride: Codable, Equatable, Sendable {
    public var inputPricePerMillion: Double?
    public var outputPricePerMillion: Double?
    public var cacheReadPricePerMillion: Double?
    public var currency: String?
    public var note: String?

    public init(
        inputPricePerMillion: Double? = nil,
        outputPricePerMillion: Double? = nil,
        cacheReadPricePerMillion: Double? = nil,
        currency: String? = nil,
        note: String? = nil
    ) {
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
        self.currency = currency
        self.note = note
    }
}

// MARK: - OnboardingConfiguration

/// 应用外观偏好. system 跟随系统; 持久化为 rawValue 字符串.
public enum AppearancePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case light
    case dark

    /// 面板底栏外观按钮的循环顺序, 与设置中心分段选择器一致:
    /// 跟随系统 -> 浅色 -> 深色 -> 跟随系统. 以 `allCases` (声明顺序)
    /// 为准, 保证循环顺序与选项集合永不脱节.
    public var next: AppearancePreference {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return all[0] }
        return all[(index + 1) % all.count]
    }
}

/// 模糊风格偏好 (仅液态玻璃模式下展示). regular 标准, clear 通透,
/// material 哑光/材质; 持久化为 rawValue 字符串.
public enum GlassStylePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case regular
    case clear
    case material
}

/// 全局界面动效偏好 (C145). system 跟随系统「减弱动态效果」; always 始终播放
/// (忽略系统设置, 供本机开启减弱动态效果但希望看到应用内动效的用户显式 opt-in);
/// never 始终不播放. 持久化为 rawValue 字符串.
public enum MotionPreference: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case always
    case never

    /// 唯一裁决点: 是否抑制动效. 只此一处组合应用偏好与系统值,
    /// 调用方不得自行展开判定, 否则双端语义会漂移.
    public func suppressesMotion(systemReduceMotion: Bool) -> Bool {
        switch self {
        case .system: return systemReduceMotion
        case .always: return false
        case .never: return true
        }
    }
}

/// 非敏感配置. 持久化到 Application Support/Bruce/config/onboarding-v1.json.
public struct OnboardingConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var selectedModules: Set<String>
    public var consentVersion: Int?
    /// 菜单栏指标 rawValue 有序列表. nil 使用应用默认值.
    public var menuBarMetrics: [String]?
    /// 菜单栏是否仅显示图标 (隐藏文字指标). nil/false 表示显示指标.
    public var menuBarIconOnly: Bool?
    /// 订阅 provider 配置, 键为 SubscriptionProviderID rawValue.
    /// v1 配置文件无此键, 加载时按缺省 (全部未配置) 处理.
    public var subscriptionProviders: [String: SubscriptionProviderConfiguration]
    /// 模型单价人工校准覆盖, 键为模型标识 (如 "k3-agent", "deepseek-v4-flash").
    public var pricingOverrides: [String: ModelPricingOverride]?
    /// 自动刷新间隔 (分钟). nil (含 JSON 显式 null) 表示使用默认 30 分钟.
    /// 合法区间见 `refreshIntervalRange`; 3 / 6 为设置页预设, 其余值经「自定义」输入 (C160).
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
    /// 电脑锁屏后是否禁止订阅额度刷新 (C064). 默认开启保护以节省云端 API 配额.
    public var pauseSubscriptionRefreshOnScreenLock: Bool
    /// 全局界面动效偏好 (C145). nil 表示跟随系统.
    public var motionPreference: MotionPreference?

    /// 默认自动刷新间隔 (分钟).
    public static let defaultRefreshIntervalMinutes = 30
    /// 设置页分段选择器预置的刷新间隔 (分钟); 其余合法值经「自定义」输入 (C160).
    public static let presetRefreshIntervalMinutes: [Int] = [3, 6]
    /// 自定义刷新间隔的合法区间 (分钟), 与 Windows `refresh_interval_secs` 的 60–86400 秒钳制一致 (C160).
    public static let refreshIntervalRange: ClosedRange<Int> = 1...1440

    /// 解析后的刷新间隔: nil 或超出合法区间的值一律回落默认 30 分钟.
    public var resolvedRefreshIntervalMinutes: Int {
        guard let value = refreshIntervalMinutes,
              Self.refreshIntervalRange.contains(value) else {
            return Self.defaultRefreshIntervalMinutes
        }
        return value
    }

    /// 解析后的外观偏好: nil 一律回落跟随系统.
    public var resolvedAppearanceMode: AppearancePreference {
        appearanceMode ?? .system
    }

    /// 解析后的全局动效偏好: nil (含 JSON 显式 null 或非法值) 一律回落跟随系统.
    public var resolvedMotionPreference: MotionPreference {
        motionPreference ?? .system
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
        menuBarIconOnly: Bool? = nil,
        subscriptionProviders: [String: SubscriptionProviderConfiguration] = [:],
        pricingOverrides: [String: ModelPricingOverride]? = nil,
        refreshIntervalMinutes: Int? = nil,
        appearanceMode: AppearancePreference? = nil,
        interfaceStyle: InterfaceStylePreference? = nil,
        glassStyle: GlassStylePreference? = nil,
        subscriptionProviderOrder: [String]? = nil,
        dashboardHotkey: GlobalHotkey? = nil,
        keychainAccessConfigured: Bool = false,
        keychainAccess: KeychainAccessConfiguration? = nil,
        systemNotificationsEnabled: Bool = true,
        pauseSubscriptionRefreshOnScreenLock: Bool = true,
        motionPreference: MotionPreference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.selectedModules = selectedModules
        self.consentVersion = consentVersion
        self.menuBarMetrics = menuBarMetrics
        self.menuBarIconOnly = menuBarIconOnly
        self.subscriptionProviders = subscriptionProviders
        self.pricingOverrides = pricingOverrides
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
        self.pauseSubscriptionRefreshOnScreenLock = pauseSubscriptionRefreshOnScreenLock
        self.motionPreference = motionPreference
    }

    /// 自定义解码: 旧版本配置缺失的键一律回落缺省, 不因新增字段拒绝加载.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        selectedModules = try container.decodeIfPresent(Set<String>.self, forKey: .selectedModules) ?? []
        consentVersion = try container.decodeIfPresent(Int.self, forKey: .consentVersion)
        menuBarMetrics = try container.decodeIfPresent([String].self, forKey: .menuBarMetrics)
        menuBarIconOnly = try container.decodeIfPresent(Bool.self, forKey: .menuBarIconOnly)
        subscriptionProviders = try container.decodeIfPresent(
            [String: SubscriptionProviderConfiguration].self,
            forKey: .subscriptionProviders
        ) ?? [:]
        pricingOverrides = try container.decodeIfPresent(
            [String: ModelPricingOverride].self,
            forKey: .pricingOverrides
        )
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
        // 电脑锁屏暂停订阅刷新: 旧配置缺该键时默认开启保护.
        pauseSubscriptionRefreshOnScreenLock = try container.decodeIfPresent(
            Bool.self, forKey: .pauseSubscriptionRefreshOnScreenLock
        ) ?? true
        // 全局动效偏好: 旧配置缺该键 (或值非法) 一律回落跟随系统 (C145).
        motionPreference = (try? container.decodeIfPresent(
            MotionPreference.self, forKey: .motionPreference
        )) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case selectedModules
        case consentVersion
        case menuBarMetrics
        case menuBarIconOnly
        case subscriptionProviders
        case pricingOverrides
        case refreshIntervalMinutes
        case appearanceMode
        case interfaceStyle
        case glassStyle
        case subscriptionProviderOrder
        case dashboardHotkey
        case keychainAccess
        case keychainAccessConfigured
        case systemNotificationsEnabled
        case pauseSubscriptionRefreshOnScreenLock
        case motionPreference
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(selectedModules, forKey: .selectedModules)
        try container.encodeIfPresent(consentVersion, forKey: .consentVersion)
        try container.encodeIfPresent(menuBarMetrics, forKey: .menuBarMetrics)
        try container.encodeIfPresent(menuBarIconOnly, forKey: .menuBarIconOnly)
        try container.encode(subscriptionProviders, forKey: .subscriptionProviders)
        try container.encodeIfPresent(pricingOverrides, forKey: .pricingOverrides)
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
        try container.encode(
            pauseSubscriptionRefreshOnScreenLock,
            forKey: .pauseSubscriptionRefreshOnScreenLock
        )
        try container.encodeIfPresent(motionPreference, forKey: .motionPreference)
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
    /// StepFun (Step Plan) 控制台 Oasis-Token 字符串
    public static let stepfunToken = "stepfun:token"
    /// TypeSafe Jev API key 字符串
    public static let jevAPIKey = "jev:api-key"
    /// Cline / ClinePass API key 字符串 (app.cline.bot Settings > API Keys 创建)
    public static let clineAPIKey = "cline:api-key"
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

// MARK: - ProtectedFileCredentialStore

/// 文件凭据存储的错误面.
///
/// `corrupted` 是关键语义: 文件存在但无法读取/解码时, 读与写都必须失败并保留现场,
/// 严禁把损坏折叠为空 payload —— 空 payload 被写回会抹除其余全部凭据 (C042).
public enum ProtectedFileCredentialStoreError: Error, Equatable {
    /// 文件存在但无法读取或解码. `backupPath` 为损坏现场副本 (尽力而为, 可能为 nil).
    case corrupted(backupPath: String?)
    /// 写入流程失败 (临时文件/属性设置/替换), 失败原因摘要.
    case writeFailed(String)
}

/// 本地受权限保护的文件凭据存储 (0600 POSIX 权限: -rw-------).
/// 专为本地优先设计, 避免 macOS Keychain 因 Ad-hoc 签名哈希变动而频繁弹出密码授权框.
/// 同时为后续 Windows (%LOCALAPPDATA%\Bruce\credentials.json) 和 Linux 跨平台提供统一的基础存储模型.
///
/// 写盘规格与 `AtomicJSONStore` 对齐: 创建即 0600 -> 写 -> fsync -> 重读校验 -> 备份 -> 原子替换 -> 复位 0600;
/// 任一步失败即抛错, 不做静默降级 (C042).
public final class ProtectedFileCredentialStore: IntentAwareCredentialStore, @unchecked Sendable {
    public static let defaultDirectoryName = "Bruce"
    public static let defaultFileName = "credentials.json"

    private struct Payload: Codable {
        var version: Int = 1
        var credentials: [String: String] = [:]
    }

    public let fileURL: URL
    private let accessController: KeychainAccessController
    private let fallbackKeychainStore: KeychainCredentialStore?
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(
        fileURL: URL? = nil,
        accessController: KeychainAccessController = KeychainAccessController(),
        fallbackKeychainStore: KeychainCredentialStore? = nil,
        fileManager: FileManager = .default
    ) {
        self.accessController = accessController
        self.fallbackKeychainStore = fallbackKeychainStore
        self.fileManager = fileManager

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = appSupport
                .appendingPathComponent(Self.defaultDirectoryName, isDirectory: true)
                .appendingPathComponent(Self.defaultFileName, isDirectory: false)
        }
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
        lock.lock()
        defer { lock.unlock() }

        var payload = try loadPayloadLocked()
        payload.credentials[account] = value
        try writePayloadLocked(payload)
    }

    public func loadCredential(forAccount account: String) throws -> String? {
        try loadCredential(forAccount: account, intent: .automatic)
    }

    public func loadCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws -> String? {
        try requireAccess(intent)
        lock.lock()
        defer { lock.unlock() }

        var payload = try loadPayloadLocked()
        if let existing = payload.credentials[account] {
            return existing
        }

        // 本地文件未命中时, 尝试从既有 Keychain fallback 读取并自动迁移至文件
        if let fallbackKeychainStore,
           let result = try? fallbackKeychainStore.loadCredential(forAccount: account, intent: intent),
           !result.isEmpty {
            payload.credentials[account] = result
            // 迁移写盘失败不得吞错: 错误上抛以便调用方感知持久化未生效
            try writePayloadLocked(payload)
            return result
        }
        return nil
    }

    public func deleteCredential(forAccount account: String) throws {
        try deleteCredential(forAccount: account, intent: .automatic)
    }

    public func deleteCredential(
        forAccount account: String,
        intent: KeychainAccessIntent
    ) throws {
        try requireAccess(intent)
        lock.lock()
        defer { lock.unlock() }

        var payload = try loadPayloadLocked()
        if payload.credentials.removeValue(forKey: account) != nil {
            try writePayloadLocked(payload)
        }

        if let fallbackKeychainStore {
            try? fallbackKeychainStore.deleteCredential(forAccount: account, intent: intent)
        }
    }

    public func configureKeychainAccess() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try loadPayloadLocked().credentials.count
    }

    // MARK: - 内部私有方法

    private func requireAccess(_ intent: KeychainAccessIntent) throws {
        guard accessController.allows(source: .bruceStore, intent: intent) else {
            if accessController.policy.state == .blocked {
                throw KeychainError.accessBlocked(
                    .bruceStore,
                    errSecInteractionNotAllowed
                )
            }
            throw KeychainError.notConfigured(.bruceStore)
        }
    }

    private static let posixPermissionsKey = FileAttributeKey.posixPermissions

    /// 读取 payload.
    ///
    /// 三态语义: 文件不存在 -> 空 payload (正常首次使用);
    /// 文件存在但读/解码失败 -> 保留损坏现场副本后抛 `.corrupted`, **不得**转空.
    private func loadPayloadLocked() throws -> Payload {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return Payload()
        }
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            let backup = preserveCorruptedFile()
            throw ProtectedFileCredentialStoreError.corrupted(backupPath: backup?.path)
        }
        return payload
    }

    /// 损坏现场副本 (尽力而为): 保留原始字节便于人工恢复, 不阻断错误上抛.
    private func preserveCorruptedFile() -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).corrupt-\(stamp)")
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.moveItem(at: fileURL, to: backupURL)
            return backupURL
        } catch {
            return nil
        }
    }

    /// 原子写盘: 创建即 0600 -> 写 -> fsync -> 重读校验 -> 备份 -> 替换 -> 复位 0600.
    private func writePayloadLocked(_ payload: Payload) throws {
        let parentDirectory = fileURL.deletingLastPathComponent()
        // 目录存在也校正权限 (原实现仅在不存在时创建, 已存在则放任漂移)
        if !fileManager.fileExists(atPath: parentDirectory.path) {
            try fileManager.createDirectory(
                at: parentDirectory,
                withIntermediateDirectories: true,
                attributes: [Self.posixPermissionsKey: 0o700]
            )
        } else {
            try? fileManager.setAttributes([Self.posixPermissionsKey: 0o700], ofItemAtPath: parentDirectory.path)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        let tempURL = parentDirectory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            // createFile 即带 0600, 不留 umask 窗口
            guard fileManager.createFile(
                atPath: tempURL.path,
                contents: nil,
                attributes: [Self.posixPermissionsKey: 0o600]
            ) else {
                throw ProtectedFileCredentialStoreError.writeFailed("无法创建临时文件")
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            // 重读校验: 确认落盘内容可解码, 防止半写文件成为新的「损坏」
            let reread = try Data(contentsOf: tempURL)
            _ = try JSONDecoder().decode(Payload.self, from: reread)
            // 覆盖前备份既有文件, 失败即回滚
            if fileManager.fileExists(atPath: fileURL.path) {
                let backupURL = parentDirectory.appendingPathComponent("\(fileURL.lastPathComponent).bak")
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: fileURL, to: backupURL)
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: fileURL)
            }
            // 权限设置失败必须上抛 (原实现 try? 吞掉)
            try fileManager.setAttributes([Self.posixPermissionsKey: 0o600], ofItemAtPath: fileURL.path)
        } catch let error as ProtectedFileCredentialStoreError {
            try? fileManager.removeItem(at: tempURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw ProtectedFileCredentialStoreError.writeFailed(String(describing: error))
        }
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
