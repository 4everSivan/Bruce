import Foundation

// MARK: - ReadinessEvaluator

/// 根据本机扫描和连接状态计算模块就绪度.
/// 纯规则, 无副作用, 可测试.
public struct ReadinessEvaluator: Sendable {
    public init() {}

    /// 评估 Agent 用量模块.
    /// 必要条件: Python 3.9+ 且至少一个会话源可读.
    /// CC Switch 和 Antigravity 是可选增强, 单独存在不能让模块 ready.
    public func evaluateAgentUsage(
        pythonStatus: LocalDependencyStatus,
        pythonVersion: String?,
        sessionSources: [DependencyProbe],
        ccSwitchStatus: SQLiteSchemaProbeResult,
        antigravityStatus: SQLiteSchemaProbeResult
    ) -> ModuleReadinessResult {
        var probes: [DependencyProbe] = []
        probes.append(DependencyProbe(
            kind: .python, status: pythonStatus, detail: pythonVersion
        ))
        probes.append(contentsOf: sessionSources)

        var issues: [ScanIssue] = []
        var warnings: [String] = []
        var actions: [SetupAction] = []

        // Python 不合格直接阻塞
        if pythonStatus != .available {
            issues.append(ScanIssue(
                code: "PYTHON_UNAVAILABLE",
                stage: "scan",
                category: .dependency,
                retryable: false,
                suggestedAction: pythonStatus == .missing ? .installPython : .choosePython
            ))
            actions.append(.choosePython)
            if pythonStatus == .missing { actions.append(.installPython) }
            return ModuleReadinessResult(
                module: .agentUsage,
                readiness: .missingDependency,
                localDependencies: probes,
                connection: .notRequired,
                blockingReason: "需要 Python 3.9 或更高版本",
                issues: issues,
                actions: actions
            )
        }

        // 检查会话源 (排除 SQLite 数据库)
        let sessionProbes = sessionSources.filter { $0.kind == .sessionDirectory }
        let availableSessions = sessionProbes.filter { $0.status == .available }

        if availableSessions.isEmpty {
            for probe in sessionProbes where probe.status != .available {
                warnings.append("\(probe.detail ?? "会话源") 不可用")
            }
            issues.append(ScanIssue(
                code: "NO_SESSION_SOURCE",
                stage: "scan",
                category: .dependency,
                retryable: false,
                suggestedAction: .retryLocalScan
            ))
            actions.append(.retryLocalScan)
            return ModuleReadinessResult(
                module: .agentUsage,
                readiness: .missingDependency,
                localDependencies: probes,
                connection: .notRequired,
                blockingReason: "没有可用的本机会话源",
                warnings: warnings,
                issues: issues,
                actions: actions
            )
        }

        // 添加 SQLite 探测结果
        let ccSwitchProbe = DependencyProbe(
            kind: .sqliteDatabase,
            status: mapSQLiteStatus(ccSwitchStatus),
            detail: SQLiteSchemaProfile.ccSwitch.displayName
        )
        let agyProbe = DependencyProbe(
            kind: .sqliteDatabase,
            status: mapSQLiteStatus(antigravityStatus),
            detail: SQLiteSchemaProfile.antigravity.displayName
        )
        probes.append(ccSwitchProbe)
        probes.append(agyProbe)

        // 有部分会话源不可用 -> partial
        let hasUnavailableSessions = sessionProbes.contains { $0.status != .available }
        if hasUnavailableSessions {
            for probe in sessionProbes where probe.status != .available {
                warnings.append("\(probe.detail ?? "会话源") 暂不可用")
            }
            actions.append(.retryLocalScan)
        }

        // SQLite 状态作为 warning, 不阻塞
        if ccSwitchStatus != .available && ccSwitchStatus != .missing {
            warnings.append("CC Switch 数据库: \(ccSwitchStatus.rawValue)")
        }
        if antigravityStatus != .available && antigravityStatus != .missing {
            warnings.append("Antigravity 数据库: \(antigravityStatus.rawValue)")
        }

        let readiness: ModuleReadiness = hasUnavailableSessions ? .partial : .ready
        return ModuleReadinessResult(
            module: .agentUsage,
            readiness: readiness,
            localDependencies: probes,
            connection: .notRequired,
            warnings: warnings,
            issues: issues,
            actions: actions
        )
    }

    /// 评估 GitHub 模块.
    /// 必要条件: Python 3.9+, gh CLI 可用, gh 已登录.
    public func evaluateGitHub(
        pythonStatus: LocalDependencyStatus,
        pythonVersion: String?,
        ghCliStatus: LocalDependencyStatus,
        ghVersion: String?,
        ghLoggedIn: Bool
    ) -> ModuleReadinessResult {
        var probes: [DependencyProbe] = []
        probes.append(DependencyProbe(
            kind: .python, status: pythonStatus, detail: pythonVersion
        ))
        probes.append(DependencyProbe(
            kind: .ghCli, status: ghCliStatus, detail: ghVersion
        ))

        var issues: [ScanIssue] = []
        var actions: [SetupAction] = []

        if pythonStatus != .available {
            issues.append(ScanIssue(
                code: "PYTHON_UNAVAILABLE",
                stage: "scan", category: .dependency,
                suggestedAction: .installPython
            ))
            actions.append(.installPython)
            return ModuleReadinessResult(
                module: .github, readiness: .missingDependency,
                localDependencies: probes, connection: .notChecked,
                blockingReason: "需要 Python 3.9 或更高版本",
                issues: issues, actions: actions
            )
        }

        if ghCliStatus != .available {
            issues.append(ScanIssue(
                code: "GH_CLI_MISSING",
                stage: "scan", category: .dependency,
                suggestedAction: .installGitHubCLI
            ))
            actions.append(.installGitHubCLI)
            return ModuleReadinessResult(
                module: .github, readiness: .missingDependency,
                localDependencies: probes, connection: .notChecked,
                blockingReason: "需要安装 GitHub CLI",
                issues: issues, actions: actions
            )
        }

        if !ghLoggedIn {
            issues.append(ScanIssue(
                code: "GH_NOT_LOGGED_IN",
                stage: "scan", category: .auth,
                suggestedAction: .loginGitHub
            ))
            actions.append(.loginGitHub)
            return ModuleReadinessResult(
                module: .github, readiness: .pendingAuthorization,
                localDependencies: probes, connection: .pendingAuthorization,
                blockingReason: "需要登录 GitHub",
                issues: issues, actions: actions
            )
        }

        return ModuleReadinessResult(
            module: .github, readiness: .ready,
            localDependencies: probes, connection: .connected,
            actions: actions
        )
    }

    /// 评估 GitLab 模块.
    /// 必要条件: Python 3.9+, HTTPS base URL, PAT 已配置, /api/v4/user 验证通过.
    public func evaluateGitLab(
        pythonStatus: LocalDependencyStatus,
        pythonVersion: String?,
        baseURL: URL?,
        connectionStatus: ConnectionStatus
    ) -> ModuleReadinessResult {
        var probes: [DependencyProbe] = []
        probes.append(DependencyProbe(
            kind: .python, status: pythonStatus, detail: pythonVersion
        ))

        var issues: [ScanIssue] = []
        var actions: [SetupAction] = []

        if pythonStatus != .available {
            issues.append(ScanIssue(
                code: "PYTHON_UNAVAILABLE",
                stage: "scan", category: .dependency,
                suggestedAction: .installPython
            ))
            actions.append(.installPython)
            return ModuleReadinessResult(
                module: .gitlab, readiness: .missingDependency,
                localDependencies: probes, connection: .notChecked,
                blockingReason: "需要 Python 3.9 或更高版本",
                issues: issues, actions: actions
            )
        }

        guard let url = baseURL, let scheme = url.scheme, scheme == "https" else {
            issues.append(ScanIssue(
                code: "GITLAB_URL_MISSING",
                stage: "scan", category: .dependency,
                suggestedAction: .configureGitLab
            ))
            actions.append(.configureGitLab)
            return ModuleReadinessResult(
                module: .gitlab, readiness: .pendingAuthorization,
                localDependencies: probes, connection: .pendingAuthorization,
                blockingReason: "需要配置私有 GitLab HTTPS 地址",
                issues: issues, actions: actions
            )
        }

        let readiness: ModuleReadiness
        switch connectionStatus {
        case .connected:
            readiness = .ready
        case .expired:
            readiness = .authorizationExpired
            issues.append(ScanIssue(
                code: "GITLAB_AUTH_EXPIRED",
                stage: "verify", category: .auth,
                suggestedAction: .replaceGitLabPAT
            ))
            actions.append(.replaceGitLabPAT)
        case .unreachable:
            readiness = .networkUnreachable
            issues.append(ScanIssue(
                code: "GITLAB_UNREACHABLE",
                stage: "verify", category: .network, retryable: true,
                suggestedAction: .retryConnection
            ))
            actions.append(.retryConnection)
        case .pendingAuthorization, .notChecked, .verifying:
            readiness = .pendingAuthorization
            issues.append(ScanIssue(
                code: "GITLAB_NOT_VERIFIED",
                stage: "verify", category: .auth,
                suggestedAction: .configureGitLab
            ))
            actions.append(.configureGitLab)
        case .notRequired, .unsupported:
            readiness = .unsupported
        }

        return ModuleReadinessResult(
            module: .gitlab, readiness: readiness,
            localDependencies: probes, connection: connectionStatus,
            issues: issues, actions: actions
        )
    }

    private func mapSQLiteStatus(_ result: SQLiteSchemaProbeResult) -> LocalDependencyStatus {
        switch result {
        case .available: return .available
        case .missing: return .missing
        case .locked: return .locked
        case .incompatible: return .incompatible
        case .corrupted: return .corrupted
        case .timedOut: return .timedOut
        }
    }
}
