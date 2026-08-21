import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

@main
struct BruceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var coordinator: OnboardingCoordinator
    @StateObject private var diagnostics: DiagnosticService
    private let runtime: AppRuntime
    private let scheduler: RefreshScheduler
    private let runner: CollectorExecutable & CollectorRuntimeControlling
    private let bootstrap: ApplicationBootstrap
    private let settingsWindowController: SettingsWindowController
    private let statusItemController: MenuBarStatusItemController
    private let hotkeyMonitor: GlobalHotkeyMonitor

    init() {
        let configStore = try? OnboardingConfigurationStore()
        let rustURL = Self.resolveRustCollectorURL()
        let collectorRuntime: CollectorRuntimeStatus
        if rustURL != nil {
            collectorRuntime = .rustAvailable
        } else {
            #if DEBUG
            collectorRuntime = .pythonPreview
            #else
            collectorRuntime = .rustUnavailable
            #endif
        }
        let runner: CollectorExecutable & CollectorRuntimeControlling
        if let rustURL {
            runner = RustBinaryAdapter(executableURL: rustURL)
        } else {
            #if DEBUG
            // Preview-only compatibility path. Release never falls back to Python.
            let configuredPath = configStore?.load()?.pythonPath
            let pythonPath = (configuredPath?.isEmpty == false)
                ? configuredPath!
                : "/usr/bin/python3"
            let pythonURL = URL(fileURLWithPath: pythonPath)
            let bridgeURL = BruceApp.resolveBridgeURL()
                ?? URL(fileURLWithPath: "bridge/run_bridge.py")
            runner = PythonPreviewAdapter(
                pythonURL: pythonURL,
                bridgeURL: bridgeURL
            )
            #else
            runner = UnavailableCollectorAdapter()
            #endif
        }
        self.runner = runner
        let store = (try? ArtifactStore())
            ?? (try? ArtifactStore(
                rootURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("Bruce-fallback")
            ))
        let resolvedStore = store ?? (try! ArtifactStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Bruce-fallback")
        ))
        // 配置与凭证存储在 Scheduler 输入提供器和 Coordinator 之间共享同一实例
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
        // 与 runInputProvider 共享同一 Keychain 实例, 保证轮换写回与注入一致.
        let credentialUpdateCoordinator = CredentialUpdateCoordinator(
            credentialStore: credentialStore
        )
        let scheduler = RefreshScheduler(
            executor: runner, store: resolvedStore,
            runInputProvider: runInputProvider,
            credentialUpdateCoordinator: credentialUpdateCoordinator
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
            codexTokenManager: codexTokenManager,
            collectorRuntime: collectorRuntime
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
        let settingsController = SettingsWindowController(
            model: model,
            coordinator: coordinator,
            diagnostics: diagnostics
        )
        self.settingsWindowController = settingsController
        let statusController = MenuBarStatusItemController(
            model: model,
            coordinator: coordinator,
            openSettings: { [settingsController] in
                settingsController.present()
            },
            terminateApplication: {
                NSApplication.shared.terminate(nil)
            }
        )
        self.statusItemController = statusController
        let monitor = GlobalHotkeyMonitor(
            onPress: { [weak statusController] in
                statusController?.toggleDashboard()
            },
            onRegistrationFailure: { [weak model] message in
                model?.setSettingsError(message)
            }
        )
        self.hotkeyMonitor = monitor
        coordinator.setHotkeyMonitor(monitor)
        startApplicationIfNeeded()
    }

    var body: some Scene {
        // 状态项与弹出面板由 AppDelegate 自管理; 无可见 SwiftUI 场景.
        // Settings 场景仅作 SwiftUI App 必需锚点, 移除其菜单项避免空窗口入口.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }

    private func startApplicationIfNeeded() {
        appDelegate.configure(
            runtime: runtime,
            settingsWindowController: settingsWindowController,
            statusItemController: statusItemController,
            hotkeyMonitor: hotkeyMonitor,
            startApplication: {
                Task { @MainActor in
                    let didStart = await bootstrap.startIfNeeded()
                    if didStart, !coordinator.consentConfirmed {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            settingsWindowController.present()
                        }
                    }
                }
            }
        )
    }

    #if DEBUG
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
    #endif

    private static func resolveRustCollectorURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["BRUCE_COLLECTOR_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        if let resourceURL = Bundle.main.resourceURL {
            let packaged = resourceURL.appendingPathComponent("Bruce-collector")
            if FileManager.default.isExecutableFile(atPath: packaged.path) {
                return packaged
            }
        }
        #if DEBUG
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        var current = executable.deletingLastPathComponent()
        for _ in 0..<10 {
            for relativePath in [
                "rust/Bruce-collector/target/debug/Bruce-collector",
                "rust/Bruce-collector/target/release/Bruce-collector"
            ] {
                let candidate = current.appendingPathComponent(relativePath)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
            current = current.deletingLastPathComponent()
        }
        #endif
        return nil
    }
}
