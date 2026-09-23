import Foundation

// MARK: - AtomicJSONStore

/// 统一的项目自有 JSON 持久化基建: 原子写 + 目录/文件权限 + 重读校验 + 备份/回滚.
///
/// 抽取自原先三处重复实现 (ArtifactStore / DeepSeekUsageLedger /
/// OnboardingConfigurationStore), 消除「原子写 + 0600/0700 + schemaVersion」的复制。
/// 本类型只依赖 Foundation, 不耦合任何业务模型, 因此放在 BruceOnboardingCore
/// 以便 BruceAppCore 与 BruceOnboardingCore 两模块共用 (BruceAppCore 已依赖本模块)。
///
/// 设计要点:
/// - `write` 语义与既有实现逐行对齐: 建临时文件(0600) → 写 → synchronize → 关闭 →
///   置权限 → 重读校验 → 故障注入钩子 → 原子替换(或首建 move) → 置权限; 任意一步失败
///   清理临时文件, 保证磁盘上不残留半写入内容。
/// - `read` 用 `ReadResult` 穷尽化「缺失 / 不兼容(高版本) / 损坏」三态, 由调用方决定是否回滚。
/// - `backup` / `rollback` 提供统一备份与回滚安全网, 落实 `AGENTS.md` 要求的
///   「备份和回滚约束」(不引入数据库, 仅收敛现有文件写)。
package struct AtomicJSONStore {

    /// 写阶段钩子, 供故障注入 (Harness 验证原子性用).
    package enum WriteStage: Equatable {
        case beforeTempWrite
        case beforeReplace
        case beforeMetadataReplace
        case beforeMigrationReplace
    }

    /// 读结果: 区分「文件不存在 / schema 高版本不兼容 / 读取失败(IO/权限) /
    /// 解码或校验损坏」, 让调用方选择回滚或重建, 而非笼统抛错.
    /// `.unreadable` 表示文件内容未知 (可能是瞬时 IO/权限故障), 不应触发回滚.
    package enum ReadResult<T> {
        case loaded(T)
        case missing
        case incompatible(Int)
        case unreadable
        case corrupt
    }

    /// 回滚结果.
    package enum RollbackOutcome {
        /// 已从备份还原目标文件.
        case rolledBack
        /// 目标存在但无可用备份.
        case noBackup
        /// 备份存在但还原失败.
        case failed
    }

    /// 写失败时抛出的错误 (与既有 store 的 storageFailure 语义一致).
    package enum AtomicJSONStoreError: Error, Equatable {
        case storageFailure
    }

    package typealias FaultInjector = (WriteStage) throws -> Void

    private let fileManager: FileManager
    private let filePermissions: Int
    private let dirPermissions: Int
    private let faultInjector: FaultInjector?

    package init(
        fileManager: FileManager = .default,
        filePermissions: Int = 0o600,
        dirPermissions: Int = 0o700,
        faultInjector: FaultInjector? = nil
    ) {
        self.fileManager = fileManager
        self.filePermissions = filePermissions
        self.dirPermissions = dirPermissions
        self.faultInjector = faultInjector
    }

    // MARK: - 目录

    /// 确保目录存在且权限为 dirPermissions (默认 0700).
    package func prepareDirectory(at url: URL) throws {
        do {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(
                    at: url,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: dirPermissions]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: dirPermissions],
                ofItemAtPath: url.path
            )
        } catch {
            throw AtomicJSONStoreError.storageFailure
        }
    }

    // MARK: - 原子写

    /// 原子写入已序列化的字节 (调用方负责编码). 供既有 store 直接复用已存在的
    /// `Data` (如 `publish` 的 `currentData` / `migrateV0` 的 `migratedData`),
    /// 避免二次编码把 Data 误包成 base64.
    /// - Parameters:
    ///   - validate: 写入后重读校验闭包; 校验不通过抛错并丢弃临时文件.
    ///   - backupPrevious: 为 true 且目标已存在时, 先 `backup` 当前内容 (幂等).
    ///   - stage: 故障注入阶段标识 (用于 beforeReplace / beforeMetadataReplace /
    ///     beforeMigrationReplace 等既有 ArtifactStore 钩子).
    package func write(
        _ data: Data,
        to targetURL: URL,
        validate: ((Data) throws -> Void)? = nil,
        backupPrevious: Bool = false,
        stage: WriteStage = .beforeReplace
    ) throws {
        try writeData(
            data,
            to: targetURL,
            validate: validate,
            backupPrevious: backupPrevious,
            stage: stage
        )
    }

    /// 将可编码值原子写入 targetURL (内部先 `JSONEncoder` 编码再走字节写路径).
    package func write<T: Codable>(
        _ value: T,
        to targetURL: URL,
        validate: ((T) throws -> Void)? = nil,
        backupPrevious: Bool = false,
        stage: WriteStage = .beforeReplace
    ) throws {
        let data = try JSONEncoder().encode(value)
        try writeData(
            data,
            to: targetURL,
            validate: { reread in
                try validate?(try JSONDecoder().decode(T.self, from: reread))
            },
            backupPrevious: backupPrevious,
            stage: stage
        )
    }

    private func writeData(
        _ data: Data,
        to targetURL: URL,
        validate: ((Data) throws -> Void)? = nil,
        backupPrevious: Bool = false,
        stage: WriteStage = .beforeReplace
    ) throws {
        if backupPrevious,
           fileManager.fileExists(atPath: targetURL.path) {
            _ = backup(targetURL)
        }

        let temporaryURL = targetURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(targetURL.lastPathComponent).\(UUID().uuidString).tmp"
            )
        do {
            try faultInjector?(.beforeTempWrite)
            guard fileManager.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: filePermissions]
            ) else {
                throw AtomicJSONStoreError.storageFailure
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: temporaryURL.path
            )
            let reread = try Data(contentsOf: temporaryURL)
            try validate?(reread)
            try faultInjector?(stage)
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
                [.posixPermissions: filePermissions],
                ofItemAtPath: targetURL.path
            )
        } catch let error as AtomicJSONStoreError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw AtomicJSONStoreError.storageFailure
        }
    }

    // MARK: - 读

    /// 读取并解码目标文件, 返回穷尽化的 `ReadResult`.
    /// - `validate`: 解码后可选业务校验; 校验失败归为 `.corrupt`.
    /// - Note: 文件存在但读不出字节 (权限/IO) 归为 `.unreadable`, 只有
    ///   解码或校验失败才算 `.corrupt`, 避免瞬时 IO 故障误触发回滚.
    package func read<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        validate: ((T) throws -> Void)? = nil
    ) -> ReadResult<T> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable
        }
        do {
            let decoded = try JSONDecoder().decode(type, from: data)
            try validate?(decoded)
            return .loaded(decoded)
        } catch {
            return .corrupt
        }
    }

    // MARK: - 备份 / 回滚

    /// 将目标文件复制到 `<basename>.backup.json`.
    ///
    /// 已存在的旧备份会被覆盖: 备份始终是「上一次写入前」的状态 (滚动深度 1),
    /// 而不是 write-once 的陈旧快照 — 否则回滚会还原任意久远的数据.
    /// 目标不存在时返回 false; 复制失败返回 false (调用方自行决定是否继续).
    @discardableResult
    package func backup(_ url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        let backupURL = self.backupURL(for: url)
        do {
            try prepareDirectory(at: backupURL.deletingLastPathComponent())
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
            try fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: backupURL.path
            )
            return true
        } catch {
            return false
        }
    }

    /// 用备份 `<basename>.backup.json` 还原目标文件.
    package func rollback(_ url: URL) -> RollbackOutcome {
        let backupURL = self.backupURL(for: url)
        guard fileManager.fileExists(atPath: backupURL.path) else {
            return .noBackup
        }
        do {
            try prepareDirectory(at: url.deletingLastPathComponent())
            _ = try fileManager.replaceItemAt(url, withItemAt: backupURL)
            try fileManager.setAttributes(
                [.posixPermissions: filePermissions],
                ofItemAtPath: url.path
            )
            return .rolledBack
        } catch {
            return .failed
        }
    }

    /// 删除备份文件 (若后续不再需要保留旧副本时调用).
    package func removeBackup(_ url: URL) {
        let backupURL = self.backupURL(for: url)
        try? fileManager.removeItem(at: backupURL)
    }

    func backupURL(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        return dir.appendingPathComponent("\(name).backup.json")
    }
}
