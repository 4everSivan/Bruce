import AppKit
import BruceAppCore
import SwiftUI

/// 设置中心「请求日志」页 (design/14): 摘要条 + 全宽表格 + 居中详情 Sheet。
struct RequestLogView: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: RequestLogViewModel
    @State private var showsAgentFilter = false

    init(collectorURL: URL?) {
        _model = StateObject(wrappedValue: RequestLogViewModel(collectorURL: collectorURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toolbar
            summary
            scopeLine
            tableCard
        }
        .task {
            model.applyDefaultAgents(activeAgentIDs)
            await model.loadIfNeeded()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await model.refreshInPlace()
            }
        }
        .onChange(of: model.range) { _, _ in
            Task { await model.reloadForFilterChange() }
        }
        // Collector 在刷新末尾写入请求库；artifact 更新即代表本轮明细已落盘。
        .onChange(of: appModel.moduleArtifacts[.agentUsage]) { _, _ in
            let agentsChanged = model.applyDefaultAgents(activeAgentIDs)
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                if agentsChanged {
                    await model.reloadForFilterChange()
                } else {
                    await model.refreshInPlace()
                }
            }
        }
        .sheet(item: $model.selectedEntry) { entry in
            RequestLogDetailSheet(entry: entry)
        }
    }

    /// 今日有 Token 用量的受支持 Agent；首次进入的默认勾选来源。
    private var activeAgentIDs: Set<String> {
        Set(
            appModel.analyticsSnapshot(range: .today).agents
                .filter { $0.totalTokens > 0 }
                .map(\.agentID)
        )
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            FluentSegmentedPicker(
                options: RequestLogRange.allCases.map { ($0.title, $0) },
                selection: $model.range
            )

            Button {
                showsAgentFilter.toggle()
            } label: {
                filterLabel(model.agentLabel)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsAgentFilter, arrowEdge: .bottom) {
                agentFilterPopover
            }

            Menu {
                Button("全部模型") { model.setModel(nil) }
                Divider()
                ForEach(model.modelOptions, id: \.self) { name in
                    Button(name) { model.setModel(name) }
                }
            } label: {
                filterLabel(model.selectedModel ?? "全部模型")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 8)

            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .background(SettingsDemoTokens.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
            )
            .disabled(model.isLoading)
            .help("同步并刷新")
        }
    }

    private var agentFilterPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                model.selectAllAgents()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.selectedAgentIDs.count == RequestLogViewModel.supportedAgentIDs.count
                        ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            model.selectedAgentIDs.count == RequestLogViewModel.supportedAgentIDs.count
                                ? SettingsDemoTokens.accent : SettingsDemoTokens.text3
                        )
                    Text("全部 Agent")
                        .font(.system(size: 11.5, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider().overlay(SettingsDemoTokens.separator)

            ForEach(RequestLogViewModel.agents.filter { RequestLogViewModel.supportedAgentIDs.contains($0.id) }) { agent in
                let selected = model.selectedAgentIDs.contains(agent.id)
                Button {
                    model.setAgent(agent.id, selected: !selected)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 12))
                            .foregroundStyle(
                                selected ? SettingsDemoTokens.accent : SettingsDemoTokens.text3
                            )
                        AgentBrandBadge(
                            asset: AgentBrandPalette.asset(forAgent: agent.id),
                            seriesHex: PanelAgentColor.resolve(agentID: agent.id).hex,
                            size: 16,
                            followsTheme: false
                        )
                        Text(agent.name)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 220)
    }

    private func filterLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(SettingsDemoTokens.text2)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(SettingsDemoTokens.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    private var summary: some View {
        let data = model.data.effectiveSummary
        return HStack(spacing: 0) {
            summaryMetric("请求数", RequestLogFormat.count(model.data.total))
            summaryDivider
            summaryMetric("Token 合计", RequestLogFormat.tokens(data.tokens))
            summaryDivider
            summaryMetric("已计价费用", RequestLogFormat.costSummary(data.costUsd))
            summaryDivider
            summaryMetric("平均每请求", RequestLogFormat.tokens(data.avgTokens))
        }
        .frame(height: 54)
        .background(SettingsDemoTokens.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(SettingsDemoTokens.text3)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(SettingsDemoTokens.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(SettingsDemoTokens.separator)
            .frame(width: 1, height: 30)
    }

    private var scopeLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
            Text("基于本机会话日志，不包含未落盘的失败请求；明细保留 30 天。首版支持 Claude Code / Codex / Antigravity / ZCode。")
                .font(.system(size: 10.5))
        }
        .foregroundStyle(SettingsDemoTokens.text2)
        .lineLimit(1)
    }

    private var tableCard: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider().overlay(SettingsDemoTokens.separator)
            if model.isLoading && model.data.entries.isEmpty {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.data.entries.isEmpty {
                tableError(error)
            } else if model.data.entries.isEmpty {
                tableEmpty
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.data.entries) { entry in
                            tableRow(entry)
                            Divider().overlay(SettingsDemoTokens.separator.opacity(0.6))
                        }
                    }
                }
            }
            Divider().overlay(SettingsDemoTokens.separator)
            tableFooter
        }
        .frame(maxWidth: .infinity)
        .frame(height: 430)
        .background(SettingsDemoTokens.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            headerCell("时间", width: 92)
            headerCell("Agent", width: 104)
            headerCell("模型", width: 128)
            headerCell("新鲜输入", width: 60, alignment: .trailing)
            headerCell("输出", width: 52, alignment: .trailing)
            headerCell("缓存读", width: 66, alignment: .trailing)
            headerCell("费用", width: 62, alignment: .trailing)
            headerCell("速度", width: 58, alignment: .trailing)
            headerCell("工程", width: nil)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
    }

    private func headerCell(
        _ title: String,
        width: CGFloat?,
        alignment: Alignment = .leading
    ) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(SettingsDemoTokens.text3)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }

    private func tableRow(_ entry: RequestLogEntryModel) -> some View {
        HStack(spacing: 6) {
            Text(RequestLogFormat.time(entry.occurredAt))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text2)
                .frame(width: 92, alignment: .leading)
            HStack(spacing: 8) {
                AgentBrandBadge(
                    asset: AgentBrandPalette.asset(forAgent: entry.agentId),
                    seriesHex: PanelAgentColor.resolve(agentID: entry.agentId).hex,
                    size: 18,
                    followsTheme: false,
                    fallbackMonogram: "?"
                )
                Text(RequestLogViewModel.agentName(entry.agentId))
                    .font(.system(size: 11.5))
                    .lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            Text(entry.displayModel)
                .font(.system(size: 10.6, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text)
                .lineLimit(1)
                .frame(width: 128, alignment: .leading)
            numberCell(entry.input, width: 60)
            numberCell(entry.output, width: 52)
            numberCell(entry.cacheRead, width: 66)
            Text(RequestLogFormat.rowCost(entry.costUsd))
                .font(.system(size: 10.6, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(entry.costUsd == nil ? SettingsDemoTokens.text3 : SettingsDemoTokens.text)
                .frame(width: 62, alignment: .trailing)
            Text(entry.speedText)
                .font(.system(size: 10.4, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(entry.speedTokensPerSecond == nil ? SettingsDemoTokens.text3 : SettingsDemoTokens.text2)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
            Text(entry.project ?? "—")
                .font(.system(size: 10))
                .foregroundStyle(SettingsDemoTokens.text2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedEntry = entry }
        .hoverHighlight(highlighted: model.highlightedEntryIDs.contains(entry.id))
    }

    private func numberCell(_ value: UInt64, width: CGFloat) -> some View {
        Text(RequestLogFormat.count(value))
            .font(.system(size: 10.6, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(SettingsDemoTokens.text2)
            .frame(width: width, alignment: .trailing)
    }

    private var tableEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 18))
                .foregroundStyle(SettingsDemoTokens.text3)
                .frame(width: 34, height: 34)
                .background(SettingsDemoTokens.surfaceHover, in: RoundedRectangle(cornerRadius: 9))
            Text(model.selectedAgentIDs.isEmpty ? "还没有选中任何 Agent" : "没有匹配的请求")
                .font(.system(size: 13, weight: .semibold))
            Text(model.selectedAgentIDs.isEmpty
                ? "在 Agent 筛选中至少选择一个 Agent。"
                : "调整时间范围、Agent 或模型筛选；请求明细只保留最近 30 天。")
                .font(.system(size: 11))
                .foregroundStyle(SettingsDemoTokens.text2)
                .multilineTextAlignment(.center)
            if let notice = model.data.notice {
                Text(notice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func tableError(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundStyle(SettingsDemoTokens.warn)
                .frame(width: 34, height: 34)
                .background(SettingsDemoTokens.surfaceHover, in: RoundedRectangle(cornerRadius: 9))
            Text("请求日志暂不可用")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(SettingsDemoTokens.text2)
                .multilineTextAlignment(.center)
            Button("重试") { Task { await model.refresh() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var tableFooter: some View {
        HStack(spacing: 10) {
            Text("共 \(RequestLogFormat.count(model.data.total)) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(SettingsDemoTokens.text3)
            Spacer()
            Picker("", selection: $model.pageSize) {
                Text("50 条/页").tag(50)
                Text("100 条/页").tag(100)
                Text("200 条/页").tag(200)
            }
            .labelsHidden()
            .frame(width: 102)
            .onChange(of: model.pageSize) { _, _ in
                Task { await model.reloadForFilterChange() }
            }
            Button {
                Task { await model.previousPage() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(model.page == 0)
            Text("第 \(model.page + 1) / \(model.pageCount) 页")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SettingsDemoTokens.text2)
                .frame(minWidth: 70)
            Button {
                Task { await model.nextPage() }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(model.page + 1 >= model.pageCount)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

// MARK: - View Model

@MainActor
final class RequestLogViewModel: ObservableObject {
    struct AgentOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    static let agents: [AgentOption] = [
        .init(id: "claude-code", name: "Claude Code"),
        .init(id: "codex", name: "Codex"),
        .init(id: "antigravity", name: "Antigravity"),
        .init(id: "kimi-code-cli", name: "Kimi Code CLI"),
        .init(id: "kimi-work", name: "Kimi Work"),
        .init(id: "grok", name: "Grok"),
        .init(id: "pi", name: "Pi"),
        .init(id: "zcode", name: "ZCode"),
        .init(id: "opencode", name: "OpenCode"),
        .init(id: "codebuddy", name: "CodeBuddy"),
        .init(id: "dsh", name: "DSH"),
    ]

    static let supportedAgentIDs = RequestLogAgentFilter.supportedAgentIDs

    static func agentName(_ id: String) -> String {
        agents.first(where: { $0.id == id })?.name ?? id
    }

    @Published var range: RequestLogRange = .sevenDays
    @Published private(set) var agentFilter = RequestLogAgentFilter()
    var selectedAgentIDs: Set<String> { agentFilter.selectedIDs }
    @Published private(set) var selectedModel: String?
    @Published var pageSize: Int = 50
    @Published private(set) var page: Int = 0
    @Published private(set) var data: RequestLogPageModel = .empty
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedEntry: RequestLogEntryModel?
    /// New request IDs from a background refresh; the row tint fades out after 1.8s.
    @Published private(set) var highlightedEntryIDs: Set<String> = []

    private let client: RequestLogClient
    private var loaded = false
    private var highlightClearTask: Task<Void, Never>?

    init(collectorURL: URL?) {
        client = RequestLogClient(executableURL: collectorURL)
    }

    var modelOptions: [String] {
        var values = data.models ?? []
        if let selectedModel, !values.contains(selectedModel) {
            values.insert(selectedModel, at: 0)
        }
        return values
    }

    var pageCount: Int {
        max(1, Int((data.total + UInt64(pageSize) - 1) / UInt64(pageSize)))
    }

    var agentLabel: String {
        let count = selectedAgentIDs.count
        if count == RequestLogViewModel.supportedAgentIDs.count { return "全部 Agent" }
        if count == 0 { return "未选 Agent" }
        if count == 1, let id = selectedAgentIDs.first { return Self.agentName(id) }
        return "\(count) 个 Agent"
    }

    func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await refresh(highlightNew: false)
    }

    func reloadForFilterChange() async {
        page = 0
        highlightedEntryIDs = []
        await refresh(highlightNew: false)
    }

    /// `silent`: background refresh — keep the table and last data on failure.
    /// `highlightNew`: briefly tint rows that were not in the previous page.
    func refresh(silent: Bool = false, highlightNew: Bool = true) async {
        guard !isLoading else { return }
        if selectedAgentIDs.isEmpty {
            data = .empty
            errorMessage = nil
            highlightedEntryIDs = []
            return
        }
        let previousIDs = Set(data.entries.map(\.id))
        let hadData = !previousIDs.isEmpty
        isLoading = true
        defer { isLoading = false }
        let now = Date()
        let query = RequestLogQuery(
            start: Int64(range.startDate(now: now).timeIntervalSince1970 * 1000),
            end: Int64(now.timeIntervalSince1970 * 1000),
            agentIDs: selectedAgentIDs.sorted(),
            model: selectedModel,
            page: page,
            pageSize: pageSize
        )
        do {
            let next = try await client.query(query)
            if next == data {
                errorMessage = nil
                return
            }
            let newIDs = Set(next.entries.map(\.id)).subtracting(previousIDs)
            data = next
            errorMessage = nil
            if highlightNew, hadData, !newIDs.isEmpty {
                highlightedEntryIDs.formUnion(newIDs)
                scheduleHighlightClear()
            }
        } catch {
            // 后台刷新失败保留上一次结果，不把整张表替换成错误态。
            if !silent {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// 自动刷新入口：只刷新第 1 页；保留筛选与页码，不整表重载。
    func refreshInPlace() async {
        guard page == 0 else { return }
        let previousPage = page
        await refresh(silent: true, highlightNew: true)
        if page >= pageCount {
            page = max(0, pageCount - 1)
            if page != previousPage {
                await refresh(silent: true, highlightNew: false)
            }
        }
    }

    private func scheduleHighlightClear() {
        highlightClearTask?.cancel()
        highlightClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeOut(duration: 0.8)) {
                self.highlightedEntryIDs.removeAll()
            }
        }
    }

    /// 首次进入/artifact 更新时，默认勾选“今日有使用量”的受支持 Agent。
    @discardableResult
    func applyDefaultAgents(_ ids: Set<String>) -> Bool {
        guard agentFilter.applyDefault(activeIDs: ids) else { return false }
        page = 0
        return true
    }

    func selectAllAgents() {
        guard agentFilter.selectAll() else { return }
        Task { await reloadForFilterChange() }
    }

    func setAgent(_ id: String, selected: Bool) {
        guard agentFilter.set(id, selected: selected) else { return }
        Task { await reloadForFilterChange() }
    }

    func setModel(_ model: String?) {
        selectedModel = model
        Task { await reloadForFilterChange() }
    }

    func previousPage() async {
        guard page > 0 else { return }
        page -= 1
        await refresh()
    }

    func nextPage() async {
        guard page + 1 < pageCount else { return }
        page += 1
        await refresh()
    }
}

// MARK: - Detail Sheet

private struct RequestLogDetailSheet: View {
    let entry: RequestLogEntryModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(SettingsDemoTokens.separator)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("身份") {
                        detailGrid([
                            ("时间", RequestLogFormat.dateTime(entry.occurredAt), true),
                            ("Agent", RequestLogViewModel.agentName(entry.agentId), false),
                            ("工程", entry.project ?? "—", false),
                            ("数据来源", "本机会话日志", false),
                        ])
                    }
                    section("模型") {
                        detailGrid([
                            ("模型", entry.displayModel, true),
                            ("原始模型名", entry.rawModel ?? entry.model ?? "—", true),
                            ("计价模型", entry.model ?? "—", true),
                            ("保真度", entry.fidelity == "exact" ? "精确（来源给出 Token 计数）" : "估算", false),
                        ])
                    }
                    section("Token") {
                        HStack(spacing: 8) {
                            tokenCell("新鲜输入", entry.input)
                            tokenCell("输出", entry.output)
                            tokenCell("缓存读", entry.cacheRead)
                            tokenCell("缓存写", entry.cacheCreation)
                        }
                        Text(tokenNote)
                            .font(.system(size: 10))
                            .foregroundStyle(SettingsDemoTokens.text3)
                            .padding(.top, 8)
                    }
                    section("性能") {
                        detailGrid([
                            ("速度", entry.speedText, false),
                            ("总耗时", RequestLogFormat.duration(entry.latencyMs), false),
                            ("首字", RequestLogFormat.duration(entry.firstTokenMs), false),
                            ("来源", entry.latencyMs == nil ? "会话日志未记录" : "原生计时", false),
                        ])
                    }
                    section("费用") {
                        detailGrid([
                            ("合计", RequestLogFormat.rowCost(entry.costUsd), true),
                            ("状态", "\(entry.statusCode) · 已完成", false),
                        ])
                    }
                    section("请求 ID") {
                        HStack(spacing: 8) {
                            Text(entry.requestId)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(SettingsDemoTokens.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(copied ? "已复制" : "复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.requestId, forType: .string)
                                copied = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(9)
                        .background(SettingsDemoTokens.bg, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
                        )
                    }
                }
                .padding(.horizontal, 18)
            }
        }
        .frame(width: 480)
        .frame(maxHeight: 560)
        .background(SettingsDemoTokens.surface)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 14))
                .foregroundStyle(SettingsDemoTokens.accent)
                .frame(width: 28, height: 28)
                .background(
                    SettingsDemoTokens.accent.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("请求详情")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(RequestLogFormat.dateTime(entry.occurredAt)) · \(RequestLogViewModel.agentName(entry.agentId))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SettingsDemoTokens.text3)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(SettingsDemoTokens.text3)
            content()
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SettingsDemoTokens.separator.opacity(0.7))
                .frame(height: 1)
        }
    }

    private func detailGrid(_ rows: [(String, String, Bool)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.0)
                        .font(.system(size: 10))
                        .foregroundStyle(SettingsDemoTokens.text3)
                    Text(row.1)
                        .font(.system(size: row.2 ? 10.8 : 12, design: row.2 ? .monospaced : .default))
                        .lineLimit(1)
                }
            }
        }
    }

    private func tokenCell(_ title: String, _ value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5))
                .foregroundStyle(SettingsDemoTokens.text3)
            Text(RequestLogFormat.count(value))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .background(SettingsDemoTokens.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(SettingsDemoTokens.separator, lineWidth: 1)
        )
    }

    private var tokenNote: String {
        entry.agentId == "antigravity"
            ? "Antigravity Token 口径：输入不含缓存，输出已包含思考；不再二次扣减或累加。"
            : "Token 口径与聚合一致：输入为已排除缓存的新鲜输入，输出为模型返回的完成量。"
    }
}

// MARK: - Formatting

enum RequestLogFormat {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func time(_ millis: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func dateTime(_ millis: Int64) -> String {
        dateTimeFormatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
    }

    static func count(_ value: UInt64) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func tokens(_ value: UInt64) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.2fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return String(value)
    }

    static func rowCost(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 0.1
            ? String(format: "$%.2f", value)
            : String(format: "$%.4f", value)
    }

    static func costSummary(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    static func duration(_ millis: Int64?) -> String {
        guard let millis, millis > 0 else { return "—" }
        if millis >= 1000 {
            return String(format: "%.2fs", Double(millis) / 1000)
        }
        return "\(millis)ms"
    }
}

// MARK: - Row hover

private struct RequestLogRowHover: ViewModifier {
    let highlighted: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                hovering
                    ? SettingsDemoTokens.surfaceHover
                    : (highlighted ? SettingsDemoTokens.accent.opacity(0.16) : Color.clear)
            )
            .overlay(alignment: .leading) {
                if highlighted {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(SettingsDemoTokens.accent)
                        .frame(width: 2)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.8), value: highlighted)
            .onHover { hovering = $0 }
    }
}

private extension View {
    func hoverHighlight(highlighted: Bool = false) -> some View {
        modifier(RequestLogRowHover(highlighted: highlighted))
    }
}
