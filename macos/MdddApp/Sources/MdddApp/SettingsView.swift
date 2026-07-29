import AppKit
import MdddOnboardingCore
import SwiftUI

/// Onboarding 设置页: 三张模块状态卡 + 统一授权区.
/// 状态同时使用图标和文字; 扫描或验证中的卡片只禁用对应按钮, 不阻塞其他模块.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @State private var gitlabBaseURLText = ""
    @State private var gitlabPATText = ""
    @FocusState private var patFieldFocused: Bool

    var body: some View {
        Form {
            if let error = model.settingsErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("设置错误: \(error)")
                }
            }

            appearanceSection
            agentUsageCard
            githubCard
            gitlabCard
            consentSection
        }
        .formStyle(.grouped)
        .onAppear {
            if gitlabBaseURLText.isEmpty {
                gitlabBaseURLText = coordinator.configuredGitLabBaseURL ?? ""
            }
        }
    }

    // MARK: - 外观区

    /// 主题手动切换: 选择经 coordinator.setTheme 持久化, 保存失败时
    /// model.theme 不变, Picker 自动回退到当前主题 (fail-closed).
    private var appearanceSection: some View {
        Section("外观") {
            Picker("主题", selection: themeBinding) {
                Text(AppTheme.classic.title).tag(AppTheme.classic)
                if GlassTheme.isLiquidGlassAvailable {
                    Text(AppTheme.liquidGlass.title).tag(AppTheme.liquidGlass)
                }
            }
            if !GlassTheme.isLiquidGlassAvailable {
                Text("液态玻璃需要 macOS 26 或更高版本")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .glassFormRowBackground(theme: model.theme)
    }

    private var themeBinding: Binding<AppTheme> {
        Binding(
            get: { model.theme },
            set: { coordinator.setTheme($0) }
        )
    }

    // MARK: - Agent 用量卡

    private var agentUsageCard: some View {
        let result = model.moduleResults[.agentUsage]
        let pythonProbe = result?.localDependencies.first { $0.kind == .python }
        let sessionProbes = (result?.localDependencies ?? [])
            .filter { $0.kind == .sessionDirectory }
        let availableSessions = sessionProbes.filter { $0.status == .available }
        let busy = model.busyModules.contains(.agentUsage)

        return Section("Agent 用量") {
            LabeledContent("Python") {
                statusText(
                    probeStatusText(pythonProbe),
                    icon: probeStatusIcon(pythonProbe)
                )
            }
            if let version = pythonProbe?.detail {
                LabeledContent("版本", value: version)
            }
            LabeledContent(
                "有效会话源",
                value: "\(availableSessions.count) / \(sessionProbes.count)"
            )
            ForEach(result?.warnings ?? [], id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let reason = result?.blockingReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("选择 Python…") { choosePython() }
                    .disabled(busy)
                Button("重新检查") { coordinator.rescan() }
                    .disabled(busy)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .glassFormRowBackground(theme: model.theme)
        .glassButtonStyle(theme: model.theme)
    }

    // MARK: - GitHub 卡

    private var githubCard: some View {
        let result = model.moduleResults[.github]
        let ghProbe = result?.localDependencies.first { $0.kind == .ghCli }
        let busy = model.busyModules.contains(.github)

        return Section("GitHub") {
            LabeledContent("GitHub CLI") {
                statusText(
                    probeStatusText(ghProbe),
                    icon: probeStatusIcon(ghProbe)
                )
            }
            if let version = ghProbe?.detail {
                LabeledContent("版本", value: version)
            }
            LabeledContent("登录状态") {
                statusText(
                    connectionStatusText(result?.connection),
                    icon: connectionStatusIcon(result?.connection)
                )
            }
            if let reason = result?.blockingReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("登录 GitHub") { coordinator.loginGitHub() }
                    .disabled(busy || ghProbe?.status != .available)
                Button("重新检查") { coordinator.rescan() }
                    .disabled(busy)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("登录在浏览器中完成, 关闭浏览器页面即可取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .glassFormRowBackground(theme: model.theme)
        .glassButtonStyle(theme: model.theme)
    }

    // MARK: - GitLab 卡

    private var gitlabCard: some View {
        let result = model.moduleResults[.gitlab]
        let busy = model.busyModules.contains(.gitlab)

        return Section("GitLab") {
            TextField("HTTPS base URL", text: $gitlabBaseURLText)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
            SecureField("PAT (输入后不回显)", text: $gitlabPATText)
                .textFieldStyle(.roundedBorder)
                .focused($patFieldFocused)
                .disabled(busy)
            LabeledContent("连接状态") {
                statusText(
                    connectionStatusText(result?.connection),
                    icon: connectionStatusIcon(result?.connection)
                )
            }
            if let reason = result?.blockingReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("保存并验证") {
                    coordinator.saveAndVerifyGitLab(
                        baseURL: gitlabBaseURLText, pat: gitlabPATText
                    )
                    // PAT 只进 Keychain, 提交后清空输入框
                    gitlabPATText = ""
                }
                .disabled(busy || gitlabBaseURLText.isEmpty || gitlabPATText.isEmpty)
                Button("更换 PAT") {
                    gitlabPATText = ""
                    patFieldFocused = true
                }
                .disabled(busy)
                Button("断开") {
                    coordinator.revokeModule(.gitlab)
                    gitlabPATText = ""
                }
                .disabled(busy)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("断开会停止 GitLab 调度并删除本应用保存的 PAT; 远端 PAT 请在 GitLab 设置中撤销")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .glassFormRowBackground(theme: model.theme)
        .glassButtonStyle(theme: model.theme)
    }

    // MARK: - 统一授权区

    private var consentSection: some View {
        Section("统一授权") {
            Toggle("Agent 用量", isOn: moduleBinding(.agentUsage))
            Toggle("GitHub", isOn: moduleBinding(.github))
            Toggle("GitLab", isOn: moduleBinding(.gitlab))

            VStack(alignment: .leading, spacing: 6) {
                Text("授权后应用将:")
                    .font(.subheadline.weight(.medium))
                summaryLine("扫描本机 Agent 会话目录和 CC Switch / Antigravity 数据库 (只读)")
                summaryLine("访问 github.com (通过 gh 官方登录态)")
                if let host = coordinator.configuredGitLabBaseURL
                    .flatMap({ URL(string: $0)?.host }) {
                    summaryLine("访问 \(host) (使用已保存的 PAT)")
                }
                summaryLine("默认每 30 分钟自动刷新已授权模块")
                summaryLine("Agent 云端额度 Provider 当前未启用, 不会访问云端额度接口")
                summaryLine("可随时在此撤销授权暂停采集, 或通过 GitLab 卡的\"断开\"删除已保存的 PAT")
            }
            .padding(.vertical, 4)

            if coordinator.consentConfirmed {
                HStack {
                    statusText("当前授权有效", icon: "checkmark.circle.fill")
                    Spacer()
                    Button("撤销全部授权") {
                        coordinator.revokeAllConsent()
                    }
                }
            } else {
                Button("确认授权") {
                    coordinator.confirmConsent(
                        selectedModules: coordinator.selectedModules
                    )
                }
                .disabled(coordinator.selectedModules.isEmpty)
            }
        }
        .glassFormRowBackground(theme: model.theme)
        .glassButtonStyle(theme: model.theme)
    }

    // MARK: - Helpers

    private func choosePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "选择 Python 3.9 或更高版本的可执行文件"
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.choosePython(path: url.path)
        }
    }

    private func moduleBinding(_ module: CollectorModule) -> Binding<Bool> {
        Binding(
            get: { coordinator.selectedModules.contains(module) },
            set: { selected in
                if selected {
                    coordinator.selectedModules.insert(module)
                } else {
                    coordinator.selectedModules.remove(module)
                }
            }
        )
    }

    private func summaryLine(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func statusText(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
    }

    private func probeStatusText(_ probe: DependencyProbe?) -> String {
        guard let probe else { return "未扫描" }
        switch probe.status {
        case .available: return "可用"
        case .missing: return "未安装"
        case .incompatible: return "版本不兼容"
        case .locked: return "被锁定"
        case .timedOut: return "检查超时"
        case .corrupted: return "已损坏"
        }
    }

    private func probeStatusIcon(_ probe: DependencyProbe?) -> String {
        guard let probe else { return "circle.dashed" }
        switch probe.status {
        case .available: return "checkmark.circle.fill"
        case .missing, .incompatible: return "exclamationmark.triangle.fill"
        case .locked, .timedOut, .corrupted: return "xmark.circle"
        }
    }

    private func connectionStatusText(_ status: ConnectionStatus?) -> String {
        guard let status else { return "未检查" }
        switch status {
        case .notRequired: return "无需连接"
        case .notChecked: return "未检查"
        case .pendingAuthorization: return "待授权"
        case .verifying: return "验证中"
        case .connected: return "已连接"
        case .expired: return "授权失效"
        case .unreachable: return "网络不可达"
        case .unsupported: return "不支持"
        }
    }

    private func connectionStatusIcon(_ status: ConnectionStatus?) -> String {
        guard let status else { return "circle.dashed" }
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .pendingAuthorization, .expired: return "exclamationmark.triangle.fill"
        case .unreachable: return "wifi.slash"
        case .verifying: return "arrow.clockwise"
        case .notRequired, .notChecked, .unsupported: return "circle.dashed"
        }
    }
}
