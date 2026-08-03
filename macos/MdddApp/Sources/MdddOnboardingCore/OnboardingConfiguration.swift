import Foundation

// MARK: - SubscriptionProviderID

/// 订阅额度 provider 标识. 持久化为配置字典键和 Keychain account 前缀.
public enum SubscriptionProviderID: String, Codable, Sendable, CaseIterable {
    case kimi
    case deepseek
    case volcengine
    case codex
    case antigravity
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
}

// MARK: - OnboardingConfiguration

/// 应用外观偏好. system 跟随系统; 持久化为 rawValue 字符串.
public enum AppearancePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case system
    case light
    case dark
}

/// 液态玻璃风格偏好. regular 系统标准玻璃, clear 更通透,
/// material 退化为材质质感; 持久化为 rawValue 字符串.
public enum GlassStylePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case regular
    case clear
    case material
}

/// 非敏感配置. 持久化到 Application Support/mddd/config/onboarding-v1.json.
public struct OnboardingConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public var pythonPath: String?
    public var selectedModules: Set<String>
    public var consentVersion: Int?
    public var connectionStates: [String: String]
    public var lastVerifiedAt: [String: String]
    /// 菜单栏指标 rawValue 有序列表. nil 使用应用默认值.
    public var menuBarMetrics: [String]?
    /// 订阅 provider 配置, 键为 SubscriptionProviderID rawValue.
    /// v1 配置文件无此键, 加载时按缺省 (全部未配置) 处理.
    public var subscriptionProviders: [String: SubscriptionProviderConfiguration]
    /// 自动刷新间隔 (分钟). nil (含 JSON 显式 null) 表示使用默认 30 分钟.
    public var refreshIntervalMinutes: Int?
    /// 外观偏好. nil (含 JSON 显式 null 或非法值) 表示跟随系统.
    public var appearanceMode: AppearancePreference?
    /// 液态玻璃风格偏好. nil (含 JSON 显式 null 或非法值) 表示标准玻璃.
    public var glassStyle: GlassStylePreference?

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

    /// 解析后的玻璃风格: nil 一律回落标准玻璃.
    public var resolvedGlassStyle: GlassStylePreference {
        glassStyle ?? .regular
    }

    public init(
        schemaVersion: Int = OnboardingConfiguration.currentSchemaVersion,
        pythonPath: String? = nil,
        selectedModules: Set<String> = [],
        consentVersion: Int? = nil,
        connectionStates: [String: String] = [:],
        lastVerifiedAt: [String: String] = [:],
        menuBarMetrics: [String]? = nil,
        subscriptionProviders: [String: SubscriptionProviderConfiguration] = [:],
        refreshIntervalMinutes: Int? = nil,
        appearanceMode: AppearancePreference? = nil,
        glassStyle: GlassStylePreference? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pythonPath = pythonPath
        self.selectedModules = selectedModules
        self.consentVersion = consentVersion
        self.connectionStates = connectionStates
        self.lastVerifiedAt = lastVerifiedAt
        self.menuBarMetrics = menuBarMetrics
        self.subscriptionProviders = subscriptionProviders
        self.refreshIntervalMinutes = refreshIntervalMinutes
        self.appearanceMode = appearanceMode
        self.glassStyle = glassStyle
    }

    /// 自定义解码: 旧版本配置缺失的键一律回落缺省, 不因新增字段拒绝加载.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        pythonPath = try container.decodeIfPresent(String.self, forKey: .pythonPath)
        selectedModules = try container.decodeIfPresent(Set<String>.self, forKey: .selectedModules) ?? []
        consentVersion = try container.decodeIfPresent(Int.self, forKey: .consentVersion)
        connectionStates = try container.decodeIfPresent([String: String].self, forKey: .connectionStates) ?? [:]
        lastVerifiedAt = try container.decodeIfPresent([String: String].self, forKey: .lastVerifiedAt) ?? [:]
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
        // 非法字符串与缺键一样按 nil (标准玻璃) 处理
        glassStyle = try? container.decodeIfPresent(
            GlassStylePreference.self, forKey: .glassStyle
        )
    }
}

// MARK: - OnboardingConfigurationStore

/// 非敏感配置的原子读写. 文件权限 0600.
public final class OnboardingConfigurationStore: @unchecked Sendable {
    private let configURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "mddd.onboarding-config")

    public init(configDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.configURL = configDirectory
            .appendingPathComponent("onboarding-v1.json")
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
            .appendingPathComponent("mddd", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
        try self.init(configDirectory: configDir)
    }

    /// 读取配置. 文件不存在返回空配置. schema 版本不匹配返回 nil.
    public func load() -> OnboardingConfiguration? {
        queue.sync {
            guard fileManager.fileExists(atPath: configURL.path) else {
                return OnboardingConfiguration()
            }
            do {
                let data = try Data(contentsOf: configURL)
                let config = try JSONDecoder().decode(
                    OnboardingConfiguration.self, from: data
                )
                // 未知新 schema -> 安全拒绝
                guard config.schemaVersion <= OnboardingConfiguration.currentSchemaVersion else {
                    return nil
                }
                return config
            } catch {
                return nil
            }
        }
    }

    /// 原子写入配置: 临时文件 -> 同步 -> 重读校验 -> 原子替换.
    public func save(_ config: OnboardingConfiguration) throws {
        try queue.sync {
            let data = try JSONEncoder().encode(config)
            let tempURL = configURL
                .deletingLastPathComponent()
                .appendingPathComponent(".onboarding-v1.\(UUID().uuidString).tmp")

            do {
                guard fileManager.createFile(
                    atPath: tempURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw OnboardingConfigError.storageFailure
                }
                let handle = try FileHandle(forWritingTo: tempURL)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: tempURL.path
                )

                // 重读校验
                let reread = try Data(contentsOf: tempURL)
                let verified = try JSONDecoder().decode(
                    OnboardingConfiguration.self, from: reread
                )
                guard verified == config else {
                    throw OnboardingConfigError.storageFailure
                }

                // 原子替换
                if fileManager.fileExists(atPath: configURL.path) {
                    _ = try fileManager.replaceItemAt(configURL, withItemAt: tempURL)
                } else {
                    try fileManager.moveItem(at: tempURL, to: configURL)
                }
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: configURL.path
                )
            } catch let error as OnboardingConfigError {
                try? fileManager.removeItem(at: tempURL)
                throw error
            } catch {
                try? fileManager.removeItem(at: tempURL)
                throw OnboardingConfigError.storageFailure
            }
        }
    }

    private func ensureDirectory(at url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path
        )
    }
}

// MARK: - OnboardingConfigError

public enum OnboardingConfigError: Error, Equatable {
    case storageFailure
    case unknownSchema
}

// MARK: - SubscriptionCredentialAccount

/// 订阅 provider 的 Keychain account 键. service 统一为
/// com.mddd.dashboard.credentials.
public enum SubscriptionCredentialAccount {
    /// JSON {"access_token": ..., "refresh_token": ...}
    public static let kimiWebTokens = "kimi:web-tokens"
    /// DeepSeek API key 字符串
    public static let deepseekAPIKey = "deepseek:api-key"
    /// 火山引擎 AccessKey 字符串
    public static let volcengineAccessKey = "volcengine:ak"
    /// 火山引擎 SecretKey 字符串
    public static let volcengineSecretKey = "volcengine:sk"
    /// CC Switch 同构 JSON {"accounts": {id: {email, refresh_token, access_token, id_token}}}
    public static let codexAccounts = "codex:accounts"
    /// Codex 当前账号 id 字符串
    public static let codexActiveAccount = "codex:active-account"
    /// Antigravity 令牌文件同构 JSON
    public static let antigravityOAuth = "antigravity:oauth"
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

/// macOS Keychain 实现.
/// 保存为 update 优先的原子语义: 不先删后加, 添加失败不会丢失原凭证.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let defaultService = "com.mddd.dashboard.credentials"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func saveCredential(_ value: String, forAccount account: String) throws {
        let data = Data(value.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data
        ]

        // 优先 SecItemUpdate: 已存在则就地更新, 不经过删除窗口
        var status = SecItemUpdate(
            baseQuery as CFDictionary, updateAttributes as CFDictionary
        )
        if status == errSecItemNotFound {
            // 不存在才添加; 并发下撞见重复项则回退 update
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(addQuery as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    baseQuery as CFDictionary, updateAttributes as CFDictionary
                )
            }
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func loadCredential(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.loadFailed(status)
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func deleteCredential(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

// MARK: - KeychainError

public enum KeychainError: Error, Equatable {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}
