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
        print("ArtifactStore tests passed: 5")
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
