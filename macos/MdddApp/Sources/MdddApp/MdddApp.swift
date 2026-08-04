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
    private let bootstrap: ApplicationBootstrap
    private let settingsWindowController: SettingsWindowController

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
        // Codex v2: 单一 store / OAuth client / token manager, 供登录、
        // 运行输入提供器和 Coordinator 共享 (任务 5 装配).
        let codexStore = CodexCredentialStore(store: credentialStore)
        let codexTokenManager = CodexTokenManager(
            store: codexStore,
            client: CodexOAuthClient.defaultClient()
        )
        let runInputProvider = OnboardingRunInputProvider(
            configStore: configStore,
            credentialStore: credentialStore,
            codexTokenInjector: codexTokenManager,
            codexStore: codexStore
        )
        let scheduler = RefreshScheduler(
            executor: runner, store: resolvedStore,
            runInputProvider: runInputProvider
        )
        // 任务 9: 把 Codex token manager 挂到 Scheduler, 支持
        // quota 401 定向重试自愈 (强制刷新被挑战账号).
        scheduler.codexTokenManager = codexTokenManager
        self.scheduler = scheduler

        // DeepSeek 月度账本: 基于 ArtifactStore 根目录隔离存储.
        // 生产使用公历 + 设备当前时区 (不受用户历法偏好影响).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let ledger = DeepSeekUsageLedger(
            rootURL: resolvedStore.rootURL,
            calendar: calendar
        )

        // 单一 AppModel: UI 和 Coordinator 共享同一实例
        let model = AppModel(deepSeekLedger: ledger)
        let runtime = AppRuntime()
        self.runtime = runtime
        _model = StateObject(wrappedValue: model)
        let coordinator = OnboardingCoordinator(
            scheduler: scheduler,
            model: model,
            runtime: runtime,
            configStore: configStore,
            credentialStore: credentialStore,
            codexStore: codexStore,
            codexTokenManager: codexTokenManager
        )
        _coordinator = StateObject(wrappedValue: coordinator)
        let diagnostics = DiagnosticService(
            model: model,
            scheduler: scheduler,
            store: resolvedStore
        )
        _diagnostics = StateObject(wrappedValue: diagnostics)
        bootstrap = ApplicationBootstrap(
            runtime: runtime,
            scheduler: scheduler,
            runner: runner,
            coordinator: coordinator,
            runInputProvider: runInputProvider,
            codexTokenManager: codexTokenManager,
            model: model,
            codexMigration: codexStore
        )
        settingsWindowController = SettingsWindowController(
            model: model,
            coordinator: coordinator,
            diagnostics: diagnostics
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDashboardView(
                openSettings: {
                    settingsWindowController.present()
                },
                terminateApplication: {
                    NSApplication.shared.terminate(nil)
                }
            )
                .environmentObject(model)
                .environmentObject(coordinator)
        } label: {
            MenuBarLabelView(model: model)
                .onAppear {
                    startApplicationIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }

    private func startApplicationIfNeeded() {
        appDelegate.configure(runtime: runtime)
        Task { @MainActor in
            let didStart = await bootstrap.startIfNeeded()
            if didStart, !coordinator.consentConfirmed {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    settingsWindowController.present()
                }
            }
        }
    }

    private static func resolveBridgeURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let packagedBridge = resourceURL
                .appendingPathComponent("runtime")
                .appendingPathComponent("bridge")
                .appendingPathComponent("run_bridge.py")
            if FileManager.default.fileExists(atPath: packagedBridge.path) {
                return packagedBridge
            }
        }

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
