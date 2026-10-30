import SwiftUI
import BruceAppCore

/// 全域模型跨源归并大盘卡片
struct CanonicalModelAnalyticsCard: View {
    let canonicalModels: [CanonicalModelSummary]

    @State private var isMergedView = true
    @State private var expandedKeys: Set<String> = []

    private var totalSourcesCount: Int {
        canonicalModels.reduce(0) { $0 + max(1, $1.sources.count) }
    }

    private var allRawSources: [ModelSourceContribution] {
        var list: [ModelSourceContribution] = []
        for model in canonicalModels {
            if model.sources.isEmpty {
                list.append(ModelSourceContribution(
                    rawModelName: model.canonicalKey,
                    agentID: "",
                    agentDisplayName: "通用",
                    tokens: model.totalTokens,
                    tokensText: model.totalTokensText,
                    costUsd: model.estimatedCostUsd,
                    costText: model.costText,
                    shareOfModelPercent: 100.0
                ))
            } else {
                list.append(contentsOf: model.sources)
            }
        }
        return list.sorted { $0.tokens > $1.tokens }
    }

    var body: some View {
        FluentCard {
            VStack(alignment: .leading, spacing: 12) {
                // 顶部标题与合并视图切换
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("模型分布")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(SettingsDemoTokens.text)
                            Text("\(canonicalModels.count) 款主模型 · \(totalSourcesCount) 个渠道")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SettingsDemoTokens.ok)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    SettingsDemoTokens.ok.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }
                        Text("自动归并同类模型，支持展开查看各渠道细分贡献")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }

                    Spacer()

                    // 归并视图 vs 原始渠道切换
                    FluentSegmentedPicker(
                        options: [
                            ("合并视图", true),
                            ("原始渠道", false)
                        ],
                        selection: $isMergedView
                    )
                }

                if canonicalModels.isEmpty {
                    emptyModelsPlaceholder
                } else if isMergedView {
                    // 归并合并视图
                    VStack(spacing: 8) {
                        ForEach(canonicalModels) { model in
                            canonicalModelRow(model)
                        }
                    }
                } else {
                    // 原始渠道平铺视图
                    VStack(spacing: 8) {
                        ForEach(Array(allRawSources.enumerated()), id: \.offset) { index, src in
                            rawSourceRow(src, index: index + 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - 归并后模型行

    private func canonicalModelRow(_ model: CanonicalModelSummary) -> some View {
        let isExpanded = expandedKeys.contains(model.canonicalKey)
        let hasMultipleSources = model.sources.count > 1

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // 厂商品牌徽章 (C161)
                AgentBrandBadge(
                    asset: AgentBrandPalette.asset(forModelKey: model.canonicalKey),
                    seriesHex: model.colorHex,
                    size: 18,
                    followsTheme: false,
                    fallbackMonogram: String(model.displayName.prefix(1)).uppercased()
                )

                // 模型显示名与厂商标签
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)

                        Text(model.vendor)
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsDemoTokens.text3)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                SettingsDemoTokens.surfaceHover,
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )

                        if hasMultipleSources {
                            Text("合并 \(model.sources.count) 个渠道")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(SettingsDemoTokens.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    SettingsDemoTokens.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                )
                        }
                    }

                    Text("规范键: \(model.canonicalKey)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }

                Spacer(minLength: 8)

                // 占比进度条
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(SettingsDemoTokens.surfaceHover)
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(Color(hex: model.colorHex))
                                    .frame(width: max(2, proxy.size.width * CGFloat(min(1.0, max(0.0, model.sharePercent / 100.0)))))
                            }
                        }
                        .frame(width: 70, height: 5)

                        Text(String(format: "%.1f%%", model.sharePercent))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text2)
                            .frame(width: 42, alignment: .trailing)
                    }

                    HStack(spacing: 6) {
                        Text(model.totalTokensText)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text)

                        if let costText = model.costText {
                            Text(costText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.ok)
                        }
                    }
                }

                // 展开/折叠按钮 (多渠道时可用)
                if hasMultipleSources {
                    Button {
                        if isExpanded {
                            expandedKeys.remove(model.canonicalKey)
                        } else {
                            expandedKeys.insert(model.canonicalKey)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDemoTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起渠道明细" : "展开 \(model.sources.count) 个渠道明细")
                } else {
                    Color.clear.frame(width: 13, height: 13)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                SettingsDemoTokens.bg.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )

            // 展开后的各来源贡献下钻列表
            if isExpanded && hasMultipleSources {
                VStack(spacing: 4) {
                    ForEach(model.sources) { src in
                        HStack(spacing: 8) {
                            Text("↳")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text3)
                                .padding(.leading, 12)

                            Text(src.rawModelName)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text)

                            Text(src.agentDisplayName)
                                .font(.system(size: 9.5))
                                .foregroundStyle(SettingsDemoTokens.text2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    SettingsDemoTokens.surfaceHover,
                                    in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                                )

                            Spacer()

                            Text("\(src.tokensText) (\(String(format: "%.1f%%", src.shareOfModelPercent)))")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text2)

                            if let cost = src.costText {
                                Text(cost)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(SettingsDemoTokens.ok)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            SettingsDemoTokens.surface.opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                    }
                }
                .padding(.leading, 6)
            }
        }
    }

    // MARK: - 原始渠道平铺行

    private func rawSourceRow(_ src: ModelSourceContribution, index: Int) -> some View {
        HStack(spacing: 8) {
            Text("#\(index)")
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text3)
                .frame(width: 24, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(src.rawModelName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text("来源 Agent: \(src.agentDisplayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }

            Spacer()

            Text(src.tokensText)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text)

            if let cost = src.costText {
                Text(cost)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.ok)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            SettingsDemoTokens.bg.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
    }

    private var emptyModelsPlaceholder: some View {
        HStack {
            Spacer()
            Text("暂无模型消耗数据")
                .font(.system(size: 12))
                .foregroundStyle(SettingsDemoTokens.text3)
            Spacer()
        }
        .padding(.vertical, 16)
    }
}
