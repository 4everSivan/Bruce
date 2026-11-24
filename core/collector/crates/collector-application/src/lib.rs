#![deny(unsafe_code)]

//! Rust collection application orchestration.
//!
//! The Bridge owns protocol validation and the response envelope. This module
//! owns the collection flow and keeps local aggregation details out of that
//! protocol seam.

mod account;
mod context;
mod egress;
mod execution;
mod paths;
#[cfg(test)]
mod tests_history;
#[cfg(test)]
mod tests_local;
#[cfg(test)]
mod tests_quota;
#[cfg(test)]
mod tests_run;
#[cfg(test)]
mod tests_support;

use account::{build_account_plan, validate_account_request};
use collector_aggregate::UsageAccumulator;
use collector_credential::{validate_credential_challenges, validate_credential_updates};
use collector_domain::{
    AgentUsage, AgentUsageArtifact, BridgeRequest, CollectionWindow, Diagnostic,
    ModelPricingOverride, PricingTable, RequestRecord, TokenBucket, UsageSample, WindowError,
    AGENT_USAGE_MODULE, AGENT_USAGE_SCHEMA_VERSION, LOCAL_HISTORY_STORE_UNAVAILABLE,
    LOCAL_REQUEST_LOG_UNAVAILABLE, LOCAL_SOURCE_NOTICE, REQUEST_LOG_AGENT_IDS,
    REQUEST_LOG_MAX_PER_SOURCE,
};
use collector_history::HistoryStore;
use collector_local::{
    default_cache_root, remove_legacy_kimi_cache, scan_antigravity_cached, scan_claude_cached,
    scan_codebuddy_cached, scan_codex_cached_with_cancellation, scan_dsh_cached, scan_grok_cached,
    scan_kimi_cli_cached, scan_kimi_tree_cached, scan_opencode_cached, scan_pi_cached,
    scan_zcode_cached, ScanStats, SourceScan, SourceScanError,
};
use collector_provider::{HttpClient, ProviderError, UreqHttpClient};
use collector_request_log::{RequestLogEntry, RequestLogFilter, RequestLogStore};
use collector_runtime::{RuntimeError, RuntimeLimits};
use context::RunContext;
use execution::{execute_quota_accounts, QuotaExecution};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use std::time::Instant;

pub use collector_local::ScanStats as CollectionScanStats;
pub use context::{CollectionMetrics, SourcePerformanceMetric};

/// Validate credential outputs before the Bridge serializes the response.
/// The Bridge depends on this application boundary rather than on the
/// credential implementation crate directly.
pub fn validate_credential_outputs(
    updates: &[Value],
    challenges: &[Value],
) -> Result<(Vec<Value>, Vec<Value>), Diagnostic> {
    let updates = validate_credential_updates(&Value::Array(updates.to_vec()))
        .map_err(|error| error.diagnostic)?;
    let challenges = validate_credential_challenges(&Value::Array(challenges.to_vec()))
        .map_err(|error| error.diagnostic)?;
    Ok((updates, challenges))
}

/// Run output consumed by the Bridge before it creates the protocol envelope.
#[derive(Debug)]
pub struct CollectionOutput {
    pub artifact: Value,
    pub diagnostics: Vec<Diagnostic>,
    pub generated_at: String,
    pub scan_stats: ScanStats,
    pub metrics: CollectionMetrics,
    pub source_metrics: Vec<SourcePerformanceMetric>,
    pub credential_updates: Vec<Value>,
    pub credential_challenges: Vec<Value>,
}

/// A failed run. C171: 额度账号在本轮已刷新成功时, 服务端已轮换 refresh token;
/// 整轮随后因本机扫描失败 / 取消 / 超时而失败, 新令牌也必须随错误交给 Bridge,
/// 由 error envelope 带回宿主写回, 否则本地只剩已作废的旧令牌。
pub struct CollectionFailure {
    pub diagnostic: Diagnostic,
    /// 装箱切片: 让各 Result 的 Err 变体保持在 clippy result_large_err 门槛内。
    pub credential_updates: Box<[Value]>,
}

impl From<Diagnostic> for CollectionFailure {
    fn from(diagnostic: Diagnostic) -> Self {
        Self {
            diagnostic,
            credential_updates: Box::default(),
        }
    }
}

/// 手写 Debug: credential_updates 携带令牌明文, 只输出条数。
impl std::fmt::Debug for CollectionFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("CollectionFailure")
            .field("diagnostic", &self.diagnostic)
            .field("credential_updates", &self.credential_updates.len())
            .finish()
    }
}

/// Execute one collection run with production read-only adapters.
pub fn collect_agent_usage(request: &BridgeRequest) -> Result<CollectionOutput, CollectionFailure> {
    collect_agent_usage_with_dependencies(request, &UreqHttpClient::default())
}

/// Execute one collection run with an injected HTTP adapter.
/// This is the fixture seam used by application tests and benchmark targets
/// and never performs external I/O unless the supplied adapter does so.
///
/// C229: there is no credential adapter. The collector never reads host
/// credential files or the Keychain; every credential arrives in
/// `request.credentials`, injected by the host app.
pub fn collect_agent_usage_with_dependencies(
    request: &BridgeRequest,
    http: &dyn HttpClient,
) -> Result<CollectionOutput, CollectionFailure> {
    let context = prepare_run(request, http)?;
    if request
        .context
        .get("quotaRetryOnly")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return collect_quota_retry_only(&context);
    }
    let gathered = gather(&context);
    let assembled = assemble(&context, gathered)?;
    publish(&context, assembled)
}

/// Phase 0: validate the request and build the per-run context.
fn prepare_run<'a>(
    request: &'a BridgeRequest,
    http: &'a dyn HttpClient,
) -> Result<RunContext<'a>, CollectionFailure> {
    validate_account_request(request)?;
    let window = CollectionWindow::from_context(&request.context).map_err(window_diagnostic)?;
    Ok(RunContext::new(
        request,
        window,
        http,
        RuntimeLimits::default(),
    )?)
}

/// C062: 额度仍新鲜/429 冷却时 Swift 只请求本地统计; 此时不启动额度 worker,
/// 也不输出 denied 占位, 避免把「本轮故意不查额度」误报成 partial.
fn local_usage_only(context: &RunContext<'_>) -> bool {
    context
        .request
        .context
        .get("localUsageOnly")
        .and_then(Value::as_bool)
        == Some(true)
}

/// Raw results of the concurrent local and quota workers.
struct Gathered {
    local: Result<LocalCollection, Diagnostic>,
    quota: Option<QuotaExecution>,
}

/// Phase 1: run the local scan and (when allowed) the quota worker concurrently.
fn gather(context: &RunContext<'_>) -> Gathered {
    let (local, quota) = std::thread::scope(|scope| {
        let local = scope.spawn(|| collect_local_usage(context));
        let quota = (!local_usage_only(context) && context.capability_allowed("externalQuotas"))
            .then(|| scope.spawn(|| collect_quota_usage(context)));
        // C043: worker panic 不再 expect 崩溃 —— 降级为诊断, 其余通道照常产出,
        // 保证 stdout 恒有可解释的 envelope (取消语义仍由 cancellation 诊断表达)。
        let local = local
            .join()
            .unwrap_or_else(|_| Err(worker_panic_diagnostic("本机采集工作线程异常中止")));
        let quota = quota.map(|worker| {
            worker.join().unwrap_or_else(|_| QuotaExecution {
                diagnostics: vec![worker_panic_diagnostic("额度采集工作线程异常中止")],
                ..QuotaExecution::default()
            })
        });
        (local, quota)
    });
    Gathered { local, quota }
}

/// Everything the artifact needs, built but not yet published.
struct Assembled {
    agents: Vec<AgentUsage>,
    services: Vec<Value>,
    diagnostics: Vec<Diagnostic>,
    scan_stats: ScanStats,
    source_metrics: Vec<SourcePerformanceMetric>,
    /// C171: 额度线程已完成, 其轮换令牌在服务端已生效; 此后任何一步失败都随错误带出。
    credential_updates: Vec<Value>,
    credential_challenges: Vec<Value>,
}

/// A failed run that still hands already-rotated tokens back to the host (C171).
fn run_failure(diagnostic: Diagnostic, credential_updates: &[Value]) -> CollectionFailure {
    CollectionFailure {
        diagnostic,
        credential_updates: credential_updates.to_vec().into_boxed_slice(),
    }
}

/// Cancellation fence: a cancelled or timed-out run must not publish an artifact.
fn cancellation_fence(
    context: &RunContext<'_>,
    credential_updates: &[Value],
) -> Result<(), CollectionFailure> {
    context
        .cancellation
        .check()
        .map_err(|error| run_failure(local_source_runtime_diagnostic(error), credential_updates))
}

/// Phase 2: merge worker results into agents, services and diagnostics.
fn assemble(context: &RunContext<'_>, gathered: Gathered) -> Result<Assembled, CollectionFailure> {
    let Gathered { local, quota } = gathered;
    // 本轮未启动额度 worker (仅本地 / 未授权 externalQuotas) 时没有可带出的轮换令牌。
    let quota = quota.unwrap_or_default();
    let local = local.map_err(|diagnostic| run_failure(diagnostic, &quota.credential_updates))?;
    cancellation_fence(context, &quota.credential_updates)?;
    let mut diagnostics = local.diagnostics;
    let pricing_table = resolve_pricing_table(context.request);
    persist_request_logs(context, &local.agents, &pricing_table, &mut diagnostics);
    let agents = build_agents(context, &local.agents, &pricing_table);
    // C124: 未授予 externalQuotas (无订阅凭证 / 未同意授权) 或本轮只做本地统计时,
    // 额度 worker 不会启动, quota 为空: 不输出占位 service, 也不消费/产生额度诊断。
    // 旧版的「CC Switch 云端额度」/「Codex 账号额度」占位状态为 partial, 会让纯本机
    // 统计的每一轮都带 COLLECTOR_PARTIAL_RESULT 而显示为部分失败。
    diagnostics.extend(quota.diagnostics);
    if quota.services.iter().any(|service| {
        matches!(
            service.get("status").and_then(Value::as_str),
            Some("partial") | Some("error")
        )
    }) {
        diagnostics.push(Diagnostic::new(
            "COLLECTOR_PARTIAL_RESULT",
            "collector",
            "collect",
            "部分数据源采集失败, 已保留可用结果",
            true,
        ));
    }
    Ok(Assembled {
        agents,
        services: quota.services,
        diagnostics,
        scan_stats: local.scan_stats,
        source_metrics: local.source_metrics,
        credential_updates: quota.credential_updates,
        credential_challenges: quota.credential_challenges,
    })
}

/// C253: 汇总已计价 agent 的费用 —— 任一 agent 已计价即保留总额，合法 $0 输出 Some(0.0)。
fn total_cost_of(costs: impl Iterator<Item = Option<f64>>) -> Option<f64> {
    let mut total = 0.0;
    let mut has_cost = false;
    for cost in costs.flatten() {
        total += cost;
        has_cost = true;
    }
    has_cost.then_some(total)
}

/// Phase 3: fence, serialize and fence again before handing the artifact out.
fn publish(
    context: &RunContext<'_>,
    assembled: Assembled,
) -> Result<CollectionOutput, CollectionFailure> {
    let updates = &assembled.credential_updates;
    cancellation_fence(context, updates)?;
    // C253: 已计价但合计为 $0 的模型仍要输出 `Some(0.0)`，`> 0.0` 会把它误报为未计价。
    let total_cost = total_cost_of(assembled.agents.iter().map(|agent| agent.today_cost_usd));
    let artifact = AgentUsageArtifact {
        schema_version: AGENT_USAGE_SCHEMA_VERSION,
        module: AGENT_USAGE_MODULE.to_owned(),
        generated_at: context.window.generated_at(),
        agents: assembled.agents,
        services: assembled.services,
        total_cost_usd: total_cost,
    };
    let artifact = serde_json::to_value(artifact).map_err(|_| {
        run_failure(
            Diagnostic::new(
                "ARTIFACT_SERIALIZATION_FAILED",
                "collector",
                "serialize",
                "artifact 序列化失败",
                false,
            ),
            updates,
        )
    })?;
    cancellation_fence(context, updates)?;
    Ok(CollectionOutput {
        artifact,
        diagnostics: assembled.diagnostics,
        generated_at: context.window.generated_at(),
        scan_stats: assembled.scan_stats,
        metrics: context.metrics.snapshot(),
        source_metrics: assembled.source_metrics,
        credential_updates: assembled.credential_updates,
        credential_challenges: assembled.credential_challenges,
    })
}

/// 宿主下发的价卡: 合法且不早于内置基线时采用, 否则回退内置基线 (防倒退 Anti-Rollback)。
fn resolve_pricing_table(request: &BridgeRequest) -> PricingTable {
    let pricing_overrides: HashMap<String, ModelPricingOverride> = request
        .context
        .get("pricingOverrides")
        .or_else(|| request.context.get("pricing_overrides"))
        .and_then(|val| serde_json::from_value(val.clone()).ok())
        .unwrap_or_default();
    let Some(raw) = request.context.get("pricingCatalog") else {
        return PricingTable::new(pricing_overrides);
    };
    let bytes = serde_json::to_vec(raw).unwrap_or_default();
    match collector_domain::pricing::CatalogFile::parse_and_validate(&bytes) {
        Ok(catalog_file)
            if !catalog_file.is_older_than(collector_domain::pricing::builtin_updated_at()) =>
        {
            PricingTable::with_catalog(&catalog_file.models, pricing_overrides)
        }
        _ => PricingTable::new(pricing_overrides),
    }
}

/// Persist request-granularity rows after the aggregate scan and pricing table
/// are ready. Failure is informational: the request log is a rebuildable
/// side-channel and must never fail the artifact.
fn persist_request_logs(
    context: &RunContext<'_>,
    agents: &BTreeMap<String, LocalAgentResult>,
    pricing: &PricingTable,
    diagnostics: &mut Vec<Diagnostic>,
) {
    let Some(home) = context.request.context.get("home").and_then(Value::as_str) else {
        return;
    };
    let path = source_path(
        context,
        "request_log_db",
        paths::resolve_request_log_path(Path::new(home)),
    );
    let cutoff = collector_domain::request_log_cutoff_millis(context.window.now.timestamp_millis());
    let mut entries = Vec::new();
    let mut truncated_total = 0;
    // Shared aggregators also emit rows for agents outside the request-log
    // scope (CodeBuddy / DSH); only in-scope agents reach the store (C249).
    let in_scope = agents
        .iter()
        .filter(|(agent_id, _)| REQUEST_LOG_AGENT_IDS.contains(&agent_id.as_str()));
    for (agent_id, result) in in_scope {
        if result.requests.truncated > 0 {
            truncated_total += result.requests.truncated;
            // design/14 §3.5.3: the cap keeps the newest rows; say how many
            // older ones were left out (informational, not a fault).
            diagnostics.push(Diagnostic::new(
                LOCAL_SOURCE_NOTICE,
                "local",
                agent_id,
                format!(
                    "请求日志明细超过每源 {REQUEST_LOG_MAX_PER_SOURCE} 条上限, 已保留最近 \
                     {REQUEST_LOG_MAX_PER_SOURCE} 条, 未记录较早的 {} 条",
                    result.requests.truncated
                ),
                false,
            ));
        }
        for request in &result.requests.rows {
            let (cost_usd, pricing_model) = request_cost(pricing, request);
            entries.push(RequestLogEntry {
                agent_id: agent_id.clone(),
                request_key: request.key.clone(),
                occurred_at: request.timestamp_millis,
                model: request.model.clone(),
                raw_model: request.raw_model.clone(),
                project: request.project.clone(),
                input: request.input,
                output: request.output,
                cache_read: request.cache_read,
                cache_creation: request.cache_creation,
                cache_creation_1h: request.cache_creation_1h,
                cost_usd,
                pricing_model,
                status_code: 200,
                fidelity: request.fidelity.clone(),
                latency_ms: request.latency_ms,
                first_token_ms: request.first_token_ms,
            });
        }
    }
    context
        .metrics
        .request_log_rows_truncated
        .store(truncated_total, Ordering::Release);
    // With nothing to write, still prune an existing store so expired detail
    // does not linger while every in-scope agent is idle; never create one.
    if entries.is_empty() && !path.is_file() {
        return;
    }
    let started = Instant::now();
    let result = RequestLogStore::open(&path).and_then(|mut store| store.merge(&entries, cutoff));
    let elapsed_ms = usize::try_from(started.elapsed().as_millis()).unwrap_or(usize::MAX);
    context
        .metrics
        .request_log_merge_ms
        .store(elapsed_ms, Ordering::Release);
    match result {
        Ok(outcome) => {
            context
                .metrics
                .request_log_rows_written
                .store(outcome.written, Ordering::Release);
            context
                .metrics
                .request_log_rows_pruned
                .store(outcome.pruned, Ordering::Release);
        }
        Err(error) => diagnostics.push(Diagnostic::new(
            LOCAL_REQUEST_LOG_UNAVAILABLE,
            "local",
            "request-log",
            format!("请求日志写入失败, 已跳过本轮明细: {error}"),
            true,
        )),
    }
}

/// Read-only request-log page for the `request-log` Bridge module.
pub fn query_request_log_artifact(
    request: &BridgeRequest,
    generated_at: &str,
) -> Result<Value, Diagnostic> {
    let context = &request.context;
    let home = context
        .get("home")
        .and_then(Value::as_str)
        .filter(|home| !home.is_empty())
        .ok_or_else(|| invalid_request("请求日志查询需要 home"))?;
    let start = context
        .get("start")
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid_request("请求日志查询需要 start"))?;
    let end = context
        .get("end")
        .and_then(Value::as_i64)
        .ok_or_else(|| invalid_request("请求日志查询需要 end"))?;
    if end < start || end.saturating_sub(start) > 31 * 24 * 60 * 60 * 1000 {
        return Err(invalid_request("请求日志时间范围无效或超过 31 天"));
    }
    let page = context.get("page").and_then(Value::as_u64).unwrap_or(0);
    let page_size = context
        .get("pageSize")
        .and_then(Value::as_u64)
        .unwrap_or(50);
    if page > 1000 || page_size == 0 || page_size > 200 {
        return Err(invalid_request("请求日志分页参数无效"));
    }
    let agent_ids = match context.get("agentIds") {
        None => Vec::new(),
        Some(Value::Array(values)) if values.len() <= 32 => values
            .iter()
            .map(|value| {
                value
                    .as_str()
                    .filter(|value| REQUEST_LOG_AGENT_IDS.contains(value))
                    .map(str::to_owned)
                    .ok_or_else(|| invalid_request("请求日志 agentIds 无效"))
            })
            .collect::<Result<Vec<_>, _>>()?,
        Some(_) => return Err(invalid_request("请求日志 agentIds 无效")),
    };
    let model = context
        .get("model")
        .and_then(Value::as_str)
        .filter(|model| !model.is_empty())
        .map(str::to_owned);
    if model.as_ref().is_some_and(|model| model.len() > 128) {
        return Err(invalid_request("请求日志 model 过长"));
    }
    let status = match context.get("status") {
        None => None,
        Some(value) => {
            let value = value
                .as_u64()
                .and_then(|value| u16::try_from(value).ok())
                .filter(|value| (100..=599).contains(value))
                .ok_or_else(|| invalid_request("请求日志 status 无效"))?;
            Some(value)
        }
    };
    let path = context
        .get("paths")
        .and_then(Value::as_object)
        .and_then(|paths| paths.get("request_log_db"))
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_else(|| paths::resolve_request_log_path(Path::new(home)));
    if !path.is_file() {
        return Ok(json!({
            "schemaVersion": 1,
            "module": "request-log",
            "generatedAt": generated_at,
            "total": 0,
            "page": page,
            "pageSize": page_size,
            "summary": { "tokens": 0, "costUsd": 0.0, "avgTokens": 0 },
            "models": [],
            "entries": [],
            "notice": "请求日志库尚未生成"
        }));
    }
    let store = RequestLogStore::open_read_only(&path).map_err(|error| {
        Diagnostic::new(
            "REQUEST_LOG_UNAVAILABLE",
            "local",
            "request-log",
            format!("请求日志库不可用: {error}"),
            true,
        )
    })?;
    let result = store
        .query(&RequestLogFilter {
            start,
            end,
            agent_ids,
            model,
            status,
            page: page as u32,
            page_size: page_size as u32,
        })
        .map_err(|error| {
            Diagnostic::new(
                "REQUEST_LOG_QUERY_FAILED",
                "local",
                "request-log",
                format!("请求日志查询失败: {error}"),
                true,
            )
        })?;
    let entries = result
        .entries
        .into_iter()
        .map(|entry| {
            json!({
                "requestId": entry.request_key,
                "agentId": entry.agent_id,
                "model": entry.model,
                "rawModel": entry.raw_model,
                "occurredAt": entry.occurred_at,
                "input": entry.input,
                "output": entry.output,
                "cacheRead": entry.cache_read,
                "cacheCreation": entry.cache_creation,
                "cacheCreation1h": entry.cache_creation_1h,
                "costUsd": entry.cost_usd,
                "pricingModel": entry.pricing_model,
                "statusCode": entry.status_code,
                "project": entry.project,
                "fidelity": entry.fidelity,
                "latencyMs": entry.latency_ms,
                "firstTokenMs": entry.first_token_ms
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "schemaVersion": 1,
        "module": "request-log",
        "generatedAt": generated_at,
        "total": result.total,
        "page": page,
        "pageSize": page_size,
        "summary": {
            "tokens": result.tokens,
            "costUsd": result.cost_usd,
            "avgTokens": result.avg_tokens
        },
        "models": result.models,
        "entries": entries
    }))
}

fn invalid_request(message: &str) -> Diagnostic {
    Diagnostic::new(
        "BRIDGE_INVALID_REQUEST",
        "protocol",
        "request",
        message,
        false,
    )
}

fn request_cost(pricing: &PricingTable, request: &RequestRecord) -> (Option<f64>, Option<String>) {
    let Some(model) = request.model.as_deref().filter(|model| !model.is_empty()) else {
        return (None, None);
    };
    let Some((pricing_key, price)) = pricing.resolve_with_key(model) else {
        return (None, None);
    };
    let sample = UsageSample {
        timestamp_millis: request.timestamp_millis,
        model: Some(model),
        input: request.input,
        output: request.output,
        cache_read: request.cache_read,
        cache_creation: request.cache_creation,
        cache_creation_1h: request.cache_creation_1h,
        project: request.project.as_deref(),
    };
    // C253: 用请求级价卡分类，`context.pricingCatalog` 热更新的峰谷/长上下文档才生效。
    let rate_class = pricing.rate_class(model, request.timestamp_millis, request.input);
    let mut bucket = TokenBucket::default();
    bucket.add_sample_classified(&sample, rate_class);
    (
        Some(pricing.calculate_cost(&bucket, &price)),
        Some(pricing_key),
    )
}

/// 输出的 agent 行 (固定顺序): id, 展示名, 有数据时的 note, 未发现会话时的 note。
const AGENT_SPECS: [(&str, &str, &str, &str); 11] = [
    (
        "kimi-work",
        "Kimi Work",
        "额度见下方 Kimi 服务",
        "未发现会话记录",
    ),
    (
        "kimi-code-cli",
        "Kimi Code CLI",
        "额度见下方 Kimi 服务",
        "未发现会话记录",
    ),
    (
        "claude-code",
        "Claude Code",
        "额度见下方 Claude 服务",
        "未发现会话记录",
    ),
    (
        "codex",
        "Codex",
        "额度见下方 Codex 账号 (实时查询)",
        "未发现会话记录",
    ),
    (
        "grok",
        "Grok",
        "按消息内容估算 (不含每轮重发的上下文, 偏低), 非精确 token 计数",
        "未发现会话记录",
    ),
    ("pi", "Pi", "本机会话聚合", "未发现会话记录"),
    ("zcode", "ZCode", "本机会话聚合", "未发现会话记录"),
    ("codebuddy", "CodeBuddy", "本机会话聚合", "未发现会话记录"),
    ("opencode", "OpenCode", "本机会话聚合", "未发现会话记录"),
    ("dsh", "DSH", "本机会话聚合", "未发现会话记录"),
    (
        "antigravity",
        "Antigravity",
        "Antigravity CLI/IDE 本机会话聚合",
        "未发现会话记录",
    ),
];

/// 每个已知 agent 输出一行: 有本机结果时 finalize, 否则输出占位行。
fn build_agents(
    context: &RunContext<'_>,
    sources: &BTreeMap<String, LocalAgentResult>,
    pricing_table: &PricingTable,
) -> Vec<AgentUsage> {
    let sessions_allowed = context.capability_allowed("localSessions");
    let placeholder_status = if sessions_allowed {
        "not_found"
    } else {
        "unavailable"
    };
    AGENT_SPECS
        .iter()
        .map(|&(id, name, note, not_found_note)| {
            let missing_note = if sessions_allowed {
                not_found_note
            } else {
                "未授权 localSessions 能力, 已跳过本机会话扫描"
            };
            match sources.get(id) {
                Some(source) => finalize_local_agent(
                    &context.window,
                    id,
                    name,
                    source,
                    note,
                    placeholder_status,
                    missing_note,
                    pricing_table,
                ),
                None => placeholder_agent(
                    &context.window,
                    id,
                    name,
                    placeholder_status,
                    missing_note,
                    pricing_table,
                ),
            }
        })
        .collect()
}

struct LocalCollection {
    agents: BTreeMap<String, LocalAgentResult>,
    diagnostics: Vec<Diagnostic>,
    scan_stats: ScanStats,
    source_metrics: Vec<SourcePerformanceMetric>,
}

struct LocalAgentResult {
    found: bool,
    contribution: collector_domain::UsageContribution,
    /// Request rows emitted by this source during the scan (design/14).
    requests: collector_domain::RequestRows,
    diagnostic: Option<String>,
    /// 来源信息级说明 (C198): 附在 note 后, 不改变 status。
    notice: Option<String>,
    /// 来源当前不可用但台账有历史量时的 note (T26); Some 时 artifact status=history。
    history_note: Option<String>,
}

fn collect_local_usage(context: &RunContext<'_>) -> Result<LocalCollection, Diagnostic> {
    let mut collection = LocalCollection {
        agents: BTreeMap::new(),
        diagnostics: Vec::new(),
        scan_stats: ScanStats::default(),
        source_metrics: Vec::new(),
    };
    if !context.capability_allowed("localSessions") {
        return Ok(collection);
    }
    let Some(home) = context.request.context.get("home").and_then(Value::as_str) else {
        return Err(Diagnostic::new(
            "BRIDGE_INVALID_REQUEST",
            "protocol",
            "context",
            "本地会话扫描需要 home",
            false,
        ));
    };
    let home = PathBuf::from(home);
    let cache_root = default_cache_root(&home);
    // C116: Kimi Code CLI 改用共享 JSONL 缓存引擎, 清理旧版引擎遗留的条目 (缓存可再生)。
    remove_legacy_kimi_cache(&cache_root);
    // T26: 全量本机扫描轮将派生数值合并进 collector 自有台账; 台账失败只降级,
    // 不影响本轮扫描结果 (回退为「仅扫描贡献」)。
    let history_path = source_path(
        context,
        "history_db",
        paths::resolve_usage_history_path(&home),
    );
    let mut history = match HistoryStore::open(&history_path) {
        Ok(store) => Some(store),
        Err(error) => {
            collection.diagnostics.push(Diagnostic::new(
                LOCAL_HISTORY_STORE_UNAVAILABLE,
                "local",
                "history",
                format!("用量历史台账不可用, 本轮仅使用扫描结果: {error}"),
                true,
            ));
            None
        }
    };
    let jobs = local_source_jobs(context, &home, &cache_root);
    // C110 / C116: 9 个本机源交给 local_workers 大小的工作池并行扫描, 结果按源序合并,
    // 诊断与指标顺序不变。
    for (source, source_metric, degradation) in run_local_sources(context, jobs)? {
        let id = source_metric.source_id.clone();
        collection.source_metrics.push(source_metric);
        collection.scan_stats.merge(source.stats.clone());
        // C046: 源读取失败 (I/O) 以信息级诊断暴露, 不再完全静默。
        if let Some(warning) = degradation {
            collection.diagnostics.push(warning);
        }
        if let Some(message) = source.diagnostic.clone() {
            // C198: diagnostic 只承载真实 schema/读取故障, 保留原故障码与 Partial 语义;
            // 说明性信息走下方 notice。
            collection.diagnostics.push(Diagnostic::new(
                "LOCAL_SOURCE_SCHEMA_INCOMPATIBLE",
                "local",
                &id,
                message,
                true,
            ));
        }
        if let Some(message) = source.notice.clone() {
            collection.diagnostics.push(Diagnostic::new(
                LOCAL_SOURCE_NOTICE,
                "local",
                &id,
                message,
                false,
            ));
        }
        if let Some(store) = history.as_mut() {
            // C199: 声明来源的派生口径版本; 版本升级后的首个来源可见轮按扫描窗口向下修正台账。
            let merged = store.merge_versioned(
                &id,
                &source.contribution,
                source.found,
                &context.window.today,
                &context.captured_at,
                collector_local::source_derivation_version(&id),
                &context.window.day_list,
            );
            if let Err(error) = merged {
                collection.diagnostics.push(Diagnostic::new(
                    LOCAL_HISTORY_STORE_UNAVAILABLE,
                    "local",
                    "history",
                    format!("用量历史台账写入失败, 本轮仅使用扫描结果: {error}"),
                    true,
                ));
                history = None;
            }
        }
        collection.agents.insert(
            id,
            LocalAgentResult {
                found: source.found,
                contribution: source.contribution,
                requests: source.requests,
                diagnostic: source.diagnostic,
                notice: source.notice,
                history_note: None,
            },
        );
    }
    if let Some(store) = history.as_ref() {
        let mut load_error: Option<String> = None;
        for (id, entry) in collection.agents.iter_mut() {
            match store.load(id, &context.window) {
                Ok(stored) if stored.has_data => {
                    entry.contribution = stored.contribution;
                    if !entry.found {
                        entry.history_note = Some(match stored.last_found_at {
                            Some(last) => {
                                format!(
                                    "本机未发现会话来源, 显示已保存的历史用量 (最后同步 {last})"
                                )
                            }
                            None => "本机未发现会话来源, 显示已保存的历史用量".to_owned(),
                        });
                    }
                }
                Ok(_) => {}
                Err(error) => {
                    load_error = Some(format!("用量历史台账读取失败, 本轮仅使用扫描结果: {error}"));
                    break;
                }
            }
        }
        if let Some(message) = load_error {
            collection.diagnostics.push(Diagnostic::new(
                LOCAL_HISTORY_STORE_UNAVAILABLE,
                "local",
                "history",
                message,
                true,
            ));
        }
    }
    Ok(collection)
}

type LocalScan<'a> = Box<dyn FnOnce() -> Result<SourceScan, SourceScanError> + Send + 'a>;

struct LocalSourceJob<'a> {
    source_id: &'static str,
    scan: LocalScan<'a>,
}

type LocalSourceResult = (SourceScan, SourcePerformanceMetric, Option<Diagnostic>);

/// 本机源扫描任务, 顺序即 artifact 诊断与指标顺序 (Kimi Code CLI 居首, C116 前为独立主源)。
fn local_source_jobs<'a>(
    context: &'a RunContext<'a>,
    home: &Path,
    cache_root: &'a Path,
) -> Vec<LocalSourceJob<'a>> {
    let window = &context.window;
    let cancellation = &context.cancellation;
    let kimi_cli = source_path(
        context,
        "kimi_cli_sessions",
        home.join(".kimi-code").join("sessions"),
    );
    let kimi_work = source_path(
        context,
        "daimon_kimi_sessions",
        paths::resolve_kimi_work_sessions_path(home),
    );
    let claude = source_path(
        context,
        "claude_projects",
        paths::resolve_claude_projects_path(home),
    );
    let codex = source_path(
        context,
        "codex_sessions",
        paths::resolve_codex_sessions_path(home),
    );
    let orca_home = source_path(context, "orca_home", paths::resolve_orca_home_path(home));
    let orca_sessions = source_path(
        context,
        "orca_codex_sessions",
        orca_home
            .join("codex-runtime-home")
            .join("home")
            .join("sessions"),
    );
    let orca_accounts = source_path(
        context,
        "orca_codex_accounts",
        orca_home.join("codex-accounts"),
    );
    // C119: Orca 内置 Codex 的会话就是 Codex 会话, 与 Codex CLI 同一次扫描去重并计入 Codex;
    // 不单设 Orca 行 (该行此前恒为「未发现会话记录」)。
    let mut codex_roots = vec![codex, orca_sessions];
    if let Ok(entries) = fs::read_dir(&orca_accounts) {
        for entry in entries.flatten() {
            let sessions = entry.path().join("home").join("sessions");
            if sessions.is_dir() {
                codex_roots.push(sessions);
            }
        }
    }
    let grok_root = source_path(context, "grok_home", paths::resolve_grok_home_path(home));
    let grok_roots = [
        grok_root.join("sessions"),
        grok_root.join("archived_sessions"),
    ];
    let pi = source_path(
        context,
        "pi_sessions",
        paths::resolve_pi_sessions_path(home),
    );
    let opencode = source_path(
        context,
        "opencode_db",
        paths::resolve_opencode_db_path(home),
    );
    let zcode = source_path(context, "zcode_db", paths::resolve_zcode_db_path(home));
    let codebuddy = source_path(
        context,
        "codebuddy_projects",
        paths::resolve_codebuddy_projects_path(home),
    );
    let dsh = source_path(
        context,
        "dsh_sessions",
        paths::resolve_dsh_sessions_path(home),
    );
    let [antigravity_cli_default, antigravity_ide_default] =
        paths::resolve_antigravity_brain_roots(home);
    let antigravity_cli = source_path(context, "antigravity_cli_brain", antigravity_cli_default);
    let antigravity_ide = source_path(context, "antigravity_ide_brain", antigravity_ide_default);
    let antigravity_roots = [antigravity_cli, antigravity_ide];
    vec![
        LocalSourceJob {
            source_id: "kimi-code-cli",
            scan: Box::new(move || {
                scan_kimi_cli_cached(&kimi_cli, window, cache_root, cancellation)
            }),
        },
        LocalSourceJob {
            source_id: "kimi-work",
            scan: Box::new(move || {
                scan_kimi_tree_cached(&kimi_work, window, cache_root, cancellation)
            }),
        },
        LocalSourceJob {
            source_id: "claude-code",
            scan: Box::new(move || scan_claude_cached(&claude, window, cache_root, cancellation)),
        },
        LocalSourceJob {
            source_id: "codex",
            scan: Box::new(move || {
                scan_codex_cached_with_cancellation(&codex_roots, window, cache_root, cancellation)
            }),
        },
        LocalSourceJob {
            source_id: "codebuddy",
            scan: Box::new(move || {
                scan_codebuddy_cached(&codebuddy, window, cache_root, cancellation)
            }),
        },
        LocalSourceJob {
            source_id: "grok",
            scan: Box::new(move || scan_grok_cached(&grok_roots, window, cache_root, cancellation)),
        },
        LocalSourceJob {
            source_id: "opencode",
            scan: Box::new(move || {
                scan_opencode_cached(&opencode, window, cache_root, cancellation)
            }),
        },
        LocalSourceJob {
            source_id: "pi",
            scan: Box::new(move || scan_pi_cached(&pi, window, cache_root, cancellation)),
        },
        LocalSourceJob {
            source_id: "zcode",
            scan: Box::new(move || scan_zcode_cached(&zcode, window, cache_root, cancellation)),
        },
        LocalSourceJob {
            source_id: "dsh",
            scan: Box::new(move || scan_dsh_cached(&dsh, window, cache_root, cancellation)),
        },
        LocalSourceJob {
            source_id: "antigravity",
            scan: Box::new(move || {
                scan_antigravity_cached(&antigravity_roots, window, cache_root, cancellation)
            }),
        },
    ]
}

/// 以 `local_workers` 大小的工作池执行本机源扫描 (C110); 每个任务持一个本机扫描许可。
/// 结果按任务原序返回, 取消/超时按原序上报首个错误; 单个任务所在线程 panic 时降级为
/// 该源的空结果 + 诊断 (C043)。
fn run_local_sources(
    context: &RunContext<'_>,
    jobs: Vec<LocalSourceJob<'_>>,
) -> Result<Vec<LocalSourceResult>, Diagnostic> {
    let source_ids = jobs.iter().map(|job| job.source_id).collect::<Vec<_>>();
    let workers = context.limits.local_workers.clamp(1, jobs.len().max(1));
    let queue = Mutex::new(jobs.into_iter().enumerate().collect::<VecDeque<_>>());
    let results = Mutex::new(
        (0..source_ids.len())
            .map(|_| None)
            .collect::<Vec<Option<Result<LocalSourceResult, Diagnostic>>>>(),
    );
    std::thread::scope(|scope| {
        let handles = (0..workers)
            .map(|_| {
                scope.spawn(|| loop {
                    let next = queue
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())
                        .pop_front();
                    let Some((index, job)) = next else {
                        break;
                    };
                    let result = context
                        .budgets
                        .acquire_local(&context.cancellation)
                        .map_err(local_source_runtime_diagnostic)
                        .and_then(|_permit| {
                            collect_secondary_source(context, job.source_id, job.scan)
                        });
                    results
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner())[index] = Some(result);
                })
            })
            .collect::<Vec<_>>();
        for handle in handles {
            let _ = handle.join();
        }
    });
    results
        .into_inner()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .into_iter()
        .zip(source_ids)
        .map(|(result, source_id)| {
            result.unwrap_or_else(|| {
                let warning =
                    worker_panic_diagnostic(&format!("本机 {source_id} 扫描工作线程异常中止"));
                Ok((
                    SourceScan::empty(&context.window),
                    SourcePerformanceMetric {
                        source_id: source_id.to_owned(),
                        elapsed_ms: 0,
                        stats: ScanStats::default(),
                    },
                    Some(warning),
                ))
            })
        })
        .collect()
}

/// Execute one local source scan and retain only its aggregate diagnostics.
pub fn timed_source_scan<F>(
    source_id: &'static str,
    scan: F,
) -> (Result<SourceScan, SourceScanError>, SourcePerformanceMetric)
where
    F: FnOnce() -> Result<SourceScan, SourceScanError>,
{
    let started = Instant::now();
    let source = scan();
    let metric = SourcePerformanceMetric {
        source_id: source_id.to_owned(),
        elapsed_ms: started.elapsed().as_millis() as u64,
        stats: source
            .as_ref()
            .map(|source| source.stats.clone())
            .unwrap_or_default(),
    };
    (source, metric)
}

fn collect_secondary_source<F>(
    context: &RunContext<'_>,
    source_id: &'static str,
    scan: F,
) -> Result<(SourceScan, SourcePerformanceMetric, Option<Diagnostic>), Diagnostic>
where
    F: FnOnce() -> Result<SourceScan, SourceScanError>,
{
    context
        .cancellation
        .check()
        .map_err(local_source_runtime_diagnostic)?;
    let (source, metric) = timed_source_scan(source_id, scan);
    context
        .cancellation
        .check()
        .map_err(local_source_runtime_diagnostic)?;
    match source {
        Ok(source) => Ok((source, metric, None)),
        Err(SourceScanError::Runtime(error)) => Err(local_source_runtime_diagnostic(error)),
        // C046: 次要源 I/O 错误不再完全静默 —— 返回信息级诊断说明,
        // 「源不存在」与「读取失败」从此可区分; 该源无数据即无数据,
        // 失败语义 (envelope 不升级为故障) 保持既有兜底行为不变。
        Err(SourceScanError::Io(error)) => {
            let empty = SourceScan::empty(&context.window);
            let warning = Diagnostic::new(
                "LOCAL_SOURCE_IO_DEGRADED",
                "local",
                source_id,
                format!("本机 {source_id} 会话读取失败, 已跳过该源: {error}"),
                true,
            );
            Ok((empty, metric, Some(warning)))
        }
    }
}

fn collect_quota_usage(context: &RunContext<'_>) -> QuotaExecution {
    match build_account_plan(context.request) {
        Ok(plans) => execute_quota_accounts(context, &plans),
        Err(diagnostic) => QuotaExecution {
            diagnostics: vec![diagnostic],
            ..QuotaExecution::default()
        },
    }
}

fn collect_quota_retry_only(
    context: &RunContext<'_>,
) -> Result<CollectionOutput, CollectionFailure> {
    let quota = match build_account_plan(context.request) {
        Ok(plans) => execute_quota_accounts(context, &plans),
        Err(diagnostic) => QuotaExecution {
            diagnostics: vec![diagnostic],
            ..QuotaExecution::default()
        },
    };
    let mut diagnostics = quota.diagnostics;
    if quota.services.iter().any(|service| {
        matches!(
            service.get("status").and_then(Value::as_str),
            Some("partial") | Some("error")
        )
    }) {
        diagnostics.push(Diagnostic::new(
            "COLLECTOR_PARTIAL_RESULT",
            "collector",
            "collect",
            "部分数据源采集失败, 已保留可用结果",
            true,
        ));
    }
    // C171: 重试轮已拿到的轮换令牌同样随超时错误带出。
    context
        .cancellation
        .check()
        .map_err(|error| CollectionFailure {
            diagnostic: runtime_diagnostic(error),
            credential_updates: quota.credential_updates.clone().into_boxed_slice(),
        })?;
    Ok(CollectionOutput {
        artifact: json!({
            "schemaVersion": AGENT_USAGE_SCHEMA_VERSION,
            "module": AGENT_USAGE_MODULE,
            "generatedAt": context.window.generated_at(),
            "agents": [],
            "services": quota.services,
            "totalCostUsd": null,
        }),
        diagnostics,
        generated_at: context.window.generated_at(),
        scan_stats: ScanStats::default(),
        metrics: context.metrics.snapshot(),
        source_metrics: Vec::new(),
        credential_updates: quota.credential_updates,
        credential_challenges: quota.credential_challenges,
    })
}

fn runtime_diagnostic(error: RuntimeError) -> Diagnostic {
    ProviderError::from_runtime(error).diagnostic
}

fn local_source_runtime_diagnostic(_error: RuntimeError) -> Diagnostic {
    Diagnostic::new(
        "LOCAL_SOURCE_CANCELLED",
        "local",
        "cancel",
        "本机会话扫描因取消或超时提前停止, 未发布部分采集结果",
        true,
    )
}

/// C043: 工作线程 panic 的统一诊断 (重试可自愈)。
fn worker_panic_diagnostic(message: &str) -> Diagnostic {
    Diagnostic::new(
        "COLLECTOR_WORKER_PANICKED",
        "runtime",
        "worker",
        message,
        true,
    )
}

fn placeholder_agent(
    window: &CollectionWindow,
    id: &str,
    name: &str,
    status: &str,
    note: &str,
    pricing: &PricingTable,
) -> AgentUsage {
    let mut agent = UsageAccumulator::new(window.clone()).finalize_with_pricing(id, name, pricing);
    agent.status = status.to_owned();
    agent.note = note.to_owned();
    agent
}

#[allow(clippy::too_many_arguments)]
fn finalize_local_agent(
    window: &CollectionWindow,
    id: &str,
    name: &str,
    source: &LocalAgentResult,
    note: &str,
    placeholder_status: &str,
    placeholder_note: &str,
    pricing: &PricingTable,
) -> AgentUsage {
    let mut accumulator = UsageAccumulator::new(window.clone());
    // C046: 合并失败不再静默 —— 与 aggregation.rs 同一诊断码, 并把 agent 降级为
    // partial (用量已缺失, 不能继续对外报 ok)。
    let merged = accumulator.merge_delta(&source.contribution);
    let mut agent = accumulator.finalize_with_pricing(id, name, pricing);
    if !merged {
        agent.status = "partial".to_owned();
        agent.note = format!("{note} (本机用量合并失败, 数据不完整)");
    }
    if let Some(diagnostic) = &source.diagnostic {
        agent.status = "error".to_owned();
        agent.note = match &source.history_note {
            Some(history_note) => format!("{diagnostic} ({history_note})"),
            None => diagnostic.clone(),
        };
    } else if let Some(history_note) = &source.history_note {
        // T26: 来源当前不可用但台账有历史量 —— 历史数据有效, 状态用 history 区分于 ok。
        agent.status = "history".to_owned();
        agent.note = history_note.clone();
    } else if source.found {
        if merged {
            agent.note = note.to_owned();
        }
    } else {
        agent.status = placeholder_status.to_owned();
        agent.note = placeholder_note.to_owned();
    }
    // C198: 信息级说明只附在 note 后, 不改变上面定下的状态; 故障时 note 已是故障说明。
    if let (None, Some(notice)) = (&source.diagnostic, &source.notice) {
        agent.note = format!("{} ({notice})", agent.note);
    }
    agent
}

fn window_diagnostic(error: WindowError) -> Diagnostic {
    Diagnostic::new(
        "BRIDGE_INVALID_REQUEST",
        "protocol",
        "window",
        error.to_string(),
        false,
    )
}

fn source_path(context: &RunContext<'_>, key: &str, default: PathBuf) -> PathBuf {
    context
        .request
        .context
        .get("paths")
        .and_then(Value::as_object)
        .and_then(|paths| paths.get(key))
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or(default)
}
