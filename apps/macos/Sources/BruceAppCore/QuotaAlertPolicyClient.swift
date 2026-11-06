import Foundation
import BruceOnboardingCore

// MARK: - 共享额度预警决策 (T29/T30, design/02 规则 15)

/// 共享决策内核返回的一条告警事件.
package struct QuotaAlertEvent: Equatable, Sendable {
    package let eventId: String
    package let key: String
    package let serviceID: String
    package let serviceName: String
    package let providerID: String?
    package let windowKey: String
    package let windowLabel: String
    package let usedPercent: Double
    package let tier: Int
    package let resetAt: Int64?
    package let resetText: String?

    package init(
        eventId: String,
        key: String,
        serviceID: String,
        serviceName: String,
        providerID: String? = nil,
        windowKey: String,
        windowLabel: String,
        usedPercent: Double,
        tier: Int,
        resetAt: Int64? = nil,
        resetText: String? = nil
    ) {
        self.eventId = eventId
        self.key = key
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.providerID = providerID
        self.windowKey = windowKey
        self.windowLabel = windowLabel
        self.usedPercent = usedPercent
        self.tier = tier
        self.resetAt = resetAt
        self.resetText = resetText
    }

    init?(json: JSONValue) {
        guard let object = json.objectValue,
              let eventId = object["eventId"]?.stringValue,
              let key = object["key"]?.stringValue,
              let serviceID = object["serviceId"]?.stringValue,
              let serviceName = object["serviceName"]?.stringValue,
              let windowKey = object["windowKey"]?.stringValue,
              let windowLabel = object["windowLabel"]?.stringValue,
              let usedPercent = object["usedPercent"]?.doubleValue,
              let tier = object["tier"]?.intValue else {
            return nil
        }
        self.init(
            eventId: eventId,
            key: key,
            serviceID: serviceID,
            serviceName: serviceName,
            providerID: object["providerId"]?.stringValue,
            windowKey: windowKey,
            windowLabel: windowLabel,
            usedPercent: usedPercent,
            tier: tier,
            resetAt: object["resetAt"]?.intValue.map(Int64.init),
            resetText: object["resetText"]?.stringValue
        )
    }

    /// 转换为气泡展示模型.
    package var quotaAlert: QuotaAlert {
        QuotaAlert(
            serviceID: serviceID,
            serviceName: serviceName,
            windowLabel: windowLabel,
            usedPercent: usedPercent,
            tier: tier,
            providerID: providerID,
            resetText: resetText,
            resetsAt: resetAt.map {
                ISODate.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
            },
            resetToken: resetAt.map { "epoch:\($0)" },
            eventId: eventId
        )
    }
}

/// 一次决策的新状态与事件.
package struct QuotaAlertDecision: Equatable, Sendable {
    package let state: JSONValue
    package let events: [QuotaAlertEvent]
}

@MainActor
package protocol QuotaAlertDeciding: AnyObject {
    func decide(
        services: [JSONValue],
        previousState: JSONValue?,
        deliverable: Bool,
        activeKeys: [String]?,
        now: Date
    ) async throws -> QuotaAlertDecision
}

/// 经共享策略入口 (policy-request-v1) 调用 `alertDecide`; 与额度门禁/回填使用同一
/// 进程内静态库 (T16), 但保持独立客户端, 避免测试中脚本化额度策略时误消费预警响应.
@MainActor
package final class CollectorQuotaAlertPolicy: QuotaAlertDeciding {
    private let transport: QuotaPolicyTransport

    package init(transport: @escaping QuotaPolicyTransport) {
        self.transport = transport
    }

    package static func inProcess() -> CollectorQuotaAlertPolicy {
        CollectorQuotaAlertPolicy { input in InProcessQuotaPolicyTransport.call(input) }
    }

    package func decide(
        services: [JSONValue],
        previousState: JSONValue?,
        deliverable: Bool,
        activeKeys: [String]?,
        now: Date
    ) async throws -> QuotaAlertDecision {
        let request: JSONValue = .object([
            "schemaVersion": .integer(1),
            "operation": .string("alertDecide"),
            "nowMs": .integer(Int(now.timeIntervalSince1970 * 1000)),
            "deliverable": .boolean(deliverable),
            "services": .array(services),
            "previousState": previousState ?? .null,
            "activeKeys": activeKeys.map { .array($0.sorted().map(JSONValue.string)) } ?? .null,
        ])
        let output = try await transport(try JSONEncoder().encode(request))
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: output).objectValue,
              response["schemaVersion"]?.intValue == 1 else {
            throw QuotaPolicyError.invalidResponse
        }
        guard response["status"]?.stringValue == "success",
              let result = response["result"]?.objectValue else {
            let code = response["diagnostics"]?.arrayValue?.first?.objectValue?["code"]?
                .stringValue
            guard let code else { throw QuotaPolicyError.invalidResponse }
            throw QuotaPolicyError.rejected(code: code)
        }
        guard let state = result["state"],
              let events = result["events"]?.arrayValue else {
            throw QuotaPolicyError.invalidResponse
        }
        return QuotaAlertDecision(
            state: state,
            events: events.compactMap(QuotaAlertEvent.init(json:))
        )
    }
}

// MARK: - 状态持久化

/// 额度预警状态文件: 独立于展示快照, 清理用量缓存不删除.
package struct QuotaAlertStateStore {
    package static var standard: QuotaAlertStateStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Bruce", isDirectory: true)
            .appendingPathComponent("metadata", isDirectory: true)
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("Bruce", isDirectory: true)
                .appendingPathComponent("metadata", isDirectory: true)
        return QuotaAlertStateStore(url: base.appendingPathComponent("quota-alert-state-v1.json"))
    }

    private let url: URL
    private let store = AtomicJSONStore()

    package init(url: URL) {
        self.url = url
    }

    /// 读取状态; 缺失/损坏/版本不匹配返回 nil (调用方按静默 bootstrap 处理).
    package func load() -> JSONValue? {
        guard case .loaded(let state) = store.read(JSONValue.self, from: url),
              state.objectValue?["version"]?.intValue == 1 else {
            return nil
        }
        return state
    }

    /// 原子写入; 返回是否成功, 失败不阻断刷新 (调用方只记诊断).
    @discardableResult
    package func save(_ state: JSONValue) -> Bool {
        do {
            try store.prepareDirectory(at: url.deletingLastPathComponent())
            try store.write(state, to: url)
            return true
        } catch {
            // 状态丢失最多导致下一次 bootstrap, 不影响本轮展示; 由调用方日志记录.
            return false
        }
    }
}
