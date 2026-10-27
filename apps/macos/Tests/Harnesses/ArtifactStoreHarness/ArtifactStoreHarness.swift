import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

private enum StoreTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func storeExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw StoreTestFailure.expectation(message)
    }
}

@main
@MainActor
struct ArtifactStoreHarness {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw StoreTestFailure.expectation("expected repository root")
        }
        let repository = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        )
        try validatesVersionedArtifacts(repository: repository)
        try writesPrivateAtomicSnapshots(repository: repository)
        try fallsBackAfterCorruptionAndWriteFailure(repository: repository)
        try migratesAndRejectsUnknownSchemas(repository: repository)
        try clearCachesRemovesSnapshotsAndStaysUsable(repository: repository)
        try validatesCalendarDaysStrictlyAndQuickly(repository: repository)
        try verifiedSnapshotCacheFollowsDiskBytes(repository: repository)
        print("ArtifactStore tests passed: 7")
    }

    /// C106: 逐日校验语义与旧「非宽松 DateFormatter + 回写比对」一致, 且 182 天 ×
    /// 10 agent 的满尺寸 artifact 单次校验不再耗时数百毫秒.
    private static func validatesCalendarDaysStrictlyAndQuickly(
        repository: URL
    ) throws {
        for valid in ["2026-07-28", "2024-02-29", "2000-02-29", "0001-01-01", "2026-12-31"] {
            try storeExpect(CalendarDay.isValid(valid), "valid day rejected: \(valid)")
        }
        for invalid in [
            "", "2026-7-28", "2026-07-8", "2026-02-29", "1900-02-29", "2026-02-30",
            "2026-04-31", "2026-13-01", "2026-00-10", "2026-01-00", "0000-01-01",
            " 2026-07-28", "2026-07-28 ", "2026/07/28", "２０２６-07-28", "20260728xx",
        ] {
            try storeExpect(!CalendarDay.isValid(invalid), "invalid day accepted: \(invalid)")
        }

        let validator = ArtifactValidator()
        var invalidDay = try fixture(repository: repository, module: .agentUsage)
        if case .object(var object) = invalidDay,
           case .array(var agents)? = object["agents"],
           case .object(var agent)? = agents.first,
           case .array(var daily)? = agent["daily"],
           case .object(var day)? = daily.first {
            day["date"] = .string("2026-02-30")
            daily[0] = .object(day)
            agent["daily"] = .array(daily)
            agents[0] = .object(agent)
            object["agents"] = .array(agents)
            invalidDay = .object(object)
        }
        do {
            _ = try validator.validate(invalidDay, for: .agentUsage)
            throw StoreTestFailure.expectation("impossible calendar day accepted")
        } catch ArtifactValidationError.invalidValue {
        }

        // 满尺寸 artifact: 与生产请求同口径 (days=182, 10 个 agent).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 4, day: 28))!
        let dates = (0..<182).map { offset -> String in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }
        let daily = JSONValue.array(dates.map { date in
            .object(["date": .string(date), "input": .integer(1), "output": .integer(1), "total": .integer(2)])
        })
        let zeroBucket = JSONValue.object([
            "input": .integer(0), "output": .integer(0), "cacheRead": .integer(0),
            "cacheCreation": .integer(0), "total": .integer(0),
        ])
        let agents = JSONValue.array((0..<10).map { index in
            .object([
                "id": .string("agent-\(index)"), "name": .string("Agent \(index)"),
                "status": .string("ok"), "note": .null, "today": zeroBucket,
                "daily": daily, "hours": .array(Array(repeating: .integer(0), count: 24)),
                "todayCostUsd": .null,
            ])
        })
        let large = JSONValue.object([
            "schemaVersion": .integer(1), "module": .string("agent-usage"),
            "generatedAt": .string("2026-10-26T00:00:00Z"), "agents": agents,
            "services": .array([]), "totalCostUsd": .null,
        ])
        let started = Date()
        _ = try validator.validate(large, for: .agentUsage)
        let elapsed = Date().timeIntervalSince(started)
        try storeExpect(
            elapsed < 0.25,
            "full-size artifact validation took \(Int(elapsed * 1000)) ms (expected < 250 ms)"
        )
    }

    /// C121: 已校验快照缓存只在磁盘字节完全一致时复用; 外部改写立即重新读取,
    /// 不合格的当前快照仍不得轮换为 previous; 不再写 .backup.json 并清理旧版遗留.
    private static func verifiedSnapshotCacheFollowsDiskBytes(
        repository: URL
    ) throws {
        let root = try temporaryRoot("verified-cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(rootURL: root)
        let base = try fixture(repository: repository, module: .agentUsage)
        func variant(_ login: String) -> JSONValue {
            guard case .object(var object) = base else { return base }
            object["login"] = .string(login)
            return .object(object)
        }
        let currentURL = store.snapshotURL(for: .agentUsage)
        let previousURL = store.previousSnapshotURL(for: .agentUsage)
        let staleBackup = store.snapshotsURL
            .appendingPathComponent("agent-usage.json.backup.json")

        try store.publish(variant("a"), for: .agentUsage)
        try Data("{}".utf8).write(to: staleBackup)
        try store.publish(variant("b"), for: .agentUsage)
        try storeExpect(
            !FileManager.default.fileExists(atPath: staleBackup.path),
            "publish should drop the redundant .backup.json"
        )
        let previous = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: previousURL))
        try storeExpect(previous == variant("a"), "previous should hold the prior snapshot")
        let cached = try store.load(.agentUsage)
        try storeExpect(cached.artifact == variant("b"), "cached load")

        // 外部改写为另一份合格快照: 字节变化, 必须重新读取
        try JSONEncoder().encode(variant("external")).write(to: currentURL)
        let reloaded = try store.load(.agentUsage)
        try storeExpect(
            reloaded.source == .current && reloaded.artifact == variant("external"),
            "external rewrite must not be masked by the cache"
        )
        try store.publish(variant("c"), for: .agentUsage)
        let rotated = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: previousURL))
        try storeExpect(rotated == variant("external"), "verified external snapshot rotates to previous")

        // 可解析但不合格 (含敏感字段) 的当前快照: 不得轮换为 previous
        guard case .object(var tainted) = variant("tainted"),
              case .array(var agents)? = tainted["agents"],
              case .object(var agent)? = agents.first else {
            throw StoreTestFailure.expectation("fixture has no agents")
        }
        agent["nested"] = .array([.object(["apiKey": .string("x")])])
        agents[0] = .object(agent)
        tainted["agents"] = .array(agents)
        do {
            _ = try ArtifactValidator().validate(.object(tainted), for: .agentUsage)
            throw StoreTestFailure.expectation("nested sensitive key accepted")
        } catch ArtifactValidationError.sensitiveField {
        }
        try JSONEncoder().encode(JSONValue.object(tainted)).write(to: currentURL)
        try store.publish(variant("d"), for: .agentUsage)
        let kept = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: previousURL))
        try storeExpect(kept == variant("external"), "invalid current snapshot must not become previous")
        let latest = try store.load(.agentUsage)
        try storeExpect(latest.artifact == variant("d"), "latest publish is current")
    }

    private static func fixture(
        repository: URL,
        module: CollectorModule,
        variant: String = "valid",
        versioned: Bool = true
    ) throws -> JSONValue {
        let url = repository
            .appendingPathComponent("tests/fixtures/artifacts")
            .appendingPathComponent(module.rawValue)
            .appendingPathComponent("\(variant).json")
        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: url)
        ) as? [String: Any]
        guard var artifact = root?["artifact"] as? [String: Any] else {
            throw StoreTestFailure.expectation("fixture has no artifact")
        }
        if versioned {
            artifact["schemaVersion"] = 1
            artifact["module"] = module.rawValue
        }
        return try JSONDecoder().decode(
            JSONValue.self,
            from: JSONSerialization.data(
                withJSONObject: artifact,
                options: [.sortedKeys]
            )
        )
    }

    private static func temporaryRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Bruce-store-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private static func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func validatesVersionedArtifacts(
        repository: URL
    ) throws {
        let validator = ArtifactValidator()
        for module in CollectorModule.allCases {
            for variant in ["valid", "partial", "empty"] {
                let artifact = try fixture(
                    repository: repository,
                    module: module,
                    variant: variant
                )
                _ = try validator.validate(artifact, for: module)
            }
        }

        var wrongModule = try fixture(
            repository: repository,
            module: .agentUsage
        )
        if case .object(var object) = wrongModule {
            object["module"] = .string("other-module")
            wrongModule = .object(object)
        }
        do {
            _ = try validator.validate(wrongModule, for: .agentUsage)
            throw StoreTestFailure.expectation("module mismatch accepted")
        } catch ArtifactValidationError.moduleMismatch {
        }

        var sensitive = try fixture(
            repository: repository,
            module: .agentUsage
        )
        if case .object(var object) = sensitive {
            object["access_token"] = .string("fixture-secret")
            sensitive = .object(object)
        }
        do {
            _ = try validator.validate(sensitive, for: .agentUsage)
            throw StoreTestFailure.expectation("sensitive artifact accepted")
        } catch ArtifactValidationError.sensitiveField {
        }
    }

    private static func writesPrivateAtomicSnapshots(
        repository: URL
    ) throws {
        let root = try temporaryRoot("private")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(rootURL: root)
        let artifact = try fixture(
            repository: repository,
            module: .agentUsage
        )
        let successDate = Date(timeIntervalSince1970: 1_786_000_000)
        try store.publish(
            artifact,
            for: .agentUsage,
            attemptedAt: successDate
        )

        let rootPermissions = try permissions(root)
        let snapshotDirectoryPermissions = try permissions(store.snapshotsURL)
        let snapshotPermissions = try permissions(
            store.snapshotURL(for: .agentUsage)
        )
        let metadataPermissions = try permissions(store.metadataURL)
        try storeExpect(
            rootPermissions == 0o700,
            "Application Support root is not private"
        )
        try storeExpect(
            snapshotDirectoryPermissions == 0o700,
            "snapshot directory is not private"
        )
        try storeExpect(
            snapshotPermissions == 0o600,
            "snapshot file is not private"
        )
        try storeExpect(
            metadataPermissions == 0o600,
            "metadata file is not private"
        )

        let fresh = try store.load(
            .agentUsage,
            now: successDate.addingTimeInterval(1_800),
            staleAfter: 3_600
        )
        try storeExpect(!fresh.metadata.isStale, "fresh snapshot is stale")
        try store.recordAttempt(
            for: .agentUsage,
            at: successDate.addingTimeInterval(2_000),
            errorCategory: .network
        )
        let failedAttempt = try store.load(
            .agentUsage,
            now: successDate.addingTimeInterval(2_100),
            staleAfter: 3_600
        )
        try storeExpect(
            failedAttempt.metadata.errorCategory == .network,
            "last attempt error was not retained"
        )
        try storeExpect(
            failedAttempt.metadata.lastSuccessAt
                == fresh.metadata.lastSuccessAt,
            "failed attempt replaced last success"
        )
    }

    private static func fallsBackAfterCorruptionAndWriteFailure(
        repository: URL
    ) throws {
        let root = try temporaryRoot("fallback")
        defer { try? FileManager.default.removeItem(at: root) }
        let baselineStore = try ArtifactStore(rootURL: root)
        let first = try fixture(
            repository: repository,
            module: .agentUsage
        )
        var second = first
        if case .object(var object) = second {
            object["login"] = .string("second-fixture")
            second = .object(object)
        }
        try baselineStore.publish(first, for: .agentUsage)
        try baselineStore.publish(second, for: .agentUsage)
        try Data("{corrupted".utf8).write(
            to: baselineStore.snapshotURL(for: .agentUsage)
        )

        let fallback = try baselineStore.load(.agentUsage)
        try storeExpect(
            fallback.source == .previous,
            "corrupt current snapshot did not use previous success"
        )
        try storeExpect(
            fallback.artifact == first,
            "fallback did not preserve the previous artifact"
        )
        try storeExpect(
            fallback.metadata.isStale,
            "fallback snapshot was not marked stale"
        )

        let currentBeforeFailure = try Data(
            contentsOf: baselineStore.snapshotURL(for: .agentUsage)
        )
        let failingStore = try ArtifactStore(
            rootURL: root,
            faultInjector: { stage in
                if stage == .beforeReplace {
                    throw StoreTestFailure.expectation("injected replace failure")
                }
            }
        )
        do {
            try failingStore.publish(first, for: .agentUsage)
            throw StoreTestFailure.expectation("replace failure was ignored")
        } catch ArtifactStoreError.storageFailure {
        }
        let currentAfterFailure = try Data(
            contentsOf: baselineStore.snapshotURL(for: .agentUsage)
        )
        try storeExpect(
            currentBeforeFailure == currentAfterFailure,
            "failed replace changed the current snapshot"
        )
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            atPath: baselineStore.snapshotsURL.path
        ).filter { $0.hasSuffix(".tmp") }
        try storeExpect(
            temporaryFiles.isEmpty,
            "failed write left temporary files"
        )
    }

    private static func migratesAndRejectsUnknownSchemas(
        repository: URL
    ) throws {
        let migrationRoot = try temporaryRoot("migration")
        defer { try? FileManager.default.removeItem(at: migrationRoot) }
        let store = try ArtifactStore(rootURL: migrationRoot)
        let v0 = try fixture(
            repository: repository,
            module: .agentUsage,
            versioned: false
        )
        let v0Data = try JSONEncoder().encode(v0)
        try v0Data.write(to: store.snapshotURL(for: .agentUsage))
        let migrated = try store.load(.agentUsage)
        try storeExpect(
            migrated.source == .migrated,
            "v0 snapshot was not migrated"
        )
        let migrationBackup = try Data(
            contentsOf: store.migrationBackupURL(for: .agentUsage)
        )
        try storeExpect(
            migrationBackup == v0Data,
            "migration did not preserve a rollback copy"
        )

        let failedRoot = try temporaryRoot("migration-failure")
        defer { try? FileManager.default.removeItem(at: failedRoot) }
        let failedStore = try ArtifactStore(
            rootURL: failedRoot,
            faultInjector: { stage in
                if stage == .beforeMigrationReplace {
                    throw StoreTestFailure.expectation(
                        "injected migration failure"
                    )
                }
            }
        )
        try v0Data.write(to: failedStore.snapshotURL(for: .agentUsage))
        let beforeMigration = try Data(
            contentsOf: failedStore.snapshotURL(for: .agentUsage)
        )
        do {
            _ = try failedStore.load(.agentUsage)
            throw StoreTestFailure.expectation("migration failure was ignored")
        } catch ArtifactStoreError.migrationFailed {
        }
        let afterFailedMigration = try Data(
            contentsOf: failedStore.snapshotURL(for: .agentUsage)
        )
        try storeExpect(
            afterFailedMigration == beforeMigration,
            "failed migration changed the original snapshot"
        )

        let unknownRoot = try temporaryRoot("unknown")
        defer { try? FileManager.default.removeItem(at: unknownRoot) }
        let unknownStore = try ArtifactStore(rootURL: unknownRoot)
        var unknown = try fixture(
            repository: repository,
            module: .agentUsage
        )
        if case .object(var object) = unknown {
            object["schemaVersion"] = .integer(99)
            unknown = .object(object)
        }
        let unknownData = try JSONEncoder().encode(unknown)
        try unknownData.write(to: unknownStore.snapshotURL(for: .agentUsage))
        do {
            _ = try unknownStore.load(.agentUsage)
            throw StoreTestFailure.expectation("unknown schema was accepted")
        } catch ArtifactStoreError.unknownSchema(let version) {
            try storeExpect(version == 99, "unknown version changed")
        }
        let afterUnknownLoad = try Data(
            contentsOf: unknownStore.snapshotURL(for: .agentUsage)
        )
        try storeExpect(
            afterUnknownLoad == unknownData,
            "unknown schema snapshot was modified"
        )
    }

    private static func clearCachesRemovesSnapshotsAndStaysUsable(
        repository: URL
    ) throws {
        let root = try temporaryRoot("clear")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ArtifactStore(rootURL: root)
        let artifact = try fixture(repository: repository, module: .agentUsage)
        try store.publish(artifact, for: .agentUsage)
        try store.clearSnapshotCaches()
        do {
            _ = try store.load(.agentUsage)
            throw StoreTestFailure.expectation("cleared snapshot still loads")
        } catch ArtifactStoreError.noSnapshot {
        }
        // 清理后目录已重建且可再次发布 (下次刷新自动重建语义).
        try store.publish(artifact, for: .agentUsage)
        let reloaded = try store.load(.agentUsage)
        try storeExpect(
            reloaded.artifact == artifact,
            "republish after clear failed"
        )
        let rebuiltPermissions = try permissions(store.snapshotsURL)
        try storeExpect(
            rebuiltPermissions == 0o700,
            "rebuilt snapshot directory is not private"
        )
    }
}
