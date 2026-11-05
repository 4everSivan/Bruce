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

/// C212: Agent 卡内刷新只跑本地采集, 不查询订阅额度; 上一份全部 provider 进入
/// skip, 由共享 merge 原样回填, 订阅卡数值与时间戳不变。
pub fn plan_local_only(previous: Option<&serde_json::Value>) -> QuotaRunPolicy {
    collector_policy::plan(&collector_policy::PlanInput {
        previous,
        enabled_providers: Some(&[]),
        now_ms: 0,
        interval_secs: 0,
        force_refresh: false,
        bypass_cooldown: false,
        suppress_external_quotas: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn local_only_policy_skips_all_previous_providers() {
        let previous = json!({
            "services": [
                { "id": "claude_a", "app": "claude", "status": "ok", "windows": [] },
                { "id": "codex_b", "app": "codex", "status": "ok", "windows": [] }
            ]
        });
        let policy = plan_local_only(Some(&previous));
        assert!(!policy.include_external_quotas);
        assert!(policy.skip_providers.contains("claude"));
        assert!(policy.skip_providers.contains("codex"));
    }
}
