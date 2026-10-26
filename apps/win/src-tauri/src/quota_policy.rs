//! 订阅额度 per-provider 门禁与 429 冷却 (C077, 对齐 mac `QuotaRefreshPolicy` +
//! `QuotaCarryOverMerger`)。
//!
//! 纯逻辑: 只读上一份 artifact 的 service 时间戳, 不触碰网络/存储。
//! - 新鲜度门禁: provider 的 `quotaAttemptedAt` (回退 `capturedAt`) 距今不足刷新间隔时
//!   跳过额度查询 (不再每轮无条件全量查询);
//! - 429 冷却: service 带 `rateLimitedAt` 且距今不足 30 分钟时跳过 (partial, 仅该
//!   provider; 其余 provider 照常查询);
//! - 手动刷新绕过新鲜度与冷却 (bypassCooldown);
//! - Codex 永不进入 skip (其四源合并/重试链路需要完整首轮结果);
//! - 被跳过的 provider 由 `carry_over_skipped` 用上一份 service 原样回填并标 stale,
//!   冷却/失败/过期不丢旧值。

use std::collections::{BTreeMap, BTreeSet};

use chrono::{SecondsFormat, TimeZone, Utc};
use serde_json::{json, Value};

/// 自动额度查询的 429 冷却 (秒, 对齐 mac `rateLimitCooldown`)。
pub const RATE_LIMIT_COOLDOWN_SECS: i64 = 30 * 60;

/// 单轮刷新对外部额度查询的决策。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuotaRunPolicy {
    /// 是否发起任何外部额度查询 (false = 本地专用 run, 回填全部旧 service)。
    pub include_external_quotas: bool,
    /// 本轮跳过的 provider (额度仍新鲜或处于 429 冷却)。
    pub skip_providers: BTreeSet<String>,
    /// 跳过原因是 429 冷却的 provider (回填时强制标 stale)。
    pub rate_limited_providers: BTreeSet<String>,
}

impl QuotaRunPolicy {
    /// 查询全部 provider (无门禁)。
    pub fn include_all() -> Self {
        Self {
            include_external_quotas: true,
            skip_providers: BTreeSet::new(),
            rate_limited_providers: BTreeSet::new(),
        }
    }

    /// 本地专用 run: 不查询任何 provider, 回填全部旧 service。
    pub fn local_only() -> Self {
        Self {
            include_external_quotas: false,
            skip_providers: BTreeSet::new(),
            rate_limited_providers: BTreeSet::new(),
        }
    }

    pub fn is_skipped(&self, provider: &str) -> bool {
        self.skip_providers.contains(provider)
    }
}

/// 时间戳 (毫秒) → RFC 3339 秒级 UTC 字符串 (与 artifact `capturedAt` 同格式)。
pub fn timestamp_iso(now_ms: i64) -> String {
    Utc.timestamp_millis_opt(now_ms)
        .single()
        .map(|dt| dt.to_rfc3339_opts(SecondsFormat::Secs, true))
        .unwrap_or_default()
}

/// 解析 service 的时间戳字段 (RFC 3339 / epoch 秒 / epoch 毫秒) 为毫秒。
pub fn parse_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => chrono::DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|dt| dt.timestamp_millis()),
        Value::Number(number) => number.as_i64().map(|raw| {
            // 数值 > 1e12 视为毫秒, 否则视为秒 (对齐 mac isExpired 口径)。
            if raw > 1_000_000_000_000 {
                raw
            } else {
                raw * 1000
            }
        }),
        _ => None,
    }
}

pub fn captured_at(service: &Value) -> Option<i64> {
    parse_ms(service.get("capturedAt"))
}

pub fn rate_limited_at(service: &Value) -> Option<i64> {
    parse_ms(service.get("rateLimitedAt"))
}

/// 最近一次真实额度尝试: `quotaAttemptedAt` 优先, 回退 `capturedAt`, 失败 service
/// 再回退 `rateLimitedAt` (对齐 mac `attemptAt`)。
pub fn attempt_at(service: &Value) -> Option<i64> {
    if let Some(value) = parse_ms(service.get("quotaAttemptedAt")) {
        return Some(value);
    }
    if let Some(value) = captured_at(service) {
        return Some(value);
    }
    let status = service.get("status").and_then(Value::as_str).unwrap_or("");
    if matches!(status, "error" | "partial" | "unavailable") {
        return rate_limited_at(service);
    }
    None
}

/// 限流文案识别 (对齐 mac `isRateLimitedNote`)。
pub fn is_rate_limited_note(note: &str) -> bool {
    note.contains("429") || note.contains("限流") || note.contains("RATE_LIMIT")
}

/// 服务是否因限流失败 (C118, mac `QuotaRefreshPolicy.isRateLimited` 同义): collector 下发
/// `failureKind` 时以其为准 (包括显式 null), 旧 artifact 无该字段时回退匹配 note 文案。
pub fn is_rate_limited(service: &Value) -> bool {
    match service.get("failureKind") {
        Some(kind) => kind.as_str() == Some("rateLimit"),
        None => is_rate_limited_note(service.get("note").and_then(Value::as_str).unwrap_or("")),
    }
}

/// 本轮发出过 429 的 provider (status error/partial + 限流文案)。
pub fn rate_limited_providers_in(artifact: Option<&Value>) -> BTreeSet<String> {
    let mut result = BTreeSet::new();
    for service in artifact
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let status = service.get("status").and_then(Value::as_str).unwrap_or("");
        if !matches!(status, "error" | "partial") {
            continue;
        }
        if is_rate_limited(service) {
            result.insert(crate::runtime_core::provider_id(service).to_owned());
        }
    }
    result
}

fn is_cooling(services: &[&Value], now_ms: i64, cooldown_secs: i64) -> bool {
    services
        .iter()
        .filter_map(|service| rate_limited_at(service))
        .max()
        .is_some_and(|limited| now_ms - limited < cooldown_secs * 1000)
}

/// 上次快照之后是否有窗口 `resetsAt` 已过去 (epoch 秒, 对齐 mac `hasPassedBoundary`)。
fn has_passed_boundary(services: &[&Value], now_ms: i64) -> bool {
    let now_epoch = now_ms / 1000;
    for service in services {
        if service.get("kind").and_then(Value::as_str) != Some("windows") {
            continue;
        }
        let Some(captured) = captured_at(service) else {
            continue;
        };
        let captured_epoch = captured / 1000;
        for window in service
            .get("windows")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            if let Some(reset) = window.get("resetsAt").and_then(Value::as_i64) {
                if reset <= now_epoch && reset > captured_epoch {
                    return true;
                }
            }
        }
    }
    false
}

/// 全部 service 的时间戳都落在 interval 内 (多账号: 任一过期即视为需重查)。
fn all_recent(
    services: &[&Value],
    now_ms: i64,
    interval_secs: i64,
    extract: fn(&Value) -> Option<i64>,
) -> bool {
    if services.is_empty() {
        return false;
    }
    let values: Vec<i64> = services
        .iter()
        .filter_map(|service| extract(service))
        .collect();
    values.len() == services.len() && values.iter().all(|&at| now_ms - at < interval_secs * 1000)
}

/// 计算本轮额度策略 (对齐 mac `QuotaRefreshPolicy.plan`)。
///
/// - `force_refresh`: 手动或窗口边界触发, 绕过新鲜度门禁;
/// - `bypass_cooldown`: 手动刷新为 true, 连 429 冷却也绕过;
/// - `interval_secs <= 0` 表示不做新鲜度门禁 (测试兼容), 查询全部。
pub fn plan(
    previous: Option<&Value>,
    enabled_providers: &[String],
    now_ms: i64,
    interval_secs: i64,
    force_refresh: bool,
    bypass_cooldown: bool,
) -> QuotaRunPolicy {
    if force_refresh && bypass_cooldown {
        return QuotaRunPolicy::include_all();
    }
    if interval_secs <= 0 {
        return QuotaRunPolicy::include_all();
    }

    let mut by_provider: BTreeMap<String, Vec<&Value>> = BTreeMap::new();
    for service in previous
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        by_provider
            .entry(crate::runtime_core::provider_id(service).to_owned())
            .or_default()
            .push(service);
    }

    let mut skip = BTreeSet::new();
    let mut rate_limited = BTreeSet::new();
    let mut due = BTreeSet::new();

    for provider in enabled_providers {
        let services = by_provider
            .get(provider.as_str())
            .cloned()
            .unwrap_or_default();
        // 无历史 service (新启用/首次采集): 必须查询。
        if services.is_empty() {
            due.insert(provider.clone());
            continue;
        }

        if !bypass_cooldown && is_cooling(&services, now_ms, RATE_LIMIT_COOLDOWN_SECS) {
            rate_limited.insert(provider.clone());
            if provider != "codex" {
                skip.insert(provider.clone());
            }
            continue;
        }

        if force_refresh {
            due.insert(provider.clone());
            continue;
        }

        // 上次快照后已有窗口重置: 即使未满间隔也必须重查 (C037 兼容)。
        if has_passed_boundary(&services, now_ms) {
            due.insert(provider.clone());
            continue;
        }

        if all_recent(&services, now_ms, interval_secs, attempt_at) {
            if provider != "codex" {
                skip.insert(provider.clone());
            }
            continue;
        }

        if all_recent(&services, now_ms, interval_secs, captured_at) {
            if provider != "codex" {
                skip.insert(provider.clone());
            }
            continue;
        }

        due.insert(provider.clone());
    }

    let include = force_refresh || !due.is_empty();
    if !include {
        // 全部 provider 仍新鲜: 本地专用 run, 回填全部旧 service。
        skip = enabled_providers.iter().cloned().collect();
    }
    QuotaRunPolicy {
        include_external_quotas: include,
        skip_providers: skip,
        rate_limited_providers: rate_limited,
    }
}

/// 给单个 service 写 `quotaAttemptedAt`, 命中限流时写 `rateLimitedAt`, 成功则清除。
fn annotate_service(service: &mut Value, now_iso: &str) {
    let rate_limited = is_rate_limited(service);
    let Some(object) = service.as_object_mut() else {
        return;
    };
    object.insert(
        "quotaAttemptedAt".to_owned(),
        Value::String(now_iso.to_owned()),
    );
    let status = object.get("status").and_then(Value::as_str).unwrap_or("");
    let failed = matches!(status, "error" | "partial" | "unavailable");
    if failed && rate_limited {
        object.insert(
            "rateLimitedAt".to_owned(),
            Value::String(now_iso.to_owned()),
        );
    } else if !failed {
        object.remove("rateLimitedAt");
    }
}

/// 给本轮真实查询过的 service 写时间戳 (跳过 provider 不写, 由回填处理)。
pub fn annotate_attempts(artifact: &mut Value, policy: &QuotaRunPolicy, now_iso: &str) {
    let Some(services) = artifact.get_mut("services").and_then(Value::as_array_mut) else {
        return;
    };
    for service in services.iter_mut() {
        let provider = crate::runtime_core::provider_id(service).to_owned();
        if policy.skip_providers.contains(&provider) {
            continue;
        }
        annotate_service(service, now_iso);
    }
}

/// 定向刷新用: 只给目标 provider 的 service 写时间戳。
pub fn annotate_provider(artifact: &mut Value, provider: &str, now_iso: &str) {
    let Some(services) = artifact.get_mut("services").and_then(Value::as_array_mut) else {
        return;
    };
    for service in services.iter_mut() {
        if crate::runtime_core::provider_id(service) == provider {
            annotate_service(service, now_iso);
        }
    }
}

/// 被跳过的 provider: 用上一份 service 原样回填 (已存在同 ID 的跳过, 不复活已删除账号);
/// 失败/冷却/过期 → 标 stale。
pub fn carry_over_skipped(
    artifact: &mut Value,
    previous: Option<&Value>,
    policy: &QuotaRunPolicy,
    now_ms: i64,
    interval_secs: i64,
) {
    let Some(previous_services) = previous
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
    else {
        return;
    };
    let existing: BTreeSet<String> = artifact
        .get("services")
        .and_then(Value::as_array)
        .map(|services| {
            services
                .iter()
                .filter_map(|service| service.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();

    let mut carried: Vec<Value> = Vec::new();
    for service in previous_services {
        let Some(id) = service.get("id").and_then(Value::as_str) else {
            continue;
        };
        if existing.contains(id) {
            continue;
        }
        let provider = crate::runtime_core::provider_id(service).to_owned();
        if !policy.skip_providers.contains(&provider) {
            continue;
        }
        let mut carried_service = service.clone();
        let status = service.get("status").and_then(Value::as_str).unwrap_or("");
        let failed = matches!(status, "error" | "partial" | "unavailable");
        let cooling = policy.rate_limited_providers.contains(&provider);
        let aged = captured_at(service)
            .map(|at| now_ms - at >= interval_secs * 1000)
            .unwrap_or(true);
        if failed || cooling || aged {
            carried_service["freshness"] = json!("stale");
        } else if carried_service.get("freshness").is_none() {
            carried_service["freshness"] = json!("fresh");
        }
        carried.push(carried_service);
    }
    if carried.is_empty() {
        return;
    }
    if let Some(services) = artifact.get_mut("services").and_then(Value::as_array_mut) {
        services.extend(carried);
    }
}
