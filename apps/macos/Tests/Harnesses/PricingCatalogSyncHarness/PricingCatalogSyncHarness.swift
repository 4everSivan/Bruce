import Foundation
@testable import BruceAppCore
@testable import BruceOnboardingCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "") throws {
    guard condition() else {
        throw HarnessFailure(message: message.isEmpty ? "Assertion failed" : message)
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "") throws {
    guard a == b else {
        throw HarnessFailure(message: "\(message): expected \(b), got \(a)")
    }
}

struct HarnessFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class MockPricingTransport: PricingCatalogTransport, @unchecked Sendable {
    var result: Result<Data, Error>

    init(result: Result<Data, Error>) {
        self.result = result
    }

    func fetchCatalog(from url: URL) async throws -> Data {
        try result.get()
    }
}

@main
@MainActor
struct PricingCatalogSyncHarness {
    static func main() async throws {
        let repoRoot = resolveRepoRoot()
        var passed = 0

        func run(_ name: String, _ body: () async throws -> Void) async throws {
            print("Pricing catalog sync: \(name)")
            try await body()
            passed += 1
        }

        try await run("updatedAt 格式校验与修订号比对") {
            try testUpdatedAtFormattingAndComparison()
        }

        try await run("validateAndParse 校验有效与非法价卡") {
            try testValidateAndParse()
        }

        try await run("偏好设置默认值与持久化") {
            try testPreferencesPersistence()
        }

        try await run("防倒退：本地旧缓存启动清理并回退内置") {
            try testAntiRollbackPurgesStaleFile()
        }

        try await run("防倒退：远端版本过期拒绝落盘") {
            try await testRemoteStaleVersionRejected()
        }

        try await run("手动同步：拉取更新、计算差异、POSIX 0600 原子落盘与状态转换") {
            try await testManualSyncUpdateAndPermissions()
        }

        try await run("手动同步：已是最新") {
            try await testManualSyncUpToDate()
        }

        try await run("手动同步：网络超时/离线/HTTP 404/格式错误分类") {
            try await testManualSyncErrorClassification()
        }

        try await run("恢复内置：移除同步文件并重置活动目录") {
            try await testRestoreBuiltin()
        }

        try await run("自动同步：启动 30 秒 + 24 小时调度与静默容错") {
            try await testAutoSyncScheduleAndSilentFailure()
        }

        var parityCount = 0
        try await run("双端文案与状态机共享对拍 fixture (cases.json)") {
            parityCount = try testParityWithFixture(repoRoot: repoRoot)
        }

        try await run("CollectorRunInput 动态价卡注入集成") {
            try await testCollectorRunInputInjection()
        }

        print("PricingCatalogSync tests passed: \(passed) (parity assertions: \(parityCount))")
    }

    // MARK: - Tests

    static func testUpdatedAtFormattingAndComparison() throws {
        try expect(BuiltinModelPricingCatalog.isValidUpdatedAt("2026-10-31"))
        try expect(BuiltinModelPricingCatalog.isValidUpdatedAt("2026-10-31.1"))
        try expect(BuiltinModelPricingCatalog.isValidUpdatedAt("2026-10-31.12"))
        try expect(!BuiltinModelPricingCatalog.isValidUpdatedAt("2026-1-31"))
        try expect(!BuiltinModelPricingCatalog.isValidUpdatedAt("2026-10-31."))
        try expect(!BuiltinModelPricingCatalog.isValidUpdatedAt("2026-10-31.a"))
        try expect(!BuiltinModelPricingCatalog.isValidUpdatedAt("invalid"))

        try expectEqual(
            BuiltinModelPricingCatalog.compareUpdatedAt("2026-10-31", "2026-10-31"),
            .orderedSame
        )
        try expectEqual(
            BuiltinModelPricingCatalog.compareUpdatedAt("2026-10-30", "2026-10-31"),
            .orderedAscending
        )
        try expectEqual(
            BuiltinModelPricingCatalog.compareUpdatedAt("2026-11-01", "2026-10-31"),
            .orderedDescending
        )
        try expectEqual(
            BuiltinModelPricingCatalog.compareUpdatedAt("2026-10-31", "2026-10-31.1"),
            .orderedAscending
        )
        try expectEqual(
            BuiltinModelPricingCatalog.compareUpdatedAt("2026-10-31.2", "2026-10-31.10"),
            .orderedAscending
        )
    }

    static func testValidateAndParse() throws {
        let validJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-10-31",
          "models": [
            {
              "model": "test-m1",
              "displayName": "Test M1",
              "vendor": "Test",
              "input": 1.0,
              "output": 2.0,
              "cacheRead": 0.1,
              "cacheWrite": [1.25, 2.0],
              "note": "test note",
              "listed": true
            },
            {
              "model": "test-alias",
              "displayName": "Test Alias",
              "vendor": "Test",
              "input": 1.0,
              "output": 2.0,
              "listed": false
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try BuiltinModelPricingCatalog.validateAndParse(data: validJSON, source: .synced)
        try expectEqual(parsed.schemaVersion, 1)
        try expectEqual(parsed.updatedAt, "2026-10-31")
        try expectEqual(parsed.models.count, 1) // only listed models
        try expectEqual(parsed.models[0].modelName, "test-m1")

        // Bad schemaVersion
        let badSchema = """
        {"schemaVersion": 2, "updatedAt": "2026-10-31", "models": [{"model":"m","displayName":"M","vendor":"V","input":1,"output":2}]}
        """.data(using: .utf8)!
        do {
            _ = try BuiltinModelPricingCatalog.validateAndParse(data: badSchema)
            throw HarnessFailure(message: "Should reject schemaVersion 2")
        } catch PricingCatalogError.unsupportedSchemaVersion {
            // ok
        }

        // Duplicate model
        let dup = """
        {"schemaVersion": 1, "updatedAt": "2026-10-31", "models": [
            {"model":"m1","displayName":"M1","vendor":"V","input":1,"output":2},
            {"model":"M1","displayName":"M1 dup","vendor":"V","input":1,"output":2}
        ]}
        """.data(using: .utf8)!
        do {
            _ = try BuiltinModelPricingCatalog.validateAndParse(data: dup)
            throw HarnessFailure(message: "Should reject duplicate model keys")
        } catch PricingCatalogError.duplicateModel {
            // ok
        }
    }

    static func testPreferencesPersistence() throws {
        let defaults = UserDefaults(suiteName: "PricingCatalogSyncHarness.Preferences")!
        defaults.removePersistentDomain(forName: "PricingCatalogSyncHarness.Preferences")

        let prefs = PricingCatalogPreferences(defaults: defaults)
        try expect(prefs.autoSyncEnabled, "默认开启自动同步")
        try expect(prefs.lastSyncAt == nil, "初始上次同步为空")

        prefs.autoSyncEnabled = false
        let now = Date(timeIntervalSince1970: 1785211200)
        prefs.lastSyncAt = now

        let reloaded = PricingCatalogPreferences(defaults: defaults)
        try expect(!reloaded.autoSyncEnabled, "关闭状态持久化")
        try expectEqual(reloaded.lastSyncAt?.timeIntervalSince1970, now.timeIntervalSince1970)
    }

    static func testAntiRollbackPurgesStaleFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")
        let staleJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2020-01-01",
          "models": [
            {"model": "stale-model", "displayName": "Stale", "vendor": "V", "input": 1, "output": 1, "listed": true}
          ]
        }
        """.data(using: .utf8)!
        try staleJSON.write(to: fileURL)

        BuiltinModelPricingCatalog.reloadActiveCatalog(fileURL: fileURL)
        try expectEqual(BuiltinModelPricingCatalog.currentSource, .builtin, "过期版本自动回退内置基线")
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "过期文件已被自动清理")
    }

    static func testRemoteStaleVersionRejected() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")
        let staleRemoteJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2020-01-01",
          "models": [
            {"model": "stale-m", "displayName": "Stale", "vendor": "V", "input": 1, "output": 1, "listed": true}
          ]
        }
        """.data(using: .utf8)!

        let transport = MockPricingTransport(result: .success(staleRemoteJSON))
        let service = PricingCatalogSyncService(
            fileURL: fileURL,
            transport: transport
        )

        service.syncNow()
        // Wait for sync task to complete
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .failed(let reason) = service.stage else {
            throw HarnessFailure(message: "Expected failed stage, got \(service.stage)")
        }
        try expectEqual(reason, .staleVersion)
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "过期远端价格表未落盘")
    }

    static func testManualSyncUpdateAndPermissions() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")

        // Construct remote catalog with 1 new model and 1 adjusted model
        let newRemoteJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-05",
          "models": [
            {"model": "k3-agent", "displayName": "Kimi K3 (Agent)", "vendor": "Moonshot Kimi", "input": 99.0, "output": 15.0, "listed": true},
            {"model": "brand-new-model", "displayName": "Brand New", "vendor": "NewVendor", "input": 5.0, "output": 25.0, "listed": true}
          ]
        }
        """.data(using: .utf8)!

        let transport = MockPricingTransport(result: .success(newRemoteJSON))
        var updatedFired = false
        let service = PricingCatalogSyncService(
            fileURL: fileURL,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1785211200) }
        )
        service.onCatalogUpdated = {
            updatedFired = true
        }

        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .updated(let updatedAt, let count, let added, let adjusted) = service.stage else {
            throw HarnessFailure(message: "Expected updated stage, got \(service.stage)")
        }
        try expectEqual(updatedAt, "2026-11-05")
        try expectEqual(count, 2)
        try expectEqual(added, 1)
        try expectEqual(adjusted, 1)
        try expect(updatedFired, "触发了 onCatalogUpdated 回调")

        // 校验落盘文件权限 0600
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let posixPerms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        try expectEqual(posixPerms, 0o600, "文件权限必须为 0600")

        // 内存态已热生效
        try expectEqual(BuiltinModelPricingCatalog.currentSource, .synced)
        try expectEqual(BuiltinModelPricingCatalog.currentUpdatedAt, "2026-11-05")
        try expect(BuiltinModelPricingCatalog.allModels.contains(where: { $0.modelName == "brand-new-model" }))
    }

    static func testManualSyncUpToDate() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")

        // Active catalog already set to 2026-11-05 from previous test
        let sameRemoteJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-05",
          "models": [
            {"model": "k3-agent", "displayName": "Kimi K3 (Agent)", "vendor": "Moonshot Kimi", "input": 99.0, "output": 15.0, "listed": true},
            {"model": "brand-new-model", "displayName": "Brand New", "vendor": "NewVendor", "input": 5.0, "output": 25.0, "listed": true}
          ]
        }
        """.data(using: .utf8)!

        let transport = MockPricingTransport(result: .success(sameRemoteJSON))
        let service = PricingCatalogSyncService(
            fileURL: fileURL,
            transport: transport
        )

        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)

        guard case .upToDate(let updatedAt, let count) = service.stage else {
            throw HarnessFailure(message: "Expected upToDate stage, got \(service.stage)")
        }
        try expectEqual(updatedAt, "2026-11-05")
        try expectEqual(count, 2)
    }

    static func testManualSyncErrorClassification() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")

        // 1. Timeout
        let transport = MockPricingTransport(result: .failure(PricingSyncFailureReason.timeout))
        let service = PricingCatalogSyncService(fileURL: fileURL, transport: transport)
        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .failed(let r1) = service.stage else { throw HarnessFailure(message: "timeout") }
        try expectEqual(r1, .timeout)

        // 2. Offline
        transport.result = .failure(PricingSyncFailureReason.offline)
        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .failed(let r2) = service.stage else { throw HarnessFailure(message: "offline") }
        try expectEqual(r2, .offline)

        // 3. HTTP 404
        transport.result = .failure(PricingSyncFailureReason.httpError(statusCode: 404))
        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .failed(let r3) = service.stage else { throw HarnessFailure(message: "404") }
        try expectEqual(r3, .httpError(statusCode: 404))

        // 4. Invalid JSON
        transport.result = .success("not-json".data(using: .utf8)!)
        service.syncNow()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .failed(let r4) = service.stage else { throw HarnessFailure(message: "invalid") }
        try expectEqual(r4, .invalidCatalog)
    }

    static func testRestoreBuiltin() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")
        try "dummy".write(to: fileURL, atomically: true, encoding: .utf8)

        var notified = false
        let service = PricingCatalogSyncService(fileURL: fileURL)
        service.onCatalogUpdated = { notified = true }

        service.restoreBuiltin()
        guard case .restored = service.stage else {
            throw HarnessFailure(message: "Expected restored stage")
        }
        try expect(!FileManager.default.fileExists(atPath: fileURL.path), "已删除本地同步文件")
        try expectEqual(BuiltinModelPricingCatalog.currentSource, .builtin, "已恢复为内置基线")
        try expect(notified, "触发了刷新通知")
    }

    static func testAutoSyncScheduleAndSilentFailure() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("pricing-catalog.json")

        var simNow = Date(timeIntervalSince1970: 1785200000)
        let transport = MockPricingTransport(result: .failure(PricingSyncFailureReason.timeout))
        let service = PricingCatalogSyncService(
            fileURL: fileURL,
            transport: transport,
            now: { simNow }
        )

        service.start()
        defer { service.stop() }

        // At launch, autoSyncTick() shouldn't run before 30s delay
        await service.autoSyncTick()
        try expectEqual(service.stage, .idle)

        // Advance 31s
        simNow = simNow.addingTimeInterval(31)
        await service.autoSyncTick()
        // Failure must be silent! stage stays .idle!
        try expectEqual(service.stage, .idle, "自动同步失败必须完全静默, stage 保持 idle")

        // Switch to success
        let okJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-10",
          "models": [
            {"model": "k3-agent", "displayName": "K3", "vendor": "Kimi", "input": 3, "output": 15, "listed": true}
          ]
        }
        """.data(using: .utf8)!
        transport.result = .success(okJSON)

        // 24 hours later
        simNow = simNow.addingTimeInterval(24 * 3600 + 1)
        await service.autoSyncTick()
        guard case .updated = service.stage else {
            throw HarnessFailure(message: "Expected auto sync to update, got \(service.stage)")
        }
    }

    static func testParityWithFixture(repoRoot: URL) throws -> Int {
        let fixtureURL = repoRoot.appendingPathComponent("tests/fixtures/pricing-sync-parity/cases.json")
        let data = try Data(contentsOf: fixtureURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        var assertions = 0

        // 1. Rows
        let rows = root["rows"] as? [String: String] ?? [:]
        try expectEqual(PricingCopy.caption, rows["caption"])
        try expectEqual(PricingCopy.autoSyncTitle, rows["autoSyncTitle"])
        try expectEqual(PricingCopy.autoSyncSubtitle, rows["autoSyncSubtitle"])
        try expectEqual(PricingCopy.currentCatalogTitle, rows["currentCatalogTitle"])
        try expectEqual(PricingCopy.syncCatalogTitle, rows["syncCatalogTitle"])
        try expectEqual(PricingCopy.syncButton, rows["syncButton"])
        try expectEqual(PricingCopy.restoreButton, rows["restoreButton"])
        assertions += 7

        // 2. Current catalog
        let currentCatalogs = root["currentCatalog"] as? [[String: Any]] ?? []
        for item in currentCatalogs {
            let source = (item["source"] as? String) == "builtin" ? PricingCatalogSource.builtin : .synced
            let count = item["modelCount"] as? Int ?? 0
            let expected = item["expectedSubtitle"] as? String ?? ""
            let actual = PricingCatalogPresentation.currentCatalogSubtitle(source: source, modelCount: count)
            try expectEqual(actual, expected)
            assertions += 1
        }

        // 3. Last sync
        let now = ISO8601DateFormatter().date(from: "2026-10-31T14:30:00+08:00")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        let lastSyncs = root["lastSync"] as? [[String: Any]] ?? []
        for item in lastSyncs {
            let atStr = item["at"] as? String
            let date = atStr.flatMap { ISO8601DateFormatter().date(from: $0) }
            let expected = item["expected"] as? String ?? ""
            let actual = PricingCatalogPresentation.lastSyncSubtitle(date, now: now, calendar: cal)
            try expectEqual(actual, expected)
            assertions += 1
        }

        // 4. Stages
        let stages = root["stages"] as? [[String: Any]] ?? []
        for item in stages {
            let phase = item["phase"] as? [String: Any] ?? [:]
            let kind = phase["kind"] as? String ?? ""
            let stage: PricingSyncStage

            switch kind {
            case "idle":
                stage = .idle
            case "syncing":
                stage = .syncing
            case "upToDate":
                stage = .upToDate(
                    updatedAt: phase["updatedAt"] as? String ?? "",
                    modelCount: phase["modelCount"] as? Int ?? 0
                )
            case "updated":
                stage = .updated(
                    updatedAt: phase["updatedAt"] as? String ?? "",
                    modelCount: phase["modelCount"] as? Int ?? 0,
                    addedCount: phase["addedCount"] as? Int ?? 0,
                    adjustedCount: phase["adjustedCount"] as? Int ?? 0
                )
            case "restored":
                stage = .restored(
                    updatedAt: phase["updatedAt"] as? String ?? "",
                    modelCount: phase["modelCount"] as? Int ?? 0
                )
            case "failed":
                let reasonStr = phase["reason"] as? String ?? ""
                let reason: PricingSyncFailureReason
                switch reasonStr {
                case "timeout": reason = .timeout
                case "offline": reason = .offline
                case "http_error": reason = .httpError(statusCode: phase["statusCode"] as? Int ?? 404)
                case "invalid_catalog": reason = .invalidCatalog
                case "stale_version": reason = .staleVersion
                default: fatalError("unknown reason \(reasonStr)")
                }
                stage = .failed(reason: reason)
            default:
                fatalError("unknown kind \(kind)")
            }

            let display = PricingCatalogPresentation.stageDisplay(for: stage)
            let exp = item["expected"] as? [String: Any] ?? [:]
            let expKind = exp["kind"] as? String ?? ""

            switch (display, expKind) {
            case (.hidden, "hidden"):
                break
            case (.spinner(let text), "spinner"):
                try expectEqual(text, exp["text"] as? String ?? "")
            case (.confirmation(let text), "confirmation"):
                try expectEqual(text, exp["text"] as? String ?? "")
            case (.failure(let title, let detail, let statusLine), "failure"):
                try expectEqual(title, exp["title"] as? String ?? "")
                try expectEqual(detail, exp["detail"] as? String ?? "")
                try expectEqual(statusLine, exp["statusLine"] as? String ?? "")
            default:
                throw HarnessFailure(message: "Mismatch in stage display for \(kind): got \(display), expected \(expKind)")
            }

            let expSync = item["syncEnabled"] as? Bool ?? true
            let expRestore = item["restoreEnabled"] as? Bool ?? true
            try expectEqual(PricingCatalogPresentation.isSyncButtonEnabled(for: stage), expSync)
            try expectEqual(PricingCatalogPresentation.isRestoreButtonEnabled(for: stage), expRestore)
            assertions += 3
        }

        return assertions
    }

    static func testCollectorRunInputInjection() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configStore = try OnboardingConfigurationStore(
            configDirectory: tempDir,
            fileManager: .default
        )
        var config = OnboardingConfiguration()
        config.consentVersion = 1
        config.keychainAccessConfigured = true
        try configStore.save(config)

        let credentialStore = InMemoryCredentialStore()
        let provider = OnboardingRunInputProvider(
            configStore: configStore,
            credentialStore: credentialStore
        )

        // Builtin state -> context["pricingCatalog"] is nil
        BuiltinModelPricingCatalog.resetToBuiltin()
        let inputBuiltin = try await provider.runInput(for: .agentUsage)
        try expect(inputBuiltin.context["pricingCatalog"] == nil, "内置基线状态时不注入 pricingCatalog")

        // Synced state -> context["pricingCatalog"] is populated
        let syncedJSON = """
        {
          "schemaVersion": 1,
          "updatedAt": "2026-11-20",
          "models": [
            {"model": "m-dyn", "displayName": "Dyn", "vendor": "V", "input": 1, "output": 2, "listed": true}
          ]
        }
        """.data(using: .utf8)!
        let parsed = try BuiltinModelPricingCatalog.validateAndParse(data: syncedJSON, source: .synced)
        BuiltinModelPricingCatalog.setActiveCatalog(parsed)

        let inputSynced = try await provider.runInput(for: .agentUsage)
        try expect(inputSynced.context["pricingCatalog"] != nil, "已同步状态注入 pricingCatalog")

        // Cleanup
        BuiltinModelPricingCatalog.resetToBuiltin()
    }

    private static func resolveRepoRoot() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PricingCatalogSyncHarness.swift -> PricingCatalogSyncHarness/
            .deletingLastPathComponent() // -> Harnesses/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> macos/
            .deletingLastPathComponent() // -> apps/
            .deletingLastPathComponent() // -> repoRoot
    }
}

