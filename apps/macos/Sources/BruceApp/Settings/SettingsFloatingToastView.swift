import SwiftUI

/// 设置中心统一悬浮错误胶囊 (C111)
///
/// 规格对齐：
/// - 8pt 卡片级连续圆角 (与 Fluent 设置卡片与 C103 8pt 呼吸感体系协同)
/// - 42pt 标准高 (Apple HIG 最小人体工程学点击靶区)
/// - 420pt 固定居中宽 (大标题上方规整稳定)
/// - 环形微圆环倒计时 (4s 平滑收敛，呼应菜单栏 PrecisionRingGaugeView 品牌符号)
/// - 鼠标悬停暂停 (Hover 暂停倒计时并高亮 Accent 蓝)
/// - ✕ 按钮随时一键手动清除
@MainActor
struct SettingsFloatingToastView: View {
    let message: String
    var tone: ToastTone = .warn
    let onDismiss: @MainActor () -> Void

    enum ToastTone {
        case warn
        case danger
        case ok
        case info

        var iconName: String {
            switch self {
            case .warn: return "exclamationmark.triangle.fill"
            case .danger: return "xmark.circle.fill"
            case .ok: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .warn: return SettingsDemoTokens.warn
            case .danger: return SettingsDemoTokens.danger
            case .ok: return SettingsDemoTokens.ok
            case .info: return SettingsDemoTokens.accent
            }
        }
    }

    @State private var progress: CGFloat = 1.0
    @State private var isHovered = false
    @State private var timer: Timer?

    private let duration: TimeInterval = 4.0
    private let tickInterval: TimeInterval = 0.05

    var body: some View {
        HStack(spacing: 10) {
            // 语义状态图标
            Image(systemName: tone.iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tone.color)
                .frame(width: 18, height: 18)

            // 提示文案 (单行，长文本尾部截断)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SettingsDemoTokens.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 环形微圆环倒计时 + ✕ 关闭按钮融合体
            ZStack {
                // 环形底轨
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1.8)
                    .frame(width: 20, height: 20)

                // 动态闭合进度条 (呼应菜单栏圆环)
                Circle()
                    .trim(from: 0, to: max(0, min(1, progress)))
                    .stroke(
                        isHovered ? SettingsDemoTokens.accent : tone.color,
                        style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 20, height: 20)
                    .animation(.linear(duration: tickInterval), value: progress)

                // 中心 ✕ 关闭按钮
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isHovered ? SettingsDemoTokens.text : SettingsDemoTokens.text2)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("清除提示")
                .accessibilityLabel("关闭提示")
            }
            .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 10, x: 0, y: 4)
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
    }

    private func startTimer() {
        progress = 1.0
        let totalTicks = duration / tickInterval
        let step = 1.0 / CGFloat(totalTicks)

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { _ in
            Task { @MainActor in
                guard !isHovered else { return } // 悬停暂停
                if progress > 0 {
                    progress -= step
                } else {
                    stopTimer()
                    onDismiss()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
