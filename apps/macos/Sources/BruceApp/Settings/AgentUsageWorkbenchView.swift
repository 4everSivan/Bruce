import AppKit
import SwiftUI
import BruceAppCore
import BruceOnboardingCore
import UniformTypeIdentifiers

/// Agent 用量分析与 Token 统计工作台顶层视图
struct AgentUsageWorkbenchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @State private var timeRange: AnalyticsTimeRange = .sevenDays
    @State private var exportMessage: String? = nil
    @State private var showsExportAlert: Bool = false

    var body: some View {
        let kpi = model.analyticsKPISummary(range: timeRange, overrides: coordinator.pricingOverrides)
        let canonicalModels = model.canonicalModels(range: timeRange, overrides: coordinator.pricingOverrides)
        let timeline = model.analyticsTimeline(range: timeRange, overrides: coordinator.pricingOverrides)
        let agents = model.analyticsAgents(range: timeRange, overrides: coordinator.pricingOverrides)

        // 汇总 24 小时 hourlyTokens
        let artifact = model.decodedAgentUsageArtifact()
        let hourlyTokens: [Int] = (0..<24).map { hour in
            artifact?.agents.reduce(0) { sum, agent in
                sum + (hour < agent.hours.count ? agent.hours[hour] : 0)
            } ?? 0
        }

        return VStack(alignment: .leading, spacing: 14) {
            // 顶部时间切片与导出工具条
            headerToolbar

            // 4 格核心 KPI 磁贴
            kpiTilesGrid(kpi)

            // 时序趋势折线分析
            TimelineChartCard(
                points: timeline.points,
                peakSummary: timeline.peakSummary,
                avgSummary: timeline.avgSummary,
                availableAgents: agents,
                availableModels: canonicalModels
            )

            // 全域模型跨源归并大盘
            CanonicalModelAnalyticsCard(canonicalModels: canonicalModels)

            // 多 Agent 协同矩阵与工程下钻
            AgentComparisonMatrixCard(agents: agents)

            // Token 构成四象限与活跃时段
            TokenCompositionCard(
                kpi: kpi,
                hourlyTokens: hourlyTokens
            )

            // 底部会话探针与数据管理
            sessionProbeFooterCard
        }
        .alert(
            "数据导出",
            isPresented: $showsExportAlert,
            actions: {
                Button("确定", role: .cancel) {}
            },
            message: {
                Text(exportMessage ?? "")
            }
        )
    }

    // MARK: - 顶部时间切片与工具栏

    private var headerToolbar: some View {
        HStack(alignment: .center, spacing: 10) {
            // 时间范围分段选择器
            FluentSegmentedPicker(
                options: AnalyticsTimeRange.allCases.map { ($0.displayName, $0) },
                selection: $timeRange
            )

            Spacer()

            // 导出 CSV 账单
            Button("导出 CSV 账单") {
                exportCSV()
            }
            .fluentButton()
            .help("导出归一化模型与 Token 账单 CSV")

            // 导出 JSON 明细
            Button("导出 JSON 明细") {
                exportJSON()
            }
            .fluentButton()
            .help("导出完整会话用量 JSON 原始结构")
        }
    }

    // MARK: - 4 格核心 KPI 磁贴

    private func kpiTilesGrid(_ kpi: AnalyticsKPISummary) -> some View {
        HStack(spacing: 10) {
            // 1. 总 Token
            kpiTile(
                title: "总 Token",
                value: kpi.totalTokensText,
                sub: "\(kpi.equivalentMText) Tokens",
                tag: timeRange.displayName,
                color: SettingsDemoTokens.accent
            )

            // 2. 估算费用
            kpiTile(
                title: "估算费用",
                value: kpi.costText,
                sub: kpi.averageCostPerMillionText,
                tag: "官方定价",
                color: SettingsDemoTokens.ok
            )

            // 3. Prompt Cache 收益
            kpiTile(
                title: "缓存收益",
                value: kpi.cacheHitRateText,
                sub: kpi.cacheSavedCostText,
                tag: "已省",
                color: Color(hex: "10B981")
            )

            // 4. 活跃 Agent 与会话
            kpiTile(
                title: "活跃 Agent",
                value: "\(kpi.activeAgentsCount) 个",
                sub: "\(kpi.totalTurns) 轮交互",
                tag: "全域",
                color: Color(hex: "8B5CF6")
            )
        }
    }

    private func kpiTile(
        title: String,
        value: String,
        sub: String,
        tag: String,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.text2)
                Spacer()
                Text(tag)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        color.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                    )
            }

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text)

            Text(sub)
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsDemoTokens.text3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsDemoTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    // MARK: - 底部会话探针与数据源健康度

    private var sessionProbeFooterCard: some View {
        let result = model.moduleResults[.agentUsage]
        let sessionProbes = (result?.localDependencies ?? [])
            .filter { $0.kind == .sessionDirectory }
        let busy = model.busyModules.contains(.agentUsage)
        let rustAvailable = coordinator.collectorRuntimeStatus == .rustAvailable

        return VStack(alignment: .leading, spacing: 6) {
            Text("会话来源与采集探针")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(SettingsDemoTokens.text3)
                .padding(.leading, 2)

            FluentCard {
                FluentRow(
                    "Rust Collector",
                    sub: "扫描本机会话目录并计算 Token 增量缓存与指纹"
                ) {
                    HStack(spacing: 6) {
                        FluentStatusDot(level: rustAvailable ? .ok : .warn)
                        Text(rustAvailable ? "可用" : "不可用")
                            .font(.system(size: 12.5))
                            .foregroundStyle(
                                rustAvailable ? SettingsDemoTokens.text2 : SettingsDemoTokens.warn
                            )
                    }
                }

                if sessionProbes.isEmpty {
                    FluentRow("尚未检查", sub: "点击下方重新检查", divided: true)
                } else {
                    ForEach(Array(sessionProbes.enumerated()), id: \.offset) { _, probe in
                        FluentRow(
                            probe.detail ?? "会话源",
                            sub: probe.kind == .sessionDirectory ? "本机会话目录" : "本机数据库",
                            divided: true
                        ) {
                            HStack(spacing: 6) {
                                let isAvailable = probe.status == .available
                                let isMissing = probe.status == .missing
                                if !isMissing {
                                    FluentStatusDot(level: isAvailable ? .ok : .warn)
                                }
                                Text(isAvailable ? "就绪" : isMissing ? "未安装" : "未授权")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(
                                        isAvailable
                                            ? SettingsDemoTokens.text2
                                            : isMissing ? SettingsDemoTokens.text3 : SettingsDemoTokens.warn
                                    )
                            }
                        }
                    }
                }

                let missingSessionNames = Set(
                    sessionProbes
                        .filter { $0.status == .missing }
                        .compactMap { $0.detail }
                )
                ForEach(
                    visibleAgentUsageWarnings(
                        result?.warnings ?? [],
                        missingSessionNames: missingSessionNames
                    ),
                    id: \.self
                ) { warning in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(SettingsDemoTokens.warn)
                        Text(warning)
                            .font(.system(size: 11.5))
                            .foregroundStyle(SettingsDemoTokens.text2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .overlay(alignment: .top) {
                        SettingsDemoTokens.separator.frame(height: 1)
                    }
                }

                HStack {
                    Text("所有会话仅在本机分析，绝不上报远程服务器")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.text3)

                    Spacer()

                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button("重新检查") {
                        coordinator.rescan()
                    }
                    .fluentButton()
                    .disabled(busy)
                    .accessibilityLabel("重新检查 Agent 用量依赖")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }
            }
        }
    }

    // MARK: - 数据导出实现

    private func exportCSV() {
        let canonicalModels = model.canonicalModels(range: timeRange, overrides: coordinator.pricingOverrides)
        var csv = "CanonicalModel,Vendor,TotalTokens,EstimatedCostUSD,SharePercent,SourceCount\n"
        for m in canonicalModels {
            let cost = m.estimatedCostUsd.map { String(format: "%.4f", $0) } ?? "0.0"
            csv += "\"\(m.displayName)\",\"\(m.vendor)\",\(m.totalTokens),\(cost),\(String(format: "%.2f", m.sharePercent)),\(m.sources.count)\n"
        }

        saveTextToFile(content: csv, defaultName: "bruce_agent_usage_\(Date.now.formatted(.iso8601.year().month().day())).csv")
    }

    private func exportJSON() {
        guard let artifact = model.decodedAgentUsageArtifact() else {
            exportMessage = "当前暂无已缓存的 Agent 用量数据"
            showsExportAlert = true
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(artifact), let jsonStr = String(data: data, encoding: .utf8) else {
            exportMessage = "数据格式化失败"
            showsExportAlert = true
            return
        }

        saveTextToFile(content: jsonStr, defaultName: "bruce_agent_usage_artifact.json")
    }

    private func saveTextToFile(content: String, defaultName: String) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultName

        if savePanel.runModal() == .OK, let url = savePanel.url {
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                exportMessage = "已成功导出至:\n\(url.lastPathComponent)"
                showsExportAlert = true
            } catch {
                exportMessage = "导出保存失败: \(error.localizedDescription)"
                showsExportAlert = true
            }
        }
    }

    private func visibleAgentUsageWarnings(
        _ warnings: [String],
        missingSessionNames: Set<String>
    ) -> [String] {
        warnings.filter { warning in
            guard !warning.hasPrefix("Kimi Work ") else { return false }
            let duplicatesMissingSource = missingSessionNames.contains { name in
                warning == "\(name) 不可用" || warning == "\(name) 暂不可用"
            }
            return !duplicatesMissingSource
        }
    }
}
