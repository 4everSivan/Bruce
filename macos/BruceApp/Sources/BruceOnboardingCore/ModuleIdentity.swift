import Foundation

/// 采集模块标识. 在 Core 和 executable 之间共享.
public enum CollectorModule: String, Codable, CaseIterable, Sendable {
    case agentUsage = "agent-usage"
}
