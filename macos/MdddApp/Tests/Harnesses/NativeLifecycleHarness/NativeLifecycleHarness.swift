import Foundation
@testable import MdddApp

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
private final class WindowPresenter: MainWindowPresenting {
    private(set) var windowCount = 1
    private(set) var presentationCount = 0
    private(set) var isVisible = true

    func close() {
        isVisible = false
    }

    func presentMainWindow() {
        presentationCount += 1
        isVisible = true
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
}

@main
@MainActor
struct NativeLifecycleHarness {
    static func main() throws {
        try closeReopenKeepsOneWindowAndScheduler()
        try exitForcesRemainingTasksAfterGracePeriod()
        try exitCompletesImmediatelyWithoutRunningTasks()
        try dockBadgeNeverContainsIdentifiers()
        print("Native lifecycle tests passed: 4")
    }

    private static func closeReopenKeepsOneWindowAndScheduler() throws {
        let runtime = Runtime()
        let presenter = WindowPresenter()
        let coordinator = ApplicationLifecycleCoordinator(
            runtime: runtime,
            windowPresenter: presenter
        )
        runtime.startSchedulerIfNeeded()
        runtime.startSchedulerIfNeeded()

        presenter.close()
        coordinator.reopenMainWindow()
        coordinator.reopenMainWindow()

        try expect(presenter.isVisible, "reopen should show the main window")
        try expect(presenter.windowCount == 1, "reopen created another window")
        try expect(
            presenter.presentationCount == 2,
            "repeated activation was not handled"
        )
        try expect(
            runtime.schedulerStartCount == 1,
            "reopen created another scheduler"
        )
    }

    private static func exitForcesRemainingTasksAfterGracePeriod() throws {
        let runtime = Runtime()
        runtime.hasRunningTasks = true
        var graceAction: (@MainActor () -> Void)?
        var completionCount = 0
        let coordinator = ApplicationLifecycleCoordinator(
            runtime: runtime,
            windowPresenter: WindowPresenter(),
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
            runtime: runtime,
            windowPresenter: WindowPresenter()
        )
        coordinator.beginTermination {
            completed = true
        }
        try expect(completed, "idle exit should complete immediately")
        try expect(runtime.forceCount == 0, "idle exit forced a task")
    }

    private static func dockBadgeNeverContainsIdentifiers() throws {
        let model = AppModel()
        model.setStatus(
            ModuleStatus(
                state: .authRequired,
                detail: "fixture@example.test"
            ),
            for: .github
        )
        try expect(model.dockBadgeState.label == "•", "attention badge changed")
        model.setStatus(
            ModuleStatus(
                state: .failed,
                detail: "private/repository"
            ),
            for: .gitlab
        )
        try expect(model.dockBadgeState.label == "!", "failure badge changed")
    }
}
