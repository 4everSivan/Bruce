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

/// Codex 旧凭证迁移结果的脱敏展示状态 (任务 7).
/// 不携带账号 ID, 邮箱, token 或 Keychain service/account 名称;
/// 文案只说明「旧 Codex 账号数据无法安全迁移/清理」.
package enum CodexMigrationDisplayStatus: Equatable, Sendable {
    /// 尚未执行迁移 (App 启动前).
    case notStarted
    /// 无旧数据或迁移成功: 正常, Codex gate 开放.
    case completed
    /// v2 数据已写入并校验, 旧键清理待重试: 非阻断, 下次启动重试清理.
    case cleanupPending
    /// 损坏 / 结构不支持 / 读写校验失败: 阻断, Codex 外部额度关闭.
    case blocked

    package var isBlocking: Bool {
        self == .blocked
    }

    /// 迁移结果 -> 脱敏展示状态 (任务 7).
    /// migrated / noLegacyData 正常; cleanupPending 非阻断 (v2 可用);
    /// corruptedJSON / incompatibleSchema / failed 阻断 Codex 外部额度.
    package static func from(_ result: CodexMigrationResult) -> CodexMigrationDisplayStatus {
        switch result {
        case .noLegacyData, .migrated:
            return .completed
        case .cleanupPending:
            return .cleanupPending
        case .corruptedJSON, .incompatibleSchema, .failed:
            return .blocked
        }
    }

    package var userMessage: String? {
        switch self {
        case .notStarted, .completed:
            return nil
        case .cleanupPending:
            return "旧 Codex 账号数据清理未完成, 下次启动将自动重试"
        case .blocked:
            return "旧 Codex 账号数据无法安全迁移, 已暂停 Codex 外部额度查询"
        }
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
    /// 本机是否存在 Claude CLI 登录态 (Keychain 或 ~/.claude/.credentials.json);
    /// 由 coordinator 显式刷新, 同时作为 claude provider 的 configured 语义.
    @Published package private(set) var claudeLocalAvailable = false
    /// 本机是否存在 Grok CLI 登录态 (~/.grok/auth.json 含可用条目);
    /// 由 coordinator 显式刷新, 同时作为 grok provider 的 configured 语义.
    @Published package private(set) var grokLocalAvailable = false
    /// 正在保存, 验证或导入的订阅 provider, 供设置页禁用对应按钮.
    @Published package private(set) var busySubscriptionProviders: Set<SubscriptionProviderID> = []
    /// Codex 已导入账号摘要 (数量与邮箱前缀), 供设置页展示.
    @Published package private(set) var codexAccountSummary: (count: Int, emailPrefixes: [String])?
    /// Codex 非敏感账号状态 (授权状态, 来源, 存储健康), 供设置页渲染;
    /// 由 bootstrap 从 token manager 快照刷新.
    @Published package private(set) var codexAccountStatuses: [CodexAccountStatus] = []
    /// Codex 旧凭证迁移结果 (任务 7): 只保存脱敏可展示状态, 不暴露
    /// 存储错误对象或原始 Keychain 内容. 阻断性错误关闭 Codex 外部额度,
    /// 非阻断 (cleanupPending) 保留额度并提示下次启动重试清理.
    @Published package private(set) var codexMigrationStatus: CodexMigrationDisplayStatus = .notStarted
    /// 订阅 provider 展示顺序, 供设置页排列与面板映射排序使用.
    @Published package private(set) var subscriptionProviderOrder: [SubscriptionProviderID] = []
    @Published package private(set) var menuBarMetrics: [MenuBarMetric]
    /// 最近一次面板映射产生的诊断, 随 artifact 与模块状态变更重算.
    /// 不进 UI; 供诊断路径与 harness 读取, 诊断包 schema 锁定期暂不外发.
    package private(set) var panelDiagnostics: [PanelDiagnostic] = []
    /// DeepSeek 月度账本. 由 MdddApp 装配注入; nil 表示账本未启用
    /// (测试或账本创建失败), 此时月度统计不可用但余额卡不受影响.
    private let deepSeekLedger: DeepSeekUsageLedger?
    /// DeepSeek 月度派生状态 (唯一 UI 状态源). 账本不可用时为 nil.
    @Published package private(set) var deepSeekMonthlyUsage: DeepSeekMonthlyUsage?

    package init(
        menuBarMetricRawValues: [String]? = nil,
        deepSeekLedger: DeepSeekUsageLedger? = nil
    ) {
        self.deepSeekLedger = deepSeekLedger
        menuBarMetrics = MenuBarMetricConfiguration(
            rawValues: menuBarMetricRawValues
        ).metrics
        moduleStatuses = Dictionary(
            uniqueKeysWithValues: DashboardModule.allCases.map {
                ($0, .notConfigured)
            }
        )
        moduleStatuses[.settings] = ModuleStatus(state: .ready, detail: nil)
        if deepSeekLedger != nil {
            deepSeekMonthlyUsage = .unavailable
        }
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
        if module == .agentUsage {
            updateDeepSeekMonthlyUsage(from: artifact)
        }
        refreshPanelDiagnostics()
    }

    /// 追踪 ID 变化时立即失效当前派生月度状态 (等下一次有效余额观察重建基线).
    /// 由 OnboardingCoordinator 在发布 subscriptionProviders 后调用.
    package func invalidateDeepSeekMonthlyUsage() {
        deepSeekMonthlyUsage = deepSeekLedger != nil ? .unavailable : nil
    }

    // MARK: - 账单导出

    /// 账单导出 CSV: 当前 artifact 的逐日 token 明细, 今日成本与 DeepSeek 月度摘要.
    /// 无有效 artifact 时返回 nil (设置页提示先刷新).
    package func billingReportCSV() -> String? {
        guard let artifact = decodedAgentUsageArtifact() else { return nil }
        var lines: [String] = [
            "# mddd 账单导出",
            "# 数据时间,\(artifact.generatedAt)",
            "",
            "日期,Agent,输入 tokens,输出 tokens,合计 tokens",
        ]
        for agent in artifact.agents {
            for day in agent.daily {
                lines.append([
                    day.date,
                    Self.csvField(agent.name),
                    String(day.input),
                    String(day.output),
                    String(day.total),
                ].joined(separator: ","))
            }
        }
        lines.append("")
        lines.append("# 今日成本 (CNY 按汇率 \(PanelFormat.cnyPerUsd) 换算)")
        lines.append("Agent,成本 USD,成本 CNY")
        var hasCost = false
        for agent in artifact.agents {
            guard let usd = agent.todayCostUsd else { continue }
            hasCost = true
            lines.append([
                Self.csvField(agent.name),
                Self.moneyText(usd),
                Self.moneyText(usd * PanelFormat.cnyPerUsd),
            ].joined(separator: ","))
        }
        if let total = artifact.totalCostUsd {
            hasCost = true
            lines.append(
                "合计,\(Self.moneyText(total)),"
                    + Self.moneyText(total * PanelFormat.cnyPerUsd)
            )
        }
        if !hasCost {
            lines.append("无定价数据")
        }
        switch deepSeekMonthlyUsage {
        case .trend(let trend):
            lines.append("")
            lines.append("# DeepSeek 月度")
            lines.append("本月消费 \(trend.currency),\(Self.decimalText(trend.estimatedConsumption))")
            lines.append("当前余额 \(trend.currency),\(Self.decimalText(trend.currentBalance))")
        case .baseline(let baseline):
            lines.append("")
            lines.append("# DeepSeek 月度")
            lines.append("当前余额 \(baseline.currency),\(Self.decimalText(baseline.currentBalance))")
        case .unavailable, .none:
            break
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// CSV 字段转义: 含逗号, 引号或换行时加双引号包裹.
    private static func csvField(_ text: String) -> String {
        guard text.contains(",") || text.contains("\"") || text.contains("\n") else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func moneyText(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    /// 重新解码 Artifact, 只把有效 DeepSeek 余额观察交给账本,
    /// 派生月度状态作为唯一 UI 状态源保存. 无效/空/失败/未授权
    /// 的 DeepSeek Artifact 不读写账本.
    private func updateDeepSeekMonthlyUsage(from artifact: JSONValue?) {
        guard let ledger = deepSeekLedger else {
            deepSeekMonthlyUsage = nil
            return
        }
        guard let artifact,
              case .agentUsage(let decoded) = try? ArtifactValidator()
                  .validate(artifact, for: .agentUsage) else {
            // 无效/空 Artifact: 不读写账本, 保留当前状态.
            return
        }
        guard let service = decoded.services.first(where: {
            $0.id == "deepseek"
        }) else {
            return
        }
        // 仅接受已校验 Artifact 中 id==deepseek, status==ok, kind==balance,
        // 余额为非负有限值的观察.
        guard service.status == "ok",
              service.kind == "balance",
              let balance = service.balance,
              balance.isFinite,
              balance >= 0,
              let currency = service.currency else {
            return
        }
        let trackingID = subscriptionProviders[.deepseek]?.usageTrackingID
        ledger.setTrackingID(trackingID)
        deepSeekMonthlyUsage = ledger.record(
            DeepSeekUsageObservation(
                observedAt: decoded.generatedAt,
                balance: Decimal(balance),
                currency: currency
            )
        )
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
        let oldTrackingID = subscriptionProviders[.deepseek]?.usageTrackingID
        subscriptionProviders = providers
        // 追踪 ID 变化 (保存/更换 API key) 时立即失效派生月度状态,
        // 等下一次有效余额观察重建基线, 避免新旧账户混算.
        if providers[.deepseek]?.usageTrackingID != oldTrackingID {
            invalidateDeepSeekMonthlyUsage()
        }
    }

    package func setSubscriptionCredentialConfigured(
        _ configured: Bool, for provider: SubscriptionProviderID
    ) {
        subscriptionCredentialConfigured[provider] = configured
    }

    package func setAntigravityLocalAvailable(_ available: Bool) {
        antigravityLocalAvailable = available
    }

    package func setClaudeLocalAvailable(_ available: Bool) {
        claudeLocalAvailable = available
    }

    package func setGrokLocalAvailable(_ available: Bool) {
        grokLocalAvailable = available
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

    /// 发布脱敏的 Codex 迁移结果 (任务 7). 只接收可展示状态,
    /// 不暴露存储错误对象或原始 Keychain 内容.
    package func setCodexMigrationStatus(_ status: CodexMigrationDisplayStatus) {
        codexMigrationStatus = status
    }

    package func setMenuBarMetrics(_ metrics: [MenuBarMetric]) {
        menuBarMetrics = MenuBarMetricConfiguration(metrics: metrics).metrics
    }

    package func setSubscriptionProviderOrder(_ order: [SubscriptionProviderID]) {
        subscriptionProviderOrder = order
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
            moduleStatuses: moduleStatuses,
            deepSeekMonthlyUsage: deepSeekMonthlyUsage,
            providerOrder: subscriptionProviderOrder.map(\.rawValue)
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
