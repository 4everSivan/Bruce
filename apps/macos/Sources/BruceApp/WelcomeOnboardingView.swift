import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - WelcomeWindowController (10-首次启动欢迎与引导向导 §4.2 R2/R6)

/// 独立欢迎向导窗口控制器:
/// - 锁定方案 A 尺寸 780 × 540, 单实例防重;
/// - 打开期间启用 Regular 激活策略显示 Dock 图标与主菜单;
/// - 完成向导后自动关闭并触发 `onCompleteOpenDashboard` 展开菜单栏看板.
@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let coordinator: OnboardingCoordinator
    private let onCompleteOpenDashboard: @MainActor () -> Void
    private let onOpenSubscriptionSettings: @MainActor (SubscriptionProviderID?) -> Void
    private let isSettingsWindowVisible: @MainActor () -> Bool
    private var window: NSWindow?
    private var isDockPresentationActive = false

    static let contentWidth: CGFloat = 780
    static let contentHeight: CGFloat = 540

    var managedWindow: NSWindow? { window }

    init(
        model: AppModel,
        coordinator: OnboardingCoordinator,
        onCompleteOpenDashboard: @escaping @MainActor () -> Void,
        onOpenSubscriptionSettings: @escaping @MainActor (SubscriptionProviderID?) -> Void,
        isSettingsWindowVisible: @escaping @MainActor () -> Bool = { false }
    ) {
        self.model = model
        self.coordinator = coordinator
        self.onCompleteOpenDashboard = onCompleteOpenDashboard
        self.onOpenSubscriptionSettings = onOpenSubscriptionSettings
        self.isSettingsWindowVisible = isSettingsWindowVisible
        super.init()
    }

    /// 打开或前置欢迎向导窗口.
    func present() {
        coordinator.refreshOfficialLocalAvailability()
        coordinator.rescan()
        let window = window ?? makeWindow()
        setDockIconVisible(true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// 关闭欢迎窗口并在下一拍触发菜单栏看板展开.
    func dismissAndOpenDashboard() {
        window?.close()
        DispatchQueue.main.async { [onCompleteOpenDashboard] in
            onCompleteOpenDashboard()
        }
    }

    func handleDockReopen() {
        guard isDockPresentationActive else { return }
        present()
    }

    func windowWillClose(_ notification: Notification) {
        if !isSettingsWindowVisible() {
            setDockIconVisible(false)
        }
    }

    private func setDockIconVisible(_ visible: Bool) {
        guard isDockPresentationActive != visible else { return }
        isDockPresentationActive = visible
        if visible {
            _ = NSApp.setActivationPolicy(.regular)
        } else if !isSettingsWindowVisible() {
            _ = NSApp.setActivationPolicy(.accessory)
        }
    }

    private func makeWindow() -> NSWindow {
        let rootView = WelcomeOnboardingView(
            onFinish: { [weak self] in
                self?.dismissAndOpenDashboard()
            },
            onOpenProviderSettings: { [weak self] provider in
                self?.window?.close()
                self?.onOpenSubscriptionSettings(provider)
            }
        )
        .environmentObject(model)
        .environmentObject(coordinator)
        .frame(
            width: Self.contentWidth,
            height: Self.contentHeight
        )

        let window = WelcomeHostWindow(
            contentViewController: NSHostingController(
                rootView: MotionEnvironmentRoot(
                    coordinator: coordinator,
                    content: rootView
                )
            )
        )
        window.title = WelcomeCopy.windowTitle
        window.styleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .fullSizeContentView,
        ]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(
            width: Self.contentWidth,
            height: Self.contentHeight
        ))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("Bruce.WelcomeWindow")
        window.delegate = self
        window.center()
        self.window = window
        return window
    }
}

private final class WelcomeHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - WelcomeOnboardingView (方案 A · 780 × 540 双栏沉浸式向导)

struct WelcomeOnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.motionSuppressed) private var motionSuppressed

    let onFinish: () -> Void
    let onOpenProviderSettings: (SubscriptionProviderID?) -> Void

    @State private var currentStep: WelcomeWizardStep = .environmentScan
    @State private var importedSources: Set<String> = []

    private static let sidebarWidth: CGFloat = 224
    private static let defaultHotkey = GlobalHotkey(
        keyCode: 11,
        modifiers: [.command, .shift]
    )

    var body: some View {
        HStack(spacing: 0) {
            sidebarRail
                .frame(width: Self.sidebarWidth)
                .frame(maxHeight: .infinity)
                .background(SettingsDemoTokens.nav)

            Rectangle()
                .fill(SettingsDemoTokens.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        switch currentStep {
                        case .environmentScan:
                            step1EnvironmentView
                        case .subscriptionConnect:
                            step2SubscriptionView
                        case .appearanceAndShortcut:
                            step3AppearanceView
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 26)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Rectangle()
                    .fill(SettingsDemoTokens.separator)
                    .frame(height: 1)

                bottomActionBar
                    .padding(.horizontal, 28)
                    .padding(.vertical, 13)
                    .background(SettingsDemoTokens.nav.opacity(0.65))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsDemoTokens.window)
        }
        .preferredColorScheme(coordinator.appearanceMode.colorScheme)
        .environment(\.BruceResolvedTheme, coordinator.resolvedTheme)
    }

    // MARK: - 左侧品牌与三步导航栏 (224pt)

    private var sidebarRail: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 顶部品牌区: 真实项目比格犬图标 + Bruce + 版本
            HStack(spacing: 11) {
                appIconView
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bruce")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Text("\(AppVersion.current()) · \(WelcomeCopy.brandSubtitle)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
            .padding(.top, 30)

            // 三步垂直导航轨
            VStack(alignment: .leading, spacing: 6) {
                ForEach(WelcomeWizardStep.allCases, id: \.rawValue) { step in
                    stepRailButton(step)
                }
            }

            Spacer(minLength: 8)

            // 底部 100% 本地只读隐私承诺卡
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 11.5))
                    Text(WelcomeCopy.privacyTitle)
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(SettingsDemoTokens.ok)

                Text(WelcomeCopy.privacyBody)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(1.5)
            }
            .padding(11)
            .background(
                SettingsDemoTokens.ok.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(SettingsDemoTokens.ok.opacity(0.22), lineWidth: 1)
            )
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var appIconView: some View {
        if let nsImage = Self.loadProjectAppIcon() {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 6, y: 3)
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(SettingsDemoTokens.accent.opacity(0.18))
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.accent)
                )
        }
    }

    private static func loadProjectAppIcon() -> NSImage? {
        if let resourceURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: resourceURL) {
            return image
        }
        if let appImage = NSApp.applicationIconImage {
            return appImage
        }
        return nil
    }

    private func stepRailButton(_ step: WelcomeWizardStep) -> some View {
        let isActive = currentStep == step
        let isDone = step.rawValue < currentStep.rawValue
            || (step == .environmentScan && coordinator.consentConfirmed && coordinator.keychainAccessConfigured)

        return Button {
            withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.16)) {
                currentStep = step
            }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            isActive
                                ? SettingsDemoTokens.accent
                                : isDone
                                    ? SettingsDemoTokens.ok.opacity(0.18)
                                    : SettingsDemoTokens.surfaceHover
                        )
                    Circle()
                        .strokeBorder(
                            isActive
                                ? SettingsDemoTokens.accent
                                : isDone
                                    ? SettingsDemoTokens.ok.opacity(0.45)
                                    : SettingsDemoTokens.separator,
                            lineWidth: 1
                        )
                    Text(isDone && !isActive ? "✓" : "\(step.rawValue)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            isActive
                                ? Color.white
                                : isDone
                                    ? SettingsDemoTokens.ok
                                    : SettingsDemoTokens.text3
                        )
                }
                .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(step.navTitle)
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(
                            isActive
                                ? SettingsDemoTokens.text
                                : isDone
                                    ? SettingsDemoTokens.text2
                                    : SettingsDemoTokens.text3
                        )
                    Text(step.navSubtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsDemoTokens.text3)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isActive ? SettingsDemoTokens.accent.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isActive ? SettingsDemoTokens.accent.opacity(0.32) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 1: 环境扫描与双门禁合并启用

    private var step1EnvironmentView: some View {
        let probes = resolvedLocalProbes
        let readyCount = probes.filter { $0.status == .available }.count

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(WelcomeCopy.step1Eyebrow)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(SettingsDemoTokens.accent)
                Text(WelcomeCopy.step1Title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(WelcomeCopy.step1Description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(WelcomeCopy.step1SectionTitle)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text2)
                Spacer()
                HStack(spacing: 8) {
                    Text(WelcomeOnboardingPresentation.readySourcesSummary(readyCount: readyCount))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(readyCount > 0 ? SettingsDemoTokens.ok : SettingsDemoTokens.text2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            (readyCount > 0 ? SettingsDemoTokens.ok : SettingsDemoTokens.text3).opacity(0.14),
                            in: Capsule()
                        )
                    Button(WelcomeCopy.step1RescanButton) {
                        coordinator.rescan()
                    }
                    .fluentButton()
                }
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 7
            ) {
                ForEach(Array(probes.enumerated()), id: \.offset) { _, probe in
                    probeTile(probe)
                }
            }

            // 双门禁合并说明卡
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(SettingsDemoTokens.accent.opacity(0.16))
                        .frame(width: 26, height: 26)
                    Image(systemName: "bolt.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(WelcomeCopy.step1ConsentTitle)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Text(WelcomeCopy.step1ConsentBody)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(1.5)
                }
            }
            .padding(12)
            .background(
                SettingsDemoTokens.accent.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsDemoTokens.accent.opacity(0.28), lineWidth: 1)
            )
        }
    }

    private var resolvedLocalProbes: [DependencyProbe] {
        if let existing = model.moduleResults[.agentUsage]?.localDependencies,
           !existing.isEmpty {
            return existing
        }
        return [
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Claude Code"),
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Codex CLI"),
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "Kimi Code CLI"),
            DependencyProbe(kind: .sessionDirectory, status: .available, detail: "OpenCode"),
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "ZCode"),
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "CodeBuddy"),
            DependencyProbe(kind: .sessionDirectory, status: .missing, detail: "Pi"),
            DependencyProbe(kind: .sqliteDatabase, status: .available, detail: SQLiteSchemaProfile.ccSwitch.displayName),
        ]
    }

    private func probeTile(_ probe: DependencyProbe) -> some View {
        let name = probe.detail ?? "会话源"
        let isReady = probe.status == .available
        let agentMeta = Self.agentMeta(forDisplayName: name)

        return HStack(spacing: 9) {
            if let agentID = agentMeta.agentID {
                AgentBrandBadge(
                    asset: AgentBrandPalette.asset(forAgent: agentID),
                    seriesHex: agentMeta.colorHex,
                    size: 24,
                    followsTheme: false,
                    fallbackMonogram: String(name.prefix(1)).uppercased()
                )
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(hex: "#0EA5E9"))
                    .frame(width: 24, height: 24)
                    .overlay(
                        Text("CC")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    )
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                    .lineLimit(1)
                Text(agentMeta.subtitle)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                if isReady {
                    FluentStatusDot(level: .ok)
                }
                Text(isReady ? "就绪" : "未安装")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(isReady ? SettingsDemoTokens.ok : SettingsDemoTokens.text3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            SettingsDemoTokens.surface,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isReady ? SettingsDemoTokens.ok.opacity(0.28) : SettingsDemoTokens.separator,
                    lineWidth: 1
                )
        )
        .opacity(isReady ? 1.0 : 0.65)
    }

    private static func agentMeta(
        forDisplayName name: String
    ) -> (agentID: String?, colorHex: String, subtitle: String) {
        switch name {
        case "Claude Code":
            return ("claude-code", "#D97757", "~/.claude/projects")
        case "Codex CLI":
            return ("codex", "#10A37F", "~/.codex/sessions")
        case "Kimi Code CLI":
            return ("kimi-code-cli", "#4C9CFF", "~/.kimi-code/sessions")
        case "Kimi Work":
            return ("kimi-work", "#4C9CFF", "Application Support/kimi-desktop")
        case "OpenCode":
            return ("opencode", "#A855F7", "opencode.db (mode=ro)")
        case "ZCode":
            return ("zcode", "#6366F1", "~/.zcode/cli/db")
        case "CodeBuddy":
            return ("codebuddy", "#5B3DF5", "~/.codebuddy/projects")
        case "Pi":
            return ("pi", "#EC4899", "~/.pi/agent/sessions")
        default:
            return (nil, "#0EA5E9", "~/.cc-switch/cc-switch.db (mode=ro)")
        }
    }

    // MARK: - Step 2: 订阅额度快速连接 (可选)

    private struct DiscoveredLocalCredential: Identifiable {
        let id: String
        let provider: SubscriptionProviderID
        let title: String
        let subtitle: String
        let action: @MainActor () -> Void
    }

    private var discoveredCredentials: [DiscoveredLocalCredential] {
        var items: [DiscoveredLocalCredential] = []
        if coordinator.codexCLIAuthFileExists() {
            items.append(DiscoveredLocalCredential(
                id: "codex-cli",
                provider: .codex,
                title: "ChatGPT / Codex CLI",
                subtitle: "检测到 ~/.codex/auth.json 登录态",
                action: { coordinator.importCodexFromLocalCLI() }
            ))
        } else if coordinator.codexCCAccountsFileExists() {
            items.append(DiscoveredLocalCredential(
                id: "codex-cc",
                provider: .codex,
                title: "Codex (CC Switch 账号池)",
                subtitle: "检测到本机 CC Switch Codex 凭据",
                action: { coordinator.importCodexFromCCSwitch() }
            ))
        }
        if model.claudeLocalAvailable {
            items.append(DiscoveredLocalCredential(
                id: "claude-local",
                provider: .claude,
                title: "Claude Code CLI",
                subtitle: "检测到本机 Claude OAuth 凭据 (静默只读)",
                action: { coordinator.importClaudeFromLocal() }
            ))
        }
        if model.grokLocalAvailable {
            items.append(DiscoveredLocalCredential(
                id: "grok-local",
                provider: .grok,
                title: "Grok CLI",
                subtitle: "检测到本机 ~/.grok 登录凭据",
                action: { coordinator.importGrokFromLocal() }
            ))
        }
        if coordinator.ccSwitchDatabaseExists() {
            items.append(DiscoveredLocalCredential(
                id: "volcengine-cc",
                provider: .volcengine,
                title: "火山引擎 (CC Switch)",
                subtitle: "检测到 ~/.cc-switch/cc-switch.db 凭据",
                action: { coordinator.importVolcengineFromCCSwitch() }
            ))
        }
        return items
    }

    private var step2SubscriptionView: some View {
        let discovered = discoveredCredentials
        let providers = SubscriptionProviderID.allCases.filter { $0 != .jev }

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(WelcomeCopy.step2Eyebrow)
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(SettingsDemoTokens.accent)
                    Text(WelcomeCopy.step2OptionalBadge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.warn)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(SettingsDemoTokens.warn.opacity(0.14), in: Capsule())
                }
                Text(WelcomeCopy.step2Title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(WelcomeCopy.step2Description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !discovered.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(WelcomeCopy.step2DiscoveryTitle)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.ok)

                    ForEach(discovered) { item in
                        let isConfigured = (model.subscriptionCredentialConfigured[item.provider] ?? false)
                            || importedSources.contains(item.id)
                        HStack(spacing: 10) {
                            ProviderBrandBadge(
                                providerID: item.provider.rawValue,
                                name: item.provider.displayName,
                                size: 26
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(SettingsDemoTokens.text)
                                Text(item.subtitle)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(SettingsDemoTokens.text2)
                            }
                            Spacer()
                            if isConfigured {
                                Text(WelcomeCopy.step2ImportedBadge)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(SettingsDemoTokens.ok)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(SettingsDemoTokens.ok.opacity(0.14), in: Capsule())
                            } else {
                                Button(WelcomeCopy.step2ImportButton) {
                                    importedSources.insert(item.id)
                                    item.action()
                                }
                                .fluentButton(.primary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            SettingsDemoTokens.surface,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(SettingsDemoTokens.ok.opacity(0.28), lineWidth: 1)
                        )
                    }
                }
                .padding(11)
                .background(
                    SettingsDemoTokens.ok.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(SettingsDemoTokens.ok.opacity(0.24), lineWidth: 1)
                )
            }

            Text(WelcomeCopy.step2ProvidersSectionTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SettingsDemoTokens.text2)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 7
            ) {
                ForEach(providers, id: \.rawValue) { provider in
                    providerQuickTile(provider)
                }
            }
        }
    }

    private func providerQuickTile(_ provider: SubscriptionProviderID) -> some View {
        let isConfigured = model.subscriptionCredentialConfigured[provider] ?? false
        let isVerified = model.subscriptionProviders[provider]?.verificationStatus == .ok

        return HStack(spacing: 9) {
            ProviderBrandBadge(
                providerID: provider.rawValue,
                name: provider.displayName,
                size: 24
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                    .lineLimit(1)
                Text(Self.providerAuthSubtitle(for: provider))
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsDemoTokens.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isConfigured || isVerified {
                HStack(spacing: 4) {
                    FluentStatusDot(level: .ok)
                    Text("已连接")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.ok)
                }
            } else {
                Button("去配置") {
                    coordinator.addSubscriptionProvider(provider)
                    onOpenProviderSettings(provider)
                }
                .fluentButton()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            SettingsDemoTokens.surface,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    (isConfigured || isVerified)
                        ? SettingsDemoTokens.ok.opacity(0.32)
                        : SettingsDemoTokens.separator,
                    lineWidth: 1
                )
        )
    }

    private static func providerAuthSubtitle(for id: SubscriptionProviderID) -> String {
        switch id {
        case .codex: return "本机 CLI / OAuth 设备码"
        case .claude: return "本机 CLI / OAuth 令牌"
        case .kimi: return "API Key · 5h + 周限额"
        case .deepseek: return "API Key · 实时余额"
        case .zhipu: return "API Key · GLM Coding"
        case .volcengine: return "AK/SK 或 CC Switch"
        case .stepfun: return "网页登录或 API Key"
        case .opencodeGo: return "OAuth JSON 凭据"
        case .grok: return "本机 CLI / OAuth"
        case .cline: return "Bearer 令牌 · 三窗口"
        case .jev: return "API Key"
        }
    }

    // MARK: - Step 3: 外观与快捷唤出

    private var step3AppearanceView: some View {
        let isNothing = coordinator.resolvedTheme.interfaceStyle == .nothing
        let previewMetrics = WelcomeOnboardingPresentation.menuBarPreviewMetricsText(
            isNothingTheme: isNothing,
            iconOnly: coordinator.menuBarIconOnly
        )
        let glassSupported = coordinator.liquidGlassSupported()

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(WelcomeCopy.step3Eyebrow)
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(SettingsDemoTokens.accent)
                Text(WelcomeCopy.step3Title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(WelcomeCopy.step3Description)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 菜单栏双同心子母环实时预览卡
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("macOS 菜单栏预览")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    Spacer()
                    Image(systemName: "wifi")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.65))
                    HStack(spacing: 7) {
                        dualRingPreviewGauge
                        if !previewMetrics.isEmpty {
                            Text(previewMetrics)
                                .font(.system(
                                    size: isNothing ? 12.5 : 12,
                                    weight: .semibold,
                                    design: .monospaced
                                ))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Color.white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(SettingsDemoTokens.accent.opacity(0.55), lineWidth: 1)
                    )
                    Text("周一 15:18")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#1A2236"), Color(hex: "#0F1420")],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

                HStack(spacing: 8) {
                    ringLegendPill(
                        color: SettingsDemoTokens.ok,
                        title: WelcomeCopy.step3RingOuterTitle,
                        subtitle: WelcomeCopy.step3RingOuterSubtitle
                    )
                    ringLegendPill(
                        color: SettingsDemoTokens.warn,
                        title: WelcomeCopy.step3RingInnerTitle,
                        subtitle: WelcomeCopy.step3RingInnerSubtitle
                    )
                }
            }
            .padding(11)
            .background(
                SettingsDemoTokens.surface,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
            )

            // 界面风格三选一
            VStack(alignment: .leading, spacing: 6) {
                Text("界面风格（即时生效）")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text2)
                HStack(spacing: 8) {
                    styleOptionTile(
                        title: "经典材质",
                        subtitle: "高对比毛玻璃暗色卡片",
                        selected: coordinator.interfaceStyle == .classic,
                        enabled: true
                    ) {
                        coordinator.setInterfaceStyle(.classic)
                    }
                    styleOptionTile(
                        title: "液态玻璃",
                        subtitle: glassSupported ? "macOS 26 原生通透折射" : "需 macOS 26+",
                        selected: coordinator.interfaceStyle == .liquidGlass,
                        enabled: glassSupported
                    ) {
                        coordinator.setInterfaceStyle(.liquidGlass)
                    }
                    styleOptionTile(
                        title: "Nothing 点阵",
                        subtitle: "纯黑工业点阵 + 12.5pt 等宽",
                        selected: coordinator.interfaceStyle == .nothing,
                        enabled: true
                    ) {
                        coordinator.setInterfaceStyle(.nothing)
                    }
                }
            }

            // 看板卡片布局二选一
            VStack(alignment: .leading, spacing: 6) {
                Text("看板卡片布局")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text2)
                HStack(spacing: 8) {
                    styleOptionTile(
                        title: "纵向级联 (Stack)",
                        subtitle: "一屏上下纵览用量、订阅与小时趋势",
                        selected: model.layoutMode == .stack,
                        enabled: true
                    ) {
                        model.setLayoutMode(.stack)
                    }
                    styleOptionTile(
                        title: "顶栏单卡切换 (Tabbed)",
                        subtitle: "紧凑单卡高度，顶部图标秒切",
                        selected: model.layoutMode == .tabbed,
                        enabled: true
                    ) {
                        model.setLayoutMode(.tabbed)
                    }
                }
            }

            // 快捷偏好行: 纯图标模式 + 全局快捷键
            HStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("仅显示双环图标")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("隐藏菜单栏百分比与金额文字")
                            .font(.system(size: 10.5))
                            .foregroundStyle(SettingsDemoTokens.text3)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { coordinator.menuBarIconOnly },
                            set: { coordinator.setMenuBarIconOnly($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    SettingsDemoTokens.surface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
                )

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("全局唤出热键")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text(coordinator.dashboardHotkey?.displayString ?? "未设置")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.accent)
                    }
                    Spacer()
                    if coordinator.dashboardHotkey == nil {
                        Button("设为 ⌘⇧B") {
                            coordinator.setDashboardHotkey(Self.defaultHotkey)
                        }
                        .fluentButton()
                    } else {
                        Button("清除") {
                            coordinator.setDashboardHotkey(nil)
                        }
                        .fluentButton()
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(
                    SettingsDemoTokens.surface,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
                )
            }
        }
    }

    private var dualRingPreviewGauge: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1.8)
                .frame(width: 15, height: 15)
            Circle()
                .trim(from: 0, to: 0.76)
                .stroke(
                    SettingsDemoTokens.ok,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 15, height: 15)
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 1.5)
                .frame(width: 8.5, height: 8.5)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(
                    SettingsDemoTokens.warn,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 8.5, height: 8.5)
        }
        .frame(width: 16, height: 16)
    }

    private func ringLegendPill(
        color: Color,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsDemoTokens.bg.opacity(0.6),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
    }

    private func styleOptionTile(
        title: String,
        subtitle: String,
        selected: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(SettingsDemoTokens.accent)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? SettingsDemoTokens.accent.opacity(0.12) : SettingsDemoTokens.surface,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        selected ? SettingsDemoTokens.accent : SettingsDemoTokens.separator,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.45)
    }

    // MARK: - 底部固定操作栏

    @ViewBuilder
    private var bottomActionBar: some View {
        switch currentStep {
        case .environmentScan:
            HStack {
                HStack(spacing: 6) {
                    FluentStatusDot(level: .ok)
                    Text("100% 本地只读 · 零系统密码框打扰")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }
                Spacer()
                Button(WelcomeCopy.step1PrimaryButton) {
                    _ = coordinator.completeWelcomeStep1()
                    coordinator.refreshOfficialLocalAvailability()
                    withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.18)) {
                        currentStep = .subscriptionConnect
                    }
                }
                .fluentButton(.primary)
                .keyboardShortcut(.defaultAction)
            }

        case .subscriptionConnect:
            HStack {
                Button(WelcomeCopy.step2BackButton) {
                    withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.18)) {
                        currentStep = .environmentScan
                    }
                }
                .fluentButton()
                Spacer()
                HStack(spacing: 8) {
                    Button(WelcomeCopy.step2SkipButton) {
                        withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.18)) {
                            currentStep = .appearanceAndShortcut
                        }
                    }
                    .fluentButton()
                    Button(WelcomeCopy.step2NextButton) {
                        withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.18)) {
                            currentStep = .appearanceAndShortcut
                        }
                    }
                    .fluentButton(.primary)
                    .keyboardShortcut(.defaultAction)
                }
            }

        case .appearanceAndShortcut:
            HStack {
                Button(WelcomeCopy.step2BackButton) {
                    withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.18)) {
                        currentStep = .subscriptionConnect
                    }
                }
                .fluentButton()
                Spacer()
                Button(WelcomeCopy.step3FinishButton) {
                    _ = coordinator.completeWelcomeWizard()
                    onFinish()
                }
                .fluentButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
