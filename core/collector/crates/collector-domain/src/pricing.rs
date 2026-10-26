#![deny(unsafe_code)]

use crate::TokenBucket;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Pricing rates for a model per million tokens.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelPricing {
    pub input_price_per_million: f64,
    pub output_price_per_million: f64,
    #[serde(default)]
    pub cache_read_price_per_million: Option<f64>,
    #[serde(default = "default_usd")]
    pub currency: String,
    #[serde(default)]
    pub note: Option<String>,
    /// 5 分钟 TTL 缓存写入相对输入单价的倍率 (C107); 缺省 1.0 (按输入单价计)。
    #[serde(default)]
    pub cache_write_multiplier: Option<f64>,
    /// 1 小时 TTL 缓存写入相对输入单价的倍率 (C107); 缺省沿用 5 分钟倍率。
    #[serde(default)]
    pub cache_write_1h_multiplier: Option<f64>,
}

/// 内置价卡目录行 (C108)。唯一事实源为 crate 根目录的 `pricing-catalog.json`:
/// 采集端计费、Windows 设置页 / 工作台与 mac 设置页 (由 `scripts/gen-pricing-catalog.mjs`
/// 生成) 均派生自同一份数据, 不再各自维护价卡副本。单位为美元 / 百万 token。
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CatalogModel {
    pub model: String,
    pub display_name: String,
    pub vendor: String,
    pub input: f64,
    pub output: f64,
    /// 缺省 (null) 时按输入单价 10% 计 (`calculate_cost` 兜底)。
    pub cache_read: Option<f64>,
    /// [5 分钟 TTL 倍率, 1 小时 TTL 倍率] (相对输入单价); 缺省按 1.0。
    #[serde(default)]
    pub cache_write: Option<(f64, f64)>,
    pub note: String,
    /// false 的行参与计费但不在设置页单列 (版本别名 / 受限型号)。
    #[serde(default = "listed_by_default")]
    pub listed: bool,
}

fn listed_by_default() -> bool {
    true
}

#[derive(Deserialize)]
struct CatalogFile {
    models: Vec<CatalogModel>,
}

/// 全部内置价卡行, 顺序即设置页展示顺序 (C108)。
///
/// 数据随源码编译期嵌入; 可解析性与唯一性由 `catalog_is_well_formed` 用例锁定,
/// 故运行期解析失败不可达。
pub fn catalog() -> &'static [CatalogModel] {
    static CATALOG: std::sync::OnceLock<Vec<CatalogModel>> = std::sync::OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str::<CatalogFile>(include_str!("../pricing-catalog.json"))
            .expect("pricing-catalog.json 由 catalog_is_well_formed 用例保证可解析")
            .models
    })
}

fn default_usd() -> String {
    "USD".to_string()
}

/// User override configuration for model pricing.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ModelPricingOverride {
    #[serde(default)]
    pub input_price_per_million: Option<f64>,
    #[serde(default)]
    pub output_price_per_million: Option<f64>,
    #[serde(default)]
    pub cache_read_price_per_million: Option<f64>,
    #[serde(default)]
    pub currency: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub struct PricingTable {
    builtin: HashMap<String, ModelPricing>,
    overrides: HashMap<String, ModelPricingOverride>,
}

impl Default for PricingTable {
    fn default() -> Self {
        Self::new(HashMap::new())
    }
}

impl PricingTable {
    pub fn new(overrides: HashMap<String, ModelPricingOverride>) -> Self {
        let builtin = catalog()
            .iter()
            .map(|entry| {
                (
                    entry.model.to_lowercase(),
                    ModelPricing {
                        input_price_per_million: entry.input,
                        output_price_per_million: entry.output,
                        cache_read_price_per_million: entry.cache_read,
                        currency: default_usd(),
                        note: Some(entry.note.clone()),
                        cache_write_multiplier: entry
                            .cache_write
                            .map(|(five_minutes, _)| five_minutes),
                        cache_write_1h_multiplier: entry.cache_write.map(|(_, one_hour)| one_hour),
                    },
                )
            })
            .collect();
        Self { builtin, overrides }
    }

    /// Resolves model pricing by checking overrides first, then built-in baselines.
    pub fn resolve(&self, raw_model_name: &str) -> Option<ModelPricing> {
        let normalized = Self::normalize_model_name(raw_model_name);

        // 1. Direct or normalized match in overrides
        let matched_override = self
            .overrides
            .get(raw_model_name)
            .or_else(|| self.overrides.get(&normalized))
            .or_else(|| Self::best_prefix_match(&self.overrides, &normalized));

        // 2. Direct or normalized match in builtin
        let matched_builtin = self
            .builtin
            .get(&normalized)
            .or_else(|| self.builtin.get(raw_model_name))
            .or_else(|| Self::best_prefix_match(&self.builtin, &normalized));

        match (matched_builtin, matched_override) {
            (Some(builtin), Some(over)) => Some(ModelPricing {
                input_price_per_million: over
                    .input_price_per_million
                    .unwrap_or(builtin.input_price_per_million),
                output_price_per_million: over
                    .output_price_per_million
                    .unwrap_or(builtin.output_price_per_million),
                cache_read_price_per_million: over
                    .cache_read_price_per_million
                    .or(builtin.cache_read_price_per_million),
                currency: over
                    .currency
                    .clone()
                    .unwrap_or_else(|| builtin.currency.clone()),
                note: over.note.clone().or_else(|| builtin.note.clone()),
                cache_write_multiplier: builtin.cache_write_multiplier,
                cache_write_1h_multiplier: builtin.cache_write_1h_multiplier,
            }),
            (Some(builtin), None) => Some(builtin.clone()),
            (None, Some(over)) => {
                if let (Some(input), Some(output)) =
                    (over.input_price_per_million, over.output_price_per_million)
                {
                    Some(ModelPricing {
                        input_price_per_million: input,
                        output_price_per_million: output,
                        cache_read_price_per_million: over.cache_read_price_per_million,
                        currency: over.currency.clone().unwrap_or_else(default_usd),
                        note: over.note.clone(),
                        cache_write_multiplier: None,
                        cache_write_1h_multiplier: None,
                    })
                } else {
                    None
                }
            }
            (None, None) => None,
        }
    }

    /// Normalizes model identifier by lowercasing, stripping vendor/prefix, and bracketed tags.
    fn normalize_model_name(name: &str) -> String {
        let mut s = name.to_lowercase();
        if let Some(pos) = s.find('[') {
            s.truncate(pos);
        }
        if let Some(pos) = s.rfind('/') {
            s = s[pos + 1..].to_string();
        }
        s.trim().to_string()
    }

    /// 前缀匹配多候选时的确定性选择 (C070): 遍历 HashMap 取首个命中会随进程哈希种子
    /// 变化 (如 `gpt-5.4-mini-2026` 可能落到 `gpt-5.4` 而非 `gpt-5.4-mini` 的单价)。
    /// 优先「目录键是模型名前缀」的候选并取最长 (最具体的基础型号); 其次「模型名是目录键
    /// 前缀」的候选取最短; 同长按键名字典序。
    fn best_prefix_match<'a, V>(map: &'a HashMap<String, V>, normalized: &str) -> Option<&'a V> {
        map.iter()
            .filter(|(key, _)| Self::model_matches(normalized, key))
            .map(|(key, value)| {
                let target = Self::normalize_model_name(key);
                let base_of_model = normalized.starts_with(&target);
                // 排序键: (基础型号优先, 基础型号越长越好 / 扩展型号越短越好, 字典序)
                let length_rank = if base_of_model {
                    target.len() as i64
                } else {
                    -(target.len() as i64)
                };
                (
                    (base_of_model, length_rank, std::cmp::Reverse(key.clone())),
                    value,
                )
            })
            .max_by(|left, right| left.0.cmp(&right.0))
            .map(|(_, value)| value)
    }

    fn model_matches(model: &str, target: &str) -> bool {
        let t = Self::normalize_model_name(target);
        !t.is_empty() && (model == t || model.starts_with(&t) || t.starts_with(model))
    }

    /// Calculates token cost in USD for a given bucket and pricing rule.
    pub fn calculate_cost(&self, bucket: &TokenBucket, pricing: &ModelPricing) -> f64 {
        let input_cost = (bucket.input as f64) * pricing.input_price_per_million / 1_000_000.0;
        let output_cost = (bucket.output as f64) * pricing.output_price_per_million / 1_000_000.0;
        let cache_rate = pricing
            .cache_read_price_per_million
            .unwrap_or(pricing.input_price_per_million * 0.1);
        let cache_read_cost = (bucket.cache_read as f64) * cache_rate / 1_000_000.0;
        // C107: 缓存写入按 TTL 拆分计价; 倍率缺省 1.0 (非 Anthropic 模型沿用输入单价)。
        let one_hour = bucket.cache_creation_1h.min(bucket.cache_creation);
        let five_minutes = bucket.cache_creation - one_hour;
        let five_minute_multiplier = pricing.cache_write_multiplier.unwrap_or(1.0);
        let one_hour_multiplier = pricing
            .cache_write_1h_multiplier
            .unwrap_or(five_minute_multiplier);
        let cache_creation_cost = ((five_minutes as f64) * five_minute_multiplier
            + (one_hour as f64) * one_hour_multiplier)
            * pricing.input_price_per_million
            / 1_000_000.0;
        input_cost + output_cost + cache_read_cost + cache_creation_cost
    }

    /// 缓存读取相对按输入单价计费节省的 USD (C070):
    /// cacheRead × (输入单价 − 缓存读取单价); 缓存读取单价缺省时与 `calculate_cost` 同取输入 10%。
    pub fn calculate_cache_savings(&self, bucket: &TokenBucket, pricing: &ModelPricing) -> f64 {
        let cache_rate = pricing
            .cache_read_price_per_million
            .unwrap_or(pricing.input_price_per_million * 0.1);
        let saved_rate = (pricing.input_price_per_million - cache_rate).max(0.0);
        (bucket.cache_read as f64) * saved_rate / 1_000_000.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefix_resolution_is_deterministic_and_prefers_the_most_specific_base() {
        let table = PricingTable::default();
        // 两个目录键都是模型名前缀: 取最长的 gpt-5.4-mini, 而不是遍历顺序碰到的 gpt-5.4
        let rule = table.resolve("gpt-5.4-mini-2026").unwrap();
        assert_eq!(rule.input_price_per_million, 0.15);
        let rule = table.resolve("openai/o1-mini-preview").unwrap();
        assert_eq!(rule.input_price_per_million, 1.10);
        // 反复解析结果恒定 (不同 PricingTable 实例的 HashMap 哈希种子不同)
        for _ in 0..16 {
            let fresh = PricingTable::default();
            assert_eq!(
                fresh
                    .resolve("gpt-5.4-mini-2026")
                    .unwrap()
                    .input_price_per_million,
                0.15
            );
            assert_eq!(
                fresh.resolve("glm-5").map(|r| r.input_price_per_million),
                table.resolve("glm-5").map(|r| r.input_price_per_million),
            );
        }
    }

    #[test]
    fn cache_savings_price_cache_reads_against_the_input_rate() {
        let table = PricingTable::default();
        let rule = table.resolve("k3-agent").unwrap();
        let bucket = TokenBucket {
            input: 0,
            output: 0,
            cache_read: 1_000_000,
            cache_creation: 0,
            cache_creation_1h: 0,
            total: 1_000_000,
        };
        // (3.00 − 0.30) USD / 1M
        assert!((table.calculate_cache_savings(&bucket, &rule) - 2.70).abs() < 1e-9);
    }

    #[test]
    fn builtin_pricing_resolves_and_calculates_cost() {
        let table = PricingTable::default();
        let rule = table.resolve("k3-agent").expect("k3-agent should exist");
        assert_eq!(rule.input_price_per_million, 3.0);
        assert_eq!(rule.output_price_per_million, 15.0);
        assert_eq!(rule.cache_read_price_per_million, Some(0.30));

        let mut bucket = TokenBucket::default();
        bucket.add(1_000_000, 100_000, 500_000, 0);
        let cost = table.calculate_cost(&bucket, &rule);
        // input: 1M * 3.0 = 3.0
        // output: 0.1M * 15.0 = 1.5
        // cache: 0.5M * 0.30 = 0.15
        // total: 4.65
        assert!((cost - 4.65).abs() < 1e-6);
    }

    #[test]
    fn pricing_overrides_take_precedence() {
        let mut overrides = HashMap::new();
        overrides.insert(
            "k3-agent".to_string(),
            ModelPricingOverride {
                input_price_per_million: Some(1.0),
                output_price_per_million: None,
                cache_read_price_per_million: None,
                currency: None,
                note: Some("Custom contract".to_string()),
            },
        );
        let table = PricingTable::new(overrides);
        let rule = table.resolve("k3-agent").expect("k3-agent should exist");
        assert_eq!(rule.input_price_per_million, 1.0); // overridden
        assert_eq!(rule.output_price_per_million, 15.0); // inherited from builtin
        assert_eq!(rule.note, Some("Custom contract".to_string()));
    }

    #[test]
    fn normalized_model_matching() {
        let table = PricingTable::default();
        let rule = table
            .resolve("openai/gpt-5.6-luna")
            .expect("should resolve prefix");
        assert_eq!(rule.input_price_per_million, 0.20);
    }

    #[test]
    fn jev_pricing_resolves_and_calculates_cost() {
        let table = PricingTable::default();
        let rule = table
            .resolve("jev-latest")
            .expect("jev-latest should exist");
        assert_eq!(rule.input_price_per_million, 0.042);
        assert_eq!(rule.output_price_per_million, 0.0);
        assert_eq!(rule.cache_read_price_per_million, None);

        let mut bucket = TokenBucket::default();
        bucket.add(1_000_000, 500_000, 0, 0);
        let cost = table.calculate_cost(&bucket, &rule);
        // input: 1M * 0.042 = 0.042
        // output: 0.5M * 0.0 = 0.0
        // total: 0.042
        assert!((cost - 0.042).abs() < 1e-6);
    }

    #[test]
    fn cline_pass_pricing_resolves_and_calculates_cost() {
        let table = PricingTable::default();
        // 真实采集串: ZCode 将 cline-pass/* 原样写入 model_id, 依赖 normalize 剥离前缀后精确命中
        let rule = table
            .resolve("cline-pass/deepseek-v4.1-flash")
            .expect("cline-pass/deepseek-v4.1-flash should resolve");
        assert_eq!(rule.input_price_per_million, 0.30);
        assert_eq!(rule.output_price_per_million, 1.20);
        assert_eq!(rule.cache_read_price_per_million, Some(0.006));

        let mut bucket = TokenBucket::default();
        bucket.add(1_000_000, 100_000, 500_000, 0);
        let cost = table.calculate_cost(&bucket, &rule);
        // input: 1M * 0.30 = 0.30
        // output: 0.1M * 1.20 = 0.12
        // cache: 0.5M * 0.006 = 0.003
        // total: 0.423
        assert!((cost - 0.423).abs() < 1e-6);

        // 其余新增档位逐一可解析 (含多段 slug 与带点号 slug)
        for (model, input, output) in [
            ("cline-pass/kimi-k3", 3.00, 15.00),
            ("cline-pass/mimo-v2.5", 0.14, 0.28),
            ("cline-pass/mimo-v2.5-pro", 1.74, 3.48),
            ("cline-pass/minimax-m3", 0.30, 1.20),
            ("cline-pass/muse-spark-1.3-contributor", 0.10, 0.20),
            ("cline-pass/qwen3.8-max", 2.00, 6.00),
            ("cline-pass/qwen3.7-max", 2.50, 7.50),
            ("cline-pass/qwen3.7-plus", 0.40, 1.60),
            ("cline-pass/glm-5.3", 1.40, 4.40),
        ] {
            let rule = table
                .resolve(model)
                .unwrap_or_else(|| panic!("{model} should resolve"));
            assert_eq!(rule.input_price_per_million, input, "{model} input");
            assert_eq!(rule.output_price_per_million, output, "{model} output");
        }
    }

    #[test]
    fn cline_pass_entries_do_not_shadow_existing_models() {
        let table = PricingTable::default();
        // deepseek-v4.1-flash (ClinePass) 与既有 deepseek-v4-flash 双向前缀均不等, 不得互相劫持
        let legacy = table
            .resolve("deepseek-v4-flash")
            .expect("deepseek-v4-flash should exist");
        assert_eq!(legacy.input_price_per_million, 0.15);
        assert_eq!(legacy.cache_read_price_per_million, Some(0.003));
        // glm-5.3-flash 保持 Zhipu 既有条目 (cache 0.015), 未被 ClinePass 区块覆盖
        let glm = table
            .resolve("glm-5.3-flash")
            .expect("glm-5.3-flash should exist");
        assert_eq!(glm.cache_read_price_per_million, Some(0.015));
    }

    #[test]
    fn deepseek_flash_legacy_name_priced_official_tier() {
        // C073: 官方 API 旧命名 deepseek-flash 按 V4 Flash 档计价,
        // 且不劫持也不并入 v4.1 (ClinePass 档) 与 v4-flash 的解析。
        let table = PricingTable::default();
        let rule = table
            .resolve("deepseek-flash")
            .expect("deepseek-flash should resolve");
        assert_eq!(rule.input_price_per_million, 0.15);
        assert_eq!(rule.output_price_per_million, 0.60);
        assert_eq!(rule.cache_read_price_per_million, Some(0.003));

        let v41 = table
            .resolve("deepseek-v4.1-flash")
            .expect("deepseek-v4.1-flash should stay on ClinePass tier");
        assert_eq!(v41.input_price_per_million, 0.30);

        let mut bucket = TokenBucket::default();
        bucket.add(1_299_047, 190_062, 138_345_856, 0);
        // 实机 2026-10 旧命名桶: input 1.3M + output 0.19M + cache 138.3M
        // input: 1.299047 * 0.15 = 0.19486
        // output: 0.190062 * 0.60 = 0.11404
        // cache: 138.345856 * 0.003 = 0.41504
        // total ≈ 0.72393
        let cost = table.calculate_cost(&bucket, &rule);
        assert!((cost - 0.723_936).abs() < 1e-4, "cost = {cost}");
    }

    /// C107: Claude 单价按 Anthropic 官方校正; Opus 5 不得被 Opus 5.5 行反向前缀劫持。
    #[test]
    fn claude_rows_match_anthropic_list_prices() {
        let table = PricingTable::default();
        let opus55 = table.resolve("claude-opus-5-5").unwrap();
        assert_eq!(
            (
                opus55.input_price_per_million,
                opus55.output_price_per_million,
                opus55.cache_read_price_per_million
            ),
            (4.0, 20.0, Some(0.20))
        );
        let opus5 = table.resolve("claude-opus-5").unwrap();
        assert_eq!(opus5.input_price_per_million, 5.0, "Opus 5 走自身行");
        let fable = table.resolve("claude-fable-5-1").unwrap();
        assert_eq!(fable.cache_read_price_per_million, Some(0.25));
        let haiku = table.resolve("claude-haiku-5-5").unwrap();
        assert_eq!(haiku.input_price_per_million, 0.10);
        let dated = table.resolve("claude-opus-5-5-20261001").unwrap();
        assert_eq!(
            dated.input_price_per_million, 4.0,
            "带日期后缀取最具体基础型号"
        );
        for model in ["claude-opus-5-5", "claude-sonnet-5", "claude-haiku-4-5"] {
            let rule = table.resolve(model).unwrap();
            assert_eq!(rule.cache_write_multiplier, Some(1.25), "{model}");
            assert_eq!(rule.cache_write_1h_multiplier, Some(2.0), "{model}");
        }
        assert_eq!(
            table.resolve("gpt-5.4").unwrap().cache_write_multiplier,
            None
        );
    }

    /// C107: 缓存写入按 TTL 拆分计价 —— Anthropic 5 分钟 1.25×、1 小时 2× 输入单价;
    /// 未声明倍率的模型保持按输入单价计 (与改动前一致)。
    #[test]
    fn cache_writes_are_priced_by_ttl() {
        let table = PricingTable::default();
        let bucket = TokenBucket {
            input: 0,
            output: 0,
            cache_read: 0,
            cache_creation: 1_000_000,
            total: 1_000_000,
            cache_creation_1h: 600_000,
        };
        let opus = table.resolve("claude-opus-5-5").unwrap();
        // 400k × 1.25 × $4 + 600k × 2 × $4 = $2.0 + $4.8
        let cost = table.calculate_cost(&bucket, &opus);
        assert!((cost - 6.8).abs() < 1e-9, "cost = {cost}");

        let gpt = table.resolve("gpt-5.4").unwrap();
        let cost = table.calculate_cost(&bucket, &gpt);
        assert!(
            (cost - 2.5).abs() < 1e-9,
            "非 Anthropic 模型按输入单价: {cost}"
        );

        // 覆盖输入单价时倍率随之生效
        let mut overrides = HashMap::new();
        overrides.insert(
            "claude-opus-5-5".to_owned(),
            ModelPricingOverride {
                input_price_per_million: Some(10.0),
                ..ModelPricingOverride::default()
            },
        );
        let custom = PricingTable::new(overrides);
        let rule = custom.resolve("claude-opus-5-5").unwrap();
        let cost = custom.calculate_cost(&bucket, &rule);
        assert!((cost - 17.0).abs() < 1e-9, "cost = {cost}");
    }

    /// C108: 价卡目录可解析、键唯一 (大小写不敏感)、单价非负、展示字段齐备。
    #[test]
    fn catalog_is_well_formed() {
        let models = catalog();
        assert!(models.len() >= 90, "目录行数异常: {}", models.len());
        let mut keys = std::collections::BTreeSet::new();
        for entry in models {
            assert!(
                keys.insert(entry.model.to_lowercase()),
                "重复键 {}",
                entry.model
            );
            assert!(!entry.display_name.is_empty() && !entry.vendor.is_empty());
            assert!(entry.input >= 0.0 && entry.output >= 0.0);
            assert!(entry.cache_read.is_none_or(|price| price >= 0.0));
            if let Some((five_minutes, one_hour)) = entry.cache_write {
                assert!(
                    five_minutes >= 1.0 && one_hour >= five_minutes,
                    "{}",
                    entry.model
                );
            }
        }
        // 计费表与目录同源: 每一行都能按自身键解析回同一单价
        let table = PricingTable::default();
        for entry in models {
            let rule = table.resolve(&entry.model).expect("目录行必须可解析");
            assert_eq!(rule.input_price_per_million, entry.input, "{}", entry.model);
            assert_eq!(
                rule.output_price_per_million, entry.output,
                "{}",
                entry.model
            );
        }
    }
}
