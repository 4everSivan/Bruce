import Foundation
import BruceOnboardingCore

// MARK: - RefreshBackoffPolicy

/// 刷新退避与错误分类策略 (阶段 C: 从 RefreshScheduler 拆出).
///
/// 纯逻辑: 计算退避时长, 不启动刷新, 不触碰 timer 或状态.
/// 退避公式只在共享 `collector-policy::refresh` 中实现一份 (T17): 限流走固定退避;
/// 其他走指数退避 (base * 2^(retry-1)) + 抖动, 上限 maxBackoffSeconds.
@MainActor
struct RefreshBackoffPolicy {
    let configuration: SchedulerConfiguration
    /// 抖动比例 (capped 的 0...0.1); 注入以便测试确定性.
    let jitterProvider: () -> Double

    init(
        configuration: SchedulerConfiguration,
        jitterProvider: @escaping () -> Double
    ) {
        self.configuration = configuration
        self.jitterProvider = jitterProvider
    }

    /// 计算退避秒数. 共享入口不可用时回到上限 (最保守的等待), 不退回本地公式.
    func computeBackoff(
        retryCount: Int,
        category: SnapshotErrorCategory?
    ) -> Double {
        SharedRefreshPolicy.backoff(
            retryCount: retryCount,
            rateLimited: category == .rateLimit,
            base: configuration.baseBackoffSeconds,
            max: configuration.maxBackoffSeconds,
            rateLimit: configuration.rateLimitBackoffSeconds,
            jitterFraction: jitterProvider()
        ) ?? configuration.maxBackoffSeconds
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
        case .rustNotExecutable: return (.dependency, false)
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
            // 采集链路诊断 category 值域不含 "rateLimit": 真实限流信号是
            // provider 层 code=PROVIDER_RATE_LIMIT (HTTP 429), 先按 code 判定 (C006).
            if diagnostic.code == "PROVIDER_RATE_LIMIT" {
                return .rateLimit
            }
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
