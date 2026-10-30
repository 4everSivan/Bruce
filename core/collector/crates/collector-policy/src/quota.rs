//! 订阅额度 per-provider 门禁与回填 (C062 / C071 / C077 / C118 / C120, T13 收敛为单份实现)。
//!
//! - 新鲜度门禁: provider 的 `quotaAttemptedAt` (回退 `capturedAt`) 距今不足刷新间隔时
//!   跳过额度查询; 间隔最短按 3 分钟计 (C164), 本地采集更快时额度查询不跟随;
//! - 429 冷却: service 带 `rateLimitedAt` 且距今不足 30 分钟时跳过 (仅该 provider);
//! - 手动刷新绕过新鲜度与冷却; 窗口边界唤醒绕过新鲜度但尊重冷却;
//! - Codex 永不进入 skip (其四源合并 / 重试链路需要完整首轮结果);
//! - 锁屏等抑制场景: 全部上一份 provider 进入 skip, 由回填原样保留 (C071);
//! - 回填: 被跳过的 provider 用上一份 service 原样回填并按新鲜期标注; 本轮失败的
//!   service 借用合格旧展示字段并标 stale; 本轮真实查询的 service 写尝试时间戳。

use std::collections::{BTreeMap, BTreeSet};

use chrono::{SecondsFormat, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// 自动额度查询的 429 冷却 (秒)。
pub const RATE_LIMIT_COOLDOWN_SECS: i64 = 30 * 60;

/// 自动额度查询的最短间隔 (秒, C164): 刷新间隔可设到 1 分钟 (C160), 但外部额度接口
/// 最快 3 分钟查询一次; 手动刷新与窗口边界重查不受此限。
pub const MIN_QUOTA_INTERVAL_SECS: i64 = 3 * 60;

/// 门禁与回填实际使用的间隔: `<= 0` 保持「不做门禁」语义, 其余不低于最短间隔。
fn effective_interval_secs(interval_secs: i64) -> i64 {
    if interval_secs <= 0 {
        interval_secs
    } else {
        interval_secs.max(MIN_QUOTA_INTERVAL_SECS)
    }
}

/// 本轮查询失败时从合格旧 service 借用的展示字段 (design/02 规则 12)。
pub const BORROWED_FIELDS: [&str; 7] = [
    "windows",
    "balance",
    "currency",
    "plan",
    "extra",
    "kind",
    "capturedAt",
];

/// 永不跳过的 provider: 其四源合并 / 定向重试需要完整首轮结果。
const NEVER_SKIPPED: &str = "codex";

/// 单轮刷新对外部额度查询的决策。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QuotaRunPolicy {
    /// 是否发起任何外部额度查询 (false = 本地专用 run, 回填全部被跳过的旧 service)。
    pub include_external_quotas: bool,
    /// 本轮跳过的 provider (额度仍新鲜、处于 429 冷却或被抑制)。
    pub skip_providers: BTreeSet<String>,
    /// 跳过原因是 429 冷却的 provider (回填时强制标 stale)。
    pub rate_limited_providers: BTreeSet<String>,
}

impl QuotaRunPolicy {
    /// 查询全部 provider (无门禁)。
    pub fn include_all() -> Self {
        Self {
            include_external_quotas: true,
            ..Self::default()
        }
    }

    /// 本地专用 run: 不查询任何 provider。
    pub fn local_only() -> Self {
        Self::default()
    }

    pub fn is_skipped(&self, provider: &str) -> bool {
        self.skip_providers.contains(provider)
    }
}

/// 门禁输入。
#[derive(Debug, Clone, Copy)]
pub struct PlanInput<'a> {
    /// 上一份已发布 artifact; `None` / 无 services 视为无历史。
    pub previous: Option<&'a Value>,
    /// 本轮启用的 provider (C120); `None` 表示未知 (mac 测试桩), 沿用上一份中出现的 provider。
    pub enabled_providers: Option<&'a [String]>,
    pub now_ms: i64,
    /// 额度查询周期 (秒); `<= 0` 表示不做新鲜度门禁, 查询全部。
    pub interval_secs: i64,
    /// 手动或窗口边界触发: 绕过新鲜度门禁。
    pub force_refresh: bool,
    /// 手动刷新: 连 429 冷却也绕过。
    pub bypass_cooldown: bool,
    /// 锁屏等场景强制抑制外部额度查询 (C064 / C071)。
    pub suppress_external_quotas: bool,
}

/// 时间戳 (毫秒) → RFC 3339 秒级 UTC 字符串 (与 artifact `capturedAt` 同格式)。
pub fn timestamp_iso(now_ms: i64) -> String {
    Utc.timestamp_millis_opt(now_ms)
        .single()
        .map(|dt| dt.to_rfc3339_opts(SecondsFormat::Secs, true))
        .unwrap_or_default()
}

/// 解析 service 的时间戳字段 (RFC 3339, 可带小数秒 / epoch 秒 / epoch 毫秒) 为毫秒。
pub fn parse_ms(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::String(text) => chrono::DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|dt| dt.timestamp_millis()),
        // 数值 > 1e12 视为毫秒, 否则视为秒。
        Value::Number(number) => number.as_i64().map(|raw| {
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

fn status(service: &Value) -> &str {
    service.get("status").and_then(Value::as_str).unwrap_or("")
}

/// 失败口径: `error` / `partial` / `unavailable`。
pub fn is_failed_status(status: &str) -> bool {
    matches!(status, "error" | "partial" | "unavailable")
}

/// 最近一次真实额度尝试: `quotaAttemptedAt` 优先, 回退 `capturedAt`, 失败 service
/// 再回退 `rateLimitedAt` (C120)。
pub fn attempt_at(service: &Value) -> Option<i64> {
    parse_ms(service.get("quotaAttemptedAt"))
        .or_else(|| captured_at(service))
        .or_else(|| {
            if is_failed_status(status(service)) {
                rate_limited_at(service)
            } else {
                None
            }
        })
}

/// 限流文案识别 (C118 前旧 artifact 的回退判据)。
pub fn is_rate_limited_note(note: &str) -> bool {
    note.contains("429") || note.contains("限流") || note.contains("RATE_LIMIT")
}

/// 服务是否因限流失败 (C118): 下发 `failureKind` 时以其为准 (包括显式 null),
/// 旧 artifact 无该字段时回退匹配 note 文案。
pub fn is_rate_limited(service: &Value) -> bool {
    service.as_object().is_some_and(object_is_rate_limited)
}

fn object_is_rate_limited(object: &Map<String, Value>) -> bool {
    match object.get("failureKind") {
        Some(kind) => kind.as_str() == Some("rateLimit"),
        None => is_rate_limited_note(object.get("note").and_then(Value::as_str).unwrap_or("")),
    }
}

fn object_failed(object: &Map<String, Value>) -> bool {
    is_failed_status(object.get("status").and_then(Value::as_str).unwrap_or(""))
}

/// 服务所属 provider (C118): 优先 collector 显式下发的 `provider`, 旧 artifact 缺省时
/// 回退按 service id 前缀推断。
pub fn provider_id(service: &Value) -> &str {
    match service.get("provider").and_then(Value::as_str) {
        Some(provider) if !provider.is_empty() => provider,
        _ => provider_of_id(service.get("id").and_then(Value::as_str).unwrap_or("")),
    }
}

/// service / 订阅卡 section ID → provider rawValue。单账号 section 的 ID 是带账号后缀的
/// service ID (如 `zhipu_9be9…`), 多账号分组 section 的 ID 即 provider 本身 (如 `cline`),
/// 两者经同一前缀规则归一; 无法识别时原样返回。
pub fn provider_of_id(id: &str) -> &str {
    const PREFIXES: [(&str, &str); 12] = [
        ("codex", "codex"),
        ("claude", "claude"),
        ("kimi", "kimi"),
        ("deepseek", "deepseek"),
        ("volc", "volcengine"),
        ("zhipu", "zhipu"),
        ("glm", "zhipu"),
        ("grok", "grok"),
        ("opencode", "opencodeGo"),
        ("step", "stepfun"),
        ("cline", "cline"),
        ("jev", "jev"),
    ];
    PREFIXES
        .iter()
        .find(|(prefix, _)| id.starts_with(prefix))
        .map_or(id, |(_, provider)| provider)
}

fn services(artifact: Option<&Value>) -> &[Value] {
    artifact
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// 本轮发出过 429 的 provider (status error / partial 且判定为限流)。
pub fn rate_limited_providers_in(artifact: Option<&Value>) -> BTreeSet<String> {
    services(artifact)
        .iter()
        .filter(|service| matches!(status(service), "error" | "partial"))
        .filter(|service| is_rate_limited(service))
        .map(|service| provider_id(service).to_owned())
        .collect()
}

fn is_cooling(services: &[&Value], now_ms: i64) -> bool {
    services
        .iter()
        .filter_map(|service| rate_limited_at(service))
        .max()
        .is_some_and(|limited| now_ms - limited < RATE_LIMIT_COOLDOWN_SECS * 1000)
}

fn reset_epoch(window: &Value) -> Option<i64> {
    let reset = window.get("resetsAt")?;
    reset
        .as_i64()
        .or_else(|| reset.as_f64().map(|value| value as i64))
}

/// 上次快照之后是否有窗口 `resetsAt` (epoch 秒) 已过去 (C037 兼容)。
fn has_passed_boundary(services: &[&Value], now_ms: i64) -> bool {
    let now_epoch = now_ms.div_euclid(1000);
    services.iter().any(|service| {
        if service.get("kind").and_then(Value::as_str) != Some("windows") {
            return false;
        }
        let Some(captured) = captured_at(service) else {
            return false;
        };
        let captured_epoch = captured.div_euclid(1000);
        service
            .get("windows")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(reset_epoch)
            .any(|reset| reset <= now_epoch && reset > captured_epoch)
    })
}

/// 全部 service 的时间戳都落在间隔内 (多账号: 任一过期即视为需重查)。
fn all_recent(
    services: &[&Value],
    now_ms: i64,
    interval_secs: i64,
    extract: fn(&Value) -> Option<i64>,
) -> bool {
    !services.is_empty()
        && services
            .iter()
            .all(|service| extract(service).is_some_and(|at| now_ms - at < interval_secs * 1000))
}

/// 计算本轮额度策略。
pub fn plan(input: &PlanInput<'_>) -> QuotaRunPolicy {
    let previous_services = services(input.previous);
    if input.suppress_external_quotas {
        // C071: 抑制运行等价于「上一份全部 provider 进入 skip」, 由回填原样保留;
        // 返回空 skip 会发布零 services 的 artifact, 订阅卡在解锁后被清空。
        return QuotaRunPolicy {
            include_external_quotas: false,
            skip_providers: previous_services
                .iter()
                .map(|service| provider_id(service).to_owned())
                .collect(),
            rate_limited_providers: BTreeSet::new(),
        };
    }
    if (input.force_refresh && input.bypass_cooldown) || input.interval_secs <= 0 {
        return QuotaRunPolicy::include_all();
    }

    let mut by_provider: BTreeMap<&str, Vec<&Value>> = BTreeMap::new();
    for service in previous_services {
        by_provider
            .entry(provider_id(service))
            .or_default()
            .push(service);
    }
    let candidates: BTreeSet<String> = match input.enabled_providers {
        Some(enabled) => enabled.iter().cloned().collect(),
        None if by_provider.is_empty() => return QuotaRunPolicy::include_all(),
        None => by_provider
            .keys()
            .map(|provider| (*provider).to_owned())
            .collect(),
    };

    let mut skip = BTreeSet::new();
    let mut rate_limited = BTreeSet::new();
    let mut due = false;
    for provider in &candidates {
        let services = by_provider
            .get(provider.as_str())
            .map_or(&[][..], Vec::as_slice);
        let skippable = provider != NEVER_SKIPPED;
        // 无历史 service (新启用 / 首次采集): 必须查询。
        if services.is_empty() {
            due = true;
            continue;
        }
        if !input.bypass_cooldown && is_cooling(services, input.now_ms) {
            rate_limited.insert(provider.clone());
            if skippable {
                skip.insert(provider.clone());
            }
            continue;
        }
        // 强制刷新, 或上次快照后已有窗口重置: 即使未满间隔也必须重查。
        if input.force_refresh || has_passed_boundary(services, input.now_ms) {
            due = true;
            continue;
        }
        let interval_secs = effective_interval_secs(input.interval_secs);
        let fresh = all_recent(services, input.now_ms, interval_secs, attempt_at)
            || all_recent(services, input.now_ms, interval_secs, captured_at);
        if !fresh {
            due = true;
        } else if skippable {
            skip.insert(provider.clone());
        }
    }

    let include = input.force_refresh || due;
    if !include {
        // 全部 provider 仍新鲜: 本地专用 run, 回填全部启用 provider 的旧 service。
        skip = candidates;
    }
    QuotaRunPolicy {
        include_external_quotas: include,
        skip_providers: skip,
        rate_limited_providers: rate_limited,
    }
}

/// 旧 service 是否可作为失败时借用的成功快照: `capturedAt` 可解析, 且 freshness 为
/// fresh / stale; 无 freshness 的旧 artifact 以 status ok / empty 判定。
pub fn is_qualified_previous(service: &Value) -> bool {
    let captured = service
        .get("capturedAt")
        .and_then(Value::as_str)
        .is_some_and(|text| chrono::DateTime::parse_from_rfc3339(text).is_ok());
    if !captured {
        return false;
    }
    match service.get("freshness").and_then(Value::as_str) {
        Some(freshness) => matches!(freshness, "fresh" | "stale"),
        None => matches!(status(service), "ok" | "empty"),
    }
}

/// 本轮 service 的新鲜度: 失败时借用合格旧展示字段并标 stale, 无合格历史标
/// unavailable 并去掉 `capturedAt`; 成功且未带 freshness 时补 fresh (已带的保留)。
fn apply_freshness(object: &mut Map<String, Value>, previous: Option<&Value>) {
    if !object_failed(object) {
        object
            .entry("freshness")
            .or_insert_with(|| Value::String("fresh".to_owned()));
        return;
    }
    match previous.filter(|previous| is_qualified_previous(previous)) {
        Some(previous) => {
            for field in BORROWED_FIELDS {
                if let Some(value) = previous.get(field) {
                    object.insert(field.to_owned(), value.clone());
                }
            }
            object.insert("freshness".to_owned(), Value::String("stale".to_owned()));
        }
        None => {
            object.insert(
                "freshness".to_owned(),
                Value::String("unavailable".to_owned()),
            );
            object.remove("capturedAt");
        }
    }
}

/// 本轮真实查询过的 service: 写 `quotaAttemptedAt`; 限流失败写 `rateLimitedAt`,
/// 成功则清除。
fn stamp_attempt(object: &mut Map<String, Value>, now_iso: &str) {
    let failed = object_failed(object);
    let rate_limited = object_is_rate_limited(object);
    object.insert(
        "quotaAttemptedAt".to_owned(),
        Value::String(now_iso.to_owned()),
    );
    if failed && rate_limited {
        object.insert(
            "rateLimitedAt".to_owned(),
            Value::String(now_iso.to_owned()),
        );
    } else if !failed {
        object.remove("rateLimitedAt");
    }
}

/// 被跳过 provider 的回填标注: 失败 / 冷却 / 成功快照已过间隔 → stale, 否则缺省补 fresh。
fn mark_carried(object: &mut Map<String, Value>, cooling: bool, now_ms: i64, interval_secs: i64) {
    let interval_secs = effective_interval_secs(interval_secs);
    let aged =
        parse_ms(object.get("capturedAt")).is_none_or(|at| now_ms - at >= interval_secs * 1000);
    if object_failed(object) || cooling || aged {
        object.insert("freshness".to_owned(), Value::String("stale".to_owned()));
    } else {
        object
            .entry("freshness")
            .or_insert_with(|| Value::String("fresh".to_owned()));
    }
}

fn index_by_id(services: &[Value]) -> BTreeMap<&str, &Value> {
    services
        .iter()
        .filter_map(|service| {
            service
                .get("id")
                .and_then(Value::as_str)
                .map(|id| (id, service))
        })
        .collect()
}

/// 单轮合并 (不写时间戳、不回填跳过的 provider): 只保留本轮返回的 service, 按本轮顺序;
/// 失败的借用同 ID 合格旧值。供无门禁的整轮应用与定向刷新合并复用。
pub fn merge_round(previous: Option<&Value>, current: &Value) -> Value {
    let previous_by_id = index_by_id(services(previous));
    let mut result = current.clone();
    if let Some(services) = result.get_mut("services").and_then(Value::as_array_mut) {
        for service in services {
            let previous = service
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| previous_by_id.get(id).copied());
            if let Some(object) = service.as_object_mut() {
                apply_freshness(object, previous);
            }
        }
    }
    result
}

/// 完整回填: 输出沿用上一份 service 的顺序 (订阅卡在无自定义顺序时按 artifact 顺序展示,
/// 跳过的 provider 不会被挪到末尾), 本轮新增的 service 按本轮顺序排在其后。
/// - 本轮返回的 service: 写尝试时间戳并按失败口径借用同 ID 合格旧值;
/// - 本轮未返回且其 provider 被跳过: 用上一份原样回填并按新鲜期标注;
/// - 本轮未返回且其 provider 已查询: 视为账号删除 / 不可用, 不复活。
pub fn merge(
    previous: Option<&Value>,
    current: &Value,
    policy: &QuotaRunPolicy,
    now_ms: i64,
    interval_secs: i64,
) -> Value {
    if !current.is_object() {
        return current.clone();
    }
    let now_iso = timestamp_iso(now_ms);
    let current_services = services(Some(current));
    let current_by_id = index_by_id(current_services);
    let annotate = |service: &Value, previous: Option<&Value>| {
        let mut service = service.clone();
        if let Some(object) = service.as_object_mut() {
            stamp_attempt(object, &now_iso);
            apply_freshness(object, previous);
        }
        service
    };

    let mut output = Vec::with_capacity(current_services.len());
    let mut emitted = BTreeSet::new();
    for previous_service in services(previous) {
        let Some(id) = previous_service.get("id").and_then(Value::as_str) else {
            continue;
        };
        if !emitted.insert(id) {
            continue;
        }
        if let Some(current_service) = current_by_id.get(id) {
            output.push(annotate(current_service, Some(previous_service)));
            continue;
        }
        let provider = provider_id(previous_service);
        if policy.is_skipped(provider) {
            let mut carried = previous_service.clone();
            if let Some(object) = carried.as_object_mut() {
                let cooling = policy.rate_limited_providers.contains(provider);
                mark_carried(object, cooling, now_ms, interval_secs);
            }
            output.push(carried);
        }
    }
    for current_service in current_services {
        let id = current_service.get("id").and_then(Value::as_str);
        if id.is_some_and(|id| emitted.contains(id)) {
            continue;
        }
        output.push(annotate(current_service, None));
    }

    let mut result = current.clone();
    result["services"] = Value::Array(output);
    result
}

fn annotate_where(artifact: &mut Value, now_ms: i64, selected: impl Fn(&Value) -> bool) {
    let now_iso = timestamp_iso(now_ms);
    let Some(services) = artifact.get_mut("services").and_then(Value::as_array_mut) else {
        return;
    };
    for service in services.iter_mut().filter(|service| selected(service)) {
        if let Some(object) = service.as_object_mut() {
            stamp_attempt(object, &now_iso);
            if !object_failed(object) {
                object
                    .entry("freshness")
                    .or_insert_with(|| Value::String("fresh".to_owned()));
            }
        }
    }
}

/// 定向刷新: 只给本轮真实查询到的 service (按 ID) 写尝试时间戳; 合并与失败借用由
/// 定向合并器完成, 这里不改动。
pub fn annotate_services(artifact: &mut Value, service_ids: &BTreeSet<String>, now_ms: i64) {
    annotate_where(artifact, now_ms, |service| {
        service
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| service_ids.contains(id))
    });
}

/// 定向刷新: 给目标 provider 的全部 service 写尝试时间戳 (定向合并后目标 provider 只剩
/// 本轮返回的 service)。
pub fn annotate_provider(artifact: &mut Value, provider: &str, now_ms: i64) {
    annotate_where(artifact, now_ms, |service| provider_id(service) == provider);
}
