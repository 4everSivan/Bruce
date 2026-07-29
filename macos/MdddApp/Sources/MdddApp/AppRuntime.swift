import Foundation

@MainActor
protocol ApplicationRuntimeControlling: AnyObject {
    var hasRunningTasks: Bool { get }
    func startSchedulerIfNeeded()
    func stopScheduling()
    func cancelRunningTasks()
    func forceTerminateRunningTasks()
}

@MainActor
final class AppRuntime: ObservableObject, ApplicationRuntimeControlling {
    private(set) var schedulerStartCount = 0
    private(set) var acceptsNewTasks = true
    private var schedulerStarted = false
    private var runningTaskCancellations: [UUID: () -> Void] = [:]
    private var forceTerminationHandlers: [UUID: () -> Void] = [:]
    private var scheduler: RefreshScheduler?
    private var runner: CollectorRunner?

    var hasRunningTasks: Bool {
        !runningTaskCancellations.isEmpty
            || (runner?.activeModuleCount ?? 0) > 0
    }

    func configure(scheduler: RefreshScheduler, runner: CollectorRunner) {
        self.scheduler = scheduler
        self.runner = runner
    }

    func startSchedulerIfNeeded() {
        guard !schedulerStarted else { return }
        schedulerStarted = true
        schedulerStartCount += 1
        scheduler?.start()
    }

    func registerRunningTask(
        cancel: @escaping () -> Void,
        forceTerminate: @escaping () -> Void
    ) -> UUID? {
        guard acceptsNewTasks else { return nil }
        let id = UUID()
        runningTaskCancellations[id] = cancel
        forceTerminationHandlers[id] = forceTerminate
        return id
    }

    func finishRunningTask(_ id: UUID) {
        runningTaskCancellations[id] = nil
        forceTerminationHandlers[id] = nil
    }

    func stopScheduling() {
        acceptsNewTasks = false
        scheduler?.stop()
    }

    func cancelRunningTasks() {
        scheduler?.stop()
        runningTaskCancellations.values.forEach { $0() }
    }

    func forceTerminateRunningTasks() {
        runner?.forceTerminateAll()
        forceTerminationHandlers.values.forEach { $0() }
        runningTaskCancellations.removeAll()
        forceTerminationHandlers.removeAll()
    }
}
