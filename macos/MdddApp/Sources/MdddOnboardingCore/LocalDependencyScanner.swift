import Foundation

// MARK: - LocalDependencyScanPaths

/// 扫描所需的全部本机路径, 显式注入, 不存在读取真实用户目录的隐式全局状态.
public struct LocalDependencyScanPaths: Sendable {
    /// 会话目录候选: 展示名 (不含完整路径) 和目录 URL.
    public struct SessionDirectory: Sendable, Equatable {
        public let displayName: String
        public let url: URL

        public init(displayName: String, url: URL) {
            self.displayName = displayName
            self.url = url
        }
    }

    /// SQLite 数据库候选: schema profile 和文件 URL.
    public struct SQLiteDatabase: Sendable {
        public let profile: SQLiteSchemaProfile
        public let url: URL

        public init(profile: SQLiteSchemaProfile, url: URL) {
            self.profile = profile
            self.url = url
        }
    }

    public var userPreferredPythonPath: String?
    public var pythonCandidates: [String]
    public var sessionDirectories: [SessionDirectory]
    public var sqliteDatabases: [SQLiteDatabase]

    public init(
        userPreferredPythonPath: String? = nil,
        pythonCandidates: [String] = PythonPathResolver.defaultCandidates,
        sessionDirectories: [SessionDirectory] = [],
        sqliteDatabases: [SQLiteDatabase] = []
    ) {
        self.userPreferredPythonPath = userPreferredPythonPath
        self.pythonCandidates = pythonCandidates
        self.sessionDirectories = sessionDirectories
        self.sqliteDatabases = sqliteDatabases
    }

    /// 基于显式传入的 home 目录构造标准候选集合.
    /// 调用方负责提供 home; 本函数不隐式读取真实用户目录.
    public static func standard(home: URL) -> LocalDependencyScanPaths {
        LocalDependencyScanPaths(
            sessionDirectories: [
                SessionDirectory(
                    displayName: "Kimi Work",
                    url: home.appendingPathComponent(
                        "Library/Application Support/kimi-desktop"
                    )
                ),
                SessionDirectory(
                    displayName: "Kimi Code CLI",
                    url: home.appendingPathComponent(".kimi-code/sessions")
                ),
                SessionDirectory(
                    displayName: "Claude Code",
                    url: home.appendingPathComponent(".claude/projects")
                ),
                SessionDirectory(
                    displayName: "Codex CLI",
                    url: home.appendingPathComponent(".codex/sessions")
                ),
            ],
            sqliteDatabases: [
                SQLiteDatabase(
                    profile: .ccSwitch,
                    url: home.appendingPathComponent(".cc-switch/cc-switch.db")
                ),
                SQLiteDatabase(
                    profile: .antigravity,
                    url: home.appendingPathComponent(
                        ".gemini/antigravity-cli/conversation_summaries.db"
                    )
                ),
            ]
        )
    }
}

// MARK: - LocalDependencyScanner

/// 异步, 非 MainActor 的本机只读扫描服务.
/// 扫描 Python 和 gh 版本, 会话目录存在性, 以及 SQLite schema 兼容性.
/// 不检查 gh 登录态 (属于 ProviderConnectionVerifier), 不发出任何网络请求.
public struct LocalDependencyScanner: Sendable {
    private let paths: LocalDependencyScanPaths
    private let processProbe: AsyncProcessProbe
    private let sqliteProbe: SQLiteSchemaProbe

    public init(
        paths: LocalDependencyScanPaths,
        processProbe: AsyncProcessProbe = AsyncProcessProbe(),
        sqliteProbe: SQLiteSchemaProbe = SQLiteSchemaProbe()
    ) {
        self.paths = paths
        self.processProbe = processProbe
        self.sqliteProbe = sqliteProbe
    }

    /// 执行完整本机扫描, 返回所有探测项.
    public func scan() async -> [DependencyProbe] {
        var probes: [DependencyProbe] = []
        probes.append(await scanPython())
        probes.append(contentsOf: scanSessionDirectories())
        for database in paths.sqliteDatabases {
            probes.append(await scanSQLite(database))
        }
        return probes
    }

    /// 扫描 Python: 解析绝对路径, 运行 --version 并校验最低版本.
    public func scanPython() async -> DependencyProbe {
        guard let pythonPath = PythonPathResolver.resolve(
            userPreferred: paths.userPreferredPythonPath,
            candidates: paths.pythonCandidates,
            fileManager: .default
        ) else {
            return DependencyProbe(kind: .python, status: .missing)
        }

        let result = await processProbe.run(
            executablePath: pythonPath,
            arguments: ["--version"]
        )
        switch result {
        case .success(let output):
            let version = PythonVersionParser.parse(output)
            guard PythonVersionParser.isCompatible(version) else {
                // 版本可解析但过低, 或输出无法解析: 都是 incompatible, 不伪装为 missing
                return DependencyProbe(
                    kind: .python, status: .incompatible,
                    detail: result.firstLine
                )
            }
            return DependencyProbe(
                kind: .python, status: .available,
                detail: result.firstLine
            )
        case .timedOut:
            return DependencyProbe(kind: .python, status: .timedOut)
        case .nonZeroExit:
            // 文件存在但无法正常执行版本检查
            return DependencyProbe(kind: .python, status: .incompatible)
        case .cancelled:
            return DependencyProbe(kind: .python, status: .timedOut)
        case .launchFailed:
            return DependencyProbe(kind: .python, status: .missing)
        }
    }

    /// 扫描会话目录存在性, 只读.
    public func scanSessionDirectories() -> [DependencyProbe] {
        paths.sessionDirectories.map { candidate in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: candidate.url.path,
                isDirectory: &isDirectory
            ) && isDirectory.boolValue
            return DependencyProbe(
                kind: .sessionDirectory,
                status: exists ? .available : .missing,
                detail: candidate.displayName
            )
        }
    }

    /// 扫描单个 SQLite 数据库的 schema 兼容性.
    public func scanSQLite(
        _ database: LocalDependencyScanPaths.SQLiteDatabase
    ) async -> DependencyProbe {
        let result = await sqliteProbe.probe(
            fileURL: database.url,
            profile: database.profile,
            fileManager: .default
        )
        let status: LocalDependencyStatus
        switch result {
        case .available:
            status = .available
        case .missing:
            status = .missing
        case .locked:
            status = .locked
        case .incompatible:
            status = .incompatible
        case .corrupted:
            status = .corrupted
        case .timedOut:
            status = .timedOut
        }
        return DependencyProbe(
            kind: .sqliteDatabase,
            status: status,
            detail: database.profile.displayName
        )
    }
}
