import AppKit
import MdddAppCore
import SwiftUI

@MainActor
final class ApplicationBootstrap {
    private let runtime: AppRuntime
    private let scheduler: RefreshScheduler
    private let runner: CollectorRunner
    private let coordinator: OnboardingCoordinator
    private weak var model: AppModel?
    private var started = false

    init(
        runtime: AppRuntime,
        scheduler: RefreshScheduler,
        runner: CollectorRunner,
        coordinator: OnboardingCoordinator,
        model: AppModel
    ) {
        self.runtime = runtime
        self.scheduler = scheduler
        self.runner = runner
        self.coordinator = coordinator
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
        runtime.configure(scheduler: scheduler, runner: runner)
        runtime.startSchedulerIfNeeded()
        coordinator.scanAndReconcile()
        return true
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
