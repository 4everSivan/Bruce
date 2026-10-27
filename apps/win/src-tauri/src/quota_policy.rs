//! 订阅额度 per-provider 门禁与回填 (C077)。
//!
//! 实现位于跨端共享 crate `collector-policy` (T13, design/08): 门禁、回填、尝试时间戳与
//! 限流 / provider 判定只有这一份, mac 经 collector 策略入口调用同一实现。本模块保留
//! Windows 侧的调用路径, 并固定 Windows 无锁屏抑制的入参。

pub use collector_policy::{
    annotate_provider, attempt_at, captured_at, is_qualified_previous, is_rate_limited,
    is_rate_limited_note, merge, merge_round, parse_ms, rate_limited_at, rate_limited_providers_in,
    timestamp_iso, QuotaRunPolicy, RATE_LIMIT_COOLDOWN_SECS,
};

/// 计算本轮额度策略。
///
/// - `force_refresh`: 手动或窗口边界触发, 绕过新鲜度门禁;
/// - `bypass_cooldown`: 手动刷新为 true, 连 429 冷却也绕过;
/// - `interval_secs <= 0` 表示不做新鲜度门禁 (测试兼容), 查询全部。
pub fn plan(
    previous: Option<&serde_json::Value>,
    enabled_providers: &[String],
    now_ms: i64,
    interval_secs: i64,
    force_refresh: bool,
    bypass_cooldown: bool,
) -> QuotaRunPolicy {
    collector_policy::plan(&collector_policy::PlanInput {
        previous,
        enabled_providers: Some(enabled_providers),
        now_ms,
        interval_secs,
        force_refresh,
        bypass_cooldown,
        suppress_external_quotas: false,
    })
}
