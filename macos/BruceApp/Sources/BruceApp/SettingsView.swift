import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 设置页: 左侧边栏分类导航 + 右侧单分类面板, Fluent 平面视觉
/// (token 与组件见 Settings/FluentSettingsChrome.swift, 1:1 对齐
/// docs/design/settings-layout-demo.html).
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @EnvironmentObject private var diagnostics: DiagnosticService

    /// 侧边栏选中分类.
    @State private var category = SettingsCategory.general
    @State private var diagnosticsPreview = ""
    @State private var showsDiagnosticsPreview = false
    // 订阅额度分区输入态 (编辑态由配置对话框内部管理)
    @State private var deepseekValues: [String: String] = [:]
    @State private var volcengineValues: [String: String] = [:]
    @State private var showsVolcengineCCImportConfirm = false
    @State private var zhipuValues: [String: String] = [:]
    @State private var zhipuSiteIsCN = true
    @State private var kimiValues: [String: String] = [:]
    @State private var claudePasteText = ""
    @State private var claudeEditing = false
    @State private var grokPasteText = ""
    @State private var grokEditing = false
    @State private var opencodeGoPasteText = ""
    @State private var opencodeGoEditing = false
    @State private var showsCodexCCImportConfirm = false
    // 订阅额度标签式管理: 本次会话点击添加的 provider 与 P2 配置 sheet 目标
    @State private var addedSubscriptionProviders: Set<SubscriptionProviderID> = []
    /// 当前在配置 sheet 中打开的 provider (P2 对话框).
    @State private var configuringProvider: SubscriptionProviderID?
    @State private var providerToAdd: SubscriptionProviderID?
    // 通知权限状态: denied 时预警通知无法投递, 提示用户前往系统设置
    @State private var notificationDenied = false
    // 首次启动时引导配置 Bruce 自有 Keychain 访问权限
    @State private var showsKeychainAccessGuide = false
    @State private var didEvaluateKeychainAccessGuide = false
    // 数据管理: 清理确认与操作反馈
    @State private var showsClearCacheConfirm = false
    @State private var dataActionMessage: String?
    @State private var accountRemovalRequest: AccountRemovalRequest?

    private struct AccountRemovalRequest {
        let provider: SubscriptionProviderID
        let accountID: String
        let displayName: String
    }

    /// 侧边栏分类: 线性图标 (跨平台同构, 对应 WinUI NavigationView).
    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, agentUsage, subscription, consent, maintenance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "通用"
            case .agentUsage: return "Agent 用量"
            case .subscription: return "订阅额度"
            case .consent: return "授权与隐私"
            case .maintenance: return "维护"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .agentUsage: return "chart.bar"
            case .subscription: return "cloud"
            case .consent: return "checkmark.shield"
            case .maintenance: return "wrench.and.screwdriver"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            // demo: 侧栏与内容之间是 1px 平面分隔线, 非系统 Divider 的半透明黑
            Rectangle()
                .fill(SettingsDemoTokens.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.settingsErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("设置错误: \(error)")
                    }
                    crumb("设置 / \(category.title)")
                    paneTitle(category.title)
                    paneContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsDemoTokens.window)
            // P2 配置对话框: 挂在右侧内容 ScrollView 上, 与 body 根的
            // showsDiagnosticsPreview sheet 错开挂载点, 避免同视图双 sheet 冲突.
            .sheet(isPresented: Binding(
                get: { configuringProvider != nil },
                set: { isPresented in
                    if !isPresented { configuringProvider = nil }
                }
            )) {
                if let id = configuringProvider {
                    providerConfigSheet(id)
                }
            }
        }
        .preferredColorScheme(coordinator.appearanceMode.colorScheme)
        .environment(\.BruceResolvedTheme, coordinator.resolvedTheme)
        .sheet(isPresented: $showsDiagnosticsPreview) {
            diagnosticsPreviewSheet
        }
        // 订阅相关确认对话框提升到 body 级: 触发按钮在 P2 配置 sheet 内,
        // 挂在被遮罩的面板视图下可能无法呈现.
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
            "从 CC Switch 发现 Codex 账号?",
            isPresented: $showsCodexCCImportConfirm,
            titleVisibility: .visible
        ) {
            Button("发现账号") {
                coordinator.importCodexFromCCSwitch()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只读发现账号元数据. 不导入、不保存、不使用 CC Switch 持有的 Codex 登录令牌, 也不会回写 CC Switch")
        }
        .confirmationDialog(
            accountRemovalRequest.map { "移除 \($0.displayName) 账号?" } ?? "移除账号?",
            isPresented: Binding(
                get: { accountRemovalRequest != nil },
                set: { isPresented in
                    if !isPresented {
                        accountRemovalRequest = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("移除账号", role: .destructive) {
                guard let request = accountRemovalRequest else { return }
                accountRemovalRequest = nil
                coordinator.removeAccount(
                    accountID: request.accountID,
                    from: request.provider
                )
            }
            Button("取消", role: .cancel) {
                accountRemovalRequest = nil
            }
        } message: {
            Text("只删除 Bruce 本地保存的该账号凭证, 不会修改 CC Switch、Codex CLI 或第三方服务上的账号")
        }
        .onChange(of: model.settingsErrorMessage) { _, message in
            if let message {
                announce(message)
            }
        }
        .sheet(isPresented: $showsKeychainAccessGuide) {
            keychainAccessGuide
        }
        .onAppear(perform: presentKeychainAccessGuideIfNeeded)
    }

    // MARK: - 侧边栏

    /// L2 Fluent 侧栏 (定稿 settings-layout-demo.html): 216pt 平面导航,
    /// 线性图标 + 文字; 选中项浅底 + 左缘 3pt accent 指示条;
    /// 不依赖材质模糊与彩色图标底, 为跨平台 (WinUI NavigationView) 同构设计.
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(item.title)
                            .font(.system(
                                size: 12.5,
                                weight: category == item ? .semibold : .regular
                            ))
                        Spacer()
                    }
                    .foregroundStyle(category == item ? Color.primary : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        category == item ? SettingsDemoTokens.navSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                    )
                    // 左缘 accent 指示条 (Fluent NavigationView 同款)
                    .overlay(alignment: .leading) {
                        if category == item {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Color.accentColor)
                                .frame(width: 3)
                                .padding(.vertical, 9)
                                .padding(.leading, -6)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer()
            Text(AppVersion.current())
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .frame(width: 216)
        .frame(maxHeight: .infinity)
        .background(SettingsDemoTokens.nav)
    }

    // MARK: - 面板切换

    @ViewBuilder
    private var paneContent: some View {
        switch category {
        case .general: generalPane
        case .agentUsage: agentUsagePane
        case .subscription: subscriptionPane
        case .consent: consentPane
        case .maintenance: maintenancePane
        }
    }

    /// demo crumb: 面板标题上方的灰色小字分类名.
    private func crumb(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(SettingsDemoTokens.text3)
    }

    /// demo .pane-title: 19px semibold 大标题.
    private func paneTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(SettingsDemoTokens.text)
    }

    /// demo .caption: 11px semibold 灰色分组标题.
    private func paneCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(SettingsDemoTokens.text3)
            .padding(.leading, 2)
    }

    // MARK: - 通用面板

    /// 通用偏好: 外观, 界面风格, 模糊风格, 自动刷新与菜单栏指标.
    private var generalPane: some View {
        let glassSupported = coordinator.liquidGlassSupported()
        let showBlurStyles = glassSupported
            && coordinator.resolvedTheme.interfaceStyle == .liquidGlass

        return VStack(alignment: .leading, spacing: 14) {
            FluentCard {
                FluentRow(
                    "配色模式",
                    sub: "立即作用于菜单栏面板与设置窗口"
                ) {
                    FluentSegmentedPicker(
                        options: [
                            ("跟随系统", AppearancePreference.system),
                            ("浅色", AppearancePreference.light),
                            ("深色", AppearancePreference.dark),
                        ],
                        selection: Binding(
                            get: { coordinator.appearanceMode },
                            set: { coordinator.setAppearanceMode($0) }
                        )
                    )
                }
                FluentRow(
                    "界面风格",
                    sub: glassSupported
                        ? "经典为材质面板; 液态玻璃使用系统玻璃效果; Nothing 为纯色平面风格, 无模糊无玻璃"
                        : "液态玻璃需要 macOS 26; 当前可使用经典或 Nothing",
                    divided: true
                ) {
                    FluentSegmentedPicker(
                        options: [
                            ("经典", InterfaceStylePreference.classic),
                            ("液态玻璃", InterfaceStylePreference.liquidGlass),
                            ("Nothing", InterfaceStylePreference.nothing),
                        ],
                        selection: Binding(
                            get: { coordinator.interfaceStyle },
                            set: { coordinator.setInterfaceStyle($0) }
                        )
                    )
                }
                if showBlurStyles {
                    FluentRow(
                        "模糊风格",
                        sub: "标准与通透为系统液态玻璃, 哑光退化为材质质感",
                        divided: true
                    ) {
                        FluentSegmentedPicker(
                            options: [
                                ("标准", GlassStylePreference.regular),
                                ("通透", GlassStylePreference.clear),
                                ("哑光", GlassStylePreference.material),
                            ],
                            selection: Binding(
                                get: { coordinator.glassStyle },
                                set: { coordinator.setGlassStyle($0) }
                            )
                        )
                    }
                }
                FluentRow(
                    "刷新间隔",
                    sub: "已授权模块的自动采集周期, 变更后立即重新计时",
                    divided: true
                ) {
                    FluentSegmentedPicker(
                        options: OnboardingConfiguration.allowedRefreshIntervalMinutes
                            .map { ("\($0) 分钟", $0) },
                        selection: Binding(
                            get: { coordinator.refreshIntervalMinutes },
                            set: { coordinator.setRefreshIntervalMinutes($0) }
                        )
                    )
                }
                FluentRow(
                    "系统通知",
                    sub: "预警与额度提醒; 关闭后 Bruce 不会投递通知",
                    divided: true
                ) {
                    HStack(spacing: 8) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { coordinator.systemNotificationsEnabled },
                                set: { coordinator.setSystemNotificationsEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        Text(coordinator.systemNotificationsEnabled ? "已开启" : "已关闭")
                            .font(.system(size: 12.5))
                            .foregroundStyle(
                                coordinator.systemNotificationsEnabled
                                    ? SettingsDemoTokens.ok : SettingsDemoTokens.text3
                            )
                        if notificationDenied {
                            Button("前往系统设置") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                                )
                            }
                            .fluentButton()
                        }
                    }
                }
                .onAppear(perform: refreshNotificationStatus)
                FluentRow(
                    "钥匙串访问",
                    sub: "统一管理 Bruce 保存的订阅凭证访问权限",
                    divided: true
                ) {
                    HStack(spacing: 8) {
                        if coordinator.keychainAccessConfigured {
                            Text("已配置")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.ok)
                            Button("重新配置") {
                                coordinator.configureKeychainAccess()
                            }
                            .fluentButton()
                        } else {
                            Text("未配置")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.warn)
                            Button("配置") {
                                coordinator.configureKeychainAccess()
                            }
                            .fluentButton()
                        }
                    }
                }
                FluentRow("版本", divided: true) {
                    Text(AppVersion.current())
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }
            }

            paneCaption("全局快捷键")

            FluentCard {
                GlobalHotkeyRecorder()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            paneCaption("菜单栏指标")

            FluentCard {
                Text("选择 1 至 3 项指标, 菜单栏将按下列顺序紧凑展示; 拖拽已选指标调整顺序")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                menuBarMetricList
            }
        }
    }

    /// 查询系统通知授权状态; 仅 denied 视为未开启, notDetermined 会在首次预警时弹授权.
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in notificationDenied = denied }
        }
    }

    private func presentKeychainAccessGuideIfNeeded() {
        guard !didEvaluateKeychainAccessGuide else { return }
        didEvaluateKeychainAccessGuide = true
        guard !coordinator.keychainAccessConfigured else {
            return
        }
        DispatchQueue.main.async {
            showsKeychainAccessGuide = true
        }
    }

    private var keychainAccessGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("配置钥匙串访问", systemImage: "key.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Bruce 会把订阅凭证保存在 macOS 钥匙串中。首次配置时系统可能要求输入一次 macOS 登录密码, 以统一授权 Bruce 访问已有凭证。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Bruce 不会保存你的系统密码, 配置文件只记录访问状态。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Button("稍后") {
                    showsKeychainAccessGuide = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("现在配置") {
                    showsKeychainAccessGuide = false
                    coordinator.configureKeychainAccess()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private func moveMenuBarMetric(
        _ dragged: MenuBarMetric,
        onto target: MenuBarMetric
    ) {
        var metrics = model.menuBarMetrics
        metrics.removeAll { $0 == dragged }
        guard let targetIndex = metrics.firstIndex(of: target) else { return }
        metrics.insert(dragged, at: targetIndex)
        coordinator.setMenuBarMetrics(metrics)
    }

    /// 菜单栏指标列表: 已选指标可拖拽排序, 未选指标点击添加.
    private var menuBarMetricList: some View {
        VStack(spacing: 0) {
            ForEach(model.menuBarMetrics) { metric in
                menuBarMetricRow(metric, selected: true, divided: true)
                    .onDrop(
                        of: [.text],
                        delegate: LiveReorderDropDelegate<MenuBarMetric>(
                            target: metric,
                            move: moveMenuBarMetric
                        )
                    )
            }
            ForEach(
                MenuBarMetric.allCases.filter { !model.menuBarMetrics.contains($0) }
            ) { metric in
                menuBarMetricRow(metric, selected: false, divided: true)
            }
        }
    }

    /// 单个菜单栏指标行: 已选行有拖拽手柄和移除按钮, 未选行有添加按钮.
    private func menuBarMetricRow(
        _ metric: MenuBarMetric,
        selected: Bool,
        divided: Bool
    ) -> some View {
        HStack(spacing: 10) {
            if selected {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDemoTokens.text3)
                    .accessibilityHidden(true)
                    .draggable(metric.rawValue)
            }
            Text(metric.title)
                .font(.system(size: 13))
                .foregroundStyle(
                    selected ? SettingsDemoTokens.text : SettingsDemoTokens.text2
                )
            Spacer()
            if selected {
                Button {
                    var metrics = model.menuBarMetrics
                    guard metrics.count > 1 else { return }
                    metrics.removeAll { $0 == metric }
                    coordinator.setMenuBarMetrics(metrics)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(SettingsDemoTokens.danger)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("移除\(metric.title)")
            } else {
                Button {
                    var metrics = model.menuBarMetrics
                    guard !metrics.contains(metric),
                          metrics.count < MenuBarMetricConfiguration.maximumCount else {
                        return
                    }
                    metrics.append(metric)
                    coordinator.setMenuBarMetrics(metrics)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(SettingsDemoTokens.accent)
                }
                .buttonStyle(.borderless)
                .disabled(
                    model.menuBarMetrics.count >= MenuBarMetricConfiguration.maximumCount
                )
                .accessibilityLabel("添加\(metric.title)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if divided {
                SettingsDemoTokens.separator.frame(height: 1)
            }
        }
    }

    // MARK: - Agent 用量面板

    private var agentUsagePane: some View {
        let result = model.moduleResults[.agentUsage]
        let sessionProbes = (result?.localDependencies ?? [])
            .filter { $0.kind == .sessionDirectory }
        let busy = model.busyModules.contains(.agentUsage)
        let rustAvailable = coordinator.collectorRuntimeStatus == .rustAvailable

        return VStack(alignment: .leading, spacing: 14) {
            paneCaption("会话来源")
            FluentCard {
                FluentRow(
                    "Rust Collector",
                    sub: "扫描本机会话并聚合 token 用量"
                ) {
                    HStack(spacing: 6) {
                        FluentStatusDot(level: rustAvailable ? .ok : .warn)
                        Text(rustAvailable ? "可用" : "不可用")
                            .font(.system(size: 12.5))
                            .foregroundStyle(
                                rustAvailable ? SettingsDemoTokens.text2 : SettingsDemoTokens.warn
                            )
                    }
                }
                if sessionProbes.isEmpty {
                    FluentRow("尚未检查", sub: "点击下方重新检查", divided: true)
                } else {
                    ForEach(Array(sessionProbes.enumerated()), id: \.offset) { _, probe in
                        FluentRow(
                            probe.detail ?? "会话源",
                            sub: probe.kind == .sessionDirectory ? "本机会话目录" : "本机数据库",
                            divided: true
                        ) {
                            HStack(spacing: 6) {
                                FluentStatusDot(
                                    level: probe.status == .available ? .ok : .warn
                                )
                                Text(probe.status == .available ? "就绪" : "未授权")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(
                                        probe.status == .available
                                            ? SettingsDemoTokens.text2
                                            : SettingsDemoTokens.warn
                                    )
                            }
                        }
                    }
                }
                ForEach(visibleAgentUsageWarnings(result?.warnings ?? []), id: \.self) { warning in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(SettingsDemoTokens.warn)
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        SettingsDemoTokens.separator.frame(height: 1)
                    }
                }
                if let reason = result?.blockingReason {
                    Text(reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.warn)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) {
                            SettingsDemoTokens.separator.frame(height: 1)
                        }
                }
                HStack {
                    Spacer()
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("重新检查") { coordinator.rescan() }
                        .fluentButton()
                        .disabled(busy)
                        .accessibilityLabel("重新检查 Agent 用量依赖")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Kimi Work 属于可选增强探测, 不在 Agent 用量配置卡片中展示其状态提示.
    private func visibleAgentUsageWarnings(_ warnings: [String]) -> [String] {
        warnings.filter { warning in
            !warning.hasPrefix("Kimi Work ")
        }
    }

    // MARK: - 订阅额度面板

    /// 订阅 provider 的标签式管理: 顶部 Picker 只列未配置的 provider,
    /// 点击添加后其管理组出现在下方列表 (默认收起为一行).
    /// 读取本机文件和真实网络验证都只由用户点击触发;
    /// 失败经 model.settingsErrorMessage 提示 (fail-closed).
    private var subscriptionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneCaption("云端额度凭证")
            FluentCard {
                ForEach(Array(visibleSubscriptionProviders.enumerated()), id: \.element) { index, id in
                    subscriptionProviderRow(id, divided: index > 0)
                }
                if visibleSubscriptionProviders.isEmpty {
                    FluentRow("尚未配置任何订阅 Provider", sub: "从下方添加服务")
                }
            }
            .accessibilityElement(children: .contain)
            FluentCard {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("添加服务")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("只列出尚未配置的 Provider, 添加后打开配置窗口")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    Spacer()
                    Picker("", selection: $providerToAdd) {
                        Text("选择 Provider")
                            .tag(SubscriptionProviderID?.none)
                        ForEach(unconfiguredSubscriptionProviders, id: \.self) { id in
                            Text(id.displayName)
                                .tag(SubscriptionProviderID?.some(id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityHint("只列出尚未配置的订阅 Provider")
                    Button("添加…") {
                        guard let id = providerToAdd else { return }
                        // Phase 4: 持久化"已添加"状态, 跨会话保持
                        coordinator.addSubscriptionProvider(id)
                        addedSubscriptionProviders.insert(id)
                        configuringProvider = id
                        providerToAdd = nil
                    }
                    .fluentButton(.primary)
                    .disabled(providerToAdd == nil)
                    .accessibilityHint("将所选 Provider 加入上方列表并打开配置窗口")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Text("配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度; 拖拽行调整看板展示顺序")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsDemoTokens.text3)
        }
        .onAppear {
            coordinator.refreshOfficialLocalAvailability()
        }
    }

    /// 已在列表中展示的 provider: 配置中已添加 (持久化) 或本次会话刚添加.
    /// Phase 4: 未手动添加不显示 (与"全部手动添加"决策一致).
    private var visibleSubscriptionProviders: [SubscriptionProviderID] {
        let order = model.subscriptionProviderOrder
        let inOrder = Set(order)
        let isVisible = { (id: SubscriptionProviderID) -> Bool in
            (self.model.subscriptionProviders[id] != nil)
                || self.addedSubscriptionProviders.contains(id)
        }
        let ordered = order.filter(isVisible)
        let unordered = SubscriptionProviderID.allCases.filter {
            !inOrder.contains($0) && isVisible($0)
        }
        return ordered + unordered
    }

    /// 尚未进入列表的 provider, 供添加 Picker 选择.
    private var unconfiguredSubscriptionProviders: [SubscriptionProviderID] {
        SubscriptionProviderID.allCases.filter {
            !visibleSubscriptionProviders.contains($0)
        }
    }

    /// 单个 provider 行 (P2 + D3 定稿, demo .row): 拖拽手柄 (仅此可发起拖拽,
    /// 避免误触行内按钮) + 名称/副标题 + 状态尾件 + 配置按钮 + 启用开关;
    /// 点击「配置」弹出独立配置窗口 (sheet); 拖动经 LiveReorderDropDelegate 实时让位.
    private func subscriptionProviderRow(
        _ id: SubscriptionProviderID,
        divided: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(SettingsDemoTokens.text3)
                .accessibilityHidden(true)
                .draggable(id.rawValue)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(subscriptionRowSubtitle(id))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
            }
            Spacer(minLength: 8)
            subscriptionStatusTail(id)
            Button("配置") {
                configuringProvider = id
            }
            .fluentButton()
            .accessibilityHint("打开 \(id.displayName) 的配置窗口")
            subscriptionEnabledToggle(id)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            if divided {
                SettingsDemoTokens.separator.frame(height: 1)
            }
        }
        .onDrop(
            of: [.text],
            delegate: LiveReorderDropDelegate<SubscriptionProviderID>(
                target: id,
                move: moveSubscriptionProvider
            )
        )
        .accessibilityElement(children: .contain)
    }

    /// demo .r-sub: 凭证形态 + 账号数摘要.
    private func subscriptionRowSubtitle(_ id: SubscriptionProviderID) -> String {
        let kind: String
        switch id {
        case .kimi: kind = "Web 令牌"
        case .deepseek, .volcengine, .zhipu: kind = "API Key"
        case .codex: kind = "OAuth 设备码"
        case .claude, .grok: kind = "CLI 登录态"
        case .opencodeGo: kind = "OAuth 设备码"
        }
        let count = model.providerAccountSummaries[id]?.count ?? 0
        return count > 1 ? "\(kind) · \(count) 个账号" : kind
    }

    /// demo .r-tail: 纯文字状态, ok 绿 / warn 黄 / 其他灰.
    private func subscriptionStatusTail(_ id: SubscriptionProviderID) -> some View {
        let configured = model.subscriptionCredentialConfigured[id] ?? false
        let status = model.subscriptionProviders[id]?.verificationStatus ?? .none
        let text: String
        let tint: Color
        if !configured {
            text = "未配置"
            tint = SettingsDemoTokens.text3
        } else {
            switch status {
            case .ok:
                text = "已配置"
                tint = SettingsDemoTokens.ok
            case .failed:
                text = "验证失败"
                tint = SettingsDemoTokens.warn
            case .needsRelogin:
                text = "授权已过期"
                tint = SettingsDemoTokens.warn
            case .none:
                text = "已配置 · 未验证"
                tint = SettingsDemoTokens.text2
            }
        }
        return Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(tint)
            .accessibilityLabel("\(id.displayName) 状态: \(text)")
    }

    /// P2 配置对话框: API key 类 (Kimi/DeepSeek/火山/智谱) 走
    /// APIKeyProviderConfigDialog (demo CFG_DIALOG 1:1, 高度自适应);
    /// 其余 provider 走通用外壳 (横幅 + 账号列表 + 既有管理 section).
    @ViewBuilder
    private func providerConfigSheet(
        _ id: SubscriptionProviderID
    ) -> some View {
        switch id {
        case .kimi, .deepseek, .volcengine, .zhipu:
            apiKeyProviderDialog(id)
        case .codex, .claude, .grok, .opencodeGo:
            genericProviderConfigSheet(id)
        }
    }

    /// 通用配置外壳: demo 对话框骨架 + 各 provider 既有管理 section;
    /// 这些 section 自带保存/移除操作, footer 只留关闭按钮.
    private func genericProviderConfigSheet(
        _ id: SubscriptionProviderID
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // dg-head
            Text("配置 \(id.displayName)")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            // dg-body
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProviderStatusBanner(
                        configured: model.subscriptionCredentialConfigured[id] ?? false,
                        status: model.subscriptionProviders[id]?.verificationStatus ?? .none,
                        lastVerifiedAt: model.subscriptionProviders[id]?.lastVerifiedAt
                    )
                    providerAccountList(id)
                    subscriptionProviderManagement(id)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 4)
            }
            // dg-foot
            HStack {
                Spacer()
                Button("完成") { configuringProvider = nil }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 460, height: 420)
    }

    /// API key 类 provider 的 demo 版配置对话框; 保存闭包与原内联 section 一致.
    @ViewBuilder
    private func apiKeyProviderDialog(
        _ id: SubscriptionProviderID
    ) -> some View {
        let dismiss = { configuringProvider = nil }
        switch id {
        case .kimi:
            APIKeyProviderConfigDialog(
                id: .kimi,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "sk-•••••••••••••••• (输入后不回显)",
                        accessibilityLabel: "Kimi For Coding API key"
                    )
                ],
                values: $kimiValues,
                guide: ProviderCredentialGuide(
                    summary: "在 kimi.com/code 申请 Kimi For Coding API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: nil,
                extra: .none,
                onRemove: { removeSubscriptionProvider(.kimi) },
                onSave: { coordinator.saveAndVerifyKimi(apiKey: $0["apiKey"] ?? "") },
                onDismiss: dismiss
            )
        case .deepseek:
            APIKeyProviderConfigDialog(
                id: .deepseek,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "sk-•••••••••••••••• (输入后不回显)",
                        accessibilityLabel: "DeepSeek API key"
                    )
                ],
                values: $deepseekValues,
                guide: ProviderCredentialGuide(
                    summary: "在 DeepSeek 平台获取 API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: nil,
                extra: .none,
                onRemove: { removeSubscriptionProvider(.deepseek) },
                onSave: { coordinator.saveAndVerifyDeepSeek(apiKey: $0["apiKey"] ?? "") },
                onDismiss: dismiss
            )
        case .volcengine:
            APIKeyProviderConfigDialog(
                id: .volcengine,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "accessKey",
                        label: "Access Key",
                        placeholder: "AK•••••••• (输入后不回显)",
                        accessibilityLabel: "火山引擎 Access Key"
                    ),
                    APIKeyFieldDescriptor(
                        id: "secretKey",
                        label: "Secret Key",
                        placeholder: "SK•••••••• (输入后不回显)",
                        accessibilityLabel: "火山引擎 Secret Key"
                    )
                ],
                values: $volcengineValues,
                guide: ProviderCredentialGuide(
                    summary: "在火山引擎控制台获取 Access Key 与 Secret Key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
                extra: .ccSwitchImport($showsVolcengineCCImportConfirm),
                onRemove: { removeSubscriptionProvider(.volcengine) },
                onSave: {
                    coordinator.saveAndVerifyVolcengine(
                        accessKey: $0["accessKey"] ?? "",
                        secretKey: $0["secretKey"] ?? ""
                    )
                },
                onDismiss: dismiss
            )
        case .zhipu:
            APIKeyProviderConfigDialog(
                id: .zhipu,
                fields: [
                    APIKeyFieldDescriptor(
                        id: "apiKey",
                        label: "API Key",
                        placeholder: "•••••••• (输入后不回显)",
                        accessibilityLabel: "智谱 API key"
                    )
                ],
                values: $zhipuValues,
                guide: ProviderCredentialGuide(
                    summary: "在智谱 BigModel 控制台获取 API key",
                    linkTitle: nil,
                    linkURL: nil
                ),
                footnote: "此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担",
                extra: .sitePicker($zhipuSiteIsCN),
                onRemove: { removeSubscriptionProvider(.zhipu) },
                onSave: {
                    coordinator.saveAndVerifyZhipu(
                        apiKey: $0["apiKey"] ?? "",
                        baseURL: zhipuSiteIsCN
                            ? "https://open.bigmodel.cn/api/paas/v4"
                            : "https://api.z.ai/api/paas/v4"
                    )
                },
                onDismiss: dismiss
            )
        default:
            EmptyView()
        }
    }

    /// 多账号列表: 显示该 provider 的全部账号 (名称 + 状态 + 移除按钮).
    /// 单账号 (0 或 1 个) 不显示列表, 保持现有管理 UI.
    /// Codex 走专用 codexGroup (已有账号状态列表).
    private func providerAccountList(_ id: SubscriptionProviderID) -> some View {
        let summaries = model.providerAccountSummaries[id] ?? []
        guard id != .codex, summaries.count >= 1 else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(summaries.enumerated()), id: \.element.accountID) {
                    _, summary in
                    HStack(spacing: 6) {
                        Text(summary.displayName)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        accountStateLabel(summary)
                        Button {
                            accountRemovalRequest = AccountRemovalRequest(
                                provider: id,
                                accountID: summary.accountID,
                                displayName: summary.displayName
                            )
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除账号 \(summary.displayName)")
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.vertical, 2)
        )
    }

    /// 账号状态文案 (非敏感).
    private func accountStateLabel(
        _ summary: ProviderAccountSummary
    ) -> some View {
        let (text, icon): (String, String)
        switch summary.authorizationState {
        case .connected:
            text = "已连接"
            icon = "checkmark.circle.fill"
        case .needsReauthorization:
            text = "需要重新登录"
            icon = "exclamationmark.triangle.fill"
        case .revoked:
            text = "已撤销"
            icon = "xmark.circle.fill"
        }
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(summary.authorizationState == .connected
                ? Color.secondary : Color.orange)
            .accessibilityLabel("\(summary.displayName) 状态: \(text)")
    }

    /// 非 API key 类 provider 的管理 section, 仅用于通用配置外壳;
    /// API key 类 (Kimi/DeepSeek/火山/智谱) 已由 APIKeyProviderConfigDialog 接管.
    @ViewBuilder
    private func subscriptionProviderManagement(
        _ id: SubscriptionProviderID
    ) -> some View {
        switch id {
        case .kimi, .deepseek, .volcengine, .zhipu:
            // 对话框版表单已接管, 通用外壳不会走到这里.
            EmptyView()
        case .codex:
            CodexProviderSettingsSection(
                showsCodexCCImportConfirm: $showsCodexCCImportConfirm,
                onRemove: { removeSubscriptionProvider(.codex) },
                onRemoveAccount: { accountID, displayName in
                    accountRemovalRequest = AccountRemovalRequest(
                        provider: .codex,
                        accountID: accountID,
                        displayName: displayName
                    )
                }
            )
        case .claude:
            ClaudeProviderSettingsSection(
                claudePasteText: $claudePasteText,
                claudeEditing: $claudeEditing,
                onRemove: { removeSubscriptionProvider(.claude) }
            )
        case .grok:
            GrokProviderSettingsSection(
                grokPasteText: $grokPasteText,
                grokEditing: $grokEditing,
                onRemove: { removeSubscriptionProvider(.grok) }
            )
        case .opencodeGo:
            OfficialLocalProviderSettingsSection(
                id: .opencodeGo,
                available: false,
                missingHint: "未检测到 OpenCode GO 登录态",
                pasteText: $opencodeGoPasteText,
                onRemove: { removeSubscriptionProvider(.opencodeGo) },
                importFromLocal: {},
                savePaste: { coordinator.importOpenCodeGoFromPaste($0) },
                pasteHint: "打开 opencode.ai → 登录 → 开发者工具 → Application → Cookies → 复制 auth 值 (Fe26.2**...) 与 workspace URL 中的 wrk_ ID, 粘贴 JSON",
                showsLocalRedetect: false,
                isEditing: $opencodeGoEditing
            )
        }
    }

    /// 移除 provider: 凭证与配置由 coordinator 处理 (fail-closed),
    /// 成功后该行从列表消失并回到添加 Picker.
    private func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        coordinator.removeSubscriptionProvider(id)
        addedSubscriptionProviders.remove(id)
    }

    /// 调整订阅 provider 在列表中的顺序; 顺序同时作用于面板用量卡展示.
    private func moveSubscriptionProvider(
        _ dragged: SubscriptionProviderID,
        onto target: SubscriptionProviderID
    ) {
        var order = visibleSubscriptionProviders
        order.removeAll { $0 == dragged }
        guard let targetIndex = order.firstIndex(of: target) else { return }
        order.insert(dragged, at: targetIndex)
        coordinator.setSubscriptionProviderOrder(order)
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

    // MARK: - 授权与隐私面板

    private var consentPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            FluentCard {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Agent 用量")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("允许按授权范围采集本机会话用量")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    Spacer()
                    Toggle("", isOn: moduleBinding(.agentUsage))
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                VStack(alignment: .leading, spacing: 6) {
                    Text("授权后应用将:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text2)
                    summaryLine("扫描本机 Agent 会话目录和 CC Switch 数据库 (只读)")
                    summaryLine("每 \(coordinator.refreshIntervalMinutes) 分钟自动刷新已授权模块")
                    let enabledProviders = coordinator
                        .enabledConfiguredSubscriptionProviders
                    if enabledProviders.isEmpty {
                        summaryLine("未配置启用的订阅额度 Provider, 不会访问云端额度接口")
                    } else {
                        let names = enabledProviders.map(\.displayName)
                            .joined(separator: " / ")
                        summaryLine("确认授权后查询已启用订阅 Provider 的云端额度: \(names)")
                    }
                    summaryLine("可随时在此撤销授权暂停采集")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }

                HStack {
                    if coordinator.consentConfirmed {
                        HStack(spacing: 6) {
                            FluentStatusDot(level: .ok)
                            Text("当前授权有效")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.ok)
                        }
                    }
                    Spacer()
                    if coordinator.consentConfirmed {
                        Button("撤销全部授权") {
                            coordinator.revokeAllConsent()
                        }
                        .fluentButton(.danger)
                        .accessibilityHint("停止所有模块的自动采集")
                    } else {
                        Button("确认授权") {
                            coordinator.confirmConsent(
                                selectedModules: coordinator.selectedModules
                            )
                        }
                        .fluentButton(.primary)
                        .disabled(coordinator.selectedModules.isEmpty)
                        .accessibilityHint("允许已选模块按 \(coordinator.refreshIntervalMinutes) 分钟周期采集")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }
            }
        }
    }

    // MARK: - 维护面板 (数据 + 诊断)

    /// 维护: 清理可再生缓存 (仅本应用快照), 账单导出, 诊断包预览与导出.
    private var maintenancePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneCaption("数据")
            FluentCard {
                FluentRow("清理用量缓存", sub: "仅删除本应用快照, 不影响配置, 凭证与账单统计") {
                    Button("清理") {
                        showsClearCacheConfirm = true
                    }
                    .fluentButton(.danger)
                    .accessibilityHint("删除本应用生成的快照缓存, 不影响配置与凭证")
                }
                FluentRow("导出账单", sub: "token 用量与花费统计 CSV", divided: true) {
                    Button("导出…") {
                        exportBilling()
                    }
                    .fluentButton()
                    .accessibilityHint("选择位置保存 token 用量与花费统计 CSV")
                }
                if let dataActionMessage {
                    Text(dataActionMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) {
                            SettingsDemoTokens.separator.frame(height: 1)
                        }
                }
            }

            paneCaption("诊断")
            FluentCard {
                FluentRow("诊断信息", sub: "最近采集错误与模块状态, 脱敏 JSON") {
                    Button("预览") {
                        do {
                            diagnosticsPreview = try diagnostics.preview()
                            model.setSettingsError(nil)
                            showsDiagnosticsPreview = true
                        } catch {
                            model.setSettingsError("诊断预览生成失败")
                        }
                    }
                    .fluentButton()
                    .accessibilityHint("显示导出前的脱敏 JSON 内容")
                }
                FluentRow("导出诊断包", sub: "脱敏后 zip, 不含 Artifact 与凭证", divided: true) {
                    Button("导出…") {
                        exportDiagnostics()
                    }
                    .fluentButton()
                    .accessibilityHint("选择位置保存不含业务数据的 ZIP 文件")
                }
            }
        }
        .confirmationDialog(
            "确认清理缓存?",
            isPresented: $showsClearCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("清理", role: .destructive) {
                clearCache()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅删除本应用生成的快照缓存, 配置, 凭证与账单统计不受影响")
        }
    }

    private func clearCache() {
        do {
            try coordinator.clearSnapshotCaches()
            dataActionMessage = "缓存已清理"
            model.setSettingsError(nil)
        } catch {
            dataActionMessage = nil
            model.setSettingsError("缓存清理失败")
        }
    }

    private func exportBilling() {
        guard let csv = model.billingReportCSV() else {
            model.setSettingsError("暂无可导出的用量数据, 请先刷新")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.billingFilename()
        panel.message = "导出 token 用量与花费统计 (CSV)"
        guard panel.runModal() == .OK, let destination = panel.url else {
            return
        }
        do {
            // BOM 保证 Excel 正确识别 UTF-8 中文.
            try ("\u{FEFF}" + csv).write(
                to: destination,
                atomically: true,
                encoding: .utf8
            )
            dataActionMessage = "账单已导出"
            model.setSettingsError(nil)
        } catch {
            dataActionMessage = nil
            model.setSettingsError("账单导出失败")
        }
    }

    private static func billingFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Bruce-billing-\(formatter.string(from: Date())).csv"
    }

    // MARK: - 诊断预览弹层

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
            .foregroundStyle(SettingsDemoTokens.text2)
    }

}

// MARK: - D3 实时让位拖动

/// D3 实时让位排序 (定稿 settings-layout-demo.html): 仅手柄可发起拖拽;
/// 悬停经过目标行时立即带着动画交换位置, 其他行实时滑动让位, 松手即落定.
/// dragged id 经 item provider 异步解析 (同进程约一帧), 连续 hover 由
/// `dragged != target` 去重; move 回调内部完成持久化.
private struct LiveReorderDropDelegate<ID: RawRepresentable & Equatable & Sendable>: DropDelegate
    where ID.RawValue == String
{
    let target: ID
    let move: (ID, ID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func dropEntered(info: DropInfo) {
        guard let provider = info.itemProviders(for: [.text]).first else { return }
        let target = self.target
        _ = provider.loadObject(ofClass: String.self) { raw, _ in
            guard let raw else { return }
            Task { @MainActor in
                guard let dragged = ID(rawValue: raw), dragged != target else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    move(dragged, target)
                }
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool { true }
}
