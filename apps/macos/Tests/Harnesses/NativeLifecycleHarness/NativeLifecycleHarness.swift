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
        try closeTransitionPublishesHiddenWhenWindowAlreadyHidden()
        try occludedPanelIsNotPublishedAsVisible()
        try statusItemToggleAlternatesOpenAndClosed()
        try statusItemResignDoesNotBreakToggle()
        try hiddenPanelDisablesAllDecorativeAnimations()
        try metricSelectionNormalizes()
        try menuBarSummaryUsesValidQuotaWindows()
        try metricFormatterUsesCompactValues()
        try menuBarContentUsesStableIconAndMetrics()
        try menuBarContentUsesRefreshAndFailureIcons()
        try dashboardPlacementFallsBackFromInvalidStatusItemCoordinates()
        print("Native lifecycle tests passed: 14")
    }

    private static func closeTransitionPublishesHiddenWhenWindowAlreadyHidden() throws {
        let alreadyHidden = DashboardPanelVisibilityTransition.close(panelIsVisible: false)
        try expect(
            alreadyHidden.visible == false,
            "closing an already-hidden panel must publish hidden state"
        )
        try expect(
            alreadyHidden.shouldOrderOut == false,
            "closing an already-hidden panel must not order it out again"
        )

        let visible = DashboardPanelVisibilityTransition.close(panelIsVisible: true)
        try expect(
            visible.visible == false,
            "closing a visible panel must publish hidden state"
        )
        try expect(
            visible.shouldOrderOut,
            "closing a visible panel must order it out"
        )
    }

    private static func occludedPanelIsNotPublishedAsVisible() throws {
        try expect(
            !DashboardPanelVisibilityTransition.isActuallyVisible(
                panelIsVisible: true,
                occlusionStateIsVisible: false
            ),
            "an occluded panel must publish hidden state"
        )
        try expect(
            DashboardPanelVisibilityTransition.isActuallyVisible(
                panelIsVisible: true,
                occlusionStateIsVisible: true
            ),
            "an onscreen panel must publish visible state"
        )
        try expect(
            !DashboardPanelVisibilityTransition.isActuallyVisible(
                panelIsVisible: false,
                occlusionStateIsVisible: true
            ),
            "an ordered-out panel must publish hidden state"
        )
    }

    private static func statusItemResignDoesNotBreakToggle() throws {
        try expect(
            !DashboardPanelDismissalPolicy.shouldDismissOnApplicationResign(
                panelIsVisible: false,
                pointerIsInsideStatusItem: true,
                statusItemActionInProgress: false
            ),
            "first status item click must not dismiss a hidden panel"
        )
        try expect(
            !DashboardPanelDismissalPolicy.shouldDismissOnApplicationResign(
                panelIsVisible: true,
                pointerIsInsideStatusItem: true,
                statusItemActionInProgress: false
            ),
            "second status item click must reach toggle instead of resign dismissal"
        )
        try expect(
            !DashboardPanelDismissalPolicy.shouldDismissOnApplicationResign(
                panelIsVisible: true,
                pointerIsInsideStatusItem: false,
                statusItemActionInProgress: true
            ),
            "status item action must win over resign notification"
        )
        try expect(
            DashboardPanelDismissalPolicy.shouldDismissOnApplicationResign(
                panelIsVisible: true,
                pointerIsInsideStatusItem: false,
                statusItemActionInProgress: false
            ),
            "clicking another application must dismiss the panel"
        )
    }

    private static func statusItemToggleAlternatesOpenAndClosed() throws {
        let closed = DashboardPanelToggleState.closed
        let opened = closed.toggled
        try expect(
            opened == .open,
            "the first status item toggle must open the dashboard"
        )
        try expect(
            opened.toggled == .closed,
            "the second status item toggle must close the dashboard"
        )
        try expect(
            opened.toggled.toggled == .open,
            "the third status item toggle must open the dashboard again"
        )
    }

    private static func hiddenPanelDisablesAllDecorativeAnimations() throws {
        try expect(
            !DashboardPanelAnimationPolicy.allowsHero(panelVisible: false, reduceMotion: false),
            "a hidden panel must not mount hero animation"
        )
        try expect(
            !DashboardPanelAnimationPolicy.allowsHeatmap(
                panelVisible: false,
                isNothing: true,
                filled: true,
                reduceMotion: false
            ),
            "a hidden panel must not mount heatmap animation"
        )
        try expect(
            DashboardPanelAnimationPolicy.allowsHero(panelVisible: true, reduceMotion: false),
            "a visible panel may mount hero animation"
        )
        try expect(
            DashboardPanelAnimationPolicy.allowsHeatmap(
                panelVisible: true,
                isNothing: true,
                filled: true,
                reduceMotion: false
            ),
            "a visible Nothing panel may mount filled-cell animation"
        )
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

    private static func menuBarContentUsesStableIconAndMetrics() throws {
        let summary = MenuBarSummary(
            minimumRemainingQuota: 67.6,
            averageRemainingQuota: 50,
            todayTokens: 124_000,
            todayCostUsd: 1.28,
            overallStatus: .fresh
        )
        let content = MenuBarStatusItemContentBuilder().build(
            metrics: [.todayTokens, .todayCost],
            summary: summary,
            isRefreshing: false
        )

        try expect(
            content.iconName == "gauge",
            "normal menu bar content must use a native gauge icon"
        )
        try expect(
            content.metricText == "124k  $1.28",
            "menu bar content must preserve compact metric formatting"
        )
        try expect(
            content.accessibilityLabel.contains("今日 Token 124k")
                && content.accessibilityLabel.contains("今日费用 $1.28"),
            "menu bar accessibility content must describe visible metrics"
        )
    }

    private static func menuBarContentUsesRefreshAndFailureIcons() throws {
        let refreshing = MenuBarSummary(
            minimumRemainingQuota: nil,
            averageRemainingQuota: nil,
            todayTokens: nil,
            todayCostUsd: nil,
            overallStatus: .fresh
        )
        let refreshingContent = MenuBarStatusItemContentBuilder().build(
            metrics: [],
            summary: refreshing,
            isRefreshing: true
        )
        try expect(
            refreshingContent.iconName == "arrow.clockwise",
            "refreshing menu bar content must use the refresh icon"
        )

        let authRequired = MenuBarSummary(
            minimumRemainingQuota: nil,
            averageRemainingQuota: nil,
            todayTokens: nil,
            todayCostUsd: nil,
            overallStatus: .authRequired
        )
        let authContent = MenuBarStatusItemContentBuilder().build(
            metrics: [.overallStatus],
            summary: authRequired,
            isRefreshing: false
        )
        try expect(
            authContent.iconName == "exclamationmark.triangle",
            "authorization-required menu bar content must use the warning icon"
        )

        let failed = MenuBarSummary(
            minimumRemainingQuota: nil,
            averageRemainingQuota: nil,
            todayTokens: nil,
            todayCostUsd: nil,
            overallStatus: .failed
        )
        let failedContent = MenuBarStatusItemContentBuilder().build(
            metrics: [.overallStatus],
            summary: failed,
            isRefreshing: false
        )
        try expect(
            failedContent.iconName == "xmark.circle",
            "failed menu bar content must use the failure icon"
        )
    }

    private static func dashboardPlacementFallsBackFromInvalidStatusItemCoordinates() throws {
        let visibleFrame = CGRect(x: 65, y: 0, width: 1855, height: 1050)
        let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let invalidMacOS27Anchor = CGRect(x: 8, y: -14, width: 22.5, height: 29)
        let fallback = DashboardPanelPlacementResolver.resolve(
            anchorRect: invalidMacOS27Anchor,
            panelSize: CGSize(width: 440, height: 880),
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
        try expect(
            fallback.usedFallbackAnchor,
            "invalid status item coordinates must use a fallback anchor"
        )
        try expect(
            fallback.origin == CGPoint(x: 1472, y: 162),
            "fallback dashboard placement is not inside the visible frame"
        )

        let validAnchor = CGRect(x: 1450, y: 1050, width: 22.5, height: 29)
        let anchored = DashboardPanelPlacementResolver.resolve(
            anchorRect: validAnchor,
            panelSize: CGSize(width: 440, height: 880),
            visibleFrame: visibleFrame,
            screenFrame: screenFrame
        )
        try expect(
            !anchored.usedFallbackAnchor,
            "valid status item coordinates must remain the panel anchor"
        )
        try expect(
            anchored.origin == CGPoint(x: 1241.25, y: 162),
            "valid dashboard placement changed unexpectedly"
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
