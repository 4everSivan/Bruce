//! Per-provider quota response parsers (C053).

use crate::{
    clamp_percent, invalid_payload, number, number_with_default, parse_window_percentage,
    reset_epoch, service_result, window, ProviderError,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;

/// Return the stable Codex service ID shared by Swift and Rust.
pub fn codex_service_id(account_id: &str) -> String {
    let digest = Sha256::digest(account_id.as_bytes());
    format!("codex_{:x}", digest)[..22].to_owned()
}

fn codex_window_label(seconds: Option<i64>) -> &'static str {
    match seconds {
        Some(seconds) if seconds <= 6 * 60 * 60 => "5小时窗口",
        Some(seconds) if seconds <= 8 * 24 * 60 * 60 => "每周窗口",
        Some(_) => "每月窗口",
        None => "窗口",
    }
}

fn codex_window_seconds(value: Option<&Value>) -> Option<i64> {
    number(value).map(|value| value as i64)
}

/// Parse the Codex `wham/usage` response without retaining the access token.
/// The shape intentionally follows the legacy wire contract because Swift's
/// panel and Codex snapshot merger already consume these fields.
pub fn parse_codex_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let rate_limit = object
        .get("rate_limit")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let mut windows = Vec::new();
    for key in ["primary_window", "secondary_window"] {
        let Some(window) = rate_limit.get(key).and_then(Value::as_object) else {
            continue;
        };
        let seconds = codex_window_seconds(window.get("limit_window_seconds"));
        let used_percent = match window.get("used_percent") {
            None | Some(Value::Null) => 0.0,
            Some(value) => number(Some(value)).ok_or_else(invalid_payload)?,
        };
        windows.push(json!({
            "label": codex_window_label(seconds),
            "usedPercent": clamp_percent(used_percent),
            "windowMinutes": seconds.map(|value| value / 60),
            "resetsAt": window.get("reset_at").cloned().unwrap_or(Value::Null),
        }));
    }
    let plan = object
        .get("plan_type")
        .filter(|value| !value.is_null())
        .cloned();
    let mut result = service_result("windows", plan, windows);
    if let Some(credits) = object.get("credits").and_then(Value::as_object) {
        if credits.get("unlimited").and_then(Value::as_bool) == Some(true) {
            result["extra"] = Value::String("Credits 不限量".to_owned());
        } else if credits.get("has_credits").and_then(Value::as_bool) == Some(true) {
            // Credits 剩余余额走结构化 balance 字段 (双端渲染于窗口行下方);
            // 归零或耗尽时不产出, 下一次刷新条目自动消失。
            // currency=credits 为展示层判别键 (非货币), 勿按汇率符号渲染。
            if let Some(balance) = number(credits.get("balance")).filter(|value| *value > 0.0) {
                result["balance"] = json!(balance);
                result["currency"] = Value::String("credits".to_owned());
            }
        }
    }
    result["freshness"] = Value::String("fresh".to_owned());
    result["failureKind"] = Value::Null;
    Ok(Some(result))
}

/// Parse the Kimi For Coding usage response without retaining the API key.
pub fn parse_kimi_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    if let Some(limits) = object.get("limits").and_then(Value::as_array) {
        for item in limits {
            let Some(detail) = item.get("detail").and_then(Value::as_object) else {
                continue;
            };
            let Ok(limit) = number_with_default(detail.get("limit"), 1.0, true) else {
                continue;
            };
            let Ok(remaining) = number_with_default(detail.get("remaining"), 0.0, true) else {
                continue;
            };
            let used = (limit - remaining).max(0.0);
            let percent = if limit > 0.0 {
                used / limit * 100.0
            } else {
                0.0
            };
            windows.push(window(
                "5小时窗口",
                percent,
                Some(300),
                reset_epoch(detail.get("resetTime")),
            ));
        }
    }
    if let Some(usage) = object.get("usage").and_then(Value::as_object) {
        let limit = number_with_default(usage.get("limit"), 1.0, true).unwrap_or(1.0);
        let remaining = number_with_default(usage.get("remaining"), 0.0, true).unwrap_or(0.0);
        let used = (limit - remaining).max(0.0);
        let percent = if limit > 0.0 {
            used / limit * 100.0
        } else {
            0.0
        };
        windows.push(window(
            "7天窗口",
            percent,
            Some(7 * 24 * 60),
            reset_epoch(usage.get("resetTime")),
        ));
    }
    Ok(Some(json!({
        "kind": "windows",
        "plan": null,
        "windows": windows,
        "extra": null,
    })))
}

/// Parse the DeepSeek balance response. An absent balance list is a valid empty result.
pub fn parse_deepseek_balance(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let Some(info) = object
        .get("balance_infos")
        .and_then(Value::as_array)
        .and_then(|items| items.first())
        .and_then(Value::as_object)
    else {
        return Ok(None);
    };
    let balance = number(info.get("total_balance")).unwrap_or(0.0);
    let currency = info
        .get("currency")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .unwrap_or("CNY");
    Ok(Some(json!({
        "kind": "balance",
        "plan": null,
        "windows": [],
        "balance": balance,
        "currency": currency,
    })))
}

fn zhipu_reset(value: Option<&Value>) -> Option<i64> {
    let number = number(value)?;
    if number <= 0.0 {
        return None;
    }
    Some(if number > 1_000_000_000_000.0 {
        (number / 1_000.0) as i64
    } else {
        number as i64
    })
}

fn zhipu_percentage(object: &serde_json::Map<String, Value>) -> f64 {
    let limit = object_value(object, &["usage", "limit", "total"]);
    let used = object_value(
        object,
        &["currentValue", "current_value", "used", "usedValue"],
    );
    let remaining = object_value(object, &["remaining", "remain"]);
    let explicit = object_value(
        object,
        &[
            "percentage",
            "usedPercent",
            "used_percent",
            "usedPercentage",
        ],
    )
    .and_then(|value| number(Some(value)));
    let derived = || {
        parse_window_percentage(limit, used, remaining).or_else(|| {
            let used = number(used)?;
            let remaining = number(remaining)?;
            let total = used + remaining;
            (total > 0.0).then_some((used / total) * 100.0)
        })
    };
    let remaining_percent = object_value(
        object,
        &[
            "remainingPercentage",
            "remaining_percent",
            "remainingPercent",
        ],
    )
    .and_then(|value| number(Some(value)))
    .map(|value| 100.0 - value);

    explicit
        .or_else(derived)
        .or(remaining_percent)
        .map(clamp_percent)
        .unwrap_or(0.0)
}

fn zhipu_windows(limits: Option<&Value>) -> Vec<Value> {
    let mut five_hour: Option<(Option<i64>, f64)> = None;
    let mut weekly: Option<(Option<i64>, f64)> = None;
    let mut unclassified = Vec::new();
    if let Some(items) = limits.and_then(Value::as_array) {
        for item in items {
            let Some(object) = item.as_object() else {
                continue;
            };
            let kind = object_value(object, &["type"])
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_uppercase();
            if kind != "TOKENS_LIMIT" && kind != "CREDIT_LIMIT" {
                continue;
            }
            let percentage = zhipu_percentage(object);
            let entry = (
                zhipu_reset(object_value(
                    object,
                    &["nextResetTime", "resetTime", "reset_time"],
                )),
                percentage,
            );
            let unit = object_value(object, &["unit"])
                .and_then(|value| number(Some(value)))
                .map(|value| value as i64);
            let number = object_value(object, &["number"])
                .and_then(|value| number(Some(value)))
                .map(|value| value as i64);
            match (unit, number) {
                (Some(3), _) | (_, Some(5)) if five_hour.is_none() => five_hour = Some(entry),
                (Some(6), _) | (_, Some(1)) if weekly.is_none() => weekly = Some(entry),
                _ => unclassified.push(entry),
            }
        }
    }
    unclassified.sort_by_key(|(reset, _)| (*reset).unwrap_or(-1));
    for entry in unclassified {
        if five_hour.is_none() {
            five_hour = Some(entry);
        } else if weekly.is_none() {
            weekly = Some(entry);
        }
    }
    let mut windows = Vec::new();
    if let Some((reset, percent)) = five_hour {
        windows.push(window("每 5 小时", percent, Some(300), reset));
    }
    if let Some((reset, percent)) = weekly {
        windows.push(window("每周", percent, Some(10080), reset));
    }
    windows
}

/// Parse the Zhipu Coding Plan quota response.
pub fn parse_zhipu_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    if object.get("success").and_then(Value::as_bool) == Some(false) {
        return Err(ProviderError::new(
            "PROVIDER_REMOTE_REJECTED",
            "parse",
            "Z.ai 额度查询被服务端拒绝",
            false,
        ));
    }
    let data = object.get("data").ok_or_else(invalid_payload)?;
    let (plan, limits) = match data {
        Value::Object(data) => (
            object_value(data, &["level", "plan"])
                .cloned()
                .unwrap_or(Value::Null),
            object_value(data, &["limits"]),
        ),
        // Newer Coding Plan responses return `data` as the limits array
        // directly: {"code":200,"data":[...]}.
        Value::Array(_) => (
            object_value(object, &["level", "plan"])
                .cloned()
                .unwrap_or(Value::Null),
            Some(data),
        ),
        _ => return Err(invalid_payload()),
    };
    Ok(Some(service_result(
        "windows",
        Some(plan),
        zhipu_windows(limits),
    )))
}

/// Parse the StepFun Step Plan quota/rate-limit response.
pub fn parse_stepfun_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    if let Some(code) = object.get("code").and_then(Value::as_i64) {
        if code != 0 && code != 200 {
            let msg = object
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("StepFun 服务端拒绝");
            return Err(ProviderError::new(
                "PROVIDER_REMOTE_REJECTED",
                "parse",
                msg,
                false,
            ));
        }
    }

    let mut windows = Vec::new();

    // Credit-based plan rate limit
    if let Some(credit_limit) = object
        .get("plan_credit_rate_limit")
        .and_then(Value::as_object)
    {
        if let Some(left_rate) = number(credit_limit.get("subscription_credit_left_rate")) {
            let used_percent = clamp_percent((1.0 - left_rate) * 100.0);
            let resets_at = credit_limit
                .get("credit_buckets")
                .and_then(Value::as_array)
                .and_then(|arr| arr.first())
                .and_then(Value::as_object)
                .and_then(|b| {
                    number(b.get("next_reset_at")).or_else(|| number(b.get("reset_time")))
                })
                .or_else(|| number(credit_limit.get("subscription_credit_reset_time")))
                .map(|t| {
                    if t > 1_000_000_000_000.0 {
                        (t / 1000.0) as i64
                    } else {
                        t as i64
                    }
                });
            windows.push(window("Credits", used_percent, None, resets_at));
        }
        if let Some(topup_left_rate) = number(credit_limit.get("topup_credit_left_rate")) {
            if topup_left_rate > 0.0 && topup_left_rate < 1.0 {
                let used_percent = clamp_percent((1.0 - topup_left_rate) * 100.0);
                windows.push(window("加油包 Credits", used_percent, None, None));
            }
        }
    }

    // 5-hour window
    if let Some(left_rate) = number(object.get("five_hour_usage_left_rate")) {
        let resets_at = number(object.get("five_hour_usage_reset_time")).map(|t| {
            if t > 1_000_000_000_000.0 {
                (t / 1000.0) as i64
            } else {
                t as i64
            }
        });
        if left_rate > 0.0 || resets_at.unwrap_or(0) > 0 {
            let used_percent = clamp_percent((1.0 - left_rate) * 100.0);
            windows.push(window("5小时窗口", used_percent, Some(300), resets_at));
        }
    }

    // Weekly window
    if let Some(left_rate) = number(object.get("weekly_usage_left_rate")) {
        let resets_at = number(object.get("weekly_usage_reset_time")).map(|t| {
            if t > 1_000_000_000_000.0 {
                (t / 1000.0) as i64
            } else {
                t as i64
            }
        });
        if left_rate > 0.0 || resets_at.unwrap_or(0) > 0 {
            let used_percent = clamp_percent((1.0 - left_rate) * 100.0);
            windows.push(window("每周窗口", used_percent, Some(10080), resets_at));
        }
    }

    if windows.is_empty() {
        return Ok(None);
    }

    let plan = object
        .get("plan_name")
        .or_else(|| object.get("plan"))
        .cloned();

    Ok(Some(service_result("windows", plan, windows)))
}

fn object_value<'a>(
    object: &'a serde_json::Map<String, Value>,
    names: &[&str],
) -> Option<&'a Value> {
    names.iter().find_map(|name| {
        object
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value)
    })
}

fn volc_window(node: Option<&Value>, label: &str) -> Option<Value> {
    let object = node?.as_object()?;
    let limit = object_value(object, &["Limit", "Total", "Quota", "TotalQuota"]);
    let used = object_value(object, &["Used", "Usage", "UsedQuota"]);
    let remaining = object_value(object, &["Remaining", "Remain"]);
    let percent = parse_window_percentage(limit, used, remaining)?;
    let reset = object_value(object, &["ResetTime", "QuotaResetTime"])
        .and_then(|value| reset_epoch(Some(value)));
    Some(window(label, percent, None, reset))
}

/// Parse both known Volcengine quota response shapes.
pub fn parse_volcengine_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows = Vec::new();
    if let Some(items) = object.get("QuotaUsage").and_then(Value::as_array) {
        for item in items {
            let Some(item) = item.as_object() else {
                continue;
            };
            let level = item
                .get("Level")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_ascii_lowercase();
            let label = match level.as_str() {
                "session" => "5小时窗口",
                "weekly" => "每周窗口",
                "monthly" => "每月窗口",
                _ if !level.is_empty() => level.as_str(),
                _ => "窗口",
            };
            let Some(percent) = number(item.get("Percent")) else {
                continue;
            };
            let reset = reset_epoch(item.get("ResetTimestamp"));
            windows.push(window(label, clamp_percent(percent), None, reset));
        }
    } else {
        for (key, label) in [
            ("AFPFiveHour", "5小时窗口"),
            ("FiveHour", "5小时窗口"),
            ("AFPWeekly", "每周窗口"),
            ("Weekly", "每周窗口"),
            ("AFPMonthly", "每月窗口"),
            ("Monthly", "每月窗口"),
        ] {
            if windows.is_empty() || !windows.iter().any(|value| value["label"] == label) {
                if let Some(value) = volc_window(object.get(key), label) {
                    windows.push(value);
                }
            }
        }
        if windows.is_empty() {
            for (key, value) in object {
                let lower = key.to_ascii_lowercase();
                let label = if lower.contains("fivehour") || lower.contains("5hour") {
                    Some("5小时窗口")
                } else if lower.contains("weekly") || lower.contains("week") {
                    Some("每周窗口")
                } else if lower.contains("monthly") || lower.contains("month") {
                    Some("每月窗口")
                } else {
                    None
                };
                if let Some(label) = label {
                    if let Some(parsed) = volc_window(Some(value), label) {
                        windows.push(parsed);
                    }
                }
            }
        }
    }
    let plan = ["PlanType", "Plan", "PlanName"]
        .iter()
        .find_map(|key| object.get(*key).and_then(Value::as_str))
        .map(|value| Value::String(value.to_owned()));
    Ok(Some(service_result("windows", plan, windows)))
}

/// Parse the TypeSafe models response for Jev.
/// Jev 为纯余额/按量计费决策模型，不生成伪造的速率限额进度条，也不在看板输出冗余模型与计费描述。
pub fn parse_jev_models(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let _models = object
        .get("models")
        .and_then(Value::as_array)
        .ok_or_else(invalid_payload)?;

    let windows: Vec<Value> = Vec::new();

    Ok(Some(json!({
        "kind": "balance",
        "plan": "System One",
        "windows": windows,
        "extra": Value::Null,
    })))
}

const CLAUDE_TIERS: &[(&str, &str, Option<u64>)] = &[
    ("five_hour", "每 5 小时", Some(300)),
    ("seven_day", "每周", Some(10080)),
    ("seven_day_fable", "每周 Fable", Some(10080)),
    ("seven_day_opus", "每周 Opus", Some(10080)),
    ("seven_day_sonnet", "每周 Sonnet", Some(10080)),
];

fn claude_tier(key: &str) -> (&str, Option<u64>) {
    CLAUDE_TIERS
        .iter()
        .find(|(known, _, _)| *known == key)
        .map(|(_, label, minutes)| (*label, *minutes))
        .unwrap_or((key, None))
}

/// 已知档位输出序 (对照 cc-switch KNOWN_TIERS 排序); 未知窗口返回 len 稳定排后。
fn claude_tier_rank(key: &str) -> usize {
    CLAUDE_TIERS
        .iter()
        .position(|(known, _, _)| *known == key)
        .unwrap_or(CLAUDE_TIERS.len())
}

/// Parse the Cline plan usage-limits response (web dashboard source).
/// ClinePass 三窗口直读网页控制台同源权威端点 `/users/me/plan/usage-limits` (C039):
/// `percentUsed` 与 `resetsAt` 由服务端算好返回 (与网页逐字一致), Bruce 不做任何本地窗口建模.
/// 服务端语义备查 (仅作理解, 严禁据此复刻建模): 5h = 「上一块到期后首单开块 [t, t+5h)」的活动块;
/// weekly/monthly = 窗口内最早一单 + 7d/30d 的滚动窗口 (纳秒级 resetsAt 实证, 2026-10-16).
/// `limits` 缺失或形状异常返回错误 (fail-visible); 未知窗口类型跳过.
pub fn parse_cline_usage_limits(
    plan_payload: &Value,
    limits_payload: &Value,
) -> Result<Option<Value>, ProviderError> {
    if cline_pass_entitled(plan_payload) != Some(true) {
        return Ok(None);
    }
    let limits = limits_payload
        .get("data")
        .and_then(|data| data.get("limits"))
        .and_then(Value::as_array)
        .ok_or_else(invalid_payload)?;
    let mut windows = Vec::with_capacity(limits.len());
    for limit in limits {
        let kind = limit
            .get("type")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default();
        let (label, window_minutes) = match kind {
            "five_hour" => ("每 5 小时", Some(300_u64)),
            "weekly" => ("每周", Some(10080)),
            "monthly" => ("每月", Some(43200)),
            _ => continue,
        };
        let percent = clamp_percent(number(limit.get("percentUsed")).ok_or_else(invalid_payload)?);
        let resets_at = reset_epoch(limit.get("resetsAt"));
        windows.push(window(label, percent, window_minutes, resets_at));
    }
    // C020: 不再注入订阅生命周期注记 (extra), 卡片仅展示计划名与三窗口.
    Ok(Some(service_result(
        "windows",
        cline_plan_name(plan_payload).map(Value::String),
        windows,
    )))
}

/// 定位 `/users/me/plan` 返回体的订阅外层对象 (`data`):
/// 真实报文为 `{"data":{"planHistoryId","plan":{...},"cancelAt","canceledAt"},"success":true}`,
/// 订阅生命周期字段 (`canceledAt`/`cancelAt`/`currentPeriodStart`) 位于本层;
/// 直接传 data 对象时原样返回.
fn cline_plan_outer(payload: &Value) -> &Value {
    payload.get("data").unwrap_or(payload)
}

/// 定位内层 `ClineSubscriptionPlan` (`displayName` / `entitlements` 所在层).
fn cline_plan_inner(payload: &Value) -> &Value {
    let outer = cline_plan_outer(payload);
    outer.get("plan").unwrap_or(outer)
}

/// ClinePass 订阅门槛: `entitlements.cline_pass` 存在、未显式停用且三窗口限额均为正
/// (真实阈值来自 `inferenceCapThreshold`, 账户级计划如 `[Internal]` 与公开计划可能不同).
/// `Some(false)` = 非 ClinePass 账户 (空态); `None` = 报文缺订阅信息 (同按非 Pass 处理).
pub(crate) fn cline_pass_entitled(payload: &Value) -> Option<bool> {
    let entitlements = cline_plan_inner(payload)
        .get("entitlements")?
        .get("cline_pass")?;
    if entitlements.get("enabled").and_then(Value::as_bool) == Some(false) {
        return Some(false);
    }
    let caps = entitlements.get("inferenceCapThreshold")?;
    let entitled = [
        "last5HoursUsageCostUSDPerUser",
        "last7daysUsageCostUSDPerUser",
        "last30daysUsageCostUSDPerUser",
    ]
    .iter()
    .filter_map(|key| number(caps.get(key)))
    .all(|cap| cap > 0.0);
    Some(entitled)
}

fn cline_plan_name(payload: &Value) -> Option<String> {
    let inner = cline_plan_inner(payload);
    ["displayName", "name"].iter().find_map(|key| {
        inner
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    })
}

/// Parse the Claude OAuth usage response (`/api/oauth/usage`).
/// 对照 cc-switch `parse_claude_quota` (farion1231/cc-switch, 2026-10-18) 对齐口径:
/// - 顶层旧版窗口取 `utilization`/`resets_at`, 单条脏数据 (utilization 非数值) 逐窗口跳过,
///   不再让整卡报错;
/// - `limits[]` 承载模型专属周限额: 仅收 `kind=weekly_scoped` + `group=weekly` 且
///   `scope.surface` 为空的行, 模型归一自 `scope.model.display_name` (trim+小写 →
///   fable/opus/sonnet), 取 `percent` (须为非负数值) 与 `resets_at` (字符串或 null);
///   与 Claude Code 一致不按 `is_active` 过滤 (0%/null 重置也可能是有效额度), 同名档位
///   首条优先去重并覆盖同名旧版顶层窗口;
/// - 输出按已知档位序排列, 未知窗口稳定排后; `extra_usage` 独立成行追加在末尾。
pub fn parse_claude_usage(payload: &Value) -> Result<Option<Value>, ProviderError> {
    let object = payload.as_object().ok_or_else(invalid_payload)?;
    let mut windows: Vec<(usize, Value)> = Vec::new();
    for (key, value) in object {
        if key == "extra_usage" || key == "limits" {
            continue;
        }
        let Some(entry) = value.as_object() else {
            continue;
        };
        let Some(percent) = number(entry.get("utilization")) else {
            continue;
        };
        let (label, minutes) = claude_tier(key);
        windows.push((
            claude_tier_rank(key),
            window(
                label,
                clamp_percent(percent),
                minutes,
                reset_epoch(entry.get("resets_at")),
            ),
        ));
    }
    if let Some(limits) = object.get("limits").and_then(Value::as_array) {
        let mut scoped = BTreeSet::new();
        for limit in limits {
            if limit.get("kind").and_then(Value::as_str) != Some("weekly_scoped")
                || limit.get("group").and_then(Value::as_str) != Some("weekly")
                // 特定使用场景 (scope.surface) 的子限额不并入模型整体周限额。
                || limit.pointer("/scope/surface").is_some_and(|value| !value.is_null())
            {
                continue;
            }
            let Some(model) = limit
                .pointer("/scope/model/display_name")
                .and_then(Value::as_str)
            else {
                continue;
            };
            let tier = match model.trim().to_ascii_lowercase().as_str() {
                "fable" => "seven_day_fable",
                "opus" => "seven_day_opus",
                "sonnet" => "seven_day_sonnet",
                _ => continue,
            };
            let Some(percent) = limit.get("percent").and_then(Value::as_f64) else {
                continue;
            };
            // resets_at 仅收字符串或 null (cc-switch 反序列化同口径), 数值形态整行跳过;
            // 校验必须先于去重插入, 否则被跳过的行会占掉该档位的"首条"名额。
            let resets_at = match limit.get("resets_at") {
                None | Some(Value::Null) => None,
                Some(Value::String(_)) => reset_epoch(limit.get("resets_at")),
                Some(_) => continue,
            };
            if !percent.is_finite() || percent < 0.0 || !scoped.insert(tier) {
                continue;
            }
            let (label, minutes) = claude_tier(tier);
            let row = window(label, clamp_percent(percent), minutes, resets_at);
            let rank = claude_tier_rank(tier);
            match windows.iter_mut().find(|(existing, _)| *existing == rank) {
                Some(slot) => slot.1 = row,
                None => windows.push((rank, row)),
            }
        }
    }
    windows.sort_by_key(|(rank, _)| *rank);
    let mut rows: Vec<Value> = windows.into_iter().map(|(_, row)| row).collect();
    if let Some(extra) = object.get("extra_usage").and_then(Value::as_object) {
        if extra.get("is_enabled").and_then(Value::as_bool) == Some(true) {
            if let Some(percent) = number(extra.get("utilization")) {
                let mut value = window("额外用量", clamp_percent(percent), None, None);
                if let Some(value) = value.as_object_mut() {
                    value.insert("ownRow".to_owned(), Value::Bool(true));
                }
                rows.push(value);
            }
        }
    }
    Ok(Some(service_result("windows", None, rows)))
}
