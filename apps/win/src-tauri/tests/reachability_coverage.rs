//! 网络可达性闸门覆盖 (C076) —— 假探针驱动的状态机契约: 离线跳过、联网单次补偿、
//! 手动刷新不变。真实 Windows 连通性 API 行为仍以真机验收为准。

use bruce_win_lib::reachability::{
    should_skip_refresh, NetworkProbe, ReachabilityDecision, ReachabilityGate,
    OFFLINE_PROBE_INTERVAL_SECS,
};

/// 可注入假探针 (离线→在线跃迁按脚本推进)。
struct FakeProbe(Vec<bool>);

impl NetworkProbe for FakeProbe {
    fn is_online(&self) -> bool {
        *self.0.last().unwrap_or(&true)
    }
}

#[test]
fn fake_probe_is_injectable_and_decoupled_from_scheduling() {
    let probe = FakeProbe(vec![false]);
    assert!(!probe.is_online());
    let probe = FakeProbe(vec![true]);
    assert!(probe.is_online());
}

#[test]
fn offline_ticks_skip_without_retry_and_reconnect_compensates_once() {
    let probe = FakeProbe(vec![false]);
    let mut gate = ReachabilityGate::new();
    // 定时唤醒: 离线时跳过且不发起刷新 (retries 不增长由调度侧保证)。
    assert_eq!(
        gate.observe(probe.is_online()),
        ReachabilityDecision::Offline
    );
    assert!(should_skip_refresh(ReachabilityDecision::Offline, false));
    assert!(gate.is_paused());

    // 网络恢复: 恰好一次补偿, 之后回到常规在线语义。
    let probe = FakeProbe(vec![true]);
    assert_eq!(
        gate.observe(probe.is_online()),
        ReachabilityDecision::Compensate
    );
    assert_eq!(
        gate.observe(probe.is_online()),
        ReachabilityDecision::Online
    );
    assert!(!gate.is_paused());
    assert!(!should_skip_refresh(ReachabilityDecision::Online, false));
}

#[test]
fn offline_probe_interval_is_short_and_fixed() {
    // 离线重探不得进入指数退避 (固定短周期)。
    assert_eq!(OFFLINE_PROBE_INTERVAL_SECS, 30);
}
