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

        // StepFun
        add("step-3.7-flash", 0.20, 1.15, Some(0.03), "Step-3.7 Flash");
        add("step-5-preview", 1.00, 2.70, Some(0.05), "Step-5 Preview");

        // Tencent Hunyuan
        add("hy3", 0.15, 0.60, Some(0.015), "Tencent Hunyuan 3");
        add(
            "hy4-preview",
            0.85,
            2.55,
            Some(0.08),
            "Tencent Hunyuan 4 Preview",
        );

        // Anthropic Claude
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

        // Grok
        add("grok-3", 3.00, 15.00, Some(0.75), "Grok 3");
        add("grok-3-mini", 0.30, 1.50, Some(0.075), "Grok 3 Mini");

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
            .or_else(|| {
                self.overrides.iter().find_map(|(k, v)| {
                    if Self::model_matches(&normalized, k) {
                        Some(v)
                    } else {
                        None
                    }
                })
            });

        // 2. Direct or normalized match in builtin
        let matched_builtin = self
            .builtin
            .get(&normalized)
            .or_else(|| self.builtin.get(raw_model_name))
            .or_else(|| {
                self.builtin.iter().find_map(|(k, v)| {
                    if Self::model_matches(&normalized, k) {
                        Some(v)
                    } else {
                        None
                    }
                })
            });

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
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
