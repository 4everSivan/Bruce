import AppKit
import MdddAppCore
import MdddOnboardingCore
import SwiftUI
import UniformTypeIdentifiers

/// Onboarding 设置页: 三张模块状态卡 + 统一授权区.
/// 状态同时使用图标和文字; 扫描或验证中的卡片只禁用对应按钮, 不阻塞其他模块.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @EnvironmentObject private var diagnostics: DiagnosticService

    @State private var gitlabBaseURLText = ""
    @State private var gitlabPATText = ""
    @State private var diagnosticsPreview = ""
    @State private var showsDiagnosticsPreview = false
    @FocusState private var patFieldFocused: Bool
    // 订阅额度分区输入与编辑态
    @State private var deepseekKeyText = ""
    @State private var deepseekEditing = false
    @State private var volcengineAKText = ""
    @State private var volcengineSKText = ""
    @State private var volcengineEditing = false
    @State private var showsVolcengineCCImportConfirm = false
    @State private var kimiPasteText = ""
    @State private var kimiEditing = false
    @State private var showsCodexCCImportConfirm = false

    var body: some View {
        Form {
            if let error = model.settingsErrorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("设置错误: \(error)")
                }
            }

            menuBarDisplaySection
            agentUsageCard
            subscriptionSection
            githubCard
            gitlabCard
            consentSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .onAppear {
            if gitlabBaseURLText.isEmpty {
                gitlabBaseURLText = coordinator.configuredGitLabBaseURL ?? ""
            }
        }
        .sheet(isPresented: $showsDiagnosticsPreview) {
            diagnosticsPreviewSheet
        }
        .onChange(of: model.settingsErrorMessage) { message in
            if let message {
                announce(message)
            }
        }
    }

    // MARK: - 菜单栏显示

    private var menuBarDisplaySection: some View {
        Section("菜单栏显示") {
            Text("选择 1 至 3 项指标, 菜单栏将按下列顺序紧凑展示")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(MenuBarMetric.allCases) { metric in
                HStack {
                    Toggle(
                        isOn: menuBarMetricBinding(metric)
                    ) {
                        Label(metric.title, systemImage: metric.systemImage)
                    }
                    .disabled(
                        (!model.menuBarMetrics.contains(metric)
                            && model.menuBarMetrics.count
                                >= MenuBarMetricConfiguration.maximumCount)
                            || (model.menuBarMetrics.contains(metric)
                                && model.menuBarMetrics.count == 1)
                    )
                    Spacer()
                    if let index = model.menuBarMetrics.firstIndex(of: metric) {
                        Button {
                            moveMenuBarMetric(metric, offset: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel("上移\(metric.title)")
                        Button {
                            moveMenuBarMetric(metric, offset: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == model.menuBarMetrics.count - 1)
                        .accessibilityLabel("下移\(metric.title)")
                    }
                }
            }
        }
        .glassFormRowBackground()
        .glassButtonStyle()
    }

    private func menuBarMetricBinding(
        _ metric: MenuBarMetric
    ) -> Binding<Bool> {
        Binding(
            get: { model.menuBarMetrics.contains(metric) },
            set: { selected in
                var metrics = model.menuBarMetrics
                if selected {
                    guard !metrics.contains(metric),
                          metrics.count
                            < MenuBarMetricConfiguration.maximumCount else {
                        return
                    }
                    metrics.append(metric)
                } else {
                    guard metrics.count > 1 else { return }
                    metrics.removeAll { $0 == metric }
                }
                coordinator.setMenuBarMetrics(metrics)
            }
        )
    }

    private func moveMenuBarMetric(
        _ metric: MenuBarMetric,
        offset: Int
    ) {
        guard let index = model.menuBarMetrics.firstIndex(of: metric) else {
            return
        }
        let target = index + offset
        guard model.menuBarMetrics.indices.contains(target) else { return }
        var metrics = model.menuBarMetrics
        metrics.swapAt(index, target)
        coordinator.setMenuBarMetrics(metrics)
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
                    .accessibilityHint("选择 Python 3.9 或更高版本的可执行文件")
                Button("重新检查") { coordinator.rescan() }
                    .disabled(busy)
                    .accessibilityLabel("重新检查 Agent 用量依赖")
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .glassFormRowBackground()
        .glassButtonStyle()
    }

    // MARK: - 订阅额度

    /// 五个订阅 provider 的凭证配置与状态. 读取本机文件和真实网络验证
    /// 都只由用户点击触发; 失败经 model.settingsErrorMessage 提示 (fail-closed).
    private var subscriptionSection: some View {
        Section("订阅额度") {
            Text("配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度")
                .font(.caption)
                .foregroundStyle(.secondary)
            deepSeekGroup
            volcengineGroup
            kimiGroup
            codexGroup
            antigravityGroup
        }
        .accessibilityElement(children: .contain)
        .glassFormRowBackground()
        .glassButtonStyle()
        .confirmationDialog(
            "从 CC Switch 导入火山引擎凭证?",
            isPresented: $showsVolcengineCCImportConfirm,
            titleVisibility: .visible
        ) {
            Button("导入") {
                coordinator.importVolcengineFromCCSwitch()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只读访问 CC Switch 数据库, 不会修改 CC Switch 的任何数据")
        }
        .confirmationDialog(
            "从 CC Switch 导入 Codex 账号库?",
            isPresented: $showsCodexCCImportConfirm,
            titleVisibility: .visible
        ) {
            Button("导入") {
                coordinator.importCodexFromCCSwitch()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只读导入一次, 导入后由本应用自管, 不会回写 CC Switch")
        }
    }

    private var deepSeekGroup: some View {
        let configured = model.subscriptionCredentialConfigured[.deepseek] ?? false
        let busy = model.busySubscriptionProviders.contains(.deepseek)
        let editing = deepseekEditing || !configured

        return subscriptionGroup("DeepSeek") {
            subscriptionStatusLine(.deepseek)
            subscriptionEnabledToggle(.deepseek)
            if editing {
                SecureField("API key (输入后不回显)", text: $deepseekKeyText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("DeepSeek API key")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                HStack {
                    Button("保存并验证") {
                        coordinator.saveAndVerifyDeepSeek(apiKey: deepseekKeyText)
                        // API key 只进 Keychain, 提交后清空输入框
                        deepseekKeyText = ""
                        deepseekEditing = false
                    }
                    .disabled(busy || deepseekKeyText.isEmpty)
                    .accessibilityHint("保存到 Keychain 并联网验证 DeepSeek 余额接口")
                    if configured {
                        Button("取消") {
                            deepseekKeyText = ""
                            deepseekEditing = false
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } else {
                HStack {
                    Button("更换") { deepseekEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的 DeepSeek API key")
                    Button("移除") {
                        coordinator.removeSubscriptionProvider(.deepseek)
                    }
                    .disabled(busy)
                    .accessibilityHint("删除本应用保存的 DeepSeek API key")
                }
            }
        }
    }

    private var volcengineGroup: some View {
        let configured = model.subscriptionCredentialConfigured[.volcengine] ?? false
        let busy = model.busySubscriptionProviders.contains(.volcengine)
        let editing = volcengineEditing || !configured

        return subscriptionGroup("火山引擎") {
            subscriptionStatusLine(.volcengine)
            subscriptionEnabledToggle(.volcengine)
            if editing {
                SecureField("AccessKey (输入后不回显)", text: $volcengineAKText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("火山引擎 AccessKey")
                SecureField("SecretKey (输入后不回显)", text: $volcengineSKText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("火山引擎 SecretKey")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                HStack {
                    Button("保存并验证") {
                        coordinator.saveAndVerifyVolcengine(
                            accessKey: volcengineAKText,
                            secretKey: volcengineSKText
                        )
                        volcengineAKText = ""
                        volcengineSKText = ""
                        volcengineEditing = false
                    }
                    .disabled(
                        busy || volcengineAKText.isEmpty || volcengineSKText.isEmpty
                    )
                    .accessibilityHint("保存到 Keychain 并做本地格式校验")
                    if configured {
                        Button("取消") {
                            volcengineAKText = ""
                            volcengineSKText = ""
                            volcengineEditing = false
                        }
                        .disabled(busy)
                    }
                }
                Text("此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Button("更换") { volcengineEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的火山引擎 AK/SK")
                    Button("移除") {
                        coordinator.removeSubscriptionProvider(.volcengine)
                    }
                    .disabled(busy)
                    .accessibilityHint("删除本应用保存的火山引擎 AK/SK")
                }
            }
            if coordinator.ccSwitchDatabaseExists() {
                Button("从 CC Switch 导入") {
                    showsVolcengineCCImportConfirm = true
                }
                .disabled(busy)
                .accessibilityHint("只读导入 CC Switch 中火山 Codingplan 的 AK/SK")
            }
        }
    }

    private var kimiGroup: some View {
        let configured = model.subscriptionCredentialConfigured[.kimi] ?? false
        let needsRelogin = model.subscriptionProviders[.kimi]?
            .verificationStatus == .needsRelogin
        let localFileExists = coordinator.kimiLocalTokensFileExists()
        // needsRelogin 时保留粘贴入口, 便于重新登录
        let showPaste = kimiEditing || !configured || (needsRelogin && !localFileExists)

        return subscriptionGroup("Kimi") {
            subscriptionStatusLine(.kimi)
            subscriptionEnabledToggle(.kimi)
            if localFileExists {
                Button("从本机导入") {
                    coordinator.importKimiFromLocalFile()
                }
                .accessibilityHint("读取 kimi-dashboard 保存的本机浏览器令牌")
            }
            if showPaste && !localFileExists {
                Text("打开 kimi.com 并登录 → 开发者工具 → Application → 复制 access_token 与 refresh_token, 粘贴整段 JSON 或两段 token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $kimiPasteText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 96)
                    .accessibilityLabel("Kimi 令牌粘贴框")
                HStack {
                    Button("验证并保存") {
                        coordinator.importKimiFromPaste(kimiPasteText)
                        kimiPasteText = ""
                        kimiEditing = false
                    }
                    .disabled(kimiPasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("校验后保存到本应用的 Keychain")
                    if configured {
                        Button("取消") {
                            kimiPasteText = ""
                            kimiEditing = false
                        }
                    }
                }
            }
            if configured {
                HStack {
                    if !localFileExists && !showPaste {
                        Button("更换") { kimiEditing = true }
                            .accessibilityHint("重新粘贴 Kimi 令牌")
                    }
                    Button("移除") {
                        coordinator.removeSubscriptionProvider(.kimi)
                        kimiEditing = false
                    }
                    .accessibilityHint("删除本应用保存的 Kimi 令牌")
                }
            }
        }
    }

    private var codexGroup: some View {
        let configured = model.subscriptionCredentialConfigured[.codex] ?? false

        return subscriptionGroup("Codex") {
            subscriptionStatusLine(.codex)
            subscriptionEnabledToggle(.codex)
            if let summary = model.codexAccountSummary, summary.count > 0 {
                let shown = summary.emailPrefixes.prefix(5).joined(separator: ", ")
                let suffix = summary.emailPrefixes.count > 5 ? " 等" : ""
                Text("已导入 \(summary.count) 个账号: \(shown)\(suffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if coordinator.codexCLIAuthFileExists() {
                    Button("从本机导入当前账号") {
                        coordinator.importCodexFromLocalCLI()
                    }
                    .accessibilityHint("读取 Codex CLI 的当前登录账号")
                }
                if coordinator.codexCCAccountsFileExists() {
                    Button("从 CC Switch 导入账号库") {
                        showsCodexCCImportConfirm = true
                    }
                    .accessibilityHint("只读导入 CC Switch 管理的 Codex 多账号")
                }
            }
            if configured {
                Button("移除") {
                    coordinator.removeSubscriptionProvider(.codex)
                }
                .accessibilityHint("删除本应用保存的全部 Codex 账号凭证")
            }
        }
    }

    private var antigravityGroup: some View {
        let configured = model.subscriptionCredentialConfigured[.antigravity] ?? false

        return subscriptionGroup("Antigravity") {
            subscriptionStatusLine(.antigravity)
            subscriptionEnabledToggle(.antigravity)
            if coordinator.antigravityTokenFileExists() {
                Button("从本机导入") {
                    coordinator.importAntigravityFromLocalFile()
                }
                .accessibilityHint("读取 Antigravity CLI 的本机 OAuth 令牌")
            } else if !configured {
                Text("未检测到本机 Antigravity 令牌文件, 请先通过 Antigravity CLI 登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if configured {
                Button("移除") {
                    coordinator.removeSubscriptionProvider(.antigravity)
                }
                .accessibilityHint("删除本应用保存的 Antigravity 令牌")
            }
        }
    }

    private func subscriptionGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// 状态行: 未配置 / 已配置 · 验证通过 / 验证失败(原因) / 需要重新登录.
    private func subscriptionStatusLine(
        _ id: SubscriptionProviderID
    ) -> some View {
        let configured = model.subscriptionCredentialConfigured[id] ?? false
        let status = model.subscriptionProviders[id]?.verificationStatus ?? .none
        let text: String
        let icon: String
        if !configured {
            text = "未配置"
            icon = "circle.dashed"
        } else {
            switch status {
            case .ok:
                text = "已配置 · 验证通过"
                icon = "checkmark.circle.fill"
            case .failed(let reason):
                text = "验证失败: \(reason)"
                icon = "exclamationmark.triangle.fill"
            case .needsRelogin:
                text = "需要重新登录"
                icon = "exclamationmark.triangle.fill"
            case .none:
                text = "已配置 · 未验证"
                icon = "circle.dashed"
            }
        }
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(configured && status == .ok ? .secondary : .primary)
            .accessibilityLabel("\(id.displayName) 状态: \(text)")
    }

    /// enabled 开关: 有凭证才可开, 保存失败由 coordinator 报错并回退.
    private func subscriptionEnabledToggle(
        _ id: SubscriptionProviderID
    ) -> some View {
        let configured = model.subscriptionCredentialConfigured[id] ?? false
        return Toggle(
            isOn: Binding(
                get: { model.subscriptionProviders[id]?.enabled ?? false },
                set: { coordinator.setSubscriptionProviderEnabled(id, $0) }
            )
        ) {
            Text("启用云端额度查询")
                .font(.caption)
        }
        .disabled(!configured)
        .accessibilityHint(configured ? "启用后 Collector 将查询该 Provider 云端额度" : "请先配置凭证")
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
                    .accessibilityHint("在浏览器中完成 GitHub 官方登录")
                Button("重新检查") { coordinator.rescan() }
                    .disabled(busy)
                    .accessibilityLabel("重新检查 GitHub 连接")
                if busy {
                    ProgressView()
                        .controlSize(.small)
                    Text("登录在浏览器中完成, 关闭浏览器页面即可取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .glassFormRowBackground()
        .glassButtonStyle()
    }

    // MARK: - GitLab 卡

    private var gitlabCard: some View {
        let result = model.moduleResults[.gitlab]
        let busy = model.busyModules.contains(.gitlab)

        return Section("GitLab") {
            TextField("HTTPS base URL", text: $gitlabBaseURLText)
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .accessibilityLabel("GitLab HTTPS 地址")
            SecureField("PAT (输入后不回显)", text: $gitlabPATText)
                .textFieldStyle(.roundedBorder)
                .focused($patFieldFocused)
                .disabled(busy)
                .accessibilityLabel("GitLab 个人访问令牌")
                .accessibilityHint("令牌只保存到本应用的 Keychain")
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
                .accessibilityHint("保存到 Keychain 并验证 GitLab 连接")
                Button("更换 PAT") {
                    gitlabPATText = ""
                    patFieldFocused = true
                }
                .disabled(busy)
                .accessibilityHint("清空令牌输入框并移动键盘焦点")
                Button("断开") {
                    coordinator.revokeModule(.gitlab)
                    gitlabPATText = ""
                }
                .disabled(busy)
                .accessibilityHint("停止 GitLab 调度并删除本应用保存的令牌")
                if busy {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text("断开会停止 GitLab 调度并删除本应用保存的 PAT; 远端 PAT 请在 GitLab 设置中撤销")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .glassFormRowBackground()
        .glassButtonStyle()
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
                let enabledProviders = coordinator
                    .enabledConfiguredSubscriptionProviders
                if enabledProviders.isEmpty {
                    summaryLine("未配置启用的订阅额度 Provider, 不会访问云端额度接口")
                } else {
                    let names = enabledProviders.map(\.displayName)
                        .joined(separator: " / ")
                    summaryLine("确认授权后查询已启用订阅 Provider 的云端额度: \(names)")
                }
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
                    .accessibilityHint("停止所有模块的自动采集")
                }
            } else {
                Button("确认授权") {
                    coordinator.confirmConsent(
                        selectedModules: coordinator.selectedModules
                    )
                }
                .disabled(coordinator.selectedModules.isEmpty)
                .accessibilityHint("允许已选模块按默认 30 分钟周期采集")
            }
        }
        .glassFormRowBackground()
        .glassButtonStyle()
    }

    // MARK: - 诊断

    private var diagnosticsSection: some View {
        Section("诊断") {
            Text("诊断包仅包含应用与系统版本、模块状态、依赖状态和快照校验结果, 不包含 Artifact、账号信息或凭证")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("预览诊断") {
                    do {
                        diagnosticsPreview = try diagnostics.preview()
                        model.setSettingsError(nil)
                        showsDiagnosticsPreview = true
                    } catch {
                        model.setSettingsError("诊断预览生成失败")
                    }
                }
                .accessibilityHint("显示导出前的脱敏 JSON 内容")
                Button("导出诊断包…") {
                    exportDiagnostics()
                }
                .accessibilityHint("选择位置保存不含业务数据的 ZIP 文件")
            }
        }
        .glassFormRowBackground()
        .glassButtonStyle()
    }

    private var diagnosticsPreviewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("诊断预览")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("关闭") {
                    showsDiagnosticsPreview = false
                }
                .keyboardShortcut(.cancelAction)
            }
            Text("以下内容与导出包中的 report.json 一致")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(diagnosticsPreview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel("脱敏诊断 JSON 预览")
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = diagnostics.suggestedFilename()
        panel.message = "导出不含 Artifact、账号信息或凭证的最小诊断包"
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            try diagnostics.export(to: destination)
            model.setSettingsError(nil)
            announce("诊断包已导出")
        } catch {
            model.setSettingsError("诊断包导出失败, 未写入业务数据")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
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
