import AppKit
import Foundation
import QuartzCore
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
        try menuBarImageRenderingSurvivesHighFrequencyRedraw()
        try dashboardPlacementFallsBackFromInvalidStatusItemCoordinates()
        try panelSizingKeepsTopAnchoredWithinScreen()
        try dashboardSettingsRouteOrdersCloseBeforeOpen()
        try swapHeightNeverClampsUnmeasuredContent()
        try stackShortcutMotionNeverAnimatesScroll()
        try cardHeaderHandleStaysInsideCardGutter()
        try decorativeDashboardMotionStaysRemoved()
        try welcomeOnboardingPresentationMatchesParityFixture()
        try launchAtLoginServiceMockAndStateTransitions()
        print("Native lifecycle tests passed: 22")
    }

    /// C187: 仪表盘/气泡跳转设置中心的顺序固定为 关闭面板 → 写入深链 → 打开设置，
    /// 且主面板可见时状态预警气泡静默跳过（设计 03 §14 互斥门控）。
    private static func dashboardSettingsRouteOrdersCloseBeforeOpen() throws {
        var order: [String] = []
        DashboardSettingsRoute.open(
            deepLink: { order.append("deepLink") },
            closeDashboard: { order.append("close") },
            openSettings: { order.append("open") }
        )
        try expect(
            order == ["close", "deepLink", "open"],
            "设置跳转必须 关闭面板→置深链→打开设置, got \(order)"
        )
        try expect(
            !StatusBubblePresentationPolicy.shouldPresent(dashboardOpen: true),
            "仪表盘打开时应静默跳过状态气泡"
        )
        try expect(
            StatusBubblePresentationPolicy.shouldPresent(dashboardOpen: false),
            "仪表盘关闭时应允许状态气泡"
        )
    }

    /// T25: 开机自启动 Mock 服务与状态转换断言
    private static func launchAtLoginServiceMockAndStateTransitions() throws {
        let mock = MockLaunchAtLoginService(status: .notRegistered)
        try expect(mock.status == .notRegistered, "initial status must be notRegistered")
        try expect(!mock.status.isEnabled, "notRegistered must not be enabled")
        try expect(!mock.status.needsApproval, "notRegistered must not need approval")

        // 注册测试
        try mock.register()
        try expect(mock.registerCallCount == 1, "registerCallCount must be 1")
        try expect(mock.status == .enabled, "status must be enabled after register")
        try expect(mock.status.isEnabled, "enabled status must return isEnabled == true")

        // 注销测试
        try mock.unregister()
        try expect(mock.unregisterCallCount == 1, "unregisterCallCount must be 1")
        try expect(mock.status == .notRegistered, "status must be notRegistered after unregister")

        // 拦截与需系统批准状态测试
        mock.setStatus(.requiresApproval)
        try expect(mock.status.needsApproval, "requiresApproval must return needsApproval == true")
        try expect(!mock.status.isEnabled, "requiresApproval must not be enabled")

        // 打开系统设置
        mock.openSystemSettings()
        try expect(mock.openSettingsCallCount == 1, "openSettingsCallCount must be 1")

        // 错误抛出测试
        mock.shouldThrowOnRegister = NSError(domain: "SMAppServiceErrorDomain", code: 1)
        do {
            try mock.register()
            throw TestFailure.expectation("mock.register should have thrown error")
        } catch where !(error is TestFailure) {
            // Expected error
        }
    }

    /// C148: 交换态容器的高度目标 —— 未测量时退回自然高度, 绝不用 0 裁死内容;
    /// 折叠是显式的 0, 与被测内容无关.
    private static func swapHeightNeverClampsUnmeasuredContent() throws {
        try expect(
            DashboardSwapHeight.target(measured: 0) == nil,
            "unmeasured content must fall back to natural height, never 0"
        )
        try expect(
            DashboardSwapHeight.target(measured: 0.4) == nil,
            "sub-pixel noise must not count as a measured height"
        )
        try expect(
            DashboardSwapHeight.target(measured: 212.4) == 212.4,
            "a measured natural height must be used verbatim as the container target"
        )
        try expect(
            DashboardSwapHeight.collapsed == 0,
            "the collapsed target is an explicit zero, not the unmeasured fallback"
        )
    }

    /// C232: 纵向布局快捷键固定为「无动画定位 + 单次高度动画」; 减弱动效时全部落值.
    /// 滚动与收放同时动画会让滚动目标随卡片高度逐帧移动, 与窗口高度互相追尾.
    private static func stackShortcutMotionNeverAnimatesScroll() throws {
        try expect(
            DashboardStackShortcutMotionPolicy.motion(motionSuppressed: false)
                == .instantScrollAnimatedToggle,
            "normal motion: locate instantly, then animate the toggle exactly once"
        )
        try expect(
            DashboardStackShortcutMotionPolicy.motion(motionSuppressed: true)
                == .instantScrollInstantToggle,
            "reduced motion: shortcut must animate neither scroll nor toggle"
        )
    }

    /// C147: 面板尺寸裁决 —— 顶边锚定、屏幕夹取、超高压缩、水平夹取.
    private static func panelSizingKeepsTopAnchoredWithinScreen() throws {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let content = CGSize(width: 440, height: 662)

        // 1. 正常尺寸: 顶部保持不动, 高度不变.
        let anchored = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: 1000,
            contentSize: content,
            currentX: 700,
            visibleFrame: visibleFrame
        )
        try expect(
            anchored.size == content && abs(anchored.maxY - 1000) < 0.01,
            "normal content must keep its size and top edge"
        )

        // 2. 内容高于屏幕可用高度: 压缩高度, 顶栏与底栏都留在屏内.
        let oversized = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: 1000,
            contentSize: CGSize(width: 440, height: 1600),
            currentX: 700,
            visibleFrame: visibleFrame
        )
        let availableHeight = visibleFrame.height - DashboardPanelSizingPolicy.edgeInset * 2
        try expect(
            abs(oversized.height - availableHeight) < 0.01,
            "oversized content must be clamped to the visible frame height"
        )
        try expect(
            oversized.maxY <= visibleFrame.maxY - DashboardPanelSizingPolicy.edgeInset + 0.01
                && oversized.minY >= visibleFrame.minY + DashboardPanelSizingPolicy.edgeInset - 0.01,
            "oversized panel must stay fully inside the visible frame"
        )

        // 3. 顶部越屏: 必须被拉回屏内 (Header 不允许被顶出窗口/屏幕).
        let aboveScreen = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: visibleFrame.maxY + 200,
            contentSize: content,
            currentX: 700,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(aboveScreen.maxY - (visibleFrame.maxY - DashboardPanelSizingPolicy.edgeInset)) < 0.01,
            "a panel top above the screen must be pulled back below the visible frame top"
        )

        // 4. 底部越屏 (顶边压得太低): 整体上移, 底栏不得掉出屏幕下沿.
        let belowScreen = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: 100,
            contentSize: content,
            currentX: 700,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(belowScreen.minY - (visibleFrame.minY + DashboardPanelSizingPolicy.edgeInset)) < 0.01,
            "a panel bottom below the screen must be lifted to the visible frame bottom"
        )

        // 5. 水平夹取: 面板不得越过屏幕左右内距.
        let leftOverflow = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: 1000,
            contentSize: content,
            currentX: -120,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(leftOverflow.minX - DashboardPanelSizingPolicy.edgeInset) < 0.01,
            "a panel left of the screen must be clamped to the left inset"
        )
        let rightOverflow = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: 1000,
            contentSize: content,
            currentX: 5000,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(
                rightOverflow.maxX
                    - (visibleFrame.maxX - DashboardPanelSizingPolicy.edgeInset)
            ) < 0.01,
            "a panel right of the screen must be clamped to the right inset"
        )

        // 6. 非正尺寸兜底: 宽高至少 1pt, 不允许出现零/负尺寸窗口.
        let degenerate = DashboardPanelSizingPolicy.resolvedContentSize(
            CGSize(width: -10, height: 0)
        )
        try expect(
            degenerate.width >= 1 && degenerate.height >= 1,
            "non-positive content sizes must resolve to at least one point"
        )
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

    /// C233: 拖拽手柄必须完整落在卡片左边距内 —— 手柄一旦宽过边距就得挤占标题行,
    /// 标题又会在每次收放时横移.
    private static func cardHeaderHandleStaysInsideCardGutter() throws {
        for isNothing in [false, true] {
            try expect(
                DashboardCardHeaderLayout.handleWidth(isNothing: isNothing) > 0,
                "drag handle must have a positive width (isNothing: \(isNothing))"
            )
            try expect(
                DashboardCardHeaderLayout.handleFitsGutter(isNothing: isNothing),
                "drag handle must fit inside the card gutter (isNothing: \(isNothing))"
            )
        }
    }

    /// C233: 已移除的装饰性动效不得回流到看板视图 (量条扫光 / 高光 / 入场生长、
    /// 数字滚动、柱体生长、Hero 呼吸、状态灯脉冲、标题行接力淡入).
    private static func decorativeDashboardMotionStaysRemoved() throws {
        let appSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NativeLifecycleHarness.swift -> NativeLifecycleHarness/
            .deletingLastPathComponent() // -> Harnesses/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> macos/
            .appendingPathComponent("Sources/BruceApp")
        let viewsDirectory = appSources.appendingPathComponent("Views")
        var files = try FileManager.default
            .contentsOfDirectory(at: viewsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "QuotaAlertBubbleView.swift" }
        files.append(appSources.appendingPathComponent("MenuBarViews.swift"))
        try expect(files.count > 4, "dashboard view sources must be found: \(files.count)")

        let banned = [
            "MeterMotionPolicy",
            "contentTransition(.numericText",
            "sheenPhase",
            "animateEntrance",
            "grownColumns",
            "heroBreathing",
            "PulsingStatusDot",
            "miniSwapAnimation",
            "statusSwapAnimation",
        ]
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in banned {
                try expect(
                    !source.contains(token),
                    "\(file.lastPathComponent) reintroduces removed decorative motion: \(token)"
                )
            }
        }
        // 看板里唯一允许的循环动画是底栏刷新图标.
        let loops = try files.reduce(into: [String: Int]()) { counts, file in
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = source.components(separatedBy: ".repeatForever(").count - 1
            if count > 0 { counts[file.lastPathComponent] = count }
        }
        try expect(
            loops == ["MenuBarViews.swift": 1],
            "only the footer refresh spinner may loop: \(loops)"
        )
    }

    private static func hiddenPanelDisablesAllDecorativeAnimations() throws {
        // C044 / TD-012: 定向刷新进度指示 / 滚动条压制 (Hero 呼吸与小时卡生长已随 C233 移除)
        try expect(
            !DashboardPanelAnimationPolicy.allowsRefreshProgress(panelVisible: false),
            "a hidden panel must not mount the provider refresh ProgressView"
        )
        try expect(
            DashboardPanelAnimationPolicy.allowsRefreshProgress(panelVisible: true),
            "a visible panel may mount the provider refresh ProgressView"
        )
        try expect(
            !DashboardPanelAnimationPolicy.allowsScrollIndicatorSuppression(
                panelVisible: false
            ),
            "a hidden panel must not rewrite the scroll view scroller"
        )
        try expect(
            DashboardPanelAnimationPolicy.allowsScrollIndicatorSuppression(
                panelVisible: true
            ),
            "a visible panel may suppress the scroll view scroller"
        )
        try expect(
            DashboardPanelAnimationPolicy.allowsCurtainTransition(motionSuppressed: false),
            "curtain transition must be allowed when motion is not suppressed"
        )
        try expect(
            !DashboardPanelAnimationPolicy.allowsCurtainTransition(motionSuppressed: true),
            "curtain transition must be suppressed when motion is suppressed"
        )
        // C145: MotionPreference 三态 × 系统值共 6 组, 唯一裁决点语义.
        let motionMatrix: [(MotionPreference, Bool, Bool)] = [
            (.system, false, false),
            (.system, true, true),
            (.always, false, false),
            (.always, true, false),
            (.never, false, true),
            (.never, true, true),
        ]
        for (preference, systemReduceMotion, expected) in motionMatrix {
            try expect(
                preference.suppressesMotion(systemReduceMotion: systemReduceMotion) == expected,
                "MotionPreference.\(preference.rawValue) with system=\(systemReduceMotion) must suppress=\(expected)"
            )
        }
        try expect(
            DashboardPanelAnimationPolicy.curtainOpenDuration == 0.24,
            "curtain open duration must be 0.24s"
        )
        try expect(
            DashboardPanelAnimationPolicy.curtainCloseDuration == 0.14,
            "curtain close duration must be 0.14s"
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
        try expect(graceAction != nil, "有运行任务时退出应先安排宽限期回调")
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
        try expect(
            abs((content.outerQuotaRatio ?? 0) - 0.50) < 0.001
                && abs((content.innerQuotaRatio ?? 0) - 0.676) < 0.001,
            "dual concentric quota ratios must map average and minimum quotas respectively"
        )
        // C183: 整体订阅单轨星规映射与三档色阶动力学校验
        try expect(
            abs((content.subscriptionQuotaRatio ?? 0) - 0.50) < 0.001,
            "subscription quota ratio must map average quota for single orbit gauge"
        )
        try expect(
            MenuBarQuotaTier.tier(for: 0.51) == .healthy,
            ">50% quota must be healthy tier (emerald green)"
        )
        try expect(
            MenuBarQuotaTier.tier(for: 0.50) == .warning,
            "50% quota must be warning tier (amber)"
        )
        try expect(
            MenuBarQuotaTier.tier(for: 0.20) == .warning,
            "20% quota must be warning tier (amber)"
        )
        try expect(
            MenuBarQuotaTier.tier(for: 0.19) == .critical,
            "<20% quota must be critical tier (red)"
        )

        // C180: Nothing 极客点阵主题自动切 T-4 极客等宽与斜杠弱化分隔符
        let nothingContent = MenuBarStatusItemContentBuilder().build(
            metrics: [.minimumRemainingQuota, .todayTokens, .todayCost],
            summary: summary,
            isRefreshing: false,
            isNothingTheme: true
        )
        try expect(
            nothingContent.metricText == "68% / 124K / $1.28",
            "nothing theme must format metrics with uppercase units and slash separators"
        )
        try expect(
            nothingContent.isNothingTheme == true,
            "nothing theme content must flag isNothingTheme"
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

    /// C203: 菜单栏图标高频重绘压力回归 —— drawingHandler 闭包内只绘制不测量.
    ///
    /// 背景: `attrString.size()` 走 NSStringDrawingEngine 的 CoreText 排版测量路径,
    /// 在 NSImage drawingHandler 的离屏上下文中偶发属性字典插 nil (SIGABRT, 每天多次自退).
    /// 本用例按修复后的模式 (缓存字体 + 闭包内仅 `draw(in:)`, 排版高度经字体度量推导)
    /// 高频光栅化双主题指标文本, 断言全程稳定出图.
    private static func menuBarImageRenderingSurvivesHighFrequencyRedraw() throws {
        let classicFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let nothingFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        let classicTexts = ["124k  $1.28", "1.2M  $12.4", "--  $--"]
        let nothingTexts = ["68% / 124K / $1.28", "9% / 2.4M / $240", "-- / -- / --"]

        for iteration in 0..<2_000 {
            let isNothingTheme = iteration.isMultiple(of: 2)
            let font = isNothingTheme ? nothingFont : classicFont
            let texts = isNothingTheme ? nothingTexts : classicTexts
            let text = texts[iteration % texts.count]
            let canvas = NSSize(width: 96, height: 22)

            let image = NSImage(size: canvas, flipped: false) { _ in
                let attrString = NSMutableAttributedString(
                    string: text,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.white,
                    ]
                )
                let baselineY = round((canvas.height - font.capHeight) / 2.0 + font.descender)
                let textRect = NSRect(
                    x: 25,
                    y: max(0, baselineY),
                    width: max(0, canvas.width - 25),
                    height: ceil(font.ascender + abs(font.descender))
                )
                attrString.draw(in: textRect)
                return true
            }

            guard let rasterized = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw TestFailure.expectation(
                    "menu bar image rasterization returned nil at iteration \(iteration)"
                )
            }
            try expect(
                rasterized.width > 0 && rasterized.height > 0,
                "menu bar image rasterization must produce a non-empty bitmap at iteration \(iteration)"
            )
        }
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

    // MARK: - T22 欢迎向导双端对拍

    private struct WelcomeParityFixture: Decodable {
        struct PresentCase: Decodable {
            let name: String
            let welcomeCompletedVersion: Int?
            let consentConfirmed: Bool
            let keychainAccessConfigured: Bool
            let expected: Bool
        }
        struct ReadyCase: Decodable {
            let readyCount: Int
            let expected: String
        }
        struct MetricsCase: Decodable {
            let isNothingTheme: Bool
            let iconOnly: Bool
            let expected: String
        }
        let copy: [String: String]
        let shouldPresentWelcomeCases: [PresentCase]
        let readySourcesSummaryCases: [ReadyCase]
        let menuBarPreviewMetricsCases: [MetricsCase]
    }

    private static func welcomeOnboardingPresentationMatchesParityFixture() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // NativeLifecycleHarness.swift -> NativeLifecycleHarness/
            .deletingLastPathComponent() // -> Harnesses/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> macos/
            .deletingLastPathComponent() // -> apps/
            .deletingLastPathComponent() // -> repoRoot
        let fixtureURL = repoRoot.appendingPathComponent("tests/fixtures/welcome-onboarding-parity/cases.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(WelcomeParityFixture.self, from: data)

        try expect(fixture.copy["windowTitle"] == WelcomeCopy.windowTitle, "windowTitle mismatch")
        try expect(fixture.copy["privacyTitle"] == WelcomeCopy.privacyTitle, "privacyTitle mismatch")
        try expect(fixture.copy["step1NavTitle"] == WelcomeCopy.step1NavTitle, "step1NavTitle mismatch")
        try expect(fixture.copy["step2NavTitle"] == WelcomeCopy.step2NavTitle, "step2NavTitle mismatch")
        try expect(fixture.copy["step3NavTitle"] == WelcomeCopy.step3NavTitle, "step3NavTitle mismatch")
        try expect(fixture.copy["step1PrimaryButton"] == WelcomeCopy.step1PrimaryButton, "step1PrimaryButton mismatch")
        try expect(fixture.copy["step3FinishButton"] == WelcomeCopy.step3FinishButton, "step3FinishButton mismatch")
        try expect(fixture.copy["settingsRowTitle"] == WelcomeCopy.settingsRowTitle, "settingsRowTitle mismatch")
        try expect(fixture.copy["settingsRowSubtitle"] == WelcomeCopy.settingsRowSubtitle, "settingsRowSubtitle mismatch")
        try expect(fixture.copy["settingsReopenButton"] == WelcomeCopy.settingsReopenButton, "settingsReopenButton mismatch")

        for item in fixture.shouldPresentWelcomeCases {
            let actual = WelcomeOnboardingPresentation.shouldPresentWelcome(
                welcomeCompletedVersion: item.welcomeCompletedVersion,
                consentConfirmed: item.consentConfirmed,
                keychainAccessConfigured: item.keychainAccessConfigured
            )
            try expect(actual == item.expected, "shouldPresentWelcome mismatch for \(item.name)")

            var config = OnboardingConfiguration()
            config.welcomeCompletedVersion = item.welcomeCompletedVersion
            config.consentVersion = item.consentConfirmed ? 1 : nil
            config.keychainAccessConfigured = item.keychainAccessConfigured
            try expect(
                config.shouldPresentWelcomeOnStartup() == item.expected,
                "OnboardingConfiguration.shouldPresentWelcomeOnStartup mismatch for \(item.name)"
            )
        }

        for item in fixture.readySourcesSummaryCases {
            try expect(
                WelcomeOnboardingPresentation.readySourcesSummary(readyCount: item.readyCount) == item.expected,
                "readySourcesSummary mismatch for \(item.readyCount)"
            )
        }

        for item in fixture.menuBarPreviewMetricsCases {
            try expect(
                WelcomeOnboardingPresentation.menuBarPreviewMetricsText(
                    isNothingTheme: item.isNothingTheme,
                    iconOnly: item.iconOnly
                ) == item.expected,
                "menuBarPreviewMetricsText mismatch"
            )
        }
    }
}
