use super::{
    finish, number_u64, project_from_zcode, record, timestamp_number, SourceScan, SourceScanError,
    MAX_SOURCE_ROWS,
};
use crate::sqlite_cache::{
    scan_sqlite_cached, SqliteCacheConfig, SqliteCursor, SqliteIncrementalAdapter, SqliteReadResult,
};
use crate::ScanStats;
use collector_domain::{CollectionWindow, UsageContribution, UsageContributionBuilder};
use collector_runtime::CancellationToken;
use rusqlite::{Connection, OpenFlags};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io;
use std::path::Path;

fn sqlite_error(window: &CollectionWindow, message: &str) -> SourceScan {
    let mut result = SourceScan::empty(window);
    result.diagnostic = Some(message.to_owned());
    result
}

fn open_read_only(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_URI,
    )
}

fn sqlite_schema_error(message: impl Into<String>) -> SourceScanError {
    SourceScanError::Io(io::Error::new(io::ErrorKind::InvalidData, message.into()))
}

fn sqlite_query_error(message: impl Into<String>) -> SourceScanError {
    SourceScanError::Io(io::Error::other(message.into()))
}

fn sqlite_table_columns(
    connection: &Connection,
    table: &str,
) -> Result<Vec<(String, String)>, SourceScanError> {
    let pragma = format!("PRAGMA table_info({table})");
    let mut statement = connection
        .prepare(&pragma)
        .map_err(|_| sqlite_schema_error("sqlite table_info query failed"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .map_err(|_| sqlite_schema_error("sqlite table_info query failed"))?;
    let mut columns = Vec::new();
    for row in rows {
        columns.push(row.map_err(|_| sqlite_schema_error("sqlite table_info query failed"))?);
    }
    if columns.is_empty() {
        return Err(sqlite_schema_error("sqlite table is missing"));
    }
    Ok(columns)
}

fn sqlite_schema_fingerprint(
    connection: &Connection,
    tables: &[&str],
) -> Result<String, SourceScanError> {
    let mut hasher = Sha256::new();
    for table in tables {
        let sql = connection
            .query_row(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1",
                [*table],
                |row| row.get::<_, Option<String>>(0),
            )
            .map_err(|_| sqlite_schema_error("sqlite schema query failed"))?
            .ok_or_else(|| sqlite_schema_error("sqlite table is missing"))?;
        let columns = sqlite_table_columns(connection, table)?;
        hasher.update(table.as_bytes());
        hasher.update(sql.as_bytes());
        for (name, kind) in columns {
            hasher.update(name.as_bytes());
            hasher.update(kind.as_bytes());
        }
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn merge_sqlite_contributions(
    base: &UsageContribution,
    delta: &UsageContribution,
    window: &CollectionWindow,
) -> UsageContribution {
    let mut builder = UsageContributionBuilder::new(window.clone());
    if !builder.merge_contribution(base) || !builder.merge_contribution(delta) {
        return base.clone();
    }
    builder.contribution()
}

#[derive(Debug, Clone)]
struct OpenCodeRow {
    rowid: Option<i64>,
    data: String,
}

struct OpenCodeSqliteAdapter;

impl OpenCodeSqliteAdapter {
    fn has_rows(connection: &Connection) -> Result<bool, SourceScanError> {
        match connection.query_row("SELECT 1 FROM message LIMIT 1", [], |row| {
            row.get::<_, i64>(0)
        }) {
            Ok(_) => Ok(true),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(false),
            Err(_) => Err(sqlite_query_error("opencode message query failed")),
        }
    }

    fn read_rows(
        connection: &Connection,
        cursor: Option<&SqliteCursor>,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<(Vec<OpenCodeRow>, bool), SourceScanError> {
        cancellation.check()?;
        let mut rows = Vec::new();
        let mut rowid_supported = true;
        if let Some(cursor) = cursor {
            let Some(rowid) = cursor.rowid else {
                return Err(sqlite_schema_error("opencode row cursor is unavailable"));
            };
            let mut statement = connection
                .prepare(
                    "SELECT rowid, data FROM message \
                     WHERE rowid > ?1 AND data LIKE '%tokens%' \
                     ORDER BY rowid ASC LIMIT ?2",
                )
                .map_err(|_| sqlite_schema_error("opencode row cursor is unavailable"))?;
            let result = statement
                .query_map(rusqlite::params![rowid, MAX_SOURCE_ROWS], |row| {
                    Ok(OpenCodeRow {
                        rowid: Some(row.get(0)?),
                        data: row.get(1)?,
                    })
                })
                .map_err(|_| sqlite_query_error("opencode incremental query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("opencode row read failed"))?);
            }
            let capped = rows.len() as i64 >= MAX_SOURCE_ROWS;
            return Ok((rows, capped));
        }

        let mut statement = match connection.prepare(
            "SELECT rowid, data FROM message \
             WHERE data LIKE '%tokens%' ORDER BY rowid DESC LIMIT ?1",
        ) {
            Ok(statement) => statement,
            Err(_) => {
                rowid_supported = false;
                connection
                    .prepare("SELECT data FROM message WHERE data LIKE '%tokens%' LIMIT ?1")
                    .map_err(|_| sqlite_query_error("opencode message query failed"))?
            }
        };
        if rowid_supported {
            let result = statement
                .query_map([MAX_SOURCE_ROWS], |row| {
                    Ok(OpenCodeRow {
                        rowid: Some(row.get(0)?),
                        data: row.get(1)?,
                    })
                })
                .map_err(|_| sqlite_query_error("opencode message query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("opencode row read failed"))?);
            }
        } else {
            let result = statement
                .query_map([MAX_SOURCE_ROWS], |row| {
                    Ok(OpenCodeRow {
                        rowid: None,
                        data: row.get(0)?,
                    })
                })
                .map_err(|_| sqlite_query_error("opencode message query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("opencode row read failed"))?);
            }
        }
        rows.reverse();
        let capped = rows.len() as i64 >= MAX_SOURCE_ROWS || !rowid_supported;
        Ok((rows, capped))
    }

    fn parse_rows(
        rows: &[OpenCodeRow],
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<(UsageContribution, SqliteCursor), SourceScanError> {
        let mut builder = UsageContributionBuilder::new(window.clone());
        let mut cursor = SqliteCursor::default();
        for row in rows {
            cancellation.check()?;
            if let Some(rowid) = row.rowid {
                cursor.rowid = Some(cursor.rowid.unwrap_or(rowid).max(rowid));
            }
            let Ok(value) = serde_json::from_str::<Value>(&row.data) else {
                stats.malformed_lines = stats.malformed_lines.saturating_add(1);
                continue;
            };
            stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
            if value.get("role").and_then(Value::as_str) != Some("assistant") {
                continue;
            }
            let tokens = value.get("tokens").unwrap_or(&Value::Null);
            let Some(created) =
                timestamp_number(value.get("time").and_then(|value| value.get("created")))
            else {
                continue;
            };
            cursor.timestamp_millis = Some(cursor.timestamp_millis.unwrap_or(created).max(created));
            if created < (window.cutoff_ts * 1000.0) as i64 {
                continue;
            }
            let cache = tokens.get("cache").unwrap_or(&Value::Null);
            record(
                &mut builder,
                created,
                value
                    .get("modelID")
                    .and_then(Value::as_str)
                    .or(Some("opencode")),
                number_u64(tokens.get("input")),
                number_u64(tokens.get("output"))
                    .saturating_add(number_u64(tokens.get("reasoning"))),
                number_u64(cache.get("read")),
                number_u64(cache.get("write")),
                None,
            );
            stats.usage_records = stats.usage_records.saturating_add(1);
        }
        Ok((builder.contribution(), cursor))
    }
}

impl SqliteIncrementalAdapter for OpenCodeSqliteAdapter {
    fn source_id(&self) -> &'static str {
        "opencode"
    }

    fn schema_fingerprint(&self, connection: &Connection) -> Result<String, SourceScanError> {
        let columns = sqlite_table_columns(connection, "message")?;
        if !columns.iter().any(|(name, _)| name == "data") {
            return Err(sqlite_schema_error(
                "opencode message.data column is missing",
            ));
        }
        sqlite_schema_fingerprint(connection, &["message"])
    }

    fn read_full(
        &self,
        connection: &Connection,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError> {
        let found = Self::has_rows(connection)?;
        let (rows, capped) = Self::read_rows(connection, None, cancellation, stats)?;
        let (contribution, cursor) = Self::parse_rows(&rows, window, cancellation, stats)?;
        Ok(SqliteReadResult {
            contribution,
            cursor,
            found,
            rows_read: rows.len() as u64,
            diagnostic: capped
                .then(|| format!("仅保留 opencode 最新 {MAX_SOURCE_ROWS} 条候选消息")),
            append_safe: !capped && rows.iter().all(|row| row.rowid.is_some()),
            capped,
        })
    }

    fn read_since(
        &self,
        connection: &Connection,
        cursor: &SqliteCursor,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError> {
        let (rows, capped) = Self::read_rows(connection, Some(cursor), cancellation, stats)?;
        let (contribution, cursor) = Self::parse_rows(&rows, window, cancellation, stats)?;
        Ok(SqliteReadResult {
            contribution,
            cursor,
            found: !rows.is_empty(),
            rows_read: rows.len() as u64,
            diagnostic: capped.then(|| "opencode 增量候选消息超过上限, 已回退全量读取".to_owned()),
            append_safe: !capped && rows.iter().all(|row| row.rowid.is_some()),
            capped,
        })
    }

    fn merge_delta(
        &self,
        base: &UsageContribution,
        delta: &UsageContribution,
        window: &CollectionWindow,
    ) -> UsageContribution {
        merge_sqlite_contributions(base, delta, window)
    }
}

fn opencode_cache_config(cache_root: &Path, window: &CollectionWindow) -> SqliteCacheConfig {
    SqliteCacheConfig {
        cache_root: cache_root.to_owned(),
        source_id: "opencode".to_owned(),
        parser_version: 1,
        window: window.clone(),
    }
}

pub fn scan_opencode_cached(
    path: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_sqlite_cached(
        path,
        &opencode_cache_config(cache_root, window),
        &OpenCodeSqliteAdapter,
        cancellation,
    )
}

#[derive(Debug, Clone)]
struct ZCodeRow {
    rowid: Option<i64>,
    started_at: i64,
    model: Option<String>,
    input: Option<i64>,
    output: Option<i64>,
    reasoning: Option<i64>,
    cache_creation: Option<i64>,
    cache_read: Option<i64>,
    directory: Option<String>,
    task_type: Option<String>,
}

struct ZCodeSqliteAdapter;

impl ZCodeSqliteAdapter {
    fn has_rows(connection: &Connection) -> Result<bool, SourceScanError> {
        match connection.query_row("SELECT 1 FROM model_usage LIMIT 1", [], |row| {
            row.get::<_, i64>(0)
        }) {
            Ok(_) => Ok(true),
            Err(rusqlite::Error::QueryReturnedNoRows) => Ok(false),
            Err(_) => Err(sqlite_query_error("zcode model_usage query failed")),
        }
    }

    fn read_rows(
        connection: &Connection,
        cursor: Option<&SqliteCursor>,
        cutoff_ms: i64,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<(Vec<ZCodeRow>, bool), SourceScanError> {
        cancellation.check()?;
        let mut rows = Vec::new();
        if let Some(cursor) = cursor {
            let Some(rowid) = cursor.rowid else {
                return Err(sqlite_schema_error("zcode row cursor is unavailable"));
            };
            let mut statement = connection
                .prepare(
                    "SELECT m.rowid, m.started_at, m.model_id, m.input_tokens, \
                     m.output_tokens, m.reasoning_tokens, m.cache_creation_input_tokens, \
                     m.cache_read_input_tokens, s.directory, s.task_type \
                     FROM model_usage m LEFT JOIN session s ON s.id = m.session_id \
                     WHERE m.rowid > ?1 AND m.started_at >= ?2 \
                     ORDER BY m.rowid ASC LIMIT ?3",
                )
                .map_err(|_| sqlite_schema_error("zcode row cursor is unavailable"))?;
            let result = statement
                .query_map(
                    rusqlite::params![rowid, cutoff_ms, MAX_SOURCE_ROWS],
                    |row| {
                        Ok(ZCodeRow {
                            rowid: Some(row.get(0)?),
                            started_at: row.get(1)?,
                            model: row.get(2)?,
                            input: row.get(3)?,
                            output: row.get(4)?,
                            reasoning: row.get(5)?,
                            cache_creation: row.get(6)?,
                            cache_read: row.get(7)?,
                            directory: row.get(8)?,
                            task_type: row.get(9)?,
                        })
                    },
                )
                .map_err(|_| sqlite_query_error("zcode incremental query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("zcode row read failed"))?);
            }
            let capped = rows.len() as i64 >= MAX_SOURCE_ROWS;
            return Ok((rows, capped));
        }

        let mut rowid_supported = true;
        let mut statement = match connection.prepare(
            "SELECT m.rowid, m.started_at, m.model_id, m.input_tokens, \
             m.output_tokens, m.reasoning_tokens, m.cache_creation_input_tokens, \
             m.cache_read_input_tokens, s.directory, s.task_type \
             FROM model_usage m LEFT JOIN session s ON s.id = m.session_id \
             WHERE m.started_at >= ?1 ORDER BY m.started_at DESC LIMIT ?2",
        ) {
            Ok(statement) => statement,
            Err(_) => {
                rowid_supported = false;
                connection
                    .prepare(
                        "SELECT m.started_at, m.model_id, m.input_tokens, m.output_tokens, \
                         m.reasoning_tokens, m.cache_creation_input_tokens, \
                         m.cache_read_input_tokens, s.directory, s.task_type \
                         FROM model_usage m LEFT JOIN session s ON s.id = m.session_id \
                         WHERE m.started_at >= ?1 ORDER BY m.started_at DESC LIMIT ?2",
                    )
                    .map_err(|_| sqlite_query_error("zcode model_usage query failed"))?
            }
        };
        if rowid_supported {
            let result = statement
                .query_map(rusqlite::params![cutoff_ms, MAX_SOURCE_ROWS], |row| {
                    Ok(ZCodeRow {
                        rowid: Some(row.get(0)?),
                        started_at: row.get(1)?,
                        model: row.get(2)?,
                        input: row.get(3)?,
                        output: row.get(4)?,
                        reasoning: row.get(5)?,
                        cache_creation: row.get(6)?,
                        cache_read: row.get(7)?,
                        directory: row.get(8)?,
                        task_type: row.get(9)?,
                    })
                })
                .map_err(|_| sqlite_query_error("zcode model_usage query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("zcode row read failed"))?);
            }
        } else {
            let result = statement
                .query_map(rusqlite::params![cutoff_ms, MAX_SOURCE_ROWS], |row| {
                    Ok(ZCodeRow {
                        rowid: None,
                        started_at: row.get(0)?,
                        model: row.get(1)?,
                        input: row.get(2)?,
                        output: row.get(3)?,
                        reasoning: row.get(4)?,
                        cache_creation: row.get(5)?,
                        cache_read: row.get(6)?,
                        directory: row.get(7)?,
                        task_type: row.get(8)?,
                    })
                })
                .map_err(|_| sqlite_query_error("zcode model_usage query failed"))?;
            for row in result {
                cancellation.check()?;
                stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
                rows.push(row.map_err(|_| sqlite_query_error("zcode row read failed"))?);
            }
        }
        rows.reverse();
        let capped = rows.len() as i64 >= MAX_SOURCE_ROWS || !rowid_supported;
        Ok((rows, capped))
    }

    fn parse_rows(
        rows: &[ZCodeRow],
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<(UsageContribution, SqliteCursor), SourceScanError> {
        let mut builder = UsageContributionBuilder::new(window.clone());
        let mut cursor = SqliteCursor::default();
        for row in rows {
            cancellation.check()?;
            if let Some(rowid) = row.rowid {
                cursor.rowid = Some(cursor.rowid.unwrap_or(rowid).max(rowid));
            }
            cursor.timestamp_millis = Some(
                cursor
                    .timestamp_millis
                    .unwrap_or(row.started_at)
                    .max(row.started_at),
            );
            let input = u64::try_from(row.input.unwrap_or(0)).unwrap_or(0);
            let output = u64::try_from(row.output.unwrap_or(0)).unwrap_or(0);
            let reasoning = u64::try_from(row.reasoning.unwrap_or(0)).unwrap_or(0);
            let cache_creation = u64::try_from(row.cache_creation.unwrap_or(0)).unwrap_or(0);
            let cache_read = u64::try_from(row.cache_read.unwrap_or(0)).unwrap_or(0);
            if input == 0 && output == 0 && reasoning == 0 && cache_creation == 0 && cache_read == 0
            {
                continue;
            }
            let project = project_from_zcode(row.directory.clone(), row.task_type.clone());
            record(
                &mut builder,
                row.started_at,
                row.model.as_deref().or(Some("unknown")),
                input
                    .saturating_sub(cache_read)
                    .saturating_sub(cache_creation),
                output.saturating_add(reasoning),
                cache_read,
                cache_creation,
                project.as_deref(),
            );
            stats.usage_records = stats.usage_records.saturating_add(1);
        }
        Ok((builder.contribution(), cursor))
    }
}

impl SqliteIncrementalAdapter for ZCodeSqliteAdapter {
    fn source_id(&self) -> &'static str {
        "zcode"
    }

    fn schema_fingerprint(&self, connection: &Connection) -> Result<String, SourceScanError> {
        let usage_columns = sqlite_table_columns(connection, "model_usage")?;
        let required_usage = [
            "started_at",
            "model_id",
            "input_tokens",
            "output_tokens",
            "reasoning_tokens",
            "cache_creation_input_tokens",
            "cache_read_input_tokens",
            "session_id",
        ];
        if required_usage
            .iter()
            .any(|name| !usage_columns.iter().any(|(column, _)| column == name))
        {
            return Err(sqlite_schema_error(
                "zcode model_usage columns are incompatible",
            ));
        }
        let session_columns = sqlite_table_columns(connection, "session")?;
        if ["id", "directory", "task_type"]
            .iter()
            .any(|name| !session_columns.iter().any(|(column, _)| column == name))
        {
            return Err(sqlite_schema_error(
                "zcode session columns are incompatible",
            ));
        }
        sqlite_schema_fingerprint(connection, &["model_usage", "session"])
    }

    fn read_full(
        &self,
        connection: &Connection,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError> {
        let found = Self::has_rows(connection)?;
        let cutoff_ms = (window.cutoff_ts * 1000.0) as i64;
        let (rows, capped) = Self::read_rows(connection, None, cutoff_ms, cancellation, stats)?;
        let (contribution, cursor) = Self::parse_rows(&rows, window, cancellation, stats)?;
        Ok(SqliteReadResult {
            contribution,
            cursor,
            found,
            rows_read: rows.len() as u64,
            diagnostic: capped.then(|| format!("仅保留 zcode 最新 {MAX_SOURCE_ROWS} 条用量记录")),
            append_safe: !capped && rows.iter().all(|row| row.rowid.is_some()),
            capped,
        })
    }

    fn read_since(
        &self,
        connection: &Connection,
        cursor: &SqliteCursor,
        window: &CollectionWindow,
        cancellation: &CancellationToken,
        stats: &mut ScanStats,
    ) -> Result<SqliteReadResult, SourceScanError> {
        let cutoff_ms = (window.cutoff_ts * 1000.0) as i64;
        let (rows, capped) =
            Self::read_rows(connection, Some(cursor), cutoff_ms, cancellation, stats)?;
        let (contribution, cursor) = Self::parse_rows(&rows, window, cancellation, stats)?;
        Ok(SqliteReadResult {
            contribution,
            cursor,
            found: !rows.is_empty(),
            rows_read: rows.len() as u64,
            diagnostic: capped.then(|| "zcode 增量用量记录超过上限, 已回退全量读取".to_owned()),
            append_safe: !capped && rows.iter().all(|row| row.rowid.is_some()),
            capped,
        })
    }

    fn merge_delta(
        &self,
        base: &UsageContribution,
        delta: &UsageContribution,
        window: &CollectionWindow,
    ) -> UsageContribution {
        merge_sqlite_contributions(base, delta, window)
    }
}

fn zcode_cache_config(cache_root: &Path, window: &CollectionWindow) -> SqliteCacheConfig {
    SqliteCacheConfig {
        cache_root: cache_root.to_owned(),
        source_id: "zcode".to_owned(),
        parser_version: 1,
        window: window.clone(),
    }
}

pub fn scan_zcode_cached(
    path: &Path,
    window: &CollectionWindow,
    cache_root: &Path,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    scan_sqlite_cached(
        path,
        &zcode_cache_config(cache_root, window),
        &ZCodeSqliteAdapter,
        cancellation,
    )
}

pub fn scan_opencode(path: &Path, window: &CollectionWindow) -> SourceScan {
    scan_opencode_with_cancellation(path, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_opencode_with_cancellation(
    path: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    cancellation.check()?;
    if !path.is_file() {
        return Ok(SourceScan::empty(window));
    }
    let connection = match open_read_only(path) {
        Ok(connection) => connection,
        Err(_) => return Ok(sqlite_error(window, "本机 opencode 数据库暂不可读")),
    };
    let any_message = match connection.query_row("SELECT 1 FROM message LIMIT 1", [], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(_) => true,
        Err(rusqlite::Error::QueryReturnedNoRows) => false,
        Err(_) => return Ok(sqlite_error(window, "本机 opencode 数据库 schema 不兼容")),
    };
    if !any_message {
        return Ok(SourceScan::empty(window));
    }
    // 行数超上限时按 rowid DESC 截断, 保留最新插入的消息 (rowid 随追加单调递增);
    // WITHOUT ROWID 表不支持该排序时回退旧行为 (无序全量前 N 行), 不把兼容性变成报错.
    let mut statement = match connection
        .prepare("SELECT data FROM message WHERE data LIKE '%tokens%' ORDER BY rowid DESC LIMIT ?1")
        .or_else(|_| {
            connection.prepare("SELECT data FROM message WHERE data LIKE '%tokens%' LIMIT ?1")
        }) {
        Ok(statement) => statement,
        Err(_) => return Ok(sqlite_error(window, "本机 opencode 数据库 schema 不兼容")),
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let rows = match statement.query_map([MAX_SOURCE_ROWS], |row| row.get::<_, String>(0)) {
        Ok(rows) => rows,
        Err(_) => return Ok(sqlite_error(window, "本机 opencode 数据库查询失败")),
    };
    let mut collected = Vec::new();
    for row in rows {
        cancellation.check()?;
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok(data) = row else { continue };
        collected.push(data);
    }
    let capped = collected.len() as i64 >= MAX_SOURCE_ROWS;
    // 回放顺序反转为时间升序, 保持聚合语义与全量扫描一致.
    for data in collected.into_iter().rev() {
        cancellation.check()?;
        let Ok(value) = serde_json::from_str::<Value>(&data) else {
            stats.malformed_lines = stats.malformed_lines.saturating_add(1);
            continue;
        };
        stats.json_lines_parsed = stats.json_lines_parsed.saturating_add(1);
        if value.get("role").and_then(Value::as_str) != Some("assistant") {
            continue;
        }
        let tokens = value.get("tokens").unwrap_or(&Value::Null);
        let Some(created) =
            timestamp_number(value.get("time").and_then(|value| value.get("created")))
        else {
            continue;
        };
        if created < (window.cutoff_ts * 1000.0) as i64 {
            continue;
        }
        let cache = tokens.get("cache").unwrap_or(&Value::Null);
        record(
            &mut builder,
            created,
            value
                .get("modelID")
                .and_then(Value::as_str)
                .or(Some("opencode")),
            number_u64(tokens.get("input")),
            number_u64(tokens.get("output")).saturating_add(number_u64(tokens.get("reasoning"))),
            number_u64(cache.get("read")),
            number_u64(cache.get("write")),
            None,
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    }
    // C041: 截断标记随扫描返回, 上游归为信息级降级而非故障。
    let mut scan = finish(window, builder, stats, true);
    scan.capped = capped;
    Ok(scan)
}

pub fn scan_zcode(path: &Path, window: &CollectionWindow) -> SourceScan {
    scan_zcode_with_cancellation(path, window, &CancellationToken::new())
        .unwrap_or_else(|_| SourceScan::empty(window))
}

pub fn scan_zcode_with_cancellation(
    path: &Path,
    window: &CollectionWindow,
    cancellation: &CancellationToken,
) -> Result<SourceScan, SourceScanError> {
    cancellation.check()?;
    if !path.is_file() {
        return Ok(SourceScan::empty(window));
    }
    let connection = match open_read_only(path) {
        Ok(connection) => connection,
        Err(error) => {
            return Ok(sqlite_error(
                window,
                &format!("本机 zcode 数据库暂不可读: {error}"),
            ))
        }
    };
    let any_usage = match connection.query_row("SELECT 1 FROM model_usage LIMIT 1", [], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(_) => true,
        Err(rusqlite::Error::QueryReturnedNoRows) => false,
        Err(error) => {
            return Ok(sqlite_error(
                window,
                &format!("本机 zcode 数据库 schema 不兼容: {error}"),
            ))
        }
    };
    if !any_usage {
        return Ok(SourceScan::empty(window));
    }
    let mut statement = match connection.prepare(
        "SELECT m.started_at, m.model_id, m.input_tokens, m.output_tokens, \
         m.reasoning_tokens, m.cache_creation_input_tokens, m.cache_read_input_tokens, \
         s.directory, s.task_type FROM model_usage m LEFT JOIN session s ON s.id = m.session_id \
         WHERE m.started_at >= ?1 ORDER BY m.started_at DESC LIMIT ?2",
    ) {
        Ok(statement) => statement,
        Err(error) => {
            return Ok(sqlite_error(
                window,
                &format!("本机 zcode 数据库 schema 不兼容: {error}"),
            ))
        }
    };
    let mut builder = UsageContributionBuilder::new(window.clone());
    let mut stats = ScanStats::default();
    let cutoff_ms = (window.cutoff_ts * 1000.0) as i64;
    // 行数超上限时按 started_at DESC 截断, 保留最新记录 (旧记录滑出窗口后自愈);
    // 折叠前反转回时间升序, 保持模型出现顺序等聚合语义与全量扫描一致.
    let rows = match statement.query_map([cutoff_ms, MAX_SOURCE_ROWS], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Option<i64>>(2)?,
            row.get::<_, Option<i64>>(3)?,
            row.get::<_, Option<i64>>(4)?,
            row.get::<_, Option<i64>>(5)?,
            row.get::<_, Option<i64>>(6)?,
            row.get::<_, Option<String>>(7)?,
            row.get::<_, Option<String>>(8)?,
        ))
    }) {
        Ok(rows) => rows,
        Err(error) => {
            return Ok(sqlite_error(
                window,
                &format!("本机 zcode 数据库查询失败: {error}"),
            ))
        }
    };
    let mut collected = Vec::new();
    for row in rows {
        cancellation.check()?;
        stats.sqlite_rows_read = stats.sqlite_rows_read.saturating_add(1);
        let Ok(row) = row else { continue };
        collected.push(row);
    }
    let capped = collected.len() as i64 >= MAX_SOURCE_ROWS;
    for (
        started_at,
        model,
        input,
        output,
        reasoning,
        cache_creation,
        cache_read,
        directory,
        task_type,
    ) in collected.into_iter().rev()
    {
        cancellation.check()?;
        let input = u64::try_from(input.unwrap_or(0)).unwrap_or(0);
        let output = u64::try_from(output.unwrap_or(0)).unwrap_or(0);
        let reasoning = u64::try_from(reasoning.unwrap_or(0)).unwrap_or(0);
        let cache_creation = u64::try_from(cache_creation.unwrap_or(0)).unwrap_or(0);
        let cache_read = u64::try_from(cache_read.unwrap_or(0)).unwrap_or(0);
        if input == 0 && output == 0 && reasoning == 0 && cache_creation == 0 && cache_read == 0 {
            continue;
        }
        let project = project_from_zcode(directory, task_type);
        record(
            &mut builder,
            started_at,
            model.as_deref().or(Some("unknown")),
            input
                .saturating_sub(cache_read)
                .saturating_sub(cache_creation),
            output.saturating_add(reasoning),
            cache_read,
            cache_creation,
            project.as_deref(),
        );
        stats.usage_records = stats.usage_records.saturating_add(1);
    }
    // C041: 截断标记随扫描返回, 上游归为信息级降级而非故障。
    let mut scan = finish(window, builder, stats, true);
    scan.capped = capped;
    Ok(scan)
}
