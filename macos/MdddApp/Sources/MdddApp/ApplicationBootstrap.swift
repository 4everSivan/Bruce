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
    private let quotaAlertNotifier = QuotaAlertNotifier()
    private weak var model: AppModel?
    private var started = false
    private var appearanceObserver: AnyCancellable?

    init(
        runtime: AppRuntime,
        scheduler: RefreshScheduler,
        runner: CollectorRunner,
        coordinator: OnboardingCoordinator,
        runInputProvider: OnboardingRunInputProvider,
        model: AppModel
    ) {
        self.runtime = runtime
        self.scheduler = scheduler
        self.runner = runner
        self.coordinator = coordinator
        self.runInputProvider = runInputProvider
        self.model = model
    }

    @discardableResult
    func startIfNeeded() -> Bool {
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
        // Collector 轮换的新令牌写回 Keychain, 保证下次刷新用有效令牌.
        scheduler.onCredentialUpdates = { [runInputProvider] _, updates in
            runInputProvider.apply(credentialUpdates: updates)
        }
        // 后台刷新发现 5h 额度新跨越 80% 阈值时弹系统通知.
        scheduler.onQuotaAlerts = { [quotaAlertNotifier] _, alerts in
            quotaAlertNotifier.deliver(alerts)
        }
        // 外观偏好应用级生效: SwiftUI preferredColorScheme 只影响环境,
        // 玻璃与 material 的真实配色由窗口 appearance 驱动.
        applyAppearance(coordinator.appearanceMode)
        appearanceObserver = coordinator.$appearanceMode.sink { [weak self] mode in
            self?.applyAppearance(mode)
        }
        runtime.configure(scheduler: scheduler, runner: runner)
        runtime.startSchedulerIfNeeded()
        coordinator.scanAndReconcile()
        return true
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

    func present() {
        let window = window ?? makeWindow()
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

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
}
