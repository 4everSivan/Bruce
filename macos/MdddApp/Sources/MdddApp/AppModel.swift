import SwiftUI
import MdddOnboardingCore

enum DashboardModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case agentUsage
    case github
    case gitlab
    case settings

    var id: String { rawValue }

    var title: String {
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

    var systemImage: String {
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

    init(_ module: CollectorModule) {
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

enum ModuleRunState: String, Codable, Sendable {
    case notConfigured
    case ready
    case refreshing
    case fresh
    case partial
    case stale
    case authRequired
    case offline
    case failed

    var title: String {
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

    var symbolName: String {
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

struct ModuleStatus: Equatable, Sendable {
    let state: ModuleRunState
    let detail: String?

    static let notConfigured = ModuleStatus(
        state: .notConfigured,
        detail: nil
    )
}

enum DockBadgeState: Equatable, Sendable {
    case none
    case attention
    case refreshFailed

    var label: String? {
        switch self {
        case .none:
            return nil
        case .attention:
            return "•"
        case .refreshFailed:
            return "!"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedModule: DashboardModule = .agentUsage
    @Published private(set) var moduleStatuses: [DashboardModule: ModuleStatus]
    @Published private(set) var moduleArtifacts: [DashboardModule: JSONValue] = [:]
    /// 最近一次就绪评估结果, 来源是 OnboardingCoordinator 的扫描和验证.
    @Published private(set) var moduleResults: [CollectorModule: ModuleReadinessResult] = [:]
    /// 正在扫描或验证的模块, 供设置页禁用对应按钮.
    @Published private(set) var busyModules: Set<CollectorModule> = []
    /// 设置页操作失败的用户可读错误, 不含凭证.
    @Published private(set) var settingsErrorMessage: String?
    @Published private(set) var dockBadgeState: DockBadgeState = .none
    /// 当前外观主题, 默认经典; 由 OnboardingCoordinator 从配置恢复和持久化.
    @Published var theme: AppTheme = .classic

    init() {
        moduleStatuses = Dictionary(
            uniqueKeysWithValues: DashboardModule.allCases.map {
                ($0, .notConfigured)
            }
        )
        moduleStatuses[.settings] = ModuleStatus(state: .ready, detail: nil)
    }

    func status(for module: DashboardModule) -> ModuleStatus {
        moduleStatuses[module] ?? .notConfigured
    }

    func setStatus(_ status: ModuleStatus, for module: DashboardModule) {
        moduleStatuses[module] = status
        updateDockBadge()
    }

    func setArtifact(_ artifact: JSONValue?, for module: DashboardModule) {
        moduleArtifacts[module] = artifact
    }

    /// 发布 Core 的就绪评估结果, 并把 readiness 映射为 Dashboard 状态.
    func setModuleResult(_ result: ModuleReadinessResult) {
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

    func setBusy(_ busy: Bool, for module: CollectorModule) {
        if busy {
            busyModules.insert(module)
        } else {
            busyModules.remove(module)
        }
    }

    func setSettingsError(_ message: String?) {
        settingsErrorMessage = message
    }

    /// 判断模块是否满足前置依赖, 允许执行 Collector.
    func canRunCollector(for module: CollectorModule) -> Bool {
        let readiness = moduleResults[module]?.readiness
        return readiness == .ready || readiness == .partial
    }

    /// 返回 Core 的 ModuleReadiness 枚举, 供 ActivationGate 使用.
    /// 优先使用最近的就绪评估结果, 没有评估时回退到运行状态推断.
    func readinessValue(for module: CollectorModule) -> MdddOnboardingCore.ModuleReadiness {
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

    private func updateDockBadge() {
        let states = moduleStatuses
            .filter { $0.key != .settings }
            .map(\.value.state)
        if states.contains(.failed) {
            dockBadgeState = .refreshFailed
        } else if states.contains(where: {
            [.partial, .stale, .authRequired, .offline].contains($0)
        }) {
            dockBadgeState = .attention
        } else {
            dockBadgeState = .none
        }
    }
}
