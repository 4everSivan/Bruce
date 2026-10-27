//! 窗口边界唤醒与刷新退避 (T17, design/08): 两端共用一份纯函数实现。
//!
//! - `window_boundaries` / `boundary_ids`: 从 artifact 的 `services[].windows[].resetsAt`
//!   提取窗口重置时刻 (epoch 秒, 与卡片展示同源); 只认 `kind == "windows"` 的服务。
//! - `boundary_delay`: 定时刷新不得跨过未来的额度窗口重置时刻 (C037)。三道防线:
//!   只认严格在未来的边界 (滚动窗口的滑出时刻前移时天然不触发); 同一「边界值」只消费
//!   一次 (epoch 秒精确去重); 未命中边界则回落原间隔。
//! - `capped_backoff` / `backoff_seconds`: 限流走固定退避; 其他走指数退避
//!   (`base * 2^(retry-1)`) + 抖动, 上限 `max`。
//!
//! 不做网络 / 文件 I/O, 不接触凭据; 输入输出均为 `serde_json::Value` 或标量。

use std::collections::BTreeSet;

use serde_json::Value;

/// 边界唤醒的默认提前量 (秒)。
pub const DEFAULT_BOUNDARY_SLACK_SECS: f64 = 20.0;
/// 指数退避的最大移位 (与 Windows 原实现一致, 防止巨大 retry 溢出)。
const MAX_BACKOFF_SHIFT: u32 = 10;

/// 从 artifact 提取订阅窗口的重置时刻 (epoch 秒)。
pub fn window_boundaries(artifact: &Value) -> Vec<i64> {
    artifact
        .get("services")
        .and_then(Value::as_array)
        .map(|services| boundary_ids(services))
        .unwrap_or_default()
}

/// 从 services 提取窗口重置时刻 (epoch 秒)。只认 `kind == "windows"`;
/// `resetsAt` 接受整数或数值 (小数按秒截断), null / 缺失 / 非数值忽略。
pub fn boundary_ids(services: &[Value]) -> Vec<i64> {
    let mut boundaries = Vec::new();
    for service in services {
        if service.get("kind").and_then(Value::as_str) != Some("windows") {
            continue;
        }
        let Some(windows) = service.get("windows").and_then(Value::as_array) else {
            continue;
        };
        for window in windows {
            let Some(reset) = window.get("resetsAt") else {
                continue;
            };
            if let Some(epoch) = reset
                .as_i64()
                .or_else(|| reset.as_f64().map(|value| value as i64))
            {
                boundaries.push(epoch);
            }
        }
    }
    boundaries
}

/// 下次唤醒间隔 (秒): `min(interval, 最近一个未来边界 + slack)`; 命中时消费该边界。
///
/// `now` 为 epoch 秒 (可含小数); 过滤 / 剪枝按整秒 (`now as i64`), 与 mac 原实现一致。
/// 已进入过去的边界从 `consumed` 剪掉, 顺带收敛集合规模。
pub fn boundary_delay(
    interval: f64,
    boundaries: &[i64],
    now: f64,
    slack: f64,
    consumed: &mut BTreeSet<i64>,
) -> f64 {
    let now_epoch = now as i64;
    consumed.retain(|&boundary| boundary > now_epoch);

    let mut best: Option<(f64, i64)> = None;
    for &boundary in boundaries {
        if boundary <= now_epoch || consumed.contains(&boundary) {
            continue;
        }
        let delay = (boundary as f64 + slack - now).max(0.0);
        if delay >= interval {
            continue;
        }
        if best.is_none_or(|(chosen, _)| delay < chosen) {
            best = Some((delay, boundary));
        }
    }

    match best {
        Some((delay, boundary)) => {
            consumed.insert(boundary);
            delay
        }
        None => interval,
    }
}

/// 退避的指数部分 (未加抖动): `min(base * 2^(retry-1), max)`。
/// `retry_count` 0 与 1 同为首个重试档 (与 Windows 原实现一致, 避免 0 下溢)。
pub fn capped_backoff(retry_count: u32, base_seconds: f64, max_seconds: f64) -> f64 {
    let shift = retry_count.max(1).saturating_sub(1).min(MAX_BACKOFF_SHIFT);
    let exponential = base_seconds * 2f64.powi(shift as i32);
    exponential.min(max_seconds)
}

/// 一个重试档的退避秒数: 限流固定 `rate_limit_seconds`; 其余
/// `min(capped + capped * jitter_fraction, max)`。抖动比例由调用方注入
/// (两端现有实现均为 capped 的 0~10%), 便于测试确定性。
pub fn backoff_seconds(
    retry_count: u32,
    rate_limited: bool,
    base_seconds: f64,
    max_seconds: f64,
    rate_limit_seconds: f64,
    jitter_fraction: f64,
) -> f64 {
    if rate_limited {
        return rate_limit_seconds;
    }
    let capped = capped_backoff(retry_count, base_seconds, max_seconds);
    let jitter = capped * jitter_fraction.clamp(0.0, 1.0);
    (capped + jitter).min(max_seconds)
}

/// 边界集合转回升序数组 (JSON 输出用)。
pub fn boundary_vec(consumed: &BTreeSet<i64>) -> Vec<i64> {
    consumed.iter().copied().collect()
}
