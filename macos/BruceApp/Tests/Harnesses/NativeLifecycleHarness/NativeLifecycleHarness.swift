import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

enum TestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw TestFailure.expectation(message)
    }
}

@MainActor
private final class Runtime: ApplicationRuntimeControlling {
    var hasRunningTasks = false
    private(set) var schedulerStartCount = 0
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var forceCount = 0

    func startSchedulerIfNeeded() {
        if schedulerStartCount == 0 {
            schedulerStartCount = 1
        }
    }

    func stopScheduling() {
        stopCount += 1
    }

    func cancelRunningTasks() {
        cancelCount += 1
    }

    func forceTerminateRunningTasks() {
        forceCount += 1
        hasRunningTasks = false
    }

    func resumeScheduling() {
        resumeCount += 1
    }

    private(set) var resumeCount = 0
}

@main
@MainActor
struct NativeLifecycleHarness {
    static func main() throws {
        try exitForcesRemainingTasksAfterGracePeriod()
        try exitCompletesImmediatelyWithoutRunningTasks()
        try cancelTerminationRestoresScheduling()
        try metricSelectionNormalizes()
        try menuBarSummaryUsesValidQuotaWindows()
        try metricFormatterUsesCompactValues()
        print("Native lifecycle tests passed: 6")
    }

    private static func exitForcesRemainingTasksAfterGracePeriod() throws {
        let runtime = Runtime()
        runtime.hasRunningTasks = true
        var graceAction: (@MainActor () -> Void)?
        var completionCount = 0
        let coordinator = ApplicationLifecycleCoordinator(
            runtime: runtime,
            scheduleGracePeriod: { action in graceAction = action }
        )

        coordinator.beginTermination {
            completionCount += 1
        }

        try expect(runtime.stopCount == 1, "exit did not stop scheduling")
        try expect(runtime.cancelCount == 1, "exit did not cancel tasks")
        try expect(completionCount == 0, "exit ignored the grace period")
        graceAction?()
        try expect(runtime.forceCount == 1, "exit did not force termination")
        try expect(completionCount == 1, "exit completion count is invalid")
    }

    private static func exitCompletesImmediatelyWithoutRunningTasks() throws {
        let runtime = Runtime()
        var completed = false
        let coordinator = ApplicationLifecycleCoordinator(
            runtime: runtime
        )
        coordinator.beginTermination {
            completed = true
        }
        try expect(completed, "idle exit should complete immediately")
        try expect(runtime.forceCount == 0, "idle exit forced a task")

        runtime.startSchedulerIfNeeded()
        runtime.startSchedulerIfNeeded()
        try expect(
            runtime.schedulerStartCount == 1,
            "scheduler started more than once"
        )
    }

    /// 用户取消退出后恢复调度: cancelTermination 调用 resumeScheduling,
    /// 后续刷新继续可用 (回归: 曾永久 stopped 导致刷新按钮失效).
    private static func cancelTerminationRestoresScheduling() throws {
        let runtime = Runtime()
        runtime.hasRunningTasks = true
        var graceAction: (@MainActor () -> Void)?
        let coordinator = ApplicationLifecycleCoordinator(
            runtime: runtime,
            scheduleGracePeriod: { action in graceAction = action }
        )

        coordinator.beginTermination { }
        try expect(runtime.stopCount == 1, "cancel 前应 stop scheduling")
        try expect(runtime.resumeCount == 0, "cancel 前不应 resume")

        // 用户取消退出
        coordinator.cancelTermination()
        try expect(runtime.resumeCount == 1, "取消退出应恢复调度")
        try expect(runtime.stopCount == 1, "取消退出不应重复 stop")

        // 再次取消无操作 (幂等)
        coordinator.cancelTermination()
        try expect(runtime.resumeCount == 1, "重复取消应幂等")
    }

    private static func metricSelectionNormalizes() throws {
        let config = MenuBarMetricConfiguration(rawValues: [
            MenuBarMetric.todayTokens.rawValue,
            MenuBarMetric.todayTokens.rawValue,
            "unknown",
            MenuBarMetric.averageRemainingQuota.rawValue,
            MenuBarMetric.todayCost.rawValue,
            MenuBarMetric.overallStatus.rawValue,
        ])
        try expect(
            config.metrics == [
                .todayTokens,
                .averageRemainingQuota,
                .todayCost,
            ],
            "menu bar metrics were not normalized"
        )
        try expect(
            MenuBarMetricConfiguration(rawValues: []).metrics
                == MenuBarMetricConfiguration.defaultMetrics,
            "empty menu bar metrics did not use defaults"
        )
    }

    private static func menuBarSummaryUsesValidQuotaWindows() throws {
        let artifact = agentUsageArtifact()
        let statuses: [DashboardModule: ModuleStatus] = [
            .agentUsage: ModuleStatus(state: .fresh, detail: nil),
        ]
        let summary = MenuBarSummaryBuilder().build(
            agentArtifact: artifact,
            moduleStatuses: statuses
        )
        try expect(
            summary.minimumRemainingQuota == 30,
            "minimum remaining quota is invalid"
        )
        try expect(
            summary.averageRemainingQuota == 50,
            "average remaining quota is invalid"
        )
        try expect(summary.todayTokens == 124_000, "today tokens are invalid")
        try expect(summary.todayCostUsd == 1.28, "today cost is invalid")
        try expect(
            summary.overallStatus == .fresh,
            "overall status priority is invalid"
        )
    }

    private static func metricFormatterUsesCompactValues() throws {
        let summary = MenuBarSummary(
            minimumRemainingQuota: 67.6,
            averageRemainingQuota: nil,
            todayTokens: 124_000,
            todayCostUsd: 1.28,
            overallStatus: .authRequired
        )
        let formatter = MenuBarMetricFormatter()
        try expect(
            formatter.string(
                for: .minimumRemainingQuota,
                summary: summary
            ) == "68%",
            "quota formatting is invalid"
        )
        try expect(
            formatter.string(for: .todayTokens, summary: summary) == "124k",
            "token formatting is invalid"
        )
        try expect(
            formatter.string(for: .todayCost, summary: summary) == "$1.28",
            "cost formatting is invalid"
        )
        try expect(
            formatter.string(
                for: .averageRemainingQuota,
                summary: summary
            ) == "--",
            "missing value formatting is invalid"
        )
        try expect(
            formatter.string(for: .overallStatus, summary: summary) == "需要授权",
            "status formatting is invalid"
        )
    }

    private static func agentUsageArtifact() -> JSONValue {
        let tokenBucket: JSONValue = .object([
            "input": .integer(100_000),
            "output": .integer(24_000),
            "cacheRead": .integer(0),
            "cacheCreation": .integer(0),
            "total": .integer(124_000),
        ])
        let agent: JSONValue = .object([
            "id": .string("fixture-agent"),
            "name": .string("Fixture Agent"),
            "status": .string("ok"),
            "today": tokenBucket,
            "daily": .array([]),
            "hours": .array(Array(repeating: .integer(0), count: 24)),
            "todayCostUsd": .double(1.28),
        ])
        let activeService: JSONValue = .object([
            "id": .string("active"),
            "name": .string("Active"),
            "status": .string("ok"),
            "windows": .array([
                .object(["usedPercent": .integer(30)]),
                .object(["usedPercent": .double(70)]),
                .object(["usedPercent": .integer(130)]),
            ]),
        ])
        let failedService: JSONValue = .object([
            "id": .string("failed"),
            "name": .string("Failed"),
            "status": .string("error"),
            "windows": .array([
                .object(["usedPercent": .integer(99)]),
            ]),
        ])
        return .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-07-30T00:00:00Z"),
            "agents": .array([agent]),
            "services": .array([activeService, failedService]),
            "totalCostUsd": .double(1.28),
        ])
    }
}
