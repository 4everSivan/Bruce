import Foundation

// MARK: - LocalDependencyStatus

/// 本机依赖扫描结果. 不含凭证内容.
public enum LocalDependencyStatus: String, Equatable, Sendable {
    case available
    case missing
    case incompatible
    case locked
    case timedOut
    case corrupted
}

// MARK: - CollectorRuntimeStatus

/// Rust Collector 执行文件的本机状态.
public enum CollectorRuntimeStatus: String, Equatable, Sendable {
    case rustAvailable
    case rustUnavailable
}

// MARK: - ConnectionStatus

/// 外部服务连接状态.
public enum ConnectionStatus: String, Equatable, Sendable {
    case notRequired
    case notChecked
    case pendingAuthorization
    case verifying
    case connected
    case expired
    case unreachable
    case unsupported
}

// MARK: - ModuleReadiness

/// 模块就绪度. 综合本机依赖, 连接状态和授权版本.
public enum ModuleReadiness: String, Equatable, Sendable {
    case ready
    case partial
    case missingDependency
    case pendingAuthorization
    case authorizationExpired
    case networkUnreachable
    case unsupported
}

// MARK: - SetupAction

/// 结构化设置动作, 替代纯指导字符串.
public enum SetupAction: String, Equatable, Sendable {
    case retryLocalScan
    case retryConnection
    case reviewAuthorization
}

// MARK: - ScanIssue

/// 扫描或验证过程中产生的非敏感诊断.
public struct ScanIssue: Equatable, Sendable {
    public enum Category: String, Equatable, Sendable {
        case dependency
        case auth
        case network
        case schema
        case storage
        case timeout
        case cancelled
    }

    public let code: String
    public let stage: String
    public let category: Category
    public let retryable: Bool
    public let suggestedAction: SetupAction?

    public init(
        code: String,
        stage: String,
        category: Category,
        retryable: Bool = false,
        suggestedAction: SetupAction? = nil
    ) {
        self.code = code
        self.stage = stage
        self.category = category
        self.retryable = retryable
        self.suggestedAction = suggestedAction
    }
}

// MARK: - ModuleReadinessResult

/// 单模块的就绪评估结果.
public struct ModuleReadinessResult: Equatable, Sendable {
    public let module: CollectorModule
    public let readiness: ModuleReadiness
    public let localDependencies: [DependencyProbe]
    public let connection: ConnectionStatus
    public let blockingReason: String?
    public let warnings: [String]
    public let issues: [ScanIssue]
    public let actions: [SetupAction]

    public init(
        module: CollectorModule,
        readiness: ModuleReadiness,
        localDependencies: [DependencyProbe],
        connection: ConnectionStatus,
        blockingReason: String? = nil,
        warnings: [String] = [],
        issues: [ScanIssue] = [],
        actions: [SetupAction] = []
    ) {
        self.module = module
        self.readiness = readiness
        self.localDependencies = localDependencies
        self.connection = connection
        self.blockingReason = blockingReason
        self.warnings = warnings
        self.issues = issues
        self.actions = actions
    }
}

// MARK: - DependencyProbe

/// 单项依赖或数据源的只读扫描结果.
public struct DependencyProbe: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case sessionDirectory
        case sqliteDatabase
    }

    public let kind: Kind
    public let status: LocalDependencyStatus
    /// 非敏感的版本或摘要, 不含凭证.
    public let detail: String?

    public init(kind: Kind, status: LocalDependencyStatus, detail: String? = nil) {
        self.kind = kind
        self.status = status
        self.detail = detail
    }
}

// MARK: - CollectorCapability

/// Collector 能力白名单. Bridge 根据已授权能力决定是否执行特定操作.
public enum CollectorCapability: String, Codable, Sendable {
    case localSessions
    case localPricing
    case externalQuotas
}

/// 每次运行授予 Collector 的执行策略.
public struct CollectorExecutionPolicy: Equatable, Sendable {
    public let module: CollectorModule
    public let capabilities: Set<CollectorCapability>

    public init(module: CollectorModule, capabilities: Set<CollectorCapability>) {
        self.module = module
        self.capabilities = capabilities
    }
}
