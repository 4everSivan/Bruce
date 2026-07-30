import AppKit
import MdddAppCore
import MdddOnboardingCore
import SwiftUI

@main
struct MdddApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var coordinator: OnboardingCoordinator
    @StateObject private var diagnostics: DiagnosticService
    private let runtime: AppRuntime
    private let scheduler: RefreshScheduler
    private let runner: CollectorRunner

    init() {
        let pythonURL = URL(fileURLWithPath: "/usr/bin/python3")
        let bridgeURL = MdddApp.resolveBridgeURL()
            ?? URL(fileURLWithPath: "bridge/run_bridge.py")
        let runner = CollectorRunner(pythonURL: pythonURL, bridgeURL: bridgeURL)
        self.runner = runner
        let store = (try? ArtifactStore())
            ?? (try? ArtifactStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("mddd-fallback")
            ))
        let resolvedStore = store ?? (try! ArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("mddd-fallback")
        ))
        // 配置与凭证存储在 Scheduler 输入提供器和 Coordinator 之间共享同一实例
        let configStore = try? OnboardingConfigurationStore()
        let credentialStore = KeychainCredentialStore()
        let runInputProvider = OnboardingRunInputProvider(
            configStore: configStore,
            credentialStore: credentialStore
        )
        let scheduler = RefreshScheduler(
            executor: runner, store: resolvedStore,
            runInputProvider: runInputProvider
        )
        self.scheduler = scheduler

        // 单一 AppModel: UI 和 Coordinator 共享同一实例
        let model = AppModel()
        let runtime = AppRuntime()
        self.runtime = runtime
        _model = StateObject(wrappedValue: model)
        let coordinator = OnboardingCoordinator(
            scheduler: scheduler,
            model: model,
            runtime: runtime,
            configStore: configStore,
            credentialStore: credentialStore
        )
        _coordinator = StateObject(wrappedValue: coordinator)
        _diagnostics = StateObject(wrappedValue: DiagnosticService(
            model: model,
            scheduler: scheduler,
            store: resolvedStore
        ))
    }

    var body: some Scene {
        Window("mddd", id: MainWindow.identifier.rawValue) {
            DashboardView()
                .environmentObject(model)
                .environmentObject(coordinator)
                .environmentObject(diagnostics)
                .background(MainWindowRegistration())
                .onAppear {
                    wireScheduler()
                    appDelegate.configure(runtime: runtime)
                    runtime.startSchedulerIfNeeded()
                    coordinator.scanAndReconcile()
                    appDelegate.setDockBadge(model.dockBadgeState)
                }
                .onReceive(model.$dockBadgeState) { state in
                    appDelegate.setDockBadge(state)
                }
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }

    private func wireScheduler() {
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
    }

    private static func resolveBridgeURL() -> URL? {
        let executable = CommandLine.arguments[0]
        var current = URL(fileURLWithPath: executable)
            .deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = current.appendingPathComponent("bridge/run_bridge.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            current = current.deletingLastPathComponent()
        }
        let cwdCandidate = URL(fileURLWithPath: "bridge/run_bridge.py")
        if FileManager.default.fileExists(atPath: cwdCandidate.path) {
            return cwdCandidate
        }
        return nil
    }
}
