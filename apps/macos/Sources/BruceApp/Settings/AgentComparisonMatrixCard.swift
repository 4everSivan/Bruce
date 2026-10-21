import SwiftUI
import BruceAppCore

/// 多 Agent 协同矩阵与工程下钻卡片
struct AgentComparisonMatrixCard: View {
    let agents: [AnalyticsAgentCardItem]

    @State private var expandedAgentIDs: Set<String> = []

    var body: some View {
        FluentCard {
            VStack(alignment: .leading, spacing: 12) {
                // 顶部标题
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Agent 表现")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(SettingsDemoTokens.text)
                            Text("\(agents.count) 个活跃")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SettingsDemoTokens.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    SettingsDemoTokens.accent.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                        }
                        Text("透视各 Agent 用量占比、Token 结构与关联工程")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    Spacer()
                }

                if agents.isEmpty {
                    emptyAgentsPlaceholder
                } else {
                    VStack(spacing: 8) {
                        ForEach(agents) { agent in
                            agentRow(agent)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Agent 单行展示

    private func agentRow(_ agent: AnalyticsAgentCardItem) -> some View {
        let isExpanded = expandedAgentIDs.contains(agent.agentID)
        let hasDetails = !agent.topProjects.isEmpty || !agent.topModels.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Agent 标识点
                Circle()
                    .fill(Color(hex: agent.colorHex))
                    .frame(width: 9, height: 9)

                // Agent 名称与状态
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(SettingsDemoTokens.text)

                        Text(agent.status)
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsDemoTokens.text2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                SettingsDemoTokens.surfaceHover,
                                in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                            )
                    }

                    if let note = agent.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsDemoTokens.text3)
                    }
                }

                Spacer(minLength: 8)

                // 构成比例条 (输入蓝 + 输出紫 + 缓存绿)
                VStack(alignment: .trailing, spacing: 2) {
                    stackedProportionBar(agent)
                        .frame(width: 80, height: 5)

                    HStack(spacing: 6) {
                        Text(agent.totalTokensText)
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text)

                        Text(agent.costText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.ok)

                        Text(String(format: "%.1f%%", agent.sharePercent))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text3)
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                // 下钻开关
                if hasDetails {
                    Button {
                        if isExpanded {
                            expandedAgentIDs.remove(agent.agentID)
                        } else {
                            expandedAgentIDs.insert(agent.agentID)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsDemoTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "收起关联工程与模型" : "展开关联工程与模型下钻")
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

            // 展开后的关联项目与模型下钻
            if isExpanded && hasDetails {
                VStack(alignment: .leading, spacing: 6) {
                    // Top Projects
                    if !agent.topProjects.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text("📁 今日 Top 工程:")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SettingsDemoTokens.text3)
                                .frame(width: 90, alignment: .leading)

                            FlowLayout(spacing: 6) {
                                ForEach(agent.topProjects.prefix(4), id: \.name) { project in
                                    HStack(spacing: 4) {
                                        Text(project.name)
                                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(SettingsDemoTokens.text)
                                        Text("(\(PanelFormat.tokenCount(project.total)))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(SettingsDemoTokens.text3)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        SettingsDemoTokens.surfaceHover,
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }

                    // Top Models
                    if !agent.topModels.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text("⚡️ 主要消耗模型:")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(SettingsDemoTokens.text3)
                                .frame(width: 90, alignment: .leading)

                            FlowLayout(spacing: 6) {
                                ForEach(agent.topModels.prefix(3)) { model in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(Color(hex: model.colorHex))
                                            .frame(width: 6, height: 6)
                                        Text(model.displayName)
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(SettingsDemoTokens.text)
                                        Text("(\(model.totalTokensText))")
                                            .font(.system(size: 9.5, design: .monospaced))
                                            .foregroundStyle(SettingsDemoTokens.text3)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        SettingsDemoTokens.surfaceHover,
                                        in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    )
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 2)
                .background(
                    SettingsDemoTokens.surface.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
            }
        }
    }

    private func stackedProportionBar(_ agent: AnalyticsAgentCardItem) -> some View {
        let total = max(1, agent.inputTokens + agent.outputTokens + agent.cacheReadTokens)
        let inRatio = CGFloat(agent.inputTokens) / CGFloat(total)
        let outRatio = CGFloat(agent.outputTokens) / CGFloat(total)
        let cacheRatio = CGFloat(agent.cacheReadTokens) / CGFloat(total)

        return GeometryReader { proxy in
            let w = proxy.size.width
            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(hex: "4C9CFF"))
                    .frame(width: max(1, w * inRatio))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(hex: "A855F7"))
                    .frame(width: max(1, w * outRatio))
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(hex: "10B981"))
                    .frame(width: max(1, w * cacheRatio))
            }
        }
    }

    private var emptyAgentsPlaceholder: some View {
        HStack {
            Spacer()
            Text("暂无活跃 Agent 消耗数据")
                .font(.system(size: 12))
                .foregroundStyle(SettingsDemoTokens.text3)
            Spacer()
        }
        .padding(.vertical, 16)
    }
}

/// 简易 FlowLayout 用于标签自适应换行
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var height: CGFloat = 0
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            height = currentY + lineHeight
        }

        return CGSize(width: width, height: max(height, lineHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: .unspecified)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
