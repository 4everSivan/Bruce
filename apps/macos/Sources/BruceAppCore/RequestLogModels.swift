import Foundation

/// Request-log time slices. The server retains 30 days, so `allTime` is not offered.
package enum RequestLogRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .today: return "今日"
        case .sevenDays: return "近 7 天"
        case .thirtyDays: return "近 30 天"
        }
    }

    package func startDate(now: Date = Date()) -> Date {
        switch self {
        case .today:
            return Calendar.current.startOfDay(for: now)
        case .sevenDays:
            return now.addingTimeInterval(-7 * 24 * 60 * 60)
        case .thirtyDays:
            return now.addingTimeInterval(-30 * 24 * 60 * 60)
        }
    }
}

package struct RequestLogQuery: Equatable, Sendable {
    package var start: Int64
    package var end: Int64
    package var agentIDs: [String]
    package var model: String?
    package var page: Int
    package var pageSize: Int

    package init(
        start: Int64,
        end: Int64,
        agentIDs: [String] = [],
        model: String? = nil,
        page: Int = 0,
        pageSize: Int = 50
    ) {
        self.start = start
        self.end = end
        self.agentIDs = agentIDs
        self.model = model
        self.page = page
        self.pageSize = pageSize
    }
}

/// Request-log Agent 筛选策略 (design/14 §4.2.8):
/// 首次默认只勾选今日有 Token 用量的受支持来源；用户手动改选后不再自动覆盖；
/// 「全部 Agent」是幂等全选，重复点击不会清空。
package struct RequestLogAgentFilter: Equatable, Sendable {
    package static let supportedAgentIDs: Set<String> = [
        "claude-code", "codex", "antigravity", "zcode",
    ]

    package private(set) var selectedIDs: Set<String> = []
    package private(set) var hasUserChosen = false

    package init() {}

    /// 返回是否实际改变了选择。
    @discardableResult
    package mutating func applyDefault(activeIDs: Set<String>) -> Bool {
        guard !hasUserChosen else { return false }
        let next = activeIDs.intersection(Self.supportedAgentIDs)
        guard next != selectedIDs else { return false }
        selectedIDs = next
        return true
    }

    /// 重复点击保持全选；返回是否实际改变了选择。
    @discardableResult
    package mutating func selectAll() -> Bool {
        hasUserChosen = true
        guard selectedIDs != Self.supportedAgentIDs else { return false }
        selectedIDs = Self.supportedAgentIDs
        return true
    }

    @discardableResult
    package mutating func set(_ id: String, selected: Bool) -> Bool {
        guard Self.supportedAgentIDs.contains(id) else { return false }
        hasUserChosen = true
        if selected {
            return selectedIDs.insert(id).inserted
        }
        return selectedIDs.remove(id) != nil
    }
}

package struct RequestLogSummaryModel: Codable, Equatable, Sendable {
    package let tokens: UInt64
    package let costUsd: Double
    package let avgTokens: UInt64

    package static let empty = RequestLogSummaryModel(tokens: 0, costUsd: 0, avgTokens: 0)
}

package struct RequestLogEntryModel: Codable, Identifiable, Equatable, Sendable {
    package let requestId: String
    package let agentId: String
    package let model: String?
    package let rawModel: String?
    package let occurredAt: Int64
    package let input: UInt64
    package let output: UInt64
    package let cacheRead: UInt64
    package let cacheCreation: UInt64
    package let cacheCreation1h: UInt64?
    package let costUsd: Double?
    package let statusCode: Int
    package let project: String?
    package let fidelity: String
    package let latencyMs: Int64?
    package let firstTokenMs: Int64?

    package var id: String { requestId }

    /// Estimated output speed for session-log rows (cc-switch 同口径):
    /// output ÷ total latency (first-token wait included), only when output ≥ 200
    /// and latency ≥ 1s. The UI prefixes it with `≈`.
    package var speedTokensPerSecond: Double? {
        guard output >= 200, let latencyMs, latencyMs >= 1_000 else { return nil }
        let speed = Double(output) / (Double(latencyMs) / 1000)
        return speed.isFinite && speed > 0 ? speed : nil
    }

    package var speedText: String {
        guard let speedTokensPerSecond else { return "—" }
        let value = speedTokensPerSecond >= 1
            ? String(Int(speedTokensPerSecond.rounded()))
            : String(format: "%.1f", speedTokensPerSecond)
        return "≈\(value)/s"
    }

    /// 表格/详情展示用模型名：优先归一化模型；归一化失败（如 Antigravity
    /// Orchestrator 模式）回退原始标签；两者皆缺才显示 `unknown`。
    package var displayModel: String {
        if let model, !model.isEmpty { return model }
        if let rawModel, !rawModel.isEmpty { return rawModel }
        return "unknown"
    }

    package var totalTokens: UInt64 {
        input + output + cacheRead + cacheCreation
    }
}

package struct RequestLogPageModel: Codable, Equatable, Sendable {
    package let total: UInt64
    package let page: Int
    package let pageSize: Int
    package let summary: RequestLogSummaryModel?
    package let models: [String]?
    package let entries: [RequestLogEntryModel]
    package let notice: String?

    package var effectiveSummary: RequestLogSummaryModel {
        summary ?? RequestLogSummaryModel(
            tokens: entries.reduce(0) { $0 + $1.totalTokens },
            costUsd: entries.compactMap(\.costUsd).reduce(0, +),
            avgTokens: 0
        )
    }

    package static let empty = RequestLogPageModel(
        total: 0,
        page: 0,
        pageSize: 50,
        summary: .empty,
        models: [],
        entries: [],
        notice: nil
    )
}

package enum RequestLogClientError: Error, Equatable, LocalizedError, Sendable {
    case missingExecutable
    case launchFailed
    case timedOut
    case processFailed(exitCode: Int32)
    case invalidEnvelope
    case collector(String)

    package var errorDescription: String? {
        switch self {
        case .missingExecutable:
            return "未找到 Bruce Collector, 无法查询请求日志"
        case .launchFailed:
            return "请求日志查询进程启动失败"
        case .timedOut:
            return "请求日志查询超时"
        case let .processFailed(exitCode):
            return "请求日志查询进程退出码 \(exitCode)"
        case .invalidEnvelope:
            return "请求日志查询返回格式无效"
        case let .collector(message):
            return message
        }
    }
}
