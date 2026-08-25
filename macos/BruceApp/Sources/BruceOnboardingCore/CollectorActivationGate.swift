import Foundation

// MARK: - CollectorActivationGate

/// Scheduler 启用模块的唯一入口. 默认 deny.
/// 只有满足全部条件才允许启用 Collector:
///   moduleSelected AND consentVersionIsCurrent
///   AND localDependenciesPermitRun AND connectionStatePermitsRun
///   AND appIsAcceptingNewTasks
public struct CollectorActivationGate: Sendable {
    /// 当前授权版本. 版本变化后所有模块默认禁用.
    public let consentVersion: Int

    /// 配置中记录的已确认授权版本. 不匹配时拒绝.
    public let confirmedConsentVersion: Int?

    public init(consentVersion: Int, confirmedConsentVersion: Int?) {
        self.consentVersion = consentVersion
        self.confirmedConsentVersion = confirmedConsentVersion
    }

    /// 判断单个模块是否允许启动 Collector.
    public func canActivate(
        module: CollectorModule,
        readiness: ModuleReadiness,
        isModuleSelected: Bool,
        appIsAcceptingNewTasks: Bool
    ) -> Bool {
        // 未确认统一授权 -> deny
        guard let confirmed = confirmedConsentVersion, confirmed == consentVersion else {
            return false
        }
        // 模块未被用户选择 -> deny
        guard isModuleSelected else { return false }
        // 应用不接受新任务 -> deny
        guard appIsAcceptingNewTasks else { return false }

        // 根据模块和就绪度判断
        switch module {
        case .agentUsage:
            // Agent: ready 或 partial (有有效会话源) 可以运行本地分析
            return readiness == .ready || readiness == .partial
        }
    }
}
