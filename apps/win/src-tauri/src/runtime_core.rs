//! Pure refresh, window and snapshot policies; no GUI, network or user-home access.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::{DateTime, FixedOffset};
use collector_domain::{AgentUsageArtifact, BridgeResponse, ResponseStatus};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefreshOutcome {
    Success,
    Failed { rate_limited: bool },
}

/// A retry replaces the normal interval. There is exactly one interruptible wait.
pub fn next_delay(outcome: RefreshOutcome, retries: u32, interval: u64, backoff: u64) -> u64 {
    if matches!(outcome, RefreshOutcome::Failed { .. }) && retries <= 5 {
        backoff
    } else {
        interval
    }
}

/// Backoff retries retain the manual origin; the next normal cycle may notify again.
pub fn manual_alert_reason(input: bool, retries: u32, previous: bool) -> bool {
    input || (retries > 0 && retries <= 5 && previous)
}

pub fn provider_id(service: &Value) -> &str {
    let id = service.get("id").and_then(Value::as_str).unwrap_or("");
    if id.starts_with("codex") {
        "codex"
    } else if id.starts_with("claude") {
        "claude"
    } else if id.starts_with("kimi") {
        "kimi"
    } else if id.starts_with("deepseek") {
        "deepseek"
    } else if id.starts_with("volc") {
        "volcengine"
    } else if id.starts_with("zhipu") || id.starts_with("glm") {
        "zhipu"
    } else if id.starts_with("grok") {
        "grok"
    } else if id.starts_with("opencode") {
        "opencodeGo"
    } else if id.starts_with("step") {
        "stepfun"
    } else if id.starts_with("cline") {
        "cline"
    } else {
        id
    }
}

fn qualified(service: &Value) -> bool {
    let captured = service
        .get("capturedAt")
        .and_then(Value::as_str)
        .and_then(|text| DateTime::parse_from_rfc3339(text).ok())
        .is_some();
    if !captured {
        return false;
    }
    match service.get("freshness").and_then(Value::as_str) {
        Some("fresh" | "stale") => true,
        Some(_) => false,
        None => matches!(
            service.get("status").and_then(Value::as_str),
            Some("ok" | "")
        ),
    }
}

/// Only IDs returned by this collection survive. Removed accounts cannot reappear
/// from history; failed current accounts may borrow qualified old display fields.
pub fn merge_snapshot(previous: Option<&Value>, current: &Value) -> Value {
    let mut result = current.clone();
    let previous_services: BTreeMap<&str, &Value> = previous
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|service| {
            service
                .get("id")
                .and_then(Value::as_str)
                .map(|id| (id, service))
        })
        .collect();
    if let Some(services) = result.get_mut("services").and_then(Value::as_array_mut) {
        for service in services {
            if !service.is_object() {
                continue;
            }
            let status = service.get("status").and_then(Value::as_str).unwrap_or("");
            if matches!(status, "ok" | "empty") {
                service["freshness"] = json!("fresh");
                continue;
            }
            let old = service
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| previous_services.get(id))
                .filter(|old| qualified(old));
            if let Some(old) = old {
                for field in [
                    "windows",
                    "balance",
                    "currency",
                    "plan",
                    "extra",
                    "kind",
                    "capturedAt",
                ] {
                    if let Some(value) = old.get(field) {
                        service[field] = value.clone();
                    }
                }
                service["freshness"] = json!("stale");
            } else {
                service["freshness"] = json!("unavailable");
                if let Some(object) = service.as_object_mut() {
                    object.remove("capturedAt");
                }
            }
        }
    }
    result
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotState {
    artifact: Option<Value>,
    pub phase: String,
    pub last_success_at: Option<String>,
    pub error: Option<String>,
    #[serde(default)]
    diagnostics: Vec<String>,
}

impl Default for SnapshotState {
    fn default() -> Self {
        Self {
            artifact: None,
            phase: "idle".into(),
            last_success_at: None,
            error: None,
            diagnostics: vec![],
        }
    }
}

/// 清理快照: 仅删除本应用的持久化文件 (与 mac「清理用量缓存」等价 —— 不动配置与
/// 凭证); 文件不存在视为已清理, 幂等。下次刷新会重新采集并重建快照。
pub fn clear_snapshot(root: &Path) -> Result<(), String> {
    match fs::remove_file(root.join("snapshot.json")) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.to_string()),
    }
}

/// 按模型汇总今日用量 (agent.models: 模型名 -> tokens)。供设置页「模型计费」表使用。
pub fn model_usage(artifact: &Value) -> Vec<Value> {
    let mut totals: BTreeMap<String, i64> = BTreeMap::new();
    for agent in artifact
        .get("agents")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        for (model, total) in agent
            .get("models")
            .and_then(Value::as_object)
            .into_iter()
            .flatten()
        {
            *totals.entry(model.clone()).or_default() += total.as_i64().unwrap_or(0);
        }
    }
    let mut rows: Vec<(String, i64)> = totals.into_iter().collect();
    // 用量降序, 并列按模型名升序 (与 mac 表格排序一致)
    rows.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    rows.into_iter()
        .map(|(model, tokens)| json!({"model": model, "tokens": tokens}))
        .collect()
}

/// 账单 CSV: 列与 mac `AppModel.billingReportCSV` 逐列一致 —— 头部注释 (数据时间) +
/// 逐 agent 逐日 token 段 + 今日成本段 (USD/CNY) + 合计; 无定价数据时输出占位行。
pub fn billing_csv(artifact: &Value) -> Option<String> {
    let agents = artifact.get("agents")?.as_array()?;
    let generated_at = artifact
        .get("generatedAt")
        .and_then(Value::as_str)
        .unwrap_or("");
    let mut lines: Vec<String> = vec![
        "# Bruce 账单导出".to_owned(),
        format!("# 数据时间,{generated_at}"),
        String::new(),
        "日期,Agent,输入 tokens,输出 tokens,合计 tokens".to_owned(),
    ];
    for agent in agents {
        let name = agent.get("name").and_then(Value::as_str).unwrap_or("");
        for day in agent
            .get("daily")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            lines.push(
                [
                    day.get("date")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_owned(),
                    csv_field(name),
                    day.get("input")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        .to_string(),
                    day.get("output")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        .to_string(),
                    day.get("total")
                        .and_then(Value::as_i64)
                        .unwrap_or(0)
                        .to_string(),
                ]
                .join(","),
            );
        }
    }
    lines.push(String::new());
    lines.push(format!(
        "# 今日成本 (CNY 按汇率 {} 换算)",
        bruce_win_viewmodel::format::CNY_PER_USD
    ));
    lines.push("Agent,成本 USD,成本 CNY".to_owned());
    let mut has_cost = false;
    for agent in agents {
        let Some(usd) = agent.get("todayCostUsd").and_then(Value::as_f64) else {
            continue;
        };
        has_cost = true;
        lines.push(
            [
                csv_field(agent.get("name").and_then(Value::as_str).unwrap_or("")),
                format!("{usd:.4}"),
                format!("{:.4}", usd * bruce_win_viewmodel::format::CNY_PER_USD),
            ]
            .join(","),
        );
    }
    if let Some(total) = artifact.get("totalCostUsd").and_then(Value::as_f64) {
        has_cost = true;
        lines.push(format!(
            "合计,{:.4},{:.4}",
            total,
            total * bruce_win_viewmodel::format::CNY_PER_USD
        ));
    }
    if !has_cost {
        lines.push("无定价数据".to_owned());
    }
    Some(lines.join("\n") + "\n")
}

/// CSV 字段转义 (与 mac `csvField` 同规则: 含逗号/引号/换行才加引号并双写引号)。
fn csv_field(text: &str) -> String {
    if text.contains(',') || text.contains('"') || text.contains('\n') {
        format!("\"{}\"", text.replace('"', "\"\""))
    } else {
        text.to_owned()
    }
}

/// 诊断报告 (脱敏): 对应 mac 诊断包 report.json 的字段子集 —— 版本/平台/模块状态/
/// 诊断码/快照存在性; **不含**凭证、账号标识、完整本机路径与业务数据。Windows 侧为
/// 单文件 JSON (mac 为 zip 包, 见 design 05 §4.4 的适配取舍)。
pub fn diagnostics_report(version: &str, panel: &Value) -> Value {
    let runtime = panel.get("runtime").cloned().unwrap_or_else(|| json!({}));
    json!({
        "application": { "version": version, "platform": std::env::consts::OS },
        "module": {
            "phase": runtime.get("phase").cloned().unwrap_or(Value::Null),
            "lastSuccessAt": runtime.get("lastSuccessAt").cloned().unwrap_or(Value::Null),
            "error": runtime.get("error").cloned().unwrap_or(Value::Null),
        },
        "diagnostics": runtime
            .get("diagnosticCodes")
            .cloned()
            .unwrap_or_else(|| json!([])),
        "note": "脱敏报告: 不含凭证、账号标识、完整本机路径与业务活动数据",
    })
}

/// 导出路径: `<root>/exports/<prefix>-<yyyyMMdd-HHmmss>.<extension>` (UTC), 目录不存在
/// 则创建; 返回完整路径供界面展示。
pub fn export_path(root: &Path, prefix: &str, extension: &str) -> Result<String, String> {
    let directory = root.join("exports");
    fs::create_dir_all(&directory).map_err(|error| error.to_string())?;
    let stamp = chrono::Utc::now().format("%Y%m%d-%H%M%S");
    Ok(directory
        .join(format!("{prefix}-{stamp}.{extension}"))
        .to_string_lossy()
        .into_owned())
}

/// 导出目标解析: 用户在保存对话框选定路径时用其原样路径 (父目录自建, 扩展名缺失
/// 则补全); 未选定时回落到 `<root>/exports/` 的带时间戳文件名。
pub fn resolve_export_path(
    root: &Path,
    prefix: &str,
    extension: &str,
    requested: Option<&str>,
) -> Result<String, String> {
    let Some(requested) = requested.map(str::trim).filter(|value| !value.is_empty()) else {
        return export_path(root, prefix, extension);
    };
    let mut target = PathBuf::from(requested);
    if target.extension().is_none() {
        target.set_extension(extension);
    }
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
    }
    Ok(target.to_string_lossy().into_owned())
}

/// 写入导出文件 (沿用凭证模块的原子私有写: 临时文件 + 替换, 权限限定当前用户)。
pub fn write_export(path: &str, bytes: &[u8]) -> Result<(), String> {
    crate::credentials::atomic_private_write(Path::new(path), bytes)
        .map_err(|_| "EXPORT_WRITE_FAILED".to_owned())
}

impl SnapshotState {
    pub fn artifact(&self) -> Option<&Value> {
        self.artifact.as_ref()
    }

    /// Filter restored snapshots against current credentials before publishing.
    pub fn prune_credentials(&mut self, credentials: &BTreeMap<String, Value>) {
        let Some(services) = self
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        else {
            return;
        };
        services.retain(|service| {
            let provider = provider_id(service);
            let accounts = credentials
                .get(&format!("{provider}QuotaAccounts"))
                .and_then(Value::as_object);
            let id = service.get("id").and_then(Value::as_str).unwrap_or("");
            if provider == "codex" {
                return accounts.is_some_and(|accounts| {
                    accounts
                        .keys()
                        .any(|account| collector_provider::codex_service_id(account) == id)
                });
            }
            let prefix = match provider {
                "kimi" => "kimi_coding_".to_owned(),
                "opencodeGo" => "opencode_go_".to_owned(),
                _ => format!("{provider}_"),
            };
            if let Some(account_id) = id.strip_prefix(&prefix) {
                if let Some(accounts) = accounts {
                    return accounts.contains_key(account_id);
                }
                return credentials.contains_key(&format!("{provider}OAuth"));
            }
            accounts.is_some_and(|accounts| !accounts.is_empty())
                || credentials.contains_key(&format!("{provider}OAuth"))
        });
    }

    pub fn load(root: &Path) -> Self {
        match fs::read(root.join("snapshot.json")) {
            Ok(bytes) => match serde_json::from_slice::<Self>(&bytes) {
                Ok(mut state)
                    if state
                        .artifact
                        .as_ref()
                        .map(validate_artifact)
                        .transpose()
                        .is_ok() =>
                {
                    state.fail("SNAPSHOT_RESTORED");
                    state
                }
                _ => Self {
                    phase: "failed".into(),
                    error: Some("SNAPSHOT_INVALID".into()),
                    ..Self::default()
                },
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(_) => Self {
                phase: "failed".into(),
                error: Some("SNAPSHOT_READ_FAILED".into()),
                ..Self::default()
            },
        }
    }

    pub fn save(&self, root: &Path) -> Result<(), String> {
        let bytes = serde_json::to_vec(self).map_err(|_| "SNAPSHOT_WRITE_FAILED".to_owned())?;
        crate::credentials::atomic_private_write(&root.join("snapshot.json"), &bytes)
            .map_err(|_| "SNAPSHOT_WRITE_FAILED".to_owned())
    }

    pub fn begin_refresh(&mut self) {
        self.phase = "refreshing".into();
    }

    pub fn fail(&mut self, code: &str) {
        self.phase = if self.artifact.is_some() {
            "stale"
        } else {
            "failed"
        }
        .into();
        self.error = Some(code.into());
        if let Some(services) = self
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        {
            for service in services {
                if qualified(service) {
                    service["freshness"] = json!("stale");
                }
            }
        }
    }

    /// Validate before mutating the saved snapshot. Bridge error artifacts never
    /// replace a valid previous snapshot, and malformed JSON is a visible failure.
    pub fn apply_response(&mut self, response: &BridgeResponse) -> Result<(), String> {
        self.diagnostics = response
            .diagnostics
            .iter()
            .map(|d| {
                if d.code.len() <= 64
                    && d.code
                        .chars()
                        .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_')
                {
                    d.code.clone()
                } else {
                    "COLLECTOR_DIAGNOSTIC".into()
                }
            })
            .collect();
        if response.status == ResponseStatus::Error {
            self.fail("COLLECTION_FAILED");
            return Err("COLLECTION_FAILED".into());
        }
        let Some(current) = response.artifact.as_ref() else {
            self.fail("ARTIFACT_MISSING");
            return Err("ARTIFACT_MISSING".into());
        };
        if validate_artifact(current).is_err() {
            self.fail("ARTIFACT_INVALID");
            return Err("ARTIFACT_INVALID".into());
        }
        self.artifact = Some(merge_snapshot(self.artifact.as_ref(), current));
        self.phase = if response.status == ResponseStatus::Partial {
            "partial"
        } else {
            "fresh"
        }
        .into();
        self.error = if response.status == ResponseStatus::Partial {
            Some("COLLECTION_PARTIAL".into())
        } else {
            None
        };
        if response.status == ResponseStatus::Success {
            self.last_success_at = Some(response.generated_at.clone());
        }
        Ok(())
    }

    pub fn panel_json(
        &self,
        now: DateTime<FixedOffset>,
        usage_enabled: bool,
        enabled_providers: &[String],
        provider_order: &[String],
    ) -> Value {
        let mut typed = self
            .artifact
            .as_ref()
            .and_then(|a| serde_json::from_value::<AgentUsageArtifact>(a.clone()).ok());
        if let Some(artifact) = typed.as_mut() {
            artifact
                .services
                .retain(|service| enabled_providers.iter().any(|p| p == provider_id(service)));
            artifact.services.sort_by_key(|service| {
                provider_order
                    .iter()
                    .position(|p| p == provider_id(service))
                    .unwrap_or(usize::MAX)
            });
        }
        let mapper = bruce_win_viewmodel::usage::PanelViewModelMapper::default();
        let mut panel =
            serde_json::to_value(mapper.make(typed.as_ref(), now)).unwrap_or_else(|_| json!({}));
        if !usage_enabled {
            panel["usage"] = Value::Null;
            panel["hourly"] = Value::Null;
        }
        // Viewmodel grouping has its own canonical sort, so apply configured order after mapping.
        if let Some(sections) = panel
            .pointer_mut("/subscription/sections")
            .and_then(Value::as_array_mut)
        {
            sections.sort_by_key(|section| {
                provider_order
                    .iter()
                    .position(|p| p == provider_id(section))
                    .unwrap_or(usize::MAX)
            });
        }
        panel["runtime"] = json!({"phase":self.phase,"lastSuccessAt":self.last_success_at,"error":self.error,"diagnosticCodes":self.diagnostics});
        panel
    }
}

fn validate_artifact(value: &Value) -> Result<(), ()> {
    let artifact: AgentUsageArtifact = serde_json::from_value(value.clone()).map_err(|_| ())?;
    DateTime::parse_from_rfc3339(&artifact.generated_at).map_err(|_| ())?;
    if artifact
        .services
        .iter()
        .any(|service| !service.is_object() || service.get("id").and_then(Value::as_str).is_none())
    {
        return Err(());
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WindowAction {
    None,
    HideDashboardAndPersist,
    HideSettings,
}

pub fn window_action(label: &str, lost_focus: bool, close: bool) -> WindowAction {
    match (label, lost_focus, close) {
        ("dashboard", true, _) | ("dashboard", _, true) => WindowAction::HideDashboardAndPersist,
        ("settings", _, true) => WindowAction::HideSettings,
        _ => WindowAction::None,
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

/// 屏幕物理边界与工作区几何信息 (解耦 Tauri GUI 依赖，便于纯单测)。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MonitorBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub work_x: i32,
    pub work_y: i32,
    pub work_width: u32,
    pub work_height: u32,
    pub scale_factor: f64,
}

/// 托盘图标在屏幕中的物理坐标与尺寸。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TrayIconBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// 最终计算出的面板物理尺寸与位置。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DashboardGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// 纯函数：根据显示器物理工作区、DPI 缩放与托盘图标 Rect，计算自适应看板物理尺寸与贴靠坐标。
///
/// 核心保障：
/// 1. 杜绝溢出：在 1080p 150%、1366x768 等小屏/高缩放下自动降低高度，保证底栏齿轮/退出按钮完整可见；
/// 2. 贴靠精准：优先贴靠托盘图标（底任务栏上方 10px / 顶任务栏下方 10px），并居中或安全右贴齐；
/// 3. 无托盘坐标兜底：热键或无托盘 Rect 时贴靠工作区右下角安全边距，不越界。
pub fn compute_dashboard_geometry(
    monitor: &MonitorBounds,
    tray: Option<&TrayIconBounds>,
) -> DashboardGeometry {
    let scale = if monitor.scale_factor > 0.0 {
        monitor.scale_factor
    } else {
        1.0
    };

    // 1. 宽度：基准逻辑宽度 440px
    let base_logical_w = 440.0_f64;
    let max_logical_w = (monitor.work_width as f64 / scale - 16.0).max(240.0);
    let target_logical_w = base_logical_w.min(max_logical_w);
    let win_w = ((target_logical_w * scale).round() as u32).min(monitor.work_width);

    // 2. 高度：基准逻辑高度 760px；小屏自适应
    let base_logical_h = 760.0_f64;
    let avail_logical_h = monitor.work_height as f64 / scale;
    // 上下各预留 10px 边距 (共 20px)，最小保障 320px
    let max_logical_h = (avail_logical_h - 20.0).max(320.0);
    let target_logical_h = base_logical_h.min(max_logical_h);
    let win_h = ((target_logical_h * scale).round() as u32).min(monitor.work_height);

    let margin_x = ((12.0 * scale).round() as i32).max(4);
    let margin_y = ((10.0 * scale).round() as i32).max(4);

    // 3. 垂直定位 (Y)：判断任务栏处于屏幕上方还是下方
    let is_top_taskbar = if let Some(t) = tray {
        t.y + (t.height as i32 / 2) < monitor.y + (monitor.height as i32 / 2)
    } else {
        monitor.work_y > monitor.y + margin_y
    };

    let target_y = if is_top_taskbar {
        if let Some(t) = tray {
            t.y + t.height as i32 + margin_y
        } else {
            monitor.work_y + margin_y
        }
    } else if let Some(t) = tray {
        t.y - win_h as i32 - margin_y
    } else {
        monitor.work_y + monitor.work_height as i32 - win_h as i32 - margin_y
    };

    let min_y = monitor.work_y;
    let max_y = (monitor.work_y + monitor.work_height as i32 - win_h as i32).max(min_y);
    let clamped_y = target_y.clamp(min_y, max_y);

    // 4. 水平定位 (X)
    let min_x = monitor.work_x + margin_x;
    let max_x =
        (monitor.work_x + monitor.work_width as i32 - win_w as i32 - margin_x).max(monitor.work_x);

    let target_x = if let Some(t) = tray {
        let tray_center_x = t.x + (t.width as i32 / 2);
        tray_center_x - (win_w as i32 / 2)
    } else {
        max_x
    };

    let clamped_x = if min_x <= max_x {
        target_x.clamp(min_x, max_x)
    } else {
        monitor.work_x
    };

    DashboardGeometry {
        x: clamped_x,
        y: clamped_y,
        width: win_w,
        height: win_h,
    }
}
