//! 安全、可见的启动与看板显示故障提示 (C150)。
//!
//! 提示只由固定阶段码生成；不接收或输出原始错误文本、路径、账号或凭证。

use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FailureStage {
    TauriInitialization,
    DashboardMissing,
    DashboardShow,
}

impl FailureStage {
    pub const fn code(self) -> &'static str {
        match self {
            Self::TauriInitialization => "TAURI_INIT_FAILED",
            Self::DashboardMissing => "DASHBOARD_WINDOW_MISSING",
            Self::DashboardShow => "DASHBOARD_SHOW_FAILED",
        }
    }

    const fn description(self) -> &'static str {
        match self {
            Self::TauriInitialization => "Bruce 无法完成应用初始化。",
            Self::DashboardMissing => "Bruce 找不到看板窗口。",
            Self::DashboardShow => "Bruce 无法显示看板。",
        }
    }
}

/// Build a user-facing message from a fixed stage only. Native/API error text is
/// deliberately not accepted by this function.
pub fn user_message(stage: FailureStage) -> String {
    format!(
        "{}\n诊断码：{}\n请尝试重新启动 Bruce；如仍失败，请提供此诊断码。",
        stage.description(),
        stage.code()
    )
}

/// Maps a failed Tauri initialization/run result to a safe fixed stage. The
/// underlying error is inspected only as success/failure and never formatted.
pub fn initialization_failure<T, E>(result: &Result<T, E>) -> Option<FailureStage> {
    result
        .as_ref()
        .err()
        .map(|_| FailureStage::TauriInitialization)
}

/// Classify only missing/show failures. A focus failure is intentionally
/// nonfatal once the dashboard has been shown.
pub fn classify_dashboard_show(window_exists: bool, show_succeeded: bool) -> Option<FailureStage> {
    if !window_exists {
        Some(FailureStage::DashboardMissing)
    } else if !show_succeeded {
        Some(FailureStage::DashboardShow)
    } else {
        None
    }
}

#[derive(Debug, Default)]
pub struct PromptGate(AtomicBool);

impl PromptGate {
    /// Returns true once per gate. Later errors cannot create an unbounded
    /// sequence of native dialogs.
    pub fn claim(&self) -> bool {
        !self.0.swap(true, Ordering::AcqRel)
    }
}

static NATIVE_PROMPT_GATE: PromptGate = PromptGate(AtomicBool::new(false));

/// Present one native prompt without dispatching to or waiting for Tauri's main
/// thread. Failure to display the prompt is ignored and never reported again.
pub fn show_native_failure(stage: FailureStage) {
    if NATIVE_PROMPT_GATE.claim() {
        platform::show(stage);
    }
}

#[cfg(windows)]
mod platform {
    use super::{user_message, FailureStage};
    use std::iter;
    use std::ptr;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        MessageBoxW, MB_ICONERROR, MB_OK, MB_SETFOREGROUND, MB_TOPMOST,
    };

    pub(super) fn show(stage: FailureStage) {
        let title: Vec<u16> = "Bruce 启动诊断"
            .encode_utf16()
            .chain(iter::once(0))
            .collect();
        let message: Vec<u16> = user_message(stage)
            .encode_utf16()
            .chain(iter::once(0))
            .collect();

        // MessageBoxW is the native, WebView-independent user-visible fallback.
        // Ignore its return value to avoid recursive reporting if Windows cannot
        // display a dialog (for example, during session shutdown).
        unsafe {
            let _ = MessageBoxW(
                ptr::null_mut(),
                message.as_ptr(),
                title.as_ptr(),
                MB_OK | MB_ICONERROR | MB_SETFOREGROUND | MB_TOPMOST,
            );
        }
    }
}

#[cfg(not(windows))]
mod platform {
    use super::FailureStage;

    pub(super) fn show(_stage: FailureStage) {}
}

#[cfg(test)]
mod tests {
    use super::{
        classify_dashboard_show, initialization_failure, user_message, FailureStage, PromptGate,
    };

    #[test]
    fn dashboard_failure_classification_ignores_nonfatal_focus_errors() {
        assert_eq!(
            classify_dashboard_show(false, false),
            Some(FailureStage::DashboardMissing)
        );
        assert_eq!(
            classify_dashboard_show(true, false),
            Some(FailureStage::DashboardShow)
        );
        assert_eq!(
            classify_dashboard_show(true, true),
            None,
            "a successful show is not a display failure; focus is nonfatal"
        );
    }

    #[test]
    fn initialization_failures_map_to_a_fixed_code_without_formatting_error_text() {
        let sensitive_error = Err::<(), _>("C:\\Users\\sivan\\token-secret account-secret");
        assert_eq!(
            initialization_failure(&sensitive_error),
            Some(FailureStage::TauriInitialization)
        );
        assert_eq!(initialization_failure(&Ok::<(), &str>(())), None);
    }

    #[test]
    fn native_messages_use_only_fixed_codes_and_safe_text() {
        let cases = [
            (FailureStage::TauriInitialization, "TAURI_INIT_FAILED"),
            (FailureStage::DashboardMissing, "DASHBOARD_WINDOW_MISSING"),
            (FailureStage::DashboardShow, "DASHBOARD_SHOW_FAILED"),
        ];
        for (stage, expected_code) in cases {
            let message = user_message(stage);
            assert_eq!(stage.code(), expected_code);
            assert!(message.contains(expected_code));
            assert!(message.contains("请尝试重新启动 Bruce"));
            assert!(!message.contains("C:\\Users\\"));
            assert!(!message.contains("token-secret"));
            assert!(!message.contains("account-secret"));
        }
    }

    #[test]
    fn prompt_gate_allows_only_one_native_dialog() {
        let gate = PromptGate::default();
        assert!(gate.claim());
        assert!(!gate.claim());
        assert!(PromptGate::default().claim());
    }
}
