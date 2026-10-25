import CryptoKit
import Foundation

// MARK: - 自替换安装器 (07-软件更新 §4.2 R6)

/// 外部命令边界 (ditto / xattr / 重启等待器); 测试可替换, 生产走 /usr/bin 绝对路径.
package protocol UpdateCommandRunning: Sendable {
    /// 同步等待退出; 返回是否 0 退出.
    func run(_ executablePath: String, _ arguments: [String]) async -> Bool
    /// 启动后不等待 (重启等待器须在本进程退出后继续存活).
    func launchDetached(_ executablePath: String, _ arguments: [String]) throws
}

package struct SystemUpdateCommandRunner: UpdateCommandRunning {
    package init() {}

    package func run(_ executablePath: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
            }
        }
    }

    package func launchDetached(_ executablePath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

/// 下载、校验、解压与原子替换. 所有路径均可注入, 测试在临时目录夹具上运行, 不触碰 /Applications.
package struct UpdateInstaller: Sendable {
    package typealias MoveItem = @Sendable (URL, URL) throws -> Void

    /// ~/Library/Application Support/Bruce/updates (项目既有数据目录).
    package let updatesRoot: URL
    private let commands: any UpdateCommandRunning
    private let moveItem: MoveItem

    package static let appBundleName = "Bruce.app"

    package init(
        updatesRoot: URL,
        commands: any UpdateCommandRunning = SystemUpdateCommandRunner(),
        moveItem: @escaping MoveItem = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.updatesRoot = updatesRoot
        self.commands = commands
        self.moveItem = moveItem
    }

    package static func defaultUpdatesRoot() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bruce", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
    }

    package var backupDirectory: URL {
        updatesRoot.appendingPathComponent("backup", isDirectory: true)
    }

    package func downloadURL(for version: SemanticVersion) -> URL {
        updatesRoot.appendingPathComponent("Bruce-\(version.description).zip")
    }

    package func stagingDirectory(for version: SemanticVersion) -> URL {
        updatesRoot.appendingPathComponent("staging-\(version.description)", isDirectory: true)
    }

    package func prepareUpdatesRoot() throws {
        try FileManager.default.createDirectory(at: updatesRoot, withIntermediateDirectories: true)
    }

    /// 新版本启动后清理上一轮下载、暂存与备份 (backup 只服务于替换瞬间的回滚).
    package func removeStaleArtifacts() {
        try? FileManager.default.removeItem(at: updatesRoot)
    }

    // MARK: 前置位置检查 (R6.4)

    /// 当前应用能否自替换: 非 App Translocation 随机只读挂载、所在卷可写、父目录与 bundle 可写,
    /// 且与 updates 目录同卷 (rename 才是原子的). 任一不满足即降级为引导手动更新.
    package func canSelfReplace(installedApp: URL) -> Bool {
        let fileManager = FileManager.default
        let app = installedApp.standardizedFileURL
        let parent = app.deletingLastPathComponent()
        guard app.pathExtension == "app",
              !app.path.contains("/AppTranslocation/"),
              fileManager.isWritableFile(atPath: parent.path),
              fileManager.isWritableFile(atPath: app.path),
              (try? prepareUpdatesRoot()) != nil else {
            return false
        }
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey, .volumeIsReadOnlyKey]
        guard let appValues = try? parent.resourceValues(forKeys: keys),
              let rootValues = try? updatesRoot.resourceValues(forKeys: keys),
              appValues.volumeIsReadOnly != true,
              let appVolume = appValues.volumeIdentifier as? NSObject,
              let rootVolume = rootValues.volumeIdentifier as? NSObject else {
            return false
        }
        return appVolume.isEqual(rootVolume)
    }

    // MARK: 校验与解压 (R6.2 / R6.3)

    package static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 校验下载包并解压到暂存目录, 返回可直接替换的 Bruce.app.
    /// 顺序: SHA256 → ditto 解压 → xattr -cr 剥离 quarantine → Info.plist 复核
    /// (bundle 标识一致、版本等于清单且严格大于本地, 防清单污染导致的降级/回滚).
    package func prepare(
        archive: URL,
        release: UpdateRelease,
        localVersion: SemanticVersion,
        bundleIdentifier: String?
    ) async throws -> URL {
        guard (try? Self.sha256Hex(of: archive)) == release.sha256 else {
            throw UpdateInstallFailure.checksumMismatch
        }
        let staging = stagingDirectory(for: release.version)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw UpdateInstallFailure.extractFailed
        }
        guard await commands.run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path]) else {
            throw UpdateInstallFailure.extractFailed
        }
        let app = staging.appendingPathComponent(Self.appBundleName, isDirectory: true)
        guard fileManager.fileExists(atPath: app.path),
              await commands.run("/usr/bin/xattr", ["-cr", app.path]) else {
            throw UpdateInstallFailure.extractFailed
        }
        try Self.validateBundle(
            at: app,
            release: release,
            localVersion: localVersion,
            bundleIdentifier: bundleIdentifier
        )
        return app
    }

    package static func validateBundle(
        at app: URL,
        release: UpdateRelease,
        localVersion: SemanticVersion,
        bundleIdentifier: String?
    ) throws {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any] else {
            throw UpdateInstallFailure.bundleMismatch
        }
        if let bundleIdentifier,
           plist["CFBundleIdentifier"] as? String != bundleIdentifier {
            throw UpdateInstallFailure.bundleMismatch
        }
        guard let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              FileManager.default.isExecutableFile(
                  atPath: app.appendingPathComponent("Contents/MacOS/\(executable)").path
              ) else {
            throw UpdateInstallFailure.bundleMismatch
        }
        guard let version = (plist["CFBundleShortVersionString"] as? String)
            .flatMap(SemanticVersion.init) else {
            throw UpdateInstallFailure.versionMismatch
        }
        guard version > localVersion else {
            throw UpdateInstallFailure.versionNotNewer
        }
        guard version == release.version else {
            throw UpdateInstallFailure.versionMismatch
        }
    }

    // MARK: 原子替换与回滚 (R6.5 / R6.6)

    /// 旧 app rename 到 updates/backup/, 新 app rename 到原位置; 第二步失败时把备份 rename 回滚.
    /// 运行中的旧进程持有旧 inode, 不受替换影响.
    package func replace(installedApp: URL, with newApp: URL) throws {
        let fileManager = FileManager.default
        let backup = backupDirectory.appendingPathComponent(
            installedApp.lastPathComponent,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: backup.path) {
                try fileManager.removeItem(at: backup)
            }
            try moveItem(installedApp, backup)
        } catch {
            // 原位置未改动.
            throw UpdateInstallFailure.replaceFailed(rolledBack: true)
        }
        do {
            try moveItem(newApp, installedApp)
        } catch {
            do {
                try moveItem(backup, installedApp)
            } catch {
                throw UpdateInstallFailure.replaceFailed(rolledBack: false)
            }
            throw UpdateInstallFailure.replaceFailed(rolledBack: true)
        }
    }

    /// 启动等待器: 本进程退出 (最长等 30 秒) 后经 LaunchServices 打开新 app.
    /// 先退后起, 避免新旧两个实例同时持有菜单栏图标与全局快捷键.
    /// pid 与路径以位置参数传入 sh, 不拼接进脚本文本.
    package func relaunch(app: URL, waitingFor pid: Int32) throws {
        let script = """
        i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; /usr/bin/open "$2"
        """
        do {
            try commands.launchDetached("/bin/sh", ["-c", script, "bruce-relaunch", String(pid), app.path])
        } catch {
            throw UpdateInstallFailure.relaunchFailed
        }
    }
}
