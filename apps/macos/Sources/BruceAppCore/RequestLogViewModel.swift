import Foundation
import SwiftUI

/// 设置中心「请求日志」页的视图模型 (design/14 §4.2.8)。
///
/// C249: 从 BruceApp 下沉到 BruceAppCore, 让 Harness 覆盖查询调度。查询按代次
/// 后发先至: 用户触发的查询 (进入、筛选、翻页、手动刷新) 总会发出, 并使进行中的
/// 旧查询结果作废; 后台刷新在已有查询进行时直接跳过。
@MainActor
package final class RequestLogViewModel: ObservableObject {
    package struct AgentOption: Identifiable, Hashable, Sendable {
        package let id: String
        package let name: String
    }

    package nonisolated static let agents: [AgentOption] = [
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

    package nonisolated static let supportedAgentIDs = RequestLogAgentFilter.supportedAgentIDs

    /// 「首版支持 …」说明文字, 与受支持集同源。
    package nonisolated static var supportedAgentNames: String {
        agents.filter { supportedAgentIDs.contains($0.id) }.map(\.name).joined(separator: " / ")
    }

    package nonisolated static func agentName(_ id: String) -> String {
        agents.first(where: { $0.id == id })?.name ?? id
    }

    package nonisolated static func pageCount(total: UInt64, pageSize: Int) -> Int {
        let size = UInt64(max(1, pageSize))
        return max(1, Int((total + size - 1) / size))
    }

    @Published package var range: RequestLogRange = .sevenDays
    @Published package private(set) var agentFilter = RequestLogAgentFilter()
    package var selectedAgentIDs: Set<String> { agentFilter.selectedIDs }
    @Published package private(set) var selectedModel: String?
    @Published package var pageSize: Int = 50
    @Published package private(set) var page: Int = 0
    @Published package private(set) var data: RequestLogPageModel = .empty
    @Published package private(set) var isLoading = false
    @Published package private(set) var errorMessage: String?
    @Published package var selectedEntry: RequestLogEntryModel?
    /// New request IDs from a background refresh; the row tint fades out after 1.8s.
    @Published package private(set) var highlightedEntryIDs: Set<String> = []

    private let client: RequestLogClient
    private let now: () -> Date
    private var loaded = false
    /// 每次发起查询或清空结果都递增; 只有最新代次的结果允许落地。
    private var generation = 0
    private var highlightClearTask: Task<Void, Never>?

    package convenience init(collectorURL: URL?) {
        self.init(client: RequestLogClient(executableURL: collectorURL))
    }

    init(client: RequestLogClient, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    package var modelOptions: [String] {
        var values = data.models ?? []
        if let selectedModel, !values.contains(selectedModel) {
            values.insert(selectedModel, at: 0)
        }
        return values
    }

    package var pageCount: Int {
        Self.pageCount(total: data.total, pageSize: pageSize)
    }

    package var agentLabel: String {
        let count = selectedAgentIDs.count
        if count == Self.supportedAgentIDs.count { return "全部 Agent" }
        if count == 0 { return "未选 Agent" }
        if count == 1, let id = selectedAgentIDs.first { return Self.agentName(id) }
        return "\(count) 个 Agent"
    }

    package func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        await refresh(highlightNew: false)
    }

    package func reloadForFilterChange() async {
        page = 0
        highlightedEntryIDs = []
        await refresh(highlightNew: false)
    }

    /// `silent`: background refresh — skipped while another query is in flight,
    /// and keeps the table and last data on failure.
    /// `highlightNew`: briefly tint rows that were not in the previous page.
    package func refresh(silent: Bool = false, highlightNew: Bool = true) async {
        if silent && isLoading { return }
        generation += 1
        let token = generation
        guard !selectedAgentIDs.isEmpty else {
            data = .empty
            errorMessage = nil
            highlightedEntryIDs = []
            isLoading = false
            return
        }
        let previousIDs = Set(data.entries.map(\.id))
        isLoading = true
        defer {
            if token == generation { isLoading = false }
        }
        do {
            var next = try await client.query(currentQuery())
            guard token == generation else { return }
            // 总量收缩 (时间窗滑动 / 30 天清理) 使当前页越界时, 回到最后一页再查一次。
            let lastPage = Self.pageCount(total: next.total, pageSize: pageSize) - 1
            if next.entries.isEmpty, page > lastPage {
                page = lastPage
                next = try await client.query(currentQuery())
                guard token == generation else { return }
            }
            apply(next, previousIDs: previousIDs, highlightNew: highlightNew)
        } catch {
            guard token == generation else { return }
            // 后台刷新失败保留上一次结果，不把整张表替换成错误态。
            if !silent {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }

    /// 自动刷新入口：只刷新第 1 页，避免翻页时行位移动；保留筛选，不整表重载。
    package func refreshInPlace() async {
        guard page == 0 else { return }
        await refresh(silent: true, highlightNew: true)
    }

    /// 首次进入/artifact 更新时，默认勾选“今日有使用量”的受支持 Agent。
    @discardableResult
    package func applyDefaultAgents(_ ids: Set<String>) -> Bool {
        guard agentFilter.applyDefault(activeIDs: ids) else { return false }
        page = 0
        return true
    }

    package func selectAllAgents() {
        guard agentFilter.selectAll() else { return }
        Task { await reloadForFilterChange() }
    }

    package func setAgent(_ id: String, selected: Bool) {
        guard agentFilter.set(id, selected: selected) else { return }
        Task { await reloadForFilterChange() }
    }

    package func setModel(_ model: String?) {
        selectedModel = model
        Task { await reloadForFilterChange() }
    }

    package func previousPage() async {
        guard page > 0 else { return }
        page -= 1
        await refresh()
    }

    package func nextPage() async {
        guard page + 1 < pageCount else { return }
        page += 1
        await refresh()
    }

    private func currentQuery() -> RequestLogQuery {
        let now = now()
        return RequestLogQuery(
            start: Int64(range.startDate(now: now).timeIntervalSince1970 * 1000),
            end: Int64(now.timeIntervalSince1970 * 1000),
            agentIDs: selectedAgentIDs.sorted(),
            model: selectedModel,
            page: page,
            pageSize: pageSize
        )
    }

    private func apply(
        _ next: RequestLogPageModel,
        previousIDs: Set<String>,
        highlightNew: Bool
    ) {
        errorMessage = nil
        guard next != data else { return }
        let newIDs = Set(next.entries.map(\.id)).subtracting(previousIDs)
        data = next
        if highlightNew, !previousIDs.isEmpty, !newIDs.isEmpty {
            highlightedEntryIDs.formUnion(newIDs)
            scheduleHighlightClear()
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
}
