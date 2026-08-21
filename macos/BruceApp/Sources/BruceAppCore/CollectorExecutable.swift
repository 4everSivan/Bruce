import Foundation
import BruceOnboardingCore

/// Runtime seam for the Collector process. Release uses the Rust executable;
/// Python is intentionally exposed only through the Preview adapter.
@MainActor
package protocol CollectorExecutable: AnyObject {
    func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput

    func cancel(module: CollectorModule)
    func cancelAll()
}

@MainActor
package protocol CollectorRuntimeControlling: AnyObject {
    var activeModuleCount: Int { get }
    func forceTerminateAll()
}

package typealias CollectorExecuting = CollectorExecutable

extension CollectorRunner: CollectorExecutable {}
extension CollectorRunner: CollectorRuntimeControlling {}

@MainActor
package final class RustBinaryAdapter: CollectorExecutable, CollectorRuntimeControlling {
    private let runner: CollectorRunner

    package var activeModuleCount: Int {
        runner.activeModuleCount
    }

    package init(executableURL: URL) {
        runner = CollectorRunner(rustURL: executableURL)
    }

    package func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        try await runner.run(
            module: module,
            context: context,
            credentials: credentials
        )
    }

    package func cancel(module: CollectorModule) {
        runner.cancel(module: module)
    }

    package func cancelAll() {
        runner.cancelAll()
    }

    package func forceTerminateAll() {
        runner.forceTerminateAll()
    }
}

#if DEBUG
@MainActor
package final class PythonPreviewAdapter: CollectorExecutable, CollectorRuntimeControlling {
    private let runner: CollectorRunner

    package var activeModuleCount: Int {
        runner.activeModuleCount
    }

    package init(pythonURL: URL, bridgeURL: URL) {
        runner = CollectorRunner(pythonURL: pythonURL, bridgeURL: bridgeURL)
    }

    package func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        try await runner.run(
            module: module,
            context: context,
            credentials: credentials
        )
    }

    package func cancel(module: CollectorModule) {
        runner.cancel(module: module)
    }

    package func cancelAll() {
        runner.cancelAll()
    }

    package func forceTerminateAll() {
        runner.forceTerminateAll()
    }
}
#endif

@MainActor
package final class UnavailableCollectorAdapter: CollectorExecutable, CollectorRuntimeControlling {
    package var activeModuleCount: Int { 0 }

    package init() {}

    package func run(
        module: CollectorModule,
        context: [String: JSONValue],
        credentials: [String: JSONValue]
    ) async throws -> CollectorRunOutput {
        throw CollectorRunnerError.rustNotExecutable
    }

    package func cancel(module: CollectorModule) {}

    package func cancelAll() {}

    package func forceTerminateAll() {}
}
