import Foundation
@testable import BruceAppCore

// MARK: - 安装器: 校验 / 解压 / 原子替换 / 回滚 (临时目录夹具, 不触碰真实 /Applications)

enum SoftwareUpdateInstallerTests {
    static let local = SemanticVersion(major: 0, minor: 12, patch: 2)
    static let remote = SemanticVersion(major: 0, minor: 13, patch: 0)

    /// 打包一份 `version` 的夹具 zip, 返回 (zip, 与之匹配的 release).
    static func makeArchive(
        in root: URL,
        version: String,
        releaseVersion: SemanticVersion = remote,
        bundleIdentifier: String = FixtureBundle.bundleIdentifier,
        includeExecutable: Bool = true
    ) throws -> (URL, UpdateRelease) {
        let source = root.appendingPathComponent("source-\(UUID().uuidString)", isDirectory: true)
        let app = try FixtureBundle.makeApp(
            in: source,
            version: version,
            bundleIdentifier: bundleIdentifier,
            includeExecutable: includeExecutable
        )
        let archive = root.appendingPathComponent("Bruce-\(UUID().uuidString).zip")
        try FixtureBundle.zip(app: app, to: archive)
        let release = UpdateRelease(
            version: releaseVersion,
            notes: "",
            downloadURL: URL(string: "https://github.com/4everSivan/Bruce/releases/download/\(releaseVersion.tag)/Bruce.zip")!,
            sha256: try UpdateInstaller.sha256Hex(of: archive)
        )
        return (archive, release)
    }

    static func sha256MatchesKnownVector() throws {
        let root = try TemporaryDirectories.make("sha")
        defer { TemporaryDirectories.remove(root) }
        let file = root.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        try expectEqual(
            try UpdateInstaller.sha256Hex(of: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "SHA256(\"abc\") 标准向量"
        )
    }

    static func prepareExtractsAndValidatesBundle() async throws {
        let root = try TemporaryDirectories.make("prepare")
        defer { TemporaryDirectories.remove(root) }
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        try installer.prepareUpdatesRoot()
        let (archive, release) = try makeArchive(in: root, version: "0.13.0")
        let app = try await installer.prepare(
            archive: archive,
            release: release,
            localVersion: local,
            bundleIdentifier: FixtureBundle.bundleIdentifier
        )
        try expectEqual(app.lastPathComponent, "Bruce.app", "暂存产物为 Bruce.app")
        try expect(app.path.hasPrefix(installer.updatesRoot.path), "暂存于 updates 目录")
        try expectEqual(FixtureBundle.version(of: app), "0.13.0", "暂存产物版本")
    }

    static func prepareRejectsChecksumMismatch() async throws {
        let root = try TemporaryDirectories.make("checksum")
        defer { TemporaryDirectories.remove(root) }
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        let (archive, release) = try makeArchive(in: root, version: "0.13.0")
        let tampered = UpdateRelease(
            version: release.version,
            notes: "",
            downloadURL: release.downloadURL,
            sha256: String(repeating: "0", count: 64)
        )
        try await expectThrows(UpdateInstallFailure.checksumMismatch, "SHA256 不符拒绝安装") {
            _ = try await installer.prepare(
                archive: archive,
                release: tampered,
                localVersion: local,
                bundleIdentifier: FixtureBundle.bundleIdentifier
            )
        }
        try expect(
            !FileManager.default.fileExists(atPath: installer.stagingDirectory(for: remote).path),
            "校验失败不应解压"
        )
    }

    static func prepareRejectsDowngradeAndMismatchedBundles() async throws {
        let root = try TemporaryDirectories.make("validate")
        defer { TemporaryDirectories.remove(root) }
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        try installer.prepareUpdatesRoot()

        // 清单声称 0.13.0, 包内却是本地同版本 0.12.2 (防降级/回滚).
        let (sameArchive, sameRelease) = try makeArchive(in: root, version: "0.12.2")
        try await expectThrows(UpdateInstallFailure.versionNotNewer, "包内版本不高于本地") {
            _ = try await installer.prepare(archive: sameArchive, release: sameRelease, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
        let (olderArchive, olderRelease) = try makeArchive(in: root, version: "0.11.0")
        try await expectThrows(UpdateInstallFailure.versionNotNewer, "包内版本低于本地") {
            _ = try await installer.prepare(archive: olderArchive, release: olderRelease, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
        // 包内版本更高但与清单不符.
        let (otherArchive, otherRelease) = try makeArchive(in: root, version: "0.14.0")
        try await expectThrows(UpdateInstallFailure.versionMismatch, "包内版本与清单不符") {
            _ = try await installer.prepare(archive: otherArchive, release: otherRelease, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
        let (foreignArchive, foreignRelease) = try makeArchive(in: root, version: "0.13.0", bundleIdentifier: "com.example.other")
        try await expectThrows(UpdateInstallFailure.bundleMismatch, "bundle 标识不符") {
            _ = try await installer.prepare(archive: foreignArchive, release: foreignRelease, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
        let (hollowArchive, hollowRelease) = try makeArchive(in: root, version: "0.13.0", includeExecutable: false)
        try await expectThrows(UpdateInstallFailure.bundleMismatch, "缺可执行文件") {
            _ = try await installer.prepare(archive: hollowArchive, release: hollowRelease, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
    }

    static func prepareRejectsCorruptArchive() async throws {
        let root = try TemporaryDirectories.make("corrupt")
        defer { TemporaryDirectories.remove(root) }
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        let archive = root.appendingPathComponent("Bruce.zip")
        try Data("not a zip".utf8).write(to: archive)
        let release = UpdateRelease(
            version: remote,
            notes: "",
            downloadURL: URL(string: "https://github.com/4everSivan/Bruce/releases/download/v0.13.0/Bruce.zip")!,
            sha256: try UpdateInstaller.sha256Hex(of: archive)
        )
        try await expectThrows(UpdateInstallFailure.extractFailed, "非 zip 解压失败") {
            _ = try await installer.prepare(archive: archive, release: release, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
    }

    static func prepareStripsQuarantine() async throws {
        let root = try TemporaryDirectories.make("quarantine")
        defer { TemporaryDirectories.remove(root) }
        let commands = RecordingCommandRunner()
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"), commands: commands)
        try installer.prepareUpdatesRoot()
        let (archive, release) = try makeArchive(in: root, version: "0.13.0")
        // 给 zip 打上 quarantine; ditto 解压会把它传染给 app, xattr -cr 必须剥离.
        let tag = Process()
        tag.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        tag.arguments = ["-w", "com.apple.quarantine", "0081;00000000;Bruce;", archive.path]
        try tag.run()
        tag.waitUntilExit()
        let app = try await installer.prepare(archive: archive, release: release, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        probe.arguments = ["-p", "com.apple.quarantine", app.path]
        probe.standardError = FileHandle.nullDevice
        probe.standardOutput = FileHandle.nullDevice
        try probe.run()
        probe.waitUntilExit()
        try expect(probe.terminationStatus != 0, "暂存 app 不应残留 quarantine 属性")

        commands.failingExecutables = ["/usr/bin/xattr"]
        try await expectThrows(UpdateInstallFailure.extractFailed, "xattr 失败视为不可安装") {
            _ = try await installer.prepare(archive: archive, release: release, localVersion: local, bundleIdentifier: FixtureBundle.bundleIdentifier)
        }
    }

    static func replaceSwapsBundleAndKeepsBackup() throws {
        let root = try TemporaryDirectories.make("replace")
        defer { TemporaryDirectories.remove(root) }
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let installed = try FixtureBundle.makeApp(in: applications, version: "0.12.2")
        let staged = try FixtureBundle.makeApp(in: root.appendingPathComponent("staged"), version: "0.13.0")
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        try installer.replace(installedApp: installed, with: staged)
        try expectEqual(FixtureBundle.version(of: installed), "0.13.0", "原位置已是新版本")
        try expectEqual(
            FixtureBundle.version(of: installer.backupDirectory.appendingPathComponent("Bruce.app")),
            "0.12.2",
            "旧版本进入 backup"
        )
        try expect(!FileManager.default.fileExists(atPath: staged.path), "暂存产物已移走")
    }

    static func replaceRollsBackWhenSwapFails() throws {
        let root = try TemporaryDirectories.make("rollback")
        defer { TemporaryDirectories.remove(root) }
        let installed = try FixtureBundle.makeApp(in: root.appendingPathComponent("Applications"), version: "0.12.2")
        let staged = try FixtureBundle.makeApp(in: root.appendingPathComponent("staged"), version: "0.13.0")
        let calls = Counter()
        // 第 2 次 move (新 app → 原位置) 失败, 第 3 次为回滚.
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates")) { from, to in
            if calls.increment() == 2 {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        do {
            try installer.replace(installedApp: installed, with: staged)
            throw UpdateHarnessFailure.expectation("替换失败应抛出")
        } catch let failure as UpdateInstallFailure {
            try expectEqual(failure, .replaceFailed(rolledBack: true), "回滚成功")
        }
        try expectEqual(FixtureBundle.version(of: installed), "0.12.2", "原 app 已回滚")
        try expectEqual(calls.value, 3, "备份 → 替换失败 → 回滚")
    }

    static func replaceReportsFailedRollback() throws {
        let root = try TemporaryDirectories.make("rollback-fail")
        defer { TemporaryDirectories.remove(root) }
        let installed = try FixtureBundle.makeApp(in: root.appendingPathComponent("Applications"), version: "0.12.2")
        let staged = try FixtureBundle.makeApp(in: root.appendingPathComponent("staged"), version: "0.13.0")
        let calls = Counter()
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates")) { from, to in
            if calls.increment() >= 2 {
                throw CocoaError(.fileWriteNoPermission)
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        do {
            try installer.replace(installedApp: installed, with: staged)
            throw UpdateHarnessFailure.expectation("替换失败应抛出")
        } catch let failure as UpdateInstallFailure {
            try expectEqual(failure, .replaceFailed(rolledBack: false), "回滚也失败须如实报告")
        }
        try expectEqual(
            FixtureBundle.version(of: installer.backupDirectory.appendingPathComponent("Bruce.app")),
            "0.12.2",
            "旧版本仍保留在 backup 可手动恢复"
        )
    }

    static func replaceFailsCleanlyWhenBackupFails() throws {
        let root = try TemporaryDirectories.make("backup-fail")
        defer { TemporaryDirectories.remove(root) }
        let installed = try FixtureBundle.makeApp(in: root.appendingPathComponent("Applications"), version: "0.12.2")
        let staged = try FixtureBundle.makeApp(in: root.appendingPathComponent("staged"), version: "0.13.0")
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates")) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            try installer.replace(installedApp: installed, with: staged)
            throw UpdateHarnessFailure.expectation("备份失败应抛出")
        } catch let failure as UpdateInstallFailure {
            try expectEqual(failure, .replaceFailed(rolledBack: true), "原位置未改动")
        }
        try expectEqual(FixtureBundle.version(of: installed), "0.12.2", "原 app 未被触碰")
    }

    static func selfReplaceRequiresWritableSameVolumeLocation() throws {
        let root = try TemporaryDirectories.make("location")
        defer { TemporaryDirectories.remove(root) }
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        let writable = try FixtureBundle.makeApp(in: root.appendingPathComponent("Applications"), version: "0.12.2")
        try expect(installer.canSelfReplace(installedApp: writable), "用户可写同卷位置可自替换")

        let translocated = try FixtureBundle.makeApp(
            in: root.appendingPathComponent("AppTranslocation/ABCD/d"),
            version: "0.12.2"
        )
        try expect(!installer.canSelfReplace(installedApp: translocated), "App Translocation 随机挂载不可自替换")

        let lockedParent = root.appendingPathComponent("Locked", isDirectory: true)
        let locked = try FixtureBundle.makeApp(in: lockedParent, version: "0.12.2")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
        defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path) }
        try expect(!installer.canSelfReplace(installedApp: locked), "父目录只读不可自替换")

        let bareExecutableDir = root.appendingPathComponent("debug", isDirectory: true)
        try FileManager.default.createDirectory(at: bareExecutableDir, withIntermediateDirectories: true)
        try expect(!installer.canSelfReplace(installedApp: bareExecutableDir), "非 .app (裸 swift run) 不可自替换")
    }

    static func relaunchWaitsForCurrentProcessThenOpens() throws {
        let root = try TemporaryDirectories.make("relaunch")
        defer { TemporaryDirectories.remove(root) }
        let commands = RecordingCommandRunner()
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"), commands: commands)
        let app = root.appendingPathComponent("Applications/Bruce.app")
        try installer.relaunch(app: app, waitingFor: 4242)
        try expectEqual(commands.detached.count, 1, "启动一个等待器")
        let (executable, arguments) = commands.detached[0]
        try expectEqual(executable, "/bin/sh", "等待器经 /bin/sh")
        try expectEqual(arguments.count, 5, "-c 脚本 + $0 + pid + 路径")
        try expectEqual(arguments[0], "-c", "脚本参数")
        try expect(arguments[1].contains("kill -0 \"$1\""), "等待旧进程退出")
        try expect(arguments[1].contains("/usr/bin/open \"$2\""), "经 LaunchServices 打开新 app")
        try expect(!arguments[1].contains(app.path), "路径不拼接进脚本文本")
        try expectEqual(arguments[3], "4242", "pid 以位置参数传入")
        try expectEqual(arguments[4], app.path, "路径以位置参数传入")

        commands.detachedFails = true
        do {
            try installer.relaunch(app: app, waitingFor: 4242)
            throw UpdateHarnessFailure.expectation("等待器启动失败应抛出")
        } catch let failure as UpdateInstallFailure {
            try expectEqual(failure, .relaunchFailed, "重启失败分类")
        }
    }

    static func removeStaleArtifactsOnlyTouchesUpdatesRoot() throws {
        let root = try TemporaryDirectories.make("cleanup")
        defer { TemporaryDirectories.remove(root) }
        let sibling = root.appendingPathComponent("config/onboarding-v1.json")
        try FileManager.default.createDirectory(at: sibling.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sibling)
        let installer = UpdateInstaller(updatesRoot: root.appendingPathComponent("updates"))
        try FileManager.default.createDirectory(at: installer.backupDirectory, withIntermediateDirectories: true)
        installer.removeStaleArtifacts()
        try expect(!FileManager.default.fileExists(atPath: installer.updatesRoot.path), "updates 目录已清理")
        try expect(FileManager.default.fileExists(atPath: sibling.path), "同级配置不受影响")
    }
}

/// 线程安全计数器 (moveItem 注入闭包为 @Sendable).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
