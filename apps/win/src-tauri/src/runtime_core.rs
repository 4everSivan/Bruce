//! Pure refresh, window and snapshot policies; no GUI, network or user-home access.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use bruce_win_viewmodel::analytics::{self, AnalyticsRange, AnalyticsSnapshot};
use chrono::{DateTime, FixedOffset};
use collector_domain::{AgentUsageArtifact, BridgeResponse, ResponseStatus};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

// C128: 按职责拆分 (C053 单文件规模纪律); 公开路径经 re-export 保持 crate::runtime_core::* 不变。
mod activity;
mod geometry;
mod status;

pub use activity::*;
pub use geometry::*;
pub use status::*;

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

/// 额度窗口边界唤醒的提前量 (秒): 边界是预测值, 留出刷新耗时。
pub const WINDOW_BOUNDARY_SLACK_SECS: u64 = 20;

/// 从 artifact 提取订阅窗口的重置时刻 (epoch 秒, 与卡片展示同源)。
pub fn window_boundaries(artifact: &Value) -> Vec<i64> {
    let mut boundaries = Vec::new();
    let Some(services) = artifact.get("services").and_then(Value::as_array) else {
        return boundaries;
    };
    for service in services {
        if service.get("kind").and_then(Value::as_str) != Some("windows") {
            continue;
        }
        let Some(windows) = service.get("windows").and_then(Value::as_array) else {
            continue;
        };
        for window in windows {
            if let Some(reset) = window.get("resetsAt").and_then(Value::as_i64) {
                boundaries.push(reset);
            }
        }
    }
    boundaries
}

/// 下次唤醒秒数: 定时刷新不得跨过未来的额度窗口边界 (C037)。
///
/// 三道防线杜绝刷新风暴 —— 只认严格在未来的边界 (滚动窗口的滑出时刻前移时天然不触发);
/// 同一「边界值」只消费一次 (epoch 秒精确去重); 未命中边界则回落原间隔。
pub fn boundary_wake(
    interval: u64,
    boundaries: &[i64],
    now: i64,
    slack: u64,
    consumed: &mut std::collections::BTreeSet<i64>,
) -> u64 {
    // 已进入过去的边界不再需要记忆, 顺带收敛集合规模。
    consumed.retain(|&boundary| boundary > now);

    let mut best: Option<(u64, i64)> = None;
    for &boundary in boundaries {
        if boundary <= now || consumed.contains(&boundary) {
            continue;
        }
        let delay = (boundary + slack as i64 - now).max(0) as u64;
        if delay < interval && best.is_none_or(|(chosen, _)| delay < chosen) {
            best = Some((delay, boundary));
        }
    }

    match best {
        Some((delay, boundary)) => {
            consumed.insert(boundary);
            delay
        }
        None => interval,
    }
}

/// Backoff retries retain the manual origin; the next normal cycle may notify again.
pub fn manual_alert_reason(input: bool, retries: u32, previous: bool) -> bool {
    input || (retries > 0 && retries <= 5 && previous)
}

/// 服务所属 provider (C118): 优先 collector 显式下发的 `provider`, 旧 artifact 缺省时
/// 回退按 service id 前缀推断 (mac `SubscriptionPresentationPolicy.providerID(for:)` 同义)。
pub fn provider_id(service: &Value) -> &str {
    match service.get("provider").and_then(Value::as_str) {
        Some(provider) if !provider.is_empty() => provider,
        _ => provider_of_id(service.get("id").and_then(Value::as_str).unwrap_or("")),
    }
}

/// service / 订阅卡 section ID → provider rawValue。单账号 section 的 ID 是带账号后缀的
/// service ID (如 `zhipu_9be9…`), 多账号分组 section 的 ID 即 provider 本身 (如 `cline`),
/// 两者经同一前缀规则归一 (mac `SubscriptionPresentationPolicy.providerID` 同义)。
pub fn provider_of_id(id: &str) -> &str {
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

/// 定向刷新快照合并 (mac `ScopedQuotaSnapshotMerger` 同语义): 定向运行只返回目标
/// Provider 的 services (agents 为空、不含成本), 合并回上一份完整 artifact ——
/// 保留 agents / totalCostUsd 与**非目标** Provider 的 services; 目标 Provider 只取本轮
/// 返回的 service (已断开的账号不从历史复活), 成功标 fresh, 失败借用合格旧窗口标
/// stale, 无合格历史标 unavailable; generatedAt 取本轮。
pub fn merge_scoped_snapshot(previous: Option<&Value>, current: &Value, provider: &str) -> Value {
    let round = merge_snapshot(previous, current);
    let mut result = current.clone();
    let mut services: Vec<Value> = previous
        .and_then(|value| value.get("services"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|service| provider_id(service) != provider)
        .cloned()
        .collect();
    services.extend(
        round
            .get("services")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter(|service| provider_id(service) == provider)
            .cloned(),
    );
    result["services"] = Value::Array(services);
    result["agents"] = previous
        .and_then(|value| value.get("agents"))
        .cloned()
        .unwrap_or_else(|| json!([]));
    result["totalCostUsd"] = previous
        .and_then(|value| value.get("totalCostUsd"))
        .cloned()
        .unwrap_or(Value::Null);
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

/// 设置页「Agent 用量」工作台快照 (C070, mac `AppModel.analyticsSnapshot`): 无快照或本机会话
/// 读取已关闭 (与看板隐藏用量同一开关) 时返回空快照 —— 全部指标为 0 / 「—」。
pub fn usage_analytics(
    artifact: Option<&Value>,
    usage_enabled: bool,
    range: AnalyticsRange,
) -> AnalyticsSnapshot {
    match artifact {
        Some(artifact) if usage_enabled => analytics::make(artifact, range),
        _ => analytics::empty(range),
    }
}

/// 工作台「导出 CSV 账单」: 列与 mac `AgentUsageWorkbenchView.exportCSV` 一致 —— 所选范围的
/// 归一模型逐行; 未定价模型费用列留空 (不写 0 冒充免费)。无模型明细时返回 None。
pub fn workbench_csv(snapshot: &AnalyticsSnapshot) -> Option<String> {
    if snapshot.models.is_empty() {
        return None;
    }
    let quoted = |text: &str| format!("\"{}\"", text.replace('"', "\"\""));
    let mut csv =
        "CanonicalModel,Vendor,TotalTokens,EstimatedCostUSD,SharePercent,SourceCount\n".to_owned();
    for model in &snapshot.models {
        csv.push_str(&format!(
            "{},{},{},{},{:.2},{}\n",
            quoted(&model.display_name),
            quoted(&model.vendor),
            model.total_tokens,
            model
                .cost_usd
                .map(|cost| format!("{cost:.4}"))
                .unwrap_or_default(),
            model.share_percent,
            model.sources.len()
        ));
    }
    Some(csv)
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
        self.apply_response_with_policy(response, None, 0, 0)
    }

    /// C077: 带 per-provider 额度门禁的响应应用 —— 在既有合并之后追加
    /// `quotaAttemptedAt`/`rateLimitedAt` 时间戳, 并用上一份 service 回填被跳过的
    /// provider (冷却/新鲜 provider 不丢旧值, 也不被误标 fresh)。
    pub fn apply_response_with_policy(
        &mut self,
        response: &BridgeResponse,
        policy: Option<&crate::quota_policy::QuotaRunPolicy>,
        now_ms: i64,
        interval_secs: i64,
    ) -> Result<(), String> {
        let previous = self.artifact.clone();
        self.apply_response_inner(response)?;
        if let Some(policy) = policy {
            let now_iso = crate::quota_policy::timestamp_iso(now_ms);
            let mut artifact = self.artifact.take();
            if let Some(artifact) = artifact.as_mut() {
                crate::quota_policy::annotate_attempts(artifact, policy, &now_iso);
                crate::quota_policy::carry_over_skipped(
                    artifact,
                    previous.as_ref(),
                    policy,
                    now_ms,
                    interval_secs,
                );
            }
            self.artifact = artifact;
        }
        Ok(())
    }

    fn apply_response_inner(&mut self, response: &BridgeResponse) -> Result<(), String> {
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

    /// 定向刷新只替换目标 Provider 的额度: 全局 phase / lastSuccessAt / 诊断沿用最近一次
    /// 全量采集 (定向刷新不代表本机会话已更新)。Bridge 整体失败或 artifact 不合法时,
    /// 只把目标 Provider 的合格旧值降级为 stale 并返回错误, 不触碰其他 Provider。
    pub fn apply_scoped_response(
        &mut self,
        response: &BridgeResponse,
        provider: &str,
    ) -> Result<(), String> {
        self.apply_scoped_response_inner(response, provider)
    }

    /// C077: 定向刷新应用 —— 额外给目标 provider 写 `quotaAttemptedAt` /
    /// `rateLimitedAt` (定向刷新属手动操作, 绕过冷却)。
    pub fn apply_scoped_response_with_policy(
        &mut self,
        response: &BridgeResponse,
        provider: &str,
        now_ms: i64,
    ) -> Result<(), String> {
        let result = self.apply_scoped_response_inner(response, provider);
        if result.is_ok() {
            let now_iso = crate::quota_policy::timestamp_iso(now_ms);
            if let Some(artifact) = self.artifact.as_mut() {
                crate::quota_policy::annotate_provider(artifact, provider, &now_iso);
            }
        }
        result
    }

    fn apply_scoped_response_inner(
        &mut self,
        response: &BridgeResponse,
        provider: &str,
    ) -> Result<(), String> {
        let code = if response.status == ResponseStatus::Error {
            Some("SCOPED_REFRESH_FAILED")
        } else {
            match response.artifact.as_ref() {
                None => Some("ARTIFACT_MISSING"),
                Some(current) if validate_artifact(current).is_err() => Some("ARTIFACT_INVALID"),
                Some(current) => {
                    self.artifact = Some(merge_scoped_snapshot(
                        self.artifact.as_ref(),
                        current,
                        provider,
                    ));
                    None
                }
            }
        };
        match code {
            Some(code) => {
                self.mark_provider_stale(provider);
                Err(code.into())
            }
            None => Ok(()),
        }
    }

    /// 定向刷新失败: 仅目标 Provider 的合格旧值标 stale (与全量 `fail` 同一资格判定)。
    pub fn mark_provider_stale(&mut self, provider: &str) {
        if let Some(services) = self
            .artifact
            .as_mut()
            .and_then(|a| a.get_mut("services"))
            .and_then(Value::as_array_mut)
        {
            for service in services {
                if provider_id(service) == provider && qualified(service) {
                    service["freshness"] = json!("stale");
                }
            }
        }
    }

    pub fn panel_json(
        &self,
        now: DateTime<FixedOffset>,
        usage_enabled: bool,
        enabled_providers: &[String],
        provider_order: &[String],
    ) -> Value {
        self.panel_json_verified(now, usage_enabled, enabled_providers, None, provider_order)
    }

    /// 携带 Provider 验证状态门禁的看板视图模型组装 (C087, 对齐 mac `AppModel.gatedAgentUsageArtifact`):
    /// 当 `verified_providers` 为 `Some` 时, 订阅段在 `enabled_providers` 过滤之上只保留
    /// `verificationStatus == "ok"` 的 Provider 的 service; 本地用量 (`agents` / `totalCostUsd`) 不受影响。
    pub fn panel_json_verified(
        &self,
        now: DateTime<FixedOffset>,
        usage_enabled: bool,
        enabled_providers: &[String],
        verified_providers: Option<&std::collections::BTreeSet<String>>,
        provider_order: &[String],
    ) -> Value {
        let mut typed = self
            .artifact
            .as_ref()
            .and_then(|a| serde_json::from_value::<AgentUsageArtifact>(a.clone()).ok());
        if let Some(artifact) = typed.as_mut() {
            if let Some(verified) = verified_providers {
                *artifact =
                    bruce_win_viewmodel::subscription::gate_verified_services(artifact, verified);
            }
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
            // 渲染层所需的 provider 键 (定向刷新目标 / 品牌徽章): 由 Rust 侧单点归一后附在
            // section 上, 前端不再镜像前缀规则与 provider 清单; 未知 provider 不附 (fail-closed)。
            // 只在运行时层追加, 不进入 mac 对拍的视图模型契约。
            for section in sections.iter_mut() {
                let provider = provider_id(section);
                if crate::settings::PROVIDERS.contains(&provider) {
                    section["provider"] = json!(provider);
                }
            }
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
