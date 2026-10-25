//! 应用内软件更新 (T11, 07-软件更新 §4.2)。
//!
//! 链路: `tauri-plugin-updater` 走 latest.json 直链做可用性判定与 minisign 验签 +
//! NSIS 静默安装 (§4.2 R7); 自维护 `ureq` 拉同一份清单补 notes 与包体尺寸 (HEAD), 并在
//! 插件之前给出可分类的失败 (超时/离线/HTTP/清单无效)。表现层文案在
//! apps/win/src/update-presentation.js, 与 mac 共享 tests/fixtures/update-copy-parity。
//!
//! 纯逻辑段 (semver / 跳过判定 / 失败分类 / phase 序列化) 无 tauri 依赖, 可单测;
//! desktop 段为命令与状态机。

use serde::{Deserialize, Serialize};

/// 更新清单直链 (Releases latest-download, 302 到 CDN, 避开 GitHub API 匿名限流)。
/// 与 tauri.conf.json plugins.updater.endpoints[0] 必须一致 (check-win-frontend.mjs 锁定)。
#[cfg(feature = "desktop")]
const MANIFEST_URL: &str = "https://github.com/4everSivan/Bruce/releases/latest/download/latest.json";
#[cfg(feature = "desktop")]
const RELEASES_PAGE_URL: &str = "https://github.com/4everSivan/Bruce/releases/latest";

// ---------------------------------------------------------------- 纯逻辑

/// 检查失败分类 (表现层据此出说明行与状态行; serde 形态与共享 fixture phase 一致)。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UpdateFailureKind {
    TimedOut,
    Offline,
    HttpStatus,
    InvalidManifest,
}

/// 状态机 phase (JS `BruceUpdatePresentation.stageView` 的输入, 字段名逐字对齐共享 fixture)。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum UpdatePhase {
    Idle,
    Checking,
    Latest {
        #[serde(rename = "checkedAt")]
        checked_at: String,
    },
    Available,
    Downloading {
        #[serde(rename = "receivedBytes")]
        received_bytes: u64,
        #[serde(rename = "totalBytes")]
        total_bytes: Option<u64>,
    },
    Ready,
    Failed {
        failure: UpdateFailureKind,
        #[serde(rename = "httpStatus")]
        http_status: Option<u16>,
    },
    Skipped,
    Relaunching,
}

/// 发现的新版本元信息 (横幅呈现; 尺寸由 HEAD Content-Length 补齐)。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseInfo {
    pub version: String,
    pub notes: String,
    pub size_bytes: Option<u64>,
}

/// 三段 semver 比较; 解析失败按 (0.0.0) 处理, 容忍 `v` 前缀。
pub fn compare_semver(a: &str, b: &str) -> std::cmp::Ordering {
    parse_semver(a).cmp(&parse_semver(b))
}

fn parse_semver(value: &str) -> (u64, u64, u64) {
    let parts: Vec<&str> = value.trim().trim_start_matches('v').split('.').collect();
    let pick = |index: usize| -> u64 {
        parts
            .get(index)
            .map(|s| {
                s.chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect::<String>()
                    .parse()
                    .unwrap_or(0)
            })
            .unwrap_or(0)
    };
    (pick(0), pick(1), pick(2))
}

/// 跳过判定 (07 §4.2 R4): 跳过 vN 后, 远端仍是 vN → 不再提醒; 出现更新的版本 → 自动恢复。
pub enum SkipDecision {
    /// 未跳过或版本不同: 正常呈现, 且 offered > skipped 时应清除跳过记录。
    Offer { clear_skip: bool },
    /// offered == skipped: 维持「已跳过」呈现。
    Ignore,
}

pub fn skip_decision(offered: &str, skipped: Option<&str>) -> SkipDecision {
    match skipped {
        None => SkipDecision::Offer { clear_skip: false },
        Some(skipped) if compare_semver(offered, skipped) == std::cmp::Ordering::Equal => {
            SkipDecision::Ignore
        }
        Some(skipped) => SkipDecision::Offer {
            clear_skip: compare_semver(offered, skipped) == std::cmp::Ordering::Greater,
        },
    }
}

/// ureq 拉清单的失败分类: HTTP 状态码直接映射; 传输错误按 io kind 分超时/离线。
pub fn classify_transport_failure(error: &ureq::Error) -> (UpdateFailureKind, Option<u16>) {
    match error {
        ureq::Error::Status(code, _) => (UpdateFailureKind::HttpStatus, Some(*code)),
        ureq::Error::Transport(transport) => {
            let kind = transport.kind().to_string().to_lowercase();
            if kind.contains("dns") || kind.contains("connect") || kind.contains("connection") {
                (UpdateFailureKind::Offline, None)
            } else {
                (UpdateFailureKind::TimedOut, None)
            }
        }
    }
}

/// 本地时区 RFC3339 (秒级, 带偏移) —— 表现层按字符串民事日解析, 双端时区语义一致。
pub fn now_rfc3339_local() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, false)
}

/// manifest JSON → (版本, notes, Windows 资产 URL); 结构不符返回 None (invalidManifest)。
pub fn parse_manifest(body: &str) -> Option<(String, String, String)> {
    let value: serde_json::Value = serde_json::from_str(body).ok()?;
    let version = value.get("version")?.as_str()?.to_owned();
    let notes = value
        .get("notes")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_owned();
    let url = value
        .get("platforms")?
        .get("windows-x86_64")?
        .get("url")?
        .as_str()?
        .to_owned();
    Some((version, notes, url))
}

// ---------------------------------------------------------------- desktop: 状态机与命令

#[cfg(feature = "desktop")]
pub mod desktop_impl {
    use super::*;
    use crate::{paths, settings};
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;
    use tauri::{AppHandle, Emitter, Manager};
    use tauri_plugin_updater::{Update, UpdaterExt};

    /// 一次性安装失败码 (表现层 installFailureStatusLine 映射状态行)。
    pub const INSTALL_FAILURE_DOWNLOAD: &str = "downloadFailed";
    pub const INSTALL_FAILURE_SIGNATURE: &str = "signatureInvalid";
    pub const INSTALL_FAILURE_INSTALL: &str = "installFailed";

    pub struct UpdateStateInner {
        pub phase: UpdatePhase,
        pub release: Option<ReleaseInfo>,
        pub pending: Option<Update>,
        pub downloaded_bytes: Option<Vec<u8>>,
        pub cancel: Arc<AtomicBool>,
        pub downloading: bool,
        /// 一次性安装失败码; 发出即清 (状态行 toast 语义)。
        pub install_failure: Option<String>,
    }

    impl Default for UpdateStateInner {
        fn default() -> Self {
            Self {
                phase: UpdatePhase::Idle,
                release: None,
                pending: None,
                downloaded_bytes: None,
                cancel: Arc::new(AtomicBool::new(false)),
                downloading: false,
                install_failure: None,
            }
        }
    }

    #[derive(Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct UpdateSnapshot {
        pub phase: UpdatePhase,
        pub release: Option<ReleaseInfo>,
        pub local_version: Option<String>,
        pub last_check_at: Option<String>,
        pub skipped_version: Option<String>,
        pub auto_check: bool,
        pub install_failure: Option<String>,
    }

    pub type UpdateState = Mutex<UpdateStateInner>;

    fn local_version(app: &AppHandle) -> Option<String> {
        Some(app.package_info().version.to_string())
    }

    fn read_settings() -> settings::AppSettings {
        settings::load_settings(&paths::data_root())
    }

    /// 持久化更新字段: `skipped` 三态 —— None 不动 / Some(None) 清除 / Some(Some(v)) 记录。
    fn persist_update_fields(last_check_at: Option<String>, skipped: Option<Option<String>>) {
        let root = paths::data_root();
        let mut current = settings::load_settings(&root);
        if let Some(at) = last_check_at {
            current.update_last_check_at = Some(at);
        }
        if let Some(value) = skipped {
            current.update_skipped_version = value;
        }
        let _ = settings::save_settings(&root, &current);
    }

    fn snapshot(app: &AppHandle, inner: &mut UpdateStateInner) -> UpdateSnapshot {
        let settings = read_settings();
        UpdateSnapshot {
            phase: inner.phase.clone(),
            release: inner.release.clone(),
            local_version: local_version(app),
            last_check_at: settings.update_last_check_at,
            skipped_version: settings.update_skipped_version,
            auto_check: settings.auto_check_update,
            install_failure: inner.install_failure.take(),
        }
    }

    fn publish(app: &AppHandle, inner: &mut UpdateStateInner) {
        let payload = snapshot(app, inner);
        let _ = app.emit("update-state", &payload);
    }

    /// GET latest.json (ureq, 10 秒超时) + HEAD 补包体尺寸; 失败按分类返回。
    fn fetch_release_info() -> Result<ReleaseInfo, (UpdateFailureKind, Option<u16>)> {
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(10))
            .build();
        let body = match agent.get(MANIFEST_URL).call() {
            Ok(response) => response
                .into_string()
                .map_err(|_| (UpdateFailureKind::InvalidManifest, None))?,
            Err(error) => return Err(classify_transport_failure(&error)),
        };
        let (version, notes, url) =
            parse_manifest(&body).ok_or((UpdateFailureKind::InvalidManifest, None))?;
        // HEAD 只补展示尺寸, 失败静默为 None (不影响可用性判定)。
        let size_bytes = agent.head(&url).call().ok().and_then(|response| {
            response
                .header("Content-Length")
                .and_then(|v| v.parse::<u64>().ok())
        });
        Ok(ReleaseInfo { version, notes, size_bytes })
    }

    /// 核心检查: manifest 拉取 → 插件判定 (自身比对当前版本) → 跳过语义收敛。
    /// `manual` 为 false 时 (自动检查) 任何失败保持原相位、不进入 failed (07 §4.2 R5 静默)。
    pub fn run_check(app: &AppHandle, manual: bool) {
        if manual {
            let state = app.state::<UpdateState>();
            let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
            guard.phase = UpdatePhase::Checking;
            publish(app, &mut guard);
        }
        let release = match fetch_release_info() {
            Ok(info) => info,
            Err((failure, http_status)) => {
                if manual {
                    let state = app.state::<UpdateState>();
                    let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
                    guard.phase = UpdatePhase::Failed { failure, http_status };
                    publish(app, &mut guard);
                }
                return;
            }
        };
        // 插件检查 (endpoints/pubkey 出自 tauri.conf.json): Some(update) 即远端高于当前。
        let offered: Result<Option<Update>, ()> = match app.updater() {
            Ok(updater) => tauri::async_runtime::block_on(updater.check()).map_err(|_| ()),
            Err(_) => Err(()),
        };
        let offered = match offered {
            Ok(value) => value,
            Err(_) => {
                // 插件侧失败 (网络/配置): 手动时给可分类提示, 自动静默。
                if manual {
                    let state = app.state::<UpdateState>();
                    let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
                    guard.phase = UpdatePhase::Failed {
                        failure: UpdateFailureKind::InvalidManifest,
                        http_status: None,
                    };
                    publish(app, &mut guard);
                }
                return;
            }
        };
        let checked_at = now_rfc3339_local();
        let state = app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        match offered {
            None => {
                guard.phase = UpdatePhase::Latest { checked_at: checked_at.clone() };
                guard.release = None;
                guard.pending = None;
            }
            Some(update) => {
                let offered_version = update.version.clone();
                let skipped = read_settings().update_skipped_version;
                match skip_decision(&offered_version, skipped.as_deref()) {
                    SkipDecision::Ignore => {
                        guard.phase = UpdatePhase::Skipped;
                        guard.release = Some(release);
                        guard.pending = Some(update);
                    }
                    SkipDecision::Offer { clear_skip } => {
                        if clear_skip {
                            persist_update_fields(None, Some(None));
                        }
                        // notes 优先插件读取的清单值, 兜底自取 manifest。
                        let mut info = release;
                        if info.notes.is_empty() {
                            if let Some(body) = update.body.clone() {
                                info.notes = body;
                            }
                        }
                        guard.phase = UpdatePhase::Available;
                        guard.release = Some(info);
                        guard.pending = Some(update);
                    }
                }
            }
        }
        persist_update_fields(Some(checked_at), None);
        publish(app, &mut guard);
    }

    /// 下载 (进度事件节流 ~120ms)。插件 download API 不支持中止传输 —— 「取消」语义为
    /// 停止进度呈现并在完成后丢弃字节 (带宽浪费上界为单包体积, ~7MB)。
    pub fn run_download(app: &AppHandle) {
        let (update, cancel) = {
            let state = app.state::<UpdateState>();
            let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
            if guard.downloading || guard.pending.is_none() {
                return;
            }
            guard.downloading = true;
            guard.cancel = Arc::new(AtomicBool::new(false));
            guard.phase = UpdatePhase::Downloading { received_bytes: 0, total_bytes: None };
            publish(app, &mut guard);
            (guard.pending.take().expect("checked above"), guard.cancel.clone())
        };
        let app_for_chunk = app.clone();
        let cancel_in_chunk = cancel.clone();
        let mut received: u64 = 0;
        let mut total: Option<u64> = None;
        let mut last_emit = std::time::Instant::now();
        let result = tauri::async_runtime::block_on(update.download(
            move |chunk, content_total| {
                if cancel_in_chunk.load(Ordering::Relaxed) {
                    return;
                }
                received += chunk as u64;
                if let Some(t) = content_total {
                    total = Some(t);
                }
                if last_emit.elapsed() >= Duration::from_millis(120) {
                    last_emit = std::time::Instant::now();
                    let state = &app_for_chunk.state::<UpdateState>();
                    let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
                    guard.phase =
                        UpdatePhase::Downloading { received_bytes: received, total_bytes: total };
                    publish(&app_for_chunk, &mut guard);
                }
            },
            || {},
        ));
        let cancelled = cancel.load(Ordering::Relaxed);
        let state = app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        guard.downloading = false;
        guard.pending = Some(update);
        guard.phase = UpdatePhase::Available;
        if !cancelled {
            match result {
                Ok(bytes) => {
                    guard.phase = UpdatePhase::Ready;
                    // 就绪态需要字节随 pending 一起交给 install —— 交由调用方线程内传递,
                    // 这里先落在状态上 (见 run_install 的读取)。
                    guard.downloaded_bytes = Some(bytes);
                }
                Err(_) => {
                    guard.install_failure = Some(INSTALL_FAILURE_DOWNLOAD.to_owned());
                }
            }
        }
        publish(app, &mut guard);
    }

    /// 安装并重启: 插件先 minisign 验签再执行 NSIS 静默安装; 失败按签名/安装分类回退。
    pub fn run_install(app: &AppHandle) {
        let (update, bytes) = {
            let state = app.state::<UpdateState>();
            let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
            match (guard.pending.take(), guard.downloaded_bytes.take()) {
                (Some(update), Some(bytes)) => {
                    guard.phase = UpdatePhase::Relaunching;
                    publish(app, &mut guard);
                    (update, bytes)
                }
                _ => return,
            }
        };
        if let Err(error) = update.install(&bytes) {
            let state = app.state::<UpdateState>();
            let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
            guard.pending = Some(update);
            guard.phase = UpdatePhase::Available;
            let message = error.to_string().to_lowercase();
            guard.install_failure = Some(
                if message.contains("sign") || message.contains("verify") {
                    INSTALL_FAILURE_SIGNATURE
                } else {
                    INSTALL_FAILURE_INSTALL
                }
                .to_owned(),
            );
            publish(app, &mut guard);
            return;
        }
        // NSIS 安装器接管进程; 万一返回则显式重启兜底。
        app.restart();
    }

    pub fn run_cancel(app: &AppHandle) {
        let state = app.state::<UpdateState>();
        let guard = state.lock().unwrap_or_else(|p| p.into_inner());
        guard.cancel.store(true, Ordering::Relaxed);
    }

    pub fn run_dismiss_ready(app: &AppHandle) {
        let state = app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        if matches!(guard.phase, UpdatePhase::Ready) {
            guard.phase = UpdatePhase::Available;
            publish(app, &mut guard);
        }
    }

    pub fn run_skip(app: &AppHandle, version: String) {
        persist_update_fields(None, Some(Some(version)));
        let state = app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        guard.phase = UpdatePhase::Skipped;
        publish(app, &mut guard);
    }

    pub fn run_unskip(app: &AppHandle) {
        persist_update_fields(None, Some(None));
        let state = app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        if matches!(guard.phase, UpdatePhase::Skipped) {
            guard.phase = UpdatePhase::Available;
        }
        publish(app, &mut guard);
    }

    /// 自动检查 (07 §4.2 R5): 启动 30 秒后首查, 此后每 24 小时一次; 失败完全静默。
    pub fn spawn_auto_check(app: AppHandle) {
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(30));
            loop {
                if read_settings().auto_check_update {
                    run_check(&app, false);
                }
                std::thread::sleep(Duration::from_secs(24 * 60 * 60));
            }
        });
    }

    // ------------------------------------------------------------ 命令

    #[tauri::command]
    pub fn update_state(app: AppHandle) -> Result<UpdateSnapshot, String> {
        let state = &app.state::<UpdateState>();
        let mut guard = state.lock().unwrap_or_else(|p| p.into_inner());
        Ok(snapshot(&app, &mut guard))
    }

    #[tauri::command]
    pub fn update_check(app: AppHandle, manual: Option<bool>) -> Result<(), String> {
        let manual = manual.unwrap_or(true);
        std::thread::spawn(move || run_check(&app, manual));
        Ok(())
    }

    #[tauri::command]
    pub fn update_download(app: AppHandle) -> Result<(), String> {
        std::thread::spawn(move || run_download(&app));
        Ok(())
    }

    #[tauri::command]
    pub fn update_install(app: AppHandle) -> Result<(), String> {
        std::thread::spawn(move || run_install(&app));
        Ok(())
    }

    #[tauri::command]
    pub fn update_cancel(app: AppHandle) -> Result<(), String> {
        run_cancel(&app);
        Ok(())
    }

    #[tauri::command]
    pub fn update_dismiss_ready(app: AppHandle) -> Result<(), String> {
        run_dismiss_ready(&app);
        Ok(())
    }

    #[tauri::command]
    pub fn update_skip(app: AppHandle, version: String) -> Result<(), String> {
        run_skip(&app, version);
        Ok(())
    }

    #[tauri::command]
    pub fn update_unskip(app: AppHandle) -> Result<(), String> {
        run_unskip(&app);
        Ok(())
    }

    /// 打开发布页 (查看发布页 ↗ / 手动下载 ↗)。
    #[tauri::command]
    pub fn open_release_page() -> Result<(), String> {
        open_release_url(RELEASES_PAGE_URL)
    }

    #[cfg(windows)]
    fn open_release_url(url: &str) -> Result<(), String> {
        use windows_sys::Win32::UI::Shell::ShellExecuteW;
        let operation: Vec<u16> = "open\0".encode_utf16().collect();
        let file: Vec<u16> = format!("{url}\0").encode_utf16().collect();
        let result = unsafe {
            ShellExecuteW(
                std::ptr::null_mut(),
                operation.as_ptr(),
                file.as_ptr(),
                std::ptr::null(),
                std::ptr::null(),
                1,
            )
        };
        if result as isize > 32 {
            Ok(())
        } else {
            Err("OPEN_PAGE_FAILED".to_owned())
        }
    }

    #[cfg(not(windows))]
    fn open_release_url(_url: &str) -> Result<(), String> {
        // 非 Windows 开发机仅跑测试, 真实打开由 Windows 侧承担 (与 C084 口径一致)。
        Ok(())
    }
}

// ---------------------------------------------------------------- 单测 (纯逻辑, 不触网)

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_compares_three_segments() {
        assert_eq!(compare_semver("0.13.0", "0.12.2"), std::cmp::Ordering::Greater);
        assert_eq!(compare_semver("0.12.2", "0.12.2"), std::cmp::Ordering::Equal);
        assert_eq!(compare_semver("v0.12.2", "0.12.2"), std::cmp::Ordering::Equal);
        assert_eq!(compare_semver("1.0.0", "0.99.99"), std::cmp::Ordering::Greater);
        assert_eq!(compare_semver("0.12.10", "0.12.9"), std::cmp::Ordering::Greater);
    }

    #[test]
    fn skip_decision_restores_on_newer_offer() {
        // 未跳过 → 正常呈现。
        assert!(matches!(skip_decision("0.13.0", None), SkipDecision::Offer { clear_skip: false }));
        // 跳过同版本 → 不提醒。
        assert!(matches!(skip_decision("0.13.0", Some("0.13.0")), SkipDecision::Ignore));
        // 出现更新版本 → 自动恢复 (清除跳过记录)。
        assert!(matches!(
            skip_decision("0.14.0", Some("0.13.0")),
            SkipDecision::Offer { clear_skip: true }
        ));
    }

    #[test]
    fn phase_serializes_to_fixture_shape() {
        // 与 tests/fixtures/update-copy-parity/cases.json 的 phase 字段逐字一致。
        let downloading: serde_json::Value = serde_json::to_value(UpdatePhase::Downloading {
            received_bytes: 3234567,
            total_bytes: Some(7100000),
        })
        .unwrap();
        assert_eq!(
            downloading,
            serde_json::json!({"kind": "downloading", "receivedBytes": 3234567, "totalBytes": 7100000})
        );
        let failed: serde_json::Value = serde_json::to_value(UpdatePhase::Failed {
            failure: UpdateFailureKind::HttpStatus,
            http_status: Some(404),
        })
        .unwrap();
        assert_eq!(
            failed,
            serde_json::json!({"kind": "failed", "failure": "httpStatus", "httpStatus": 404})
        );
        let unknown_total: serde_json::Value = serde_json::to_value(UpdatePhase::Downloading {
            received_bytes: 3234567,
            total_bytes: None,
        })
        .unwrap();
        assert_eq!(unknown_total["totalBytes"], serde_json::json!(null));
    }

    #[test]
    fn manifest_parser_extracts_windows_platform() {
        // fixture: tests/fixtures/update-manifest/latest.json (T10 随卡入库)。
        let body = std::fs::read_to_string(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../../tests/fixtures/update-manifest/latest.json"
        ))
        .expect("fixture 不存在");
        let (version, _notes, url) = parse_manifest(&body).expect("清单应可解析");
        assert!(version.split('.').count() == 3, "版本应为三段: {version}");
        assert!(url.starts_with("https://github.com/"), "平台 URL 应为 GitHub 直链: {url}");
        assert!(url.contains("setup.exe"), "Windows 平台应指向 NSIS 安装包: {url}");
        // 结构不符 → invalidManifest 语义 (返回 None)。
        assert!(parse_manifest("{\"version\": \"1.0.0\"}").is_none());
    }

    #[test]
    fn rfc3339_local_carries_offset() {
        let stamp = now_rfc3339_local();
        // 秒级精度 + 偏移 (Z 或 ±HH:MM); 表现层按民事日字符串解析依赖该形态。
        assert!(stamp.matches(':').count() >= 2, "RFC3339 形态异常: {stamp}");
        assert!(stamp.ends_with('Z') || stamp.contains("+") || stamp.contains("-"), "缺时区偏移: {stamp}");
    }
}
