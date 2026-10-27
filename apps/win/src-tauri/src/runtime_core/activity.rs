//! 看板窗口激活、失焦与全局快捷键状态机 (C099); C128 由 runtime_core.rs 拆出。

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowAction {
    None,
    HideDashboardAndPersist,
    HideSettings,
    HidePreview,
}

pub fn window_action(label: &str, lost_focus: bool, close: bool) -> WindowAction {
    match (label, lost_focus, close) {
        ("dashboard", true, _) | ("dashboard", _, true) => WindowAction::HideDashboardAndPersist,
        ("settings", _, true) => WindowAction::HideSettings,
        ("preview", true, _) | ("preview", _, true) => WindowAction::HidePreview,
        _ => WindowAction::None,
    }
}

/// 面板唤出后的瞬态失焦保护期 (ms)：Windows 跨进程前台切换偶发瞬态 `Focused(false)`，
/// 保护期内忽略隐藏并重申焦点，防止按快捷键后面板“闪一下即消失”。
pub const SHOW_FOCUS_GRACE_MS: u64 = 180;

/// 全局热键防抖窗口 (ms)：距上一次生效的切换不足该窗口的触发一律忽略。
/// global-hotkey 在 Windows 恒以 `MOD_NOREPEAT` 注册, 长按不会产生连发事件;
/// 此窗口只兜底极短间隔的重复投递与连按抖动。
pub const HOTKEY_REPEAT_DEBOUNCE_MS: u64 = 250;

/// 被动失焦隐藏后的防重开窗口 (ms)：防止点击托盘或按下修饰键先触发 `Focused(false)` 收起面板、
/// 紧接着到达的点击/热键回调又把面板反向重新打开。
pub const UNFOCUS_REOPEN_GUARD_MS: u64 = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToggleDecision {
    Show,
    Hide,
    Ignore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UnfocusDecision {
    Hide,
    IgnoreTransientAndRefocus,
    AlreadyHidden,
}

/// 看板面板显隐、焦点保护期与全局热键防抖状态机 (C099)。
#[derive(Debug, Clone, Default)]
pub struct DashboardActivityState {
    pub panel_open: bool,
    pub last_shown_at: Option<std::time::Instant>,
    pub last_unfocus_at: Option<std::time::Instant>,
    pub last_hotkey_at: Option<std::time::Instant>,
    pub recording_hotkey: bool,
}

impl DashboardActivityState {
    pub fn record_shown(&mut self, now: std::time::Instant) {
        self.panel_open = true;
        self.last_shown_at = Some(now);
        self.last_unfocus_at = None;
    }

    pub fn record_explicit_hide(&mut self) {
        self.panel_open = false;
        self.last_shown_at = None;
        self.last_unfocus_at = None;
    }

    /// 切换录制态并返回切换前的取值, 供调用方判断是否需要真正注销/恢复热键。
    pub fn set_recording_hotkey(&mut self, recording: bool) -> bool {
        let was_recording = self.recording_hotkey;
        self.recording_hotkey = recording;
        was_recording
    }

    pub fn on_dashboard_unfocus(&mut self, now: std::time::Instant) -> UnfocusDecision {
        if !self.panel_open {
            return UnfocusDecision::AlreadyHidden;
        }
        if let Some(shown_at) = self.last_shown_at {
            if now.saturating_duration_since(shown_at)
                < std::time::Duration::from_millis(SHOW_FOCUS_GRACE_MS)
            {
                return UnfocusDecision::IgnoreTransientAndRefocus;
            }
        }
        self.panel_open = false;
        self.last_shown_at = None;
        self.last_unfocus_at = Some(now);
        UnfocusDecision::Hide
    }

    pub fn on_hotkey_pressed(
        &mut self,
        now: std::time::Instant,
        is_visible: bool,
    ) -> ToggleDecision {
        if self.recording_hotkey {
            return ToggleDecision::Ignore;
        }
        if let Some(last) = self.last_hotkey_at {
            if now.saturating_duration_since(last)
                < std::time::Duration::from_millis(HOTKEY_REPEAT_DEBOUNCE_MS)
            {
                return ToggleDecision::Ignore;
            }
        }
        self.last_hotkey_at = Some(now);
        if is_visible {
            self.record_explicit_hide();
            return ToggleDecision::Hide;
        }
        if let Some(unfocus_at) = self.last_unfocus_at.take() {
            if now.saturating_duration_since(unfocus_at)
                < std::time::Duration::from_millis(UNFOCUS_REOPEN_GUARD_MS)
            {
                return ToggleDecision::Ignore;
            }
        }
        self.record_shown(now);
        ToggleDecision::Show
    }

    pub fn on_tray_left_click(
        &mut self,
        now: std::time::Instant,
        is_visible: bool,
    ) -> ToggleDecision {
        if is_visible {
            self.record_explicit_hide();
            return ToggleDecision::Hide;
        }
        if let Some(unfocus_at) = self.last_unfocus_at.take() {
            if now.saturating_duration_since(unfocus_at)
                < std::time::Duration::from_millis(UNFOCUS_REOPEN_GUARD_MS)
            {
                return ToggleDecision::Ignore;
            }
        }
        self.record_shown(now);
        ToggleDecision::Show
    }
}

/// 录制态挂起 / 恢复已生效热键 (C099): `RegisterHotKey` 注册的组合键会被系统直接截走,
/// 不再投递给前台窗口, 因此录制期间必须真正注销, 设置页才能录到该组合键;
/// 退出录制再按已生效热键重新注册。录制态未变化或未设热键时不触碰注册表。
pub fn suspend_or_resume_hotkey<R, U>(
    current: &str,
    was_recording: bool,
    recording: bool,
    mut register: R,
    mut unregister: U,
) -> Result<(), String>
where
    R: FnMut(&str) -> Result<(), String>,
    U: FnMut(&str) -> Result<(), String>,
{
    if was_recording == recording || current.is_empty() {
        return Ok(());
    }
    if recording {
        unregister(current)
    } else {
        register(current)
    }
}

/// Stage replacement before unregistering the working shortcut; roll back either
/// registration or persistence failure. Empty means explicitly disable shortcuts.
pub fn replace_hotkey<R, U, S>(
    old: &str,
    new: &str,
    mut register: R,
    mut unregister: U,
    save: S,
) -> Result<(), String>
where
    R: FnMut(&str) -> Result<(), String>,
    U: FnMut(&str) -> Result<(), String>,
    S: FnOnce() -> Result<(), String>,
{
    if old == new {
        return save();
    }
    if !new.is_empty() {
        register(new)?;
    }
    if !old.is_empty() {
        if let Err(error) = unregister(old) {
            if !new.is_empty() {
                let _ = unregister(new);
            }
            return Err(error);
        }
    }
    if let Err(error) = save() {
        if !new.is_empty() {
            let _ = unregister(new);
        }
        if !old.is_empty() {
            register(old).map_err(|_| "HOTKEY_ROLLBACK_FAILED".to_owned())?;
        }
        return Err(error);
    }
    Ok(())
}
