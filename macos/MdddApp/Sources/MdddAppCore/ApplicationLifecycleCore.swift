import Foundation

@MainActor
package final class ApplicationLifecycleCoordinator {
    package typealias GracePeriodScheduler = (
        @escaping @MainActor () -> Void
    ) -> Void

    private let runtime: ApplicationRuntimeControlling
    private let scheduleGracePeriod: GracePeriodScheduler
    private var terminationStarted = false

    package init(
        runtime: ApplicationRuntimeControlling,
        scheduleGracePeriod: @escaping GracePeriodScheduler = { action in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    action()
                }
            }
        }
    ) {
        self.runtime = runtime
        self.scheduleGracePeriod = scheduleGracePeriod
    }

    package func beginTermination(
        completion: @escaping @MainActor () -> Void
    ) {
        guard !terminationStarted else { return }
        terminationStarted = true
        runtime.stopScheduling()
        runtime.cancelRunningTasks()
        guard runtime.hasRunningTasks else {
            completion()
            return
        }
        scheduleGracePeriod { [runtime] in
            if runtime.hasRunningTasks {
                runtime.forceTerminateRunningTasks()
            }
            completion()
        }
    }
}
