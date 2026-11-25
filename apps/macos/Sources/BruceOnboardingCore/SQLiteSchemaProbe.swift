import Foundation

// MARK: - SQLiteSchemaProbeResult

public enum SQLiteSchemaProbeResult: String, Equatable, Sendable {
    case available
    case missing
    case locked
    case incompatible
    case corrupted
    case timedOut
}

// MARK: - SQLiteSchemaProfile

/// Collector 实际依赖的表和字段契约.
public struct SQLiteSchemaProfile: Sendable {
    public let displayName: String
    public let tables: [String: [String]]

    public init(displayName: String, tables: [String: [String]]) {
        self.displayName = displayName
        self.tables = tables
    }

    public static let ccSwitch = SQLiteSchemaProfile(
        displayName: "CC Switch",
        tables: [
            "providers": [
                "id", "name", "app_type", "settings_config", "meta", "is_current"
            ],
            "model_pricing": [
                "model_id",
                "input_cost_per_million",
                "output_cost_per_million",
                "cache_read_cost_per_million",
                "cache_creation_cost_per_million"
            ]
        ]
    )

}

// MARK: - SQLiteSchemaProbe

/// 使用真实查询契约验证 SQLite 兼容性, 始终以 mode=ro 只读打开.
/// 不执行 DDL, 迁移或写入. 不读取凭证值或活动明细.
/// locked 判定基于 sqlite3 stderr 中的 locked/busy 消息;
/// 字段检查逐行解析 PRAGMA table_info 的 cid|name|type 管道格式, 精确比较列名.
public struct SQLiteSchemaProbe: Sendable {
    private let sqlite3Path: String
    private let timeout: TimeInterval

    public init(sqlite3Path: String = "/usr/bin/sqlite3", timeout: TimeInterval = 8) {
        self.sqlite3Path = sqlite3Path
        self.timeout = timeout
    }

    /// 探测指定数据库文件的 schema 兼容性.
    /// C261: 建库检查、表存在性与各表 `PRAGMA table_info` 合并为一次 sqlite3 调用,
    /// 用标记行分隔输出, 不再为每张表串行拉起子进程。
    public func probe(
        fileURL: URL,
        profile: SQLiteSchemaProfile,
        fileManager: FileManager = .default
    ) async -> SQLiteSchemaProbeResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        let script = Self.probeScript(profile: profile)
        let openResult = await runSqlite(
            uri: "file:\(fileURL.path)?mode=ro",
            sql: script
        )
        switch openResult {
        case .timedOut:
            return .timedOut
        case .nonZeroExit(_, let stderrSummary):
            if Self.isLocked(stderrSummary: stderrSummary) {
                return .locked
            }
            return .corrupted
        case .cancelled, .launchFailed:
            return .corrupted
        case .success(let output):
            return Self.evaluate(output: output, profile: profile)
        }
    }

    /// 一次调用完成全部检查: 可打开性 / 每张表是否存在 / 每张表的列名.
    /// 标记行 (`BRUCE_TABLE:` / `BRUCE_COLUMNS:`) 把多段输出切成可解析的块。
    static func probeScript(profile: SQLiteSchemaProfile) -> String {
        var script = "SELECT 1;\n"
        for tableName in profile.tables.keys.sorted() {
            let escaped = tableName.replacingOccurrences(of: "'", with: "''")
            script += """
            SELECT 'BRUCE_TABLE:\(tableName)' FROM sqlite_master \
            WHERE type='table' AND name='\(escaped)';
            SELECT 'BRUCE_COLUMNS:\(tableName)';
            PRAGMA table_info('\(escaped)');

            """
        }
        return script
    }

    /// 解析合并脚本的输出并对照 profile 判定兼容性.
    static func evaluate(output: String, profile: SQLiteSchemaProfile) -> SQLiteSchemaProbeResult {
        var presentTables = Set<String>()
        var columnsByTable: [String: Set<String>] = [:]
        var currentTable: String?
        for line in outputLines(output) {
            if line == "1" {
                continue
            }
            if let table = marked(line, prefix: "BRUCE_TABLE:") {
                presentTables.insert(table)
                continue
            }
            if let table = marked(line, prefix: "BRUCE_COLUMNS:") {
                columnsByTable[table] = []
                currentTable = table
                continue
            }
            guard let table = currentTable else { continue }
            let fields = line.split(
                separator: "|", omittingEmptySubsequences: false
            )
            guard fields.count >= 2 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                columnsByTable[table, default: []].insert(name)
            }
        }
        for (tableName, columns) in profile.tables {
            guard presentTables.contains(tableName) else {
                return .incompatible
            }
            let actualColumns = columnsByTable[tableName] ?? []
            for column in columns where !actualColumns.contains(column) {
                return .incompatible
            }
        }
        return .available
    }

    private static func marked(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    /// locked 判定: 以 stderr 中的 locked/busy 消息为准, 不把任意非零退出当锁定.
    static func isLocked(stderrSummary: String?) -> Bool {
        guard let summary = stderrSummary?.lowercased(), !summary.isEmpty else {
            return false
        }
        return summary.contains("locked") || summary.contains("busy")
    }

    /// 按行拆分查询输出.
    static func outputLines(_ output: String) -> [String] {
        output.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// 解析 PRAGMA table_info 输出, 提取每行第二个管道字段 (列名).
    static func tableInfoColumnNames(_ output: String) -> Set<String> {
        var names = Set<String>()
        for line in output.split(separator: "\n") {
            let fields = line.split(
                separator: "|", omittingEmptySubsequences: false
            )
            guard fields.count >= 2 else { continue }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                names.insert(name)
            }
        }
        return names
    }

    private func runSqlite(uri: String, sql: String) async -> ProcessProbeResult {
        let probe = AsyncProcessProbe(timeout: timeout)
        return await probe.run(
            executablePath: sqlite3Path,
            arguments: [uri, sql]
        )
    }
}
