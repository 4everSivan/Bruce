//! 模型展示目录 —— 设置页「模型计费」（行集 / 显示名 / 厂商 / 单价）与用量工作台的模型
//! 显示名 / 厂商（`analytics`）。
//!
//! C108 起不再维护独立副本：行集直接派生自采集端价卡
//! `core/collector/crates/collector-domain/pricing-catalog.json`（唯一事实源，计费同源），
//! 新增或调整模型只改该 JSON；mac 侧目录由 `scripts/gen-pricing-catalog.mjs` 从同一文件生成。

use serde_json::{json, Value};
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy)]
pub struct CatalogEntry {
    pub model_name: &'static str,
    pub display_name: &'static str,
    pub vendor: &'static str,
    pub input_price_per_million: f64,
    pub output_price_per_million: f64,
    pub cache_read_price_per_million: Option<f64>,
    pub note: &'static str,
}

/// 设置页 / 工作台展示的价卡行 (C108): 派生自采集端 `collector_domain::pricing::catalog()`
/// (`pricing-catalog.json` 唯一事实源) 中 `listed` 的行, 顺序即展示顺序。
pub fn catalog() -> &'static [CatalogEntry] {
    static ENTRIES: OnceLock<Vec<CatalogEntry>> = OnceLock::new();
    ENTRIES.get_or_init(|| {
        collector_domain::pricing::catalog()
            .iter()
            .filter(|entry| entry.listed)
            .map(|entry| CatalogEntry {
                model_name: &entry.model,
                display_name: &entry.display_name,
                vendor: &entry.vendor,
                input_price_per_million: entry.input,
                output_price_per_million: entry.output,
                cache_read_price_per_million: entry.cache_read,
                note: &entry.note,
            })
            .collect()
    })
}

/// 供设置页消费的 JSON（数组，字段名与前端约定一致）。
pub fn as_json() -> Value {
    Value::Array(
        catalog()
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
        let listed = collector_domain::pricing::catalog()
            .iter()
            .filter(|entry| entry.listed)
            .count();
        assert_eq!(catalog().len(), listed);
        let table = collector_domain::PricingTable::default();
        for entry in catalog() {
            let rule = table.resolve(entry.model_name).expect("展示行必须可计费");
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
        let mut names = BTreeSet::new();
        for entry in catalog() {
            assert!(!entry.model_name.is_empty(), "模型名不得为空");
            assert!(!entry.display_name.is_empty(), "显示名不得为空");
            assert!(!entry.vendor.is_empty(), "厂商不得为空");
            assert!(entry.input_price_per_million >= 0.0 && entry.output_price_per_million >= 0.0);
            assert!(
                names.insert(entry.model_name),
                "模型名重复: {}",
                entry.model_name
            );
        }
    }

    #[test]
    fn catalog_json_uses_frontend_contract_keys() {
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
}
