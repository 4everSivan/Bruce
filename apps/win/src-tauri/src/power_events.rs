//! Windows 睡眠唤醒通知 (C264, design/05 规则 39)。
//!
//! 经 `PowerRegisterSuspendResumeNotification` 注册系统回调；收到
//! `PBT_APMRESUMEAUTOMATIC` / `PBT_APMRESUMESUSPEND` 时通知调度器做一次自动刷新，
//! 60s 内重复触发由调度器去重。回调只向 Tauri 状态投递一个唤醒信号，不做任何 I/O。

use tauri::AppHandle;

#[cfg(windows)]
#[allow(unsafe_code)]
pub fn start(app: AppHandle) {
    use std::ffi::c_void;
    use windows_sys::Win32::System::Power::{
        PowerRegisterSuspendResumeNotification, DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::DEVICE_NOTIFY_CALLBACK;

    unsafe extern "system" fn callback(
        context: *const c_void,
        event_type: u32,
        _setting: *const c_void,
    ) -> u32 {
        const PBT_APMRESUMEAUTOMATIC: u32 = 0x0012;
        const PBT_APMRESUMESUSPEND: u32 = 0x0007;
        if (event_type == PBT_APMRESUMEAUTOMATIC || event_type == PBT_APMRESUMESUSPEND)
            && !context.is_null()
        {
            // SAFETY: context 由下方 Box::into_raw 泄漏，注册期间始终有效。
            let app = unsafe { &*(context as *const AppHandle) };
            if let Some(control) = app.try_state::<crate::scheduler::SchedulerControl>() {
                control.request_wake_refresh();
            }
        }
        // ERROR_SUCCESS；回调返回值语义见 DEVICE_NOTIFY_CALLBACK_ROUTINE。
        0
    }

    let mut params = Box::new(DEVICE_NOTIFY_SUBSCRIBE_PARAMETERS {
        Callback: Some(callback),
        // 泄漏一份 AppHandle 供系统回调长期持有；进程退出时随进程回收。
        Context: Box::into_raw(Box::new(app)) as *mut c_void,
    });
    let mut handle: *mut c_void = std::ptr::null_mut();
    let result = unsafe {
        PowerRegisterSuspendResumeNotification(
            DEVICE_NOTIFY_CALLBACK,
            params.as_mut() as *mut _ as *mut c_void,
            &mut handle,
        )
    };
    if result == 0 {
        // 注册句柄需要在进程生命周期内保持；泄漏参数块以满足回调上下文有效期。
        std::mem::forget(params);
    } else if !params.Context.is_null() {
        // 注册失败：回收上下文，避免泄漏。
        drop(unsafe { Box::from_raw(params.Context as *mut AppHandle) });
    }
}

#[cfg(not(windows))]
pub fn start(_app: AppHandle) {}
