import AppKit
import Combine
import MdddAppCore
import MdddOnboardingCore
import SwiftUI

@MainActor
final class ApplicationBootstrap {
    private let runtime: AppRuntime
    private let scheduler: RefreshScheduler
    private let runner: CollectorRunner
    private let coordinator: OnboardingCoordinator
    private let runInputProvider: OnboardingRunInputProvider
    /// Codex v2 迁移执行器: 启动 Scheduler 前幂等迁移旧整体账号库;
    /// 失败时只暂停 Codex 外部额度, 不阻断本地统计.
    /// 生产组合根必须注入真实 CodexCredentialStore, 不得使用空迁移器.
    private let codexMigration: any CodexMigrationExecuting
    /// Codex token manager: 启动时发布一次非敏感状态,
    /// 并在每个调度周期后刷新, 供设置页订阅.
    private let codexTokenManager: CodexTokenManager
    private let quotaAlertNotifier = QuotaAlertNotifier()
    private weak var model: AppModel?
    private var started = false
    private var appearanceObserver: AnyCancellable?
    private var lastStatusRefresh = Date.distantPast

    init(
        runtime: AppRuntime,
        scheduler: RefreshScheduler,
        runner: CollectorRunner,
        coordinator: OnboardingCoordinator,
        runInputProvider: OnboardingRunInputProvider,
        codexTokenManager: CodexTokenManager,
        model: AppModel,
        codexMigration: any CodexMigrationExecuting
    ) {
        self.runtime = runtime
        self.scheduler = scheduler
        self.runner = runner
        self.coordinator = coordinator
        self.runInputProvider = runInputProvider
        self.codexTokenManager = codexTokenManager
        self.model = model
        self.codexMigration = codexMigration
    }

    @discardableResult
    func startIfNeeded() async -> Bool {
        guard !started else { return false }
        started = true
        scheduler.onStatusChange = { [weak model] module, runState, detail in
            model?.setStatus(
                ModuleStatus(state: runState, detail: detail),
                for: DashboardModule(module)
            )
        }
        scheduler.onArtifactChange = { [weak model] module, artifact in
            model?.setArtifact(artifact, for: DashboardModule(module))
        }
        // credentialUpdates 由 RefreshScheduler 注入的 CredentialUpdateCoordinator
        // 在 RefreshExecutionPipeline 中于 publish 前应用; 写回失败降级为 partial + 诊断.
        // 后台刷新发现 5h 额度新跨越 80% 阈值时弹系统通知.
        scheduler.onQuotaAlerts = { [quotaAlertNotifier] _, alerts in
            quotaAlertNotifier.deliver(alerts)
        }
        // 每个调度周期后刷新 Codex 账号状态 (token 决议会改变授权/存储状态).
        scheduler.onRunCycleCompleted = { [weak self] in
            self?.refreshCodexAccountStatuses()
        }
        // 外观偏好应用级生效: SwiftUI preferredColorScheme 只影响环境,
        // 玻璃与 material 的真实配色由窗口 appearance 驱动.
        applyAppearance(coordinator.appearanceMode)
        appearanceObserver = coordinator.$appearanceMode.sink { [weak self] mode in
            self?.applyAppearance(mode)
        }
        // 启动 Scheduler 前先执行幂等迁移, 迁移结果控制 Codex quota gate:
        // noLegacyData/migrated/cleanupPending 开放, corruptedJSON/failed 关闭.
        // 失败只暂停 Codex 外部额度, 本地 Agent token 统计和其他 provider 不受影响.
        let migrationResult = await codexMigration.executeCodexMigration()
        runInputProvider.setCodexMigrationResult(migrationResult)
        // 任务 7: 把迁移结果映射为脱敏展示状态 (不暴露账号 ID/邮箱/token),
        // 供设置页渲染阻断与非阻断提示.
        model?.setCodexMigrationStatus(.from(migrationResult))
        runtime.configure(scheduler: scheduler, runner: runner)
        runtime.startSchedulerIfNeeded()
        coordinator.scanAndReconcile()
        refreshCodexAccountStatuses()
        return true
    }

    /// 发布 token manager 的非敏感状态快照 (≤5 秒节流, 由调用方异步触发).
    private func refreshCodexAccountStatuses() {
        let now = Date()
        guard now.timeIntervalSince(lastStatusRefresh) >= 5 else { return }
        lastStatusRefresh = now
        Task { @MainActor [weak self, codexTokenManager] in
            let state = await codexTokenManager.statusSnapshot()
            self?.model?.setCodexAccountStatuses(
                state.accounts.map { account in
                    CodexAccountStatus(
                        accountID: account.accountID,
                        displayName: account.displayName,
                        authorizationState: account.authorizationState,
                        credentialOrigin: account.credentialOrigin,
                        storageBlocked: account.storageBlocked,
                        updatedAt: account.updatedAt
                    )
                }
            )
        }
    }

    /// system 恢复跟随系统 (nil), light/dark 强制应用级配色.
    private func applyAppearance(_ mode: AppearancePreference) {
        switch mode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let coordinator: OnboardingCoordinator
    private let diagnostics: DiagnosticService
    private var window: NSWindow?
    /// 配置窗口是否处于「应显示 Dock」状态 (可见或最小化).
    private var isDockPresentationActive = false

    init(
        model: AppModel,
        coordinator: OnboardingCoordinator,
        diagnostics: DiagnosticService
    ) {
        self.model = model
        self.coordinator = coordinator
        self.diagnostics = diagnostics
        super.init()
    }

    /// 打开或前置设置窗口, 并显示 Dock 图标.
    func present() {
        let window = window ?? makeWindow()
        setDockIconVisible(true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Dock 图标被点击时: 若配置会话仍在, 重新前置设置窗口.
    func handleDockReopen() {
        guard isDockPresentationActive else { return }
        present()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // isReleasedWhenClosed = false: 关闭后窗口对象保留, 仅隐藏.
        // 关闭配置窗口后恢复菜单栏-only, 去掉 Dock 图标.
        setDockIconVisible(false)
    }

    // MARK: - Private

    private func makeWindow() -> NSWindow {
        let rootView = SettingsView()
            .environmentObject(model)
            .environmentObject(coordinator)
            .environmentObject(diagnostics)
            .frame(minWidth: 700, minHeight: 620)
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: rootView)
        )
        window.title = "mddd 设置"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.minSize = NSSize(width: 700, height: 620)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    /// LSUIElement 菜单栏 App: accessory 隐藏 Dock; regular 显示 Dock.
    /// 仅在状态变化时切换, 避免重复 setActivationPolicy 闪烁.
    private func setDockIconVisible(_ visible: Bool) {
        guard isDockPresentationActive != visible else { return }
        isDockPresentationActive = visible
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        _ = NSApp.setActivationPolicy(policy)
    }
}
