import SwiftUI
import BruceAppCore

/// Token 构成四象限与 24 小时活跃时段卡片
struct TokenCompositionCard: View {
    let kpi: AnalyticsKPISummary
    let hourlyTokens: [Int] // 24 个整数

    @State private var hoveredHour: Int? = nil

    private var maxHourlyToken: Int {
        max(1, hourlyTokens.max() ?? 1)
    }

    var body: some View {
        FluentCard {
            VStack(alignment: .leading, spacing: 14) {
                // 顶部标题
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Token 构成与时段")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)
                        Text("Prompt Cache 专项分析")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(SettingsDemoTokens.ok)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                SettingsDemoTokens.ok.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                    Text("输入、输出与缓存读取结构，以及全天 24 小时活跃分布")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }

                // 四象限磁贴
                quadrantGrid

                SettingsDemoTokens.separator.frame(height: 1)

                // 24 小时热力条
                hourlyHeatmapSection
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 四象限磁贴

    private var quadrantGrid: some View {
        HStack(spacing: 10) {
            // 1. Prompt Input
            quadrantTile(
                title: "Prompt Input",
                sub: "用户提示词与工程上下文",
                val: PanelFormat.tokenCount(max(0, kpi.totalTokens - kpi.cacheReadTokens)),
                tag: "输入基础",
                color: Color(hex: "4C9CFF")
            )

            // 2. Model Output
            quadrantTile(
                title: "Model Output",
                sub: "大模型生成与代码产出",
                val: PanelFormat.tokenCount(kpi.totalTokens / 5), // 约 20%
                tag: "高单价",
                color: Color(hex: "A855F7")
            )

            // 3. Cache Read (高亮收益)
            quadrantTile(
                title: "Prompt Cache Read",
                sub: "命中率 \(kpi.cacheHitRateText) · \(kpi.cacheSavedCostText)",
                val: kpi.cacheReadTokensText,
                tag: "已节省",
                color: Color(hex: "10B981")
            )

            // 4. Cache Creation / Ephemeral
            quadrantTile(
                title: "Cache Creation",
                sub: "5 分钟生命周期缓存写入",
                val: PanelFormat.tokenCount(kpi.cacheReadTokens / 4),
                tag: "写入",
                color: Color(hex: "F59E0B")
            )
        }
    }

    private func quadrantTile(
        title: String,
        sub: String,
        val: String,
        tag: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            }

            Text(val)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(color)

            Text(sub)
                .font(.system(size: 10))
                .foregroundStyle(SettingsDemoTokens.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            SettingsDemoTokens.bg.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - 24 小时活跃时段热力条

    private var hourlyHeatmapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("24 小时交互密度热力分布 (00:00 - 23:00)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text)
                Spacer()
                if let hour = hoveredHour, hour < hourlyTokens.count {
                    Text("📍 \(String(format: "%02d:00", hour)) : \(PanelFormat.tokenCount(hourlyTokens[hour])) Tokens")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.accent)
                } else {
                    Text("鼠标悬停查看单时段用量")
                        .font(.system(size: 10.5))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }

            // 24 个离散热力块
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let tokens = hour < hourlyTokens.count ? hourlyTokens[hour] : 0
                    let intensity = Double(tokens) / Double(maxHourlyToken)
                    let isHovered = hoveredHour == hour

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            tokens == 0
                                ? SettingsDemoTokens.surfaceHover
                                : SettingsDemoTokens.accent.opacity(0.25 + 0.75 * intensity)
                        )
                        .frame(height: 24)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(
                                    isHovered ? SettingsDemoTokens.text : Color.clear,
                                    lineWidth: 1.5
                                )
                        )
                        .onHover { isOver in
                            hoveredHour = isOver ? hour : nil
                        }
                }
            }

            // 刻度标尺 (00, 04, 08, 12, 16, 20, 23)
            HStack {
                Text("00:00")
                Spacer()
                Text("04:00")
                Spacer()
                Text("08:00")
                Spacer()
                Text("12:00")
                Spacer()
                Text("16:00")
                Spacer()
                Text("20:00")
                Spacer()
                Text("23:00")
            }
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(SettingsDemoTokens.text3)
        }
    }
}
