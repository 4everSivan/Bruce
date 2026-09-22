import AppKit
import Combine
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

@MainActor
final class ApplicationBootstrap {
    private let runtime: AppRuntime
    private let scheduler: RefreshScheduler
    private let runner: any CollectorExecutable & CollectorRuntimeControlling
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
    private var keychainAccessObserver: AnyCancellable?
    private var keychainStateObserver: AnyCancellable?
    private var notificationPreferenceObserver: AnyCancellable?
    private var keychainStartupPrepared = false
    private var lastStatusRefresh = Date.distantPast

    init(
        runtime: AppRuntime,
        scheduler: RefreshScheduler,
        runner: any CollectorExecutable & CollectorRuntimeControlling,
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
        // Stage 3 / TASK-6D: 把 Scheduler 的 Provider 级定向刷新状态回调接到
        // AppModel 的 UI seam (setSubscriptionRefreshing). 只传 Bool 刷新标记,
        // 不把凭证、token 或 artifact 原始 JSON 带入 UI; 状态收敛由 AppModel
        // 的 refreshingSubscriptionProviders 集合负责 (started 进入, 终态移出).
        scheduler.onSubscriptionRefreshState = { [weak model] provider, state in
            let refreshing: Bool
            switch state {
            case .started:
                refreshing = true
            case .finished, .failed, .cancelled:
                refreshing = false
            }
            model?.setSubscriptionRefreshing(refreshing, for: provider)
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
        // 先启动调度器读取本地快照, 再准备 Keychain. Keychain ACL 可能弹出
        // 系统认证并暂时挂起启动协程; 不能让这个与凭证无关的缓存路径一起
        // 阻塞, 否则状态栏只会显示图标/占位符, 今日用量要等认证结束才出现.
        runtime.configure(scheduler: scheduler, runner: runner)
        runtime.startSchedulerIfNeeded()
        // 未配置 Bruce Keychain ACL 时, 启动阶段不执行任何凭证迁移或账号状态读取.
        // 这避免首次启动在用户主动配置之前触发 macOS 登录密码提示.
        if coordinator.keychainAccessConfigured {
            await prepareKeychainBackedStartup()
        }
        keychainAccessObserver = coordinator.$keychainAccessConfigured
            .removeDuplicates()
            .sink { [weak self] configured in
                guard configured else { return }
                self?.scheduleKeychainBackedStartup()
            }
        keychainStateObserver = coordinator.$keychainAccessState
            .removeDuplicates()
            .sink { [weak self] state in
                guard state == .allowed else { return }
                self?.scheduleKeychainBackedStartup()
            }
        quotaAlertNotifier.isEnabled = coordinator.systemNotificationsEnabled
        notificationPreferenceObserver = coordinator.$systemNotificationsEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.quotaAlertNotifier.isEnabled = enabled
            }
        coordinator.scanAndReconcile()
        refreshCodexAccountStatuses()
        return true
    }

    /// 发布 token manager 的非敏感状态快照 (≤5 秒节流, 由调用方异步触发).
    private func refreshCodexAccountStatuses() {
        guard coordinator.keychainAccessConfigured,
              keychainStartupPrepared else { return }
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

    /// 延迟到 Keychain ACL 配置完成后执行启动阶段的凭证迁移.
    private func prepareKeychainBackedStartup() async {
        guard coordinator.keychainAccessConfigured,
              !keychainStartupPrepared else { return }
        let enabledProviders = coordinator.enabledSubscriptionProviders()
        let migrationResult: CodexMigrationResult
        if enabledProviders.contains(.codex) {
            migrationResult = await codexMigration.executeCodexMigration()
        } else {
            migrationResult = .noLegacyData
        }
        runInputProvider.setCodexMigrationResult(migrationResult)
        // 只发布脱敏迁移状态, 不暴露账号 ID/邮箱/token.
        model?.setCodexMigrationStatus(.from(migrationResult))

        let preparation = await coordinator.prepareKeychainBackedStartup()
        guard preparation == .ready else {
            keychainStartupPrepared = false
            return
        }
        keychainStartupPrepared = true
    }

    /// 配置完成后补做迁移, 再开放 Scheduler 的自动刷新.
    private func scheduleKeychainBackedStartup() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await prepareKeychainBackedStartup()
            coordinator.reconcileScheduler()
            refreshCodexAccountStatuses()
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
    private var isDockPresentationActive = false

    var managedWindow: NSWindow? { window }

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

    /// 打开或前置设置窗口, 并在打开期间显示 Dock 图标与注册切换器焦点.
    func present() {
        let window = window ?? makeWindow()
        setDockIconVisible(true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Dock 图标被点击时: 若配置会话仍在, 重新前置设置窗口.
    func handleDockReopen() {
        guard isDockPresentationActive else { return }
        present()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // 关闭配置窗口后恢复菜单栏-only, 去掉 Dock 图标.
        setDockIconVisible(false)
    }

    // MARK: - Private

    private func setDockIconVisible(_ visible: Bool) {
        guard isDockPresentationActive != visible else { return }
        isDockPresentationActive = visible
        if visible {
            ensureStandardMainMenu()
            _ = NSApp.setActivationPolicy(.regular)
        } else {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private func ensureStandardMainMenu() {
        if NSApp.mainMenu != nil { return }
        let mainMenu = NSMenu()

        // 1. App 菜单
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 Bruce", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 Bruce", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 Bruce", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 2. 编辑菜单 (使输入框支持标准的 Cmd+C, Cmd+V, Cmd+A, Cmd+Z 等)
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "编辑")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // 3. 窗口菜单
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    private func makeWindow() -> NSWindow {
        let rootView = SettingsView()
            .environmentObject(model)
            .environmentObject(coordinator)
            .environmentObject(diagnostics)
            .frame(
                minWidth: 980,
                idealWidth: 1040,
                maxWidth: .infinity,
                minHeight: 620,
                idealHeight: 680,
                maxHeight: .infinity
            )
        let window = SettingsHostWindow(
            contentViewController: NSHostingController(rootView: rootView)
        )
        window.title = "Bruce 设置"
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable,
        ]
        window.minSize = NSSize(width: 980, height: 620)
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("Bruce.SettingsWindow")
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}

/// 重写 canBecomeKey 与 canBecomeMain 为 true,
/// 保证应用在 Regular 模式下被 macOS WindowServer 识别为前台主窗口,
/// 彻底支持 Command + Tab 切换器切出并前置.
private final class SettingsHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
