import Foundation
@testable import BruceOnboardingCore

// MARK: - AsyncProcessProbe / SQLite / Keychain / Scanner

extension BruceOnboardingCoreHarness {
    // MARK: - AsyncProcessProbe

    static func probeSuccessCapturesOutput() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(executablePath: "/bin/echo", arguments: ["hello"])
        guard case .success(let output) = result else {
            throw CoreTestFailure.expectation("echo should succeed, got \(result)")
        }
        try coreExpect(output == "hello", "output mismatch: \(output)")
        try coreExpect(result.firstLine == "hello", "firstLine mismatch")
    }

    static func probeLaunchFailedForMissingExecutable() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/nonexistent/binary-\(UUID().uuidString)",
            arguments: []
        )
        try coreExpect(result == .launchFailed, "should be launchFailed, got \(result)")
    }

    static func probeNonZeroExitCapturesStderrSummary() async throws {
        let probe = AsyncProcessProbe()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "echo database-is-locked-here >&2; exit 3"]
        )
        guard case .nonZeroExit(let code, let stderrSummary) = result else {
            throw CoreTestFailure.expectation("should be nonZeroExit, got \(result)")
        }
        try coreExpect(code == 3, "exit code mismatch: \(code)")
        try coreExpect(
            stderrSummary?.contains("database-is-locked-here") == true,
            "stderr summary missing: \(String(describing: stderrSummary))"
        )
    }

    /// 子进程忽略 SIGTERM, 验证宽限期后 SIGKILL 生效且不遗留等待.
    /// exec 使 sleep 替换 shell 成为直接子进程 (SIG_IGN 跨 exec 保留),
    /// 避免孤儿孙进程干扰验证.
    static func probeTimeoutForceKillsIgnoringSIGTERM() async throws {
        let probe = AsyncProcessProbe(timeout: 0.3, gracePeriod: 0.2)
        let start = Date()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "trap '' TERM; exec sleep 60"]
        )
        let elapsed = Date().timeIntervalSince(start)
        try coreExpect(result == .timedOut, "should be timedOut, got \(result)")
        try coreExpect(
            elapsed < 5,
            "force kill should finish fast, took \(elapsed)s"
        )
    }

    static func probeCallerCancellationTerminatesProcess() async throws {
        let probe = AsyncProcessProbe(timeout: 30, gracePeriod: 0.2)
        let task = Task {
            await probe.run(executablePath: "/bin/sleep", arguments: ["60"])
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let start = Date()
        task.cancel()
        let result = await task.value
        let elapsed = Date().timeIntervalSince(start)
        try coreExpect(result == .cancelled, "should be cancelled, got \(result)")
        try coreExpect(elapsed < 5, "cancel cleanup should be fast, took \(elapsed)s")
    }

    /// 输出远超管道缓冲区 (200KB > 64KB) 且超过上限:
    /// 验证读取期间强制截断, 且持续排空不阻塞子进程.
    static func probeOutputCapTruncatesAndDrains() async throws {
        let cap = 1_024
        let probe = AsyncProcessProbe(timeout: 10, maxOutputBytes: cap)
        let start = Date()
        let result = await probe.run(
            executablePath: "/bin/sh",
            arguments: ["-c", "yes X | head -c 200000"]
        )
        let elapsed = Date().timeIntervalSince(start)
        guard case .success(let output) = result else {
            throw CoreTestFailure.expectation("should succeed, got \(result)")
        }
        try coreExpect(
            output.utf8.count <= cap,
            "output should be capped at \(cap), got \(output.utf8.count)"
        )
        try coreExpect(
            elapsed < 8,
            "large output should not block the child, took \(elapsed)s"
        )
    }

    // MARK: - SQLiteSchemaProbe (临时目录 fixture, 不读真实数据库)

    /// 用 /usr/bin/sqlite3 在临时目录构造 fixture 数据库.
    static func createSQLiteFixture(at url: URL, sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CoreTestFailure.expectation(
                "fixture creation failed: \(process.terminationStatus)"
            )
        }
    }

    static let ccSwitchFixtureSQL = """
        CREATE TABLE providers (
            id TEXT, name TEXT, app_type TEXT,
            settings_config TEXT, meta TEXT, is_current INTEGER
        );
        CREATE TABLE model_pricing (
            model_id TEXT,
            input_cost_per_million REAL,
            output_cost_per_million REAL,
            cache_read_cost_per_million REAL,
            cache_creation_cost_per_million REAL
        );
        """

    static func makeTempDir(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-\(label)-\(UUID().uuidString)")
    }

    static func sqliteProbeAvailableForValidSchema() async throws {
        let tempDir = makeTempDir("sqlite-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: ccSwitchFixtureSQL)
        let bytesBefore = try Data(contentsOf: dbURL)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .available, "should be available, got \(result)")

        // 只读探测不得修改数据库文件
        let bytesAfter = try Data(contentsOf: dbURL)
        try coreExpect(bytesBefore == bytesAfter, "probe must not modify the database")
    }

    static func sqliteProbeMissingPath() async throws {
        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(
            fileURL: URL(fileURLWithPath: "/nonexistent/db-\(UUID().uuidString).db"),
            profile: .ccSwitch
        )
        try coreExpect(result == .missing, "should be missing, got \(result)")
    }

    static func sqliteProbeIncompatibleWhenMissingTable() async throws {
        let tempDir = makeTempDir("sqlite-notable")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("partial.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (
                id TEXT, name TEXT, app_type TEXT,
                settings_config TEXT, meta TEXT, is_current INTEGER
            );
            """)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .incompatible, "should be incompatible, got \(result)")
    }

    static func sqliteProbeIncompatibleWhenMissingColumn() async throws {
        let tempDir = makeTempDir("sqlite-nocol")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("nocol.db")
        try createSQLiteFixture(at: dbURL, sql: """
            CREATE TABLE providers (id TEXT, name TEXT);
            CREATE TABLE model_pricing (
                model_id TEXT,
                input_cost_per_million REAL,
                output_cost_per_million REAL,
                cache_read_cost_per_million REAL,
                cache_creation_cost_per_million REAL
            );
            """)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .incompatible, "should be incompatible, got \(result)")
    }

    /// 列名互为子串的误判陷阱: 表里有 meta_extra, 但契约要求 meta.
    /// 旧的 contains 判断会误判为兼容, 逐行精确解析必须拒绝.
    static func sqliteProbeRejectsSubstringColumnTrap() async throws {
        let tempDir = makeTempDir("sqlite-trap")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("trap.db")
        try createSQLiteFixture(at: dbURL, sql:
            "CREATE TABLE trap (id TEXT, meta_extra TEXT);")

        let profile = SQLiteSchemaProfile(
            displayName: "Trap",
            tables: ["trap": ["id", "meta"]]
        )
        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: profile)
        try coreExpect(
            result == .incompatible,
            "substring column must be rejected, got \(result)"
        )
    }

    static func sqliteProbeCorruptedForGarbageFile() async throws {
        let tempDir = makeTempDir("sqlite-corrupt")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let dbURL = tempDir.appendingPathComponent("garbage.db")
        var garbage = Data()
        for _ in 0..<256 {
            garbage.append(contentsOf: [UInt8](repeating: 0xAB, count: 16))
        }
        try garbage.write(to: dbURL)

        let probe = SQLiteSchemaProbe()
        let result = await probe.probe(fileURL: dbURL, profile: .ccSwitch)
        try coreExpect(result == .corrupted, "should be corrupted, got \(result)")
    }

    /// locked 判定单元测试: 以 stderr 消息为准, 不把任意非零退出当锁定.
    /// 真实的并发锁定场景依赖时序, 无法确定性构造, 这里只验证分类逻辑.
    static func sqliteLockedDetectionUsesStderr() throws {
        try coreExpect(
            SQLiteSchemaProbe.isLocked(stderrSummary: "Error: database is locked"),
            "locked message should map to locked"
        )
        try coreExpect(
            SQLiteSchemaProbe.isLocked(stderrSummary: "Error: database is busy"),
            "busy message should map to locked"
        )
        try coreExpect(
            !SQLiteSchemaProbe.isLocked(stderrSummary: "Error: no such table: foo"),
            "other errors must not map to locked"
        )
        try coreExpect(
            !SQLiteSchemaProbe.isLocked(stderrSummary: nil),
            "nil stderr must not map to locked"
        )
    }

    static func sqliteTableInfoParsesColumnNames() throws {
        let output = """
            0|id|INTEGER|0||1
            1|name|TEXT|1||0
            2|meta|TEXT|0||0
            """
        let names = SQLiteSchemaProbe.tableInfoColumnNames(output)
        try coreExpect(names == ["id", "name", "meta"], "parse mismatch: \(names)")
        try coreExpect(
            !names.contains("nam"), "substring must not match"
        )
    }

    // MARK: - Keychain (独立测试 service, 不触碰正式凭证)

    static let keychainTestService = "com.bruce.dashboard.credentials.harness"

    /// 验证 update 优先语义: 预置旧值后 saveCredential 是就地更新而非先删后加,
    /// 任何时刻凭证不丢失; 测试结束清理测试项.
    static func keychainUpdatePreservesAndOverwrites() throws {
        let store = KeychainCredentialStore(service: keychainTestService)
        let account = "harness-\(UUID().uuidString)"
        defer { try? store.deleteCredential(forAccount: account) }

        try store.saveCredential("old-value", forAccount: account)
        let first = try store.loadCredential(forAccount: account)
        try coreExpect(first == "old-value", "initial save failed")

        // 再次保存必须是更新语义: 新值可读, 且过程中不经过"已删除"窗口
        try store.saveCredential("new-value", forAccount: account)
        let updated = try store.loadCredential(forAccount: account)
        try coreExpect(
            updated == "new-value",
            "update should overwrite, got \(String(describing: updated))"
        )

        try store.deleteCredential(forAccount: account)
        let deleted = try store.loadCredential(forAccount: account)
        try coreExpect(deleted == nil, "delete should remove the item")
    }

    // MARK: - LocalDependencyScanner (全部注入临时路径)

    /// 构造可执行的假脚本并返回路径.
    static func makeExecutableScript(
        in dir: URL, name: String, body: String
    ) throws -> String {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(
            to: url, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
        return url.path
    }

    static func scannerFindsSessionsAndSQLite() async throws {
        let tempDir = makeTempDir("scanner-ok")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionDir = tempDir.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let dbURL = tempDir.appendingPathComponent("cc-switch.db")
        try createSQLiteFixture(at: dbURL, sql: ccSwitchFixtureSQL)

        let paths = LocalDependencyScanPaths(
            sessionDirectories: [
                .init(displayName: "Kimi Code CLI", url: sessionDir),
                .init(displayName: "Claude Code",
                      url: tempDir.appendingPathComponent("absent")),
            ],
            sqliteDatabases: [
                .init(profile: .ccSwitch, url: dbURL),
            ]
        )
        let scanner = LocalDependencyScanner(paths: paths)
        let probes = await scanner.scan()

        let sessions = probes.filter { $0.kind == .sessionDirectory }
        try coreExpect(sessions.count == 2, "should have 2 session probes")
        try coreExpect(
            sessions.first { $0.detail == "Kimi Code CLI" }?.status == .available,
            "Kimi session dir should be available"
        )
        try coreExpect(
            sessions.first { $0.detail == "Claude Code" }?.status == .missing,
            "Claude session dir should be missing"
        )
        let sqlite = probes.first { $0.kind == .sqliteDatabase }
        try coreExpect(sqlite?.status == .available, "sqlite should be available")
        try coreExpect(sqlite?.detail == "CC Switch", "sqlite detail should be display name")
    }

    static func standardPathsIncludePiSessions() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = LocalDependencyScanPaths.standard(home: home)
        let pi = paths.sessionDirectories.first { $0.displayName == "Pi" }
        try coreExpect(pi != nil, "standard paths 应包含 Pi 会话目录")
        try coreExpect(
            pi?.url.path == "/Users/example/.pi/agent/sessions",
            "Pi 会话目录 URL 错误: \(String(describing: pi?.url))"
        )
    }

    static func standardPathsIncludeZcodeDatabase() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let paths = LocalDependencyScanPaths.standard(home: home)
        let zcode = paths.sessionDirectories.first { $0.displayName == "ZCode" }
        try coreExpect(zcode != nil, "standard paths 应包含 ZCode 会话库")
        try coreExpect(
            zcode?.url.path == "/Users/example/.zcode/cli/db/db.sqlite",
            "ZCode 会话库 URL 错误: \(String(describing: zcode?.url))"
        )
    }

}
