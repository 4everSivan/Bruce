import Foundation
import BruceOnboardingCore

package enum SnapshotErrorCategory: String, Codable, Equatable, Sendable {
    case auth
    case dependency
    case network
    case rateLimit
    case schema
    case collector
    case storage
    case cancelled
}

struct ModuleSnapshotMetadata: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let artifactSchemaVersion: Int
    let module: CollectorModule
    var lastSuccessAt: String?
    var lastAttemptAt: String?
    var isStale: Bool
    var errorCategory: SnapshotErrorCategory?
}

private struct ArtifactStoreMetadata: Codable {
    let schemaVersion: Int
    var modules: [String: ModuleSnapshotMetadata]

    static let empty = ArtifactStoreMetadata(
        schemaVersion: 1,
        modules: [:]
    )
}

enum SnapshotSource: Equatable, Sendable {
    case current
    case previous
    case migrated
}

struct StoredArtifact: Equatable, Sendable {
    let artifact: JSONValue
    let decoded: DecodedArtifact
    let metadata: ModuleSnapshotMetadata
    let source: SnapshotSource
}

enum ArtifactStoreStage: Equatable {
    case beforeWrite
    case beforeReplace
    case beforeMetadataReplace
    case beforeMigrationReplace
}

enum ArtifactStoreError: Error, Equatable {
    case noSnapshot
    case corruptedSnapshot
    case unknownSchema(Int)
    case migrationFailed
    case storageFailure
}

@MainActor
package final class ArtifactStore {
    typealias FaultInjector = (ArtifactStoreStage) throws -> Void

    /// Artifact 根目录 (Application Support/Bruce 或测试注入目录).
    /// DeepSeek 月度账本等衍生存储以它为根隔离.
    package let rootURL: URL
    let snapshotsURL: URL
    let metadataURL: URL

    private let fileManager: FileManager
    private let validator: ArtifactValidator
    private let faultInjector: FaultInjector?
    private let atomicStore: AtomicJSONStore

    package convenience init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ArtifactStoreError.storageFailure
        }
        try self.init(
            rootURL: applicationSupport.appendingPathComponent(
                "Bruce",
                isDirectory: true
            )
        )
    }

    package convenience init(rootURL: URL) throws {
        try self.init(
            rootURL: rootURL,
            fileManager: .default,
            validator: ArtifactValidator(),
            faultInjector: nil
        )
    }

    init(
        rootURL: URL,
        fileManager: FileManager = .default,
        validator: ArtifactValidator = ArtifactValidator(),
        faultInjector: FaultInjector? = nil
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        snapshotsURL = self.rootURL.appendingPathComponent(
            "snapshots",
            isDirectory: true
        )
        metadataURL = self.rootURL
            .appendingPathComponent("metadata", isDirectory: true)
            .appendingPathComponent("modules.json")
        self.fileManager = fileManager
        self.validator = validator
        self.faultInjector = faultInjector
        self.atomicStore = AtomicJSONStore(
            fileManager: fileManager,
            faultInjector: faultInjector.map { inject in
                { stage in try inject(Self.stage(for: stage)) }
            }
        )
        try prepareDirectories()
    }

    func publish(
        _ artifact: JSONValue,
        for module: CollectorModule,
        attemptedAt: Date = Date()
    ) throws {
        _ = try validator.validate(artifact, for: module)
        let data = try JSONEncoder().encode(artifact)
        let currentURL = snapshotURL(for: module)
        let previousURL = previousSnapshotURL(for: module)

        if fileManager.fileExists(atPath: currentURL.path),
           let currentData = try? Data(contentsOf: currentURL),
           let currentArtifact = try? JSONDecoder().decode(
               JSONValue.self,
               from: currentData
           ),
           (try? validator.validate(currentArtifact, for: module)) != nil {
            try atomicStoreWrite(
                currentData,
                to: previousURL,
                stage: .beforeReplace
            )
        }
        try atomicStoreWrite(
            data,
            to: currentURL,
            validate: { [validator] reread in
                let value = try JSONDecoder().decode(
                    JSONValue.self,
                    from: reread
                )
                _ = try validator.validate(value, for: module)
            },
            backupPrevious: true,
            stage: .beforeReplace
        )

        var metadata = try readMetadata()
        let timestamp = Self.timestamp(attemptedAt)
        metadata.modules[module.rawValue] = ModuleSnapshotMetadata(
            schemaVersion: 1,
            artifactSchemaVersion: ArtifactValidator.currentSchemaVersion,
            module: module,
            lastSuccessAt: timestamp,
            lastAttemptAt: timestamp,
            isStale: false,
            errorCategory: nil
        )
        try writeMetadata(metadata)
    }

    func recordAttempt(
        for module: CollectorModule,
        at date: Date = Date(),
        errorCategory: SnapshotErrorCategory?
    ) throws {
        var metadata = try readMetadata()
        var moduleMetadata = metadata.modules[module.rawValue]
            ?? ModuleSnapshotMetadata(
                schemaVersion: 1,
                artifactSchemaVersion: ArtifactValidator.currentSchemaVersion,
                module: module,
                lastSuccessAt: nil,
                lastAttemptAt: nil,
                isStale: true,
                errorCategory: nil
            )
        moduleMetadata.lastAttemptAt = Self.timestamp(date)
        moduleMetadata.errorCategory = errorCategory
        if moduleMetadata.lastSuccessAt == nil {
            moduleMetadata.isStale = true
        }
        metadata.modules[module.rawValue] = moduleMetadata
        try writeMetadata(metadata)
    }

    func load(
        _ module: CollectorModule,
        now: Date = Date(),
        staleAfter: TimeInterval = 3600
    ) throws -> StoredArtifact {
        let currentURL = snapshotURL(for: module)
        do {
            let loaded = try loadArtifact(at: currentURL, for: module)
            return try storedArtifact(
                loaded.artifact,
                decoded: loaded.decoded,
                module: module,
                source: loaded.source,
                now: now,
                staleAfter: staleAfter,
                fallbackError: nil
            )
        } catch let error as ArtifactStoreError {
            let previousURL = previousSnapshotURL(for: module)
            if fileManager.fileExists(atPath: previousURL.path) {
                do {
                    let previous = try loadArtifact(
                        at: previousURL,
                        for: module,
                        allowMigration: false
                    )
                    return try storedArtifact(
                        previous.artifact,
                        decoded: previous.decoded,
                        module: module,
                        source: .previous,
                        now: now,
                        staleAfter: staleAfter,
                        fallbackError: .schema
                    )
                } catch {
                    // previous 也损坏/不兼容: 尝试从备份回滚一次.
                    if atomicStore.rollback(currentURL) == .rolledBack,
                       let rolledBack = try? loadArtifact(
                           at: currentURL,
                           for: module,
                           allowMigration: false
                       ) {
                        return try storedArtifact(
                            rolledBack.artifact,
                            decoded: rolledBack.decoded,
                            module: module,
                            source: .previous,
                            now: now,
                            staleAfter: staleAfter,
                            fallbackError: .schema
                        )
                    }
                    throw error
                }
            }
            throw error
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }
    }

    func snapshotURL(for module: CollectorModule) -> URL {
        snapshotsURL.appendingPathComponent("\(module.rawValue).json")
    }

    func previousSnapshotURL(for module: CollectorModule) -> URL {
        snapshotsURL.appendingPathComponent(
            "\(module.rawValue).previous.json"
        )
    }

    func migrationBackupURL(for module: CollectorModule) -> URL {
        snapshotsURL.appendingPathComponent(
            "\(module.rawValue).schema-v0.backup.json"
        )
    }

    package func diagnosticSnapshotSummary(
        for module: CollectorModule
    ) -> DiagnosticSnapshotSummary {
        let metadata = (try? readMetadata()).flatMap {
            $0.modules[module.rawValue]
        }
        return DiagnosticSnapshotSummary(
            module: module.rawValue,
            current: diagnosticValidation(
                at: snapshotURL(for: module),
                module: module
            ),
            previous: diagnosticValidation(
                at: previousSnapshotURL(for: module),
                module: module
            ),
            lastSuccessAt: metadata?.lastSuccessAt,
            lastAttemptAt: metadata?.lastAttemptAt,
            isStale: metadata?.isStale ?? true,
            errorCategory: metadata?.errorCategory?.rawValue
        )
    }

    private func diagnosticValidation(
        at url: URL,
        module: CollectorModule
    ) -> DiagnosticSnapshotValidation {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: url)
            let artifact = try JSONDecoder().decode(
                JSONValue.self,
                from: data
            )
            _ = try validator.validate(artifact, for: module)
            return .valid
        } catch ArtifactValidationError.unsupportedSchema {
            return .unsupportedSchema
        } catch {
            return .invalid
        }
    }

    /// 清理可再生缓存: 快照目录与元数据文件, 下次刷新自动重建.
    /// 只触碰本应用 Application Support/Bruce 下的 snapshots 与 metadata,
    /// 不影响配置, Keychain 凭证和 DeepSeek 月度账本.
    package func clearSnapshotCaches() throws {
        do {
            if fileManager.fileExists(atPath: snapshotsURL.path) {
                try fileManager.removeItem(at: snapshotsURL)
            }
            if fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.removeItem(at: metadataURL)
            }
            try prepareDirectories()
        } catch {
            throw ArtifactStoreError.storageFailure
        }
    }

    /// 统一桥接 `AtomicJSONStore.write`: 将底层 `AtomicJSONStoreError`
    /// 收敛为 `ArtifactStoreError.storageFailure`, 与重构前 `atomicWrite`
    /// 的「任意错误 -> storageFailure」语义一致 (Harness 据此断言).
    private func atomicStoreWrite(
        _ data: Data,
        to targetURL: URL,
        validate: ((Data) throws -> Void)? = nil,
        backupPrevious: Bool = false,
        stage: AtomicJSONStore.WriteStage = .beforeReplace
    ) throws {
        do {
            try atomicStore.write(
                data,
                to: targetURL,
                validate: validate,
                backupPrevious: backupPrevious,
                stage: stage
            )
        } catch is AtomicJSONStore.AtomicJSONStoreError {
            throw ArtifactStoreError.storageFailure
        }
    }

    private func prepareDirectories() throws {
        try atomicStore.prepareDirectory(at: rootURL)
        try atomicStore.prepareDirectory(at: snapshotsURL)
        try atomicStore.prepareDirectory(at: metadataURL.deletingLastPathComponent())
    }

    private func readMetadata() throws -> ArtifactStoreMetadata {
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: metadataURL)
            let metadata = try JSONDecoder().decode(
                ArtifactStoreMetadata.self,
                from: data
            )
            guard metadata.schemaVersion == 1 else {
                throw ArtifactStoreError.unknownSchema(
                    metadata.schemaVersion
                )
            }
            return metadata
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }
    }

    private func writeMetadata(_ metadata: ArtifactStoreMetadata) throws {
        let data = try JSONEncoder().encode(metadata)
        try atomicStoreWrite(
            data,
            to: metadataURL,
            validate: { reread in
                _ = try JSONDecoder().decode(
                    ArtifactStoreMetadata.self,
                    from: reread
                )
            },
            stage: .beforeMetadataReplace
        )
    }

    private func loadArtifact(
        at url: URL,
        for module: CollectorModule,
        allowMigration: Bool = true
    ) throws -> (
        artifact: JSONValue,
        decoded: DecodedArtifact,
        source: SnapshotSource
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArtifactStoreError.noSnapshot
        }
        let data: Data
        let object: [String: Any]
        do {
            data = try Data(contentsOf: url)
            guard let decodedObject = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw ArtifactStoreError.corruptedSnapshot
            }
            object = decodedObject
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }

        let version = object["schemaVersion"] as? Int ?? 0
        if version > ArtifactValidator.currentSchemaVersion {
            throw ArtifactStoreError.unknownSchema(version)
        }
        if version == 0 {
            guard allowMigration else {
                throw ArtifactStoreError.unknownSchema(0)
            }
            return try migrateV0(
                originalData: data,
                object: object,
                at: url,
                module: module
            )
        }
        guard version == ArtifactValidator.currentSchemaVersion else {
            throw ArtifactStoreError.unknownSchema(version)
        }
        do {
            let artifact = try JSONDecoder().decode(
                JSONValue.self,
                from: data
            )
            return (
                artifact,
                try validator.validate(artifact, for: module),
                .current
            )
        } catch let error as ArtifactValidationError {
            if case .unsupportedSchema(let schema) = error {
                throw ArtifactStoreError.unknownSchema(schema)
            }
            throw ArtifactStoreError.corruptedSnapshot
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }
    }

    private func migrateV0(
        originalData: Data,
        object: [String: Any],
        at url: URL,
        module: CollectorModule
    ) throws -> (
        artifact: JSONValue,
        decoded: DecodedArtifact,
        source: SnapshotSource
    ) {
        var migratedObject = object
        migratedObject["schemaVersion"] = 1
        migratedObject["module"] = module.rawValue
        do {
            let migratedData = try JSONSerialization.data(
                withJSONObject: migratedObject,
                options: [.sortedKeys]
            )
            let artifact = try JSONDecoder().decode(
                JSONValue.self,
                from: migratedData
            )
            let decoded = try validator.validate(artifact, for: module)
            let backupURL = migrationBackupURL(for: module)
            if !fileManager.fileExists(atPath: backupURL.path) {
                try atomicStoreWrite(
                    originalData,
                    to: backupURL,
                    stage: .beforeReplace
                )
            }
            // 注意: 迁移写直接用 `atomicStore.write` (不经 `atomicStoreWrite` 收敛),
            // 让 `.beforeMigrationReplace` 故障注入抛出的错误透传为
            // `ArtifactStoreError.migrationFailed` (与重构前先 `try faultInjector?`
            // 再写的行为一致, Harness 据此断言).
            try atomicStore.write(
                migratedData,
                to: url,
                validate: { [validator] reread in
                    let value = try JSONDecoder().decode(
                        JSONValue.self,
                        from: reread
                    )
                    _ = try validator.validate(value, for: module)
                },
                stage: .beforeMigrationReplace
            )
            return (artifact, decoded, .migrated)
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.migrationFailed
        }
    }

    private func storedArtifact(
        _ artifact: JSONValue,
        decoded: DecodedArtifact,
        module: CollectorModule,
        source: SnapshotSource,
        now: Date,
        staleAfter: TimeInterval,
        fallbackError: SnapshotErrorCategory?
    ) throws -> StoredArtifact {
        let metadataFile = try readMetadata()
        var metadata = metadataFile.modules[module.rawValue]
            ?? ModuleSnapshotMetadata(
                schemaVersion: 1,
                artifactSchemaVersion: ArtifactValidator.currentSchemaVersion,
                module: module,
                lastSuccessAt: nil,
                lastAttemptAt: nil,
                isStale: true,
                errorCategory: nil
            )
        if let lastSuccessAt = metadata.lastSuccessAt,
           let successDate = ISO8601DateFormatter().date(
               from: lastSuccessAt
           ) {
            metadata.isStale = now.timeIntervalSince(successDate) > staleAfter
        } else {
            metadata.isStale = true
        }
        if source == .previous {
            metadata.isStale = true
            metadata.errorCategory = fallbackError
        }
        return StoredArtifact(
            artifact: artifact,
            decoded: decoded,
            metadata: metadata,
            source: source
        )
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// 将 `AtomicJSONStore` 的写阶段映射到本 store 的 `ArtifactStoreStage`,
    /// 供故障注入钩子透传到 Harness (二者用例一一对应).
    private static func stage(for stage: AtomicJSONStore.WriteStage) -> ArtifactStoreStage {
        switch stage {
        case .beforeTempWrite:
            return .beforeWrite
        case .beforeReplace:
            return .beforeReplace
        case .beforeMetadataReplace:
            return .beforeMetadataReplace
        case .beforeMigrationReplace:
            return .beforeMigrationReplace
        }
    }
}
