import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

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
        try runInputDeniesQuotasWithoutConsent()
        try runInputLocalCapabilitiesOnlyWithoutProviders()
        try runInputAssemblesKimiWebTokens()
        try runInputAssemblesDeepSeekProviderEnv()
        try runInputAssemblesVolcengineProviderMeta()
        try runInputAssemblesCodexAccounts()
        try runInputAssemblesAntigravityOAuth()
        try runInputAssemblesAllProvidersCombined()
        try runInputDeniesQuotasWhenCredentialMissing()
        try runInputDeniesQuotasWhenCredentialCorrupted()
        try runInputDeniesQuotasWhenProviderDisabled()
        try await runsTheRealBridgeInAnIsolatedHome()
        print("CollectorRunner tests passed: 16")
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
        try runnerExpect(
            timeouts?["cancellationGraceSeconds"] == nil,
            "Swift-only cancellation grace leaked into Bridge protocol"
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
                "timezone": .string("Asia/Shanghai"),
                "capabilities": .array([
                    .string("localSessions"),
                    .string("localPricing"),
                ]),
            ]
        )
        try runnerExpect(
            [.success, .partial].contains(output.response.status),
            "isolated real Bridge did not return usable data"
        )
        try runnerExpect(
            output.response.artifact != nil,
            "isolated real Bridge returned no artifact"
        )
    }

    // MARK: - OnboardingRunInputProvider 凭证装配矩阵
    // 全部使用临时目录配置与内存凭证存储, 不触碰真实 Keychain 与用户配置.

    /// 构造临时目录配置 + 内存凭证存储的 run input 提供器.
    private static func makeRunInputProvider(
        consentVersion: Int?,
        providers: [String: SubscriptionProviderConfiguration],
        credentials: InMemoryCredentialStore
    ) throws -> (OnboardingRunInputProvider, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-runinput-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true
        )
        let store = try OnboardingConfigurationStore(configDirectory: tempDir)
        let config = OnboardingConfiguration(
            consentVersion: consentVersion,
            subscriptionProviders: providers
        )
        try store.save(config)
        return (
            OnboardingRunInputProvider(
                configStore: store,
                credentialStore: credentials
            ),
            tempDir
        )
    }

    private static func capabilityStrings(
        _ input: CollectorRunInput
    ) -> [String] {
        guard case .array(let values)? = input.context["capabilities"] else {
            return []
        }
        return values.compactMap { value in
            if case .string(let string) = value { return string }
            return nil
        }
    }

    private static func enabledProvider(
        _ id: SubscriptionProviderID
    ) -> [String: SubscriptionProviderConfiguration] {
        [id.rawValue: SubscriptionProviderConfiguration(enabled: true)]
    }

    /// 统一授权未确认时, 即使 provider enabled 且凭证齐全也不授予 externalQuotas.
    private static func runInputDeniesQuotasWithoutConsent() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "{\"access_token\":\"a\",\"refresh_token\":\"r\"}",
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: nil,
            providers: enabledProvider(.kimi),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            !capabilityStrings(input).contains("externalQuotas"),
            "未确认统一授权时不得授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "未确认统一授权时不得装配任何凭证"
        )
    }

    /// 已确认授权但一个 provider 都没配置: 只有基础能力, 凭证为空.
    private static func runInputLocalCapabilitiesOnlyWithoutProviders() throws {
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: [:],
            credentials: InMemoryCredentialStore()
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input) == ["localSessions", "localPricing"],
            "未配置 provider 时必须只有 localSessions/localPricing"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "未配置 provider 时凭证必须为空"
        )
    }

    private static func runInputAssemblesKimiWebTokens() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "{\"access_token\":\"a\",\"refresh_token\":\"r\"}",
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.kimi),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "kimi 已配置时必须授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials["kimiWebTokens"] == .object([
                "access_token": .string("a"),
                "refresh_token": .string("r"),
            ]),
            "kimiWebTokens 注入结构必须与 collect_usage.py 消费一致"
        )
    }

    private static func runInputAssemblesDeepSeekProviderEnv() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "sk-fixture",
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.deepseek),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "deepseek 已配置时必须授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials["providerEnv"] == .object([
                "deepseek": .object([
                    "ANTHROPIC_AUTH_TOKEN": .string("sk-fixture"),
                ]),
            ]),
            "providerEnv.deepseek.ANTHROPIC_AUTH_TOKEN 注入结构不符"
        )
    }

    private static func runInputAssemblesVolcengineProviderMeta() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "AK-fixture",
            forAccount: SubscriptionCredentialAccount.volcengineAccessKey
        )
        try credentials.saveCredential(
            "SK-fixture",
            forAccount: SubscriptionCredentialAccount.volcengineSecretKey
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.volcengine),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "volcengine 已配置时必须授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials["providerMeta"] == .object([
                "volcengine": .object([
                    "usage_script": .object([
                        "accessKeyId": .string("AK-fixture"),
                        "secretAccessKey": .string("SK-fixture"),
                    ]),
                ]),
            ]),
            "providerMeta.volcengine.usage_script 注入结构不符"
        )
    }

    private static func runInputAssemblesCodexAccounts() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "{\"accounts\":{\"acc-1\":{\"email\":\"u@example.com\"," +
                "\"refresh_token\":\"rt\",\"access_token\":\"at\",\"id_token\":\"it\"}}}",
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.codex),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "codex 已配置时必须授予 externalQuotas"
        )
        guard case .object(let injected)? = input.credentials["codexOAuthAccounts"],
              case .object(let accounts)? = injected["accounts"],
              case .object(let account)? = accounts["acc-1"] else {
            throw RunnerTestFailure.expectation(
                "codexOAuthAccounts 注入结构必须与 CC Switch 同构"
            )
        }
        try runnerExpect(
            account["refresh_token"] == .string("rt")
                && account["access_token"] == .string("at")
                && account["email"] == .string("u@example.com"),
            "codex 账号字段注入不完整"
        )
    }

    private static func runInputAssemblesAntigravityOAuth() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "{\"token\":{\"access_token\":\"at\",\"refresh_token\":\"rt\"}}",
            forAccount: SubscriptionCredentialAccount.antigravityOAuth
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.antigravity),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "antigravity 已配置时必须授予 externalQuotas"
        )
        guard case .object(let injected)? = input.credentials["antigravityOAuth"],
              case .object(let token)? = injected["token"] else {
            throw RunnerTestFailure.expectation(
                "antigravityOAuth 注入结构必须与令牌文件同构"
            )
        }
        try runnerExpect(
            token["refresh_token"] == .string("rt"),
            "antigravity refresh_token 注入缺失"
        )
    }

    /// 五 provider 全部配置: 注入键齐全且互不干扰.
    private static func runInputAssemblesAllProvidersCombined() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "{\"access_token\":\"a\",\"refresh_token\":\"r\"}",
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        try credentials.saveCredential(
            "sk-fixture",
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        try credentials.saveCredential(
            "AK-fixture",
            forAccount: SubscriptionCredentialAccount.volcengineAccessKey
        )
        try credentials.saveCredential(
            "SK-fixture",
            forAccount: SubscriptionCredentialAccount.volcengineSecretKey
        )
        try credentials.saveCredential(
            "{\"accounts\":{\"acc-1\":{\"refresh_token\":\"rt\",\"access_token\":\"at\"}}}",
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try credentials.saveCredential(
            "{\"token\":{\"refresh_token\":\"rt\"}}",
            forAccount: SubscriptionCredentialAccount.antigravityOAuth
        )
        var providers: [String: SubscriptionProviderConfiguration] = [:]
        for id in SubscriptionProviderID.allCases {
            providers[id.rawValue] = SubscriptionProviderConfiguration(enabled: true)
        }
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: providers,
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "全部配置时必须授予 externalQuotas"
        )
        try runnerExpect(
            Set(input.credentials.keys) == [
                "kimiWebTokens", "codexOAuthAccounts",
                "antigravityOAuth", "providerEnv", "providerMeta",
            ],
            "注入键集合不符: \(input.credentials.keys.sorted())"
        )
        guard case .object(let env)? = input.credentials["providerEnv"],
              case .object(let meta)? = input.credentials["providerMeta"] else {
            throw RunnerTestFailure.expectation("providerEnv/providerMeta 结构不符")
        }
        try runnerExpect(
            env["deepseek"] != nil && meta["volcengine"] != nil,
            "providerEnv/providerMeta 内容不完整"
        )
    }

    /// provider enabled 但 Keychain 凭证缺失: 不授予 externalQuotas.
    private static func runInputDeniesQuotasWhenCredentialMissing() throws {
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.deepseek),
            credentials: InMemoryCredentialStore()
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            !capabilityStrings(input).contains("externalQuotas"),
            "凭证缺失时不得授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "凭证缺失时不得装配注入键"
        )
    }

    /// Keychain 里凭证 JSON 损坏: fail-closed, 不授予也不注入.
    private static func runInputDeniesQuotasWhenCredentialCorrupted() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "not-json-at-all",
            forAccount: SubscriptionCredentialAccount.kimiWebTokens
        )
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.kimi),
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            !capabilityStrings(input).contains("externalQuotas"),
            "凭证 JSON 损坏时不得授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "凭证 JSON 损坏时不得装配注入键"
        )
    }

    /// 凭证存在但 provider 未 enabled: 不授予不注入.
    private static func runInputDeniesQuotasWhenProviderDisabled() throws {
        let credentials = InMemoryCredentialStore()
        try credentials.saveCredential(
            "sk-fixture",
            forAccount: SubscriptionCredentialAccount.deepseekAPIKey
        )
        let providers = [
            SubscriptionProviderID.deepseek.rawValue:
                SubscriptionProviderConfiguration(enabled: false),
        ]
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: providers,
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try provider.runInput(for: .agentUsage)
        try runnerExpect(
            !capabilityStrings(input).contains("externalQuotas"),
            "provider 未 enabled 时不得授予 externalQuotas"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "provider 未 enabled 时不得装配注入键"
        )
    }
}
