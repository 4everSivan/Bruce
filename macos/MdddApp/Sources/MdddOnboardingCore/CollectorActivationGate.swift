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
        case .github, .gitlab:
            // GitHub 和 GitLab: 只有 ready 可以运行
            return readiness == .ready
        }
    }

    /// 生成模块的执行策略. 决定 Collector 获得哪些能力.
    /// hasConfiguredSubscriptionProvider 为 true 时 agent-usage 追加
    /// externalQuotas (至少一个订阅 provider enabled 且 Keychain 凭证完整,
    /// 由调用方依据配置与凭证装配结果给出).
    public func executionPolicy(
        for module: CollectorModule,
        readiness: ModuleReadiness,
        hasConfiguredSubscriptionProvider: Bool = false
    ) -> CollectorExecutionPolicy? {
        guard canActivate(
            module: module,
            readiness: readiness,
            isModuleSelected: true,
            appIsAcceptingNewTasks: true
        ) else {
            return nil
        }

        switch module {
        case .agentUsage:
            // 本地会话和本地定价是基础能力; 订阅 provider 已配置时
            // 才追加 externalQuotas, 未配置任何 provider 不授予
            var capabilities: Set<CollectorCapability> = [.localSessions, .localPricing]
            if hasConfiguredSubscriptionProvider {
                capabilities.insert(.externalQuotas)
            }
            return CollectorExecutionPolicy(
                module: module,
                capabilities: capabilities
            )
        case .github:
            // GitHub 通过 gh CLI 执行, 不需要额外能力
            return CollectorExecutionPolicy(
                module: module,
                capabilities: []
            )
        case .gitlab:
            // GitLab 需要 base URL 和 PAT (由 run input 提供)
            return CollectorExecutionPolicy(
                module: module,
                capabilities: []
            )
        }
    }
}

// MARK: - CollectorActivationDecision

/// Gate 对全部模块的统一决策.
public struct CollectorActivationDecision: Equatable, Sendable {
    public let module: CollectorModule
    public let allowed: Bool
    public let policy: CollectorExecutionPolicy?

    public init(module: CollectorModule, allowed: Bool, policy: CollectorExecutionPolicy?) {
        self.module = module
        self.allowed = allowed
        self.policy = policy
    }
}

// MARK: - ActivationGateEvaluator

/// 批量评估所有模块的激活状态.
public struct ActivationGateEvaluator: Sendable {
    private let gate: CollectorActivationGate

    public init(gate: CollectorActivationGate) {
        self.gate = gate
    }

    public func evaluate(
        readinessByModule: [CollectorModule: ModuleReadiness],
        selectedModules: Set<CollectorModule>,
        appIsAcceptingNewTasks: Bool,
        hasConfiguredSubscriptionProvider: Bool = false
    ) -> [CollectorActivationDecision] {
        CollectorModule.allCases.map { module in
            let readiness = readinessByModule[module] ?? .missingDependency
            let isSelected = selectedModules.contains(module)
            let allowed = gate.canActivate(
                module: module,
                readiness: readiness,
                isModuleSelected: isSelected,
                appIsAcceptingNewTasks: appIsAcceptingNewTasks
            )
            let policy = allowed
                ? gate.executionPolicy(
                    for: module,
                    readiness: readiness,
                    hasConfiguredSubscriptionProvider: hasConfiguredSubscriptionProvider
                )
                : nil
            return CollectorActivationDecision(
                module: module, allowed: allowed, policy: policy
            )
        }
    }
}
