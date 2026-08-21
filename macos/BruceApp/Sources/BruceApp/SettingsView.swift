import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 设置页: 左侧边栏分类导航 + 右侧单分类面板 (方案 A, 原型 settings-redesign-v1).
/// 状态同时使用图标和文字; 扫描或验证中的卡片只禁用对应按钮, 不阻塞其他模块.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @EnvironmentObject private var diagnostics: DiagnosticService

    /// 侧边栏选中分类.
    @State private var category = SettingsCategory.general
    @State private var diagnosticsPreview = ""
    @State private var showsDiagnosticsPreview = false
    // 订阅额度分区输入与编辑态
    @State private var deepseekKeyText = ""
    @State private var deepseekEditing = false
    @State private var volcengineAKText = ""
    @State private var volcengineSKText = ""
    @State private var volcengineEditing = false
    @State private var showsVolcengineCCImportConfirm = false
    @State private var zhipuKeyText = ""
    @State private var zhipuSiteIsCN = true
    @State private var zhipuEditing = false
    @State private var kimiKeyText = ""
    @State private var kimiEditing = false
    @State private var claudePasteText = ""
    @State private var grokPasteText = ""
    @State private var opencodeGoPasteText = ""
    @State private var opencodeGoEditing = false
    @State private var showsCodexCCImportConfirm = false
    // 订阅额度标签式管理: 本次会话点击添加的 provider 与展开态
    @State private var addedSubscriptionProviders: Set<SubscriptionProviderID> = []
    @State private var expandedSubscriptionProviders: Set<SubscriptionProviderID> = []
    @State private var providerToAdd: SubscriptionProviderID?
    // 通知权限状态: denied 时预警通知无法投递, 提示用户前往系统设置
    @State private var notificationDenied = false
    // 数据管理: 清理确认与操作反馈
    @State private var showsClearCacheConfirm = false
    @State private var dataActionMessage: String?
    @State private var accountRemovalRequest: AccountRemovalRequest?

    private struct AccountRemovalRequest {
        let provider: SubscriptionProviderID
        let accountID: String
        let displayName: String
    }

    /// 侧边栏分类: 图标色沿用原分区色条配色.
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
            case .agentUsage: return "chart.bar.fill"
            case .subscription: return "cloud.fill"
            case .consent: return "checkmark.shield.fill"
            case .maintenance: return "wrench.and.screwdriver.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general: return Color(hex: "#0a84ff")
            case .agentUsage: return Color(hex: "#30d158")
            case .subscription: return Color(hex: "#ff9f0a")
            case .consent: return Color(hex: "#bf5af2")
            case .maintenance: return Color(hex: "#8e8e93")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = model.settingsErrorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("设置错误: \(error)")
                    }
                    paneTitle(category.title)
                    paneContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .preferredColorScheme(coordinator.appearanceMode.colorScheme)
        .environment(\.BruceResolvedTheme, coordinator.resolvedTheme)
        .sheet(isPresented: $showsDiagnosticsPreview) {
            diagnosticsPreviewSheet
        }
        .onChange(of: model.settingsErrorMessage) { _, message in
            if let message {
                announce(message)
            }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsCategory.allCases) { item in
                Button {
                    category = item
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 21, height: 21)
                            .background(
                                item.tint,
                                in: RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            )
                        Text(item.title)
                            .font(.system(
                                size: 12.5,
                                weight: category == item ? .semibold : .medium
                            ))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        category == item ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(SidebarMaterialView())
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

    /// 面板大标题.
    private func paneTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
    }

    /// 面板内次级分组标题 (如「菜单栏指标」).
    private func paneCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    // MARK: - 通用面板

    /// 通用偏好: 外观, 界面风格, 模糊风格, 自动刷新与菜单栏指标.
    private var generalPane: some View {
        let glassSupported = coordinator.liquidGlassSupported()
        let showBlurStyles = glassSupported
            && coordinator.resolvedTheme.interfaceStyle == .liquidGlass

        return VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                Picker(
                    "配色模式",
                    selection: Binding(
                        get: { coordinator.appearanceMode },
                        set: { coordinator.setAppearanceMode($0) }
                    )
                ) {
                    Text("跟随系统").tag(AppearancePreference.system)
                    Text("浅色").tag(AppearancePreference.light)
                    Text("深色").tag(AppearancePreference.dark)
                }
                .pickerStyle(.segmented)
                .accessibilityHint("立即作用于菜单栏面板与本设置窗口, 跟随系统时与 macOS 外观一致")

                VStack(alignment: .leading, spacing: 6) {
                    Picker(
                        "界面风格",
                        selection: Binding(
                            get: { coordinator.interfaceStyle },
                            set: { coordinator.setInterfaceStyle($0) }
                        )
                    ) {
                        Text("经典").tag(InterfaceStylePreference.classic)
                        Text("液态玻璃").tag(InterfaceStylePreference.liquidGlass)
                    }
                    .pickerStyle(.segmented)
                    // 不支持液态玻璃时整段禁用 (强制经典), 旁注说明原因.
                    .disabled(!glassSupported)
                    .opacity(glassSupported ? 1 : 0.55)
                    .accessibilityHint(
                        glassSupported
                            ? "经典为材质面板; 液态玻璃使用系统玻璃效果"
                            : "液态玻璃需要 macOS 26; 当前仅可使用经典"
                    )
                    if !glassSupported {
                        Text("液态玻璃需要 macOS 26 或更高版本")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if showBlurStyles {
                    Picker(
                        "模糊风格",
                        selection: Binding(
                            get: { coordinator.glassStyle },
                            set: { coordinator.setGlassStyle($0) }
                        )
                    ) {
                        Text("标准").tag(GlassStylePreference.regular)
                        Text("通透").tag(GlassStylePreference.clear)
                        Text("哑光").tag(GlassStylePreference.material)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityHint("标准与通透为系统液态玻璃, 哑光退化为材质质感")
                }

                Picker(
                    "刷新间隔",
                    selection: Binding(
                        get: { coordinator.refreshIntervalMinutes },
                        set: { coordinator.setRefreshIntervalMinutes($0) }
                    )
                ) {
                    ForEach(
                        OnboardingConfiguration.allowedRefreshIntervalMinutes,
                        id: \.self
                    ) { minutes in
                        Text("\(minutes) 分钟").tag(minutes)
                    }
                }
                .accessibilityHint("已授权模块的自动采集周期, 变更后立即按新间隔重新计时")

                HStack {
                    Label("系统通知", systemImage: "bell.badge")
                    Spacer()
                    if notificationDenied {
                        Text("未开启")
                            .foregroundStyle(.orange)
                        Button("前往系统设置") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
                            )
                        }
                        .accessibilityHint("打开系统设置的通知面板, 为本应用开启通知权限")
                    } else {
                        Text("已开启")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(notificationDenied ? "系统通知未开启" : "系统通知已开启")
                .onAppear(perform: refreshNotificationStatus)

                LabeledContent("版本", value: AppVersion.current())
            }
            .glassButtonStyle()

            paneCaption("全局快捷键")

            SettingsCard {
                GlobalHotkeyRecorder()
            }
            .glassButtonStyle()

            paneCaption("菜单栏指标")

            SettingsCard {
                Text("选择 1 至 3 项指标, 菜单栏将按下列顺序紧凑展示; 拖拽已选指标调整顺序")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                menuBarMetricList
            }
            .glassButtonStyle()
        }
    }

    /// 查询系统通知授权状态; 仅 denied 视为未开启, notDetermined 会在首次预警时弹授权.
    private func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in notificationDenied = denied }
        }
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
        VStack {
            ForEach(model.menuBarMetrics) { metric in
                menuBarMetricRow(metric, selected: true)
                    .draggable(metric.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let dragged = MenuBarMetric(rawValue: raw),
                              dragged != metric else { return false }
                        moveMenuBarMetric(dragged, onto: metric)
                        return true
                    }
            }
            ForEach(
                MenuBarMetric.allCases.filter { !model.menuBarMetrics.contains($0) }
            ) { metric in
                menuBarMetricRow(metric, selected: false)
            }
        }
    }

    /// 单个菜单栏指标行: 已选行有拖拽手柄和移除按钮, 未选行有添加按钮.
    private func menuBarMetricRow(_ metric: MenuBarMetric, selected: Bool) -> some View {
        HStack {
            if selected {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Label(metric.title, systemImage: metric.systemImage)
                .font(.subheadline)
                .foregroundStyle(selected ? .primary : .secondary)
            Spacer()
            if selected {
                Button {
                    var metrics = model.menuBarMetrics
                    guard metrics.count > 1 else { return }
                    metrics.removeAll { $0 == metric }
                    coordinator.setMenuBarMetrics(metrics)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.red)
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
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(
                    model.menuBarMetrics.count >= MenuBarMetricConfiguration.maximumCount
                )
                .accessibilityLabel("添加\(metric.title)")
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
            SettingsCard {
                LabeledContent("Rust Collector") {
                    statusText(
                        rustAvailable ? "可用" : "不可用",
                        icon: rustAvailable
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                }
                sessionSourceTagsSection(sessionProbes)
                ForEach(visibleAgentUsageWarnings(result?.warnings ?? []), id: \.self) { warning in
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
            .glassButtonStyle()
        }
    }

    /// Kimi Work 和 Antigravity 属于可选增强探测, 不在 Agent 用量配置卡片中展示
    /// 其本机不可用/数据库状态提示; 探测结果仍保留给 readiness 和诊断流程.
    private func visibleAgentUsageWarnings(_ warnings: [String]) -> [String] {
        warnings.filter { warning in
            !warning.hasPrefix("Kimi Work ")
                && !warning.hasPrefix("Antigravity 数据库:")
        }
    }

    /// 有效会话源: 药丸标签展示; 本机可用绿色, 不可用灰色; 只展示不可点.
    private func sessionSourceTagsSection(_ probes: [DependencyProbe]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("有效会话源")
            if probes.isEmpty {
                Text("尚未检查, 点击下方重新检查")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SessionSourceFlowLayout(spacing: 6) {
                    ForEach(Array(probes.enumerated()), id: \.offset) { _, probe in
                        sessionSourcePill(
                            name: probe.detail ?? "会话源",
                            available: probe.status == .available
                        )
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("有效会话源")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 药丸标签: 中间为 agent 名称; 绿 = 本机目录可用, 灰 = 未发现.
    private func sessionSourcePill(name: String, available: Bool) -> some View {
        Text(name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(available ? Color.white : Color.secondary)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        available
                            ? Color.green.opacity(0.85)
                            : Color.secondary.opacity(0.16)
                    )
            )
            .accessibilityLabel("\(name), \(available ? "本机可用" : "本机未发现")")
            .accessibilityAddTraits(.isStaticText)
    }

    // MARK: - 订阅额度面板

    /// 订阅 provider 的标签式管理: 顶部 Picker 只列未配置的 provider,
    /// 点击添加后其管理组出现在下方列表 (默认收起为一行).
    /// 读取本机文件和真实网络验证都只由用户点击触发;
    /// 失败经 model.settingsErrorMessage 提示 (fail-closed).
    private var subscriptionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
            Text("配置并启用后, Agent 用量将在统一授权生效时查询对应云端额度; 拖拽行调整看板展示顺序")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !unconfiguredSubscriptionProviders.isEmpty {
                HStack {
                    Picker("添加 Provider", selection: $providerToAdd) {
                        Text("选择 Provider")
                            .tag(SubscriptionProviderID?.none)
                        ForEach(unconfiguredSubscriptionProviders, id: \.self) { id in
                            Text(id.displayName)
                                .tag(SubscriptionProviderID?.some(id))
                        }
                    }
                    .accessibilityHint("只列出尚未配置的订阅 Provider")
                    Button("添加") {
                        guard let id = providerToAdd else { return }
                        // Phase 4: 持久化"已添加"状态, 跨会话保持
                        coordinator.addSubscriptionProvider(id)
                        addedSubscriptionProviders.insert(id)
                        expandedSubscriptionProviders.insert(id)
                        providerToAdd = nil
                    }
                    .disabled(providerToAdd == nil)
                    .accessibilityHint("将所选 Provider 加入下方已配置列表并展开")
                }
            }
            if visibleSubscriptionProviders.isEmpty {
                Text("尚未配置任何订阅 Provider, 从上方选择并添加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleSubscriptionProviders, id: \.self) { id in
                subscriptionProviderRow(id)
                    .draggable(id.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        guard let raw = items.first,
                              let dragged = SubscriptionProviderID(rawValue: raw),
                              dragged != id else { return false }
                        moveSubscriptionProvider(dragged, onto: id)
                        return true
                    }
            }
            }
            .accessibilityElement(children: .contain)
            .glassButtonStyle()
        }
        .onAppear {
            coordinator.refreshAntigravityLocalAvailability()
            coordinator.refreshOfficialLocalAvailability()
        }
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

    /// 单个 provider 行: 收起时为一行 (名称 + 状态 + 启用开关),
    /// 点击名称展开现有管理 UI (凭证录入 / 导入 / 验证 / 移除).
    private func subscriptionProviderRow(
        _ id: SubscriptionProviderID
    ) -> some View {
        let expanded = expandedSubscriptionProviders.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Button {
                    if expanded {
                        expandedSubscriptionProviders.remove(id)
                    } else {
                        expandedSubscriptionProviders.insert(id)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(id.displayName)
                            .font(.subheadline.weight(.medium))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(id.displayName) \(expanded ? "收起" : "展开")")
                Spacer()
                subscriptionStatusLine(id)
                subscriptionEnabledToggle(id)
            }
            if expanded {
                providerAccountList(id)
                subscriptionProviderManagement(id)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
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

    /// 展开后的管理 UI, 委托各 provider 独立 section (layout-identical extract).
    @ViewBuilder
    private func subscriptionProviderManagement(
        _ id: SubscriptionProviderID
    ) -> some View {
        switch id {
        case .kimi:
            KimiProviderSettingsSection(
                kimiKeyText: $kimiKeyText,
                kimiEditing: $kimiEditing,
                onRemove: { removeSubscriptionProvider(.kimi) }
            )
        case .deepseek:
            DeepSeekProviderSettingsSection(
                deepseekKeyText: $deepseekKeyText,
                deepseekEditing: $deepseekEditing,
                onRemove: { removeSubscriptionProvider(.deepseek) }
            )
        case .volcengine:
            VolcengineProviderSettingsSection(
                volcengineAKText: $volcengineAKText,
                volcengineSKText: $volcengineSKText,
                volcengineEditing: $volcengineEditing,
                showsVolcengineCCImportConfirm: $showsVolcengineCCImportConfirm,
                onRemove: { removeSubscriptionProvider(.volcengine) }
            )
        case .zhipu:
            ZhipuProviderSettingsSection(
                zhipuKeyText: $zhipuKeyText,
                zhipuSiteIsCN: $zhipuSiteIsCN,
                zhipuEditing: $zhipuEditing,
                onRemove: { removeSubscriptionProvider(.zhipu) }
            )
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
        case .antigravity:
            AntigravityProviderSettingsSection(
                onRemove: { removeSubscriptionProvider(.antigravity) }
            )
        case .claude:
            ClaudeProviderSettingsSection(
                claudePasteText: $claudePasteText,
                onRemove: { removeSubscriptionProvider(.claude) }
            )
        case .grok:
            GrokProviderSettingsSection(
                grokPasteText: $grokPasteText,
                onRemove: { removeSubscriptionProvider(.grok) }
            )
        case .opencodeGo:
            OpenCodeGoProviderSettingsSection(
                opencodeGoPasteText: $opencodeGoPasteText,
                opencodeGoEditing: $opencodeGoEditing,
                onRemove: { removeSubscriptionProvider(.opencodeGo) }
            )
        }
    }

    /// 移除 provider: 凭证与配置由 coordinator 处理 (fail-closed),
    /// 成功后该行从列表消失并回到添加 Picker.
    private func removeSubscriptionProvider(_ id: SubscriptionProviderID) {
        coordinator.removeSubscriptionProvider(id)
        addedSubscriptionProviders.remove(id)
        expandedSubscriptionProviders.remove(id)
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
            SettingsCard {
            Toggle("Agent 用量", isOn: moduleBinding(.agentUsage))

            VStack(alignment: .leading, spacing: 6) {
                Text("授权后应用将:")
                    .font(.subheadline.weight(.medium))
                summaryLine("扫描本机 Agent 会话目录和 CC Switch / Antigravity 数据库 (只读)")
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
                .accessibilityHint("允许已选模块按 \(coordinator.refreshIntervalMinutes) 分钟周期采集")
            }
            }
            .glassButtonStyle()
        }
    }

    // MARK: - 维护面板 (数据 + 诊断)

    /// 维护: 清理可再生缓存 (仅本应用快照), 账单导出, 诊断包预览与导出.
    private var maintenancePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneCaption("数据")
            SettingsCard {
            Text("缓存仅包含本应用生成的快照数据, 清理后下次刷新自动重建; 不影响配置, 凭证与账单统计")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("清理缓存") {
                    showsClearCacheConfirm = true
                }
                .accessibilityHint("删除本应用生成的快照缓存, 不影响配置与凭证")
                Button("导出账单…") {
                    exportBilling()
                }
                .accessibilityHint("选择位置保存 token 用量与花费统计 CSV")
            }
            if let dataActionMessage {
                Text(dataActionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }
            .glassButtonStyle()

            paneCaption("诊断")
            SettingsCard {
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
            .glassButtonStyle()
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
            .foregroundStyle(.secondary)
    }

    private func statusText(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
    }

}

// MARK: - 侧边栏材质

/// 系统 .sidebar 毛玻璃材质: 与窗口底色自然融合, 替代死板纯灰.
private struct SidebarMaterialView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - 会话源标签流式布局

/// 从左到右排布子视图, 超出宽度自动换行 (设置页有效会话源药丸标签).
private struct SessionSourceFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let frames = arrange(proposal: proposal, subviews: subviews).frames
        for index in subviews.indices {
            guard index < frames.count else { continue }
            let frame = frames[index]
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
        }

        let height = subviews.isEmpty ? 0 : y + rowHeight
        return (CGSize(width: totalWidth, height: height), frames)
    }
}
