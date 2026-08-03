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
            diagnostics: [],
            credentialChallenges: []
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
        try await enforcesModuleConcurrency()
        try await handlesTimeoutCancellationAndCrash()
        try await rejectsMismatchedAndPollutedResponses()
        try await oldBridgeResponseWithoutChallengesDecodesAsEmpty()
        try await runInputDeniesQuotasWithoutConsent()
        try await runInputLocalCapabilitiesOnlyWithoutProviders()
        try await runInputAssemblesKimiWebTokens()
        try await runInputAssemblesDeepSeekProviderEnv()
        try await runInputAssemblesVolcengineProviderMeta()
        try await runInputResolvesCodexQuotaAccounts()
        try await runInputCodexPartialFailureDoesNotBlockOthers()
        try await runInputCodexInjectsOnlyShortLivedAccessToken()
        try await runInputCodexGatedUntilMigrationCompleted()
        try runInputRejectsCodexRotationUpdates()
        try await runInputAssemblesAntigravityOAuth()
        try await runInputAssemblesAllProvidersCombined()
        try await runInputDeniesQuotasWhenCredentialMissing()
        try await runInputDeniesQuotasWhenCredentialCorrupted()
        try await runInputDeniesQuotasWhenProviderDisabled()
        try await runsTheRealBridgeInAnIsolatedHome()
        print("CollectorRunner tests passed: 21")
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
                module: .agentUsage,
                credentials: [
                    "kimiWebTokens": .object([
                        "access_token": .string("fixture-secret"),
                        "refresh_token": .string("fixture-refresh"),
                    ])
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

    /// 任务 1 冻结契约: 旧 Bridge v1 响应缺 credentialChallenges 时按空数组解码,
    /// 不升级 schemaVersion, 不报错.
    private static func oldBridgeResponseWithoutChallengesDecodesAsEmpty() async throws {
        let fixture = try RunnerFixture()
        defer { fixture.remove() }
        let launcher = FakeProcessLauncher()
        let runner = CollectorRunner(
            pythonURL: fixture.python,
            bridgeURL: fixture.bridge,
            launcher: launcher,
            timerScheduler: FakeTimerScheduler()
        )
        let task = Task {
            try await runner.run(module: .agentUsage)
        }
        await waitForLaunches(launcher, count: 1)

        let runId = try launcher.requestRunId(0)
        let oldStyleJSON = """
        {"schemaVersion":1,"runId":"\(runId)",\
        "generatedAt":"2026-07-28T12:00:00Z","status":"success",\
        "artifact":{"module":"agent-usage","schemaVersion":1,"fixture":true},\
        "credentialUpdates":[],"diagnostics":[]}
        """
        launcher.complete(
            0,
            stdout: Data(oldStyleJSON.utf8),
            exitCode: 0
        )
        let output = try await task.value
        try runnerExpect(
            output.response.schemaVersion == 1,
            "schemaVersion must stay 1 for old Bridge responses"
        )
        let challenges = output.response.credentialChallenges
        try runnerExpect(
            challenges.isEmpty,
            "missing credentialChallenges must decode as empty array"
        )
    }

    private static func enforcesModuleConcurrency() async throws {
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

        // 同模块运行中重复提交必须拒绝
        do {
            _ = try await runner.run(module: .agentUsage)
            throw RunnerTestFailure.expectation(
                "same-module duplicate was accepted"
            )
        } catch CollectorRunnerError.alreadyRunning {
        }
        try runnerExpect(runner.activeModuleCount == 1, "active count changed")

        try launcher.succeed(0)
        _ = try await agent.value
        try runnerExpect(
            runner.activeModuleCount == 0,
            "module completion did not clear active count"
        )
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
            try await timeoutRunner.run(module: .agentUsage)
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
            try await cancelRunner.run(module: .agentUsage)
        }
        await waitForLaunches(cancelLauncher, count: 1)
        cancelRunner.cancel(module: .agentUsage)
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
            try await crashRunner.run(module: .agentUsage)
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
            try await mismatchRunner.run(module: .agentUsage)
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
            try await pollutedRunner.run(module: .agentUsage)
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
        credentials: InMemoryCredentialStore,
        codexInjector: (any CodexAccessTokenInjecting)? = nil,
        codexStore: CodexCredentialStore? = nil
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
                credentialStore: credentials,
                codexTokenInjector: codexInjector,
                codexStore: codexStore
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
    private static func runInputDeniesQuotasWithoutConsent() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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
    private static func runInputLocalCapabilitiesOnlyWithoutProviders() async throws {
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: [:],
            credentials: InMemoryCredentialStore()
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input) == ["localSessions", "localPricing"],
            "未配置 provider 时必须只有 localSessions/localPricing"
        )
        try runnerExpect(
            input.credentials.isEmpty,
            "未配置 provider 时凭证必须为空"
        )
    }

    private static func runInputAssemblesKimiWebTokens() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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

    private static func runInputAssemblesDeepSeekProviderEnv() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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

    private static func runInputAssemblesVolcengineProviderMeta() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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

    /// 活跃账号存在时同步装配 codexAuth 注入, 结构对齐 collector
    /// 对 ~/.codex/auth.json 的消费 (tokens.account_id/refresh_token).
    /// 未记录活跃账号或活跃账号不在库中: 不注入 codexAuth,
    /// collector 按无 CLI 侧候选处理.
    private static func runInputAssemblesAntigravityOAuth() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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
    private static func runInputAssemblesAllProvidersCombined() async throws {
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
            "{\"token\":{\"refresh_token\":\"rt\"}}",
            forAccount: SubscriptionCredentialAccount.antigravityOAuth
        )
        let (codexStore, _) = try makeCodexStore(accounts: [
            "acc-1": "user@example.com",
        ])
        let injector = StubCodexInjector(resolutions: [
            "acc-1": "short-at",
        ])
        var providers: [String: SubscriptionProviderConfiguration] = [:]
        for id in SubscriptionProviderID.allCases {
            providers[id.rawValue] = SubscriptionProviderConfiguration(enabled: true)
        }
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: providers,
            credentials: credentials,
            codexInjector: injector,
            codexStore: codexStore
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "全部配置时必须授予 externalQuotas"
        )
        try runnerExpect(
            Set(input.credentials.keys) == [
                "kimiWebTokens", "codexQuotaAccounts",
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
        guard case .object(let quotaAccounts)? = input.credentials["codexQuotaAccounts"],
              case .object(let account)? = quotaAccounts["acc-1"] else {
            throw RunnerTestFailure.expectation("codexQuotaAccounts 注入缺失")
        }
        try runnerExpect(
            account["access_token"] == .string("short-at"),
            "combined 场景 codex access token 缺失"
        )
    }

    // MARK: - Codex 短期 access token 注入 (任务 6)

    /// 可编程 stub: 按账号返回 access token 或 nil, 记录被请求的账号.
    @MainActor
    private final class StubCodexInjector: CodexAccessTokenInjecting {
        private let resolutions: [String: String?]
        private(set) var requested: [String] = []

        init(resolutions: [String: String?]) {
            self.resolutions = resolutions
        }

        func validAccessToken(for accountID: String) async -> String? {
            requested.append(accountID)
            return resolutions[accountID] ?? nil
        }
    }

    /// 预置 connected v2 账号记录的 store.
    private static func makeCodexStore(
        accounts: [String: String]
    ) throws -> (CodexCredentialStore, InMemoryCredentialStore) {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        for (accountID, email) in accounts {
            try store.saveRecord(CodexAccountRecord(
                accountID: accountID,
                email: email,
                accessToken: "at-\(accountID)",
                refreshToken: "rt-\(accountID)",
                accessTokenExpiresAt: Date(timeIntervalSince1970: 1_752_000_000)
                    .addingTimeInterval(3600),
                authorizationState: .connected,
                credentialOrigin: .mddd,
                updatedAt: Date(timeIntervalSince1970: 1_752_000_000)
            ))
        }
        return (store, memory)
    }

    /// 多账号成功决议: 组装为 codexQuotaAccounts, 不再注入整体账号库.
    private static func runInputResolvesCodexQuotaAccounts() async throws {
        let (codexStore, memory) = try makeCodexStore(accounts: [
            "acc-1": "user@example.com",
            "acc-2": "other@example.com",
        ])
        let injector = StubCodexInjector(resolutions: [
            "acc-1": "short-at-1",
            "acc-2": "short-at-2",
        ])
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.codex),
            credentials: memory,
            codexInjector: injector,
            codexStore: codexStore
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "codex 已配置时必须授予 externalQuotas"
        )
        guard case .object(let quotaAccounts)? = input.credentials["codexQuotaAccounts"],
              case .object(let account1)? = quotaAccounts["acc-1"],
              case .object(let account2)? = quotaAccounts["acc-2"] else {
            throw RunnerTestFailure.expectation(
                "codexQuotaAccounts 注入结构不符"
            )
        }
        try runnerExpect(
            account1["access_token"] == .string("short-at-1")
                && account2["access_token"] == .string("short-at-2"),
            "短期 access token 注入不完整"
        )
        try runnerExpect(
            account1["display_name"] == .string("Codex · user"),
            "display_name 必须脱敏为邮箱前缀"
        )
        // 旧注入键一律不存在
        try runnerExpect(
            input.credentials["codexOAuthAccounts"] == nil,
            "不得注入 codexOAuthAccounts"
        )
        try runnerExpect(
            input.credentials["codexAuth"] == nil,
            "不得注入 codexAuth"
        )
        // 决议结果进入 Swift 内记录
        try runnerExpect(
            provider.resolvedCodexAccountIDs() == ["acc-1", "acc-2"],
            "决议账号列表不符"
        )
    }

    /// 单账号暂时失败或需要授权时不阻断其他账号和本地会话采集.
    private static func runInputCodexPartialFailureDoesNotBlockOthers() async throws {
        let (codexStore, memory) = try makeCodexStore(accounts: [
            "acc-1": "user@example.com",
            "acc-2": "other@example.com",
        ])
        // acc-1 决议失败 (需要重新授权), acc-2 成功
        let injector = StubCodexInjector(resolutions: [
            "acc-1": nil,
            "acc-2": "short-at-2",
        ])
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.codex),
            credentials: memory,
            codexInjector: injector,
            codexStore: codexStore
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
        try runnerExpect(
            capabilityStrings(input).contains("externalQuotas"),
            "单账号失败不得撤销 externalQuotas"
        )
        guard case .object(let quotaAccounts)? = input.credentials["codexQuotaAccounts"],
              case .object(let account2)? = quotaAccounts["acc-2"] else {
            throw RunnerTestFailure.expectation(
                "成功账号必须注入, got \(input.credentials.keys)"
            )
        }
        try runnerExpect(
            account2["access_token"] == .string("short-at-2"),
            "成功账号 access token 缺失"
        )
        try runnerExpect(
            quotaAccounts["acc-1"] == nil,
            "失败账号不得注入"
        )
        try runnerExpect(
            provider.resolvedCodexAccountIDs() == ["acc-2"],
            "决议列表必须只含成功账号"
        )
    }

    /// 注入内容只含账号键、脱敏 display_name 和 access_token;
    /// 不含 refresh_token、id_token、完整邮箱.
    private static func runInputCodexInjectsOnlyShortLivedAccessToken() async throws {
        let (codexStore, memory) = try makeCodexStore(accounts: [
            "acc-1": "user@example.com",
        ])
        let injector = StubCodexInjector(resolutions: [
            "acc-1": "fresh-access",
        ])
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.codex),
            credentials: memory,
            codexInjector: injector,
            codexStore: codexStore
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
        guard case .object(let quotaAccounts)? = input.credentials["codexQuotaAccounts"],
              case .object(let account)? = quotaAccounts["acc-1"] else {
            throw RunnerTestFailure.expectation("codexQuotaAccounts 注入缺失")
        }
        let serialized = input.credentials["codexQuotaAccounts"]
        let text = serialized.map(String.init(describing:)) ?? ""
        try runnerExpect(
            !text.contains("refresh_token") && !text.contains("rt"),
            "注入不得包含 refresh token"
        )
        try runnerExpect(
            !text.contains("id_token") && !text.contains("id-token"),
            "注入不得包含 id token"
        )
        try runnerExpect(
            !text.contains("user@example.com"),
            "注入不得包含完整邮箱"
        )
        try runnerExpect(
            account["display_name"] != nil && account["access_token"] != nil,
            "账号条目必须只含 display_name 和 access_token"
        )
    }

    /// 旧库迁移完成前 (任务 11 gate): 不注入 Codex quota 账号,
    /// 其他 provider 与本地能力不受影响; 迁移完成后恢复注入.
    private static func runInputCodexGatedUntilMigrationCompleted() async throws {
        let (codexStore, memory) = try makeCodexStore(accounts: [
            "acc-1": "user@example.com",
        ])
        let injector = StubCodexInjector(resolutions: [
            "acc-1": "fresh-access",
        ])
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.codex),
            credentials: memory,
            codexInjector: injector,
            codexStore: codexStore
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 迁移未完成: 无 Codex 注入, 但 externalQuotas 与本地能力保留
        provider.setCodexMigrationCompleted(false)
        let gated = try await provider.runInput(for: .agentUsage)
        try runnerExpect(
            gated.credentials["codexQuotaAccounts"] == nil,
            "迁移未完成时不得注入 Codex quota 账号"
        )
        try runnerExpect(
            capabilityStrings(gated).contains("localSessions"),
            "迁移未完成不得阻断本地会话能力"
        )

        // 迁移完成: 恢复注入
        provider.setCodexMigrationCompleted(true)
        let opened = try await provider.runInput(for: .agentUsage)
        guard case .object(let quotaAccounts)? = opened.credentials["codexQuotaAccounts"],
              case .object(let account)? = quotaAccounts["acc-1"] else {
            throw RunnerTestFailure.expectation("迁移完成后必须恢复 Codex 注入")
        }
        try runnerExpect(
            account["access_token"] == .string("fresh-access"),
            "迁移后注入的 access token 不符"
        )
        try runnerExpect(
            provider.resolvedCodexAccountIDs() == ["acc-1"],
            "迁移后决议账号列表不符"
        )
    }

    /// Codex rotation update 被明确拒绝, 不写回 Keychain.
    private static func runInputRejectsCodexRotationUpdates() throws {        let credentials = InMemoryCredentialStore()
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: [:],
            credentials: credentials
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        provider.apply(credentialUpdates: [
            .object([
                "provider": .string("codex"),
                "kind": .string("oauthTokens"),
                "operation": .string("replace"),
                "accountId": .string("acc-1"),
                "credentials": .object([
                    "refresh_token": .string("rotated-rt"),
                    "access_token": .string("rotated-at"),
                ]),
            ]),
        ])
        let stored = try? credentials.loadCredential(
            forAccount: SubscriptionCredentialAccount.codexAccounts
        )
        try runnerExpect(
            stored == nil,
            "Codex rotation 不得写回 Keychain"
        )
    }

    /// provider enabled 但 Keychain 凭证缺失: 不授予 externalQuotas.
    private static func runInputDeniesQuotasWhenCredentialMissing() async throws {
        let (provider, tempDir) = try makeRunInputProvider(
            consentVersion: 1,
            providers: enabledProvider(.deepseek),
            credentials: InMemoryCredentialStore()
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let input = try await provider.runInput(for: .agentUsage)
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
    private static func runInputDeniesQuotasWhenCredentialCorrupted() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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
    private static func runInputDeniesQuotasWhenProviderDisabled() async throws {
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

        let input = try await provider.runInput(for: .agentUsage)
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
