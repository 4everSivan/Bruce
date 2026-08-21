import Foundation
import BruceOnboardingCore

// MARK: - RefreshBackoffPolicy

/// 刷新退避与错误分类策略 (阶段 C: 从 RefreshScheduler 拆出).
///
/// 纯逻辑: 计算退避时长, 不启动刷新, 不触碰 timer 或状态.
/// 退避公式: 限流走固定退避; 其他走指数退避 (base * 2^(retry-1)) + 抖动,
/// 上限 maxBackoffSeconds.
@MainActor
struct RefreshBackoffPolicy {
    let configuration: SchedulerConfiguration
    let jitterProvider: (Double) -> Double

    init(
        configuration: SchedulerConfiguration,
        jitterProvider: @escaping (Double) -> Double
    ) {
        self.configuration = configuration
        self.jitterProvider = jitterProvider
    }

    /// 计算退避秒数. 限流走固定退避; 其他走指数退避 + 抖动.
    func computeBackoff(
        retryCount: Int,
        category: SnapshotErrorCategory?
    ) -> Double {
        if category == .rateLimit {
            return configuration.rateLimitBackoffSeconds
        }

        let exponential = configuration.baseBackoffSeconds
            * pow(2.0, Double(retryCount - 1))
        let capped = min(exponential, configuration.maxBackoffSeconds)
        let jitter = jitterProvider(capped)
        return min(capped + jitter, configuration.maxBackoffSeconds)
    }
}

// MARK: - RefreshErrorClassifier

/// 刷新错误分类 (阶段 C: 从 RefreshScheduler 拆出).
/// 把 CollectorRunner 错误和 Bridge 响应诊断映射为 SnapshotErrorCategory.
struct RefreshErrorClassifier: Sendable {
    init() {}

    /// 分类 CollectorRunner 抛出的错误.
    /// - Returns: (错误分类, 是否为授权错误).
    func classifyRunnerError(_ error: Error) -> (SnapshotErrorCategory, Bool) {
        guard let runnerError = error as? CollectorRunnerError else {
            return (.collector, false)
        }
        switch runnerError {
        case .timedOut: return (.collector, false)
        case .processFailed: return (.collector, false)
        case .invalidEnvelope: return (.schema, false)
        case .launchFailed: return (.dependency, false)
        case .pythonNotExecutable: return (.dependency, false)
        case .rustNotExecutable: return (.dependency, false)
        case .bridgeNotReadable: return (.dependency, false)
        case .alreadyRunning: return (.collector, false)
        case .capacityExceeded: return (.collector, false)
        case .invalidExecutablePath: return (.dependency, false)
        case .unsupportedSchema: return (.schema, false)
        case .runIdMismatch: return (.schema, false)
        }
    }

    /// 分类 Bridge 响应中的诊断, 返回首个匹配的分类.
    func classifyBridgeError(_ response: BridgeResponse) -> SnapshotErrorCategory {
        for diagnostic in response.diagnostics {
            switch diagnostic.category {
            case "auth": return .auth
            case "network": return .network
            case "rateLimit": return .rateLimit
            case "schema": return .schema
            case "collector": return .collector
            case "dependency": return .dependency
            case "storage": return .storage
            case "cancelled": return .cancelled
            case "protocol", "security", "internal": return .schema
            default: break
            }
        }
        return .collector
    }
}
