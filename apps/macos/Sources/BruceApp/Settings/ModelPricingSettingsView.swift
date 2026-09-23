import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// 模型单价与费用校准面板 (1:1 严格对齐 _adflow_backup/original_docs/design/pricing-calibration-settings-demo.html 原型).
/// 包含全局费用概览、全模型定价与用量表格 (内部固定高度滚动条, 避免页面高度过大)、
/// 交互式校准弹窗以及 config.json 联动预览.
struct ModelPricingSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @State private var searchText = ""
    @State private var filterMode = PricingFilterMode.all
    @State private var editingModel: EffectiveModelPricing? = nil
    @State private var showsResetAllConfirm = false

    enum PricingFilterMode: String, CaseIterable, Identifiable {
        case all = "全部"
        case hasUsage = "已有用量"
        case customized = "已人工校准"

        var id: String { rawValue }
    }

    // MARK: - 模型用量统计映射

    private struct ModelUsageSnapshot {
        let totalTokens: Int
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let costUsd: Double?
    }

    private var modelUsageMap: [String: ModelUsageSnapshot] {
        guard let artifact = model.decodedAgentUsageArtifact() else { return [:] }
        var map: [String: ModelUsageSnapshot] = [:]
        for agent in artifact.agents {
            if let todayModels = agent.todayModels {
                for item in todayModels {
                    let key = normalize(item.model)
                    let current = map[key]
                    let total = (current?.totalTokens ?? 0) + item.total
                    let input = (current?.inputTokens ?? 0) + item.input
                    let output = (current?.outputTokens ?? 0) + item.output
                    let cost = (current?.costUsd ?? 0.0) + (item.costUsd ?? 0.0)
                    map[key] = ModelUsageSnapshot(
                        totalTokens: total,
                        inputTokens: input,
                        outputTokens: output,
                        cacheReadTokens: 0,
                        costUsd: cost > 0 ? cost : nil
                    )
                }
            } else if let models = agent.models {
                for (modelName, total) in models {
                    let key = normalize(modelName)
                    let current = map[key]
                    map[key] = ModelUsageSnapshot(
                        totalTokens: (current?.totalTokens ?? 0) + total,
                        inputTokens: 0,
                        outputTokens: 0,
                        cacheReadTokens: 0,
                        costUsd: nil
                    )
                }
            }
        }
        return map
    }

    private var allEffectiveModels: [EffectiveModelPricing] {
        BuiltinModelPricingCatalog.resolveAll(overrides: coordinator.pricingOverrides)
    }

    private var filteredModels: [EffectiveModelPricing] {
        let usage = modelUsageMap
        return allEffectiveModels.filter { item in
            // 搜索过滤
            if !searchText.isEmpty {
                let q = searchText.lowercased()
                let match = item.modelName.lowercased().contains(q)
                    || item.displayName.lowercased().contains(q)
                    || item.vendor.lowercased().contains(q)
                guard match else { return false }
            }
            // 模式过滤
            switch filterMode {
            case .all:
                return true
            case .hasUsage:
                let key = normalize(item.modelName)
                return (usage[key]?.totalTokens ?? 0) > 0
            case .customized:
                return item.isCustom
            }
        }
    }

    private var todayTotalCost: Double {
        if let cost = model.makeMenuBarSummary().todayCostUsd {
            return cost
        }
        if let artifact = model.decodedAgentUsageArtifact(), let total = artifact.totalCostUsd {
            return total
        }
        // 若尚未由 Collector 输出，通过当前有效单价与各模型用量折算
        var calculated = 0.0
        let usage = modelUsageMap
        for item in allEffectiveModels {
            let key = normalize(item.modelName)
            if let snap = usage[key], snap.totalTokens > 0 {
                let cost = snap.costUsd ?? (Double(snap.totalTokens) * (item.inputPrice + item.outputPrice) / 2.0 / 1_000_000.0)
                calculated += cost
            }
        }
        return calculated
    }

    private var todayTotalTokens: Int {
        model.makeMenuBarSummary().todayTokens ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 实时费用总览卡
            summaryCard

            // 过滤与搜索栏
            filterBar

            // 全模型计费表格 (限制高度并带有独立滚动条)
            tableCard

            // 底部配置文件说明与重置区
            configPreviewCard
        }
        .sheet(item: $editingModel) { modelToEdit in
            ModelPricingCalibrationSheet(
                modelPricing: modelToEdit,
                onSave: { override in
                    coordinator.setPricingOverride(modelName: modelToEdit.modelName, override: override)
                },
                onReset: {
                    coordinator.removePricingOverride(modelName: modelToEdit.modelName)
                }
            )
        }
        .alert("确定恢复所有模型定价为内置基准？", isPresented: $showsResetAllConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复默认", role: .destructive) {
                coordinator.resetAllPricingOverrides()
            }
        } message: {
            Text("此操作将清除所有人工校准与自定义模型的单价覆盖配置。")
        }
    }

    // MARK: - 实时费用总览卡

    private var summaryCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("今日 TOKEN 预估折算总费用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SettingsDemoTokens.ok)
                Text("基于当前本机全部活跃 Agent 真实 Token 吞吐量进行折算")
                    .font(.system(size: 11.5))
                    .foregroundStyle(SettingsDemoTokens.text2)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(format: "$%.2f", todayTotalCost))
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text)

                if todayTotalTokens > 0 {
                    Text("/ \(formatTokens(todayTotalTokens))")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            SettingsDemoTokens.ok.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsDemoTokens.ok.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - 过滤与搜索栏

    private var filterBar: some View {
        HStack(spacing: 12) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDemoTokens.text3)
                TextField("搜索模型或厂商 (如 k3, deepseek, gpt...)", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsDemoTokens.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(SettingsDemoTokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
            )
            .frame(maxWidth: 280)

            Spacer()

            // 筛选胶囊
            HStack(spacing: 4) {
                ForEach(PricingFilterMode.allCases) { mode in
                    let isSelected = filterMode == mode
                    Button {
                        filterMode = mode
                    } label: {
                        Text(modeTitle(mode))
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? SettingsDemoTokens.accent : SettingsDemoTokens.text2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                isSelected ? SettingsDemoTokens.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(isSelected ? SettingsDemoTokens.accent.opacity(0.3) : SettingsDemoTokens.separator, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func modeTitle(_ mode: PricingFilterMode) -> String {
        let usage = modelUsageMap
        switch mode {
        case .all:
            return "全部 (\(allEffectiveModels.count))"
        case .hasUsage:
            let count = allEffectiveModels.filter { (usage[normalize($0.modelName)]?.totalTokens ?? 0) > 0 }.count
            return "已有用量 (\(count))"
        case .customized:
            let count = coordinator.pricingOverrides.count
            return "已校准 (\(count))"
        }
    }

    // MARK: - 模型计费表格 (独立固定高度与滚动条)

    private var tableCard: some View {
        VStack(spacing: 0) {
            // 表头 (Sticky)
            tableHeaderView

            SettingsDemoTokens.separator.frame(height: 1)

            // 滚动列表: 明确限制高度，显示原生独立滚动条
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if filteredModels.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "tray")
                                .font(.system(size: 20))
                                .foregroundStyle(SettingsDemoTokens.text3)
                            Text("未找到匹配的模型定价规则")
                                .font(.system(size: 12))
                                .foregroundStyle(SettingsDemoTokens.text3)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        ForEach(filteredModels) { item in
                            tableRowView(item)
                            SettingsDemoTokens.separator.frame(height: 1)
                        }
                    }
                }
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: 280) // 限制最大高度，防止撑大窗口
        }
        .background(SettingsDemoTokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    private var tableHeaderView: some View {
        HStack(spacing: 8) {
            Text("模型与厂商")
                .frame(width: 150, alignment: .leading)
            Text("今日用量")
                .frame(width: 72, alignment: .leading)
            Text("来源")
                .frame(width: 65, alignment: .leading)
            Text("输入单价")
                .frame(width: 72, alignment: .leading)
            Text("输出单价")
                .frame(width: 72, alignment: .leading)
            Text("缓存命中")
                .frame(width: 75, alignment: .leading)
            Text("今日折算")
                .frame(width: 68, alignment: .trailing)
            Spacer()
            Text("操作")
                .frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(SettingsDemoTokens.text3)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(SettingsDemoTokens.bg.opacity(0.6))
    }

    private func tableRowView(_ item: EffectiveModelPricing) -> some View {
        let key = normalize(item.modelName)
        let snap = modelUsageMap[key]
        let tokens = snap?.totalTokens ?? 0
        let cost = snap?.costUsd ?? (tokens > 0 ? (Double(tokens) * (item.inputPrice + item.outputPrice) / 2.0 / 1_000_000.0) : nil)

        return HStack(spacing: 8) {
            // 模型名称与厂商
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.modelName)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if tokens > 0 {
                        Circle()
                            .fill(SettingsDemoTokens.ok)
                            .frame(width: 5, height: 5)
                    }
                }
                Text(item.vendor)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 150, alignment: .leading)
            .help(item.modelName)

            // 今日用量
            Group {
                if tokens > 0 {
                    Text(formatTokens(tokens))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.ok)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SettingsDemoTokens.ok.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
            .frame(width: 72, alignment: .leading)

            // 来源标签
            Group {
                if item.isCustom {
                    Text("人工校准")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.warn)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(SettingsDemoTokens.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Text("内置基线")
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsDemoTokens.text3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(SettingsDemoTokens.bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .frame(width: 65, alignment: .leading)

            // 输入单价
            HStack(spacing: 2) {
                Text(String(format: "$%.2f", item.inputPrice))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text("/1M")
                    .font(.system(size: 9))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            .frame(width: 72, alignment: .leading)

            // 输出单价
            HStack(spacing: 2) {
                Text(String(format: "$%.2f", item.outputPrice))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text("/1M")
                    .font(.system(size: 9))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            .frame(width: 72, alignment: .leading)

            // 缓存命中单价
            Group {
                if let cache = item.cacheReadPrice {
                    HStack(spacing: 2) {
                        Text(String(format: "$%.3f", cache))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(SettingsDemoTokens.text2)
                        Text("/1M")
                            .font(.system(size: 9))
                            .foregroundStyle(SettingsDemoTokens.text3)
                    }
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
            .frame(width: 75, alignment: .leading)

            // 今日折算花费
            Group {
                if let cost, cost > 0 {
                    Text(String(format: "$%.2f", cost))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.ok)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.text3)
                }
            }
            .frame(width: 68, alignment: .trailing)

            Spacer()

            // 操作按钮
            HStack(spacing: 4) {
                Button("编辑") {
                    editingModel = item
                }
                .font(.system(size: 11))
                .fluentButton(.plain)

                if item.isCustom {
                    Button {
                        coordinator.removePricingOverride(modelName: item.modelName)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsDemoTokens.warn)
                    }
                    .buttonStyle(.plain)
                    .help("恢复内置默认基准")
                }
            }
            .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - 底部配置说明卡

    private var configPreviewCard: some View {
        FluentCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsDemoTokens.accent)
                    Text("配置文件实时映射 (config.json)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Spacer()
                    Text("~/Library/Application Support/Bruce/config/onboarding-v1.json")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text3)
                    if !coordinator.pricingOverrides.isEmpty {
                        Button("全部重置为基准") {
                            showsResetAllConfirm = true
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsDemoTokens.danger)
                        .buttonStyle(.plain)
                    }
                }

                Text("除在当前图形界面调整外，您也可以直接在 Bruce 的配置文件中声明 pricingOverrides 节点进行批量人工校准。")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsDemoTokens.text2)

                // JSON 代码块预览
                let jsonPreview = generateConfigJSONPreview()
                Text(jsonPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.95))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(12)
        }
    }

    private func generateConfigJSONPreview() -> String {
        if coordinator.pricingOverrides.isEmpty {
            return """
            // 当前全部使用官方内置基准单价。添加自定义或校准项后将在此展示配置代码：
            {
              "pricingOverrides": {}
            }
            """
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(coordinator.pricingOverrides),
           let str = String(data: data, encoding: .utf8) {
            return "{\n  \"pricingOverrides\": " + str.replacingOccurrences(of: "\n", with: "\n  ") + "\n}"
        }
        return "{}"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func normalize(_ s: String) -> String {
        var str = s.lowercased()
        if let idx = str.firstIndex(of: "[") {
            str = String(str[..<idx])
        }
        if let idx = str.lastIndex(of: "/") {
            str = String(str[str.index(after: idx)...])
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 单模型校准对话框 (Sheet)

private struct ModelPricingCalibrationSheet: View {
    let modelPricing: EffectiveModelPricing
    let onSave: (ModelPricingOverride) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var inputPriceText: String = ""
    @State private var outputPriceText: String = ""
    @State private var cachePriceText: String = ""
    @State private var noteText: String = ""
    @State private var currency: String = "USD"

    init(
        modelPricing: EffectiveModelPricing,
        onSave: @escaping (ModelPricingOverride) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.modelPricing = modelPricing
        self.onSave = onSave
        self.onReset = onReset
        _inputPriceText = State(initialValue: String(format: "%.2f", modelPricing.inputPrice))
        _outputPriceText = State(initialValue: String(format: "%.2f", modelPricing.outputPrice))
        if let cache = modelPricing.cacheReadPrice {
            _cachePriceText = State(initialValue: String(format: "%.4f", cache))
        } else {
            _cachePriceText = State(initialValue: "")
        }
        _noteText = State(initialValue: modelPricing.note ?? "")
        _currency = State(initialValue: modelPricing.currency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 对话框顶部
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("模型单价人工校准")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Text("\(modelPricing.displayName) (\(modelPricing.modelName)) · \(modelPricing.vendor)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }
                Spacer()
                if modelPricing.isCustom {
                    Text("当前已校准")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.warn)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(SettingsDemoTokens.warn.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            SettingsDemoTokens.separator.frame(height: 1)

            // 输入表单
            VStack(spacing: 12) {
                priceInputRow(
                    label: "输入单价 (Prompt / Input)",
                    sub: "每 100 万 (1M) Tokens 费用",
                    text: $inputPriceText
                )

                priceInputRow(
                    label: "输出单价 (Completion / Output)",
                    sub: "每 100 万 (1M) Tokens 费用",
                    text: $outputPriceText
                )

                priceInputRow(
                    label: "缓存读取命中 (Cache Hit / Read)",
                    sub: "每 100 万 (1M) Tokens 费用 (留空按 10% 默认折算)",
                    text: $cachePriceText
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("备注说明 (可选)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SettingsDemoTokens.text)
                    TextField("如：采购折扣套餐 / 内部计费合约", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
            }

            // 费用折算效果预估
            VStack(alignment: .leading, spacing: 4) {
                Text("实时折算公式与效果预估")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.95))
                let inP = Double(inputPriceText) ?? modelPricing.inputPrice
                let outP = Double(outputPriceText) ?? modelPricing.outputPrice
                let sampleCost = (1.0 * inP + 0.2 * outP)
                Text(String(format: "每消耗 1M 输入 + 200k 输出，折算费用约为 $%.3f USD", sampleCost))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text2)
            }
            .padding(10)
            .background(Color.blue.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Spacer()

            // 底部按钮
            HStack {
                if modelPricing.isCustom {
                    Button("恢复内置默认基准") {
                        onReset()
                        dismiss()
                    }
                    .fluentButton(.danger)
                }

                Spacer()

                Button("取消") {
                    dismiss()
                }
                .fluentButton(.plain)
                .keyboardShortcut(.cancelAction)

                Button("保存校准") {
                    saveChanges()
                    dismiss()
                }
                .fluentButton(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .background(SettingsDemoTokens.window)
    }

    private func priceInputRow(label: String, sub: String, text: Binding<String>) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(SettingsDemoTokens.text)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            Spacer()
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text3)
                TextField("0.00", text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SettingsDemoTokens.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
                    )
            }
        }
    }

    private func saveChanges() {
        let input = Double(inputPriceText)
        let output = Double(outputPriceText)
        let cache = Double(cachePriceText)
        let note = noteText.trimmingCharacters(in: .whitespacesAndNewlines)

        let override = ModelPricingOverride(
            inputPricePerMillion: input,
            outputPricePerMillion: output,
            cacheReadPricePerMillion: cache,
            currency: currency,
            note: note.isEmpty ? nil : note
        )
        onSave(override)
    }
}
