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

    package var id: String { requestId }

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
