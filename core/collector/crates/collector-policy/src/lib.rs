#![deny(unsafe_code)]

//! 跨端共享的每轮刷新策略 (design/08 SharedPolicyCore)。
//!
//! 第一期只含订阅额度门禁 (`plan`) 与额度回填 (`merge` / `merge_round` / 尝试时间戳标注),
//! 由 Windows 进程内调用、mac 经 collector 策略入口调用。纯函数: 不做网络、文件 I/O,
//! 不接触凭据; 输入输出均为 artifact 的 `serde_json::Value`。
//! 双端口径由 `tests/fixtures/quota-policy-parity` 与 `tests/fixtures/quota-carry-over-parity`
//! 两份共享用例裁判。

pub mod quota;

pub use quota::{
    annotate_provider, annotate_services, attempt_at, captured_at, is_failed_status,
    is_qualified_previous, is_rate_limited, is_rate_limited_note, merge, merge_round, parse_ms,
    plan, provider_id, provider_of_id, rate_limited_at, rate_limited_providers_in, timestamp_iso,
    PlanInput, QuotaRunPolicy, BORROWED_FIELDS, RATE_LIMIT_COOLDOWN_SECS,
};
