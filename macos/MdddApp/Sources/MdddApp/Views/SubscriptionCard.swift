import MdddAppCore
import MdddOnboardingCore
import SwiftUI

// 订阅用量卡: 原生 SwiftUI 版, 视觉以 panel-layout-v8.html 的订阅用量区为准.
// 只排内容, 卡片容器 (液态玻璃背景, 圆角, 阴影) 由 wave 3 统一装配.
// 数据全部来自 MdddAppCore 的 SubscriptionViewModel, 组件不读取任何凭证或 artifact.

/// 订阅用量卡: 标题行 + 若干 provider 段, 段间 1pt 分隔线.
/// 每个 provider 段头部行尾带独立定向刷新按钮 (设计契约), 状态与动作
/// 全部经参数注入; 组件不读取凭证, artifact 或 AppModel.
struct SubscriptionCard: View {
    let viewModel: SubscriptionViewModel
    /// 各 Provider 刷新按钮呈现状态, key 为 SubscriptionProviderID rawValue;
    /// section 无法归一为已知 Provider 或缺键时不渲染按钮 (fail-closed).
    var refreshControls: [String: SubscriptionRefreshControlPresentation] = [:]
    /// Provider 定向刷新动作; 目标由 section ID 经
    /// SubscriptionRefreshControlPolicy 解析, 与按钮禁用态共用同一解析.
    var onRefreshProvider: (SubscriptionProviderID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("订阅用量")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                if let updatedText = viewModel.updatedText {
                    Text(updatedText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) { index, section in
                if index > 0 {
                    Rectangle()
                        .fill(Color.adaptive(
                            light: Color.black.opacity(0.05),
                            dark: Color.white.opacity(0.10)
                        ))
                        .frame(height: 1)
                }
                ProviderSectionView(
                    section: section,
                    isFirst: index == 0,
                    refreshControl: refreshControl(for: section)
                )
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

/// 单个 provider 段: 品牌徽章 + 名称 + plan chip + 账号数, 下方窗口行 / 账号子卡 / 余额行.
/// 多账号 (>=2) 默认折叠, 折叠态展示最关键窗口摘要; 展开后按账号子卡展示.
/// 头部行尾的定向刷新按钮与名称+chevron 展开按钮互为兄弟控件, 互不误触.
private struct ProviderSectionView: View {
    let section: SubscriptionProviderSection
    let isFirst: Bool
    /// 非 nil 时头部行尾渲染定向刷新按钮.
    var refreshControl: ProviderRefreshControl? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
                .padding(.bottom, 3)

            if section.isMultiAccount {
                multiAccountContent
            } else {
                singleAccountContent
            }

            if let balance = section.balance {
                HStack(alignment: .firstTextBaseline) {
                    Text(balance.label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(balance.amountText)
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }

            // DeepSeek 月度统计: 仅当映射层提供了 ViewModel 时渲染
            // (映射层保证只有 DeepSeek section 携带它), 不硬编码 provider id.
            if let monthlyUsage = section.deepSeekMonthlyUsage {
                DeepSeekMonthlyUsageSection(viewModel: monthlyUsage)
            }

            // error/empty 段保留 collector 说明, 不静默吞掉.
            if section.status == "error" || section.status == "empty", let note = section.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#ff9f0a"))
                    .padding(.top, 2)
            }
        }
        .padding(.top, isFirst ? 10 : 8)
        .padding(.bottom, 8)
    }

    // MARK: 多账号内容

    @ViewBuilder
    private var multiAccountContent: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(section.accounts, id: \.id) { account in
                    ProviderAccountCard(account: account)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
        } else if let collapsed = section.collapsedWindow {
            WindowRowView(row: collapsed)
        }
    }

    // MARK: 单账号内容

    @ViewBuilder
    private var singleAccountContent: some View {
        ForEach(Array(section.windows.enumerated()), id: \.offset) { _, row in
            WindowRowView(row: row)
        }
    }

    // MARK: 头部

    private var head: some View {
        HStack(spacing: 6) {
            ProviderLogoBadge(providerID: section.badgeProviderID, name: section.name)
                .accessibilityHidden(true)
            if section.isMultiAccount {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(section.name)
                            .font(.system(size: 11, weight: .semibold))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(section.name)
                    .font(.system(size: 11, weight: .semibold))
            }
            if let plan = section.plan {
                PlanChip(text: plan)
            }
            if let accountCountText = section.accountCountText {
                Text(accountCountText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
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
                    action: refreshControl.action
                )
            }
        }
    }
}

// MARK: - Provider 定向刷新按钮

/// Provider 头部行尾的定向刷新按钮 (设计契约): 常态 arrow.clockwise;
/// 目标 Provider 刷新中替换为小型进度指示并禁用; 全量刷新中 / 未配置 /
/// 未启用 / 模块不可运行时禁用. 固定内容框, 状态切换不引发布局抖动.
/// 呈现快照由 SubscriptionRefreshControlPolicy 计算, 本组件不含业务判断.
private struct ProviderRefreshButton: View {
    let presentation: SubscriptionRefreshControlPresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if presentation.showsProgress {
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

// MARK: - DeepSeek 月度统计

/// DeepSeek 月度统计区块: 只保留「本月消费」一行 + 底部记账起始时间.
/// 只消费映射层提供的 DeepSeekMonthlyUsageViewModel, 不读取任何凭证或 artifact.
private struct DeepSeekMonthlyUsageSection: View {
    let viewModel: DeepSeekMonthlyUsageViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch viewModel.state {
            case .trend:
                trendContent
            case .baseline:
                baselineContent
            case .unavailable:
                unavailableContent
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: 状态内容

    private var trendContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("本月消费")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.estimatedConsumptionText)
                    .font(.system(size: 14, weight: .bold))
                    .monospacedDigit()
            }
            if !viewModel.coverageText.isEmpty {
                Text(viewModel.coverageText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var baselineContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !viewModel.coverageText.isEmpty {
                Text(viewModel.coverageText)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var unavailableContent: some View {
        HStack(spacing: 4) {
            Text("月度统计暂不可用")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    /// 合并后的辅助功能标签: 正常趋势 / 仅有基线 / 不可用三种状态明确措辞,
    /// 不暴露内部错误细节.
    private var accessibilityLabel: String {
        switch viewModel.state {
        case .trend:
            return "DeepSeek 本月消费 \(viewModel.estimatedConsumptionText)"
        case .baseline:
            return "DeepSeek 月度统计正在建立, \(viewModel.coverageText)"
        case .unavailable:
            return "DeepSeek 月度统计暂不可用"
        }
    }
}

// MARK: - 窗口行

/// 窗口量条行: label 固定 62pt + 量条 + 百分比固定 46pt + 重置文案固定 48pt.
/// ownRow 行在本布局中天然独占一行, 不做缩进或并排处理.
private struct WindowRowView: View {
    let row: SubscriptionWindowRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            // usedPercent 是已用比例, 量条从 0 向 100 填充已用量 (消耗式);
            // 百分比文字 percentText 同样是已用值 (如 "68%"), 与量条语义一致.
            MeterBar(
                usedFraction: row.usedPercent / 100,
                level: MeterLevel(usedPercent: row.usedPercent)
            )
            Text(row.percentText)
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
            Text(row.resetText)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 2.5)
        .accessibilityElement(children: .combine)
    }
}

/// 量条告警级别 (消耗式, 阈值唯一来源): 已用 >= 85% 橙, >= 95% 红.
private enum MeterLevel {
    case normal
    case warning
    case critical

    init(usedPercent: Double) {
        switch usedPercent {
        case 95...:
            self = .critical
        case 85...:
            self = .warning
        default:
            self = .normal
        }
    }
}

/// 量条: 高 5pt 圆角, 消耗式填充 (已用量从 0 向 100 增长);
/// 正常绿渐变, >= 85% 橙渐变, >= 95% 红渐变. 出现动画尊重 Reduce Motion.
private struct MeterBar: View {
    let usedFraction: Double
    let level: MeterLevel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.adaptive(
                        light: Color.black.opacity(0.07),
                        dark: Color.white.opacity(0.12)
                    ))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fillGradient)
                    .frame(width: proxy.size.width * fillWidth)
            }
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) {
                appeared = true
            }
        }
    }

    private var fillWidth: CGFloat {
        guard appeared else {
            return 0
        }
        return CGFloat(min(max(usedFraction, 0), 1))
    }

    private var fillGradient: LinearGradient {
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

// MARK: - Codex 账号子卡

/// 多账号子卡 (原 CodexAccountCard): 圆角 10pt 内层玻璃, 头部账号名 + 套餐, 下方各自窗口行.
private struct ProviderAccountCard: View {
    let account: CodexAccountViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(account.name)
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                if let plan = account.plan {
                    Text(plan)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 2)

            ForEach(Array(account.windows.enumerated()), id: \.offset) { _, row in
                WindowRowView(row: row)
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
            Color.adaptive(
                light: Color.white.opacity(0.35),
                dark: Color.white.opacity(0.10)
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.adaptive(
                    light: Color.white.opacity(0.5),
                    dark: Color.white.opacity(0.18)
                ), lineWidth: 1)
        )
    }
}

// MARK: - provider 徽章

/// 品牌色首字母徽章: 按 provider id 解析品牌色, 取名称首字符;
/// 15pt 圆角方块, 白色粗体字母, 深浅色通用.
private struct ProviderLogoBadge: View {
    let providerID: String
    let name: String

    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 15, height: 15)
            .background(
                Self.brandColor(for: providerID),
                in: RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            )
    }

    private static func brandColor(for providerID: String) -> Color {
        switch providerID {
        case "kimi":
            return Color(hex: "#0a84ff")
        case "deepseek":
            return Color(hex: "#4d6bfe")
        case "volcengine":
            return Color(hex: "#ff6a00")
        case "zhipu":
            return Color(hex: "#3859ff")
        case "codex", "openai":
            return Color(hex: "#10a37f")
        case "antigravity":
            return Color(hex: "#4285f4")
        case "claude":
            return Color(hex: "#d97757")
        case "grok":
            return Color(hex: "#111111")
        case "opencodeGo", "opencode-go", "opencode":
            return Color(hex: "#8a63d2")
        default:
            return Color(hex: "#8e8e93")
        }
    }
}

// MARK: - plan chip

/// 套餐胶囊: 9pt, 白底描边, 与 mockup .plan 一致; 深色下退化为低透明白底.
private struct PlanChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(Color.primary.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.adaptive(
                light: Color.white.opacity(0.55),
                dark: Color.white.opacity(0.12)
            ), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.adaptive(
                light: Color.white.opacity(0.6),
                dark: Color.white.opacity(0.2)
            ), lineWidth: 1))
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
                id: "antigravity",
                name: "Antigravity",
                plan: nil,
                status: "ok",
                note: nil,
                extraText: nil,
                windows: [
                    SubscriptionWindowRow(label: "5小时窗口", usedPercent: 64, resetText: "15:00", ownRow: false),
                    SubscriptionWindowRow(label: "每周窗口", usedPercent: 33, resetText: "3 天后", ownRow: false),
                ],
                balance: nil,
                accountCountText: nil
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
// 这里用 PreviewProvider, Xcode 画布同样可直接预览.
struct SubscriptionCard_Previews: PreviewProvider {
    /// 预览呈现矩阵: kimi/volcengine 常态可点; codex (多账号) 定向刷新中
    /// (spinner+禁用); antigravity/deepseek 模拟全量刷新冲突禁用;
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
            "antigravity": make("Antigravity", enabled: false),
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
