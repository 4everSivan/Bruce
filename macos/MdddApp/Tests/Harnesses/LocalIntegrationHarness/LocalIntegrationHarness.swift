import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

private enum IntegrationTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func integrationExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw IntegrationTestFailure.expectation(message)
    }
}

@MainActor
private struct IsolatedRunInputProvider: CollectorRunInputProviding {
    let home: URL
    let secret: String
    var codexTokenDecisions: [CodexTokenDecision] = []

    func runInput(for module: CollectorModule) async throws -> CollectorRunInput {
        guard module == .agentUsage else {
            throw CollectorRunInputError.missingDependency(
                module: module,
                reason: "integration harness only enables Agent usage"
            )
        }
        return CollectorRunInput(
            context: [
                "home": .string(home.path),
                "now": .string("2026-07-28T12:00:00+08:00"),
                "timezone": .string("Asia/Shanghai"),
                "capabilities": .array([
                    .string("localSessions"),
                    .string("localPricing"),
                ]),
            ],
            credentials: [
                "providerEnv": .object([
                    "MDDD_FIXTURE_TOKEN": .string(secret),
                ]),
            ]
        )
    }

    /// 隔离集成不启用 Codex 定向重试.
    func retryInput(
        for module: CollectorModule,
        accountIDs: [String]
    ) async throws -> CollectorRunInput? {
        nil
    }
}

@main
@MainActor
struct LocalIntegrationHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else {
            throw IntegrationTestFailure.expectation(
                "expected repository root, Python path and Bridge path"
            )
        }
        let repository = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        let python = URL(fileURLWithPath: CommandLine.arguments[2])
        let bridge = URL(fileURLWithPath: CommandLine.arguments[3])
        try integrationExpect(
            repository.isFileURL
                && python.path.hasPrefix("/")
                && bridge.path.hasPrefix("/"),
            "integration paths must be absolute"
        )
        try await startupRefreshCacheDiagnosticsAndCleanup(
            repository: repository,
            python: python,
            bridge: bridge
        )
        try await codexMigrationLifecycleClosedLoop()
        try deepSeekArtifactToLedgerPipeline()
        print("Local integration tests passed: 3")
    }

    /// DeepSeek Artifact -> AppModel -> 账本 -> ViewModel 链路 (隔离 fixture).
    /// 验证: 有效 DeepSeek 余额观察喂账本, 派生月度状态成为唯一 UI 状态源,
    /// 追踪 ID 变化立即失效, 无效 Artifact 不读写账本.
    private static func deepSeekArtifactToLedgerPipeline() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-ledger-pipeline-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let ledger = DeepSeekUsageLedger(rootURL: root, calendar: calendar)
        let model = AppModel(deepSeekLedger: ledger)

        // 预置 DeepSeek 配置 (usageTrackingID) 走 subscriptionProviders 发布链路
        model.setSubscriptionProviders([
            .deepseek: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok,
                usageTrackingID: "pipeline-tracking-1"
            ),
        ])

        // 1. 首次有效 Artifact: 建立基线
        let firstArtifact = makeDeepSeekArtifact(
            generatedAt: "2026-08-03T04:00:00+08:00",
            balance: 100
        )
        model.setArtifact(firstArtifact, for: .agentUsage)
        guard case .baseline = model.deepSeekMonthlyUsage else {
            throw IntegrationTestFailure.expectation(
                "首次有效 Artifact 必须建立基线, got \(String(describing: model.deepSeekMonthlyUsage))"
            )
        }

        // 2. 第二次有效 Artifact: 余额下降, 进入 trend
        let secondArtifact = makeDeepSeekArtifact(
            generatedAt: "2026-08-03T12:00:00+08:00",
            balance: 80
        )
        model.setArtifact(secondArtifact, for: .agentUsage)
        guard case .trend(let trend) = model.deepSeekMonthlyUsage else {
            throw IntegrationTestFailure.expectation(
                "第二次有效 Artifact 必须进入 trend, got \(String(describing: model.deepSeekMonthlyUsage))"
            )
        }
        try integrationExpect(trend.estimatedConsumption == 20, "推算消费应为 20")

        // 3. 无效 Artifact (DeepSeek 条目 status != ok): 不读写账本, 保留当前状态
        let failedArtifact = makeDeepSeekArtifact(
            generatedAt: "2026-08-03T13:00:00+08:00",
            balance: 70,
            serviceStatus: "error"
        )
        model.setArtifact(failedArtifact, for: .agentUsage)
        guard case .trend(let afterFailure) = model.deepSeekMonthlyUsage else {
            throw IntegrationTestFailure.expectation("无效 Artifact 不得改变月度状态")
        }
        try integrationExpect(
            afterFailure.estimatedConsumption == 20,
            "无效 Artifact 不得记账"
        )

        // 4. 追踪 ID 变化: 立即失效, 等待下一条有效观察重建基线
        model.setSubscriptionProviders([
            .deepseek: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok,
                usageTrackingID: "pipeline-tracking-2"
            ),
        ])
        guard case .unavailable = model.deepSeekMonthlyUsage else {
            throw IntegrationTestFailure.expectation(
                "追踪 ID 变化必须立即失效月度状态, got \(String(describing: model.deepSeekMonthlyUsage))"
            )
        }
        // 新 ID 下首次有效观察: 重建基线, 不继承旧消费
        let thirdArtifact = makeDeepSeekArtifact(
            generatedAt: "2026-08-04T04:00:00+08:00",
            balance: 60
        )
        model.setArtifact(thirdArtifact, for: .agentUsage)
        guard case .baseline(let newBaseline) = model.deepSeekMonthlyUsage else {
            throw IntegrationTestFailure.expectation(
                "新追踪 ID 首次观察必须重建基线, got \(String(describing: model.deepSeekMonthlyUsage))"
            )
        }
        try integrationExpect(newBaseline.currentBalance == 60, "新基线余额应为 60")

        // 5. ViewModel 映射: 仅 DeepSeek section 携带月度状态
        let panel = model.makePanelViewModel()
        let deepSeekSection = panel.subscription?.sections.first {
            $0.id == "deepseek"
        }
        try integrationExpect(
            deepSeekSection?.deepSeekMonthlyUsage != nil,
            "DeepSeek section 必须携带月度 view model"
        )
        for section in panel.subscription?.sections ?? [] where section.id != "deepseek" {
            try integrationExpect(
                section.deepSeekMonthlyUsage == nil,
                "非 DeepSeek section 不得携带月度 view model"
            )
        }

        // 6. 落盘账本不包含敏感字段
        let ledgerDir = root.appendingPathComponent("usage-ledger")
        let fileURL = ledgerDir.appendingPathComponent("deepseek-monthly.json")
        let text = try String(
            data: Data(contentsOf: fileURL), encoding: .utf8
        ) ?? ""
        try integrationExpect(
            !text.localizedCaseInsensitiveContains("apiKey")
                && !text.localizedCaseInsensitiveContains("token")
                && !text.localizedCaseInsensitiveContains("account"),
            "账本落盘不得包含敏感字段"
        )
    }

    /// 构造含单个 DeepSeek 余额条目的静态 fixture Artifact.
    private static func makeDeepSeekArtifact(
        generatedAt: String,
        balance: Double,
        serviceStatus: String = "ok",
        serviceKind: String = "balance"
    ) -> JSONValue {
        let object: [String: Any] = [
            "schemaVersion": 1,
            "module": "agent-usage",
            "generatedAt": generatedAt,
            "totalCostUsd": 0.0,
            "agents": [],
            "services": [
                [
                    "id": "deepseek",
                    "name": "DeepSeek",
                    "status": serviceStatus,
                    "kind": serviceKind,
                    "windows": [],
                    "balance": balance,
                    "currency": "CNY",
                    "app": "deepseek",
                ],
            ],
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        )
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 任务 11 迁移闭环: 旧整体账号库 -> metadata-only v2 (不含 token),
    /// 旧键删除, 幂等重试, 迁移产物不向任何注入路径暴露旧 token.
    private static func codexMigrationLifecycleClosedLoop() async throws {
        let memory = InMemoryCredentialStore()
        let store = CodexCredentialStore(store: memory)
        let fixedNow = Date(timeIntervalSince1970: 1_752_000_000)

        // 1. 预置旧整体账号库 (含 token 与完整邮箱) + 旧 active 项
        let legacyJSON = """
        {"accounts":{"acc-1":{"email":"fixture@example.test",\
        "refresh_token":"legacy-rt","access_token":"legacy-at","id_token":"legacy-it"}}}
        """
        try memory.saveCredential(
            legacyJSON, forAccount: CodexCredentialKeys.legacyAccounts
        )
        try memory.saveCredential(
            "acc-1", forAccount: CodexCredentialKeys.legacyActiveAccount
        )

        // 2. 幂等迁移执行
        let executed = store.migrateLegacyAccounts(now: fixedNow)
        guard case .migrated = executed else {
            throw IntegrationTestFailure.expectation("旧库存在时迁移必须返回 .migrated: \(executed)")
        }

        // 3. v2 记录是 metadata-only: 任何 token 字段都是 nil, 状态需重新授权
        guard let record = try store.loadRecord(for: "acc-1") else {
            throw IntegrationTestFailure.expectation("迁移后 v2 记录缺失")
        }
        try integrationExpect(
            record.accessToken == nil && record.refreshToken == nil
                && record.idToken == nil,
            "迁移复制了 token"
        )
        try integrationExpect(
            record.authorizationState == .needsReauthorization
                && record.credentialOrigin == .legacyCCSwitchDiscovery,
            "迁移记录状态/来源不符"
        )
        try integrationExpect(
            record.email == "fixture@example.test",
            "迁移丢失 email 元数据"
        )

        // 4. 旧键已删除
        let legacyAccounts = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyAccounts
        )
        try integrationExpect(legacyAccounts == nil, "旧整体库未被删除")
        let legacyActive = try memory.loadCredential(
            forAccount: CodexCredentialKeys.legacyActiveAccount
        )
        try integrationExpect(legacyActive == nil, "旧 active 项未被删除")

        // 5. 再次迁移幂等返回 .noLegacyData, 不重复写入
        let again = store.migrateLegacyAccounts(now: fixedNow)
        guard case .noLegacyData = again else {
            throw IntegrationTestFailure.expectation("无旧键时迁移必须幂等返回 .noLegacyData: \(again)")
        }
        let index = try store.loadIndex()
        try integrationExpect(
            index.accounts.count == 1 && index.migrationCompletedAt != nil,
            "迁移完成标记/账号数不符"
        )

        // 6. 迁移产物不会以旧 token 形式进入任何运行输入:
        // 无 injector 时 resolveCodexQuotaAccounts 不产生注入
        let provider = OnboardingRunInputProvider(
            configStore: nil,
            credentialStore: memory,
            codexTokenInjector: nil,
            codexStore: store
        )
        let input = try await provider.runInput(for: .agentUsage)
        try integrationExpect(
            input.credentials["codexQuotaAccounts"] == nil,
            "未授权的迁移账号不得注入 quota 输入"
        )
    }

    private static func startupRefreshCacheDiagnosticsAndCleanup(
        repository: URL,
        python: URL,
        bridge: URL
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-local-integration-\(UUID().uuidString)",
                isDirectory: true
            )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let applicationSupport = root.appendingPathComponent(
            "Application Support/mddd",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let secret = "fixture-secret-\(UUID().uuidString)"
        let store = try ArtifactStore(rootURL: applicationSupport)
        let runner = CollectorRunner(
            pythonURL: python,
            bridgeURL: bridge
        )
        let scheduler = RefreshScheduler(
            executor: runner,
            store: store,
            registerWakeNotifications: false,
            runInputProvider: IsolatedRunInputProvider(
                home: home,
                secret: secret
            )
        )
        let model = AppModel()
        scheduler.onStatusChange = { module, state, detail in
            model.setStatus(
                ModuleStatus(state: state, detail: detail),
                for: DashboardModule(module)
            )
        }
        scheduler.onArtifactChange = { module, artifact in
            model.setArtifact(artifact, for: DashboardModule(module))
        }
        scheduler.setAutoRefresh(false, for: .agentUsage)
        scheduler.start()
        scheduler.enableModule(.agentUsage)
        scheduler.refresh(.agentUsage)

        for _ in 0..<5_000 {
            if model.moduleArtifacts[.agentUsage] != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try integrationExpect(
            model.moduleArtifacts[.agentUsage] != nil,
            "isolated refresh did not publish an Agent artifact"
        )
        let snapshotURL = store.snapshotURL(for: .agentUsage)
        let snapshotData = try Data(contentsOf: snapshotURL)
        let snapshotText = String(decoding: snapshotData, as: UTF8.self)
        try integrationExpect(
            !snapshotText.contains(secret),
            "credential leaked into snapshot"
        )
        try integrationExpect(
            !snapshotText.contains(home.path),
            "isolated HOME leaked into snapshot"
        )

        let restartedModel = AppModel()
        let restartedScheduler = RefreshScheduler(
            executor: runner,
            store: store,
            registerWakeNotifications: false
        )
        restartedScheduler.onArtifactChange = { module, artifact in
            restartedModel.setArtifact(
                artifact,
                for: DashboardModule(module)
            )
        }
        restartedScheduler.start()
        try integrationExpect(
            restartedModel.moduleArtifacts[.agentUsage] != nil,
            "cache-first restart did not load the last successful snapshot"
        )

        let diagnostics = DiagnosticService(
            model: model,
            scheduler: scheduler,
            store: store
        )
        let preview = try diagnostics.preview()
        try integrationExpect(
            !preview.contains(secret)
                && !preview.contains(home.path)
                && !preview.lowercased().contains("\"artifact\""),
            "diagnostics preview contains non-allowlisted data"
        )
        let archive = root.appendingPathComponent("diagnostics.zip")
        try diagnostics.export(to: archive)
        let extracted = root.appendingPathComponent(
            "diagnostics-extracted",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: extracted,
            withIntermediateDirectories: true
        )
        try expandArchive(archive, to: extracted)
        let files = try regularFiles(in: extracted)
        try integrationExpect(
            files == [
                "mddd-diagnostics/README.txt",
                "mddd-diagnostics/report.json",
            ],
            "diagnostics ZIP contains unexpected files: \(files)"
        )
        for relativePath in files {
            let data = try Data(contentsOf: extracted.appendingPathComponent(
                relativePath
            ))
            try integrationExpect(
                !DiagnosticContentPolicy.containsSensitiveContent(data),
                "diagnostics file failed sensitive-content scan"
            )
            let text = String(decoding: data, as: UTF8.self)
            try integrationExpect(
                !text.contains(secret) && !text.contains(home.path),
                "diagnostics file contains isolated secret or HOME"
            )
        }

        let widgetFiles = [
            repository.appendingPathComponent(
                "agent-usage/widget/index.html"
            ),
        ]
        for widget in widgetFiles {
            let source = try String(contentsOf: widget, encoding: .utf8)
            try integrationExpect(
                !source.contains(secret),
                "fixture credential leaked into Widget source"
            )
        }

        scheduler.stop()
        restartedScheduler.stop()
        try FileManager.default.removeItem(at: root)
        try integrationExpect(
            !FileManager.default.fileExists(atPath: root.path),
            "isolated Application Support cleanup failed"
        )
    }

    private static func expandArchive(
        _ archive: URL,
        to destination: URL
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [
            "-x",
            "-k",
            archive.path,
            destination.path,
        ]
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "LC_ALL": "C",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try integrationExpect(
            process.terminationStatus == 0,
            "failed to expand diagnostics ZIP"
        )
    }

    private static func regularFiles(in root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey]
            )
            if values.isRegularFile == true {
                let relativeComponents = url.standardizedFileURL
                    .pathComponents
                    .dropFirst(root.standardizedFileURL.pathComponents.count)
                files.append(relativeComponents.joined(separator: "/"))
            }
        }
        return files.sorted()
    }
}
