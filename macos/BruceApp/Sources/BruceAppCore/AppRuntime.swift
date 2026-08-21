import Foundation

@MainActor
package protocol ApplicationRuntimeControlling: AnyObject {
    var hasRunningTasks: Bool { get }
    func startSchedulerIfNeeded()
    func resumeScheduling()
    func stopScheduling()
    func cancelRunningTasks()
    func forceTerminateRunningTasks()
}

@MainActor
package final class AppRuntime: ObservableObject, ApplicationRuntimeControlling {
    package private(set) var schedulerStartCount = 0
    package private(set) var acceptsNewTasks = true
    private var schedulerStarted = false
    private var scheduler: RefreshScheduler?
    private var runner: (any CollectorRuntimeControlling)?

    package var hasRunningTasks: Bool {
        (runner?.activeModuleCount ?? 0) > 0
    }

    package init() {}

    package func configure(scheduler: RefreshScheduler, runner: any CollectorRuntimeControlling) {
        self.scheduler = scheduler
        self.runner = runner
    }

    package func startSchedulerIfNeeded() {
        guard !schedulerStarted else { return }
        schedulerStarted = true
        schedulerStartCount += 1
        scheduler?.start()
    }

    /// 取消退出后恢复调度: 重置 acceptsNewTasks 并重启 Scheduler.
    /// 与 stopScheduling 对称; 仅在已停止后调用才生效.
    package func resumeScheduling() {
        acceptsNewTasks = true
        scheduler?.start()
    }

    package func stopScheduling() {
        acceptsNewTasks = false
        scheduler?.stop()
    }

    package func cancelRunningTasks() {
        scheduler?.stop()
    }

    package func forceTerminateRunningTasks() {
        runner?.forceTerminateAll()
    }
}
