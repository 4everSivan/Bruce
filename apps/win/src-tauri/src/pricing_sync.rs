//! Windows 模型价格表远端同步服务 (T21, 09-模型价格表远端同步 §4.2)。
//!
//! 核心职责:
//! 1. 远端同步: 从 GitHub Raw 直链拉取最新 pricing-catalog.json (10s 超时, 512KB 上限);
//! 2. 严格校验: 委托 collector_domain::pricing::CatalogFile 做 R3 Fail-Closed 校验;
//! 3. 防倒退门禁 (R2): 远端版本低于本地基线时拒绝落盘; 启动时若本地缓存低于内置基线则自动清理;
//! 4. POSIX 等价原子写盘: 写入 %APPDATA%\Bruce\config\pricing-catalog.json;
//! 5. 零重启热生效: 同步成功或恢复内置后即刻更新 viewmodel::model_catalog 活动目录并触发采集重算;
//! 6. 状态机与双端对拍: 表现层文案与状态机消费 tests/fixtures/pricing-sync-parity/cases.json。

use chrono::Local;
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;

#[cfg(feature = "desktop")]
use tauri::{AppHandle, Emitter, Manager};

pub const RAW_CATALOG_URL: &str =
    "https://raw.githubusercontent.com/4everSivan/Bruce/main/config/pricing-catalog.json";
pub const MAX_CATALOG_BYTES: usize = 512 * 1024; // 512 KB
pub const FETCH_TIMEOUT_SECS: u64 = 10;

// ---------------------------------------------------------------- 状态与数据结构

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PricingSyncFailureReason {
    Timeout,
    Offline,
    HttpError,
    InvalidCatalog,
    StaleVersion,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PricingSyncStage {
    #[default]
    Idle,
    Syncing,
    UpToDate {
        #[serde(rename = "updatedAt")]
        updated_at: String,
        #[serde(rename = "modelCount")]
        model_count: usize,
    },
    Updated {
        #[serde(rename = "updatedAt")]
        updated_at: String,
        #[serde(rename = "modelCount")]
        model_count: usize,
        #[serde(rename = "addedCount")]
        added_count: usize,
        #[serde(rename = "adjustedCount")]
        adjusted_count: usize,
    },
    Restored {
        #[serde(rename = "updatedAt")]
        updated_at: String,
        #[serde(rename = "modelCount")]
        model_count: usize,
    },
    Failed {
        reason: PricingSyncFailureReason,
        #[serde(rename = "statusCode", skip_serializing_if = "Option::is_none")]
        status_code: Option<u16>,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PricingCatalogSummary {
    pub source: String, // "builtin" | "synced"
    pub updated_at: String,
    pub model_count: usize,
    pub last_sync_at: Option<String>,
    pub auto_sync_enabled: bool,
    pub stage: PricingSyncStage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CatalogDiff {
    pub added_count: usize,
    pub adjusted_count: usize,
}

// ---------------------------------------------------------------- 纯逻辑计算

/// 计算当前活动展示目录与新目录的差异 (按 listed 过滤)
pub fn calculate_diff(
    current_entries: &[bruce_win_viewmodel::model_catalog::CatalogEntry],
    new_catalog: &collector_domain::pricing::CatalogFile,
) -> CatalogDiff {
    let mut added_count = 0;
    let mut adjusted_count = 0;

    let current_map: std::collections::HashMap<
        String,
        &bruce_win_viewmodel::model_catalog::CatalogEntry,
    > = current_entries
        .iter()
        .map(|entry| (entry.model_name.to_lowercase(), entry))
        .collect();

    for new_m in new_catalog.models.iter().filter(|m| m.listed) {
        if let Some(old_m) = current_map.get(&new_m.model.to_lowercase()) {
            let input_diff = (old_m.input_price_per_million - new_m.input).abs() > f64::EPSILON;
            let output_diff = (old_m.output_price_per_million - new_m.output).abs() > f64::EPSILON;
            let cache_read_diff = old_m.cache_read_price_per_million != new_m.cache_read;

            if input_diff || output_diff || cache_read_diff {
                adjusted_count += 1;
            }
        } else {
            added_count += 1;
        }
    }

    CatalogDiff {
        added_count,
        adjusted_count,
    }
}

/// 默认本地落盘路径: %APPDATA%\Bruce\config\pricing-catalog.json
pub fn pricing_catalog_path() -> PathBuf {
    crate::paths::data_root()
        .join("config")
        .join("pricing-catalog.json")
}

/// 原子写盘
pub fn save_catalog_atomic(target_path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = target_path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "No parent directory"))?;
    fs::create_dir_all(parent)?;

    let temp_name = format!("pricing-catalog-{}.tmp", uuid::Uuid::new_v4());
    let temp_path = parent.join(temp_name);

    {
        let mut file = fs::File::create(&temp_path)?;
        file.write_all(bytes)?;
        file.flush()?;
    }

    fs::rename(&temp_path, target_path)?;
    Ok(())
}

/// 启动时检查本地同步缓存并实施 R2 防倒退门禁
pub fn init_pricing_catalog(path: &Path) {
    if !path.exists() {
        return;
    }

    let bytes = match fs::read(path) {
        Ok(b) => b,
        Err(_) => return,
    };

    let catalog = match collector_domain::pricing::CatalogFile::parse_and_validate(&bytes) {
        Ok(c) => c,
        Err(_) => {
            let _ = fs::remove_file(path);
            bruce_win_viewmodel::model_catalog::reset_to_builtin();
            return;
        }
    };

    let builtin_date = collector_domain::pricing::builtin_updated_at();
    if collector_domain::pricing::compare_updated_at(&catalog.updated_at, builtin_date)
        == std::cmp::Ordering::Less
    {
        // 旧版本缓存落后于新客户端内置基线，静默清理并回退
        let _ = fs::remove_file(path);
        bruce_win_viewmodel::model_catalog::reset_to_builtin();
    } else {
        bruce_win_viewmodel::model_catalog::set_active_catalog(
            &catalog.updated_at,
            &catalog.models,
        );
    }
}

/// 供 Collector Bridge Request 上下文注入 (Tier 2 已同步价卡)
pub fn active_catalog_context_value(path: &Path) -> Option<serde_json::Value> {
    if bruce_win_viewmodel::model_catalog::current_source()
        == bruce_win_viewmodel::model_catalog::CatalogSource::Synced
    {
        if let Ok(bytes) = fs::read(path) {
            if let Ok(json) = serde_json::from_slice(&bytes) {
                return Some(json);
            }
        }
    }
    None
}

// ---------------------------------------------------------------- 远端网络拉取

pub fn classify_fetch_error(error: &ureq::Error) -> (PricingSyncFailureReason, Option<u16>) {
    match error {
        ureq::Error::Status(code, _) => (PricingSyncFailureReason::HttpError, Some(*code)),
        ureq::Error::Transport(transport) => {
            let kind = transport.kind().to_string().to_lowercase();
            if kind.contains("dns") || kind.contains("connect") || kind.contains("connection") {
                (PricingSyncFailureReason::Offline, None)
            } else {
                (PricingSyncFailureReason::Timeout, None)
            }
        }
    }
}

pub fn fetch_catalog_bytes(url: &str) -> Result<Vec<u8>, (PricingSyncFailureReason, Option<u16>)> {
    let agent = ureq::builder()
        .timeout(Duration::from_secs(FETCH_TIMEOUT_SECS))
        .build();

    let response = agent
        .get(url)
        .call()
        .map_err(|err| classify_fetch_error(&err))?;

    let mut buf = Vec::new();
    response
        .into_reader()
        .take((MAX_CATALOG_BYTES + 1) as u64)
        .read_to_end(&mut buf)
        .map_err(|_| (PricingSyncFailureReason::Offline, None))?;

    if buf.len() > MAX_CATALOG_BYTES {
        return Err((PricingSyncFailureReason::InvalidCatalog, None));
    }

    Ok(buf)
}

// ---------------------------------------------------------------- Desktop 状态机管理器

pub struct PricingSyncManager {
    stage: Mutex<PricingSyncStage>,
    syncing: AtomicBool,
}

impl Default for PricingSyncManager {
    fn default() -> Self {
        Self::new()
    }
}

impl PricingSyncManager {
    pub fn new() -> Self {
        Self {
            stage: Mutex::new(PricingSyncStage::Idle),
            syncing: AtomicBool::new(false),
        }
    }

    pub fn current_stage(&self) -> PricingSyncStage {
        self.stage.lock().unwrap().clone()
    }

    pub fn summary(&self) -> PricingCatalogSummary {
        let settings = crate::settings::load_settings(&crate::paths::data_root());
        let source_str = match bruce_win_viewmodel::model_catalog::current_source() {
            bruce_win_viewmodel::model_catalog::CatalogSource::Builtin => "builtin",
            bruce_win_viewmodel::model_catalog::CatalogSource::Synced => "synced",
        };

        PricingCatalogSummary {
            source: source_str.to_owned(),
            updated_at: bruce_win_viewmodel::model_catalog::current_updated_at(),
            model_count: bruce_win_viewmodel::model_catalog::active_catalog().len(),
            last_sync_at: settings.pricing_last_sync_at,
            auto_sync_enabled: settings.auto_sync_pricing_catalog,
            stage: self.current_stage(),
        }
    }

    #[cfg(feature = "desktop")]
    pub fn publish(&self, app: &AppHandle) {
        let payload = self.summary();
        let _ = app.emit("pricing-catalog-state", &payload);
    }

    /// 恢复内置基线
    #[cfg(feature = "desktop")]
    pub fn restore_builtin(&self, app: &AppHandle) {
        let path = pricing_catalog_path();
        if path.exists() {
            let _ = fs::remove_file(&path);
        }

        bruce_win_viewmodel::model_catalog::reset_to_builtin();

        let updated_at = bruce_win_viewmodel::model_catalog::current_updated_at();
        let model_count = bruce_win_viewmodel::model_catalog::active_catalog().len();

        {
            let mut stage_guard = self.stage.lock().unwrap();
            *stage_guard = PricingSyncStage::Restored {
                updated_at,
                model_count,
            };
        }

        self.publish(app);

        // 恢复内置后触发采集重算
        let app_handle = app.clone();
        std::thread::spawn(move || {
            if let Some(control) = app_handle.try_state::<crate::scheduler::SchedulerControl>() {
                control.request_manual_refresh();
            }
        });
    }

    /// 同步操作 (manual: true 用户点击; manual: false 定时静默)
    #[cfg(feature = "desktop")]
    pub fn sync(&self, app: &AppHandle, manual: bool) {
        if self.syncing.swap(true, Ordering::SeqCst) {
            return;
        }

        if manual {
            {
                let mut stage_guard = self.stage.lock().unwrap();
                *stage_guard = PricingSyncStage::Syncing;
            }
            self.publish(app);
        }

        let app_handle = app.clone();
        std::thread::spawn(move || {
            let manager = app_handle.state::<PricingSyncManager>();
            manager.run_sync_task(&app_handle, manual);
        });
    }

    #[cfg(feature = "desktop")]
    fn run_sync_task(&self, app: &AppHandle, manual: bool) {
        let fetch_res = fetch_catalog_bytes(RAW_CATALOG_URL);
        let result = match fetch_res {
            Ok(bytes) => self.process_fetched_bytes(&bytes),
            Err(err) => Err(err),
        };

        self.syncing.store(false, Ordering::SeqCst);

        match result {
            Ok(stage) => {
                // 更新设置持久化上次同步时间
                let root = crate::paths::data_root();
                let mut settings = crate::settings::load_settings(&root);
                settings.pricing_last_sync_at = Some(Local::now().to_rfc3339());
                let _ = crate::settings::save_settings(&root, &settings);

                {
                    let mut stage_guard = self.stage.lock().unwrap();
                    *stage_guard = stage;
                }
                self.publish(app);

                // 同步成功触发一次采集重算
                let app_handle = app.clone();
                std::thread::spawn(move || {
                    if let Some(control) =
                        app_handle.try_state::<crate::scheduler::SchedulerControl>()
                    {
                        control.request_manual_refresh();
                    }
                });
            }
            Err((reason, status_code)) => {
                if manual {
                    {
                        let mut stage_guard = self.stage.lock().unwrap();
                        *stage_guard = PricingSyncStage::Failed {
                            reason,
                            status_code,
                        };
                    }
                    self.publish(app);
                } else {
                    // 自动同步失败完全静默, stage 保持 Idle
                    let mut stage_guard = self.stage.lock().unwrap();
                    *stage_guard = PricingSyncStage::Idle;
                }
            }
        }
    }

    /// 解析并落地获取到的价格表字节流
    pub fn process_fetched_bytes(
        &self,
        bytes: &[u8],
    ) -> Result<PricingSyncStage, (PricingSyncFailureReason, Option<u16>)> {
        let catalog = collector_domain::pricing::CatalogFile::parse_and_validate(bytes)
            .map_err(|_| (PricingSyncFailureReason::InvalidCatalog, None))?;

        let builtin_date = collector_domain::pricing::builtin_updated_at();
        if collector_domain::pricing::compare_updated_at(&catalog.updated_at, builtin_date)
            == std::cmp::Ordering::Less
        {
            return Err((PricingSyncFailureReason::StaleVersion, None));
        }

        let current_entries = bruce_win_viewmodel::model_catalog::active_catalog();
        let diff = calculate_diff(&current_entries, &catalog);
        let listed_count = catalog.models.iter().filter(|m| m.listed).count();

        let is_up_to_date = bruce_win_viewmodel::model_catalog::current_source()
            == bruce_win_viewmodel::model_catalog::CatalogSource::Synced
            && catalog.updated_at == bruce_win_viewmodel::model_catalog::current_updated_at()
            && diff.added_count == 0
            && diff.adjusted_count == 0;

        if is_up_to_date {
            return Ok(PricingSyncStage::UpToDate {
                updated_at: catalog.updated_at,
                model_count: listed_count,
            });
        }

        // 原子落盘
        let path = pricing_catalog_path();
        save_catalog_atomic(&path, bytes)
            .map_err(|_| (PricingSyncFailureReason::InvalidCatalog, None))?;

        // 运行时热替换
        bruce_win_viewmodel::model_catalog::set_active_catalog(
            &catalog.updated_at,
            &catalog.models,
        );

        Ok(PricingSyncStage::Updated {
            updated_at: catalog.updated_at,
            model_count: listed_count,
            added_count: diff.added_count,
            adjusted_count: diff.adjusted_count,
        })
    }
}

// ---------------------------------------------------------------- 自动化定时调度

#[cfg(feature = "desktop")]
pub fn start_auto_sync_timer(app: AppHandle) {
    std::thread::spawn(move || {
        // 启动 30 秒后静默检查一次
        std::thread::sleep(Duration::from_secs(30));

        let settings = crate::settings::load_settings(&crate::paths::data_root());
        if settings.auto_sync_pricing_catalog {
            let manager = app.state::<PricingSyncManager>();
            manager.sync(&app, false);
        }

        // 之后每 24 小时检查一次
        loop {
            std::thread::sleep(Duration::from_secs(24 * 3600));

            let settings = crate::settings::load_settings(&crate::paths::data_root());
            if settings.auto_sync_pricing_catalog {
                let manager = app.state::<PricingSyncManager>();
                manager.sync(&app, false);
            }
        }
    });
}

// ---------------------------------------------------------------- 单测

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_stage_serialization_matches_parity_fixture() {
        let fixture_path = Path::new("../../../tests/fixtures/pricing-sync-parity/cases.json");
        let data = fs::read_to_string(fixture_path).expect("读取 cases.json");
        let root: serde_json::Value = serde_json::from_str(&data).expect("解析 json");

        let stages = root["stages"].as_array().expect("stages array");
        for item in stages {
            let phase = &item["phase"];
            let parsed_stage: PricingSyncStage =
                serde_json::from_value(phase.clone()).expect("反序列化 stage");
            let reserialized = serde_json::to_value(&parsed_stage).expect("序列化 stage");
            assert_eq!(phase, &reserialized, "Stage 序列化往返必须一致");
        }
    }

    #[test]
    fn test_anti_rollback_purges_stale_file() {
        let _guard = bruce_win_viewmodel::model_catalog::TEST_LOCK
            .lock()
            .unwrap();
        let temp_dir = std::env::temp_dir().join(format!("test-bruce-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&temp_dir).unwrap();
        let file_path = temp_dir.join("pricing-catalog.json");

        let stale_json = r#"{
            "schemaVersion": 1,
            "updatedAt": "2020-01-01",
            "models": [
                {"model": "stale", "displayName": "Stale", "vendor": "V", "input": 1, "output": 1, "listed": true}
            ]
        }"#;
        fs::write(&file_path, stale_json).unwrap();

        init_pricing_catalog(&file_path);

        assert_eq!(
            bruce_win_viewmodel::model_catalog::current_source(),
            bruce_win_viewmodel::model_catalog::CatalogSource::Builtin
        );
        assert!(!file_path.exists(), "过期缓存必须被清理");

        let _ = fs::remove_dir_all(&temp_dir);
        bruce_win_viewmodel::model_catalog::reset_to_builtin();
    }

    #[test]
    fn test_calculate_diff_counts() {
        let current = vec![
            bruce_win_viewmodel::model_catalog::CatalogEntry {
                model_name: "m1".to_owned(),
                display_name: "M1".to_owned(),
                vendor: "V".to_owned(),
                input_price_per_million: 1.0,
                output_price_per_million: 2.0,
                cache_read_price_per_million: None,
                note: "".to_owned(),
            },
            bruce_win_viewmodel::model_catalog::CatalogEntry {
                model_name: "m2".to_owned(),
                display_name: "M2".to_owned(),
                vendor: "V".to_owned(),
                input_price_per_million: 5.0,
                output_price_per_million: 10.0,
                cache_read_price_per_million: Some(0.5),
                note: "".to_owned(),
            },
        ];

        let new_catalog = collector_domain::pricing::CatalogFile {
            schema_version: 1,
            updated_at: "2026-11-01".to_owned(),
            models: vec![
                collector_domain::CatalogModel {
                    model: "m1".to_owned(),
                    display_name: "M1".to_owned(),
                    vendor: "V".to_owned(),
                    input: 1.5, // adjusted
                    output: 2.0,
                    cache_read: None,
                    cache_write: None,
                    note: "".to_owned(),
                    listed: true,
                    peak: None,
                    long_context: None,
                },
                collector_domain::CatalogModel {
                    model: "m2".to_owned(),
                    display_name: "M2".to_owned(),
                    vendor: "V".to_owned(),
                    input: 5.0, // unchanged
                    output: 10.0,
                    cache_read: Some(0.5),
                    cache_write: None,
                    note: "".to_owned(),
                    listed: true,
                    peak: None,
                    long_context: None,
                },
                collector_domain::CatalogModel {
                    model: "m3".to_owned(), // added
                    display_name: "M3".to_owned(),
                    vendor: "V".to_owned(),
                    input: 2.0,
                    output: 4.0,
                    cache_read: None,
                    cache_write: None,
                    note: "".to_owned(),
                    listed: true,
                    peak: None,
                    long_context: None,
                },
            ],
        };

        let diff = calculate_diff(&current, &new_catalog);
        assert_eq!(diff.added_count, 1);
        assert_eq!(diff.adjusted_count, 1);
    }
}
