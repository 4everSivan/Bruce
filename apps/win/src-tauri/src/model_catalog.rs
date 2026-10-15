//! 设置页「模型计费」的展示目录 —— **镜像 mac `BuiltinModelPricingCatalog`**（唯一事实源）。
//!
//! 语义边界：本表只服务设置页展示（行集 / 显示名 / 厂商 / 单价），采集侧的费用估算仍走
//! `collector-domain::PricingTable`（成本口径，覆盖面更广）。mac 侧同样是两套目录，故不是
//! 重复实现而是同构：新增或调整模型时，先改 mac 目录再同步本表（C033）。

use serde_json::{json, Value};

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

pub const CATALOG: &[CatalogEntry] = &[
    CatalogEntry {
        model_name: "k3-agent",
        display_name: "Kimi K3 (Agent)",
        vendor: "Moonshot Kimi",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.30),
        note: "Kimi 官方标准包",
    },
    CatalogEntry {
        model_name: "k3",
        display_name: "Kimi K3",
        vendor: "Moonshot Kimi",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.30),
        note: "Kimi 官方标准包",
    },
    CatalogEntry {
        model_name: "k3-256k",
        display_name: "Kimi K3 (256k)",
        vendor: "Moonshot Kimi",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.30),
        note: "长上下文 256k 窗口",
    },
    CatalogEntry {
        model_name: "kimi-code",
        display_name: "Kimi Code",
        vendor: "Moonshot Kimi",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.30),
        note: "Kimi Code 编程补全",
    },
    CatalogEntry {
        model_name: "gpt-5.6-luna",
        display_name: "GPT-5.6 Luna",
        vendor: "OpenAI / Codex",
        input_price_per_million: 0.20,
        output_price_per_million: 1.20,
        cache_read_price_per_million: Some(0.02),
        note: "高频极速轻量模型",
    },
    CatalogEntry {
        model_name: "gpt-5.6-sol",
        display_name: "GPT-5.6 Sol",
        vendor: "OpenAI / Codex",
        input_price_per_million: 4.00,
        output_price_per_million: 20.00,
        cache_read_price_per_million: Some(0.40),
        note: "旗舰推理大模型",
    },
    CatalogEntry {
        model_name: "gpt-5.6-terra",
        display_name: "GPT-5.6 Terra",
        vendor: "OpenAI / Codex",
        input_price_per_million: 2.00,
        output_price_per_million: 12.00,
        cache_read_price_per_million: Some(0.20),
        note: "主力平衡型编程模型",
    },
    CatalogEntry {
        model_name: "gpt-5.4",
        display_name: "GPT-5.4",
        vendor: "OpenAI / Codex",
        input_price_per_million: 2.50,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.25),
        note: "标准通用模型",
    },
    CatalogEntry {
        model_name: "gpt-5.4-mini",
        display_name: "GPT-5.4 mini",
        vendor: "OpenAI / Codex",
        input_price_per_million: 0.15,
        output_price_per_million: 0.60,
        cache_read_price_per_million: Some(0.015),
        note: "轻量高吞吐模型",
    },
    CatalogEntry {
        model_name: "gpt-5.2-codex",
        display_name: "GPT-5.2 Codex",
        vendor: "OpenAI / Codex",
        input_price_per_million: 1.75,
        output_price_per_million: 14.00,
        cache_read_price_per_million: Some(0.175),
        note: "经典专用代码模型",
    },
    CatalogEntry {
        model_name: "codex-auto-review",
        display_name: "Codex Auto Review",
        vendor: "OpenAI / Codex",
        input_price_per_million: 1.75,
        output_price_per_million: 14.00,
        cache_read_price_per_million: Some(0.175),
        note: "自动化审查分析",
    },
    CatalogEntry {
        model_name: "deepseek-v4-flash",
        display_name: "DeepSeek V4.1 Flash",
        vendor: "DeepSeek",
        input_price_per_million: 0.15,
        output_price_per_million: 0.60,
        cache_read_price_per_million: Some(0.003),
        note: "闲时基准单价 (忙时自动按两倍核算)",
    },
    CatalogEntry {
        model_name: "deepseek-v4-pro",
        display_name: "DeepSeek V4 Pro",
        vendor: "DeepSeek",
        input_price_per_million: 0.66,
        output_price_per_million: 1.98,
        cache_read_price_per_million: Some(0.022),
        note: "深度推理主力",
    },
    CatalogEntry {
        model_name: "deepseek-chat",
        display_name: "DeepSeek Chat",
        vendor: "DeepSeek",
        input_price_per_million: 0.14,
        output_price_per_million: 0.28,
        cache_read_price_per_million: Some(0.014),
        note: "经典通用对话",
    },
    CatalogEntry {
        model_name: "deepseek-reasoner",
        display_name: "DeepSeek Reasoner",
        vendor: "DeepSeek",
        input_price_per_million: 0.55,
        output_price_per_million: 2.19,
        cache_read_price_per_million: Some(0.14),
        note: "经典推理思考模型",
    },
    CatalogEntry {
        model_name: "glm-5.3",
        display_name: "GLM-5.3",
        vendor: "智谱 AI (Zhipu)",
        input_price_per_million: 1.40,
        output_price_per_million: 4.40,
        cache_read_price_per_million: Some(0.26),
        note: "国产旗舰通用模型",
    },
    CatalogEntry {
        model_name: "glm-5.3-flash",
        display_name: "GLM-5.3 Flash",
        vendor: "智谱 AI (Zhipu)",
        input_price_per_million: 0.15,
        output_price_per_million: 0.50,
        cache_read_price_per_million: Some(0.015),
        note: "高吞吐量轻量模型",
    },
    CatalogEntry {
        model_name: "glm-4-plus",
        display_name: "GLM-4 Plus",
        vendor: "智谱 AI (Zhipu)",
        input_price_per_million: 1.40,
        output_price_per_million: 1.40,
        cache_read_price_per_million: Some(0.26),
        note: "高阶对话模型",
    },
    CatalogEntry {
        model_name: "step-3.7-flash",
        display_name: "Step-3.7 Flash",
        vendor: "阶跃星辰 (StepFun)",
        input_price_per_million: 0.20,
        output_price_per_million: 1.15,
        cache_read_price_per_million: Some(0.03),
        note: "高性价比编程模型",
    },
    CatalogEntry {
        model_name: "step-5-preview",
        display_name: "Step-5 Preview",
        vendor: "阶跃星辰 (StepFun)",
        input_price_per_million: 1.00,
        output_price_per_million: 2.70,
        cache_read_price_per_million: Some(0.05),
        note: "阶跃新一代旗舰推理",
    },
    CatalogEntry {
        model_name: "hy3",
        display_name: "Hunyuan 3",
        vendor: "腾讯混元",
        input_price_per_million: 0.15,
        output_price_per_million: 0.60,
        cache_read_price_per_million: Some(0.015),
        note: "腾讯混元基础模型 (~1.0/4.0 CNY)",
    },
    CatalogEntry {
        model_name: "hy4-preview",
        display_name: "Hunyuan 4 Preview",
        vendor: "腾讯混元",
        input_price_per_million: 0.85,
        output_price_per_million: 2.55,
        cache_read_price_per_million: Some(0.08),
        note: "新一代大语言模型 (~6.0/18.0 CNY)",
    },
    CatalogEntry {
        model_name: "claude-sonnet-5",
        display_name: "Claude Sonnet 5",
        vendor: "Anthropic",
        input_price_per_million: 2.00,
        output_price_per_million: 10.00,
        cache_read_price_per_million: Some(0.20),
        note: "Claude 5 代主力模型",
    },
    CatalogEntry {
        model_name: "claude-haiku-4-5",
        display_name: "Claude Haiku 4.5",
        vendor: "Anthropic",
        input_price_per_million: 1.00,
        output_price_per_million: 5.00,
        cache_read_price_per_million: Some(0.10),
        note: "极速轻量补全模型",
    },
    CatalogEntry {
        model_name: "claude-3-5-sonnet",
        display_name: "Claude 3.5 Sonnet",
        vendor: "Anthropic",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.30),
        note: "经典通用编程大模型",
    },
    CatalogEntry {
        model_name: "claude-3-5-haiku",
        display_name: "Claude 3.5 Haiku",
        vendor: "Anthropic",
        input_price_per_million: 0.80,
        output_price_per_million: 4.00,
        cache_read_price_per_million: Some(0.08),
        note: "高性价比快速响应",
    },
    CatalogEntry {
        model_name: "grok-3",
        display_name: "Grok 3",
        vendor: "xAI",
        input_price_per_million: 3.00,
        output_price_per_million: 15.00,
        cache_read_price_per_million: Some(0.75),
        note: "全功能推理模型",
    },
    CatalogEntry {
        model_name: "grok-3-mini",
        display_name: "Grok 3 Mini",
        vendor: "xAI",
        input_price_per_million: 0.30,
        output_price_per_million: 1.50,
        cache_read_price_per_million: Some(0.075),
        note: "极速思考模型",
    },
];

/// 供设置页消费的 JSON（数组，字段名与前端约定一致）。
pub fn as_json() -> Value {
    Value::Array(
        CATALOG
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

    /// 行数与 mac `BuiltinModelPricingCatalog` 一致 (28); 若 mac 侧增删模型需同步本表。
    #[test]
    fn catalog_row_count_matches_mac_catalog() {
        assert_eq!(CATALOG.len(), 28);
    }

    #[test]
    fn catalog_entries_are_unique_and_complete() {
        let mut names = BTreeSet::new();
        for entry in CATALOG {
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
        assert_eq!(rows.len(), 28);
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
        let without_cache = rows.iter().find(|row| row["model"] == "codex-auto-review");
        if let Some(entry) = without_cache {
            assert!(
                entry.get("cacheReadPricePerMillion").is_some(),
                "缓存键必须存在"
            );
        }
    }
}
