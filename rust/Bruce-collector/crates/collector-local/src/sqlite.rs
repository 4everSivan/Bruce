#![deny(unsafe_code)]

//! Read-only, bounded SQLite access for third-party application databases.

use collector_domain::Diagnostic;
use collector_runtime::RuntimeLimits;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension, Row};
use std::error::Error;
use std::fmt::{self, Display, Formatter};
use std::path::Path;

pub const DEFAULT_SQLITE_BATCH_SIZE: usize = 256;
pub const DEFAULT_SQLITE_MAX_ROWS: usize = 10_000;
pub const MAX_SQLITE_BATCH_SIZE: usize = 1_024;
pub const MAX_SQLITE_ROWS: usize = 100_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SqliteLimits {
    pub batch_size: usize,
    pub max_rows: usize,
}

impl Default for SqliteLimits {
    fn default() -> Self {
        Self {
            batch_size: DEFAULT_SQLITE_BATCH_SIZE,
            max_rows: DEFAULT_SQLITE_MAX_ROWS,
        }
    }
}

impl SqliteLimits {
    pub fn from_runtime_limits(limits: RuntimeLimits) -> Result<Self, SqliteReadError> {
        limits.validate().map_err(|_| {
            SqliteReadError::new(
                "SQLITE_INVALID_LIMIT",
                "protocol",
                "sqlite",
                "RuntimeLimits 的 SQLite 参数无效",
                false,
            )
        })?;
        Ok(Self {
            batch_size: limits.sqlite_batch_rows,
            max_rows: limits.sqlite_max_rows,
        })
    }
}

impl SqliteLimits {
    fn validate(self) -> Result<Self, SqliteReadError> {
        if self.batch_size == 0 || self.batch_size > MAX_SQLITE_BATCH_SIZE {
            return Err(SqliteReadError::new(
                "SQLITE_INVALID_LIMIT",
                "protocol",
                "sqlite",
                "SQLite batch size 超出安全范围",
                false,
            ));
        }
        if self.max_rows == 0 || self.max_rows > MAX_SQLITE_ROWS {
            return Err(SqliteReadError::new(
                "SQLITE_INVALID_LIMIT",
                "protocol",
                "sqlite",
                "SQLite max rows 超出安全范围",
                false,
            ));
        }
        Ok(self)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SqliteBoundedQuery {
    pub table: String,
    pub columns: Vec<String>,
    pub filter_column: String,
    pub lower_bound: i64,
    pub order_column: String,
    pub limits: SqliteLimits,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SqliteSchema {
    pub table: String,
    pub columns: Vec<String>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct SqliteReadStats {
    pub rows_read: u64,
    pub batches: u64,
    pub truncated: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SqliteReadError {
    pub diagnostic: Diagnostic,
}

impl SqliteReadError {
    fn new(
        code: impl Into<String>,
        category: impl Into<String>,
        stage: impl Into<String>,
        message: impl Into<String>,
        retryable: bool,
    ) -> Self {
        Self {
            diagnostic: Diagnostic::new(code, category, stage, message, retryable),
        }
    }
}

impl Display for SqliteReadError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.diagnostic.message)
    }
}

impl Error for SqliteReadError {}

/// Check that a third-party database contains the requested table and columns.
///
/// The connection is opened with SQLite read-only URI semantics. This function
/// never creates, migrates, repairs, or writes a database.
pub fn check_sqlite_schema(
    path: &Path,
    table: &str,
    required_columns: &[&str],
) -> Result<SqliteSchema, SqliteReadError> {
    validate_identifier(table)?;
    for column in required_columns {
        validate_identifier(column)?;
    }
    let connection = open_read_only(path)?;
    inspect_schema(&connection, table, required_columns)
}

/// Read rows in bounded batches with a parameterized lower-bound query.
///
/// The row callback is invoked immediately and rows are not retained by the
/// adapter. SQL identifiers are validated before interpolation; all values
/// (including the lower bound and LIMIT/OFFSET) are bound parameters.
pub fn read_bounded_sqlite_rows<F>(
    path: &Path,
    query: &SqliteBoundedQuery,
    mut on_row: F,
) -> Result<SqliteReadStats, SqliteReadError>
where
    F: FnMut(&Row<'_>) -> rusqlite::Result<()>,
{
    let limits = query.limits.validate()?;
    validate_identifier(&query.table)?;
    validate_identifier(&query.filter_column)?;
    validate_identifier(&query.order_column)?;
    if query.columns.is_empty() {
        return Err(SqliteReadError::new(
            "SQLITE_INVALID_QUERY",
            "protocol",
            "sqlite",
            "SQLite 查询必须选择至少一列",
            false,
        ));
    }
    for column in &query.columns {
        validate_identifier(column)?;
    }

    let connection = open_read_only(path)?;
    let mut required_columns = query.columns.iter().map(String::as_str).collect::<Vec<_>>();
    required_columns.push(query.filter_column.as_str());
    required_columns.push(query.order_column.as_str());
    inspect_schema(&connection, &query.table, &required_columns)?;

    let selected_columns = query
        .columns
        .iter()
        .map(|column| quote_identifier(column))
        .collect::<Vec<_>>()
        .join(", ");
    let table = quote_identifier(&query.table);
    let filter_column = quote_identifier(&query.filter_column);
    let order_column = quote_identifier(&query.order_column);
    let sql = format!(
        "SELECT {selected_columns} FROM {table} WHERE {filter_column} >= ?1 ORDER BY {order_column} ASC LIMIT ?2 OFFSET ?3"
    );
    let mut statement = connection.prepare(&sql).map_err(|error| {
        sqlite_error(
            "SQLITE_QUERY_PREPARE_FAILED",
            "query",
            "SQLite 查询准备失败",
            false,
            error,
        )
    })?;

    let mut stats = SqliteReadStats::default();
    let mut offset = 0usize;
    while stats.rows_read < limits.max_rows as u64 {
        let remaining = limits.max_rows - stats.rows_read as usize;
        let batch_size = limits.batch_size.min(remaining);
        let batch_size_i64 = i64::try_from(batch_size).map_err(|_| {
            SqliteReadError::new(
                "SQLITE_INVALID_LIMIT",
                "protocol",
                "sqlite",
                "SQLite batch size 无法转换为安全整数",
                false,
            )
        })?;
        let offset_i64 = i64::try_from(offset).map_err(|_| {
            SqliteReadError::new(
                "SQLITE_INVALID_LIMIT",
                "protocol",
                "sqlite",
                "SQLite offset 无法转换为安全整数",
                false,
            )
        })?;
        let mut rows = statement
            .query(params![query.lower_bound, batch_size_i64, offset_i64])
            .map_err(|error| {
                sqlite_error(
                    "SQLITE_QUERY_FAILED",
                    "query",
                    "SQLite 查询执行失败",
                    true,
                    error,
                )
            })?;
        let mut batch_rows = 0usize;
        while let Some(row) = rows.next().map_err(|error| {
            sqlite_error(
                "SQLITE_ROW_READ_FAILED",
                "query",
                "SQLite 行读取失败",
                true,
                error,
            )
        })? {
            on_row(row).map_err(|error| {
                sqlite_error(
                    "SQLITE_ROW_PARSE_FAILED",
                    "parse",
                    "SQLite 行解析失败",
                    false,
                    error,
                )
            })?;
            batch_rows += 1;
        }
        stats.batches = stats.batches.saturating_add(1);
        stats.rows_read = stats.rows_read.saturating_add(batch_rows as u64);
        if batch_rows < batch_size {
            break;
        }
        if stats.rows_read >= limits.max_rows as u64 {
            stats.truncated = true;
            break;
        }
        offset = offset.saturating_add(batch_rows);
    }
    Ok(stats)
}

fn open_read_only(path: &Path) -> Result<Connection, SqliteReadError> {
    let path = path.to_str().ok_or_else(|| {
        SqliteReadError::new(
            "SQLITE_INVALID_PATH",
            "local",
            "open",
            "SQLite 路径无法安全解析",
            false,
        )
    })?;
    let uri = format!("file:{}?mode=ro", encode_uri_path(path));
    Connection::open_with_flags(
        uri,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|error| {
        sqlite_error(
            "SQLITE_OPEN_FAILED",
            "local",
            "SQLite 只读打开失败",
            true,
            error,
        )
    })
}

fn inspect_schema(
    connection: &Connection,
    table: &str,
    required_columns: &[&str],
) -> Result<SqliteSchema, SqliteReadError> {
    let table_exists = connection
        .query_row(
            "SELECT name FROM sqlite_master WHERE type = ?1 AND name = ?2",
            params!["table", table],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(|error| {
            sqlite_error(
                "SQLITE_SCHEMA_CHECK_FAILED",
                "schema",
                "SQLite schema 检查失败",
                false,
                error,
            )
        })?;
    if table_exists.is_none() {
        return Err(SqliteReadError::new(
            "SQLITE_UNSUPPORTED_SCHEMA",
            "schema",
            "sqlite",
            "SQLite schema 缺少目标表",
            false,
        ));
    }

    let pragma = format!("PRAGMA table_info({})", quote_identifier(table));
    let mut statement = connection.prepare(&pragma).map_err(|error| {
        sqlite_error(
            "SQLITE_SCHEMA_CHECK_FAILED",
            "schema",
            "SQLite 列定义读取失败",
            false,
            error,
        )
    })?;
    let mut rows = statement.query([]).map_err(|error| {
        sqlite_error(
            "SQLITE_SCHEMA_CHECK_FAILED",
            "schema",
            "SQLite 列定义查询失败",
            false,
            error,
        )
    })?;
    let mut columns = Vec::new();
    while let Some(row) = rows.next().map_err(|error| {
        sqlite_error(
            "SQLITE_SCHEMA_CHECK_FAILED",
            "schema",
            "SQLite 列定义读取失败",
            false,
            error,
        )
    })? {
        if columns.len() >= 256 {
            return Err(SqliteReadError::new(
                "SQLITE_SCHEMA_TOO_LARGE",
                "schema",
                "sqlite",
                "SQLite schema 列数超出安全范围",
                false,
            ));
        }
        columns.push(row.get::<_, String>(1).map_err(|error| {
            sqlite_error(
                "SQLITE_SCHEMA_CHECK_FAILED",
                "schema",
                "SQLite 列名读取失败",
                false,
                error,
            )
        })?);
    }
    if required_columns
        .iter()
        .any(|required| !columns.iter().any(|column| column == required))
    {
        return Err(SqliteReadError::new(
            "SQLITE_UNSUPPORTED_SCHEMA",
            "schema",
            "sqlite",
            "SQLite schema 缺少必需列",
            false,
        ));
    }
    Ok(SqliteSchema {
        table: table.to_owned(),
        columns,
    })
}

fn validate_identifier(identifier: &str) -> Result<(), SqliteReadError> {
    let valid = !identifier.is_empty()
        && identifier.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphanumeric() && (index > 0 || !byte.is_ascii_digit())
                || byte == b'_' && index > 0
        });
    if valid {
        Ok(())
    } else {
        Err(SqliteReadError::new(
            "SQLITE_INVALID_IDENTIFIER",
            "protocol",
            "sqlite",
            "SQLite 表名或列名不符合安全标识符规则",
            false,
        ))
    }
}

fn quote_identifier(identifier: &str) -> String {
    format!("\"{identifier}\"")
}

fn encode_uri_path(path: &str) -> String {
    let mut encoded = String::with_capacity(path.len());
    for byte in path.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push(hex_digit(byte >> 4));
            encoded.push(hex_digit(byte & 0x0f));
        }
    }
    encoded
}

fn hex_digit(value: u8) -> char {
    match value {
        0..=9 => (b'0' + value) as char,
        _ => (b'A' + value - 10) as char,
    }
}

fn sqlite_error(
    code: &str,
    stage: &str,
    message: &str,
    retryable: bool,
    _error: rusqlite::Error,
) -> SqliteReadError {
    SqliteReadError::new(code, "local", stage, message, retryable)
}

#[cfg(test)]
mod tests {
    use super::{check_sqlite_schema, read_bounded_sqlite_rows, SqliteBoundedQuery, SqliteLimits};
    use rusqlite::{params, Connection};
    use std::fs;

    fn temp_db(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "bruce-collector-sqlite-{name}-{}-{}.db",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ))
    }

    #[test]
    fn checks_schema_and_reads_parameterized_rows_in_bounded_batches() {
        let path = temp_db("bounded");
        let _ = fs::remove_file(&path);
        let connection = Connection::open(&path).unwrap();
        connection
            .execute(
                "CREATE TABLE events (id INTEGER PRIMARY KEY, created_at INTEGER NOT NULL, payload TEXT NOT NULL)",
                [],
            )
            .unwrap();
        for id in 1..=5 {
            connection
                .execute(
                    "INSERT INTO events (id, created_at, payload) VALUES (?1, ?2, ?3)",
                    params![id, id * 10, format!("payload-{id}")],
                )
                .unwrap();
        }
        drop(connection);

        let schema =
            check_sqlite_schema(&path, "events", &["id", "created_at", "payload"]).unwrap();
        assert_eq!(schema.columns.len(), 3);
        let query = SqliteBoundedQuery {
            table: "events".to_owned(),
            columns: vec!["id".to_owned(), "payload".to_owned()],
            filter_column: "created_at".to_owned(),
            lower_bound: 20,
            order_column: "created_at".to_owned(),
            limits: SqliteLimits {
                batch_size: 2,
                max_rows: 3,
            },
        };
        let mut values = Vec::new();
        let stats = read_bounded_sqlite_rows(&path, &query, |row| {
            values.push((row.get::<_, i64>(0)?, row.get::<_, String>(1)?));
            Ok(())
        })
        .unwrap();
        assert_eq!(
            values,
            vec![
                (2, "payload-2".to_owned()),
                (3, "payload-3".to_owned()),
                (4, "payload-4".to_owned()),
            ]
        );
        assert_eq!(stats.rows_read, 3);
        assert_eq!(stats.batches, 2);
        assert!(stats.truncated);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn rejects_incompatible_schema_without_writing() {
        let path = temp_db("schema");
        let _ = fs::remove_file(&path);
        let connection = Connection::open(&path).unwrap();
        connection
            .execute("CREATE TABLE events (id INTEGER PRIMARY KEY)", [])
            .unwrap();
        drop(connection);
        let error = check_sqlite_schema(&path, "events", &["created_at"]).unwrap_err();
        assert_eq!(error.diagnostic.code, "SQLITE_UNSUPPORTED_SCHEMA");
        let read_only =
            Connection::open_with_flags(&path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert!(read_only
            .execute("CREATE TABLE should_not_exist (id INTEGER)", [])
            .is_err());
        drop(read_only);
        let _ = fs::remove_file(path);
    }
}
