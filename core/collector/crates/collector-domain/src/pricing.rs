#![deny(unsafe_code)]

use crate::TokenBucket;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::OnceLock;

/// 峰谷价中的峰值档 (TD-002): 窗口按 UTC 分钟表示, `[start, end)` 且允许跨零点。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PeakPricing {
    pub input: f64,
    pub output: f64,
    #[serde(default)]
    pub cache_read: Option<f64>,
    pub start_minute_utc: u32,
    pub end_minute_utc: u32,
}

/// 长上下文分档 (TD-002): 单请求 input 超过 `threshold` 时套用该档费率。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LongContextPricing {
    pub threshold: u64,
    pub input: f64,
    pub output: f64,
    #[serde(default)]
    pub cache_read: Option<f64>,
}

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
    /// 峰值档 (TD-002); 基础单价保持非峰值档。
    #[serde(default)]
    pub peak: Option<PeakPricing>,
    /// 长上下文档 (TD-002); 基础单价保持 ≤ threshold 档。
    #[serde(default)]
    pub long_context: Option<LongContextPricing>,
}

/// 内置价卡目录行 (C108, T19)。唯一事实源为仓库顶层 `config/pricing-catalog.json`:
/// 采集端计费、Windows 设置页 / 工作台与 mac 设置页 (由 `scripts/gen-pricing-catalog.mjs`
/// 生成) 均派生自同一份数据, 不再各自维护价卡副本。单位为美元 / 百万 token。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
    /// 峰值档 (TD-002); 缺省表示单一费率。
    #[serde(default)]
    pub peak: Option<PeakPricing>,
    /// 长上下文档 (TD-002); 缺省表示不按单请求长度分档。
    #[serde(default)]
    pub long_context: Option<LongContextPricing>,
}

fn listed_by_default() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CatalogFile {
    #[serde(default)]
    pub schema_version: u32,
    #[serde(default)]
    pub updated_at: String,
    pub models: Vec<CatalogModel>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CatalogValidationError {
    Json(String),
    UnsupportedSchemaVersion(u32),
    InvalidUpdatedAt(String),
    InvalidModelCount,
    InvalidModel(String),
    DuplicateModel(String),
}

impl std::fmt::Display for CatalogValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Json(msg) => write!(f, "JSON 格式无效: {msg}"),
            Self::UnsupportedSchemaVersion(v) => write!(f, "不支持的 schemaVersion: {v} (期望 1)"),
            Self::InvalidUpdatedAt(s) => write!(f, "updatedAt 格式无效: {s}"),
            Self::InvalidModelCount => write!(f, "模型列表为空或超出上限 (上限 2000)"),
            Self::InvalidModel(msg) => write!(f, "模型定义无效: {msg}"),
            Self::DuplicateModel(k) => write!(f, "存在重复模型键: {k}"),
        }
    }
}

impl std::error::Error for CatalogValidationError {}

pub fn is_valid_updated_at(s: &str) -> bool {
    let (date_part, rev_part) = match s.split_once('.') {
        Some((d, r)) => (d, Some(r)),
        None => (s, None),
    };
    let parts: Vec<&str> = date_part.split('-').collect();
    if parts.len() != 3 {
        return false;
    }
    if parts[0].len() != 4 || !parts[0].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if parts[1].len() != 2 || !parts[1].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if parts[2].len() != 2 || !parts[2].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    if let Some(r) = rev_part {
        if r.is_empty() || !r.chars().all(|c| c.is_ascii_digit()) {
            return false;
        }
    }
    true
}

fn parse_updated_at(s: &str) -> Option<(&str, u32)> {
    if !is_valid_updated_at(s) {
        return None;
    }
    match s.split_once('.') {
        Some((d, r)) => Some((d, r.parse::<u32>().ok()?)),
        None => Some((s, 0)),
    }
}

pub fn compare_updated_at(a: &str, b: &str) -> std::cmp::Ordering {
    match (parse_updated_at(a), parse_updated_at(b)) {
        (Some((d1, r1)), Some((d2, r2))) => d1.cmp(d2).then_with(|| r1.cmp(&r2)),
        _ => a.cmp(b),
    }
}

impl CatalogFile {
    pub fn parse_and_validate(bytes: &[u8]) -> Result<Self, CatalogValidationError> {
        let raw_str =
            std::str::from_utf8(bytes).map_err(|e| CatalogValidationError::Json(e.to_string()))?;
        let file: CatalogFile = serde_json::from_str(raw_str)
            .map_err(|e| CatalogValidationError::Json(e.to_string()))?;
        file.validate()?;
        Ok(file)
    }

    pub fn validate(&self) -> Result<(), CatalogValidationError> {
        if self.schema_version != 1 {
            return Err(CatalogValidationError::UnsupportedSchemaVersion(
                self.schema_version,
            ));
        }
        if !is_valid_updated_at(&self.updated_at) {
            return Err(CatalogValidationError::InvalidUpdatedAt(
                self.updated_at.clone(),
            ));
        }
        if self.models.is_empty() || self.models.len() > 2000 {
            return Err(CatalogValidationError::InvalidModelCount);
        }
        let mut seen_keys = std::collections::HashSet::with_capacity(self.models.len());
        for (idx, entry) in self.models.iter().enumerate() {
            let model_key = entry.model.trim();
            if model_key.is_empty() {
                return Err(CatalogValidationError::InvalidModel(format!(
                    "第 {idx} 条 model 键为空"
                )));
            }
            if entry.display_name.trim().is_empty() {
                return Err(CatalogValidationError::InvalidModel(format!(
                    "模型 {model_key} displayName 为空"
                )));
            }
            if entry.vendor.trim().is_empty() {
                return Err(CatalogValidationError::InvalidModel(format!(
                    "模型 {model_key} vendor 为空"
                )));
            }
            let lower_key = model_key.to_lowercase();
            if !seen_keys.insert(lower_key) {
                return Err(CatalogValidationError::DuplicateModel(entry.model.clone()));
            }
            if !entry.input.is_finite() || entry.input < 0.0 {
                return Err(CatalogValidationError::InvalidModel(format!(
                    "模型 {model_key} input 价格无效: {}",
                    entry.input
                )));
            }
            if !entry.output.is_finite() || entry.output < 0.0 {
                return Err(CatalogValidationError::InvalidModel(format!(
                    "模型 {model_key} output 价格无效: {}",
                    entry.output
                )));
            }
            if let Some(cache_read) = entry.cache_read {
                if !cache_read.is_finite() || cache_read < 0.0 {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} cacheRead 价格无效: {cache_read}"
                    )));
                }
            }
            if let Some((five_min, one_hour)) = entry.cache_write {
                if !five_min.is_finite()
                    || five_min <= 0.0
                    || !one_hour.is_finite()
                    || one_hour <= 0.0
                {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} cacheWrite 倍率必须有限且大于 0"
                    )));
                }
            }
            if let Some(peak) = &entry.peak {
                if !peak.input.is_finite()
                    || peak.input < 0.0
                    || !peak.output.is_finite()
                    || peak.output < 0.0
                {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} peak 单价必须有限非负"
                    )));
                }
                if let Some(cr) = peak.cache_read {
                    if !cr.is_finite() || cr < 0.0 {
                        return Err(CatalogValidationError::InvalidModel(format!(
                            "模型 {model_key} peak cacheRead 必须有限非负"
                        )));
                    }
                }
                if peak.start_minute_utc >= 1440
                    || peak.end_minute_utc > 1440
                    || peak.start_minute_utc == peak.end_minute_utc
                {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} peak 时间窗口无效"
                    )));
                }
            }
            if let Some(long) = &entry.long_context {
                if !long.input.is_finite()
                    || long.input < 0.0
                    || !long.output.is_finite()
                    || long.output < 0.0
                {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} longContext 单价必须有限非负"
                    )));
                }
                if let Some(cr) = long.cache_read {
                    if !cr.is_finite() || cr < 0.0 {
                        return Err(CatalogValidationError::InvalidModel(format!(
                            "模型 {model_key} longContext cacheRead 必须有限非负"
                        )));
                    }
                }
                if long.threshold == 0 {
                    return Err(CatalogValidationError::InvalidModel(format!(
                        "模型 {model_key} longContext threshold 必须大于 0"
                    )));
                }
            }
        }
        Ok(())
    }

    /// 比较两个价格表的 updatedAt 版本。
    pub fn compare_version(&self, other_updated_at: &str) -> std::cmp::Ordering {
        compare_updated_at(&self.updated_at, other_updated_at)
    }

    /// 判断当前价格表是否落后于指定基线版本 (用于防倒退 Anti-Rollback)。
    pub fn is_older_than(&self, base_updated_at: &str) -> bool {
        self.compare_version(base_updated_at).is_lt()
    }
}

static BUILTIN_CATALOG_FILE: OnceLock<CatalogFile> = OnceLock::new();

pub fn builtin_catalog_file() -> &'static CatalogFile {
    BUILTIN_CATALOG_FILE.get_or_init(|| {
        serde_json::from_str::<CatalogFile>(include_str!(
            "../../../../../config/pricing-catalog.json"
        ))
        .expect("config/pricing-catalog.json 由 catalog_is_well_formed 用例保证可解析")
    })
}

pub fn builtin_catalog() -> &'static [CatalogModel] {
    &builtin_catalog_file().models
}

pub fn builtin_updated_at() -> &'static str {
    &builtin_catalog_file().updated_at
}

pub fn builtin_schema_version() -> u32 {
    builtin_catalog_file().schema_version
}

/// 全部内置价卡行, 顺序即设置页展示顺序 (C108, T19)。
pub fn catalog() -> &'static [CatalogModel] {
    builtin_catalog()
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
        Self::with_catalog(builtin_catalog(), overrides)
    }

    pub fn with_catalog(
        models: &[CatalogModel],
        overrides: HashMap<String, ModelPricingOverride>,
    ) -> Self {
        let builtin = models
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
                        peak: entry.peak.clone(),
                        long_context: entry.long_context.clone(),
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
                peak: builtin.peak.clone(),
                long_context: builtin.long_context.clone(),
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
                        peak: None,
                        long_context: None,
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
    ///
    /// TD-002: 桶内的 `rate_splits` 是总量的子集; 先把份额从基础桶扣除, 再按各类别
    /// 费率计费, 避免重复计价。无分档价卡的模型 `rate_splits` 为空, 行为与旧版一致。
    pub fn calculate_cost(&self, bucket: &TokenBucket, pricing: &ModelPricing) -> f64 {
        let five_minute_multiplier = pricing.cache_write_multiplier.unwrap_or(1.0);
        let one_hour_multiplier = pricing
            .cache_write_1h_multiplier
            .unwrap_or(five_minute_multiplier);
        let mut base = Counts::from_bucket(bucket);
        for tally in bucket.rate_splits.values() {
            base.subtract(tally);
        }
        let mut total = cost_for_counts(
            &base,
            rate_card(pricing, None),
            five_minute_multiplier,
            one_hour_multiplier,
        );
        for (class, tally) in &bucket.rate_splits {
            total += cost_for_counts(
                &Counts::from_tally(tally),
                rate_card(pricing, Some(class)),
                five_minute_multiplier,
                one_hour_multiplier,
            );
        }
        total
    }

    /// 缓存读取相对按输入单价计费节省的 USD (C070):
    /// cacheRead × (输入单价 − 缓存读取单价); 缓存读取单价缺省时与 `calculate_cost` 同取输入 10%。
    pub fn calculate_cache_savings(&self, bucket: &TokenBucket, pricing: &ModelPricing) -> f64 {
        let mut base = Counts::from_bucket(bucket);
        for tally in bucket.rate_splits.values() {
            base.subtract(tally);
        }
        let mut total = savings_for_counts(&base, rate_card(pricing, None));
        for (class, tally) in &bucket.rate_splits {
            total +=
                savings_for_counts(&Counts::from_tally(tally), rate_card(pricing, Some(class)));
        }
        total
    }
}

/// TD-002: 单条计价类别 (峰/长上下文) 的费率视图。
#[derive(Clone, Copy)]
struct RateCard {
    input: f64,
    output: f64,
    cache_read: Option<f64>,
}

fn rate_card(pricing: &ModelPricing, class: Option<&str>) -> RateCard {
    let base = RateCard {
        input: pricing.input_price_per_million,
        output: pricing.output_price_per_million,
        cache_read: pricing.cache_read_price_per_million,
    };
    match class {
        Some("peak") => pricing
            .peak
            .as_ref()
            .map(|tier| RateCard {
                input: tier.input,
                output: tier.output,
                cache_read: tier.cache_read,
            })
            .unwrap_or(base),
        Some("long") => pricing
            .long_context
            .as_ref()
            .map(|tier| RateCard {
                input: tier.input,
                output: tier.output,
                cache_read: tier.cache_read,
            })
            .unwrap_or(base),
        Some("peak_long") => {
            let peak = rate_card(pricing, Some("peak"));
            let long = rate_card(pricing, Some("long"));
            if peak.input == base.input && long.input == base.input {
                base
            } else {
                // 同时命中峰时与长上下文时取两者较高费率, 避免低估。
                RateCard {
                    input: peak.input.max(long.input),
                    output: peak.output.max(long.output),
                    cache_read: match (peak.cache_read, long.cache_read) {
                        (Some(a), Some(b)) => Some(a.max(b)),
                        (Some(a), None) => Some(a),
                        (None, Some(b)) => Some(b),
                        (None, None) => None,
                    },
                }
            }
        }
        _ => base,
    }
}

#[derive(Clone, Copy, Default)]
struct Counts {
    input: u64,
    output: u64,
    cache_read: u64,
    cache_creation: u64,
    cache_creation_1h: u64,
}

impl Counts {
    fn from_bucket(bucket: &TokenBucket) -> Self {
        Self {
            input: bucket.input,
            output: bucket.output,
            cache_read: bucket.cache_read,
            cache_creation: bucket.cache_creation,
            cache_creation_1h: bucket.cache_creation_1h,
        }
    }

    fn from_tally(tally: &crate::TokenTally) -> Self {
        Self {
            input: tally.input,
            output: tally.output,
            cache_read: tally.cache_read,
            cache_creation: tally.cache_creation,
            cache_creation_1h: tally.cache_creation_1h,
        }
    }

    fn subtract(&mut self, tally: &crate::TokenTally) {
        self.input = self.input.saturating_sub(tally.input);
        self.output = self.output.saturating_sub(tally.output);
        self.cache_read = self.cache_read.saturating_sub(tally.cache_read);
        self.cache_creation = self.cache_creation.saturating_sub(tally.cache_creation);
        self.cache_creation_1h = self
            .cache_creation_1h
            .saturating_sub(tally.cache_creation_1h);
    }
}

fn cost_for_counts(
    counts: &Counts,
    rates: RateCard,
    five_minute_multiplier: f64,
    one_hour_multiplier: f64,
) -> f64 {
    let input_cost = (counts.input as f64) * rates.input / 1_000_000.0;
    let output_cost = (counts.output as f64) * rates.output / 1_000_000.0;
    let cache_rate = rates.cache_read.unwrap_or(rates.input * 0.1);
    let cache_read_cost = (counts.cache_read as f64) * cache_rate / 1_000_000.0;
    // C107: 缓存写入按 TTL 拆分计价; 倍率缺省 1.0 (非 Anthropic 模型沿用输入单价)。
    let one_hour = counts.cache_creation_1h.min(counts.cache_creation);
    let five_minutes = counts.cache_creation - one_hour;
    let cache_creation_cost = ((five_minutes as f64) * five_minute_multiplier
        + (one_hour as f64) * one_hour_multiplier)
        * rates.input
        / 1_000_000.0;
    input_cost + output_cost + cache_read_cost + cache_creation_cost
}

fn savings_for_counts(counts: &Counts, rates: RateCard) -> f64 {
    let cache_rate = rates.cache_read.unwrap_or(rates.input * 0.1);
    let saved_rate = (rates.input - cache_rate).max(0.0);
    (counts.cache_read as f64) * saved_rate / 1_000_000.0
}

/// TD-002: 按模型价卡的时间窗与单请求长度对样本分类。
/// 返回 `None` 表示样本落在基础档 (非峰值 / ≤ 阈值), 也是无分档价卡模型的唯一结果。
pub fn rate_class_for(
    model: &str,
    timestamp_millis: i64,
    input_tokens: u64,
) -> Option<&'static str> {
    let normalized = PricingTable::normalize_model_name(model);
    let (_, peak, long_context) = tiered_rules()
        .iter()
        .find(|(key, _, _)| normalized == *key || normalized.starts_with(key.as_str()))?;
    let peak = peak.as_ref().is_some_and(|peak| {
        let minute = ((timestamp_millis.rem_euclid(86_400_000)) / 60_000) as u32;
        if peak.start_minute_utc <= peak.end_minute_utc {
            minute >= peak.start_minute_utc && minute < peak.end_minute_utc
        } else {
            minute >= peak.start_minute_utc || minute < peak.end_minute_utc
        }
    });
    let long = long_context
        .as_ref()
        .is_some_and(|tier| input_tokens > tier.threshold);
    match (peak, long) {
        (true, true) => Some("peak_long"),
        (true, false) => Some("peak"),
        (false, true) => Some("long"),
        (false, false) => None,
    }
}

/// 只有声明了峰值或长上下文档的价卡行才参与逐样本分类; 缓存一次避免热路径
/// 每条样本都遍历完整目录。
type TieredRule = (String, Option<PeakPricing>, Option<LongContextPricing>);

fn tiered_rules() -> &'static [TieredRule] {
    static RULES: OnceLock<Vec<TieredRule>> = OnceLock::new();
    RULES.get_or_init(|| {
        catalog()
            .iter()
            .filter(|entry| entry.peak.is_some() || entry.long_context.is_some())
            .map(|entry| {
                (
                    PricingTable::normalize_model_name(&entry.model),
                    entry.peak.clone(),
                    entry.long_context.clone(),
                )
            })
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

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
            ..Default::default()
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
            ..Default::default()
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

    /// C108, T19: 价卡目录可解析、键唯一 (大小写不敏感)、单价非负、展示字段齐备。
    #[test]
    fn catalog_is_well_formed() {
        let file = builtin_catalog_file();
        assert_eq!(file.schema_version, 1);
        assert!(is_valid_updated_at(&file.updated_at));
        assert!(file.validate().is_ok());

        let models = builtin_catalog();
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

        // C169: 锁定 GPT-6.1 系列模型官方基准单价与缓存读取
        let sol = table
            .resolve("gpt-6.1-sol")
            .expect("gpt-6.1-sol 必须可解析");
        assert_eq!(sol.input_price_per_million, 2.0);
        assert_eq!(sol.output_price_per_million, 10.0);
        assert_eq!(sol.cache_read_price_per_million, Some(0.1));

        let terra = table
            .resolve("gpt-6.1-terra")
            .expect("gpt-6.1-terra 必须可解析");
        assert_eq!(terra.input_price_per_million, 1.0);
        assert_eq!(terra.output_price_per_million, 5.0);
        assert_eq!(terra.cache_read_price_per_million, Some(0.05));

        let luna = table
            .resolve("gpt-6.1-luna")
            .expect("gpt-6.1-luna 必须可解析");
        assert_eq!(luna.input_price_per_million, 0.1);
        assert_eq!(luna.output_price_per_million, 0.5);
        assert_eq!(luna.cache_read_price_per_million, Some(0.01));
    }

    #[test]
    fn parse_and_validate_rejects_malformed_catalogs() {
        // Bad schemaVersion
        let bad_schema = br#"{"schemaVersion": 2, "updatedAt": "2026-10-31", "models": [{"model":"m1","displayName":"M1","vendor":"V1","input":1.0,"output":2.0,"note":"n"}]}"#;
        assert!(matches!(
            CatalogFile::parse_and_validate(bad_schema),
            Err(CatalogValidationError::UnsupportedSchemaVersion(2))
        ));

        // Bad updatedAt
        let bad_date = br#"{"schemaVersion": 1, "updatedAt": "invalid-date", "models": [{"model":"m1","displayName":"M1","vendor":"V1","input":1.0,"output":2.0,"note":"n"}]}"#;
        assert!(matches!(
            CatalogFile::parse_and_validate(bad_date),
            Err(CatalogValidationError::InvalidUpdatedAt(_))
        ));

        // Empty models
        let empty_models = br#"{"schemaVersion": 1, "updatedAt": "2026-10-31", "models": []}"#;
        assert!(matches!(
            CatalogFile::parse_and_validate(empty_models),
            Err(CatalogValidationError::InvalidModelCount)
        ));

        // Duplicate model
        let dup = br#"{"schemaVersion": 1, "updatedAt": "2026-10-31", "models": [
            {"model":"m1","displayName":"M1","vendor":"V1","input":1.0,"output":2.0,"note":"n"},
            {"model":"M1","displayName":"M1 dup","vendor":"V1","input":1.0,"output":2.0,"note":"n"}
        ]}"#;
        assert!(matches!(
            CatalogFile::parse_and_validate(dup),
            Err(CatalogValidationError::DuplicateModel(_))
        ));

        // Negative price
        let neg = br#"{"schemaVersion": 1, "updatedAt": "2026-10-31", "models": [
            {"model":"m1","displayName":"M1","vendor":"V1","input":-1.0,"output":2.0,"note":"n"}
        ]}"#;
        assert!(matches!(
            CatalogFile::parse_and_validate(neg),
            Err(CatalogValidationError::InvalidModel(_))
        ));

        // Non-finite price
        let nan = br#"{"schemaVersion": 1, "updatedAt": "2026-10-31", "models": [
            {"model":"m1","displayName":"M1","vendor":"V1","input":1.0,"output":null,"note":"n"}
        ]}"#;
        assert!(CatalogFile::parse_and_validate(nan).is_err());
    }

    #[test]
    fn anti_rollback_version_comparison() {
        assert_eq!(
            compare_updated_at("2026-10-31", "2026-10-31"),
            std::cmp::Ordering::Equal
        );
        assert_eq!(
            compare_updated_at("2026-10-30", "2026-10-31"),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            compare_updated_at("2026-11-01", "2026-10-31"),
            std::cmp::Ordering::Greater
        );
        assert_eq!(
            compare_updated_at("2026-10-31", "2026-10-31.1"),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            compare_updated_at("2026-10-31.2", "2026-10-31.10"),
            std::cmp::Ordering::Less
        );

        let file = CatalogFile {
            schema_version: 1,
            updated_at: "2026-10-30".to_string(),
            models: vec![],
        };
        assert!(file.is_older_than("2026-10-31"));
        assert!(!file.is_older_than("2026-10-30"));
        assert!(!file.is_older_than("2026-10-29"));
    }

    #[test]
    fn pricing_table_with_catalog_and_overrides_priority() {
        let custom_catalog = vec![
            CatalogModel {
                model: "dynamic-model-x".to_string(),
                display_name: "Dynamic Model X".to_string(),
                vendor: "Dynamic".to_string(),
                input: 5.0,
                output: 25.0,
                cache_read: Some(0.5),
                cache_write: None,
                note: "Synced".to_string(),
                listed: true,
                peak: None,
                long_context: None,
            },
            CatalogModel {
                model: "k3-agent".to_string(),
                display_name: "K3 Dynamic".to_string(),
                vendor: "Moonshot Kimi".to_string(),
                input: 2.0, // altered from 3.0
                output: 10.0,
                cache_read: None,
                cache_write: None,
                note: "Synced K3".to_string(),
                listed: true,
                peak: None,
                long_context: None,
            },
        ];

        let mut overrides = HashMap::new();
        overrides.insert(
            "k3-agent".to_string(),
            ModelPricingOverride {
                input_price_per_million: Some(1.23), // User override takes precedence
                ..Default::default()
            },
        );

        let table = PricingTable::with_catalog(&custom_catalog, overrides);

        // 1. Dynamic model resolves
        let dynamic_rule = table
            .resolve("dynamic-model-x")
            .expect("dynamic model should exist");
        assert_eq!(dynamic_rule.input_price_per_million, 5.0);

        // 2. Overrides have higher priority than dynamic catalog
        let k3_rule = table.resolve("k3-agent").expect("k3-agent should exist");
        assert_eq!(k3_rule.input_price_per_million, 1.23); // override
        assert_eq!(k3_rule.output_price_per_million, 10.0); // from dynamic catalog

        // 3. Model not in dynamic catalog does not exist
        assert!(table.resolve("non-existent-model").is_none());
    }

    fn utc_millis(value: &str) -> i64 {
        chrono::DateTime::parse_from_rfc3339(value)
            .unwrap()
            .timestamp_millis()
    }

    /// TD-002: DeepSeek V4 Pro 基础档为非峰值价, 峰值样本进入 `peak` 份额并按
    /// $1.32/$3.96 计费; 份额从总量扣除, 不得重复计价。
    #[test]
    fn deepseek_peak_and_off_peak_are_priced_separately() {
        let table = PricingTable::default();
        let rule = table.resolve("deepseek-v4-pro").unwrap();
        assert_eq!(rule.input_price_per_million, 0.66);
        assert_eq!(rule.output_price_per_million, 1.98);
        assert_eq!(
            rule.peak.as_ref().map(|peak| (peak.input, peak.output)),
            Some((1.32, 3.96))
        );

        let peak = rate_class_for("deepseek-v4-pro", utc_millis("2026-08-21T08:00:00Z"), 1_000);
        let off_peak = rate_class_for("deepseek-v4-pro", utc_millis("2026-08-21T20:00:00Z"), 1_000);
        assert_eq!(peak, Some("peak"));
        assert_eq!(off_peak, None);

        let bucket = TokenBucket {
            input: 2_000_000,
            output: 2_000_000,
            total: 4_000_000,
            rate_splits: BTreeMap::from([(
                "peak".to_owned(),
                crate::TokenTally {
                    input: 1_000_000,
                    output: 1_000_000,
                    ..Default::default()
                },
            )]),
            ..Default::default()
        };
        // 非峰值 1M: 0.66 + 1.98; 峰值 1M: 1.32 + 3.96
        let cost = table.calculate_cost(&bucket, &rule);
        assert!((cost - 7.92).abs() < 1e-9, "cost = {cost}");
    }

    /// TD-002: Qwen3.7 Plus 仅在单请求 input > 256000 时进入 `long` 档。
    #[test]
    fn qwen_long_context_tier_uses_per_request_input() {
        let table = PricingTable::default();
        let rule = table.resolve("cline-pass/qwen3.7-plus").unwrap();
        assert_eq!(rule.input_price_per_million, 0.40);
        assert_eq!(
            rule.long_context
                .as_ref()
                .map(|tier| (tier.threshold, tier.input, tier.output)),
            Some((256_000, 1.20, 4.80))
        );
        let ts = utc_millis("2026-08-21T08:00:00Z");
        assert_eq!(rate_class_for("qwen3.7-plus", ts, 256_000), None);
        assert_eq!(
            rate_class_for("cline-pass/qwen3.7-plus", ts, 256_001),
            Some("long")
        );

        let bucket = TokenBucket {
            input: 2_000_000,
            output: 2_000_000,
            total: 4_000_000,
            rate_splits: BTreeMap::from([(
                "long".to_owned(),
                crate::TokenTally {
                    input: 1_000_000,
                    output: 1_000_000,
                    ..Default::default()
                },
            )]),
            ..Default::default()
        };
        // 短上下文 1M: 0.40 + 1.60; 长上下文 1M: 1.20 + 4.80
        let cost = table.calculate_cost(&bucket, &rule);
        assert!((cost - 8.0).abs() < 1e-9, "cost = {cost}");
    }

    /// TD-002: 峰值窗口按 UTC `[00:30, 16:30)` 判定, 边界分钟不越界。
    #[test]
    fn rate_class_windows_cover_utc_boundaries() {
        let cases = [
            ("2026-08-21T00:00:00Z", None),
            ("2026-08-21T00:29:00Z", None),
            ("2026-08-21T00:30:00Z", Some("peak")),
            ("2026-08-21T16:29:00Z", Some("peak")),
            ("2026-08-21T16:30:00Z", None),
            ("2026-08-21T23:59:00Z", None),
        ];
        for (timestamp, expected) in cases {
            assert_eq!(
                rate_class_for("deepseek-v4-pro", utc_millis(timestamp), 1),
                expected,
                "{timestamp}"
            );
        }
    }
}
