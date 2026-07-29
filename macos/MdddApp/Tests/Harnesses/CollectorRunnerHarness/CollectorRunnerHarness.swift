import Foundation
@testable import MdddApp

private enum RunnerTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func runnerExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw RunnerTestFailure.expectation(message)
    }
}

@MainActor
private final class FakeProcessHandle: CollectorProcessHandling {
    private(set) var cancellationCount = 0
    private(set) var forceCount = 0

    func requestCancellation() {
        cancellationCount += 1
    }

    func forceTerminate() {
        forceCount += 1
    }
}

@MainActor
private final class FakeProcessLauncher: CollectorProcessLaunching {
    struct Launch {
        let executableURL: URL
        let arguments: [String]
        let input: Data
        let handle: FakeProcessHandle
        let completion: @MainActor (
            Result<CollectorProcessOutput, Error>
        ) -> Void
    }

    private(set) var launches: [Launch] = []

    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (
            Result<CollectorProcessOutput, Error>
        ) -> Void
    ) throws -> CollectorProcessHandling {
        let handle = FakeProcessHandle()
        launches.append(
            Launch(
                executableURL: executableURL,
                arguments: arguments,
                input: input,
                handle: handle,
                completion: completion
            )
        )
        return handle
    }

    func succeed(
        _ index: Int,
        runId: String? = nil,
        stderr: Data = Data()
    ) throws {
        let launch = launches[index]
        let resolvedRunId = try runId ?? requestRunId(index)
        let response = BridgeResponse(
            schemaVersion: 1,
            runId: resolvedRunId,
            generatedAt: "2026-07-28T12:00:00Z",
            status: .success,
            artifact: .object(["fixture": .boolean(true)]),
            credentialUpdates: [],
            diagnostics: []
        )
        launch.completion(
            .success(
                CollectorProcessOutput(
                    stdout: try JSONEncoder().encode(response),
                    stderr: stderr,
                    exitCode: 0
                )
            )
        )
    }

    func complete(
        _ index: Int,
        stdout: Data = Data(),
        stderr: Data = Data(),
        exitCode: Int32
    ) {
        launches[index].completion(
            .success(
                CollectorProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode
                )
            )
        )
    }

    func requestObject(_ index: Int) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(
            with: launches[index].input
        ) as? [String: Any] else {
            throw RunnerTestFailure.expectation("request is not an object")
        }
        return object
    }

    func requestRunId(_ index: Int) throws -> String {
        guard let runId = try requestObject(index)["runId"] as? String else {
            throw RunnerTestFailure.expectation("request has no runId")
        }
        return runId
    }
}

@MainActor
private final class FakeTimerToken: RunnerTimerToken {
    var isCancelled = false
    let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        guard !isCancelled else { return }
        action()
    }
}

@MainActor
private final class FakeTimerScheduler: RunnerTimerScheduling {
    private(set) var delays: [Double] = []
    private(set) var tokens: [FakeTimerToken] = []

    func schedule(
        after seconds: Double,
        action: @escaping @MainActor () -> Void
    ) -> RunnerTimerToken {
        let token = FakeTimerToken(action: action)
        delays.append(seconds)
        tokens.append(token)
        return token
    }
}

private struct RunnerFixture {
    let root: URL
    let python: URL
    let bridge: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mddd-runner-\(UUID().uuidString)",
            isDirectory: true
        )
        python = root.appendingPathComponent("python3")
        bridge = root.appendingPathComponent("run_bridge.py")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try Data("# bridge fixture\n".utf8).write(to: bridge)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: python.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@main
@MainActor
struct CollectorRunnerHarness {
    static func main() async throws {
        try await requestUsesAbsolutePathsAndPrivateStdin()
        try await enforcesModuleAndGlobalConcurrency()
        try await handlesTimeoutCancellationAndCrash()
        try await rejectsMismatchedAndPollutedResponses()
        try await runsTheRealBridgeInAnIsolatedHome()
        print("CollectorRunner tests passed: 5")
    }

    private static func waitForLaunches(
        _ launcher: FakeProcessLauncher,
        count: Int
    ) async {
        while launcher.launches.count < count {
            await Task.yield()
        }
    }

    private static func requestUsesAbsolutePathsAndPrivateStdin() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let launcher = FakeProcessLauncher()
        let timers = FakeTimerScheduler()
        let runner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: launcher,
            timerScheduler: timers
        )
        let task = Task {
            try await runner.run(
                module: .gitlab,
                credentials: [
                    "gitlabToken": .string("fixture-secret")
                ]
            )
        }
        await waitForLaunches(launcher, count: 1)

        let launch = launcher.launches[0]
        let request = try launcher.requestObject(0)
        let timeouts = request["timeouts"] as? [String: Any]
        try runnerExpect(
            launch.executableURL == fixture.python,
            "runner did not use the configured absolute Python path"
        )
        try runnerExpect(
            launch.arguments == [fixture.bridge.path],
            "runner added credentials or unexpected arguments"
        )
        try runnerExpect(
            !launch.arguments.joined().contains("fixture-secret"),
            "credential leaked to process arguments"
        )
        try runnerExpect(
            timeouts?["localScanSeconds"] as? Double == 30,
            "local scan timeout changed"
        )
        try runnerExpect(
            timeouts?["externalRequestSeconds"] as? Double == 10,
            "external request timeout changed"
        )
        try runnerExpect(
            timeouts?["moduleSeconds"] as? Double == 90,
            "module timeout changed"
        )

        try launcher.succeed(
            0,
            stderr: Data("Bearer fixture-secret\n".utf8)
        )
        let output = try await task.value
        try runnerExpect(
            output.response.runId == (request["runId"] as? String),
            "response runId did not match"
        )
        try runnerExpect(
            output.stderrDiagnostic?.summary.contains("fixture-secret")
                == false,
            "stderr was not sanitized"
        )
    }

    private static func enforcesModuleAndGlobalConcurrency() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let launcher = FakeProcessLauncher()
        let runner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: launcher,
            timerScheduler: FakeTimerScheduler()
        )
        let agent = Task {
            try await runner.run(module: .agentUsage)
        }
        await waitForLaunches(launcher, count: 1)

        do {
            _ = try await runner.run(module: .agentUsage)
            throw RunnerTestFailure.expectation(
                "same-module duplicate was accepted"
            )
        } catch CollectorRunnerError.alreadyRunning {
        }

        let github = Task {
            try await runner.run(module: .github)
        }
        await waitForLaunches(launcher, count: 2)
        try runnerExpect(runner.activeModuleCount == 2, "global limit not reached")

        do {
            _ = try await runner.run(module: .gitlab)
            throw RunnerTestFailure.expectation(
                "third concurrent module was accepted"
            )
        } catch CollectorRunnerError.capacityExceeded {
        }

        try launcher.succeed(1)
        _ = try await github.value
        try runnerExpect(
            runner.activeModuleCount == 1,
            "one module completion affected another module"
        )
        try launcher.succeed(0)
        _ = try await agent.value
    }

    private static func handlesTimeoutCancellationAndCrash() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }

        let timeoutLauncher = FakeProcessLauncher()
        let timeoutTimers = FakeTimerScheduler()
        let timeoutRunner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: timeoutLauncher,
            timerScheduler: timeoutTimers,
            timeouts: CollectorTimeouts(
                localScanSeconds: 30,
                externalRequestSeconds: 10,
                moduleSeconds: 1,
                cancellationGraceSeconds: 0.1
            )
        )
        let timedTask = Task {
            try await timeoutRunner.run(module: .github)
        }
        await waitForLaunches(timeoutLauncher, count: 1)
        timeoutTimers.tokens[0].fire()
        try runnerExpect(
            timeoutLauncher.launches[0].handle.cancellationCount == 1,
            "timeout did not request cancellation"
        )
        timeoutTimers.tokens[1].fire()
        try runnerExpect(
            timeoutLauncher.launches[0].handle.forceCount == 1,
            "timeout did not force termination after grace"
        )
        timeoutLauncher.complete(0, exitCode: SIGKILL)
        do {
            _ = try await timedTask.value
            throw RunnerTestFailure.expectation("timeout returned output")
        } catch CollectorRunnerError.timedOut {
        }

        let cancelLauncher = FakeProcessLauncher()
        let cancelRunner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: cancelLauncher,
            timerScheduler: FakeTimerScheduler()
        )
        let cancelledTask = Task {
            try await cancelRunner.run(module: .gitlab)
        }
        await waitForLaunches(cancelLauncher, count: 1)
        cancelRunner.cancel(module: .gitlab)
        cancelLauncher.complete(0, exitCode: SIGTERM)
        do {
            _ = try await cancelledTask.value
            throw RunnerTestFailure.expectation("cancel returned output")
        } catch is CancellationError {
        }

        let crashLauncher = FakeProcessLauncher()
        let crashRunner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: crashLauncher,
            timerScheduler: FakeTimerScheduler()
        )
        let crashTask = Task {
            try await crashRunner.run(module: .github)
        }
        await waitForLaunches(crashLauncher, count: 1)
        crashLauncher.complete(
            0,
            stderr: Data("token=fixture-secret".utf8),
            exitCode: 7
        )
        do {
            _ = try await crashTask.value
            throw RunnerTestFailure.expectation("crash returned output")
        } catch let CollectorRunnerError.processFailed(code, diagnostic) {
            try runnerExpect(code == 7, "crash exit code changed")
            try runnerExpect(
                diagnostic?.contains("fixture-secret") == false,
                "crash diagnostic leaked stderr"
            )
        }
    }

    private static func rejectsMismatchedAndPollutedResponses() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }

        let mismatchLauncher = FakeProcessLauncher()
        let mismatchRunner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: mismatchLauncher,
            timerScheduler: FakeTimerScheduler()
        )
        let mismatchTask = Task {
            try await mismatchRunner.run(module: .github)
        }
        await waitForLaunches(mismatchLauncher, count: 1)
        try mismatchLauncher.succeed(
            0,
            runId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )
        do {
            _ = try await mismatchTask.value
            throw RunnerTestFailure.expectation("mismatched runId accepted")
        } catch CollectorRunnerError.runIdMismatch {
        }

        let pollutedLauncher = FakeProcessLauncher()
        let pollutedRunner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: pollutedLauncher,
            timerScheduler: FakeTimerScheduler()
        )
        let pollutedTask = Task {
            try await pollutedRunner.run(module: .github)
        }
        await waitForLaunches(pollutedLauncher, count: 1)
        pollutedLauncher.complete(
            0,
            stdout: Data("{}\n{}".utf8),
            exitCode: 0
        )
        do {
            _ = try await pollutedTask.value
            throw RunnerTestFailure.expectation("polluted stdout accepted")
        } catch CollectorRunnerError.invalidEnvelope {
        }
    }

    private static func runsTheRealBridgeInAnIsolatedHome() async throws {
        guard CommandLine.arguments.count == 3 else {
            throw RunnerTestFailure.expectation(
                "expected absolute python and bridge paths"
            )
        }
        let pythonURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let bridgeURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let fakeHome = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-real-bridge-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fakeHome,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        let runner = CollectorRunner(
            pythonURL: pythonURL,
            bridgeURL: bridgeURL
        )
        let output = try await runner.run(
            module: .agentUsage,
            context: [
                "home": .string(fakeHome.path),
                "now": .string("2026-07-28T12:00:00+08:00"),
                "timezone": .string("Asia/Shanghai")
            ]
        )
        try runnerExpect(
            output.response.status == .success,
            "isolated real Bridge run failed"
        )
        try runnerExpect(
            output.response.artifact != nil,
            "isolated real Bridge returned no artifact"
        )
    }
}
