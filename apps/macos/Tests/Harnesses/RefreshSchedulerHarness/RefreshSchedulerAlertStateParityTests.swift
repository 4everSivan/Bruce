import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

// MARK: - 额度预警状态机共享 fixture (T29/T31)

extension RefreshSchedulerHarness {
    /// 与 collector-policy / Windows 消费同一份 cases.json, 锁定 mac 侧 state/events.
    static func quotaAlertStateMatchesSharedFixture(repository: URL) async throws {
        let url = repository
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("quota-alert-state-parity")
            .appendingPathComponent("cases.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONDecoder().decode(JSONValue.self, from: data).objectValue,
              let cases = root["cases"]?.arrayValue else {
            throw RefreshTestFailure.expectation("quota-alert-state fixture 形状无效")
        }
        let policy = CollectorQuotaAlertPolicy.inProcess()
        for caseValue in cases {
            guard let caseObject = caseValue.objectValue,
                  let name = caseObject["name"]?.stringValue,
                  let deliverable = caseObject["deliverable"]?.boolValue,
                  let steps = caseObject["steps"]?.arrayValue else {
                throw RefreshTestFailure.expectation("fixture case 形状无效")
            }
            var state = caseObject["previousState"]
            for (index, stepValue) in steps.enumerated() {
                guard let step = stepValue.objectValue,
                      let nowMs = step["nowMs"]?.intValue,
                      let services = step["services"]?.arrayValue,
                      let expected = step["expected"]?.objectValue,
                      let expectedTiers = expected["eventTiers"]?.arrayValue,
                      let expectedDelivered = expected["deliveredTier"]?.intValue,
                      let expectedWindowId = expected["windowId"]?.stringValue else {
                    throw RefreshTestFailure.expectation("fixture step 形状无效")
                }
                let decision = try await policy.decide(
                    services: services,
                    previousState: state,
                    deliverable: deliverable,
                    activeKeys: nil,
                    now: Date(timeIntervalSince1970: Double(nowMs) / 1000)
                )
                let tiers = decision.events.map(\.tier)
                let expectedTierValues = expectedTiers.compactMap(\.intValue)
                try refreshExpect(
                    tiers == expectedTierValues,
                    "\(name) step \(index) event tiers \(tiers) != \(expectedTierValues)"
                )
                let windows = decision.state.objectValue?["windows"]?.objectValue
                let key = decision.events.first.map { "\($0.serviceID)|five_hour" }
                    ?? windows?.keys.first
                guard let key, let entry = windows?[key]?.objectValue else {
                    throw RefreshTestFailure.expectation("\(name) step \(index) 缺少状态键")
                }
                try refreshExpect(
                    entry["deliveredTier"]?.intValue == expectedDelivered,
                    "\(name) step \(index) deliveredTier \(String(describing: entry["deliveredTier"])) != \(expectedDelivered)"
                )
                try refreshExpect(
                    entry["windowId"]?.stringValue == expectedWindowId,
                    "\(name) step \(index) windowId \(String(describing: entry["windowId"])) != \(expectedWindowId)"
                )
                state = decision.state
            }
        }
    }
}
