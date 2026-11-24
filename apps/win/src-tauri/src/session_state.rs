//! Windows 会话锁屏状态 (C264)。
//!
//! 锁屏期间挂起外部额度查询（与 mac `ScreenLockStateProviding` 同语义），
//! 解锁后由下一轮调度恢复。查询失败一律按「未锁屏」处理，避免误抑制采集。

/// 当前会话是否处于锁屏状态；非 Windows 平台恒为 false。
#[cfg(windows)]
#[allow(unsafe_code)]
pub fn session_locked() -> bool {
    use windows_sys::Win32::System::RemoteDesktop::{
        WTSFreeMemory, WTSQuerySessionInformationW, WTSSessionInfoEx, WTSINFOEXW,
        WTS_CURRENT_SESSION, WTS_SESSIONSTATE_LOCK,
    };

    let mut buffer: *mut u16 = std::ptr::null_mut();
    let mut bytes = 0u32;
    // WTS_CURRENT_SERVER_HANDLE 为空句柄; 查询失败不阻断采集。
    let ok = unsafe {
        WTSQuerySessionInformationW(
            std::ptr::null_mut(),
            WTS_CURRENT_SESSION,
            WTSSessionInfoEx,
            &mut buffer,
            &mut bytes,
        )
    };
    if ok == 0 || buffer.is_null() {
        return false;
    }
    let locked = unsafe {
        let info = &*(buffer as *const WTSINFOEXW);
        info.Level == 1 && info.Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK as i32
    };
    unsafe { WTSFreeMemory(buffer.cast()) };
    locked
}

#[cfg(not(windows))]
pub fn session_locked() -> bool {
    false
}

#[cfg(all(test, not(windows)))]
mod tests {
    /// 非 Windows 平台必须恒为未锁屏 (macOS 开发机/测试环境)。
    #[test]
    fn non_windows_defaults_to_unlocked() {
        assert!(!super::session_locked());
    }
}
