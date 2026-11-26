import SwiftUI
import BruceAppCore
import BruceOnboardingCore

// MARK: - Nothing 风格 Token 契约

private enum BubbleNothingTokens {
    static func display(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#FFFFFF") : Color(hex: "#000000")
    }
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#999999") : Color(hex: "#666666")
    }
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#222222") : Color(hex: "#E8E8E8")
    }
    static func borderVisible(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#333333") : Color(hex: "#CCCCCC")
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#000000") : Color(hex: "#FFFFFF")
    }
    static func emptySegment(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#222222") : Color(hex: "#E0E0E0")
    }
    static let success = Color(hex: "#4A9E5C")
    static let warning = Color(hex: "#D4A843")
    static let accent = Color(hex: "#D71921")
}

// MARK: - 订阅额度预警胶囊微卡 (方案 A · 280pt 方案)

/// 订阅额度预警气泡视图 (方案 A · 280pt 胶囊微卡)
/// 规格契约:
/// - 宽度固定 280pt;
/// - 全主题自适应:
///   - C271 起仅保留 Nothing 形态;
///   - Nothing: 纯黑/白底座 + 8pt 硬朗方角 + Space Grotesk / Space Mono 点阵字体 + 14 段方块点阵迷你进度条;
/// - 左侧 24pt 品牌瓷砖徽章 (ProviderBrandBadge, Nothing 模式自动跟随 3pt 方角与柔彩图元);
/// - 多态条目支持:
///   - 额度预警 (.quota): 首行服务名 + 窗口名 + 进度百分比; 次行量条 + 右置 R3-A 电子表秒级倒计时; 点击直达主看板;
///   - 出口阻断 (.egressIssue): 首行服务名 + [⚠️ 国内直连] / [⚠️ US ≠ JP] 标签; 次行保护文案; 点击直达设置中心;
/// - 右侧: 14pt 关闭微按钮;
/// - 视图可见期间以 1s 内部定时器跳动读秒, 关闭后销毁, 保持 0% CPU 空转.
struct QuotaAlertBubbleView: View {
    let items: [StatusBubbleAlertItem]
    var onOpenDashboard: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }

    init(
        items: [StatusBubbleAlertItem],
        onOpenDashboard: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onHoverChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.items = items
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.onHoverChange = onHoverChange
    }

    init(
        alerts: [QuotaAlert],
        onOpenDashboard: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onHoverChange: @escaping (Bool) -> Void = { _ in }
    ) {
        self.items = alerts.map { .quota($0) }
        self.onOpenDashboard = onOpenDashboard
        self.onOpenSettings = onOpenSettings
        self.onClose = onClose
        self.onHoverChange = onHoverChange
    }

    @Environment(\.colorScheme) private var colorScheme

    @State private var now: Date = Date()
    @State private var timer: Timer?
    @State private var hasAppeared: Bool = false

    private static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterStandard: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    var body: some View {
        // 卡片主体 (移除顶部尖头，呈现精致极简微卡底座)
        VStack(spacing: 8) {
            ForEach(items) { item in
                switch item {
                case .quota(let alert):
                    quotaAlertRow(alert: alert)
                case .egressIssue(let egressAlert):
                    egressAlertRow(alert: egressAlert)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(BubbleNothingTokens.surface(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(BubbleNothingTokens.borderVisible(colorScheme), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered in
            onHoverChange(isHovered)
        }
        .onAppear {
            now = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    now = Date()
                }
            }
            // 刷新同款 spring 动画: 进度条从 0 平滑增长至目标用量
            DispatchQueue.main.async {
                withAnimation(.spring(duration: 0.85, bounce: 0)) {
                    hasAppeared = true
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - 单服务额度超限告警条目 (点击跳主看板)

    @ViewBuilder
    private func quotaAlertRow(alert: QuotaAlert) -> some View {
        let alertColor = alertTierColor(tier: alert.tier)
        let percent = Int(alert.usedPercent.rounded())
        let countdown = formatCountdown(resetsAt: alert.resetsAt, resetText: alert.resetText)
        let usedFraction = hasAppeared ? min(max(alert.usedPercent / 100.0, 0.0), 1.0) : 0.0

        HStack(alignment: .center, spacing: 8) {
            // 左侧品牌瓷砖徽章 (24pt)
            Button {
                onOpenDashboard()
            } label: {
                ProviderBrandBadge(
                    providerID: alert.providerID ?? SubscriptionPresentationPolicy.providerID(forServiceID: alert.serviceID),
                    name: alert.serviceName,
                    size: 24
                )
            }
            .buttonStyle(.plain)

            // 中段信息区 (首行: 服务名 ... [每 5 小时] 倒计时; 次行: 量条 + 百分比)
            Button {
                onOpenDashboard()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    // 首行: 服务名 (左) ... [每5小时] (卡片感) + 倒计时 (右, 间距 6pt)
                    HStack(alignment: .center, spacing: 4) {
                        Text(alert.serviceName)
                            .font(NothingFont.ui(11, weight: .semibold))
                            .foregroundStyle(BubbleNothingTokens.display(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        // 每5小时 (单行不折行卡片) + 倒计时 (高优先级布局，绝不被服务名挤压折行)
                        HStack(alignment: .center, spacing: 6) {
                            windowCardChip(alert.windowLabel)

                            if let countdown {
                                Text(countdown)
                                    .font(NothingFont.mono(9.5, weight: .bold))
                                    .foregroundStyle(alertColor)
                                    .fixedSize()
                            }
                        }
                        .layoutPriority(1)
                    }

                    // 次行: 进度条 (左) + 百分比放到进度条右边
                    HStack(alignment: .center, spacing: 6) {
                        // 14 段方块点阵迷你进度条 (03 §6 规则 298), 带逐段点亮动画.
                        ZStack(alignment: .leading) {
                            HStack(spacing: 1.5) {
                                ForEach(0..<14, id: \.self) { _ in
                                    Rectangle()
                                        .fill(BubbleNothingTokens.emptySegment(colorScheme))
                                        .frame(height: 4)
                                }
                            }
                            NothingFilledSegmentsShape(
                                fraction: usedFraction,
                                segmentCount: 14,
                                spacing: 1.5
                            )
                            .fill(alertColor)
                        }
                        .frame(height: 4)

                        // 百分比置于进度条右边
                        Text("\(percent)%")
                            .font(NothingFont.mono(11, weight: .bold))
                            .foregroundStyle(alertColor)
                            .fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)

            // 右侧关闭微按钮
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(NothingFont.mono(8.5, weight: .bold))
                    .foregroundStyle(BubbleNothingTokens.secondary(colorScheme))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
    }

    // MARK: - 单服务出口阻断异常条目 (点击跳设置中心订阅面板)

    @ViewBuilder
    private func egressAlertRow(alert: EgressAlertItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            // 左侧品牌瓷砖徽章 (24pt)
            Button {
                onOpenSettings()
            } label: {
                ProviderBrandBadge(
                    providerID: alert.providerID ?? SubscriptionPresentationPolicy.providerID(forServiceID: alert.serviceID),
                    name: alert.serviceName,
                    size: 24
                )
            }
            .buttonStyle(.plain)

            // 中段信息区 (首行: 服务名 ... [⚠️ 国内直连] 标签; 次行: 拦截保护文案)
            Button {
                onOpenSettings()
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    // 首行: 服务名 (左) + 琥珀色微胶囊标签 (右)
                    HStack(alignment: .center, spacing: 4) {
                        Text(alert.serviceName)
                            .font(NothingFont.ui(11, weight: .semibold))
                            .foregroundStyle(BubbleNothingTokens.display(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        egressBadge(alert.badgeText)
                            .layoutPriority(1)
                    }

                    // 次行: 精炼拦截保护文案
                    Text(alert.explanation)
                        .font(NothingFont.mono(9))
                        .foregroundStyle(BubbleNothingTokens.secondary(colorScheme))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .buttonStyle(.plain)

            // 右侧关闭微按钮
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(NothingFont.mono(8.5, weight: .bold))
                    .foregroundStyle(BubbleNothingTokens.secondary(colorScheme))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
    }

    /// 琥珀色出口拦截微胶囊标签
    @ViewBuilder
    private func egressBadge(_ text: String) -> some View {
        Text(text)
            .font(NothingFont.mono(8.5, weight: .bold))
            .foregroundStyle(BubbleNothingTokens.warning)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(BubbleNothingTokens.emptySegment(colorScheme).opacity(0.40))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(BubbleNothingTokens.borderVisible(colorScheme), lineWidth: 1)
            )
    }

    /// 「每5小时」卡片感标签 Chip (带圆角底座与边框，严格单行不折行)
    @ViewBuilder
    private func windowCardChip(_ label: String) -> some View {
        let text = formattedWindowLabel(label)
        Text(text)
            .font(NothingFont.mono(8.5))
            .foregroundStyle(BubbleNothingTokens.secondary(colorScheme))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(BubbleNothingTokens.emptySegment(colorScheme).opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(BubbleNothingTokens.borderVisible(colorScheme), lineWidth: 1)
            )
    }

    private func formattedWindowLabel(_ label: String) -> String {
        let clean = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.contains("5") && (clean.contains("小时") || clean.contains("h")) {
            return "每5小时"
        }
        if clean.contains("周") || clean.contains("week") {
            return "每周"
        }
        if clean.contains("月") || clean.contains("month") {
            return "每月"
        }
        if clean.contains("天") || clean.contains("日") || clean.contains("day") {
            return "每日"
        }
        return clean.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - 辅助计算

    private func alertTierColor(tier: Int) -> Color {
        switch tier {
        case 95:
            return BubbleNothingTokens.accent
        case 80:
            return BubbleNothingTokens.warning
        default:
            return BubbleNothingTokens.success
        }
    }

    private func formatCountdown(resetsAt: String?, resetText: String?) -> String? {
        guard let resetsAt, !resetsAt.isEmpty else {
            return resetText
        }
        let targetDate = Self.isoFormatterWithFractional.date(from: resetsAt)
            ?? Self.isoFormatterStandard.date(from: resetsAt)
        guard let target = targetDate else {
            return resetText
        }
        let seconds = Int(target.timeIntervalSince(now))
        if seconds <= 0 {
            return "00:00:00"
        }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Nothing 分段量条动画路径 Shape

private struct NothingFilledSegmentsShape: Shape {
    var fraction: Double
    let segmentCount: Int
    let spacing: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let totalSpacing = CGFloat(segmentCount - 1) * spacing
        let segmentWidth = max((rect.width - totalSpacing) / CGFloat(segmentCount), 0)
        let filledCount = min(segmentCount, max(0, Int((fraction * Double(segmentCount)).rounded())))
        var path = Path()
        for index in 0..<filledCount {
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
