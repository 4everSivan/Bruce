import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

/// T17: 窗口边界唤醒与退避的共享 fixture (tests/fixtures/refresh-policy-parity)。
/// 与 Windows scheduler_collector_coverage 消费同一份用例; mac 走真实 C ABI 路径。
@MainActor
func refreshPolicyMatchesSharedFixture(repository: URL) throws {
    let url = repository.appendingPathComponent(
        "tests/fixtures/refresh-policy-parity/cases.json"
    )
    let fixture = try JSONDecoder().decode(
        JSONValue.self,
        from: Data(contentsOf: url)
    )
    guard let boundaryIds = fixture.objectValue?["boundaryIds"]?.arrayValue,
          let wakeCases = fixture.objectValue?["boundaryWake"]?.arrayValue,
          let backoffCases = fixture.objectValue?["backoff"]?.arrayValue else {
        throw RefreshTestFailure.expectation("refresh parity fixture 缺少用例")
    }

    func integers(_ value: JSONValue?) -> [Int64] {
        (value?.arrayValue ?? []).compactMap { $0.intValue.map(Int64.init) }
    }

    for item in boundaryIds {
        guard let object = item.objectValue,
              let name = object["name"]?.stringValue,
              let services = object["services"]?.arrayValue else {
            throw RefreshTestFailure.expectation("boundaryIds 用例格式无效")
        }
        let artifact: JSONValue = .object(["services": .array(services)])
        let actual = SubscriptionBoundaryWakePolicy.boundaries(in: artifact)
        guard actual == integers(object["expected"]) else {
            throw RefreshTestFailure.expectation(
                "boundaryIds \(name): \(actual)"
            )
        }
    }

    for item in wakeCases {
        guard let object = item.objectValue,
              let name = object["name"]?.stringValue,
              let interval = object["interval"]?.doubleValue,
              let nowEpoch = object["now"]?.doubleValue,
              let expectedDelay = object["expectedDelay"]?.doubleValue else {
            throw RefreshTestFailure.expectation("boundaryWake 用例格式无效")
        }
        var consumed = Set(integers(object["consumed"]))
        let delay = SubscriptionBoundaryWakePolicy.delay(
            intervalRemaining: interval,
            boundaries: integers(object["boundaries"]),
            now: Date(timeIntervalSince1970: nowEpoch),
            slack: object["slack"]?.doubleValue
                ?? SubscriptionBoundaryWakePolicy.slack,
            consumed: &consumed
        )
        guard abs(delay - expectedDelay) < 1e-6 else {
            throw RefreshTestFailure.expectation(
                "boundaryWake \(name): \(delay) != \(expectedDelay)"
            )
        }
        guard consumed == Set(integers(object["expectedConsumed"])) else {
            throw RefreshTestFailure.expectation(
                "boundaryWake \(name): consumed \(consumed.sorted())"
            )
        }
    }

    for item in backoffCases {
        guard let object = item.objectValue,
              let name = object["name"]?.stringValue,
              let retryCount = object["retryCount"]?.intValue,
              let rateLimited = object["rateLimited"]?.boolValue,
              let base = object["base"]?.doubleValue,
              let max = object["max"]?.doubleValue,
              let rateLimit = object["rateLimit"]?.doubleValue,
              let jitter = object["jitterFraction"]?.doubleValue,
              let expected = object["expectedSeconds"]?.doubleValue else {
            throw RefreshTestFailure.expectation("backoff 用例格式无效")
        }
        let configuration = SchedulerConfiguration(
            refreshInterval: 1800,
            staleAfter: 3600,
            maxBackoffRetries: 5,
            baseBackoffSeconds: base,
            maxBackoffSeconds: max,
            rateLimitBackoffSeconds: rateLimit,
            capacityLimit: 2,
            quotaRefreshInterval: 1800,
            wakeDedupSeconds: 60
        )
        let seconds = RefreshBackoffPolicy(
            configuration: configuration,
            jitterProvider: { jitter }
        ).computeBackoff(
            retryCount: retryCount,
            category: rateLimited ? .rateLimit : nil
        )
        guard abs(seconds - expected) < 1e-6 else {
            throw RefreshTestFailure.expectation(
                "backoff \(name): \(seconds) != \(expected)"
            )
        }
    }
}
