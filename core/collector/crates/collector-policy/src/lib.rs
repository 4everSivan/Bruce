#![deny(unsafe_code)]

//! 跨端共享的每轮刷新策略 (design/08 SharedPolicyCore)。
//!
//! 第一期含订阅额度门禁 (`plan`) 与额度回填 (`merge` / `merge_round` / 尝试时间戳标注);
//! T17 起含窗口边界唤醒 (`boundary_delay`) 与刷新退避 (`capped_backoff` / `backoff_seconds`)。
//! 由 Windows 进程内调用、mac 经策略入口 (`request::handle_request`, 静态库
//! `collector-policy-ffi` 的 C ABI, T16) 进程内调用。纯函数: 不做网络、文件 I/O, 不接触凭据;
//! 输入输出均为 artifact 的 `serde_json::Value`。
//! 双端口径由 `tests/fixtures/quota-policy-parity`、`quota-carry-over-parity` 与
//! `refresh-policy-parity` 三份共享用例裁判。

pub mod quota;
pub mod refresh;
pub mod request;

pub use quota::{
    annotate_provider, annotate_services, attempt_at, captured_at, is_failed_status,
    is_qualified_previous, is_rate_limited, is_rate_limited_note, merge, merge_round, parse_ms,
    plan, provider_id, provider_of_id, rate_limited_at, rate_limited_providers_in, timestamp_iso,
    PlanInput, QuotaRunPolicy, BORROWED_FIELDS, MIN_QUOTA_INTERVAL_SECS, RATE_LIMIT_COOLDOWN_SECS,
};
pub use refresh::{
    backoff_seconds, boundary_delay, boundary_ids, boundary_vec, capped_backoff, window_boundaries,
    DEFAULT_BOUNDARY_SLACK_SECS,
};
pub use request::{handle_request, MAX_POLICY_REQUEST_BYTES, POLICY_SCHEMA_VERSION};
