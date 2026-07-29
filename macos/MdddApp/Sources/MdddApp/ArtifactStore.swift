import Foundation
import MdddOnboardingCore

enum SnapshotErrorCategory: String, Codable, Equatable, Sendable {
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
final class ArtifactStore {
    typealias FaultInjector = (ArtifactStoreStage) throws -> Void

    let rootURL: URL
    let snapshotsURL: URL
    let metadataURL: URL

    private let fileManager: FileManager
    private let validator: ArtifactValidator
    private let faultInjector: FaultInjector?

    convenience init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ArtifactStoreError.storageFailure
        }
        try self.init(
            rootURL: applicationSupport.appendingPathComponent(
                "mddd",
                isDirectory: true
            )
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
            try atomicWrite(
                currentData,
                to: previousURL,
                validation: nil,
                replaceStage: .beforeReplace
            )
        }
        try atomicWrite(
            data,
            to: currentURL,
            validation: { [validator] reread in
                let value = try JSONDecoder().decode(
                    JSONValue.self,
                    from: reread
                )
                _ = try validator.validate(value, for: module)
            },
            replaceStage: .beforeReplace
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
            guard fileManager.fileExists(atPath: previousURL.path) else {
                throw error
            }
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
                throw error
            }
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

    private func prepareDirectories() throws {
        do {
            try createPrivateDirectory(rootURL)
            try createPrivateDirectory(snapshotsURL)
            try createPrivateDirectory(metadataURL.deletingLastPathComponent())
        } catch {
            throw ArtifactStoreError.storageFailure
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func atomicWrite(
        _ data: Data,
        to targetURL: URL,
        validation: ((Data) throws -> Void)?,
        replaceStage: ArtifactStoreStage
    ) throws {
        let temporaryURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
        do {
            try faultInjector?(.beforeWrite)
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw ArtifactStoreError.storageFailure
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            let reread = try Data(contentsOf: temporaryURL)
            try validation?(reread)
            try faultInjector?(replaceStage)
            if fileManager.fileExists(atPath: targetURL.path) {
                _ = try fileManager.replaceItemAt(
                    targetURL,
                    withItemAt: temporaryURL
                )
            } else {
                try fileManager.moveItem(
                    at: temporaryURL,
                    to: targetURL
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: targetURL.path
            )
        } catch let error as ArtifactStoreError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw ArtifactStoreError.storageFailure
        }
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
        try atomicWrite(
            data,
            to: metadataURL,
            validation: { reread in
                _ = try JSONDecoder().decode(
                    ArtifactStoreMetadata.self,
                    from: reread
                )
            },
            replaceStage: .beforeMetadataReplace
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
                try atomicWrite(
                    originalData,
                    to: backupURL,
                    validation: nil,
                    replaceStage: .beforeReplace
                )
            }
            try faultInjector?(.beforeMigrationReplace)
            try atomicWrite(
                migratedData,
                to: url,
                validation: { [validator] reread in
                    let value = try JSONDecoder().decode(
                        JSONValue.self,
                        from: reread
                    )
                    _ = try validator.validate(value, for: module)
                },
                replaceStage: .beforeReplace
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
}
