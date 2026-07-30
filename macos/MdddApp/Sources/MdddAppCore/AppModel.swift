import SwiftUI
import MdddOnboardingCore

package enum DashboardModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case agentUsage
    case github
    case gitlab
    case settings

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .agentUsage:
            return "Agent 用量"
        case .github:
            return "GitHub"
        case .gitlab:
            return "GitLab"
        case .settings:
            return "设置"
        }
    }

    package var systemImage: String {
        switch self {
        case .agentUsage:
            return "gauge.with.dots.needle.67percent"
        case .github:
            return "chevron.left.forwardslash.chevron.right"
        case .gitlab:
            return "square.grid.3x3.fill"
        case .settings:
            return "gearshape"
        }
    }

    package var collectorModule: CollectorModule? {
        switch self {
        case .agentUsage:
            return .agentUsage
        case .github:
            return .github
        case .gitlab:
            return .gitlab
        case .settings:
            return nil
        }
    }

    package init(_ module: CollectorModule) {
        switch module {
        case .agentUsage:
            self = .agentUsage
        case .github:
            self = .github
        case .gitlab:
            self = .gitlab
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
    @Published package private(set) var menuBarMetrics: [MenuBarMetric]
    /// 当前外观主题, 默认经典; 由 OnboardingCoordinator 从配置恢复和持久化.
    @Published package var theme: AppTheme = .classic

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
    }

    package func setArtifact(_ artifact: JSONValue?, for module: DashboardModule) {
        moduleArtifacts[module] = artifact
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

    package func setMenuBarMetrics(_ metrics: [MenuBarMetric]) {
        menuBarMetrics = MenuBarMetricConfiguration(metrics: metrics).metrics
    }

    /// 判断模块是否满足前置依赖, 允许执行 Collector.
    package func canRunCollector(for module: CollectorModule) -> Bool {
        let readiness = moduleResults[module]?.readiness
        return readiness == .ready || readiness == .partial
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
