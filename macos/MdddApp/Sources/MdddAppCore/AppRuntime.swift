import Foundation

@MainActor
package protocol ApplicationRuntimeControlling: AnyObject {
    var hasRunningTasks: Bool { get }
    func startSchedulerIfNeeded()
    func stopScheduling()
    func cancelRunningTasks()
    func forceTerminateRunningTasks()
}

@MainActor
package final class AppRuntime: ObservableObject, ApplicationRuntimeControlling {
    package private(set) var schedulerStartCount = 0
    package private(set) var acceptsNewTasks = true
    private var schedulerStarted = false
    private var runningTaskCancellations: [UUID: () -> Void] = [:]
    private var forceTerminationHandlers: [UUID: () -> Void] = [:]
    private var scheduler: RefreshScheduler?
    private var runner: CollectorRunner?

    package var hasRunningTasks: Bool {
        !runningTaskCancellations.isEmpty
            || (runner?.activeModuleCount ?? 0) > 0
    }

    package init() {}

    package func configure(scheduler: RefreshScheduler, runner: CollectorRunner) {
        self.scheduler = scheduler
        self.runner = runner
    }

    package func startSchedulerIfNeeded() {
        guard !schedulerStarted else { return }
        schedulerStarted = true
        schedulerStartCount += 1
        scheduler?.start()
    }

    package func registerRunningTask(
        cancel: @escaping () -> Void,
        forceTerminate: @escaping () -> Void
    ) -> UUID? {
        guard acceptsNewTasks else { return nil }
        let id = UUID()
        runningTaskCancellations[id] = cancel
        forceTerminationHandlers[id] = forceTerminate
        return id
    }

    package func finishRunningTask(_ id: UUID) {
        runningTaskCancellations[id] = nil
        forceTerminationHandlers[id] = nil
    }

    package func stopScheduling() {
        acceptsNewTasks = false
        scheduler?.stop()
    }

    package func cancelRunningTasks() {
        scheduler?.stop()
        runningTaskCancellations.values.forEach { $0() }
    }

    package func forceTerminateRunningTasks() {
        runner?.forceTerminateAll()
        forceTerminationHandlers.values.forEach { $0() }
        runningTaskCancellations.removeAll()
        forceTerminationHandlers.removeAll()
    }
}
