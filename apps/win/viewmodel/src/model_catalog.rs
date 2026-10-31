//! 模型展示目录 —— 设置页「模型计费」（行集 / 显示名 / 厂商 / 单价）与用量工作台的模型
//! 显示名 / 厂商（`analytics`）。
//!
//! C108 起不再维护独立副本：行集直接派生自采集端价卡 `config/pricing-catalog.json`，
//! T21 支持运行期热更新（支持从远端同步的新版本切换，并保留编译期内置价卡作为离线兜底）。

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::{Arc, RwLock};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogEntry {
    pub model_name: String,
    pub display_name: String,
    pub vendor: String,
    pub input_price_per_million: f64,
    pub output_price_per_million: f64,
    pub cache_read_price_per_million: Option<f64>,
    pub note: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CatalogSource {
    Builtin,
    Synced,
}

struct CatalogState {
    source: CatalogSource,
    updated_at: String,
    entries: Arc<Vec<CatalogEntry>>,
}

static STATE: RwLock<Option<CatalogState>> = RwLock::new(None);

pub static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn builtin_entries() -> Vec<CatalogEntry> {
    collector_domain::pricing::builtin_catalog()
        .iter()
        .filter(|entry| entry.listed)
        .map(|entry| CatalogEntry {
            model_name: entry.model.clone(),
            display_name: entry.display_name.clone(),
            vendor: entry.vendor.clone(),
            input_price_per_million: entry.input,
            output_price_per_million: entry.output,
            cache_read_price_per_million: entry.cache_read,
            note: entry.note.clone(),
        })
        .collect()
}

fn with_state<R>(f: impl FnOnce(&CatalogState) -> R) -> R {
    let read = STATE.read().unwrap();
    if let Some(ref state) = *read {
        return f(state);
    }
    drop(read);
    let mut write = STATE.write().unwrap();
    if write.is_none() {
        *write = Some(CatalogState {
            source: CatalogSource::Builtin,
            updated_at: collector_domain::pricing::builtin_updated_at().to_owned(),
            entries: Arc::new(builtin_entries()),
        });
    }
    f(write.as_ref().unwrap())
}

/// 当前价格表生效来源 (内置 / 已同步)
pub fn current_source() -> CatalogSource {
    with_state(|s| s.source)
}

/// 当前价格表修订日期版本
pub fn current_updated_at() -> String {
    with_state(|s| s.updated_at.clone())
}

/// 获取当前活动模型展示目录
pub fn active_catalog() -> Arc<Vec<CatalogEntry>> {
    with_state(|s| Arc::clone(&s.entries))
}

/// 兼容别名：获取当前活动目录
pub fn catalog() -> Arc<Vec<CatalogEntry>> {
    active_catalog()
}

/// 运行期热替换活动目录（已同步状态）
pub fn set_active_catalog(updated_at: &str, models: &[collector_domain::CatalogModel]) {
    let entries: Vec<CatalogEntry> = models
        .iter()
        .filter(|entry| entry.listed)
        .map(|entry| CatalogEntry {
            model_name: entry.model.clone(),
            display_name: entry.display_name.clone(),
            vendor: entry.vendor.clone(),
            input_price_per_million: entry.input,
            output_price_per_million: entry.output,
            cache_read_price_per_million: entry.cache_read,
            note: entry.note.clone(),
        })
        .collect();

    let mut write = STATE.write().unwrap();
    *write = Some(CatalogState {
        source: CatalogSource::Synced,
        updated_at: updated_at.to_owned(),
        entries: Arc::new(entries),
    });
}

/// 恢复为编译期内置基线
pub fn reset_to_builtin() {
    let mut write = STATE.write().unwrap();
    *write = Some(CatalogState {
        source: CatalogSource::Builtin,
        updated_at: collector_domain::pricing::builtin_updated_at().to_owned(),
        entries: Arc::new(builtin_entries()),
    });
}

/// 供设置页消费的 JSON（数组，字段名与前端约定一致）。
pub fn as_json() -> Value {
    let entries = active_catalog();
    Value::Array(
        entries
            .iter()
            .map(|entry| {
                json!({
                    "model": entry.model_name,
                    "displayName": entry.display_name,
                    "vendor": entry.vendor,
                    "inputPricePerMillion": entry.input_price_per_million,
                    "outputPricePerMillion": entry.output_price_per_million,
                    "cacheReadPricePerMillion": entry.cache_read_price_per_million,
                    "currency": "USD",
                    "note": entry.note
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// 展示行即采集端目录中 listed 的行 (C108: 与计费同源, 不再单独计数维护)。
    #[test]
    fn catalog_rows_are_the_listed_collector_rows() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_to_builtin();
        let listed = collector_domain::pricing::builtin_catalog()
            .iter()
            .filter(|entry| entry.listed)
            .count();
        assert_eq!(catalog().len(), listed);
        assert_eq!(current_source(), CatalogSource::Builtin);
        let table = collector_domain::PricingTable::default();
        for entry in catalog().iter() {
            let rule = table.resolve(&entry.model_name).expect("展示行必须可计费");
            assert_eq!(rule.input_price_per_million, entry.input_price_per_million);
            assert_eq!(
                rule.output_price_per_million,
                entry.output_price_per_million
            );
            assert_eq!(
                rule.cache_read_price_per_million,
                entry.cache_read_price_per_million
            );
        }
    }

    #[test]
    fn catalog_entries_are_unique_and_complete() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_to_builtin();
        let mut names = BTreeSet::new();
        for entry in catalog().iter() {
            assert!(!entry.model_name.is_empty(), "模型名不得为空");
            assert!(!entry.display_name.is_empty(), "显示名不得为空");
            assert!(!entry.vendor.is_empty(), "厂商不得为空");
            assert!(entry.input_price_per_million >= 0.0 && entry.output_price_per_million >= 0.0);
            assert!(
                names.insert(&entry.model_name),
                "模型名重复: {}",
                entry.model_name
            );
        }
    }

    #[test]
    fn catalog_json_uses_frontend_contract_keys() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_to_builtin();
        let value = as_json();
        let rows = value.as_array().expect("数组");
        assert_eq!(rows.len(), catalog().len());
        let first = rows
            .iter()
            .find(|row| row["model"] == "k3-agent")
            .expect("k3-agent 在列");
        assert_eq!(first["displayName"], "Kimi K3 (Agent)");
        assert_eq!(first["vendor"], "Moonshot Kimi");
        assert_eq!(first["inputPricePerMillion"], 3.0);
        assert_eq!(first["cacheReadPricePerMillion"], 0.30);
        assert_eq!(first["currency"], "USD");
        // 无缓存单价的条目必须以 null 出现, 而不是缺键
        let without_cache = rows.iter().find(|row| row["model"] == "jev-latest");
        if let Some(entry) = without_cache {
            assert!(
                entry.get("cacheReadPricePerMillion").is_some(),
                "缓存键必须存在"
            );
            assert!(entry["cacheReadPricePerMillion"].is_null());
        }
    }

    #[test]
    fn test_dynamic_catalog_replacement_and_reset() {
        let _guard = TEST_LOCK.lock().unwrap();
        reset_to_builtin();
        assert_eq!(current_source(), CatalogSource::Builtin);

        let custom_models = vec![
            collector_domain::CatalogModel {
                model: "dynamic-model-1".to_owned(),
                display_name: "Dynamic Model 1".to_owned(),
                vendor: "TestVendor".to_owned(),
                input: 10.0,
                output: 20.0,
                cache_read: Some(1.0),
                cache_write: None,
                note: "custom".to_owned(),
                listed: true,
                peak: None,
                long_context: None,
            },
            collector_domain::CatalogModel {
                model: "dynamic-unlisted".to_owned(),
                display_name: "Dynamic Unlisted".to_owned(),
                vendor: "TestVendor".to_owned(),
                input: 5.0,
                output: 10.0,
                cache_read: None,
                cache_write: None,
                note: "unlisted".to_owned(),
                listed: false,
                peak: None,
                long_context: None,
            },
        ];

        set_active_catalog("2026-11-15", &custom_models);
        assert_eq!(current_source(), CatalogSource::Synced);
        assert_eq!(current_updated_at(), "2026-11-15");
        assert_eq!(catalog().len(), 1);
        assert_eq!(catalog()[0].model_name, "dynamic-model-1");

        let json = as_json();
        let arr = json.as_array().expect("array");
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["model"], "dynamic-model-1");

        reset_to_builtin();
        assert_eq!(current_source(), CatalogSource::Builtin);
        assert_eq!(
            current_updated_at(),
            collector_domain::pricing::builtin_updated_at()
        );
        assert_eq!(
            catalog().len(),
            collector_domain::pricing::builtin_catalog()
                .iter()
                .filter(|m| m.listed)
                .count()
        );
    }
}
