#![deny(unsafe_code)]

//! Request-granularity usage ledger.
//!
//! Stores only derived counters and identifiers: no prompts, responses, file
//! paths, session ids or credentials. The database is independent from the
//! non-regenerable usage-history ledger and can be rebuilt from session caches.

use rusqlite::{params, params_from_iter, types::Value, Connection};
use serde::{Deserialize, Serialize};
use std::fmt;
use std::io;
use std::path::Path;
use std::time::Duration;

const SCHEMA_VERSION: i64 = 1;
const BUSY_TIMEOUT: Duration = Duration::from_secs(3);

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS request_log (
    agent_id            TEXT NOT NULL,
    request_key         TEXT NOT NULL,
    occurred_at         INTEGER NOT NULL,
    model               TEXT,
    raw_model           TEXT,
    project             TEXT,
    input               INTEGER NOT NULL DEFAULT 0,
    output              INTEGER NOT NULL DEFAULT 0,
    cache_read          INTEGER NOT NULL DEFAULT 0,
    cache_creation      INTEGER NOT NULL DEFAULT 0,
    cache_creation_1h   INTEGER NOT NULL DEFAULT 0,
    cost_usd            REAL,
    pricing_model       TEXT,
    status_code         INTEGER NOT NULL DEFAULT 200,
    fidelity            TEXT NOT NULL DEFAULT 'exact',
    latency_ms          INTEGER,
    first_token_ms      INTEGER,
    PRIMARY KEY (agent_id, request_key)
);
CREATE INDEX IF NOT EXISTS idx_request_log_time ON request_log(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_request_log_agent_time ON request_log(agent_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_request_log_model_time ON request_log(model, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_request_log_status_time ON request_log(status_code, occurred_at DESC);
"#;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RequestLogEntry {
    pub agent_id: String,
    pub request_key: String,
    pub occurred_at: i64,
    pub model: Option<String>,
    pub raw_model: Option<String>,
    pub project: Option<String>,
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_creation: u64,
    pub cache_creation_1h: u64,
    pub cost_usd: Option<f64>,
    pub pricing_model: Option<String>,
    pub status_code: u16,
    pub fidelity: String,
    pub latency_ms: Option<i64>,
    pub first_token_ms: Option<i64>,
}

impl RequestLogEntry {
    pub fn exact(
        agent_id: impl Into<String>,
        request_key: impl Into<String>,
        occurred_at: i64,
    ) -> Self {
        Self {
            agent_id: agent_id.into(),
            request_key: request_key.into(),
            occurred_at,
            model: None,
            raw_model: None,
            project: None,
            input: 0,
            output: 0,
            cache_read: 0,
            cache_creation: 0,
            cache_creation_1h: 0,
            cost_usd: None,
            pricing_model: None,
            status_code: 200,
            fidelity: "exact".to_owned(),
            latency_ms: None,
            first_token_ms: None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct RequestLogFilter {
    pub start: i64,
    pub end: i64,
    pub agent_ids: Vec<String>,
    pub model: Option<String>,
    pub status: Option<u16>,
    pub page: u32,
    pub page_size: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RequestLogPage {
    pub total: u64,
    /// Sum of the four normalized token buckets over the filtered set.
    pub tokens: u64,
    /// Sum of priced rows over the filtered set; unpriced rows contribute 0.
    pub cost_usd: f64,
    pub avg_tokens: u64,
    /// Distinct models present in the filtered set, for the UI model menu.
    pub models: Vec<String>,
    pub entries: Vec<RequestLogEntry>,
}

#[derive(Debug)]
pub enum RequestLogError {
    Sqlite(rusqlite::Error),
    Io(io::Error),
    UnsupportedSchema(i64),
}

impl fmt::Display for RequestLogError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "request log sqlite error: {error}"),
            Self::Io(error) => write!(formatter, "request log io error: {error}"),
            Self::UnsupportedSchema(version) => {
                write!(
                    formatter,
                    "unsupported request log schema version: {version}"
                )
            }
        }
    }
}

impl std::error::Error for RequestLogError {}

impl From<rusqlite::Error> for RequestLogError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<io::Error> for RequestLogError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

pub struct RequestLogStore {
    connection: Connection,
}

impl RequestLogStore {
    pub fn open(path: &Path) -> Result<Self, RequestLogError> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
                restrict_directory(parent);
            }
        }
        let connection = Connection::open(path)?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        connection.pragma_update(None, "journal_mode", "WAL")?;
        restrict_database_files(path);
        let store = Self { connection };
        store.ensure_schema()?;
        restrict_database_files(path);
        Ok(store)
    }

    /// Read-only open for the Bridge query path: never creates the database,
    /// never changes WAL state, and rejects unknown schemas.
    pub fn open_read_only(path: &Path) -> Result<Self, RequestLogError> {
        let connection = Connection::open_with_flags(
            path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        let store = Self { connection };
        let version = schema_version(&store.connection)?;
        if version != SCHEMA_VERSION {
            return Err(RequestLogError::UnsupportedSchema(version));
        }
        Ok(store)
    }

    pub fn open_in_memory() -> Result<Self, RequestLogError> {
        let connection = Connection::open_in_memory()?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        let store = Self { connection };
        store.ensure_schema()?;
        Ok(store)
    }

    fn ensure_schema(&self) -> Result<(), RequestLogError> {
        let version = schema_version(&self.connection)?;
        if version == 0 {
            self.connection.execute_batch(SCHEMA_SQL)?;
            self.connection
                .pragma_update(None, "user_version", SCHEMA_VERSION)?;
            return Ok(());
        }
        if version != SCHEMA_VERSION {
            return Err(RequestLogError::UnsupportedSchema(version));
        }
        Ok(())
    }

    /// Merge one scan's entries, then prune detail older than `cutoff`.
    ///
    /// Token counters never shrink; a rewritten response can only grow. A null
    /// cost is filled when pricing becomes available; a priced row is not
    /// rewritten downwards.
    pub fn merge(
        &mut self,
        entries: &[RequestLogEntry],
        cutoff: i64,
    ) -> Result<usize, RequestLogError> {
        let transaction = self.connection.transaction()?;
        {
            let mut statement = transaction.prepare_cached(
                "INSERT INTO request_log (
                    agent_id, request_key, occurred_at, model, raw_model, project,
                    input, output, cache_read, cache_creation, cache_creation_1h,
                    cost_usd, pricing_model, status_code, fidelity, latency_ms, first_token_ms
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
                ON CONFLICT(agent_id, request_key) DO UPDATE SET
                    input = MAX(request_log.input, excluded.input),
                    output = MAX(request_log.output, excluded.output),
                    cache_read = MAX(request_log.cache_read, excluded.cache_read),
                    cache_creation = MAX(request_log.cache_creation, excluded.cache_creation),
                    cache_creation_1h = MAX(request_log.cache_creation_1h, excluded.cache_creation_1h),
                    cost_usd = CASE
                        WHEN excluded.cost_usd IS NULL THEN request_log.cost_usd
                        WHEN request_log.cost_usd IS NULL THEN excluded.cost_usd
                        WHEN excluded.cost_usd > request_log.cost_usd THEN excluded.cost_usd
                        ELSE request_log.cost_usd
                    END,
                    pricing_model = COALESCE(excluded.pricing_model, request_log.pricing_model),
                    model = COALESCE(excluded.model, request_log.model),
                    raw_model = COALESCE(excluded.raw_model, request_log.raw_model),
                    project = COALESCE(excluded.project, request_log.project),
                    status_code = CASE
                        WHEN excluded.status_code = 200 THEN 200
                        ELSE request_log.status_code
                    END,
                    fidelity = excluded.fidelity,
                    latency_ms = COALESCE(request_log.latency_ms, excluded.latency_ms),
                    first_token_ms = COALESCE(request_log.first_token_ms, excluded.first_token_ms)",
            )?;
            for entry in entries {
                statement.execute(params![
                    entry.agent_id,
                    entry.request_key,
                    entry.occurred_at,
                    entry.model,
                    entry.raw_model,
                    entry.project,
                    entry.input as i64,
                    entry.output as i64,
                    entry.cache_read as i64,
                    entry.cache_creation as i64,
                    entry.cache_creation_1h as i64,
                    entry.cost_usd,
                    entry.pricing_model,
                    entry.status_code as i64,
                    entry.fidelity,
                    entry.latency_ms,
                    entry.first_token_ms,
                ])?;
            }
        }
        transaction.execute("DELETE FROM request_log WHERE occurred_at < ?1", [cutoff])?;
        transaction.commit()?;
        Ok(entries.len())
    }

    pub fn query(&self, filter: &RequestLogFilter) -> Result<RequestLogPage, RequestLogError> {
        let mut clauses = vec!["occurred_at >= ?".to_owned(), "occurred_at <= ?".to_owned()];
        let mut values = vec![Value::Integer(filter.start), Value::Integer(filter.end)];
        if !filter.agent_ids.is_empty() {
            let placeholders = vec!["?"; filter.agent_ids.len()].join(", ");
            clauses.push(format!("agent_id IN ({placeholders})"));
            values.extend(filter.agent_ids.iter().cloned().map(Value::Text));
        }
        if let Some(model) = filter.model.as_ref().filter(|model| !model.is_empty()) {
            clauses.push("model = ?".to_owned());
            values.push(Value::Text(model.clone()));
        }
        if let Some(status) = filter.status {
            clauses.push("status_code = ?".to_owned());
            values.push(Value::Integer(i64::from(status)));
        }
        let where_clause = clauses.join(" AND ");
        let total: i64 = self.connection.query_row(
            &format!("SELECT COUNT(*) FROM request_log WHERE {where_clause}"),
            params_from_iter(values.clone()),
            |row| row.get(0),
        )?;
        let (tokens, cost_usd): (i64, f64) = self.connection.query_row(
            &format!(
                "SELECT COALESCE(SUM(input + output + cache_read + cache_creation), 0),
                        COALESCE(SUM(cost_usd), 0)
                 FROM request_log WHERE {where_clause}"
            ),
            params_from_iter(values.clone()),
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;

        let page_size = filter.page_size.clamp(1, 200) as i64;
        let page = filter.page.min(1000) as i64;
        let mut page_values = values.clone();
        page_values.push(Value::Integer(page_size));
        page_values.push(Value::Integer(page * page_size));
        let sql = format!(
            "SELECT agent_id, request_key, occurred_at, model, raw_model, project,
                    input, output, cache_read, cache_creation, cache_creation_1h,
                    cost_usd, pricing_model, status_code, fidelity, latency_ms, first_token_ms
             FROM request_log WHERE {where_clause}
             ORDER BY occurred_at DESC, request_key ASC
             LIMIT ? OFFSET ?"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(params_from_iter(page_values), row_to_entry)?;
        let mut entries = Vec::new();
        for row in rows {
            entries.push(row?);
        }
        let mut models_statement = self.connection.prepare(&format!(
            "SELECT DISTINCT model FROM request_log
             WHERE {where_clause} AND model IS NOT NULL
             ORDER BY model ASC LIMIT 256"
        ))?;
        let model_rows = models_statement.query_map(params_from_iter(values), |row| row.get(0))?;
        let mut models = Vec::new();
        for model in model_rows {
            models.push(model?);
        }
        let total = u64::try_from(total).unwrap_or(0);
        let tokens = u64::try_from(tokens).unwrap_or(0);
        Ok(RequestLogPage {
            total,
            tokens,
            cost_usd,
            avg_tokens: tokens.checked_div(total).unwrap_or(0),
            models,
            entries,
        })
    }

    pub fn schema_version(&self) -> Result<i64, RequestLogError> {
        schema_version(&self.connection)
    }
}

fn schema_version(connection: &Connection) -> Result<i64, RequestLogError> {
    Ok(connection.query_row("PRAGMA user_version", [], |row| row.get(0))?)
}

fn row_to_entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<RequestLogEntry> {
    Ok(RequestLogEntry {
        agent_id: row.get(0)?,
        request_key: row.get(1)?,
        occurred_at: row.get(2)?,
        model: row.get(3)?,
        raw_model: row.get(4)?,
        project: row.get(5)?,
        input: row.get::<_, i64>(6)?.max(0) as u64,
        output: row.get::<_, i64>(7)?.max(0) as u64,
        cache_read: row.get::<_, i64>(8)?.max(0) as u64,
        cache_creation: row.get::<_, i64>(9)?.max(0) as u64,
        cache_creation_1h: row.get::<_, i64>(10)?.max(0) as u64,
        cost_usd: row.get(11)?,
        pricing_model: row.get(12)?,
        status_code: u16::try_from(row.get::<_, i64>(13)?).unwrap_or(200),
        fidelity: row.get(14)?,
        latency_ms: row.get(15)?,
        first_token_ms: row.get(16)?,
    })
}

#[cfg(unix)]
fn restrict_directory(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
fn restrict_directory(_path: &Path) {}

#[cfg(unix)]
fn restrict_database_files(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let mut candidates = vec![path.to_path_buf()];
    if let Some(name) = path.file_name().and_then(|value| value.to_str()) {
        candidates.push(path.with_file_name(format!("{name}-wal")));
        candidates.push(path.with_file_name(format!("{name}-shm")));
    }
    for candidate in candidates {
        let _ = std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600));
    }
}

#[cfg(not(unix))]
fn restrict_database_files(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(key: &str, occurred_at: i64, input: u64, cost: Option<f64>) -> RequestLogEntry {
        let mut entry = RequestLogEntry::exact("claude-code", key, occurred_at);
        entry.model = Some("claude-opus-5-5".to_owned());
        entry.input = input;
        entry.cost_usd = cost;
        entry
    }

    #[test]
    fn merge_is_idempotent_and_query_filters_by_agent() {
        let mut store = RequestLogStore::open_in_memory().unwrap();
        let entries = vec![entry("a", 1000, 10, Some(0.01)), entry("b", 2000, 20, None)];
        assert_eq!(store.merge(&entries, 0).unwrap(), 2);
        assert_eq!(store.merge(&entries, 0).unwrap(), 2);
        let page = store
            .query(&RequestLogFilter {
                start: 0,
                end: 10_000,
                agent_ids: vec!["claude-code".to_owned()],
                page: 0,
                page_size: 50,
                ..RequestLogFilter::default()
            })
            .unwrap();
        assert_eq!(page.total, 2);
        assert_eq!(page.entries[0].request_key, "b");
        assert_eq!(page.entries[1].request_key, "a");
    }

    #[test]
    fn merge_never_shrinks_tokens_and_fills_cost() {
        let mut store = RequestLogStore::open_in_memory().unwrap();
        store.merge(&[entry("a", 1000, 10, None)], 0).unwrap();
        store.merge(&[entry("a", 1000, 4, Some(0.5))], 0).unwrap();
        let page = store
            .query(&RequestLogFilter {
                start: 0,
                end: 10_000,
                page: 0,
                page_size: 50,
                ..RequestLogFilter::default()
            })
            .unwrap();
        assert_eq!(page.entries[0].input, 10);
        assert_eq!(page.entries[0].cost_usd, Some(0.5));
    }

    #[test]
    fn merge_prunes_detail_older_than_cutoff() {
        let mut store = RequestLogStore::open_in_memory().unwrap();
        store
            .merge(
                &[entry("old", 1000, 1, None), entry("new", 5000, 1, None)],
                3000,
            )
            .unwrap();
        let page = store
            .query(&RequestLogFilter {
                start: 0,
                end: 10_000,
                page: 0,
                page_size: 50,
                ..RequestLogFilter::default()
            })
            .unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.entries[0].request_key, "new");
    }

    #[test]
    fn query_filters_model_and_status() {
        let mut store = RequestLogStore::open_in_memory().unwrap();
        let mut other = entry("other", 3000, 1, None);
        other.agent_id = "codex".to_owned();
        other.model = Some("gpt-6.2".to_owned());
        other.status_code = 500;
        store.merge(&[entry("a", 1000, 1, None), other], 0).unwrap();
        let page = store
            .query(&RequestLogFilter {
                start: 0,
                end: 10_000,
                model: Some("gpt-6.2".to_owned()),
                status: Some(500),
                page: 0,
                page_size: 50,
                ..RequestLogFilter::default()
            })
            .unwrap();
        assert_eq!(page.total, 1);
        assert_eq!(page.entries[0].agent_id, "codex");
    }

    #[test]
    fn unknown_schema_version_is_rejected() {
        let connection = Connection::open_in_memory().unwrap();
        connection.pragma_update(None, "user_version", 99).unwrap();
        let store = RequestLogStore { connection };
        assert!(matches!(
            store.ensure_schema(),
            Err(RequestLogError::UnsupportedSchema(99))
        ));
    }
}
