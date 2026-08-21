import Foundation

// MARK: - ReadinessEvaluator

/// 根据本机扫描和连接状态计算模块就绪度.
/// 纯规则, 无副作用, 可测试.
public struct ReadinessEvaluator: Sendable {
    public init() {}

    /// 评估 Agent 用量模块.
    /// Release 必要条件: Rust Collector 可执行且至少一个会话源可读.
    /// Python 3.9+ 只在 Debug/Preview 运行时作为兼容条件.
    /// CC Switch 和 Antigravity 是可选增强, 单独存在不能让模块 ready.
    public func evaluateAgentUsage(
        pythonStatus: LocalDependencyStatus,
        pythonVersion: String?,
        sessionSources: [DependencyProbe],
        ccSwitchStatus: SQLiteSchemaProbeResult,
        antigravityStatus: SQLiteSchemaProbeResult,
        collectorRuntime: CollectorRuntimeStatus = .pythonPreview
    ) -> ModuleReadinessResult {
        var probes: [DependencyProbe] = []
        probes.append(DependencyProbe(
            kind: .python, status: pythonStatus, detail: pythonVersion
        ))
        probes.append(contentsOf: sessionSources)

        var issues: [ScanIssue] = []
        var warnings: [String] = []
        var actions: [SetupAction] = []

        // Release/正式运行时不再把 Python 当成硬依赖. Rust 缺失必须显式阻塞,
        // 避免打包错误被误报为“没有会话源”或静默回退到 Python.
        if collectorRuntime == .rustUnavailable {
            issues.append(ScanIssue(
                code: "RUST_COLLECTOR_UNAVAILABLE",
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
                blockingReason: "Rust Collector 不存在或不可执行",
                issues: issues,
                actions: actions
            )
        }

        // Python 不合格仅在 Debug/Preview 兼容路径阻塞.
        if collectorRuntime == .pythonPreview && pythonStatus != .available {
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
