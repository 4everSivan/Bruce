import Foundation
import MdddOnboardingCore

package struct AgentTokenBucket: Codable, Equatable, Sendable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheCreation: Int
    let total: Int
}

package struct AgentDailyUsage: Codable, Equatable, Sendable {
    let date: String
    let input: Int
    let output: Int
    let total: Int
}

package struct AgentProjectUsage: Codable, Equatable, Sendable {
    let name: String
    let total: Int
}

package struct AgentUsageItem: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let note: String?
    let today: AgentTokenBucket
    let daily: [AgentDailyUsage]
    let hours: [Int]
    let todayCostUsd: Double?
    /// 今日按模型聚合的 token 总量 (模型名 -> total), collector 已按量降序截断.
    let models: [String: Int]?
    /// 今日按项目聚合的分布 (collector 只保留 Top 3).
    let projects: [AgentProjectUsage]?
}

package struct AgentServiceItem: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let status: String
    let windows: [JSONValue]
    /// 来源应用标记, codex 账号条目为 "codex", App 合成条目为 kimi/deepseek/volcengine.
    let app: String?
    let isCurrent: Bool?
    /// "windows" 为量条型, "balance" 为余额型, 未授权占位为 nil.
    let kind: String?
    let plan: String?
    let balance: Double?
    let currency: String?
    let note: String?
    /// 附加说明 (如 Kimi 加量包余额文案), 与 windows 并列展示.
    let extra: String?
    /// 该账号当前展示额度数据的成功采集时间 (ISO-8601).
    /// freshness=fresh 时等于本轮成功时间; stale 时为旧额度时间; unavailable 时为 nil.
    let capturedAt: String?
    /// 额度新鲜度: fresh (本轮成功), stale (保留旧额度), unavailable (从未成功).
    let freshness: String?
    /// 失败类型: auth | permission | rateLimit | network | server | invalidResponse | storage | tokenUnavailable.
    let failureKind: String?

    package init(
        id: String,
        name: String,
        status: String,
        windows: [JSONValue],
        app: String? = nil,
        isCurrent: Bool? = nil,
        kind: String? = nil,
        plan: String? = nil,
        balance: Double? = nil,
        currency: String? = nil,
        note: String? = nil,
        extra: String? = nil,
        capturedAt: String? = nil,
        freshness: String? = nil,
        failureKind: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.windows = windows
        self.app = app
        self.isCurrent = isCurrent
        self.kind = kind
        self.plan = plan
        self.balance = balance
        self.currency = currency
        self.note = note
        self.extra = extra
        self.capturedAt = capturedAt
        self.freshness = freshness
        self.failureKind = failureKind
    }
}

package struct AgentUsageArtifact: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let module: CollectorModule
    let generatedAt: String
    let agents: [AgentUsageItem]
    let services: [AgentServiceItem]
    let totalCostUsd: Double?
}

package enum DecodedArtifact: Equatable, Sendable {
    case agentUsage(AgentUsageArtifact)
}

package enum ArtifactValidationError: Error, Equatable {
    case notAnObject
    case unsupportedSchema(Int)
    case moduleMismatch
    case invalidDate
    case invalidValue
    case sensitiveField
    case decodeFailed
}

package struct ArtifactValidator {
    package static let currentSchemaVersion = 1

    package init() {}

    package func validate(
        _ artifact: JSONValue,
        for expectedModule: CollectorModule
    ) throws -> DecodedArtifact {
        guard case .object(let object) = artifact else {
            throw ArtifactValidationError.notAnObject
        }
        if containsSensitiveField(artifact) {
            throw ArtifactValidationError.sensitiveField
        }
        guard case .integer(let schemaVersion)? = object["schemaVersion"] else {
            throw ArtifactValidationError.unsupportedSchema(0)
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ArtifactValidationError.unsupportedSchema(schemaVersion)
        }
        guard case .string(let moduleName)? = object["module"],
              moduleName == expectedModule.rawValue else {
            throw ArtifactValidationError.moduleMismatch
        }
        let data: Data
        do {
            data = try JSONEncoder().encode(artifact)
        } catch {
            throw ArtifactValidationError.decodeFailed
        }

        switch expectedModule {
        case .agentUsage:
            let decoded: AgentUsageArtifact = try decode(data)
            try validateHeader(
                version: decoded.schemaVersion,
                module: decoded.module,
                generatedAt: decoded.generatedAt,
                expectedModule: expectedModule
            )
            guard decoded.totalCostUsd.map({ $0 >= 0 }) ?? true else {
                throw ArtifactValidationError.invalidValue
            }
            for agent in decoded.agents {
                let bucket = agent.today
                guard [
                    bucket.input,
                    bucket.output,
                    bucket.cacheRead,
                    bucket.cacheCreation,
                    bucket.total,
                ].allSatisfy({ $0 >= 0 }),
                    agent.hours.count == 24,
                    agent.hours.allSatisfy({ $0 >= 0 }),
                    agent.todayCostUsd.map({ $0 >= 0 }) ?? true else {
                    throw ArtifactValidationError.invalidValue
                }
                for day in agent.daily {
                    guard validDay(day.date),
                          day.input >= 0,
                          day.output >= 0,
                          day.total >= 0 else {
                        throw ArtifactValidationError.invalidValue
                    }
                }
            }
            return .agentUsage(decoded)
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ArtifactValidationError.decodeFailed
        }
    }

    private func validateHeader(
        version: Int,
        module: CollectorModule,
        generatedAt: String,
        expectedModule: CollectorModule
    ) throws {
        guard version == Self.currentSchemaVersion else {
            throw ArtifactValidationError.unsupportedSchema(version)
        }
        guard module == expectedModule else {
            throw ArtifactValidationError.moduleMismatch
        }
        guard ISO8601DateFormatter().date(from: generatedAt) != nil else {
            throw ArtifactValidationError.invalidDate
        }
    }

    private func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    private func containsSensitiveField(_ value: JSONValue) -> Bool {
        switch value {
        case .object(let object):
            for (key, child) in object {
                let normalized = key
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber }
                if [
                    "token",
                    "secret",
                    "password",
                    "authorization",
                    "cookie",
                    "apikey",
                    "privatekey",
                    "credential",
                ].contains(where: { normalized.contains($0) }) {
                    return true
                }
                if containsSensitiveField(child) {
                    return true
                }
            }
            return false
        case .array(let values):
            return values.contains(where: containsSensitiveField)
        default:
            return false
        }
    }
}
