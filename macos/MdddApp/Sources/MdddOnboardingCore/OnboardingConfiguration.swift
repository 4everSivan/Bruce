import Foundation

// MARK: - OnboardingConfiguration

/// 非敏感配置. 持久化到 Application Support/mddd/config/onboarding-v1.json.
public struct OnboardingConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var pythonPath: String?
    public var gitlabBaseURL: String?
    public var selectedModules: Set<String>
    public var consentVersion: Int?
    public var connectionStates: [String: String]
    public var lastVerifiedAt: [String: String]
    /// 外观主题 ("classic" / "liquid-glass"). nil 按 classic 处理, 旧配置文件无此键.
    public var theme: String?

    public init(
        schemaVersion: Int = OnboardingConfiguration.currentSchemaVersion,
        pythonPath: String? = nil,
        gitlabBaseURL: String? = nil,
        selectedModules: Set<String> = [],
        consentVersion: Int? = nil,
        connectionStates: [String: String] = [:],
        lastVerifiedAt: [String: String] = [:],
        theme: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pythonPath = pythonPath
        self.gitlabBaseURL = gitlabBaseURL
        self.selectedModules = selectedModules
        self.consentVersion = consentVersion
        self.connectionStates = connectionStates
        self.lastVerifiedAt = lastVerifiedAt
        self.theme = theme
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

// MARK: - CredentialStore

/// 凭证存储协议. 系统实现使用 macOS Keychain, 测试使用内存 fake.
public protocol CredentialStore: Sendable {
    func savePAT(_ pat: String, forHost host: String) throws
    func loadPAT(forHost host: String) throws -> String?
    func deletePAT(forHost host: String) throws
}

// MARK: - InMemoryCredentialStore

/// 内存 fake, 用于测试.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func savePAT(_ pat: String, forHost host: String) throws {
        lock.lock()
        storage[host] = pat
        lock.unlock()
    }

    public func loadPAT(forHost host: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[host]
    }

    public func deletePAT(forHost host: String) throws {
        lock.lock()
        storage[host] = nil
        lock.unlock()
    }
}

// MARK: - KeychainCredentialStore

/// macOS Keychain 实现. PAT 按 gitlab:<normalized-host> 区分.
/// 保存为 update 优先的原子语义: 不先删后加, 添加失败不会丢失原凭证.
public final class KeychainCredentialStore: CredentialStore, @unchecked Sendable {
    public static let defaultService = "com.mddd.dashboard.credentials"

    private let service: String

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func savePAT(_ pat: String, forHost host: String) throws {
        let account = Self.account(forHost: host)
        let data = Data(pat.utf8)

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

    public func loadPAT(forHost host: String) throws -> String? {
        let account = Self.account(forHost: host)
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

    public func deletePAT(forHost host: String) throws {
        let account = Self.account(forHost: host)
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

    public static func account(forHost host: String) -> String {
        "gitlab:\(host)"
    }
}

// MARK: - KeychainError

public enum KeychainError: Error, Equatable {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
}
