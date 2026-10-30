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
///   - Classic / LiquidGlass: 柔白/高斯底座 + 10pt 胶囊 + SF Pro 字体 + 4pt 胶囊进度条;
///   - Nothing: 纯黑/白底座 + 8pt 硬朗方角 + Space Grotesk / Space Mono 点阵字体 + 14 段方块点阵迷你进度条;
/// - 左侧 24pt 品牌瓷砖徽章 (ProviderBrandBadge, Nothing 模式自动跟随 3pt 方角与柔彩图元);
/// - 中段: 首行服务名 + 窗口名 + 进度百分比; 次行量条 + 右置 R3-A 电子表秒级倒计时;
/// - 右侧: 14pt 关闭微按钮;
/// - 顶部居中指向小三角 (小箭头锚定菜单栏图标);
/// - 视图可见期间以 1s 内部定时器跳动读秒, 关闭后销毁, 保持 0% CPU 空转.
struct QuotaAlertBubbleView: View {
    let alerts: [QuotaAlert]
    var onOpenDashboard: () -> Void = {}
    var onClose: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }

    @Environment(\.BruceResolvedTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var now: Date = Date()
    @State private var timer: Timer?
    @State private var hasAppeared: Bool = false

    private var isNothing: Bool {
        theme.interfaceStyle == .nothing
    }

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
            ForEach(alerts, id: \.serviceID) { alert in
                alertRow(alert: alert)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: isNothing ? 8 : 10, style: .continuous)
                .fill(isNothing ? BubbleNothingTokens.surface(colorScheme) : Color(nsColor: .windowBackgroundColor).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: isNothing ? 8 : 10, style: .continuous)
                .stroke(isNothing ? BubbleNothingTokens.borderVisible(colorScheme) : Color.primary.opacity(0.12), lineWidth: isNothing ? 1 : 0.5)
        )
        .shadow(color: isNothing ? Color.clear : Color.black.opacity(0.16), radius: isNothing ? 0 : 8, x: 0, y: isNothing ? 0 : 4)
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

    // MARK: - 单服务告警条目

    @ViewBuilder
    private func alertRow(alert: QuotaAlert) -> some View {
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
                    providerID: alert.providerID ?? alert.serviceID,
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
                            .font(isNothing ? NothingFont.ui(11, weight: .semibold) : .system(size: 11, weight: .semibold))
                            .foregroundStyle(isNothing ? BubbleNothingTokens.display(colorScheme) : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        // 每5小时 (单行不折行卡片) + 倒计时 (高优先级布局，绝不被服务名挤压折行)
                        HStack(alignment: .center, spacing: 6) {
                            windowCardChip(alert.windowLabel)

                            if let countdown {
                                Text(countdown)
                                    .font(isNothing ? NothingFont.mono(9.5, weight: .bold) : .system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(alertColor)
                                    .fixedSize()
                            }
                        }
                        .layoutPriority(1)
                    }

                    // 次行: 进度条 (左) + 百分比放到进度条右边
                    HStack(alignment: .center, spacing: 6) {
                        if isNothing {
                            // Nothing 风格: 14 段方块点阵迷你进度条 (03 §6 规则 298), 带逐段点亮动画
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
                        } else {
                            // 4pt 胶囊进度条, 带从 0 增长平滑弹簧动画
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.10))
                                        .frame(height: 4)

                                    Capsule()
                                        .fill(alertColor)
                                        .frame(
                                            width: max(4, min(geo.size.width, geo.size.width * CGFloat(usedFraction))),
                                            height: 4
                                        )
                                }
                            }
                            .frame(height: 4)
                        }

                        // 百分比置于进度条右边
                        Text("\(percent)%")
                            .font(isNothing ? NothingFont.mono(11, weight: .bold) : .system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(alertColor)
                            .fixedSize()
                    }
                }
            }
            .buttonStyle(.plain)

            // 右侧关闭微按钮 (恢复置于最右端)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(isNothing ? NothingFont.mono(8.5, weight: .bold) : .system(size: 8, weight: .bold))
                    .foregroundStyle(isNothing ? BubbleNothingTokens.secondary(colorScheme) : .secondary)
                    .frame(width: 14, height: 14)
                    .background(
                        isNothing
                            ? RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Color.clear)
                            : RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .help("关闭提示")
        }
    }

    /// 「每5小时」卡片感标签 Chip (带圆角底座与边框，严格单行不折行)
    @ViewBuilder
    private func windowCardChip(_ label: String) -> some View {
        let text = formattedWindowLabel(label)
        if isNothing {
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
        } else {
            Text(text)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
        }
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
        if isNothing {
            switch tier {
            case 95:
                return BubbleNothingTokens.accent
            case 80:
                return BubbleNothingTokens.warning
            default:
                return BubbleNothingTokens.success
            }
        } else {
            switch tier {
            case 95:
                return Color(hex: "#EF4444") // 霓虹红 (Critical)
            case 80:
                return Color(hex: "#F59E0B") // 预警橙 (Warning)
            default:
                return Color(hex: "#EAB308") // 琥珀黄 (Notice)
            }
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
