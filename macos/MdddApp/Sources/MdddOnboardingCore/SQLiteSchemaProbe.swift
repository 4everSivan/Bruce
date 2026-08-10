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

    public static let antigravity = SQLiteSchemaProfile(
        displayName: "Antigravity",
        tables: [
            "conversation_summaries": [
                "step_count", "last_modified_time"
            ]
        ]
    )

    /// opencode 会话库: agent 用量只读来源 (订阅额度不走本库).
    public static let opencode = SQLiteSchemaProfile(
        displayName: "OpenCode",
        tables: [
            "session": [
                "model", "tokens_input", "tokens_output",
                "tokens_cache_read", "tokens_cache_write",
                "time_created", "directory",
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
    public func probe(
        fileURL: URL,
        profile: SQLiteSchemaProfile,
        fileManager: FileManager = .default
    ) async -> SQLiteSchemaProbeResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .missing
        }

        // 先检查文件是否可打开 (检测损坏或锁定)
        let openResult = await runSqlite(
            uri: "file:\(fileURL.path)?mode=ro",
            sql: "SELECT 1;"
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
        case .success:
            break
        }

        // 检查每个需要的表和字段
        for (tableName, columns) in profile.tables {
            // 检查表是否存在 (精确匹配行, 不用子串)
            let tableResult = await runSqlite(
                uri: "file:\(fileURL.path)?mode=ro",
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='\(tableName)';"
            )

            switch tableResult {
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
                if !Self.outputLines(output).contains(tableName) {
                    return .incompatible
                }
            }

            // 检查字段: 一次性取 table_info, 逐行解析 cid|name|type|... 精确比较
            let columnResult = await runSqlite(
                uri: "file:\(fileURL.path)?mode=ro",
                sql: "PRAGMA table_info('\(tableName)');"
            )
            switch columnResult {
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
                let actualColumns = Self.tableInfoColumnNames(output)
                for column in columns where !actualColumns.contains(column) {
                    return .incompatible
                }
            }
        }

        return .available
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
