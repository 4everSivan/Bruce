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

    /// C121: 最近一次发布或读取成功的当前快照。磁盘字节与之逐字节相同即视为已校验,
    /// 发布与读取均不再整树解码 + 校验 (181 KB 真实 artifact 单次约 70 ms)。
    private struct VerifiedSnapshot {
        let data: Data
        let artifact: JSONValue
        let decoded: DecodedArtifact
    }

    private var verifiedSnapshots: [CollectorModule: VerifiedSnapshot] = [:]

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

    /// C261: 快照与元数据的磁盘持久化 (含 3 次 fsync) 在后台串行队列执行,
    /// 主线程只等待结果; 内存缓存 `verifiedSnapshots` 仍在 MainActor 侧更新。
    nonisolated private static let persistenceQueue = DispatchQueue(
        label: "io.bruce.artifact-store",
        qos: .utility
    )

    /// C261: 返回本轮已校验解码的对象, 供 Pipeline 直接交给 AppModel,
    /// 避免主线程用同一份 artifact 再编码 + 再解码。
    @discardableResult
    func publish(
        _ artifact: JSONValue,
        for module: CollectorModule,
        attemptedAt: Date = Date()
    ) async throws -> DecodedArtifact {
        let context = ArtifactStoreDiskContext(
            fileManager: fileManager,
            validator: validator,
            atomicStore: atomicStore,
            currentURL: snapshotURL(for: module),
            previousURL: previousSnapshotURL(for: module),
            metadataURL: metadataURL
        )
        let published: (data: Data, decoded: DecodedArtifact) =
            try await withCheckedThrowingContinuation { continuation in
                Self.persistenceQueue.async {
                    do {
                        continuation.resume(
                            returning: try ArtifactStoreDisk.publish(
                                artifact: artifact,
                                module: module,
                                attemptedAt: attemptedAt,
                                context: context
                            )
                        )
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        verifiedSnapshots[module] = VerifiedSnapshot(
            data: published.data,
            artifact: artifact,
            decoded: published.decoded
        )
        return published.decoded
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
        if let verified = verifiedSnapshots[module],
           let data = try? Data(contentsOf: currentURL),
           data == verified.data {
            return try storedArtifact(
                verified.artifact,
                decoded: verified.decoded,
                module: module,
                source: .current,
                now: now,
                staleAfter: staleAfter,
                fallbackError: nil
            )
        }
        verifiedSnapshots[module] = nil
        do {
            let loaded = try loadArtifact(at: currentURL, for: module)
            verifiedSnapshots[module] = VerifiedSnapshot(
                data: loaded.data,
                artifact: loaded.artifact,
                decoded: loaded.decoded
            )
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
            _ = try validator.validate(artifact, encoded: data, for: module)
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
        verifiedSnapshots.removeAll()
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
        source: SnapshotSource,
        data: Data
    ) {
        guard fileManager.fileExists(atPath: url.path) else {
            throw ArtifactStoreError.noSnapshot
        }
        // C121: 只解码一次 JSONValue (此前先 JSONSerialization 取版本号再 JSONDecoder 全量解码)
        let data: Data
        let artifact: JSONValue
        do {
            data = try Data(contentsOf: url)
            artifact = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }
        guard case .object(let fields) = artifact else {
            throw ArtifactStoreError.corruptedSnapshot
        }

        let version: Int
        switch fields["schemaVersion"] {
        case .integer(let value):
            version = value
        case .double(let value) where value == value.rounded():
            version = Int(value)
        default:
            version = 0
        }
        if version > ArtifactValidator.currentSchemaVersion {
            throw ArtifactStoreError.unknownSchema(version)
        }
        if version == 0 {
            guard allowMigration else {
                throw ArtifactStoreError.unknownSchema(0)
            }
            guard let object = try? JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw ArtifactStoreError.corruptedSnapshot
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
            return (
                artifact,
                try validator.validate(artifact, encoded: data, for: module),
                .current,
                data
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
        source: SnapshotSource,
        data: Data
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
            return (artifact, decoded, .migrated, migratedData)
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
           let successDate = ISODate.parse(lastSuccessAt) {
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
        ISODate.string(from: date)
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

// MARK: - 后台持久化 (C261)

/// 一次 publish 所需的不可变依赖。`AtomicJSONStore` 内嵌 Harness 故障注入闭包
/// (非 Sendable), 但后台队列只做文件 I/O、不触碰 `@MainActor` 状态, 故整体标注
/// `@unchecked Sendable` 并只在串行队列内使用。
private struct ArtifactStoreDiskContext: @unchecked Sendable {
    let fileManager: FileManager
    let validator: ArtifactValidator
    let atomicStore: AtomicJSONStore
    let currentURL: URL
    let previousURL: URL
    let metadataURL: URL
}

private enum ArtifactStoreDisk {
    /// 编码 → 校验解码 → 轮换 previous → 原子写当前快照 → 写元数据。
    /// 返回已校验解码对象与落盘字节, 供 MainActor 侧更新内存缓存。
    static func publish(
        artifact: JSONValue,
        module: CollectorModule,
        attemptedAt: Date,
        context: ArtifactStoreDiskContext
    ) throws -> (data: Data, decoded: DecodedArtifact) {
        let data: Data
        do {
            data = try JSONEncoder().encode(artifact)
        } catch {
            throw ArtifactValidationError.decodeFailed
        }
        let decoded = try context.validator.validate(artifact, encoded: data, for: module)

        // 只把合格的当前快照轮换为 previous; 内容相等即已校验 (C121)。
        if let currentData = try? Data(contentsOf: context.currentURL),
           isValidSnapshot(currentData, for: module, context: context) {
            try atomicWrite(
                currentData,
                to: context.previousURL,
                stage: .beforeReplace,
                context: context
            )
        }
        // C121: 内存中已校验, 写后重读只需逐字节比对; previous 已保存上一份合格快照,
        // 不再另写同内容的 .backup.json (并清理旧版本遗留的那份)。
        try atomicWrite(
            data,
            to: context.currentURL,
            validate: { reread in
                guard reread == data else {
                    throw ArtifactStoreError.corruptedSnapshot
                }
            },
            stage: .beforeReplace,
            context: context
        )
        context.atomicStore.removeBackup(context.currentURL)

        var metadata = try readMetadata(context: context)
        let timestamp = ISODate.string(from: attemptedAt)
        metadata.modules[module.rawValue] = ModuleSnapshotMetadata(
            schemaVersion: 1,
            artifactSchemaVersion: ArtifactValidator.currentSchemaVersion,
            module: module,
            lastSuccessAt: timestamp,
            lastAttemptAt: timestamp,
            isStale: false,
            errorCategory: nil
        )
        try writeMetadata(metadata, context: context)
        return (data, decoded)
    }

    private static func atomicWrite(
        _ data: Data,
        to targetURL: URL,
        validate: ((Data) throws -> Void)? = nil,
        stage: AtomicJSONStore.WriteStage,
        context: ArtifactStoreDiskContext
    ) throws {
        do {
            try context.atomicStore.write(
                data,
                to: targetURL,
                validate: validate,
                stage: stage
            )
        } catch is AtomicJSONStore.AtomicJSONStoreError {
            throw ArtifactStoreError.storageFailure
        }
    }

    private static func isValidSnapshot(
        _ data: Data,
        for module: CollectorModule,
        context: ArtifactStoreDiskContext
    ) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return false
        }
        return (try? context.validator.validate(value, encoded: data, for: module)) != nil
    }

    private static func readMetadata(
        context: ArtifactStoreDiskContext
    ) throws -> ArtifactStoreMetadata {
        guard context.fileManager.fileExists(atPath: context.metadataURL.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: context.metadataURL)
            let metadata = try JSONDecoder().decode(
                ArtifactStoreMetadata.self,
                from: data
            )
            guard metadata.schemaVersion == 1 else {
                throw ArtifactStoreError.unknownSchema(metadata.schemaVersion)
            }
            return metadata
        } catch let error as ArtifactStoreError {
            throw error
        } catch {
            throw ArtifactStoreError.corruptedSnapshot
        }
    }

    private static func writeMetadata(
        _ metadata: ArtifactStoreMetadata,
        context: ArtifactStoreDiskContext
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try atomicWrite(
            data,
            to: context.metadataURL,
            validate: { reread in
                _ = try JSONDecoder().decode(
                    ArtifactStoreMetadata.self,
                    from: reread
                )
            },
            stage: .beforeMetadataReplace,
            context: context
        )
    }
}
