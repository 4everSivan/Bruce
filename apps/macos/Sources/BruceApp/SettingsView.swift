import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

/// 设置页: 左侧边栏分类导航 + 右侧单分类面板, Fluent 平面视觉
/// (token 与组件见 Settings/FluentSettingsChrome.swift, 1:1 对齐
/// _adflow_backup/original_docs/design/settings-layout-demo.html).
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var coordinator: OnboardingCoordinator
    @EnvironmentObject var diagnostics: DiagnosticService
    @EnvironmentObject var updates: SoftwareUpdateService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.motionSuppressed) var motionSuppressed

    /// 侧边栏选中分类.
    @State var category = SettingsCategory.general
    @State var diagnosticsPreview = ""
    @State var showsDiagnosticsPreview = false
    // 订阅额度分区输入态 (编辑态由配置对话框内部管理)
    @State var deepseekValues: [String: String] = [:]
    @State var volcengineValues: [String: String] = [:]
    @State var showsVolcengineCCImportConfirm = false
    @State var zhipuValues: [String: String] = [:]
    @State var zhipuSiteIsCN = true
    @State var kimiValues: [String: String] = [:]
    @State var stepfunValues: [String: String] = [:]
    @State var showsStepFunWebLogin = false
    @State var stepfunLoginSite: StepFunSite = .domestic
    @State var jevValues: [String: String] = [:]
    @State var clineValues: [String: String] = [:]
    @State var claudePasteText = ""
    @State var claudeEditing = false
    @State var grokPasteText = ""
    @State var grokEditing = false
    @State var opencodeGoPasteText = ""
    @State var opencodeGoEditing = false
    @State var showsCodexCCImportConfirm = false
    // 订阅额度标签式管理: 本次会话点击添加的 provider 与 P2 配置 sheet 目标
    @State var addedSubscriptionProviders: Set<SubscriptionProviderID> = []
    /// 当前在配置 sheet 中打开的 provider (P2 对话框).
    @State var configuringProvider: SubscriptionProviderID?
    @State var providerToAdd: SubscriptionProviderID?
    // 通知权限状态: denied 时预警通知无法投递, 提示用户前往系统设置
    @State var notificationDenied = false
    // 首次启动时引导配置 Bruce 自有 Keychain 访问权限
    @State var showsKeychainAccessGuide = false
    @State var didEvaluateKeychainAccessGuide = false
    // 外部 CLI 来源由独立 sheet 管理, 避免在通用页内堆叠两个开关.
    @State var showsExternalKeychainSourceManager = false
    // 数据管理: 清理确认与操作反馈
    @State var showsClearCacheConfirm = false
    @State var dataActionMessage: String?
    @State var accountRemovalRequest: AccountRemovalRequest?
    @State var accountRenameRequest: AccountRenameRequest?
    /// 统一悬浮错误胶囊状态 (C111: 零抖动、4s倒计时、手动✕关闭、Tab切换自动失效)
    @State private var activeToastMessage: String?

    struct AccountRemovalRequest {
        let provider: SubscriptionProviderID
        let accountID: String
        let displayName: String
    }

    /// 侧边栏分类: 线性图标 (跨平台同构, 对应 WinUI NavigationView).
    enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, agentUsage, modelPricing, subscription, consent, maintenance

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return "通用"
            case .agentUsage: return "模型用量"
            case .modelPricing: return "模型计费"
            case .subscription: return "订阅额度"
            case .consent: return "授权与隐私"
            case .maintenance: return "维护"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .agentUsage: return "chart.bar"
            case .modelPricing: return "dollarsign.circle"
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
            .overlay(alignment: .top) {
                // 统一悬浮极客高斯胶囊 (C111: 绝对 0px 布局抖动，8pt圆角 + 42pt高 + 420pt固定宽)
                if let message = activeToastMessage {
                    SettingsFloatingToastView(
                        message: message,
                        tone: .warn,
                        onDismiss: {
                            withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.2)) {
                                activeToastMessage = nil
                                model.setSettingsError(nil)
                            }
                        }
                    )
                    .padding(.top, 14)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
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
                withAnimation(motionSuppressed ? nil : .spring(response: 0.35, dampingFraction: 0.75)) {
                    activeToastMessage = message
                }
            } else {
                withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.2)) {
                    activeToastMessage = nil
                }
            }
        }
        .onChange(of: category) { _, _ in
            // Tab 切换自动清除当前页面的瞬时提示，杜绝跨 Tab 污染 (C111)
            if activeToastMessage != nil {
                withAnimation(motionSuppressed ? nil : .easeInOut(duration: 0.15)) {
                    activeToastMessage = nil
                    model.setSettingsError(nil)
                }
            }
        }
        .sheet(isPresented: $showsKeychainAccessGuide) {
            keychainAccessGuide
        }
        .onAppear {
            presentKeychainAccessGuideIfNeeded()
            if let initialError = model.settingsErrorMessage {
                activeToastMessage = initialError
            }
        }
    }

    // MARK: - 侧边栏

    /// L2 Fluent 侧栏 (定稿 settings-layout-demo.html): 216pt 平面导航,
    /// 线性图标 + 文字; 选中项浅底 + 左缘 3pt accent 指示条;
    /// 不依赖材质模糊与彩色图标底, 为跨平台 (WinUI NavigationView) 同构设计.
    var sidebar: some View {
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
                        // 方案 B: 有可用更新且未处理时角标挂「维护」项尾部.
                        if item == .maintenance && updates.phase.showsNavigationBadge {
                            SoftwareUpdateNavigationBadge()
                        }
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
            Text(updates.localVersion?.tag ?? AppVersion.current())
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
    var paneContent: some View {
        switch category {
        case .general: generalPane
        case .agentUsage: agentUsagePane
        case .modelPricing: modelPricingPane
        case .subscription: subscriptionPane
        case .consent: consentPane
        case .maintenance: maintenancePane
        }
    }

    var modelPricingPane: some View {
        ModelPricingSettingsView()
    }

    /// demo crumb: 面板标题上方的灰色小字分类名.
    func crumb(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11))
            .foregroundStyle(SettingsDemoTokens.text3)
    }

    /// demo .pane-title: 19px semibold 大标题.
    func paneTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(SettingsDemoTokens.text)
    }

    /// demo .caption: 11px semibold 灰色分组标题.
    func paneCaption(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(SettingsDemoTokens.text3)
            .padding(.leading, 2)
    }

    // MARK: - 通用面板

    /// 通用偏好: 外观, 界面风格, 模糊风格, 自动刷新与菜单栏指标.
    var generalPane: some View {
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
                    "仪表盘卡片布局",
                    sub: "纵向级联可滚轮纵览全部卡片；顶栏 Tab 切换通过右上角小图标在用量、订阅与活跃卡片间快速切换",
                    divided: true
                ) {
                    FluentSegmentedPicker(
                        options: [
                            ("纵向级联", DashboardLayoutMode.stack),
                            ("顶栏 Tab", DashboardLayoutMode.tabbed),
                        ],
                        selection: Binding(
                            get: { model.layoutMode },
                            set: { model.setLayoutMode($0) }
                        )
                    )
                }
                FluentRow(
                    "刷新间隔",
                    sub: "本地统计采集与订阅额度自动刷新周期；遇 429 限流时自动冷却",
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
                    "锁屏暂停订阅刷新",
                    sub: "电脑锁屏期间暂停查询云端订阅额度，避免消耗配额；解锁后自动恢复",
                    divided: true
                ) {
                    // C146: 状态由开关开合位置表达, 行内不再渲染「已开启 / 已关闭」.
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { coordinator.pauseSubscriptionRefreshOnScreenLock },
                            set: { coordinator.setPauseSubscriptionRefreshOnScreenLock($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
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
                // C145: 全局界面动效总开关. 「始终播放」只作用于 Bruce 自身动效,
                // 用于本机已开启系统「减弱动态效果」但希望看到应用内过渡的场景.
                FluentRow(
                    "界面动效",
                    sub: "关闭后全应用不做过渡动画; 「始终播放」会忽略系统「减弱动态效果」",
                    divided: true
                ) {
                    FluentSegmentedPicker(
                        options: [
                            ("跟随系统", MotionPreference.system),
                            ("始终播放", .always),
                            ("始终关闭", .never),
                        ],
                        selection: Binding(
                            get: { coordinator.motionPreference },
                            set: { coordinator.setMotionPreference($0) }
                        ),
                        accessibilityHintText: "选择界面动效策略"
                    )
                }
                FluentRow(
                    "凭据存储",
                    sub: "统一管理 Bruce 保存的订阅凭证访问权限",
                    divided: true
                ) {
                    HStack(spacing: 8) {
                        switch coordinator.keychainAccessState {
                        case .allowed:
                            Text("已配置")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.ok)
                            Button("重新配置") {
                                coordinator.configureKeychainAccess()
                            }
                            .fluentButton(.primary)
                        case .notConfigured:
                            Text("未配置")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.warn)
                            Button("配置") {
                                coordinator.configureKeychainAccess()
                            }
                            .fluentButton(.primary)
                        case .blocked:
                            Text("访问被阻断")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SettingsDemoTokens.warn)
                            Button("修复") {
                                coordinator.configureKeychainAccess()
                            }
                            .fluentButton(.primary)
                        }
                    }
                }
                FluentRow(
                    "外部 CLI 来源",
                    sub: "仅允许已明确开启的 Claude / Grok 本机来源, 不保存凭证内容",
                    divided: true
                ) {
                    Button("管理") {
                        showsExternalKeychainSourceManager = true
                    }
                    .fluentButton()
                }
                // 原「版本」行已迁入维护页「软件更新」卡 (07 §4.2 R3 方案 B), 避免同窗三处版本.
            }
            .sheet(isPresented: $showsExternalKeychainSourceManager) {
                ExternalKeychainSourceManagerView()
                    .environmentObject(coordinator)
            }

            paneCaption("全局快捷键")

            FluentCard {
                GlobalHotkeyRecorder()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            paneCaption("菜单栏指标")

            FluentCard {
                menuBarPreviewStrip

                SettingsDemoTokens.separator.frame(height: 1)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("仅显示图标")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("开启后菜单栏隐藏全部文本指标, 仅保留高精度配额环规图标")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { coordinator.menuBarIconOnly },
                        set: { coordinator.setMenuBarIconOnly($0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                if !coordinator.menuBarIconOnly {
                    SettingsDemoTokens.separator.frame(height: 1)
                    menuBarReorderableCardsSection
                }
            }
        }
    }

    /// 查询系统通知授权状态; 仅 denied 视为未开启, notDetermined 会在首次预警时弹授权.
    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in notificationDenied = denied }
        }
    }

    func presentKeychainAccessGuideIfNeeded() {
        guard !didEvaluateKeychainAccessGuide else { return }
        didEvaluateKeychainAccessGuide = true
        guard !coordinator.keychainAccessConfigured else {
            return
        }
        DispatchQueue.main.async {
            showsKeychainAccessGuide = true
        }
    }

    var keychainAccessGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("配置凭据存储", systemImage: "key.fill")
                .font(.system(size: 16, weight: .semibold))
            Text("Bruce 把订阅凭证保存在本应用的本机凭据文件中 (仅当前用户可读)。旧版本存入 macOS 钥匙串的凭证会在读取时自动迁移到该文件; 后台读取从不弹出系统密码框, 仅在你主动操作时系统才可能要求输入一次 macOS 登录密码。")
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
                .fluentButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    func moveMenuBarMetric(
        _ dragged: MenuBarMetric,
        onto target: MenuBarMetric
    ) {
        var metrics = model.menuBarMetrics
        guard let fromIndex = metrics.firstIndex(of: dragged),
              let toIndex = metrics.firstIndex(of: target),
              fromIndex != toIndex else {
            return
        }
        metrics.remove(at: fromIndex)
        metrics.insert(dragged, at: toIndex)
        coordinator.setMenuBarMetrics(metrics)
    }

    var isPreviewLight: Bool {
        switch coordinator.appearanceMode {
        case .light: return true
        case .dark: return false
        case .system: return colorScheme == .light
        }
    }

    var liveQuotaRatio: Double {
        let summary = model.makeMenuBarSummary()
        let quotaPercentage: Double?
        if model.menuBarMetrics.contains(.minimumRemainingQuota) {
            quotaPercentage = summary.minimumRemainingQuota ?? summary.averageRemainingQuota
        } else {
            quotaPercentage = summary.averageRemainingQuota ?? summary.minimumRemainingQuota
        }
        guard let percentage = quotaPercentage, percentage.isFinite else { return 0.68 }
        return max(0.0, min(100.0, percentage)) / 100.0
    }

    func metricValue(_ metric: MenuBarMetric) -> String {
        let summary = model.makeMenuBarSummary()
        let formatter = MenuBarMetricFormatter()
        return formatter.string(for: metric, summary: summary)
    }

    var menuBarPreviewText: String {
        let summary = model.makeMenuBarSummary()
        let formatter = MenuBarMetricFormatter()
        return model.menuBarMetrics.map { formatter.string(for: $0, summary: summary) }
            .joined(separator: "  ")
    }

    var menuBarPreviewIcon: some View {
        let ratio = liveQuotaRatio
        let isWarning = ratio < 0.15
        let greenColor = isPreviewLight
            ? Color(red: 0.11, green: 0.55, blue: 0.24)
            : Color(red: 0.19, green: 0.82, blue: 0.35)
        let activeColor = isWarning ? Color(red: 1.0, green: 0.27, blue: 0.23) : greenColor
        let trackColor = isPreviewLight
            ? Color.black.opacity(0.18)
            : Color.white.opacity(0.25)

        return ZStack {
            Circle()
                .stroke(trackColor, lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: CGFloat(ratio))
                .stroke(activeColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14)
    }

    /// 模拟 macOS 菜单栏条带预览.
    var menuBarPreviewStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("菜单栏实时预览")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text2)
                Spacer()
                Text("所见即所得 · 联动外观与排版")
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)

            ZStack(alignment: .top) {
                LinearGradient(
                    colors: isPreviewLight
                        ? [Color(hex: "D8E1EC"), Color(hex: "C2CFDE"), Color(hex: "B0C0D4")]
                        : [Color(hex: "101319"), Color(hex: "17202E"), Color(hex: "0C0E14")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 56)

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 12))
                        Text("Finder")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(isPreviewLight ? Color.black.opacity(0.85) : Color.white.opacity(0.9))

                    Spacer()

                    HStack(spacing: 6) {
                        menuBarPreviewIcon
                        if !coordinator.menuBarIconOnly {
                            Text(menuBarPreviewText)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                        }
                    }
                    .foregroundStyle(isPreviewLight ? Color.black.opacity(0.9) : Color.white.opacity(0.95))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isPreviewLight ? Color.black.opacity(0.06) : Color.white.opacity(0.12))
                    )

                    HStack(spacing: 8) {
                        Image(systemName: "wifi")
                            .font(.system(size: 10.5))
                        Image(systemName: "switch.2")
                            .font(.system(size: 10.5))
                        Text(Date.now, format: .dateTime.hour().minute())
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(isPreviewLight ? Color.black.opacity(0.7) : Color.white.opacity(0.75))
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    (isPreviewLight ? Color.white.opacity(0.7) : Color(hex: "12141A").opacity(0.7))
                        .background(.ultraThinMaterial)
                )
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isPreviewLight ? Color.black.opacity(0.08) : Color.white.opacity(0.08))
                        .frame(height: 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    /// 方案 B: 现代磁吸悬浮卡片区 (包含已选指标拖拽与待选指标池).
    var menuBarReorderableCardsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已选指标")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                Text("\(model.menuBarMetrics.count) / \(MenuBarMetricConfiguration.maximumCount)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }

            Text("菜单栏将按下列序号在左至右紧凑展示; 拖动点阵手柄调整顺序")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsDemoTokens.text2)

            VStack(spacing: 8) {
                ForEach(model.menuBarMetrics) { metric in
                    let order = (model.menuBarMetrics.firstIndex(of: metric) ?? 0) + 1
                    selectedMetricCard(metric, order: order)
                        .onDrop(
                            of: [.text],
                            delegate: LiveReorderDropDelegate<MenuBarMetric>(
                                target: metric,
                                motionSuppressed: motionSuppressed,
                                move: moveMenuBarMetric
                            )
                        )
                }
            }
            .animation(
                motionSuppressed ? nil : .spring(response: 0.25, dampingFraction: 0.8),
                value: model.menuBarMetrics
            )

            let unselected = MenuBarMetric.allCases.filter { !model.menuBarMetrics.contains($0) }
            if !unselected.isEmpty {
                SettingsDemoTokens.separator.frame(height: 1)
                    .padding(.vertical, 2)

                HStack {
                    Text("待选指标")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Spacer()
                    if model.menuBarMetrics.count >= MenuBarMetricConfiguration.maximumCount {
                        Text("已达到 3 项展示上限")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDemoTokens.warn)
                    }
                }

                VStack(spacing: 6) {
                    ForEach(unselected) { metric in
                        unselectedMetricCard(metric)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 现代悬浮卡片: 点阵手柄 + 序号 + 图标与名称 + 实时数值 + 移除按钮.
    func selectedMetricCard(_ metric: MenuBarMetric, order: Int) -> some View {
        let value = metricValue(metric)
        let canRemove = model.menuBarMetrics.count > 1

        return HStack(spacing: 10) {
            // 6 点点阵手柄
            VStack(spacing: 2.5) {
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
            .foregroundStyle(SettingsDemoTokens.text3)
            .frame(width: 14, height: 20)
            .contentShape(Rectangle())
            .draggable(metric.rawValue)
            .help("按住拖拽以调整指标在菜单栏的展示顺序")

            // 序号徽章
            Text("#\(order)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text2)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(SettingsDemoTokens.surfaceHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            // 图标与名称
            Image(systemName: metric.systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsDemoTokens.accent)
                .frame(width: 18)

            Text(metric.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsDemoTokens.text)

            Spacer()

            // 实时数值预览
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.ok)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(SettingsDemoTokens.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            // 移除按钮
            Button {
                var metrics = model.menuBarMetrics
                guard metrics.count > 1 else { return }
                metrics.removeAll { $0 == metric }
                withAnimation(motionSuppressed ? nil : .spring(response: 0.25, dampingFraction: 0.8)) {
                    coordinator.setMenuBarMetrics(metrics)
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13.5))
                    .foregroundStyle(canRemove ? SettingsDemoTokens.danger : SettingsDemoTokens.text3.opacity(0.3))
            }
            .buttonStyle(.plain)
            .disabled(!canRemove)
            .help(canRemove ? "从菜单栏移除" : "至少保留 1 项指标")
            .accessibilityLabel("移除\(metric.title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(SettingsDemoTokens.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    /// 待选指标卡片: 图标与名称 + 实时数值 + 添加按钮.
    func unselectedMetricCard(_ metric: MenuBarMetric) -> some View {
        let value = metricValue(metric)
        let isFull = model.menuBarMetrics.count >= MenuBarMetricConfiguration.maximumCount

        return HStack(spacing: 10) {
            Image(systemName: metric.systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsDemoTokens.text3)
                .frame(width: 18)

            Text(metric.title)
                .font(.system(size: 12.5))
                .foregroundStyle(SettingsDemoTokens.text2)

            Spacer()

            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text3)

            Button {
                var metrics = model.menuBarMetrics
                guard !metrics.contains(metric),
                      metrics.count < MenuBarMetricConfiguration.maximumCount else {
                    return
                }
                metrics.append(metric)
                withAnimation(motionSuppressed ? nil : .spring(response: 0.25, dampingFraction: 0.8)) {
                    coordinator.setMenuBarMetrics(metrics)
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isFull ? SettingsDemoTokens.text3.opacity(0.3) : SettingsDemoTokens.accent)
            }
            .buttonStyle(.plain)
            .disabled(isFull)
            .help(isFull ? "已达到 3 项展示上限" : "添加至菜单栏")
            .accessibilityLabel("添加\(metric.title)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(SettingsDemoTokens.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator.opacity(0.6), lineWidth: 1)
        )
        .opacity(isFull ? 0.6 : 1.0)
    }

    // MARK: - Agent 用量面板

    // MARK: - Agent 用量面板 (全景分析与 Token 统计工作台)

    var agentUsagePane: some View {
        AgentUsageWorkbenchView()
    }



    // MARK: - 授权与隐私面板

    var consentPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            FluentCard {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("模型用量")
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

    // MARK: - 维护面板 (软件更新 + 数据 + 诊断)

    /// 维护: 软件更新 (方案 B 置顶), 清理可再生缓存 (仅本应用快照), 账单导出, 诊断包预览与导出.
    var maintenancePane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneCaption(UpdateCopy.caption)
            SoftwareUpdateCard()

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

    func clearCache() {
        do {
            try coordinator.clearSnapshotCaches()
            dataActionMessage = "缓存已清理"
            model.setSettingsError(nil)
        } catch {
            dataActionMessage = nil
            model.setSettingsError("缓存清理失败")
        }
    }

    func exportBilling() {
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

    static func billingFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "Bruce-billing-\(formatter.string(from: Date())).csv"
    }

    // MARK: - 诊断预览弹层

    var diagnosticsPreviewSheet: some View {
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

    func exportDiagnostics() {
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

    func announce(_ message: String) {
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

    func moduleBinding(_ module: CollectorModule) -> Binding<Bool> {
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

    func summaryLine(_ text: String) -> some View {
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
struct LiveReorderDropDelegate<ID: RawRepresentable & Equatable & Sendable>: DropDelegate
    where ID.RawValue == String
{
    let target: ID
    let motionSuppressed: Bool
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
                withAnimation(motionSuppressed ? nil : .easeOut(duration: 0.15)) {
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
