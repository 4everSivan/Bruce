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
    /// Sorted built-in catalog for application settings; rates share the collector source of truth.
    pub fn builtin_catalog(&self) -> std::collections::BTreeMap<String, ModelPricing> {
        self.builtin
            .iter()
            .map(|(name, price)| (name.clone(), price.clone()))
            .collect()
    }
    pub fn new(overrides: HashMap<String, ModelPricingOverride>) -> Self {
        let mut builtin = HashMap::new();

        let mut add = |name: &str, input: f64, output: f64, cache: Option<f64>, note: &str| {
            builtin.insert(
                name.to_lowercase(),
                ModelPricing {
                    input_price_per_million: input,
                    output_price_per_million: output,
                    cache_read_price_per_million: cache,
                    currency: "USD".to_string(),
                    note: Some(note.to_string()),
                },
            );
        };

        // Kimi
        add("k3-agent", 3.0, 15.0, Some(0.30), "Kimi K3 Agent");
        add("k3", 3.0, 15.0, Some(0.30), "Kimi K3");
        add("k3-256k", 3.0, 15.0, Some(0.30), "Kimi K3 256k");
        add("kimi-code", 3.0, 15.0, Some(0.30), "Kimi Code");
        add("kimi-for-coding", 3.0, 15.0, Some(0.30), "Kimi for Coding");

        // OpenAI / Codex
        add("gpt-6.1-sol", 4.50, 22.50, Some(0.45), "GPT-6.1 Sol");
        add("gpt-6-sol", 4.00, 20.00, Some(0.40), "GPT-6 Sol");
        add("gpt-6-luna", 0.25, 1.50, Some(0.025), "GPT-6 Luna");
        add("gpt-5.6-luna", 0.20, 1.20, Some(0.02), "GPT-5.6 Luna");
        add("gpt-5.6-sol", 4.00, 20.00, Some(0.40), "GPT-5.6 Sol");
        add("gpt-5.6-terra", 2.00, 12.00, Some(0.20), "GPT-5.6 Terra");
        add("gpt-5.4", 2.50, 15.00, Some(0.25), "GPT-5.4");
        add("gpt-5.4-mini", 0.15, 0.60, Some(0.015), "GPT-5.4 mini");
        add("gpt-5.2-codex", 1.75, 14.00, Some(0.175), "GPT-5.2 Codex");
        add(
            "codex-auto-review",
            1.75,
            14.00,
            Some(0.175),
            "Codex Auto Review",
        );
        add("gpt-4o", 2.50, 10.00, Some(1.25), "GPT-4o");
        add("gpt-4o-mini", 0.15, 0.60, Some(0.075), "GPT-4o mini");
        add("o1", 15.00, 60.00, Some(7.50), "OpenAI o1");
        add("o1-mini", 1.10, 4.40, Some(0.55), "OpenAI o1-mini");
        add("o3-mini", 1.10, 4.40, Some(0.55), "OpenAI o3-mini");

        // DeepSeek
        add(
            "deepseek-v4-flash",
            0.15,
            0.60,
            Some(0.003),
            "DeepSeek V4.1 Flash",
        );
        add(
            "deepseek-v4-pro",
            0.66,
            1.98,
            Some(0.022),
            "DeepSeek V4 Pro",
        );
        // C073: 官方 API 旧命名 (zcode 等直连 DeepSeek key 的历史 model_id),
        // 与 V4 Flash 同档; 不并入 v4.1 (ClinePass 档单价不同, 跨型号不归并)。
        add(
            "deepseek-flash",
            0.15,
            0.60,
            Some(0.003),
            "DeepSeek Flash (官方 API 旧命名)",
        );
        add("deepseek-r1", 0.55, 2.19, Some(0.14), "DeepSeek R1");
        add("deepseek-chat", 0.14, 0.28, Some(0.014), "DeepSeek Chat");
        add(
            "deepseek-reasoner",
            0.55,
            2.19,
            Some(0.14),
            "DeepSeek Reasoner",
        );

        // Zhipu GLM
        add("glm-5.3", 1.40, 4.40, Some(0.26), "GLM-5.3");
        add("glm-5.3-flash", 0.15, 0.50, Some(0.015), "GLM-5.3 Flash");
        add("glm-4-plus", 1.40, 1.40, Some(0.26), "GLM-4 Plus");
        add("glm-4-air", 0.14, 0.14, Some(0.014), "GLM-4 Air");
        add("glm-4-flash", 0.01, 0.01, Some(0.001), "GLM-4 Flash");
        add("glm-4-long", 0.14, 0.14, Some(0.014), "GLM-4 Long");
        add("codegeex-4", 0.14, 0.14, None, "CodeGeeX-4");

        // StepFun
        add("step-5-preview", 1.00, 2.70, Some(0.05), "Step-5 Preview");
        add("step-3.7-flash", 0.20, 1.15, Some(0.03), "Step-3.7 Flash");
        add("step-2-16k", 5.30, 10.00, Some(0.50), "Step-2 16k");
        add("step-1-8k", 0.70, 1.40, Some(0.07), "Step-1 8k");

        // Tencent Hunyuan
        add(
            "hy4-preview",
            0.85,
            2.55,
            Some(0.08),
            "Tencent Hunyuan 4 Preview",
        );
        add("hy3", 0.15, 0.60, Some(0.015), "Tencent Hunyuan 3");
        add("hy3-x", 0.25, 0.75, Some(0.025), "Hunyuan 3X");

        // Anthropic Claude
        add(
            "claude-opus-5-5",
            5.00,
            25.00,
            Some(0.50),
            "Claude Opus 5.5",
        );
        add(
            "claude-sonnet-5",
            2.00,
            10.00,
            Some(0.20),
            "Claude Sonnet 5",
        );
        add(
            "claude-haiku-4-5",
            1.00,
            5.00,
            Some(0.10),
            "Claude Haiku 4.5",
        );
        add(
            "claude-3-7-sonnet",
            3.00,
            15.00,
            Some(0.30),
            "Claude 3.7 Sonnet",
        );
        add(
            "claude-3-5-sonnet",
            3.00,
            15.00,
            Some(0.30),
            "Claude 3.5 Sonnet",
        );
        add(
            "claude-3-5-haiku",
            0.80,
            4.00,
            Some(0.08),
            "Claude 3.5 Haiku",
        );
        add("claude-3-opus", 15.00, 75.00, Some(1.50), "Claude 3 Opus");

        // Google Gemini
        add(
            "gemini-2.0-flash",
            0.10,
            0.40,
            Some(0.025),
            "Gemini 2.0 Flash",
        );
        add(
            "gemini-2.0-flash-thinking",
            0.10,
            0.40,
            Some(0.025),
            "Gemini 2.0 Flash Thinking",
        );
        add("gemini-2.0-pro", 1.25, 5.00, Some(0.30), "Gemini 2.0 Pro");
        add("gemini-1.5-pro", 1.25, 5.00, Some(0.3125), "Gemini 1.5 Pro");
        add(
            "gemini-1.5-flash",
            0.075,
            0.30,
            Some(0.01875),
            "Gemini 1.5 Flash",
        );

        // Grok
        add("grok-3", 3.00, 15.00, Some(0.75), "Grok 3");
        add("grok-3-mini", 0.30, 1.50, Some(0.075), "Grok 3 Mini");
        add("grok-2", 2.00, 10.00, Some(0.50), "Grok 2");

        // Alibaba Qwen
        add("qwen-max", 2.80, 8.40, Some(0.28), "Qwen Max");
        add("qwen-plus", 0.56, 1.68, Some(0.056), "Qwen Plus");
        add("qwen-turbo", 0.04, 0.12, Some(0.004), "Qwen Turbo");
        add(
            "qwen-2.5-coder-32b",
            0.20,
            0.60,
            Some(0.02),
            "Qwen 2.5 Coder 32B",
        );
        add(
            "qwen-2.5-coder-7b",
            0.05,
            0.15,
            Some(0.005),
            "Qwen 2.5 Coder 7B",
        );

        // ByteDance Doubao
        add("doubao-pro-128k", 0.70, 1.40, Some(0.07), "Doubao Pro 128k");
        add("doubao-pro-32k", 0.11, 0.28, Some(0.011), "Doubao Pro 32k");
        add(
            "doubao-lite-128k",
            0.04,
            0.14,
            Some(0.004),
            "Doubao Lite 128k",
        );
        add(
            "doubao-lite-32k",
            0.04,
            0.08,
            Some(0.004),
            "Doubao Lite 32k",
        );

        // MiniMax
        add("abab6.5s", 0.14, 0.28, Some(0.014), "MiniMax Abab 6.5s");

        // 01.AI (零一万物)
        add("yi-lightning", 0.14, 0.28, Some(0.014), "Yi Lightning");
        add("yi-large", 2.80, 2.80, Some(0.28), "Yi Large");

        // Baichuan (百川智能)
        add("baichuan-4", 1.40, 1.40, Some(0.14), "Baichuan 4");

        // TypeSafe Jev
        add("jev-1.13.0", 0.042, 0.0, None, "Jev 1.13.0");
        add("jev-1.13", 0.042, 0.0, None, "Jev 1.13");
        add("jev-latest", 0.042, 0.0, None, "Jev Latest");
        add("jev-preview", 0.042, 0.0, None, "Jev Preview");
        add("jev", 0.042, 0.0, None, "Jev");

        // Cline Pass (官方文档订阅参考价; 峰谷/超长上下文档位暂按标准档单值建卡)
        // 注: glm-5.3 / glm-5.3-flash 已由 Zhipu 区块建卡 (输入输出价一致), 此处不重复覆盖.
        add("kimi-k3", 3.00, 15.00, Some(0.30), "Kimi K3 (ClinePass)");
        add(
            "deepseek-v4.1-flash",
            0.30,
            1.20,
            Some(0.006),
            "DeepSeek V4.1 Flash (ClinePass)",
        );
        add(
            "mimo-v2.5",
            0.14,
            0.28,
            Some(0.0028),
            "MiMo V2.5 (ClinePass)",
        );
        add(
            "mimo-v2.5-pro",
            1.74,
            3.48,
            Some(0.0145),
            "MiMo V2.5 Pro (ClinePass)",
        );
        add(
            "minimax-m3",
            0.30,
            1.20,
            Some(0.06),
            "MiniMax M3 (ClinePass)",
        );
        add(
            "muse-spark-1.3-contributor",
            0.10,
            0.20,
            Some(0.002),
            "Muse Spark 1.3 Contributor (ClinePass)",
        );
        add(
            "qwen3.8-max",
            2.00,
            6.00,
            Some(0.25),
            "Qwen3.8 Max (ClinePass)",
        );
        add(
            "qwen3.7-max",
            2.50,
            7.50,
            Some(0.50),
            "Qwen3.7 Max (ClinePass)",
        );
        add(
            "qwen3.7-plus",
            0.40,
            1.60,
            Some(0.04),
            "Qwen3.7 Plus (ClinePass)",
        );

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
        let cache_creation_cost =
            (bucket.cache_creation as f64) * pricing.input_price_per_million / 1_000_000.0;
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
}
