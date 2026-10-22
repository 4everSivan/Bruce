//! 刷新调度的网络可达性闸门 (C076, 对齐 mac `NetworkReachability` 与 RefreshScheduler
//! 的 `offlinePaused` 分支): 离线不发起自动刷新、不重试; 联网后单次补偿。
//!
//! 纯逻辑与平台探针解耦: `ReachabilityGate` 只做状态机, 探针以 trait 注入 ——
//! 生产走 Windows 连通性 API, 测试注入假探针, 任意平台可跑。

/// 网络可达性只读探针 (仅作刷新闸门, 不参与数据展示或采集结果判定)。
pub trait NetworkProbe: Send + Sync {
    fn is_online(&self) -> bool;
}

/// 生产探针: Windows 走 `InternetGetConnectedState`; 其它平台恒在线 (mac 开发/CI
/// 无该 API, 与 mac「首个真实 path 更新前 fail-open」同语义, 不误挡刷新)。
pub struct SystemNetworkProbe;

impl NetworkProbe for SystemNetworkProbe {
    fn is_online(&self) -> bool {
        #[cfg(windows)]
        {
            let mut flags: u32 = 0;
            // 返回 0 表示无连接; 保守判定离线 (不排重试)。flags 仅作 API 出参, 不使用。
            unsafe {
                windows_sys::Win32::Networking::WinInet::InternetGetConnectedState(&mut flags, 0)
                    != 0
            }
        }
        #[cfg(not(windows))]
        {
            true
        }
    }
}

/// 单轮调度决策。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReachabilityDecision {
    /// 在线: 正常发起自动刷新。
    Online,
    /// 离线: 跳过本轮, 不累加 retries, 不进入退避。
    Offline,
    /// 由离线跃迁到在线: 本轮刷新即离线期间唯一的一次补偿 (不补发积压的多轮)。
    Compensate,
}

/// 可达性闸门状态机: 记住上次观测, 在离线→在线跃迁时给出补偿信号。
/// 初始视为在线 (fail-open, 对齐 mac 首帧前不误挡刷新)。
pub struct ReachabilityGate {
    was_online: bool,
}

impl Default for ReachabilityGate {
    fn default() -> Self {
        Self::new()
    }
}

impl ReachabilityGate {
    pub fn new() -> Self {
        Self { was_online: true }
    }

    /// 观测一次可达性, 返回本轮决策并记住本次观测。
    pub fn observe(&mut self, online: bool) -> ReachabilityDecision {
        let decision = match (self.was_online, online) {
            (_, false) => ReachabilityDecision::Offline,
            (false, true) => ReachabilityDecision::Compensate,
            (true, true) => ReachabilityDecision::Online,
        };
        self.was_online = online;
        decision
    }

    /// 是否处于「自动刷新被断网闸门拦下」状态。
    pub fn is_paused(&self) -> bool {
        !self.was_online
    }
}

/// 离线期间的重探间隔 (秒): 短周期以便尽快发现网络恢复, 且不进入指数退避。
pub const OFFLINE_PROBE_INTERVAL_SECS: u64 = 30;

/// 离线状态码 (与既有 SNAPSHOT_* 诊断码同风格)。
pub const NETWORK_UNAVAILABLE: &str = "NETWORK_UNAVAILABLE";

/// 本轮是否跳过刷新: 离线且非手动才跳过 (手动刷新语义不变, 离线仍执行一次)。
pub fn should_skip_refresh(decision: ReachabilityDecision, manual: bool) -> bool {
    decision == ReachabilityDecision::Offline && !manual
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gate_fails_open_before_first_observation() {
        // 首个真实观测前不误挡刷新 (初始视为在线)。
        assert!(!ReachabilityGate::new().is_paused());
        let mut gate = ReachabilityGate::new();
        assert_eq!(gate.observe(true), ReachabilityDecision::Online);
    }

    #[test]
    fn gate_skips_while_offline_without_compensation() {
        let mut gate = ReachabilityGate::new();
        assert_eq!(gate.observe(false), ReachabilityDecision::Offline);
        assert_eq!(
            gate.observe(false),
            ReachabilityDecision::Offline,
            "持续离线不产生补偿"
        );
        assert!(gate.is_paused());
    }

    #[test]
    fn gate_compensates_exactly_once_on_reconnect() {
        let mut gate = ReachabilityGate::new();
        assert_eq!(gate.observe(false), ReachabilityDecision::Offline);
        assert_eq!(gate.observe(true), ReachabilityDecision::Compensate);
        assert_eq!(
            gate.observe(true),
            ReachabilityDecision::Online,
            "补偿只发生一次"
        );
        assert!(!gate.is_paused());
    }

    #[test]
    fn system_probe_is_online_off_windows() {
        // mac 开发/CI: 探针 fail-open, 不误挡刷新。
        #[cfg(not(windows))]
        assert!(SystemNetworkProbe.is_online());
    }

    #[test]
    fn only_offline_auto_refresh_is_skipped() {
        use ReachabilityDecision::{Compensate, Offline, Online};
        assert!(should_skip_refresh(Offline, false), "离线自动刷新跳过");
        assert!(
            !should_skip_refresh(Offline, true),
            "手动刷新离线仍执行一次"
        );
        assert!(!should_skip_refresh(Online, false));
        assert!(!should_skip_refresh(Compensate, false));
    }
}
