import Foundation

// MARK: - KeychainExternalSource

/// Bruce 可显式允许读取的外部 CLI Keychain 来源.
/// Bruce 自有 Keychain 不放入该集合, 由 `bruceStoreConfigured` 单独控制.
public enum KeychainExternalSource: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case claudeCLI
    case grokCLI
}

// MARK: - KeychainAccessSource

/// 一次 Keychain 操作的来源边界.
public enum KeychainAccessSource: Equatable, Sendable {
    case bruceStore
    case external(KeychainExternalSource)
}

// MARK: - KeychainAccessState

/// 运行时 Keychain 访问状态.
public enum KeychainAccessState: Equatable, Sendable {
    case notConfigured
    case allowed
    case blocked
}

// MARK: - KeychainAccessIntent

/// Keychain 操作的交互意图.
public enum KeychainAccessIntent: Equatable, Sendable {
    /// 启动、自动刷新和后台写回. 不允许触发系统认证 UI.
    case automatic
    /// 用户明确点击配置、登录或重新授权. 可以进入系统认证流程.
    case userInitiated
}

// MARK: - KeychainAccessConfiguration

/// 配置文件中的非敏感 Keychain 授权状态.
/// 不保存系统密码、Token 或任何凭证内容.
public struct KeychainAccessConfiguration: Codable, Equatable, Sendable {
    public var bruceStoreConfigured: Bool
    public var externalSources: Set<KeychainExternalSource>

    public init(
        bruceStoreConfigured: Bool = false,
        externalSources: Set<KeychainExternalSource> = []
    ) {
        self.bruceStoreConfigured = bruceStoreConfigured
        self.externalSources = externalSources
    }

    private enum CodingKeys: String, CodingKey {
        case bruceStoreConfigured
        case externalSources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bruceStoreConfigured = try container.decodeIfPresent(
            Bool.self, forKey: .bruceStoreConfigured
        ) ?? false
        // 未知的外部来源只忽略, 不扩大访问范围.
        externalSources = try container.decodeIfPresent(
            Set<KeychainExternalSource>.self, forKey: .externalSources
        ) ?? []
    }
}

// MARK: - KeychainAccessPolicy

/// 纯逻辑访问策略. 不执行 I/O, 不持有凭证值.
public struct KeychainAccessPolicy: Equatable, Sendable {
    public let configuration: KeychainAccessConfiguration
    public let state: KeychainAccessState

    public init(
        configuration: KeychainAccessConfiguration,
        state: KeychainAccessState? = nil
    ) {
        self.configuration = configuration
        if let state {
            self.state = state
        } else {
            self.state = configuration.bruceStoreConfigured ? .allowed : .notConfigured
        }
    }

    public static let notConfigured = KeychainAccessPolicy(
        configuration: KeychainAccessConfiguration(),
        state: .notConfigured
    )

    /// 判断一次操作是否允许触碰对应 Keychain 来源.
    public func allows(
        source: KeychainAccessSource,
        intent: KeychainAccessIntent
    ) -> Bool {
        switch source {
        case .bruceStore:
            // 用户主动配置 Bruce ACL 时允许进入配置流程, 即使此前未配置或已 blocked.
            if intent == .userInitiated {
                return true
            }
            return state == .allowed && configuration.bruceStoreConfigured
        case .external(let externalSource):
            // 外部来源必须同时满足显式白名单和已允许状态.
            guard state == .allowed else { return false }
            return configuration.externalSources.contains(externalSource)
        }
    }

    public func withState(_ state: KeychainAccessState) -> KeychainAccessPolicy {
        KeychainAccessPolicy(configuration: configuration, state: state)
    }
}

// MARK: - KeychainAccessController

/// App 进程共享的策略容器. 允许 OnboardingCoordinator 更新策略,
/// 让同步 CredentialStore 和异步 Scheduler 读取同一份状态.
public final class KeychainAccessController: @unchecked Sendable {
    private let lock = NSLock()
    private var currentPolicy: KeychainAccessPolicy

    public init(policy: KeychainAccessPolicy = .notConfigured) {
        currentPolicy = policy
    }

    public var policy: KeychainAccessPolicy {
        lock.lock()
        defer { lock.unlock() }
        return currentPolicy
    }

    public func update(policy: KeychainAccessPolicy) {
        lock.lock()
        currentPolicy = policy
        lock.unlock()
    }

    public func markBlocked() {
        lock.lock()
        currentPolicy = currentPolicy.withState(.blocked)
        lock.unlock()
    }

    public func clearBlocked() {
        lock.lock()
        let state: KeychainAccessState = currentPolicy.configuration.bruceStoreConfigured
            ? .allowed : .notConfigured
        currentPolicy = currentPolicy.withState(state)
        lock.unlock()
    }

    public func allows(
        source: KeychainAccessSource,
        intent: KeychainAccessIntent
    ) -> Bool {
        policy.allows(source: source, intent: intent)
    }
}
