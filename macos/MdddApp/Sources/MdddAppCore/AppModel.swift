import SwiftUI
import MdddOnboardingCore

package enum DashboardModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case agentUsage
    case settings

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .agentUsage:
            return "Agent 用量"
        case .settings:
            return "设置"
        }
    }

    package var systemImage: String {
        switch self {
        case .agentUsage:
            return "gauge.with.dots.needle.67percent"
        case .settings:
            return "gearshape"
        }
    }

    package init(_ module: CollectorModule) {
        switch module {
        case .agentUsage:
            self = .agentUsage
        }
    }
}

package enum ModuleRunState: String, Codable, Sendable {
    case notConfigured
    case ready
    case refreshing
    case fresh
    case partial
    case stale
    case authRequired
    case offline
    case failed

    package var title: String {
        switch self {
        case .notConfigured:
            return "未配置"
        case .ready:
            return "可刷新"
        case .refreshing:
            return "刷新中"
        case .fresh:
            return "最新"
        case .partial:
            return "部分可用"
        case .stale:
            return "数据已过期"
        case .authRequired:
            return "需要授权"
        case .offline:
            return "网络不可用"
        case .failed:
            return "刷新失败"
        }
    }

    package var symbolName: String {
        switch self {
        case .fresh, .ready:
            return "checkmark.circle"
        case .refreshing:
            return "arrow.clockwise"
        case .partial, .stale, .authRequired:
            return "exclamationmark.triangle"
        case .offline:
            return "wifi.slash"
        case .failed:
            return "xmark.circle"
        case .notConfigured:
            return "circle.dashed"
        }
    }
}

package struct ModuleStatus: Equatable, Sendable {
    package let state: ModuleRunState
    package let detail: String?

    package static let notConfigured = ModuleStatus(
        state: .notConfigured,
        detail: nil
    )

    package init(state: ModuleRunState, detail: String?) {
        self.state = state
        self.detail = detail
    }
}

@MainActor
package final class AppModel: ObservableObject {
    @Published package var selectedModule: DashboardModule = .agentUsage
    @Published package private(set) var moduleStatuses: [DashboardModule: ModuleStatus]
    @Published package private(set) var moduleArtifacts: [DashboardModule: JSONValue] = [:]
    /// 最近一次就绪评估结果, 来源是 OnboardingCoordinator 的扫描和验证.
    @Published package private(set) var moduleResults: [CollectorModule: ModuleReadinessResult] = [:]
    /// 正在扫描或验证的模块, 供设置页禁用对应按钮.
    @Published package private(set) var busyModules: Set<CollectorModule> = []
    /// 设置页操作失败的用户可读错误, 不含凭证.
    @Published package private(set) var settingsErrorMessage: String?
    /// 订阅 provider 非敏感配置 (来自 OnboardingConfiguration), 供设置页渲染状态.
    @Published package private(set) var subscriptionProviders: [SubscriptionProviderID: SubscriptionProviderConfiguration] = [:]
    /// 各订阅 provider 的 Keychain 凭证是否已配置.
    @Published package private(set) var subscriptionCredentialConfigured: [SubscriptionProviderID: Bool] = [:]
    /// 本机是否存在可导入的 Antigravity 登录态 (文件或登录 Keychain);
    /// 由 coordinator 显式刷新, 设置页不得在 body 中直接探测.
    @Published package private(set) var antigravityLocalAvailable = false
    /// 正在保存, 验证或导入的订阅 provider, 供设置页禁用对应按钮.
    @Published package private(set) var busySubscriptionProviders: Set<SubscriptionProviderID> = []
    /// Codex 已导入账号摘要 (数量与邮箱前缀), 供设置页展示.
    @Published package private(set) var codexAccountSummary: (count: Int, emailPrefixes: [String])?
    /// Codex 非敏感账号状态 (授权状态, 来源, 存储健康), 供设置页渲染;
    /// 由 bootstrap 从 token manager 快照刷新.
    @Published package private(set) var codexAccountStatuses: [CodexAccountStatus] = []
    @Published package private(set) var menuBarMetrics: [MenuBarMetric]
    /// 最近一次面板映射产生的诊断, 随 artifact 与模块状态变更重算.
    /// 不进 UI; 供诊断路径与 harness 读取, 诊断包 schema 锁定期暂不外发.
    package private(set) var panelDiagnostics: [PanelDiagnostic] = []

    package init(menuBarMetricRawValues: [String]? = nil) {
        menuBarMetrics = MenuBarMetricConfiguration(
            rawValues: menuBarMetricRawValues
        ).metrics
        moduleStatuses = Dictionary(
            uniqueKeysWithValues: DashboardModule.allCases.map {
                ($0, .notConfigured)
            }
        )
        moduleStatuses[.settings] = ModuleStatus(state: .ready, detail: nil)
    }

    package func status(for module: DashboardModule) -> ModuleStatus {
        moduleStatuses[module] ?? .notConfigured
    }

    package func setStatus(_ status: ModuleStatus, for module: DashboardModule) {
        moduleStatuses[module] = status
        refreshPanelDiagnostics()
    }

    package func setArtifact(_ artifact: JSONValue?, for module: DashboardModule) {
        moduleArtifacts[module] = artifact
        refreshPanelDiagnostics()
    }

    /// 发布 Core 的就绪评估结果, 并把 readiness 映射为 Dashboard 状态.
    package func setModuleResult(_ result: ModuleReadinessResult) {
        moduleResults[result.module] = result
        let dashboardModule = DashboardModule(result.module)
        switch result.readiness {
        case .ready:
            setStatus(ModuleStatus(state: .ready, detail: nil), for: dashboardModule)
        case .partial:
            setStatus(
                ModuleStatus(state: .partial, detail: result.warnings.first),
                for: dashboardModule
            )
        case .missingDependency:
            setStatus(
                ModuleStatus(state: .notConfigured, detail: result.blockingReason),
                for: dashboardModule
            )
        case .pendingAuthorization:
            setStatus(
                ModuleStatus(state: .notConfigured, detail: result.blockingReason),
                for: dashboardModule
            )
        case .authorizationExpired:
            setStatus(
                ModuleStatus(
                    state: .authRequired,
                    detail: result.blockingReason ?? "请前往设置重新验证"
                ),
                for: dashboardModule
            )
        case .networkUnreachable:
            setStatus(
                ModuleStatus(state: .offline, detail: result.blockingReason),
                for: dashboardModule
            )
        case .unsupported:
            setStatus(
                ModuleStatus(
                    state: .notConfigured,
                    detail: result.blockingReason ?? "当前环境不支持"
                ),
                for: dashboardModule
            )
        }
    }

    package func setBusy(_ busy: Bool, for module: CollectorModule) {
        if busy {
            busyModules.insert(module)
        } else {
            busyModules.remove(module)
        }
    }

    package func setSettingsError(_ message: String?) {
        settingsErrorMessage = message
    }

    package func setSubscriptionProviders(
        _ providers: [SubscriptionProviderID: SubscriptionProviderConfiguration]
    ) {
        subscriptionProviders = providers
    }

    package func setSubscriptionCredentialConfigured(
        _ configured: Bool, for provider: SubscriptionProviderID
    ) {
        subscriptionCredentialConfigured[provider] = configured
    }

    package func setAntigravityLocalAvailable(_ available: Bool) {
        antigravityLocalAvailable = available
    }

    package func setBusySubscription(
        _ busy: Bool, for provider: SubscriptionProviderID
    ) {
        if busy {
            busySubscriptionProviders.insert(provider)
        } else {
            busySubscriptionProviders.remove(provider)
        }
    }

    package func setCodexAccountSummary(
        _ summary: (count: Int, emailPrefixes: [String])?
    ) {
        codexAccountSummary = summary
    }

    package func setCodexAccountStatuses(_ statuses: [CodexAccountStatus]) {
        codexAccountStatuses = statuses
    }

    package func setMenuBarMetrics(_ metrics: [MenuBarMetric]) {
        menuBarMetrics = MenuBarMetricConfiguration(metrics: metrics).metrics
    }

    /// 判断模块是否满足前置依赖, 允许执行 Collector.
    package func canRunCollector(for module: CollectorModule) -> Bool {
        let readiness = moduleResults[module]?.readiness
        return readiness == .ready || readiness == .partial
    }

    // MARK: - 面板 view model

    /// 组装菜单栏面板的卡片 view model: artifact 经映射层条件渲染,
    /// 卡片为 nil 即不渲染. artifact 缺失或校验失败按缺失处理,
    /// 由映射层写入对应诊断.
    package func makePanelViewModel() -> PanelViewModel {
        PanelViewModelMapper().make(
            agentUsage: decodedAgentUsageArtifact(),
            moduleStatuses: moduleStatuses
        )
    }

    /// 重算面板诊断; artifact 或模块状态变更时调用, 保证诊断路径取到最新值.
    private func refreshPanelDiagnostics() {
        panelDiagnostics = makePanelViewModel().diagnostics
    }

    /// 校验并解码 agent-usage artifact; 任何失败都视为缺失.
    private func decodedAgentUsageArtifact() -> AgentUsageArtifact? {
        guard let artifact = moduleArtifacts[.agentUsage],
              case .agentUsage(let decoded) = try? ArtifactValidator()
                  .validate(artifact, for: .agentUsage)
        else {
            return nil
        }
        return decoded
    }

    /// 返回 Core 的 ModuleReadiness 枚举, 供 ActivationGate 使用.
    /// 优先使用最近的就绪评估结果, 没有评估时回退到运行状态推断.
    package func readinessValue(for module: CollectorModule) -> MdddOnboardingCore.ModuleReadiness {
        if let result = moduleResults[module] {
            return result.readiness
        }
        let dashboardModule = DashboardModule(module)
        let status = self.status(for: dashboardModule)
        switch status.state {
        case .ready, .fresh:
            return .ready
        case .refreshing:
            return .ready
        case .partial:
            return .partial
        case .notConfigured:
            return .missingDependency
        case .authRequired:
            return .authorizationExpired
        case .offline:
            return .networkUnreachable
        case .stale:
            // 有缓存但过期, 仍可能是 ready (依赖满足, 只是数据旧)
            return .ready
        case .failed:
            return .missingDependency
        }
    }
}
