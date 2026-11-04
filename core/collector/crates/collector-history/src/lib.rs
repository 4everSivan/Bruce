#![deny(unsafe_code)]

//! Bruce 自有用量历史聚合台账 (T26, design §7.3)。
//!
//! 该 crate 只持久化派生数值 (日 / 日×模型 / 月×模型 / 今日小时与工程) 与日期键,
//! 不存消息正文、路径或凭据。合并语义单调只增不减: 来源回退、会话修剪或部分
//! 扫描失败都不得抹掉既有历史。

use collector_domain::{
    CollectionWindow, ModelDelta, ProjectDelta, TokenBucket, UsageContribution,
};
use rusqlite::{params, Connection, OptionalExtension, TransactionBehavior};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::Path;
use std::time::Duration;

/// 台账 schema 版本, 写入 SQLite 的 `PRAGMA user_version`。
const SCHEMA_VERSION: i64 = 1;
/// SQLITE_BUSY 等待上限 (design §7.3: `SQLITE_BUSY` 超时不得阻塞刷新)。
const BUSY_TIMEOUT: Duration = Duration::from_secs(3);
const HOURS_PER_DAY: usize = 24;

const SCHEMA_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS agent_day (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    total INTEGER NOT NULL,
    bucket_json TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (agent_id, date)
);
CREATE TABLE IF NOT EXISTS agent_day_model (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    model TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    total INTEGER NOT NULL,
    bucket_json TEXT NOT NULL,
    PRIMARY KEY (agent_id, date, model)
);
CREATE TABLE IF NOT EXISTS agent_month_model (
    agent_id TEXT NOT NULL,
    month TEXT NOT NULL,
    model TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    total INTEGER NOT NULL,
    bucket_json TEXT NOT NULL,
    PRIMARY KEY (agent_id, month, model)
);
CREATE TABLE IF NOT EXISTS agent_today_model (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    model TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    total INTEGER NOT NULL,
    bucket_json TEXT NOT NULL,
    PRIMARY KEY (agent_id, date, model)
);
CREATE TABLE IF NOT EXISTS agent_hour (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    hour INTEGER NOT NULL,
    total INTEGER NOT NULL,
    PRIMARY KEY (agent_id, date, hour)
);
CREATE TABLE IF NOT EXISTS agent_hour_model (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    hour INTEGER NOT NULL,
    model TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    total INTEGER NOT NULL,
    bucket_json TEXT NOT NULL,
    PRIMARY KEY (agent_id, date, hour, model)
);
CREATE TABLE IF NOT EXISTS agent_project (
    agent_id TEXT NOT NULL,
    date TEXT NOT NULL,
    project TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    total INTEGER NOT NULL,
    PRIMARY KEY (agent_id, date, project)
);
CREATE TABLE IF NOT EXISTS agent_state (
    agent_id TEXT PRIMARY KEY,
    last_scan_at TEXT,
    last_found_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_agent_day_date ON agent_day (date);
CREATE INDEX IF NOT EXISTS idx_agent_day_model_date ON agent_day_model (date);
CREATE INDEX IF NOT EXISTS idx_agent_month_model_month ON agent_month_model (month);
CREATE INDEX IF NOT EXISTS idx_agent_today_model_date ON agent_today_model (date);
CREATE INDEX IF NOT EXISTS idx_agent_hour_date ON agent_hour (date);
CREATE INDEX IF NOT EXISTS idx_agent_hour_model_date ON agent_hour_model (date);
CREATE INDEX IF NOT EXISTS idx_agent_project_date ON agent_project (date);
"#;

/// 每轮 merge 末尾清理的临时表 (昨日及更早的行只保留当日)。
const TEMP_CLEANUP_SQL: &[&str] = &[
    "DELETE FROM agent_today_model WHERE date < ?1",
    "DELETE FROM agent_hour WHERE date < ?1",
    "DELETE FROM agent_hour_model WHERE date < ?1",
    "DELETE FROM agent_project WHERE date < ?1",
];

/// 历史台账的结构化错误。所有失败都只读不破坏既有数据 (事务整体回滚)。
#[derive(Debug)]
pub enum HistoryError {
    Sqlite(rusqlite::Error),
    Io(std::io::Error),
    UnsupportedSchema(i64),
    Serialize(serde_json::Error),
}

impl fmt::Display for HistoryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Sqlite(error) => write!(formatter, "history store sqlite error: {error}"),
            Self::Io(error) => write!(formatter, "history store io error: {error}"),
            Self::UnsupportedSchema(version) => {
                write!(
                    formatter,
                    "unsupported history store schema version: {version}"
                )
            }
            Self::Serialize(error) => write!(formatter, "history store json error: {error}"),
        }
    }
}

impl std::error::Error for HistoryError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Sqlite(error) => Some(error),
            Self::Io(error) => Some(error),
            Self::Serialize(error) => Some(error),
            Self::UnsupportedSchema(_) => None,
        }
    }
}

impl From<rusqlite::Error> for HistoryError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sqlite(error)
    }
}

impl From<std::io::Error> for HistoryError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for HistoryError {
    fn from(error: serde_json::Error) -> Self {
        Self::Serialize(error)
    }
}

/// 一轮 merge 的统计 (供 application 层诊断与测试断言)。
#[derive(Debug, Default, Clone)]
pub struct MergeStats {
    pub written_days: usize,
    pub kept_days: usize,
    pub written_months: usize,
    pub kept_months: usize,
}

/// 按窗口从台账投影出的读数。`contribution` 直接交给既有 `UsageAccumulator`
/// 计价; `has_data` / `last_found_at` 支撑来源消失时的 `status=history`。
#[derive(Debug, Clone)]
pub struct StoredWindow {
    pub contribution: UsageContribution,
    pub has_data: bool,
    pub last_found_at: Option<String>,
}

/// Bruce 自有的用量历史台账 (不可再生资产, 归 collector 独占写)。
pub struct HistoryStore {
    connection: Connection,
}

impl HistoryStore {
    /// 打开 (必要时创建) 磁盘台账: 建父目录 (unix 0700)、文件 0600、
    /// WAL、`busy_timeout` 3s, 并确保 schema 版本。
    pub fn open(path: &Path) -> Result<Self, HistoryError> {
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
                // 权限收紧是尽力而为: 父目录可能已存在且不归当前用户所有
                // (如显式指定到共享目录), chmod 失败不得阻断台账可用性。
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

    /// 测试用内存台账 (同样建 schema, 不涉及文件权限 / WAL)。
    pub fn open_in_memory() -> Result<Self, HistoryError> {
        let connection = Connection::open_in_memory()?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        let store = Self { connection };
        store.ensure_schema()?;
        Ok(store)
    }

    /// 单调合并一轮扫描贡献 (单事务 IMMEDIATE)。
    ///
    /// `today` 为本地日期 (`YYYY-MM-DD`), 用于判定今日临时表的整体替换与
    /// 昨日清理; 它是显式参数, 不从 contribution 形状反推。
    pub fn merge(
        &mut self,
        agent_id: &str,
        contribution: &UsageContribution,
        found: bool,
        today: &str,
        now: &str,
    ) -> Result<MergeStats, HistoryError> {
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut stats = MergeStats::default();
        let mut wrote_today = false;

        for (date, bucket) in &contribution.by_day {
            let date = date.as_str();
            // 过滤空桶: 绝不写占位 0 行。
            if bucket.total == 0 {
                continue;
            }
            let stored: Option<i64> = transaction
                .query_row(
                    "SELECT total FROM agent_day WHERE agent_id = ?1 AND date = ?2",
                    params![agent_id, date],
                    |row| row.get(0),
                )
                .optional()?;
            let new_total = saturating_i64(bucket.total);
            if matches!(stored, Some(value) if new_total < value) {
                // 来源回退 / 修剪 / 部分失败: 保留历史, 只计数。
                stats.kept_days += 1;
                continue;
            }

            let bucket_json = encode_bucket(bucket)?;
            transaction.execute(
                "INSERT INTO agent_day (agent_id, date, total, bucket_json, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT (agent_id, date) DO UPDATE SET
                     total = excluded.total,
                     bucket_json = excluded.bucket_json,
                     updated_at = excluded.updated_at",
                params![agent_id, date, new_total, bucket_json, now],
            )?;

            // 只有贡献里带该日模型明细时才替换日×模型行; 否则保留存量。
            if let Some(models) = contribution.models_by_day.get(date) {
                transaction.execute(
                    "DELETE FROM agent_day_model WHERE agent_id = ?1 AND date = ?2",
                    params![agent_id, date],
                )?;
                let ordered = ordered_models(models);
                for (ordinal, (model, model_bucket)) in ordered.iter().enumerate() {
                    transaction.execute(
                        "INSERT INTO agent_day_model
                             (agent_id, date, model, ordinal, total, bucket_json)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                        params![
                            agent_id,
                            date,
                            model.as_str(),
                            ordinal as i64,
                            saturating_i64(model_bucket.total),
                            encode_bucket(model_bucket)?,
                        ],
                    )?;
                }
            }
            stats.written_days += 1;
            if date == today {
                wrote_today = true;
            }
        }

        // 今日模型 / 小时 / 工程桶随今日整体替换。
        if wrote_today {
            for table in [
                "agent_today_model",
                "agent_hour",
                "agent_hour_model",
                "agent_project",
            ] {
                transaction.execute(
                    &format!("DELETE FROM {table} WHERE agent_id = ?1 AND date = ?2"),
                    params![agent_id, today],
                )?;
            }
            write_today_tables(&transaction, agent_id, contribution, today)?;
        }

        // 月×模型: 新月份总量 >= 存量 SUM(total) 才整月替换。
        for (month, models) in &contribution.models_by_month {
            let month = month.as_str();
            let ordered = ordered_models(models);
            let new_total = ordered
                .iter()
                .fold(0u64, |sum, (_, bucket)| sum.saturating_add(bucket.total));
            let stored: i64 = transaction.query_row(
                "SELECT COALESCE(SUM(total), 0) FROM agent_month_model
                 WHERE agent_id = ?1 AND month = ?2",
                params![agent_id, month],
                |row| row.get(0),
            )?;
            if ordered.is_empty() {
                // 过滤空桶后无内容: 不写 0 行; 存量非空时按「新小于存量」保留。
                if stored > 0 {
                    stats.kept_months += 1;
                }
                continue;
            }
            if saturating_i64(new_total) < stored {
                stats.kept_months += 1;
                continue;
            }
            transaction.execute(
                "DELETE FROM agent_month_model WHERE agent_id = ?1 AND month = ?2",
                params![agent_id, month],
            )?;
            for (ordinal, (model, bucket)) in ordered.iter().enumerate() {
                transaction.execute(
                    "INSERT INTO agent_month_model
                         (agent_id, month, model, ordinal, total, bucket_json)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        agent_id,
                        month,
                        model.as_str(),
                        ordinal as i64,
                        saturating_i64(bucket.total),
                        encode_bucket(bucket)?,
                    ],
                )?;
            }
            stats.written_months += 1;
        }

        // 来源探测状态: last_scan_at 每轮更新, last_found_at 仅在 found 时更新。
        if found {
            transaction.execute(
                "INSERT INTO agent_state (agent_id, last_scan_at, last_found_at)
                 VALUES (?1, ?2, ?2)
                 ON CONFLICT (agent_id) DO UPDATE SET
                     last_scan_at = excluded.last_scan_at,
                     last_found_at = excluded.last_found_at",
                params![agent_id, now],
            )?;
        } else {
            transaction.execute(
                "INSERT INTO agent_state (agent_id, last_scan_at, last_found_at)
                 VALUES (?1, ?2, NULL)
                 ON CONFLICT (agent_id) DO UPDATE SET
                     last_scan_at = excluded.last_scan_at",
                params![agent_id, now],
            )?;
        }

        // 今日临时表只保留 today 当天。
        for sql in TEMP_CLEANUP_SQL {
            transaction.execute(sql, params![today])?;
        }

        transaction.commit()?;
        Ok(stats)
    }

    /// 按请求窗口把台账投影回 `UsageContribution` 形状。
    pub fn load(
        &self,
        agent_id: &str,
        window: &CollectionWindow,
    ) -> Result<StoredWindow, HistoryError> {
        let mut contribution = UsageContribution {
            by_day: BTreeMap::new(),
            models_by_month: BTreeMap::new(),
            models_today: Vec::new(),
            projects_today: Vec::new(),
            hours: vec![0u64; HOURS_PER_DAY],
            models_by_day: BTreeMap::new(),
            hour_models_today: BTreeMap::new(),
        };
        let mut has_data = false;
        let mut months_seen = BTreeSet::new();

        for date in &window.day_list {
            let date = date.as_str();
            let day_json: Option<String> = self
                .connection
                .query_row(
                    "SELECT bucket_json FROM agent_day WHERE agent_id = ?1 AND date = ?2",
                    params![agent_id, date],
                    |row| row.get(0),
                )
                .optional()?;
            if let Some(json) = day_json {
                has_data = true;
                let bucket: TokenBucket = serde_json::from_str(&json)?;
                if bucket.total > 0 {
                    contribution.by_day.insert(date.to_owned(), bucket);
                }
            }

            let models = self.load_day_models(agent_id, date)?;
            if !models.is_empty() {
                contribution.models_by_day.insert(date.to_owned(), models);
            }
            if let Some(month) = date.get(..7) {
                months_seen.insert(month.to_owned());
            }
        }

        for month in &months_seen {
            let models = self.load_month_models(agent_id, month)?;
            if !models.is_empty() {
                contribution.models_by_month.insert(month.clone(), models);
            }
        }

        contribution.models_today = self.load_today_models(agent_id, &window.today)?;
        contribution.projects_today = self.load_today_projects(agent_id, &window.today)?;
        contribution.hours = self.load_hours(agent_id, &window.today)?;
        contribution.hour_models_today = self.load_hour_models(agent_id, &window.today)?;

        if !has_data {
            has_data = self.has_today_rows(agent_id, &window.today)?;
        }

        Ok(StoredWindow {
            contribution,
            has_data,
            last_found_at: self.last_found_at(agent_id)?,
        })
    }

    /// 最近一次来源探测成功的时间; 从未发现过来源时为 `None`。
    pub fn last_found_at(&self, agent_id: &str) -> Result<Option<String>, HistoryError> {
        let value: Option<Option<String>> = self
            .connection
            .query_row(
                "SELECT last_found_at FROM agent_state WHERE agent_id = ?1",
                params![agent_id],
                |row| row.get(0),
            )
            .optional()?;
        Ok(value.flatten())
    }

    /// 该 agent 在台账内是否存有任何历史数据 (不限窗口)。
    pub fn has_any_data(&self, agent_id: &str) -> Result<bool, HistoryError> {
        let found: i64 = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_day WHERE agent_id = ?1)
                 OR EXISTS(SELECT 1 FROM agent_today_model WHERE agent_id = ?1)
                 OR EXISTS(SELECT 1 FROM agent_hour WHERE agent_id = ?1)
                 OR EXISTS(SELECT 1 FROM agent_hour_model WHERE agent_id = ?1)
                 OR EXISTS(SELECT 1 FROM agent_project WHERE agent_id = ?1)",
            params![agent_id],
            |row| row.get(0),
        )?;
        Ok(found != 0)
    }

    fn ensure_schema(&self) -> Result<(), HistoryError> {
        let version: i64 = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version == 0 {
            self.connection.execute_batch(SCHEMA_SQL)?;
            self.connection
                .pragma_update(None, "user_version", SCHEMA_VERSION)?;
            Ok(())
        } else if version == SCHEMA_VERSION {
            Ok(())
        } else {
            Err(HistoryError::UnsupportedSchema(version))
        }
    }

    fn load_day_models(
        &self,
        agent_id: &str,
        date: &str,
    ) -> Result<BTreeMap<String, TokenBucket>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT model, bucket_json FROM agent_day_model
             WHERE agent_id = ?1 AND date = ?2 ORDER BY ordinal",
        )?;
        let mut rows = statement.query(params![agent_id, date])?;
        let mut models = BTreeMap::new();
        while let Some(row) = rows.next()? {
            let model: String = row.get(0)?;
            let json: String = row.get(1)?;
            let bucket: TokenBucket = serde_json::from_str(&json)?;
            if bucket.total > 0 {
                models.insert(model, bucket);
            }
        }
        Ok(models)
    }

    fn load_month_models(
        &self,
        agent_id: &str,
        month: &str,
    ) -> Result<BTreeMap<String, TokenBucket>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT model, bucket_json FROM agent_month_model
             WHERE agent_id = ?1 AND month = ?2 ORDER BY ordinal",
        )?;
        let mut rows = statement.query(params![agent_id, month])?;
        let mut models = BTreeMap::new();
        while let Some(row) = rows.next()? {
            let model: String = row.get(0)?;
            let json: String = row.get(1)?;
            let bucket: TokenBucket = serde_json::from_str(&json)?;
            if bucket.total > 0 {
                models.insert(model, bucket);
            }
        }
        Ok(models)
    }

    fn load_today_models(
        &self,
        agent_id: &str,
        today: &str,
    ) -> Result<Vec<ModelDelta>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT model, bucket_json FROM agent_today_model
             WHERE agent_id = ?1 AND date = ?2 ORDER BY ordinal",
        )?;
        let mut rows = statement.query(params![agent_id, today])?;
        let mut models = Vec::new();
        while let Some(row) = rows.next()? {
            let model: String = row.get(0)?;
            let json: String = row.get(1)?;
            models.push(ModelDelta {
                model,
                bucket: serde_json::from_str(&json)?,
            });
        }
        Ok(models)
    }

    fn load_today_projects(
        &self,
        agent_id: &str,
        today: &str,
    ) -> Result<Vec<ProjectDelta>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT project, total FROM agent_project
             WHERE agent_id = ?1 AND date = ?2 ORDER BY ordinal",
        )?;
        let mut rows = statement.query(params![agent_id, today])?;
        let mut projects = Vec::new();
        while let Some(row) = rows.next()? {
            let name: String = row.get(0)?;
            let total: i64 = row.get(1)?;
            projects.push(ProjectDelta {
                name,
                total: u64::try_from(total).unwrap_or_default(),
            });
        }
        Ok(projects)
    }

    fn load_hours(&self, agent_id: &str, today: &str) -> Result<Vec<u64>, HistoryError> {
        let mut statement = self
            .connection
            .prepare("SELECT hour, total FROM agent_hour WHERE agent_id = ?1 AND date = ?2")?;
        let mut rows = statement.query(params![agent_id, today])?;
        let mut hours = vec![0u64; HOURS_PER_DAY];
        while let Some(row) = rows.next()? {
            let hour: i64 = row.get(0)?;
            let total: i64 = row.get(1)?;
            if let Ok(hour) = usize::try_from(hour) {
                if hour < hours.len() {
                    hours[hour] = u64::try_from(total).unwrap_or_default();
                }
            }
        }
        Ok(hours)
    }

    fn load_hour_models(
        &self,
        agent_id: &str,
        today: &str,
    ) -> Result<BTreeMap<u8, BTreeMap<String, TokenBucket>>, HistoryError> {
        let mut statement = self.connection.prepare(
            "SELECT hour, model, bucket_json FROM agent_hour_model
             WHERE agent_id = ?1 AND date = ?2 ORDER BY hour, ordinal",
        )?;
        let mut rows = statement.query(params![agent_id, today])?;
        let mut hours: BTreeMap<u8, BTreeMap<String, TokenBucket>> = BTreeMap::new();
        while let Some(row) = rows.next()? {
            let hour: i64 = row.get(0)?;
            let model: String = row.get(1)?;
            let json: String = row.get(2)?;
            let bucket: TokenBucket = serde_json::from_str(&json)?;
            if let Ok(hour) = u8::try_from(hour) {
                if (hour as usize) < HOURS_PER_DAY && bucket.total > 0 {
                    hours.entry(hour).or_default().insert(model, bucket);
                }
            }
        }
        Ok(hours)
    }

    fn has_today_rows(&self, agent_id: &str, today: &str) -> Result<bool, HistoryError> {
        let found: i64 = self.connection.query_row(
            "SELECT EXISTS(SELECT 1 FROM agent_today_model WHERE agent_id = ?1 AND date = ?2)
                 OR EXISTS(SELECT 1 FROM agent_hour WHERE agent_id = ?1 AND date = ?2)
                 OR EXISTS(SELECT 1 FROM agent_hour_model WHERE agent_id = ?1 AND date = ?2)
                 OR EXISTS(SELECT 1 FROM agent_project WHERE agent_id = ?1 AND date = ?2)",
            params![agent_id, today],
            |row| row.get(0),
        )?;
        Ok(found != 0)
    }
}

fn write_today_tables(
    transaction: &rusqlite::Transaction<'_>,
    agent_id: &str,
    contribution: &UsageContribution,
    today: &str,
) -> Result<(), HistoryError> {
    for (ordinal, model) in contribution
        .models_today
        .iter()
        .enumerate()
        .filter(|(_, model)| model.bucket.total > 0)
    {
        transaction.execute(
            "INSERT INTO agent_today_model
                 (agent_id, date, model, ordinal, total, bucket_json)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                agent_id,
                today,
                model.model.as_str(),
                ordinal as i64,
                saturating_i64(model.bucket.total),
                encode_bucket(&model.bucket)?,
            ],
        )?;
    }

    for (ordinal, project) in contribution
        .projects_today
        .iter()
        .enumerate()
        .filter(|(_, project)| project.total > 0)
    {
        transaction.execute(
            "INSERT INTO agent_project (agent_id, date, project, ordinal, total)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                agent_id,
                today,
                project.name.as_str(),
                ordinal as i64,
                saturating_i64(project.total),
            ],
        )?;
    }

    for (hour, total) in contribution
        .hours
        .iter()
        .enumerate()
        .take(HOURS_PER_DAY)
        .filter(|(_, total)| **total > 0)
    {
        transaction.execute(
            "INSERT INTO agent_hour (agent_id, date, hour, total) VALUES (?1, ?2, ?3, ?4)",
            params![agent_id, today, hour as i64, saturating_i64(*total)],
        )?;
    }

    for (hour, models) in &contribution.hour_models_today {
        if usize::from(*hour) >= HOURS_PER_DAY {
            continue;
        }
        let ordered = ordered_models(models);
        for (ordinal, (model, bucket)) in ordered.iter().enumerate() {
            transaction.execute(
                "INSERT INTO agent_hour_model
                     (agent_id, date, hour, model, ordinal, total, bucket_json)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    agent_id,
                    today,
                    i64::from(*hour),
                    model.as_str(),
                    ordinal as i64,
                    saturating_i64(bucket.total),
                    encode_bucket(bucket)?,
                ],
            )?;
        }
    }

    Ok(())
}

/// 过滤空桶后按 BTreeMap (模型名) 顺序返回, ordinal 即此顺序的下标。
fn ordered_models(models: &BTreeMap<String, TokenBucket>) -> Vec<(&String, &TokenBucket)> {
    models
        .iter()
        .filter(|(_, bucket)| bucket.total > 0)
        .collect()
}

fn encode_bucket(bucket: &TokenBucket) -> Result<String, HistoryError> {
    Ok(serde_json::to_string(bucket)?)
}

fn saturating_i64(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

#[cfg(unix)]
fn restrict_directory(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700));
}

#[cfg(not(unix))]
fn restrict_directory(_path: &Path) {}

/// 台账与其 WAL/SHM 附属文件收紧到 0600 (unix); 已存在的文件即使之前
/// 权限更宽也会被纠正。
#[cfg(unix)]
fn restrict_database_files(path: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let mut candidates = Vec::with_capacity(3);
    candidates.push(path.to_path_buf());
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return;
    };
    candidates.push(path.with_file_name(format!("{name}-wal")));
    candidates.push(path.with_file_name(format!("{name}-shm")));
    for candidate in candidates {
        let _ = std::fs::set_permissions(&candidate, std::fs::Permissions::from_mode(0o600));
    }
}

#[cfg(not(unix))]
fn restrict_database_files(_path: &Path) {}

#[cfg(test)]
mod tests {
    use super::*;
    use collector_domain::TokenTally;
    use serde_json::{json, Map, Value};

    const AGENT: &str = "claude";
    const TODAY: &str = "2026-11-04";
    const NOW: &str = "2026-11-04T12:00:00Z";

    fn window_with_now(now: &str) -> CollectionWindow {
        let mut context = Map::new();
        context.insert("timezone".to_owned(), Value::String("UTC".to_owned()));
        context.insert("days".to_owned(), json!(7));
        context.insert("now".to_owned(), Value::String(now.to_owned()));
        CollectionWindow::from_context(&context).expect("collection window")
    }

    fn window() -> CollectionWindow {
        window_with_now(NOW)
    }

    fn bucket(input: u64, output: u64, cache_read: u64, cache_creation: u64) -> TokenBucket {
        let mut value = TokenBucket::default();
        value.add(input, output, cache_read, cache_creation);
        value
    }

    /// 带 1h TTL 份额与计价类别份额的桶, 用于验证 bucket_json 保真。
    fn claude_bucket() -> TokenBucket {
        let mut value = bucket(12, 6, 3, 1);
        value.cache_creation_1h = 1;
        value.rate_splits.insert(
            "peak".to_owned(),
            TokenTally {
                input: 12,
                output: 6,
                cache_read: 3,
                cache_creation: 1,
                cache_creation_1h: 1,
            },
        );
        value
    }

    fn empty_contribution() -> UsageContribution {
        UsageContribution {
            by_day: BTreeMap::new(),
            models_by_month: BTreeMap::new(),
            models_today: Vec::new(),
            projects_today: Vec::new(),
            hours: vec![0u64; HOURS_PER_DAY],
            models_by_day: BTreeMap::new(),
            hour_models_today: BTreeMap::new(),
        }
    }

    fn sample_contribution() -> UsageContribution {
        let mut contribution = empty_contribution();
        contribution
            .by_day
            .insert("2026-11-03".to_owned(), bucket(10, 5, 2, 1));
        contribution
            .by_day
            .insert("2026-11-04".to_owned(), bucket(20, 10, 4, 2));

        let mut day_models_03 = BTreeMap::new();
        day_models_03.insert("claude".to_owned(), bucket(10, 5, 2, 1));
        contribution
            .models_by_day
            .insert("2026-11-03".to_owned(), day_models_03);
        let mut day_models_04 = BTreeMap::new();
        day_models_04.insert("claude".to_owned(), claude_bucket());
        day_models_04.insert("gpt".to_owned(), bucket(8, 4, 1, 1));
        contribution
            .models_by_day
            .insert("2026-11-04".to_owned(), day_models_04);

        let mut month_models = BTreeMap::new();
        month_models.insert("claude".to_owned(), claude_bucket());
        month_models.insert("gpt".to_owned(), bucket(8, 4, 1, 1));
        contribution
            .models_by_month
            .insert("2026-11".to_owned(), month_models);

        contribution.models_today = vec![
            ModelDelta {
                model: "claude".to_owned(),
                bucket: claude_bucket(),
            },
            ModelDelta {
                model: "gpt".to_owned(),
                bucket: bucket(8, 4, 1, 1),
            },
        ];
        contribution.projects_today = vec![ProjectDelta {
            name: "bruce".to_owned(),
            total: 20,
        }];

        contribution.hours[9] = 30;
        contribution.hours[10] = 6;
        let mut hour_models_9 = BTreeMap::new();
        hour_models_9.insert("claude".to_owned(), claude_bucket());
        contribution.hour_models_today.insert(9, hour_models_9);
        let mut hour_models_10 = BTreeMap::new();
        hour_models_10.insert("gpt".to_owned(), bucket(8, 4, 1, 1));
        contribution.hour_models_today.insert(10, hour_models_10);

        contribution
    }

    fn count(store: &HistoryStore, table: &str) -> i64 {
        store
            .connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                row.get(0)
            })
            .expect("count rows")
    }

    fn count_on_date(store: &HistoryStore, table: &str, date: &str) -> i64 {
        store
            .connection
            .query_row(
                &format!("SELECT COUNT(*) FROM {table} WHERE date = ?1"),
                params![date],
                |row| row.get(0),
            )
            .expect("count rows on date")
    }

    const DATA_TABLES: &[&str] = &[
        "agent_day",
        "agent_day_model",
        "agent_month_model",
        "agent_today_model",
        "agent_hour",
        "agent_hour_model",
        "agent_project",
    ];

    #[test]
    fn merge_then_load_round_trips_all_shapes() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let contribution = sample_contribution();
        let stats = store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("merge");
        assert_eq!(stats.written_days, 2);
        assert_eq!(stats.kept_days, 0);
        assert_eq!(stats.written_months, 1);
        assert_eq!(stats.kept_months, 0);

        let stored = store.load(AGENT, &window()).expect("load");
        assert!(stored.has_data);
        assert_eq!(stored.last_found_at.as_deref(), Some(NOW));
        assert_eq!(stored.contribution.by_day, contribution.by_day);
        assert_eq!(
            stored.contribution.models_by_day,
            contribution.models_by_day
        );
        assert_eq!(
            stored.contribution.models_by_month,
            contribution.models_by_month
        );
        assert_eq!(stored.contribution.models_today, contribution.models_today);
        assert_eq!(
            stored.contribution.projects_today,
            contribution.projects_today
        );
        assert_eq!(stored.contribution.hours, contribution.hours);
        assert_eq!(
            stored.contribution.hour_models_today,
            contribution.hour_models_today
        );
        // bucket_json 必须保留 cacheCreation1h / rateSplits。
        let loaded = &stored.contribution.by_day["2026-11-03"];
        assert_eq!(loaded.total, 18);
    }

    #[test]
    fn repeated_merge_is_idempotent() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let contribution = sample_contribution();
        store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("first merge");
        let first = store.load(AGENT, &window()).expect("first load");
        let counts: Vec<i64> = DATA_TABLES
            .iter()
            .map(|table| count(&store, table))
            .collect();

        let stats = store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("second merge");
        assert_eq!(stats.kept_days, 0);
        assert_eq!(stats.kept_months, 0);
        let second = store.load(AGENT, &window()).expect("second load");
        assert_eq!(first.contribution, second.contribution);
        assert_eq!(first.has_data, second.has_data);
        let counts_again: Vec<i64> = DATA_TABLES
            .iter()
            .map(|table| count(&store, table))
            .collect();
        assert_eq!(counts, counts_again);
    }

    #[test]
    fn smaller_merge_keeps_existing_history() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let contribution = sample_contribution();
        store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("first merge");
        let original = store.load(AGENT, &window()).expect("original load");

        let mut downgraded = sample_contribution();
        downgraded
            .by_day
            .insert("2026-11-03".to_owned(), bucket(1, 0, 0, 0));
        downgraded
            .by_day
            .insert("2026-11-04".to_owned(), bucket(2, 0, 0, 0));
        let mut smaller_month = BTreeMap::new();
        smaller_month.insert("claude".to_owned(), bucket(1, 0, 0, 0));
        downgraded
            .models_by_month
            .insert("2026-11".to_owned(), smaller_month);

        let stats = store
            .merge(AGENT, &downgraded, true, TODAY, NOW)
            .expect("downgraded merge");
        assert_eq!(stats.written_days, 0);
        assert_eq!(stats.kept_days, 2);
        assert_eq!(stats.written_months, 0);
        assert_eq!(stats.kept_months, 1);

        let after = store.load(AGENT, &window()).expect("after load");
        assert_eq!(original.contribution, after.contribution);
    }

    #[test]
    fn merge_without_old_dates_keeps_their_history() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let contribution = sample_contribution();
        store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("first merge");

        let mut extra = empty_contribution();
        extra
            .by_day
            .insert("2026-11-01".to_owned(), bucket(7, 0, 0, 0));
        let mut extra_models = BTreeMap::new();
        extra_models.insert("claude".to_owned(), bucket(7, 0, 0, 0));
        extra
            .models_by_day
            .insert("2026-11-01".to_owned(), extra_models);
        store
            .merge(AGENT, &extra, true, TODAY, "2026-11-04T13:00:00Z")
            .expect("second merge");

        let stored = store.load(AGENT, &window()).expect("load");
        assert_eq!(stored.contribution.by_day.len(), 3);
        assert_eq!(
            stored.contribution.by_day["2026-11-03"],
            contribution.by_day["2026-11-03"]
        );
        assert_eq!(
            stored.contribution.by_day["2026-11-04"],
            contribution.by_day["2026-11-04"]
        );
        assert_eq!(stored.contribution.by_day["2026-11-01"].total, 7);
    }

    #[test]
    fn today_tables_are_replaced_and_yesterday_is_cleaned() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        store
            .merge(AGENT, &sample_contribution(), true, TODAY, NOW)
            .expect("first merge");
        for table in [
            "agent_today_model",
            "agent_hour",
            "agent_hour_model",
            "agent_project",
        ] {
            assert!(count_on_date(&store, table, "2026-11-04") > 0, "{table}");
        }

        let next_today = "2026-11-05";
        let mut next = empty_contribution();
        next.by_day
            .insert(next_today.to_owned(), bucket(50, 25, 5, 0));
        next.models_today = vec![ModelDelta {
            model: "opus".to_owned(),
            bucket: bucket(50, 25, 5, 0),
        }];
        next.projects_today = vec![ProjectDelta {
            name: "other".to_owned(),
            total: 50,
        }];
        next.hours[11] = 50;
        let mut hour_models = BTreeMap::new();
        hour_models.insert("opus".to_owned(), bucket(50, 25, 5, 0));
        next.hour_models_today.insert(11, hour_models);
        store
            .merge(AGENT, &next, true, next_today, "2026-11-05T12:00:00Z")
            .expect("second merge");

        // 昨日临时行清理, 今日临时行重建; 永久日桶保留。
        for table in [
            "agent_today_model",
            "agent_hour",
            "agent_hour_model",
            "agent_project",
        ] {
            assert_eq!(count_on_date(&store, table, "2026-11-04"), 0, "{table}");
            assert!(count_on_date(&store, table, next_today) > 0, "{table}");
        }
        assert_eq!(count_on_date(&store, "agent_day", "2026-11-04"), 1);

        let next_window = window_with_now("2026-11-05T12:00:00Z");
        let stored = store.load(AGENT, &next_window).expect("load");
        assert_eq!(stored.contribution.models_today, next.models_today);
        assert_eq!(stored.contribution.projects_today, next.projects_today);
        assert_eq!(stored.contribution.hours, next.hours);
        assert_eq!(
            stored.contribution.hour_models_today,
            next.hour_models_today
        );
    }

    #[test]
    fn month_buckets_replace_only_when_not_smaller() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let mut contribution = empty_contribution();
        contribution
            .by_day
            .insert(TODAY.to_owned(), bucket(15, 0, 0, 0));
        let mut month = BTreeMap::new();
        month.insert("a".to_owned(), bucket(10, 0, 0, 0));
        month.insert("b".to_owned(), bucket(5, 0, 0, 0));
        contribution
            .models_by_month
            .insert("2026-11".to_owned(), month);
        let stats = store
            .merge(AGENT, &contribution, true, TODAY, NOW)
            .expect("first merge");
        assert_eq!(stats.written_months, 1);

        let mut larger = empty_contribution();
        let mut larger_month = BTreeMap::new();
        larger_month.insert("a".to_owned(), bucket(100, 0, 0, 0));
        larger
            .models_by_month
            .insert("2026-11".to_owned(), larger_month);
        let stats = store
            .merge(AGENT, &larger, true, TODAY, NOW)
            .expect("larger merge");
        assert_eq!(stats.written_months, 1);
        assert_eq!(stats.kept_months, 0);

        let mut smaller = empty_contribution();
        let mut smaller_month = BTreeMap::new();
        smaller_month.insert("a".to_owned(), bucket(3, 0, 0, 0));
        smaller
            .models_by_month
            .insert("2026-11".to_owned(), smaller_month);
        let stats = store
            .merge(AGENT, &smaller, true, TODAY, NOW)
            .expect("smaller merge");
        assert_eq!(stats.written_months, 0);
        assert_eq!(stats.kept_months, 1);

        // 整月全空桶: 不写 0 行, 存量非空时按「新小于存量」保留。
        let mut zeroed = empty_contribution();
        let mut zero_month = BTreeMap::new();
        zero_month.insert("a".to_owned(), TokenBucket::default());
        zeroed
            .models_by_month
            .insert("2026-11".to_owned(), zero_month);
        let stats = store
            .merge(AGENT, &zeroed, true, TODAY, NOW)
            .expect("zero merge");
        assert_eq!(stats.written_months, 0);
        assert_eq!(stats.kept_months, 1);

        let stored = store.load(AGENT, &window()).expect("load");
        let month_loaded = &stored.contribution.models_by_month["2026-11"];
        assert_eq!(month_loaded.len(), 1);
        assert_eq!(month_loaded["a"].total, 100);
    }

    #[test]
    fn empty_contribution_and_zero_buckets_write_no_data_rows() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        let stats = store
            .merge(AGENT, &empty_contribution(), true, TODAY, NOW)
            .expect("empty merge");
        assert_eq!(stats.written_days, 0);
        assert_eq!(stats.kept_days, 0);
        assert_eq!(stats.written_months, 0);
        assert_eq!(stats.kept_months, 0);
        for table in DATA_TABLES {
            assert_eq!(count(&store, table), 0, "{table}");
        }
        assert_eq!(count(&store, "agent_state"), 1);
        assert!(!store.has_any_data(AGENT).expect("has_any_data"));

        let mut zeroed = empty_contribution();
        zeroed
            .by_day
            .insert(TODAY.to_owned(), TokenBucket::default());
        let mut zero_models = BTreeMap::new();
        zero_models.insert("m".to_owned(), TokenBucket::default());
        zeroed
            .models_by_day
            .insert(TODAY.to_owned(), zero_models.clone());
        zeroed
            .models_by_month
            .insert("2026-11".to_owned(), zero_models);
        zeroed.models_today = vec![ModelDelta {
            model: "m".to_owned(),
            bucket: TokenBucket::default(),
        }];
        zeroed.projects_today = vec![ProjectDelta {
            name: "p".to_owned(),
            total: 0,
        }];
        let stats = store
            .merge(AGENT, &zeroed, true, TODAY, NOW)
            .expect("zero merge");
        assert_eq!(stats.written_days, 0);
        assert_eq!(stats.written_months, 0);
        for table in DATA_TABLES {
            assert_eq!(count(&store, table), 0, "{table}");
        }
    }

    #[test]
    fn unsupported_schema_version_is_reported() {
        let connection = Connection::open_in_memory().expect("connection");
        connection
            .pragma_update(None, "user_version", 99)
            .expect("set version");
        let store = HistoryStore { connection };
        match store.ensure_schema() {
            Err(HistoryError::UnsupportedSchema(version)) => assert_eq!(version, 99),
            other => panic!("expected UnsupportedSchema, got {other:?}"),
        }
    }

    #[test]
    fn has_any_data_and_last_found_at_track_source_presence() {
        let mut store = HistoryStore::open_in_memory().expect("store");
        assert!(!store.has_any_data(AGENT).expect("empty store"));
        assert_eq!(store.last_found_at(AGENT).expect("no state"), None);

        // found=false: 数据写入但 last_found_at 保持 None。
        store
            .merge(AGENT, &sample_contribution(), false, TODAY, NOW)
            .expect("not found merge");
        assert!(store.has_any_data(AGENT).expect("after data"));
        assert_eq!(store.last_found_at(AGENT).expect("state"), None);

        // found=true 更新 last_found_at。
        let found_at = "2026-11-04T13:00:00Z";
        store
            .merge(AGENT, &sample_contribution(), true, TODAY, found_at)
            .expect("found merge");
        assert_eq!(
            store.last_found_at(AGENT).expect("state").as_deref(),
            Some(found_at)
        );

        // 再次 found=false 不得清空 last_found_at。
        let later = "2026-11-04T14:00:00Z";
        store
            .merge(AGENT, &empty_contribution(), false, TODAY, later)
            .expect("later merge");
        assert_eq!(
            store.last_found_at(AGENT).expect("state").as_deref(),
            Some(found_at)
        );

        // 另一 agent 互不影响。
        assert!(!store.has_any_data("other").expect("other agent"));
        assert_eq!(store.last_found_at("other").expect("other state"), None);
    }
}
