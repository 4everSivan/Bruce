//! Pure refresh, window and snapshot policies; no GUI, network or user-home access.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use bruce_win_viewmodel::analytics::{self, AnalyticsRange, AnalyticsSnapshot};
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

pub fn provider_id(service: &Value) -> &str {
    provider_of_id(service.get("id").and_then(Value::as_str).unwrap_or(""))
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

/// 屏幕物理边界与工作区几何信息 (解耦 Tauri GUI 依赖，便于纯单测)。
#[derive(Debug, Clone, Copy, PartialEq, serde::Serialize, serde::Deserialize)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct TrayIconBounds {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

/// 最终计算出的面板物理尺寸与位置。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct DashboardGeometry {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

fn point_in_monitor(m: &MonitorBounds, px: i32, py: i32) -> bool {
    px >= m.x && px < m.x + m.width as i32 && py >= m.y && py < m.y + m.height as i32
}

/// 看板唤出来源 (C099): 决定目标显示器与托盘锚点的取舍。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DashboardOpenSource {
    /// 托盘左键 / 托盘菜单: 面板贴托盘弹出。
    Tray,
    /// 全局热键: 面板在光标所在屏弹出 (对齐 mac 面板随活动屏菜单栏出现)。
    Hotkey,
}

/// 看板弹出位置: 目标显示器下标 (`None` 由调用方回退 `current_monitor` / `primary_monitor`)
/// 与参与几何计算的托盘锚点。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DashboardPlacement {
    pub monitor_index: Option<usize>,
    pub tray_anchor: Option<TrayIconBounds>,
}

/// 选择看板弹出位置 (C099)：
/// - 托盘唤出优先取托盘所在屏, 热键唤出优先取光标所在屏, 各自以另一方兜底;
/// - 托盘锚点只用于托盘所在屏 —— 别屏按该屏任务栏角落贴靠, 不借用另一块屏上的托盘坐标;
/// - 均未命中时不改变托盘锚点, 由调用方回退当前 / 主显示器。
pub fn select_dashboard_placement(
    monitors: &[MonitorBounds],
    tray: Option<&TrayIconBounds>,
    cursor: Option<(i32, i32)>,
    source: DashboardOpenSource,
) -> DashboardPlacement {
    let tray = tray.copied().filter(|t| t.width > 0 && t.height > 0);
    let tray_monitor =
        tray.and_then(|t| monitors.iter().position(|m| point_in_monitor(m, t.x, t.y)));
    let cursor_monitor =
        cursor.and_then(|(cx, cy)| monitors.iter().position(|m| point_in_monitor(m, cx, cy)));
    let monitor_index = match source {
        DashboardOpenSource::Tray => tray_monitor.or(cursor_monitor),
        DashboardOpenSource::Hotkey => cursor_monitor.or(tray_monitor),
    };
    let tray_anchor = if monitor_index.is_none() || monitor_index == tray_monitor {
        tray
    } else {
        None
    };
    DashboardPlacement {
        monitor_index,
        tray_anchor,
    }
}

/// 任务栏停靠边 (Windows 任务栏可置于屏幕四边任意一侧)。
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskbarEdge {
    Bottom,
    Top,
    Left,
    Right,
}

impl TaskbarEdge {
    /// 任务栏水平 (沿屏幕宽方向铺满) 时为 true。
    pub fn is_horizontal(self) -> bool {
        matches!(self, TaskbarEdge::Bottom | TaskbarEdge::Top)
    }
}

/// 消歧与兜底的优先顺序: Windows 任务栏默认停靠底部, 右侧次之。
const EDGE_PRIORITY: [TaskbarEdge; 4] = [
    TaskbarEdge::Bottom,
    TaskbarEdge::Right,
    TaskbarEdge::Top,
    TaskbarEdge::Left,
];

/// 工作区相对显示器边界的内缩量 (物理像素): (left, top, right, bottom)。
/// 任务栏所在边留下正内缩; 四边皆为 0 表示任务栏自动隐藏或不存在。
fn work_insets(monitor: &MonitorBounds) -> (i32, i32, i32, i32) {
    let left = (monitor.work_x - monitor.x).max(0);
    let top = (monitor.work_y - monitor.y).max(0);
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;
    let right = (mon_right - work_right).max(0);
    let bottom = (mon_bottom - work_bottom).max(0);
    (left, top, right, bottom)
}

/// 任务栏在该边的物理矩形 (工作区之外的那条带状区域)。
/// 相邻两边的条带互不重叠: 底边条带止于 work_right, 左边条带止于 work_bottom —
/// 这样托盘落在左下角时不会同时命中「底任务栏」与「左侧第三方工具条」。
fn bar_rect(monitor: &MonitorBounds, edge: TaskbarEdge) -> (i32, i32, i32, i32) {
    let mon_left = monitor.x;
    let mon_top = monitor.y;
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    let work_left = monitor.work_x;
    let work_top = monitor.work_y;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;
    match edge {
        TaskbarEdge::Bottom => (mon_left, work_bottom, work_right, mon_bottom),
        TaskbarEdge::Top => (mon_left, mon_top, work_right, work_top),
        TaskbarEdge::Left => (mon_left, mon_top, work_left, work_bottom),
        TaskbarEdge::Right => (work_right, mon_top, mon_right, work_bottom),
    }
}

/// 半开区间命中判定。
fn rect_contains(rect: (i32, i32, i32, i32), x: i32, y: i32) -> bool {
    let (left, top, right, bottom) = rect;
    x >= left && x < right && y >= top && y < bottom
}

fn rect_center(rect: &TrayIconBounds) -> (i32, i32) {
    (
        rect.x + rect.width as i32 / 2,
        rect.y + rect.height as i32 / 2,
    )
}

/// 四边均无内缩 (任务栏自动隐藏/隐藏) 时，按托盘贴边方向推断任务栏边。
fn edge_nearest_tray(monitor: &MonitorBounds, tray: &TrayIconBounds) -> Option<TaskbarEdge> {
    let (cx, cy) = rect_center(tray);
    let mon_right = monitor.x + monitor.width as i32;
    let mon_bottom = monitor.y + monitor.height as i32;
    // 托盘 rect 可能退化为点击点位, 带宽取托盘尺寸与屏幕尺寸 2.5% 的较大者
    let band_x = (tray.width as i32).max((monitor.width as i32 / 40).max(8));
    let band_y = (tray.height as i32).max((monitor.height as i32 / 40).max(8));
    for edge in EDGE_PRIORITY {
        let hit = match edge {
            TaskbarEdge::Bottom => mon_bottom - cy <= band_y,
            TaskbarEdge::Top => cy - monitor.y <= band_y,
            TaskbarEdge::Left => cx - monitor.x <= band_x,
            TaskbarEdge::Right => mon_right - cx <= band_x,
        };
        if hit {
            return Some(edge);
        }
    }
    None
}

/// 判定任务栏停靠边。
///
/// 1. 工作区内缩给出候选边; 托盘 rect 落在哪条候选任务栏条带内即为该边
///    (第三方 appbar/dock 与真任务栏共存时唯一可靠的消歧信号);
/// 2. 四边均无内缩 (自动隐藏/无任务栏) 时按托盘贴边方向推断;
/// 3. 仍无结论时按 Windows 默认停靠顺序 (底 > 右 > 上 > 左) 兜底。
pub fn detect_taskbar_edge(monitor: &MonitorBounds, tray: Option<&TrayIconBounds>) -> TaskbarEdge {
    let (left, top, right, bottom) = work_insets(monitor);
    let inset_of = |edge: TaskbarEdge| match edge {
        TaskbarEdge::Bottom => bottom,
        TaskbarEdge::Top => top,
        TaskbarEdge::Left => left,
        TaskbarEdge::Right => right,
    };

    if let Some(t) = tray {
        let (cx, cy) = rect_center(t);
        for edge in EDGE_PRIORITY.iter().copied().filter(|e| inset_of(*e) > 0) {
            let (l, t0, r, b) = bar_rect(monitor, edge);
            // 容差 1px: 托盘 rect 与条带边界相切时仍视为命中
            if rect_contains((l - 1, t0 - 1, r + 1, b + 1), cx, cy) {
                return edge;
            }
        }
        if left + top + right + bottom == 0 {
            if let Some(edge) = edge_nearest_tray(monitor, t) {
                return edge;
            }
        }
    }

    for edge in EDGE_PRIORITY {
        if inset_of(edge) > 0 {
            return edge;
        }
    }
    TaskbarEdge::Bottom
}

/// 托盘 rect 可信性校验: 陈旧坐标 (任务栏换边/换屏后沿用上次 rect) 与检测出的任务栏边
/// 不一致时丢弃, 交由贴角兜底, 避免把面板锚到别的显示器或屏幕另一端。
fn usable_tray<'a>(
    monitor: &MonitorBounds,
    edge: TaskbarEdge,
    tray: Option<&'a TrayIconBounds>,
) -> Option<&'a TrayIconBounds> {
    let t = tray?;
    let (left, top, right, bottom) = work_insets(monitor);
    if left + top + right + bottom == 0 {
        // 无任务栏内缩: 边本身由托盘推断而来, 直接采用
        return Some(t);
    }
    let (l, t0, r, b) = bar_rect(monitor, edge);
    let (cx, cy) = rect_center(t);
    if rect_contains((l, t0, r, b), cx, cy) {
        Some(t)
    } else {
        None
    }
}

/// 自适应尺寸: 宽度基准 440 逻辑px、高度基准 760 逻辑px，依次受工作区宽/高与 DPI 缩放约束。
fn compute_size(monitor: &MonitorBounds, scale: f64) -> (u32, u32) {
    let base_logical_w = 440.0_f64;
    let max_logical_w = (monitor.work_width as f64 / scale - 16.0).max(240.0);
    let target_logical_w = base_logical_w.min(max_logical_w);
    let win_w = ((target_logical_w * scale).round() as u32).min(monitor.work_width);

    let base_logical_h = 760.0_f64;
    let avail_logical_h = monitor.work_height as f64 / scale;
    // 上下各预留 10px 边距 (共 20px)，最小保障 320px
    let max_logical_h = (avail_logical_h - 20.0).max(320.0);
    let target_logical_h = base_logical_h.min(max_logical_h);
    let win_h = ((target_logical_h * scale).round() as u32).min(monitor.work_height);
    (win_w, win_h)
}

/// 夹紧到含边距的舒适区间; 工作区不足以同时容纳两侧边距时退化为硬边界 (面板仍不越出工作区)。
fn clamp_axis(target: i32, comfort_lo: i32, comfort_hi: i32, hard_lo: i32, hard_hi: i32) -> i32 {
    if comfort_lo <= comfort_hi {
        target.clamp(comfort_lo, comfort_hi)
    } else {
        target.clamp(hard_lo, hard_hi.max(hard_lo))
    }
}

/// 纯函数：根据显示器物理工作区、DPI 缩放与托盘图标 Rect，计算自适应看板物理尺寸与贴靠坐标。
///
/// 四边统一模型 (Windows 任务栏可停靠屏幕四边):
/// 1. 判边：由 `work_area` 内缩定位任务栏所在边，托盘 rect 用于消歧 (`detect_taskbar_edge`)；
/// 2. 贴边：面板恒贴任务栏内侧 (水平 12 / 垂直 10 逻辑px 边距)，绝不越入工作区之外；
/// 3. 对齐：沿任务栏轴向居中于托盘图标；无可用托盘坐标时贴托盘所在角落 (右/下)，再夹紧到工作区；
/// 4. 尺寸：1080p 150%、1366x768 等小屏/高缩放下自动降低高度，保证底栏齿轮/退出按钮完整可见。
pub fn compute_dashboard_geometry(
    monitor: &MonitorBounds,
    tray: Option<&TrayIconBounds>,
) -> DashboardGeometry {
    let scale = if monitor.scale_factor > 0.0 {
        monitor.scale_factor
    } else {
        1.0
    };

    let (win_w, win_h) = compute_size(monitor, scale);
    let (win_w, win_h) = (win_w as i32, win_h as i32);

    let margin_x = ((12.0 * scale).round() as i32).max(4);
    let margin_y = ((10.0 * scale).round() as i32).max(4);

    let work_left = monitor.work_x;
    let work_top = monitor.work_y;
    let work_right = monitor.work_x + monitor.work_width as i32;
    let work_bottom = monitor.work_y + monitor.work_height as i32;

    let edge = detect_taskbar_edge(monitor, tray);
    let anchor = usable_tray(monitor, edge, tray).map(rect_center);

    // 贴边轴: 面板紧贴任务栏内侧; 对齐轴: 居中于托盘, 无托盘坐标时贴托盘所在角落
    let (target_x, target_y) = match edge {
        TaskbarEdge::Bottom => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_bottom - margin_y - win_h,
        ),
        TaskbarEdge::Top => (
            anchor.map_or(work_right - margin_x - win_w, |(cx, _)| cx - win_w / 2),
            work_top + margin_y,
        ),
        TaskbarEdge::Left => (
            work_left + margin_x,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
        TaskbarEdge::Right => (
            work_right - margin_x - win_w,
            anchor.map_or(work_bottom - margin_y - win_h, |(_, cy)| cy - win_h / 2),
        ),
    };

    let x = clamp_axis(
        target_x,
        work_left + margin_x,
        work_right - margin_x - win_w,
        work_left,
        work_right - win_w,
    );
    let y = clamp_axis(
        target_y,
        work_top + margin_y,
        work_bottom - margin_y - win_h,
        work_top,
        work_bottom - win_h,
    );

    DashboardGeometry {
        x,
        y,
        width: win_w as u32,
        height: win_h as u32,
    }
}

// MARK: - 顶部四色状态灯判定 (C100)

/// 状态灯四色, 严重度 `Neutral < Ok < Warn < Error`。
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum StatusTone {
    Neutral,
    Ok,
    Warn,
    Error,
}

impl StatusTone {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Neutral => "neutral",
            Self::Ok => "ok",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }

    /// 托盘图标角标色, 与看板 HUD 状态灯同值 (styles.css `--ok` / `--warn` / `--danger` / 中性灰)。
    pub fn tray_rgba(self) -> [u8; 4] {
        match self {
            Self::Neutral => [0x8A, 0x8A, 0x8A, 0xFF],
            Self::Ok => [0x4A, 0x9E, 0x5C, 0xFF],
            Self::Warn => [0xD4, 0xA8, 0x43, 0xFF],
            Self::Error => [0xE5, 0x53, 0x4B, 0xFF],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashboardStatus {
    pub tone: StatusTone,
    pub is_refreshing: bool,
    pub reason: String,
}

/// 状态码 -> 中文态名 (与 mac `DashboardStatusToneResolver.statusLabel` / `app.js` `statusLabel` 同表)。
fn status_label(state: &str) -> &str {
    match state {
        "ok" | "fresh" => "正常",
        "ready" => "可刷新",
        "refreshing" | "loading" => "刷新中",
        "partial" => "部分失败",
        "failed" => "刷新失败",
        "error" => "失败",
        "stale" => "数据过期",
        "unavailable" => "不可用",
        "idle" => "等待刷新",
        "empty" => "暂无数据",
        "notConfigured" => "未配置",
        "authRequired" => "需要授权",
        other => other,
    }
}

fn collection_tone(module_state: &str, has_data: bool) -> StatusTone {
    match module_state {
        "failed" | "error" | "unavailable" => StatusTone::Error,
        "partial" | "stale" | "authRequired" => StatusTone::Warn,
        "fresh" | "ready" | "ok" => StatusTone::Ok,
        "idle" | "refreshing" | "loading" if has_data => StatusTone::Ok,
        _ => StatusTone::Neutral,
    }
}

fn section_tone(status: &str) -> StatusTone {
    match status {
        "error" | "failed" | "unavailable" => StatusTone::Error,
        "partial" | "stale" | "authRequired" => StatusTone::Warn,
        "ok" | "fresh" | "ready" => StatusTone::Ok,
        _ => StatusTone::Neutral,
    }
}

/// `runtime.error` 机器码 -> 中文释义 (与 `app.js` `RUNTIME_ERROR_TEXT` 同表, 由测试锁定);
/// 未登记的码返回 `None`, 不外露到原因文案。
pub fn runtime_error_text(code: &str) -> Option<&'static str> {
    Some(match code {
        "COLLECTION_PARTIAL" => "部分来源未能采集",
        "COLLECTION_FAILED" => "本次采集失败",
        "SNAPSHOT_RESTORED" => "显示上次保存的数据",
        "SNAPSHOT_WRITE_FAILED" => "本地快照写入失败",
        "SNAPSHOT_INVALID" | "SNAPSHOT_READ_FAILED" => "本地快照无法读取",
        "ARTIFACT_MISSING" => "采集结果缺失",
        "ARTIFACT_INVALID" => "采集结果格式无效",
        crate::reachability::NETWORK_UNAVAILABLE => "网络不可用",
        _ => return None,
    })
}

/// 顶部状态灯单一判定 (与 mac `DashboardStatusToneResolver.resolve` / `app.js`
/// `resolveDashboardStatus` 逐字对齐, 三端共用 `tests/fixtures/status-tone-parity` 对拍):
/// 聚合采集与订阅健康度取最严重态; `detail` 只描述采集侧, 订阅侧更严重时原因点名服务。
pub fn resolve_dashboard_status(
    module_state: &str,
    subscriptions: &[(&str, &str)],
    has_data: bool,
    detail: Option<&str>,
) -> DashboardStatus {
    let is_refreshing = matches!(module_state, "refreshing" | "loading");
    let mod_tone = collection_tone(module_state, has_data);

    let mut sub_tone = StatusTone::Neutral;
    let mut worst_sub_status = "empty";
    for (status, _) in subscriptions {
        let candidate = section_tone(status);
        if candidate > sub_tone {
            sub_tone = candidate;
            worst_sub_status = status;
        }
    }

    let tone = mod_tone.max(sub_tone);
    let detail = detail.map(str::trim).unwrap_or_default();
    let reason = if is_refreshing {
        "正在刷新…".to_owned()
    } else if tone == StatusTone::Ok {
        "运行正常".to_owned()
    } else if sub_tone > mod_tone {
        let label = status_label(worst_sub_status);
        let mut names: Vec<&str> = Vec::new();
        for (status, name) in subscriptions {
            let name = name.trim();
            if section_tone(status) == sub_tone && !name.is_empty() && !names.contains(&name) {
                names.push(name);
            }
        }
        if names.is_empty() {
            label.to_owned()
        } else {
            format!("{label} · {}", names.join("、"))
        }
    } else {
        let effective = if module_state == "idle" && !has_data {
            "empty"
        } else {
            module_state
        };
        let label = status_label(effective);
        if !detail.is_empty() && detail != label {
            format!("{label} · {detail}")
        } else {
            label.to_owned()
        }
    };

    DashboardStatus {
        tone,
        is_refreshing,
        reason,
    }
}

/// 从已发布的看板 JSON 计算状态灯 (与 `app.js` `renderStatus` 取数口径一致), 供托盘角标与提示使用。
pub fn dashboard_status_from_panel(panel: &Value) -> DashboardStatus {
    let present = |key: &str| panel.get(key).is_some_and(|value| !value.is_null());
    let has_data = present("usage") || present("subscription") || present("hourly");
    let phase = panel
        .pointer("/runtime/phase")
        .and_then(Value::as_str)
        .filter(|phase| !phase.is_empty())
        .unwrap_or(if has_data { "fresh" } else { "empty" });
    let subscriptions: Vec<(&str, &str)> = panel
        .pointer("/subscription/sections")
        .and_then(Value::as_array)
        .map(|sections| {
            sections
                .iter()
                .filter_map(|section| {
                    let status = section
                        .get("status")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())?;
                    let name = section.get("name").and_then(Value::as_str).unwrap_or("");
                    Some((status, name))
                })
                .collect()
        })
        .unwrap_or_default();
    let detail = panel
        .pointer("/runtime/error")
        .and_then(Value::as_str)
        .and_then(runtime_error_text);
    resolve_dashboard_status(phase, &subscriptions, has_data, detail)
}
