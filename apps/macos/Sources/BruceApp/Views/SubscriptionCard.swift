import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - Nothing 主题视图级 token

/// Nothing 主题本文件级颜色 token: 数值唯一来源为定稿原型
/// _adflow_backup/original_docs/design/dashboard-nothing-prototype.html (勿自创数值).
/// 仅在 `theme.interfaceStyle == .nothing` 分支消费;
/// classic / liquidGlass 代码路径绝不可触碰.
private enum NothingTokens {
    /// 文字 display: dark #FFFFFF / light #000000.
    static func display(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#FFFFFF") : Color(hex: "#000000")
    }

    /// 文字 secondary: dark #999999 / light #666666.
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#999999") : Color(hex: "#666666")
    }

    /// 文字 disabled: dark #666666 / light #999999.
    static func disabled(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#666666") : Color(hex: "#999999")
    }

    /// 常规边框: dark #222222 / light #E8E8E8.
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#222222") : Color(hex: "#E8E8E8")
    }

    /// 加强边框: dark #333333 / light #CCCCCC.
    static func borderVisible(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#333333") : Color(hex: "#CCCCCC")
    }

    /// 抬升表面 (嵌套卡片底): dark #1A1A1A / light #F0F0F0 (与 UsageHeroCard.nothingSurfaceRaised 同值).
    static func surfaceRaised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#1A1A1A") : Color(hex: "#F0F0F0")
    }

    /// 分段量条空段填充: dark #222222 / light #E0E0E0 (任务定稿口径).
    static func emptySegment(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#222222") : Color(hex: "#E0E0E0")
    }

    /// 阈值三色 (两模式一致): <50 success / 50-79 warning / >=80 accent.
    static let success = Color(hex: "#4A9E5C")
    static let warning = Color(hex: "#D4A843")
    static let accent = Color(hex: "#D71921")
}

/// 阈值档位 → Nothing 阈值色的唯一映射点 (本文件内量条填充与百分比数字共用,
/// 不允许各处手写档位色).
private func nothingThresholdColor(for level: MeterLevel) -> Color {
    switch level {
    case .normal:
        NothingTokens.success
    case .warning:
        NothingTokens.warning
    case .critical:
        NothingTokens.accent
    }
}

// 订阅用量卡: 原生 SwiftUI 版, 视觉以 panel-layout-v8.html 的订阅用量区为准.
// 只排内容, 卡片容器 (液态玻璃背景, 圆角, 阴影) 由 wave 3 统一装配.
// 数据全部来自 BruceAppCore 的 SubscriptionViewModel, 组件不读取任何凭证或 artifact.

/// 订阅用量卡: 标题行 + 若干 provider 段, 段间 1pt 分隔线.
/// 每个 provider 段头部行尾带独立定向刷新按钮 (设计契约), 状态与动作
/// 全部经参数注入; 组件不读取凭证, artifact 或 AppModel.
struct SubscriptionCard: View {
    let viewModel: SubscriptionViewModel
    /// 卡片收起态 (定稿方案 C 变体 2): 收起时只渲染标题行 + 迷你摘要.
    var isCollapsed: Bool = false
    var onToggleCollapse: () -> Void = {}
    /// 各 Provider 刷新按钮呈现状态, key 为 SubscriptionProviderID rawValue;
    /// section 无法归一为已知 Provider 或缺键时不渲染按钮 (fail-closed).
    var refreshControls: [String: SubscriptionRefreshControlPresentation] = [:]
    /// Provider 定向刷新动作; 目标由 section ID 经
    /// SubscriptionRefreshControlPolicy 解析, 与按钮禁用态共用同一解析.
    var onRefreshProvider: (SubscriptionProviderID) -> Void = { _ in }
    var onOpenSubscriptionSettings: () -> Void = {}
    /// 面板可见性: 隐藏时不得挂载逐帧动画载体 (C044, 见 DashboardPanelAnimationPolicy).
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed
    /// 展开态正文的自然高度 (C148); 折叠时容器按显式高度动画收到 0.
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleCardHeader(
                title: "订阅用量",
                isCollapsed: isCollapsed,
                onToggle: onToggleCollapse,
                cardID: .subscription
            ) {
                EmptyView()
            } mini: {
                collapsedMini
            }

            // C148: 正文高度是显式可动画值, 由标题行按钮的同一条 withAnimation 驱动.
            ZStack(alignment: .top) {
                if !isCollapsed {
                    expandedContent
                        .readingNaturalHeight(into: $expandedHeight)
                        // C148: 正文淡出比外框收拢更快收尾, 避免半透明文字在收拢过程中拖成残影.
                        .transition(.opacity.animation(motionSuppressed ? nil : .easeOut(duration: 0.22)))
                }
            }
            .frame(
                height: isCollapsed
                    ? DashboardSwapHeight.collapsed
                    : DashboardSwapHeight.target(measured: expandedHeight),
                alignment: .top
            )
            .clipped()
        }
        .clipped()
    }

    /// 展开态内容 (不含标题行; 标题行由 CollapsibleCardHeader 承担).
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(
                            theme.interfaceStyle == .nothing
                                ? NothingTokens.border(colorScheme)
                                : Color.adaptive(
                                    light: Color.black.opacity(0.05),
                                    dark: Color.white.opacity(0.10)
                                )
                        )
                        .frame(height: 1)
                }
                ProviderSectionView(
                    section: section,
                    isFirst: index == 0,
                    refreshControl: refreshControl(for: section),
                    onOpenSettings: onOpenSubscriptionSettings,
                    panelVisible: panelVisible
                )
            }

            // 订阅卡底栏: 左侧为 Nothing 三档阈值图例, 右侧与图例平齐展示最后刷新时间 (updatedText).
            SubscriptionFooterView(
                updatedText: viewModel.updatedText,
                isNothing: theme.interfaceStyle == .nothing,
                colorScheme: colorScheme
            )
        }
    }

    // MARK: 收起态迷你摘要

    /// 收起态: 各 provider 一组「品牌字母徽章 + 迷你量条」,
    /// 量条取该 provider 最紧张窗口 (collapsedPeakWindow), 三档告警配色;
    /// 无窗口的 provider (纯余额型) 不出迷你量条.
    private var collapsedMini: some View {
        let sections = viewModel.sections.filter { $0.collapsedPeakWindow != nil || $0.egress?.status == .blocked }
        return HStack(spacing: 10) {
            ForEach(sections, id: \.id) { section in
                    HStack(spacing: 5) {
                        ProviderBrandBadge(
                            providerID: section.badgeProviderID,
                            name: section.name
                        )
                        .overlay(alignment: .topTrailing) {
                            if section.egress?.status == .blocked {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                            }
                        }
                        if let peak = section.collapsedPeakWindow {
                            MiniMeterBar(usedFraction: peak.usedPercent / 100, panelVisible: panelVisible)
                        }
                    }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// 解析 section 的刷新按钮呈现与动作; 未知 Provider 或缺呈现状态时
    /// 返回 nil, 该 section 不渲染刷新按钮.
    private func refreshControl(
        for section: SubscriptionProviderSection
    ) -> ProviderRefreshControl? {
        guard let provider = SubscriptionRefreshControlPolicy.providerID(
            forSectionID: section.id
        ), let presentation = refreshControls[provider.rawValue] else {
            return nil
        }
        return ProviderRefreshControl(
            presentation: presentation,
            action: { onRefreshProvider(provider) }
        )
    }
}

/// Provider 刷新按钮的呈现 + 动作对 (section 级注入值).
private struct ProviderRefreshControl {
    let presentation: SubscriptionRefreshControlPresentation
    let action: () -> Void
}

// MARK: - provider 段

/// 单个 provider 段: 品牌徽章 + 名称 + 余额胶囊 + 账号数, 下方窗口行 / 账号子卡.
/// 套餐名 (plan) 自 C024 起不在仪表盘展示, 统一在设置中心「订阅额度」行内呈现.
/// 多账号 (>=2) 默认折叠, 折叠态展示最关键窗口摘要; 展开后按账号子卡展示.
/// 头部行尾的定向刷新按钮与名称+chevron 展开按钮互为兄弟控件, 互不误触.
private struct ProviderSectionView: View {
    let section: SubscriptionProviderSection
    let isFirst: Bool
    /// 非 nil 时头部行尾渲染定向刷新按钮.
    var refreshControl: ProviderRefreshControl? = nil
    var onOpenSettings: () -> Void = {}
    /// 面板可见性: 隐藏时刷新指示回退静态图标, 不挂 ProgressView (C044).
    var panelVisible: Bool = true
    @Environment(\.motionSuppressed) private var motionSuppressed
    @State private var expanded = false
    /// 展开态账号列表的自然高度 (C148).
    @State private var accountsHeight: CGFloat = 0
    /// 折叠态摘要行的自然高度 (C148).
    @State private var collapsedRowHeight: CGFloat = 0

    /// 是否为纯余额型 Provider (无周期窗口, 且具备余额数据; 如 DeepSeek)
    private var isBalanceBased: Bool {
        section.windows.isEmpty && !section.isMultiAccount && section.balance != nil
    }

    /// 当前段是否处于出口阻断态: 问题卡单独放大上下留白, 不放行段保持原 3pt 节奏.
    private var isEgressBlocked: Bool {
        section.egress?.status == .blocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
                .padding(.bottom, isEgressBlocked ? 10 : 3)

            egressIssue

            if section.isMultiAccount {
                multiAccountContent
                    .animation(motionSuppressed ? nil : DashboardMotionTiming.contentResizeCurve, value: expanded)
            } else {
                singleAccountContent
            }

            // error/empty 段保留 collector 说明, 不静默吞掉.
            if !isEgressBlocked, (section.status == "error" || section.status == "empty"), let note = section.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#ff9f0a"))
                    .padding(.top, 2)
            }
            // C224: 单账号段 (含纯余额型) 沿用旧快照时标注上次成功时间, 与账号子卡同款;
            // 多账号段由各账号子卡自行呈现, 这里不重复.
            if !section.isMultiAccount, let lastSuccessText = section.lastSuccessText {
                Text(lastSuccessText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityLabel("这是上次成功的数据")
            }
        }
        .padding(.top, isFirst ? 10 : 8)
        .padding(.bottom, 8)
    }

    /// 出口阻断问题卡: 单行紧凑布局 (30pt) ——
    /// 图标 + 标题 + 1px 分隔 + 保护说明同排, 右侧去设置/重测;
    /// 标题行下与卡片下各 10pt, 避免卡片贴住标题与进度条.
    @ViewBuilder
    private var egressIssue: some View {
        if let egress = section.egress, egress.status == .blocked {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                Text(egress.cardTitleText)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                Rectangle()
                    .fill(Color.orange.opacity(0.30))
                    .frame(width: 1, height: 9)
                let snapshotHint = section.hasProtectedSnapshot ? " · 保持历史快照" : ""
                Text("已拦截查额以保护账号\(snapshotHint)")
                    .font(.system(size: 9))
                    .opacity(0.72)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 8)
                egressActions
            }
            .font(.system(size: 9))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 30)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .help(egressTooltip(egress))
            .padding(.bottom, 10)
        }
    }

    /// 问题卡右侧操作区: 去设置 / 重测 以 8pt 间距 + 1px 竖线分隔.
    private var egressActions: some View {
        HStack(spacing: 8) {
            Button("去设置", action: onOpenSettings)
                .buttonStyle(.plain)
            if let refreshControl {
                Rectangle()
                    .fill(Color.orange.opacity(0.28))
                    .frame(width: 1, height: 10)
                Button("重测", action: refreshControl.action)
                    .buttonStyle(.plain)
                    .disabled(!refreshControl.presentation.isEnabled)
            }
        }
        .font(.system(size: 9))
    }

    // MARK: 多账号内容

    @ViewBuilder
    private var multiAccountContent: some View {
        // C148: 两种状态的正文都保持自然高度, 容器高度只跟当前状态走一个数值,
        // 由外层 scope 的 `.animation(value: expanded)` 插值 —— 展开与收起都是单向行程.
        ZStack(alignment: .top) {
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(section.accounts, id: \.id) { account in
                        ProviderAccountCard(account: account, panelVisible: panelVisible)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 2)
                .readingNaturalHeight(into: $accountsHeight)
                .transition(.opacity.animation(motionSuppressed ? nil : .easeOut(duration: 0.20)))
            } else if let collapsed = section.collapsedWindow {
                WindowRowView(row: collapsed, panelVisible: panelVisible, protectedSnapshot: section.hasProtectedSnapshot)
                    .readingNaturalHeight(into: $collapsedRowHeight)
                    .transition(.opacity.animation(motionSuppressed ? nil : .easeOut(duration: 0.20)))
            }
        }
        .frame(
            height: DashboardSwapHeight.target(
                measured: expanded ? accountsHeight : collapsedRowHeight
            ),
            alignment: .top
        )
        .clipped()
    }

    // MARK: 单账号内容

    @ViewBuilder
    private var singleAccountContent: some View {
        if isBalanceBased {
            BalanceDualSlotView(section: section, panelVisible: panelVisible)
        } else {
            ForEach(section.windows, id: \.label) { row in
                WindowRowView(row: row, panelVisible: panelVisible, protectedSnapshot: section.hasProtectedSnapshot)
            }
        }
    }

    // MARK: 头部

    private var head: some View {
        HStack(spacing: 6) {
            ProviderBrandBadge(providerID: section.badgeProviderID, name: section.name)
                .accessibilityHidden(true)
            if section.isMultiAccount {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(section.name)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(section.name)
                    .font(.system(size: 11, weight: .semibold))
            }
            // 余额 (Credits / 货币) 仅在非双槽模式时作为头部元数据胶囊呈现；
            // 纯余额型 Provider (无 windows) 在正文以双槽结构完整呈现，避免头部重复拥挤。
            if !isBalanceBased, let balance = section.balance {
                BalanceChip(
                    amountText: balance.amountText,
                    amount: balance.amount,
                    accessibilityText: balance.label,
                    color: Color(hex: ProviderBrandPalette.hex(for: section.badgeProviderID)),
                    panelVisible: panelVisible
                )
            }
            if let accountCountText = section.accountCountText {
                Text(accountCountText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let egress = section.egress {
                if egress.status == .blocked {
                    // 阻断态: 不在标题旁重复输出阻断标题文本，保持展示目标出口纯净国旗
                    if let expected = egress.expected {
                        let flag = EgressCountryGroups.flagEmoji(for: expected)
                        if !flag.isEmpty {
                            Text(flag)
                                .font(.system(size: 12))
                                .help(egress.maskedIp.map { "探测出口：\($0) (阻断)" } ?? "出口探测阻断")
                        }
                    }
                } else if !egress.badgeText.isEmpty {
                    Text(egress.badgeText)
                        .font(.system(size: 12))
                        .help(egressTooltip(egress))
                }
            }
            if let extraText = section.extraText {
                Text(extraText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            // 定向刷新按钮钉在头部行尾 (契约: 单/多账号位置统一);
            // 与展开/折叠按钮是兄弟控件, 点击不改变折叠状态.
            if let refreshControl {
                Spacer(minLength: 8)
                ProviderRefreshButton(
                    presentation: refreshControl.presentation,
                    action: refreshControl.action,
                    panelVisible: panelVisible
                )
            }
        }
    }

    private func egressTooltip(_ egress: EgressPresentationInfo) -> String {
        // 阻断问题卡标题改为「出口 IP 泄漏」后, 国家对比信息由 tooltip 承载,
        // 保留隐私最小暴露原则: 只展示国家代码与脱敏 IP.
        if egress.status == .blocked,
           let expected = egress.expected,
           let observed = egress.observed,
           !expected.isEmpty, !observed.isEmpty,
           expected != observed {
            let ipSuffix = egress.maskedIp.map { " · 出口 IP：\($0)" } ?? ""
            return "预期 \(expected) · 探测为 \(observed)\(ipSuffix)"
        }
        let expectedSuffix = egress.expected.map { " (\($0))" } ?? ""
        if let maskedIp = egress.maskedIp {
            return "探测出口：\(maskedIp)\(expectedSuffix)"
        } else if let expected = egress.expected {
            return "预设出口：\(expected)"
        } else {
            return "出口已校验放行"
        }
    }
}

// MARK: - Provider 定向刷新按钮

/// Provider 头部行尾的定向刷新按钮 (设计契约): 常态 arrow.clockwise;
/// 目标 Provider 刷新中替换为小型进度指示并禁用; 全量刷新中 / 未配置 /
/// 未启用 / 模块不可运行时禁用. 固定内容框, 状态切换不引发布局抖动.
/// 呈现快照由 SubscriptionRefreshControlPolicy 计算, 本组件不含业务判断.
///
/// C044: 面板隐藏时不挂载 `ProgressView` (系统不确定进度逐帧驱动,
/// 定向刷新最长 90s, 隐藏面板会持续逐帧布局), 门控判定归 DashboardPanelAnimationPolicy.
private struct ProviderRefreshButton: View {
    let presentation: SubscriptionRefreshControlPresentation
    let action: () -> Void
    var panelVisible: Bool = true

    private var showsProgress: Bool {
        presentation.showsProgress
            && DashboardPanelAnimationPolicy.allowsRefreshProgress(panelVisible: panelVisible)
    }

    var body: some View {
        Button(action: action) {
            Group {
                if showsProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // 进行中保留进度指示原色; 其余禁用态降透明度给出明确不可点反馈.
        .opacity(presentation.isEnabled || presentation.showsProgress ? 1 : 0.45)
        .disabled(!presentation.isEnabled)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(presentation.accessibilityHint)
    }
}

// MARK: - 余额型订阅双槽对称视图 (方案 B / C018)

/// 余额型订阅双槽对称视图 (方案 B / C018):
/// 左槽: 可用余额 (标题 + 加粗等宽主数值)
/// 右槽: 消费或服务状态 (存在 monthlyUsage 时为本月消费，否则为套餐/服务状态)
/// 底部: 微型覆盖说明 (如 coverageText)
private struct BalanceDualSlotView: View {
    let section: SubscriptionProviderSection
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed

    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                leftSlot
                rightSlot
            }
    }
        .padding(.top, 4)
        .padding(.bottom, 2)
    }

    // MARK: - 左槽: 可用余额

    private var leftSlot: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("可用余额")
                .font(isNothing ? NothingFont.mono(9) : .system(size: 10))
                .foregroundStyle(isNothing ? NothingTokens.disabled(colorScheme) : .secondary)

            let balanceText = section.balance?.amountText ?? "--"
            Text(balanceText)
                .font(isNothing ? NothingFont.mono(13, weight: .bold) : .system(size: 14, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(value: section.balance?.amount ?? 0))
                .animation(
                    MeterMotionPolicy.animation(
                        for: .balance,
                        panelVisible: panelVisible,
                        motionSuppressed: motionSuppressed
                    ),
                    value: balanceText
                )
                // `--` 占位与数值之间切身份: 占位不参与滚动, 首个数值直接落定.
                .id(section.balance == nil)
                .foregroundStyle(isNothing ? NothingTokens.display(colorScheme) : Color.primary.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            isNothing
                ? NothingTokens.surfaceRaised(colorScheme)
                : Color.adaptive(
                    light: Color.black.opacity(0.035),
                    dark: Color.white.opacity(0.06)
                ),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isNothing
                        ? NothingTokens.border(colorScheme)
                        : Color.adaptive(
                            light: Color.black.opacity(0.065),
                            dark: Color.white.opacity(0.10)
                        ),
                    lineWidth: isNothing ? 1 : 0.5
                )
        )
    }

    // MARK: - 右槽: 订阅状态 (C020 起移除月度统计, 恒走状态分支)

    private var rightSlot: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("订阅状态")
                .font(isNothing ? NothingFont.mono(9) : .system(size: 10))
                .foregroundStyle(isNothing ? NothingTokens.disabled(colorScheme) : .secondary)

            HStack(spacing: 4) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 5, height: 5)
                // 套餐名不在仪表盘展示 (C024): 统一在设置中心「订阅额度」行内呈现.
                // C225: 态名与点色取顶部状态灯同一张映射表, 不再直出状态码、不再恒绿.
                let statusText = DashboardStatusToneResolver.statusLabel(for: section.status)
                Text(statusText)
                    .font(isNothing ? NothingFont.mono(11, weight: .medium) : .system(size: 12, weight: .medium))
                    .foregroundStyle(isNothing ? NothingTokens.secondary(colorScheme) : Color.primary.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            isNothing
                ? NothingTokens.surfaceRaised(colorScheme)
                : Color.adaptive(
                    light: Color.black.opacity(0.035),
                    dark: Color.white.opacity(0.06)
                ),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isNothing
                        ? NothingTokens.border(colorScheme)
                        : Color.adaptive(
                            light: Color.black.opacity(0.065),
                            dark: Color.white.opacity(0.10)
                        ),
                    lineWidth: isNothing ? 1 : 0.5
                )
        )
    }

    /// C225: 状态点按 section.status 的灯色语义取订阅阈值三色; 中性态用 disabled 灰.
    private var statusDotColor: Color {
        switch DashboardStatusToneResolver.sectionTone(for: section.status) {
        case .ok:
            NothingTokens.success
        case .warn:
            NothingTokens.warning
        case .error:
            NothingTokens.accent
        case .neutral:
            NothingTokens.disabled(colorScheme)
        }
    }
}

// MARK: - 窗口行

/// 窗口量条行: label 固定 62pt + 量条 + 百分比固定 46pt + 重置文案固定 48pt.
/// ownRow 行在本布局中天然独占一行, 不做缩进或并排处理.
private struct WindowRowView: View {
    let row: SubscriptionWindowRow
    var animateEntrance: Bool = true
    /// C044/C158: 面板隐藏时不挂更新动画.
    var panelVisible: Bool = true
    var protectedSnapshot: Bool = false

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed

    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(isNothing ? NothingFont.mono(10) : .system(size: 10))
                .foregroundStyle(labelStyle)
                .frame(width: 62, alignment: .leading)
            // usedPercent 是已用比例, 量条从 0 向 100 填充已用量 (消耗式);
            // 百分比文字 percentText 同样是已用值 (如 "68%"), 与量条语义一致.
            let meterLevel = MeterLevel(usedPercent: row.usedPercent)
            MeterBar(
                usedFraction: row.usedPercent / 100,
                level: meterLevel,
                animateEntrance: animateEntrance,
                panelVisible: panelVisible
            )
            // Nothing 下百分比按档位取阈值色 (定稿 .meter-head .v),
            // classic / liquidGlass 保持默认前景色不变.
            if isNothing {
                percentText(meterLevel)
                    .foregroundStyle(nothingThresholdColor(for: meterLevel))
                    .animation(
                        MeterMotionPolicy.animation(
                            for: .thresholdColor,
                            panelVisible: panelVisible,
                            motionSuppressed: motionSuppressed
                        ),
                        value: meterLevel
                    )
            } else {
                percentText(meterLevel)
            }
            Text(row.resetText)
                .font(isNothing ? NothingFont.mono(9) : .system(size: 9))
                .foregroundStyle(resetStyle)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2.5)
        .accessibilityElement(children: .combine)
    }

    /// 百分比数字与量条同拍滚动: numericText 逐位上下滚动, 方向由 usedPercent 决定.
    private func percentText(_ level: MeterLevel) -> some View {
        Text(row.percentText)
            .font(isNothing ? NothingFont.mono(12, weight: .bold) : .system(size: 10, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: row.usedPercent))
            .animation(
                MeterMotionPolicy.animation(
                    for: .percent,
                    panelVisible: panelVisible,
                    motionSuppressed: motionSuppressed
                ),
                value: row.percentText
            )
            .frame(width: 46, alignment: .trailing)
    }

    private var labelStyle: AnyShapeStyle {
        isNothing
            ? AnyShapeStyle(NothingTokens.secondary(colorScheme))
            : AnyShapeStyle(.secondary)
    }

    private var resetStyle: AnyShapeStyle {
        isNothing
            ? AnyShapeStyle(NothingTokens.disabled(colorScheme))
            : AnyShapeStyle(.secondary)
    }
}

/// 收起态迷你量条: 5pt 高, 填充取该 provider 最紧张窗口的已用比例.
/// classic / liquidGlass: 与 MeterBar 同款三档渐变; Nothing: 直角 + 阈值纯色.
private struct MiniMeterBar: View {
    let usedFraction: Double
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed

    private var isNothing: Bool { theme.interfaceStyle == .nothing }
    private var level: MeterLevel { MeterLevel(usedPercent: usedFraction * 100) }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: isNothing ? 0 : 3, style: .continuous)
                    .fill(isNothing
                        ? NothingTokens.emptySegment(colorScheme)
                        : Color.adaptive(
                            light: Color.black.opacity(0.07),
                            dark: Color.white.opacity(0.12)
                        ))
                RoundedRectangle(cornerRadius: isNothing ? 0 : 3, style: .continuous)
                    .fill(fillStyle)
                    .frame(width: proxy.size.width * min(max(usedFraction, 0), 1))
                    .animation(
                        MeterMotionPolicy.animation(
                            for: .fill,
                            panelVisible: panelVisible,
                            motionSuppressed: motionSuppressed
                        ),
                        value: usedFraction
                    )
            }
        }
        .frame(height: 5)
    }

    private var fillStyle: AnyShapeStyle {
        if isNothing {
            return AnyShapeStyle(nothingThresholdColor(for: level))
        }
        let colors: [Color]
        switch level {
        case .normal:
            colors = [Color(hex: "#30d158"), Color(hex: "#66d4a3")]
        case .warning:
            colors = [Color(hex: "#ff9f0a"), Color(hex: "#ffd60a")]
        case .critical:
            colors = [Color(hex: "#ff453a"), Color(hex: "#ff6961")]
        }
        return AnyShapeStyle(LinearGradient(
            colors: colors, startPoint: .leading, endPoint: .trailing
        ))
    }
}

/// 量条告警级别 (消耗式, 阈值唯一来源, 全站统一口径不分主题):
/// 已用 <50% 绿 (normal), 50-79% 橙 (warning), >=80% 红 (critical).
private enum MeterLevel: Hashable {
    case normal
    case warning
    case critical

    init(usedPercent: Double) {
        switch usedPercent {
        case ..<50:
            self = .normal
        case 50..<80:
            self = .warning
        default:
            self = .critical
        }
    }

    static let all: [MeterLevel] = [.normal, .warning, .critical]
}

/// 量条: 消耗式填充 (已用量从 0 向 100 增长).
/// classic / liquidGlass: 高 5pt 圆角渐变条, 三档渐变叠放做 0.34s 交叉淡入;
/// 增长时附 2px 右缘高光 + 一次 46px 扫光. Nothing: 24 段方角分段条, 逐帧推进,
/// 动画期前沿段提亮. 更新动效只挂叶子, 时长 / 曲线 / 门控统一取自 MeterMotionPolicy.
private struct MeterBar: View {
    let usedFraction: Double
    let level: MeterLevel
    var animateEntrance: Bool = true
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed
    @State private var appeared = false
    @State private var isMoving = false
    @State private var isGrowing = false
    @State private var motionToken = 0
    @State private var sheenPhase: CGFloat = 0

    var body: some View {
        Group {
            if theme.interfaceStyle == .nothing {
                NothingSegmentedMeter(
                    usedFraction: Double(fillWidth),
                    level: level,
                    colorScheme: colorScheme,
                    thresholdAnimation: motionAnimation(.thresholdColor),
                    highlightActive: isMoving,
                    highlightAnimation: motionAnimation(.highlight)
                )
                .frame(height: 10)
                .animation(motionAnimation(.fill), value: usedFraction)
            } else {
                legacyBody
                    .frame(height: 5)
            }
        }
        .onAppear {
            guard animateEntrance else { return }
            withAnimation(motionSuppressed ? nil : .easeOut(duration: 0.45)) {
                appeared = true
            }
        }
        .onChange(of: usedFraction) { oldValue, newValue in
            guard MeterMotionPolicy.shouldPlayUpdate(
                from: oldValue,
                to: newValue,
                panelVisible: panelVisible,
                motionSuppressed: motionSuppressed
            ) else { return }
            startUpdateMotion(growing: newValue > oldValue)
        }
    }

    private func motionAnimation(_ kind: MeterMotionKind) -> Animation? {
        MeterMotionPolicy.animation(
            for: kind,
            panelVisible: panelVisible,
            motionSuppressed: motionSuppressed
        )
    }

    /// 增长提示只在增长动画期存在: 右缘高光 + 一次扫光; 下降只保留高光.
    private func startUpdateMotion(growing: Bool) {
        motionToken += 1
        let token = motionToken
        isMoving = true
        isGrowing = growing
        if growing {
            sheenPhase = 0
            withAnimation(motionAnimation(.sheen)) {
                sheenPhase = 1
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + MeterMotionPolicy.highlightHoldSeconds) {
            guard token == motionToken else { return }
            isMoving = false
            isGrowing = false
        }
    }

    private var legacyBody: some View {
        GeometryReader { proxy in
            let width = proxy.size.width * fillWidth
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.adaptive(
                        light: Color.black.opacity(0.07),
                        dark: Color.white.opacity(0.12)
                    ))
                ZStack(alignment: .leading) {
                    ForEach(MeterLevel.all, id: \.self) { candidate in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(gradient(for: candidate))
                            .opacity(candidate == level ? 1 : 0)
                    }
                    if isMoving && isGrowing {
                        Rectangle()
                            .fill(LinearGradient(
                                colors: [.clear, Color.white.opacity(0.55), .clear],
                                startPoint: .leading,
                                endPoint: .trailing
                            ))
                            .frame(width: 46)
                            .offset(x: -46 + sheenPhase * (width + 46))
                    }
                    Rectangle()
                        .fill(Color.white.opacity(isMoving ? 0.85 : 0))
                        .frame(width: 2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .animation(motionAnimation(.highlight), value: isMoving)
                }
                .frame(width: width, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .animation(motionAnimation(.levelCrossfade), value: level)
            }
            .animation(motionAnimation(.fill), value: usedFraction)
        }
    }

    private var fillWidth: CGFloat {
        guard animateEntrance ? appeared : true else {
            return 0
        }
        return CGFloat(min(max(usedFraction, 0), 1))
    }

    private func gradient(for level: MeterLevel) -> LinearGradient {
        let colors: [Color]
        switch level {
        case .normal:
            colors = [Color(hex: "#30d158"), Color(hex: "#66d4a3")]
        case .warning:
            colors = [Color(hex: "#ff9f0a"), Color(hex: "#ffd60a")]
        case .critical:
            colors = [Color(hex: "#ff453a"), Color(hex: "#ff6961")]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
}

/// Nothing 分段量条 (定稿 .segbar): 24 段全方角, 段间 2pt;
/// 空段 #222222(dark)/#E0E0E0(light); 填充段按档位取阈值色
/// (<50 success / 50-79 warning / >=80 accent, 定稿 good/warn/crit 口径).
private struct NothingSegmentedMeter: View {
    /// 0...1, 已含出现动画状态 (未出现时为 0).
    let usedFraction: Double
    let level: MeterLevel
    let colorScheme: ColorScheme
    /// C158: 档位色过渡 (MeterMotionPolicy.thresholdColor); 隐藏或减弱动态时为 nil.
    var thresholdAnimation: Animation? = nil
    /// C158: 更新动画期为 true, 前沿段 (最后点亮的一段) 提亮.
    var highlightActive: Bool = false
    var highlightAnimation: Animation? = nil

    private static let segmentCount = 24
    private static let segmentSpacing: CGFloat = 2

    var body: some View {
        ZStack(alignment: .leading) {
            HStack(spacing: Self.segmentSpacing) {
                ForEach(0..<Self.segmentCount, id: \.self) { _ in
                    Rectangle()
                        .fill(NothingTokens.emptySegment(colorScheme))
                }
            }
            // 填充段用一个可动画 Shape 绘制: animatableData 逐帧插值,
            // 段数才会随动画推进而逐段点亮, 而不是终点一次性跳变.
            NothingFilledSegmentsShape(
                fraction: usedFraction,
                segmentCount: Self.segmentCount,
                spacing: Self.segmentSpacing
            )
            .fill(nothingThresholdColor(for: level))
            .animation(thresholdAnimation, value: level)
            // 前沿段随同一插值分数逐段前移: 每段点亮时提亮, 被下一段接替后回落.
            NothingFilledSegmentsShape(
                fraction: usedFraction,
                segmentCount: Self.segmentCount,
                spacing: Self.segmentSpacing,
                frontierOnly: true
            )
            .fill(Color.white.opacity(colorScheme == .dark ? 0.45 : 0.35))
            .opacity(highlightActive ? 1 : 0)
            .animation(highlightAnimation, value: highlightActive)
        }
    }
}

/// Nothing 填充段路径: 按插值分数取前 N 段, 与空段 HStack 使用同一宽度/间距.
/// Shape 的 animatableData 在非 MainActor 隔离下逐帧插值, 避免 View 版 Animatable
/// 在 Swift 6 的隔离告警. `frontierOnly` 只取最后点亮的一段.
private struct NothingFilledSegmentsShape: Shape {
    var fraction: Double
    let segmentCount: Int
    let spacing: CGFloat
    var frontierOnly: Bool = false

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let segmentWidth = max(
            (rect.width - CGFloat(segmentCount - 1) * spacing) / CGFloat(segmentCount),
            0
        )
        let filled = min(segmentCount, max(0, Int((fraction * Double(segmentCount)).rounded())))
        var path = Path()
        for index in (frontierOnly ? max(filled - 1, 0) : 0)..<filled {
            path.addRect(CGRect(
                x: CGFloat(index) * (segmentWidth + spacing),
                y: 0,
                width: segmentWidth,
                height: rect.height
            ))
        }
        return path
    }
}

// MARK: - Codex 账号子卡

/// 多账号子卡 (原 CodexAccountCard): 圆角 10pt 内层玻璃, 头部账号名 + 套餐, 下方各自窗口行.
private struct ProviderAccountCard: View {
    let account: CodexAccountViewModel
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(account.name)
                    .font(.system(size: 10.5, weight: .semibold))
                if let tag = account.tag {
                    AccountTagChip(text: tag)
                }
                Spacer()
            }
            .padding(.bottom, 2)

            ForEach(account.windows, id: \.label) { row in
                WindowRowView(row: row, animateEntrance: false, panelVisible: panelVisible, protectedSnapshot: account.hasProtectedSnapshot)
            }

            // 分组段本身不带 note, 账号级 error 说明在子卡内展示.
            if account.status == "error", let note = account.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#ff9f0a"))
                    .padding(.top, 2)
            }
            // 非 ok 且保留有上次成功数据: 明确标注这是上次成功快照.
            if let lastSuccessText = account.lastSuccessText {
                Text(lastSuccessText)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .accessibilityLabel("这是上次成功的数据")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            isNothing
                ? NothingTokens.surfaceRaised(colorScheme)
                : Color.adaptive(
                    light: Color.white.opacity(0.35),
                    dark: Color.white.opacity(0.10)
                ),
            in: RoundedRectangle(
                cornerRadius: 6,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isNothing
                        ? NothingTokens.border(colorScheme)
                        : Color.adaptive(
                            light: Color.black.opacity(0.065),
                            dark: Color.white.opacity(0.18)
                        ),
                    lineWidth: 1
                )
        )
    }
}

// MARK: - balance chip

/// 余额元数据胶囊 (C011): 品牌色圆点 + 金额, 与 plan chip 同词汇排布在 section 头部;
/// Credits (Codex, 千分位纯数字) 与货币余额共用, 取代原先窗口行下方的裸文本余额行。
/// Nothing 主题 (与 .plan 同款定稿): 圆角 3, 透明底 + 1px 加强边框, Space Mono, secondary 文字。
private struct BalanceChip: View {
    let amountText: String
    let amount: Double
    let accessibilityText: String
    let color: Color
    var panelVisible: Bool = true

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed

    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    var body: some View {
        Group {
            if isNothing {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 4, height: 4)
                    Text(amountText)
                        .font(NothingFont.mono(9))
                        .contentTransition(.numericText(value: amount))
                        .animation(balanceAnimation, value: amountText)
                        .foregroundStyle(NothingTokens.secondary(colorScheme))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(NothingTokens.borderVisible(colorScheme), lineWidth: 1)
                )
            } else {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 4, height: 4)
                    Text(amountText)
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: amount))
                        .animation(balanceAnimation, value: amountText)
                        .foregroundStyle(Color.primary.opacity(0.85))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color.adaptive(
                    light: Color.white.opacity(0.55),
                    dark: Color.white.opacity(0.12)
                ), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.adaptive(
                    light: Color.white.opacity(0.6),
                    dark: Color.white.opacity(0.18)
                ), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var balanceAnimation: Animation? {
        MeterMotionPolicy.animation(
            for: .balance,
            panelVisible: panelVisible,
            motionSuppressed: motionSuppressed
        )
    }
}

// MARK: - account tag chip

/// 账号属性标签 (例如多账号场景下的 "国际" 站点标记):
/// Nothing 主题: 3pt 方角, 1px 加强边框, NothingFont.mono(8.5);
/// Classic / Liquid Glass 主题: 微型圆角胶囊, 主题 accent 色调 (C220 对齐 Nothing 杏 / 绿).
private struct AccountTagChip: View {
    let text: String

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    /// 面板主题 accent (C220): 浅色杏 #D4A843 / 深色绿 #4A9E5C.
    private var accent: Color {
        Color.adaptive(light: Color(hex: "#D4A843"), dark: Color(hex: "#4A9E5C"))
    }

    private var isNothing: Bool { theme.interfaceStyle == .nothing }

    var body: some View {
        if isNothing {
            Text(text)
                .font(NothingFont.mono(8.5))
                .foregroundStyle(NothingTokens.secondary(colorScheme))
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(NothingTokens.borderVisible(colorScheme), lineWidth: 1)
                )
        } else {
            Text(text)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    accent.opacity(colorScheme == .dark ? 0.22 : 0.12),
                    in: RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(accent.opacity(0.3), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - 订阅卡底栏 (三档阈值图例 + 最后刷新时间)

/// 订阅卡底部栏: 1pt 边框分隔线, 左侧为 Nothing 三档阈值图例 (<50/50–79/≥80),
/// 右侧与图例平齐展示最后刷新时间 (updatedText).
/// 当既非 Nothing 主题且无 updatedText 时隐藏.
private struct SubscriptionFooterView: View {
    let updatedText: String?
    let isNothing: Bool
    let colorScheme: ColorScheme

    var body: some View {
        if isNothing || updatedText != nil {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(
                        isNothing
                            ? NothingTokens.border(colorScheme)
                            : Color.adaptive(
                                light: Color.black.opacity(0.05),
                                dark: Color.white.opacity(0.10)
                            )
                    )
                    .frame(height: 1)
                    .padding(.top, isNothing ? 11 : 8)

                HStack(alignment: .center, spacing: 0) {
                    if isNothing {
                        HStack(spacing: 12) {
                            legendItem(color: NothingTokens.success, text: "<50")
                            legendItem(color: NothingTokens.warning, text: "50–79")
                            legendItem(color: NothingTokens.accent, text: "≥80")
                        }
                    }

                    if let updatedText {
                        Spacer(minLength: 8)
                        if isNothing {
                            Text(updatedText)
                                .font(NothingFont.mono(9))
                                .foregroundStyle(NothingTokens.disabled(colorScheme))
                        } else {
                            Text(updatedText)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, isNothing ? 10 : 8)
            }
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Rectangle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(NothingFont.mono(9))
                .foregroundStyle(NothingTokens.disabled(colorScheme))
        }
    }
}

// MARK: - 预览 fixture

private extension SubscriptionViewModel {
    /// 覆盖 mockup 全部数据形态: 多窗口 provider, ownRow, 高消耗橙/红告警, extraText,
    /// Codex 多账号子卡 (含账号级 error note), error 段 note, 余额沉底段.
    static var previewFixture: SubscriptionViewModel {
        SubscriptionViewModel(sections: [
            SubscriptionProviderSection(
                id: "kimi",
                name: "Kimi",
                plan: "Fixture Plan",
                status: "ok",
                note: nil,
                extraText: "加量包余额 38%",
                windows: [
                    SubscriptionWindowRow(label: "每 5 小时", usedPercent: 68, resetText: "15:00", ownRow: false),
                    SubscriptionWindowRow(label: "每周", usedPercent: 39, resetText: "3 天后", ownRow: false),
                    SubscriptionWindowRow(label: "每月", usedPercent: 52, resetText: "18 天后", ownRow: false),
                    SubscriptionWindowRow(label: "赠送额度", usedPercent: 81, resetText: "", ownRow: true),
                    SubscriptionWindowRow(label: "加量包", usedPercent: 88, resetText: "", ownRow: true),
                ],
                balance: nil,
                accountCountText: nil
            ),
            SubscriptionProviderSection(
                id: "volcengine",
                name: "火山引擎",
                plan: nil,
                status: "ok",
                note: nil,
                extraText: nil,
                windows: [
                    SubscriptionWindowRow(label: "每 5 小时", usedPercent: 74, resetText: "14:00", ownRow: false),
                    SubscriptionWindowRow(label: "每周", usedPercent: 46, resetText: "5 天后", ownRow: false),
                    SubscriptionWindowRow(label: "每月", usedPercent: 63, resetText: "21 天后", ownRow: false),
                ],
                balance: nil,
                accountCountText: nil
            ),
            SubscriptionProviderSection(
                id: "codex",
                name: "ChatGPT",
                plan: nil,
                status: "error",
                note: nil,
                extraText: nil,
                windows: [],
                accounts: [
                    CodexAccountViewModel(
                        id: "codex-personal",
                        name: "sivan…",
                        plan: "个人版",
                        status: "ok",
                        note: nil,
                        windows: [
                            SubscriptionWindowRow(label: "每 5 小时", usedPercent: 57, resetText: "16:00", ownRow: false),
                            SubscriptionWindowRow(label: "每周", usedPercent: 96, resetText: "2 天后", ownRow: false),
                        ]
                    ),
                    CodexAccountViewModel(
                        id: "codex-work",
                        name: "work…",
                        plan: "团队版",
                        status: "error",
                        note: "授权已过期, 请重新登录",
                        windows: [
                            SubscriptionWindowRow(label: "每 5 小时", usedPercent: 92, resetText: "13:30", ownRow: false),
                            SubscriptionWindowRow(label: "每周", usedPercent: 71, resetText: "4 天后", ownRow: false),
                        ]
                    ),
                ],
                collapsedWindow: SubscriptionWindowRow(label: "每 5 小时", usedPercent: 92, resetText: "13:30", ownRow: false),
                balance: nil,
                accountCountText: "2 个账号"
            ),
            SubscriptionProviderSection(
                id: "openai",
                name: "OpenAI",
                plan: nil,
                status: "error",
                note: "用量接口超时, 显示上次快照",
                extraText: nil,
                windows: [
                    SubscriptionWindowRow(label: "每月", usedPercent: 12, resetText: "24 天后", ownRow: false),
                ],
                
                balance: nil,
                accountCountText: nil
            ),
            SubscriptionProviderSection(
                id: "deepseek",
                name: "DeepSeek",
                plan: nil,
                status: "ok",
                note: nil,
                extraText: nil,
                windows: [],
                
                balance: BalanceRow(amount: 38.21, currency: "CNY"),
                accountCountText: "按量付费"
            ),
        ])
    }
}

// MARK: - 预览

// 命令行 swift build 无法解析 #Preview 宏插件 (PreviewsMacros),
// 这里用 PreviewProvider, Xcode 画布同样可直接预览;
// canImport 守住无 Xcode 工具链, 与 UsageHeroCard 的处理一致.
#if DEBUG && canImport(PreviewsMacros)
struct SubscriptionCard_Previews: PreviewProvider {
    /// 预览呈现矩阵: kimi/volcengine 常态可点; codex (多账号) 定向刷新中
    /// (spinner+禁用); deepseek 模拟全量刷新冲突禁用;
    /// openai 非已知 SubscriptionProviderID, 不渲染按钮 (fail-closed).
    private static var previewControls: [String: SubscriptionRefreshControlPresentation] {
        func make(
            _ name: String, refreshing: Bool = false, enabled: Bool = true
        ) -> SubscriptionRefreshControlPresentation {
            SubscriptionRefreshControlPolicy.make(
                displayName: name,
                isProviderRefreshing: refreshing,
                isFullRefreshRunning: !enabled,
                isRunnable: true
            )
        }
        return [
            "kimi": make("Kimi"),
            "volcengine": make("火山引擎"),
            "codex": make("ChatGPT", refreshing: true, enabled: false),
            "deepseek": make("DeepSeek", enabled: false),
        ]
    }

    static var previews: some View {
        SubscriptionCard(
            viewModel: .previewFixture,
            refreshControls: previewControls,
            onRefreshProvider: { _ in }
        )
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(12)
            .frame(width: 400)
            .background(
                LinearGradient(
                    colors: [Color(hex: "#dce8f2"), Color(hex: "#e9e4ef"), Color(hex: "#f2ede4")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .previewDisplayName("订阅用量卡")
    }
}
#endif
