#![deny(unsafe_code)]

//! Rust collection application orchestration.
//!
//! The Bridge owns protocol validation and the response envelope. This module
//! owns the collection flow and keeps local aggregation details out of that
//! protocol seam.

mod account;
mod context;
mod execution;
mod paths;

use account::{build_account_plan, build_codex_account_plans, validate_account_request};
use collector_aggregate::UsageAccumulator;
use collector_credential::{
    validate_credential_challenges, validate_credential_updates, CredentialSource,
    SystemCredentialSource,
};
use collector_domain::{
    AgentUsage, AgentUsageArtifact, BridgeRequest, CollectionWindow, Diagnostic,
    ModelPricingOverride, PricingTable, WindowError, AGENT_USAGE_MODULE,
    AGENT_USAGE_SCHEMA_VERSION, LOCAL_SOURCE_ROWS_CAPPED,
};
use collector_local::{
    default_cache_root, remove_legacy_kimi_cache, scan_claude_cached, scan_codebuddy_cached,
    scan_codex_roots_cached, scan_grok_cached, scan_kimi_cli_cached, scan_kimi_tree_cached,
    scan_opencode_cached, scan_pi_cached, scan_zcode_cached, CodexRoot, ScanStats, SourceScan,
    SourceScanError,
};
use collector_provider::{HttpClient, ProviderError, UreqHttpClient};
use collector_runtime::{RuntimeError, RuntimeLimits};
use context::RunContext;
use execution::{execute_quota_accounts, QuotaExecution};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
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

/// Execute one collection run with production read-only adapters.
pub fn collect_agent_usage(request: &BridgeRequest) -> Result<CollectionOutput, Diagnostic> {
    let http = UreqHttpClient::default();
    let credentials = SystemCredentialSource::default();
    collect_agent_usage_with_dependencies(request, &http, &credentials)
}

/// Execute one collection run with injected HTTP and credential adapters.
/// This is the fixture seam used by application tests and never performs
/// external I/O unless the caller supplies an adapter that does so.
pub fn collect_agent_usage_with_dependencies(
    request: &BridgeRequest,
    http: &dyn HttpClient,
    credentials: &dyn CredentialSource,
) -> Result<CollectionOutput, Diagnostic> {
    collect_agent_usage_with_dependencies_inner(
        request,
        http,
        credentials,
        #[cfg(test)]
        None,
    )
}

fn collect_agent_usage_with_dependencies_inner(
    request: &BridgeRequest,
    http: &dyn HttpClient,
    credentials: &dyn CredentialSource,
    #[cfg(test)] final_probe: Option<&mut dyn FnMut(&collector_runtime::CancellationToken)>,
) -> Result<CollectionOutput, Diagnostic> {
    validate_account_request(request)?;
    let window = CollectionWindow::from_context(&request.context).map_err(window_diagnostic)?;
    let context = RunContext::new(request, window, http, credentials, RuntimeLimits::default())?;
    // C062: 额度仍新鲜/429 冷却时 Swift 只请求本地统计; 此时不启动额度 worker,
    // 也不输出 denied 占位, 避免把「本轮故意不查额度」误报成 partial.
    let local_usage_only = request
        .context
        .get("localUsageOnly")
        .and_then(Value::as_bool)
        == Some(true);
    if request
        .context
        .get("codexQuotaRetryOnly")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return collect_codex_quota_retry_only(&context);
    }
    let (local_result, quota_result) = std::thread::scope(|scope| {
        let local = scope.spawn(|| collect_local_usage(&context));
        let quota = (!local_usage_only && context.capability_allowed("externalQuotas"))
            .then(|| scope.spawn(|| collect_quota_usage(&context)));
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
    let local = local_result?;
    context
        .cancellation
        .check()
        .map_err(local_source_runtime_diagnostic)?;
    let mut diagnostics = local.diagnostics;
    let scan_stats = local.scan_stats;
    let source_metrics = local.source_metrics;
    let window = context.window.clone();
    let sessions_allowed = context.capability_allowed("localSessions");
    let pricing_overrides: HashMap<String, ModelPricingOverride> = request
        .context
        .get("pricingOverrides")
        .or_else(|| request.context.get("pricing_overrides"))
        .and_then(|val| serde_json::from_value(val.clone()).ok())
        .unwrap_or_default();
    let pricing_table = PricingTable::new(pricing_overrides);
    let placeholder_status = if sessions_allowed {
        "not_found"
    } else {
        "unavailable"
    };
    let placeholder_note = if sessions_allowed {
        "未发现会话记录"
    } else {
        "未授权 localSessions 能力, 已跳过本机会话扫描"
    };
    let agent_specs = [
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
            "当前经 CC Switch 路由, 额度见下方对应服务",
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
            "按消息内容估算, 非精确 token 计数",
            "未发现会话记录",
        ),
        (
            "orca",
            "Orca",
            "Orca 内置 Codex 会话, 额度见下方 Codex 账号",
            "未发现会话记录",
        ),
        ("pi", "Pi", "本机会话聚合", "未发现会话记录"),
        ("zcode", "ZCode", "本机会话聚合", "未发现会话记录"),
        ("codebuddy", "CodeBuddy", "本机会话聚合", "未发现会话记录"),
        ("opencode", "OpenCode", "本机会话聚合", "未发现会话记录"),
    ];
    let mut agents = Vec::with_capacity(agent_specs.len());
    for (id, name, note, not_found_note) in agent_specs {
        let missing_note = if sessions_allowed {
            not_found_note
        } else {
            placeholder_note
        };
        if let Some(source) = local.agents.get(id) {
            agents.push(finalize_local_agent(
                &window,
                id,
                name,
                source,
                note,
                placeholder_status,
                missing_note,
                &pricing_table,
            ));
        } else {
            agents.push(placeholder_agent(
                &window,
                id,
                name,
                placeholder_status,
                missing_note,
                &pricing_table,
            ));
        }
    }
    let (services, credential_updates, credential_challenges) = if local_usage_only {
        // 本轮只做本地统计: 不输出额度占位, 也不消费/产生额度诊断.
        (Vec::new(), Vec::new(), Vec::new())
    } else if context.capability_allowed("externalQuotas") {
        let quota = quota_result.unwrap_or_default();
        diagnostics.extend(quota.diagnostics);
        (
            quota.services,
            quota.credential_updates,
            quota.credential_challenges,
        )
    } else {
        (
            vec![
                denied_service(
                    "cc_switch_providers",
                    "CC Switch 云端额度",
                    "cc-switch",
                    &window,
                ),
                denied_service("codex_accounts", "Codex 账号额度", "codex", &window),
            ],
            Vec::new(),
            Vec::new(),
        )
    };
    if services.iter().any(|service| {
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
    #[cfg(test)]
    if let Some(probe) = final_probe {
        probe(&context.cancellation);
    }
    context
        .cancellation
        .check()
        .map_err(local_source_runtime_diagnostic)?;
    let total_cost = agents
        .iter()
        .filter_map(|agent| agent.today_cost_usd)
        .sum::<f64>();
    let artifact = AgentUsageArtifact {
        schema_version: AGENT_USAGE_SCHEMA_VERSION,
        module: AGENT_USAGE_MODULE.to_owned(),
        generated_at: window.generated_at(),
        agents,
        services,
        total_cost_usd: (total_cost > 0.0).then_some(total_cost),
    };
    let artifact = serde_json::to_value(artifact).map_err(|_| {
        Diagnostic::new(
            "ARTIFACT_SERIALIZATION_FAILED",
            "collector",
            "serialize",
            "artifact 序列化失败",
            false,
        )
    })?;
    context
        .cancellation
        .check()
        .map_err(local_source_runtime_diagnostic)?;
    Ok(CollectionOutput {
        artifact,
        diagnostics,
        generated_at: window.generated_at(),
        scan_stats,
        metrics: context.metrics.snapshot(),
        source_metrics,
        credential_updates,
        credential_challenges,
    })
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
    diagnostic: Option<String>,
    /// 行数截断 (C041): 信息级降级, agent 状态保持 ok 而非 error。
    capped: bool,
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
    let jobs = local_source_jobs(context, &home, &cache_root);
    // C110 / C116: 9 个本机源交给 local_workers 大小的工作池并行扫描, 结果按源序合并,
    // 诊断与指标顺序不变。
    for (mut source, source_metric, degradation) in run_local_sources(context, jobs)? {
        let id = source_metric.source_id.clone();
        // C119: 共享扫描拆出的附属 agent (Orca) 只带贡献; 统计与诊断归主源
        for companion in std::mem::take(&mut source.companions) {
            collection.agents.insert(
                companion.source_id.to_owned(),
                LocalAgentResult {
                    found: companion.found,
                    contribution: companion.contribution,
                    diagnostic: None,
                    capped: false,
                },
            );
        }
        collection.source_metrics.push(source_metric);
        collection.scan_stats.merge(source.stats.clone());
        // C046: 源读取失败 (I/O) 以信息级诊断暴露, 不再完全静默。
        if let Some(warning) = degradation {
            collection.diagnostics.push(warning);
        }
        if let Some(message) = source.diagnostic.clone() {
            // C041: 行数截断是计划内降级, 用信息级诊断码;
            // 其余 (真实 schema/读取故障) 保留原故障码与 Partial 语义。
            let code = if source.capped {
                LOCAL_SOURCE_ROWS_CAPPED
            } else {
                "LOCAL_SOURCE_SCHEMA_INCOMPATIBLE"
            };
            collection
                .diagnostics
                .push(Diagnostic::new(code, "local", &id, message, true));
        }
        collection.agents.insert(
            id,
            LocalAgentResult {
                found: source.found,
                contribution: source.contribution,
                diagnostic: source.diagnostic,
                capped: source.capped,
            },
        );
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
    // C119: Orca 内置 Codex 的会话与 Codex CLI 一起去重, 归属到 Orca 行
    let orca_root = |path| CodexRoot {
        path,
        companion: Some("orca"),
    };
    let mut codex_roots = vec![
        CodexRoot {
            path: codex,
            companion: None,
        },
        orca_root(orca_sessions),
    ];
    if let Ok(entries) = fs::read_dir(&orca_accounts) {
        for entry in entries.flatten() {
            let sessions = entry.path().join("home").join("sessions");
            if sessions.is_dir() {
                codex_roots.push(orca_root(sessions));
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
                scan_codex_roots_cached(&codex_roots, window, cache_root, cancellation)
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

#[cfg(test)]
fn collect_agent_usage_with_final_probe<F>(
    request: &BridgeRequest,
    http: &dyn HttpClient,
    credentials: &dyn CredentialSource,
    mut probe: F,
) -> Result<CollectionOutput, Diagnostic>
where
    F: FnMut(&collector_runtime::CancellationToken),
{
    collect_agent_usage_with_dependencies_inner(request, http, credentials, Some(&mut probe))
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

fn collect_codex_quota_retry_only(
    context: &RunContext<'_>,
) -> Result<CollectionOutput, Diagnostic> {
    let quota = match build_codex_account_plans(context.request) {
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
    context.cancellation.check().map_err(runtime_diagnostic)?;
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
        if source.capped {
            // C041: 行数截断为计划内降级, 数据有效 (保留最新), 不按故障处理。
            agent.note = diagnostic.clone();
        } else {
            agent.status = "error".to_owned();
            agent.note = diagnostic.clone();
        }
    } else if source.found {
        if merged {
            agent.note = note.to_owned();
        }
    } else {
        agent.status = placeholder_status.to_owned();
        agent.note = placeholder_note.to_owned();
    }
    agent
}

fn denied_service(id: &str, name: &str, app: &str, window: &CollectionWindow) -> Value {
    json!({
        "id": id,
        "name": name,
        "app": app,
        "isCurrent": false,
        "status": "partial",
        "kind": null,
        "plan": null,
        "windows": [],
        "balance": null,
        "currency": null,
        "capturedAt": window.generated_at(),
        "note": "未授权 externalQuotas 能力, 已跳过云端额度查询",
    })
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

#[cfg(test)]
mod tests {
    use super::{
        collect_agent_usage, collect_agent_usage_with_dependencies, finalize_local_agent,
        LocalAgentResult,
    };
    use collector_credential::{CredentialReadError, CredentialSource};
    use collector_domain::BridgeRequest;
    use collector_provider::{
        codex_service_id, HttpClient, HttpRequest, HttpResponse, ProviderError,
    };
    use collector_runtime::CancellationToken;
    use serde_json::json;
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// C041: 行数截断为计划内降级 — agent 状态保持 ok 仅记 note; 真实故障仍为 error。
    #[test]
    fn local_agent_row_cap_keeps_status_ok_while_faults_stay_error() {
        use collector_domain::{CollectionWindow, PricingTable};

        let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let pricing = PricingTable::new(std::collections::HashMap::new());
        let contribution =
            collector_domain::UsageContributionBuilder::new(window.clone()).contribution();

        let capped = LocalAgentResult {
            found: true,
            contribution: contribution.clone(),
            diagnostic: Some("仅保留 zcode 最新 30000 条用量记录".to_owned()),
            capped: true,
        };
        let agent = finalize_local_agent(
            &window,
            "zcode",
            "ZCode",
            &capped,
            "本机会话聚合",
            "unavailable",
            "未发现会话记录",
            &pricing,
        );
        assert_eq!(agent.status, "ok", "行数截断为计划内降级, 不得置为 error");
        assert!(agent.note.contains("30000"), "降级说明应保留在 note");

        let faulty = LocalAgentResult {
            capped: false,
            ..capped
        };
        let agent = finalize_local_agent(
            &window,
            "zcode",
            "ZCode",
            &faulty,
            "本机会话聚合",
            "unavailable",
            "未发现会话记录",
            &pricing,
        );
        assert_eq!(agent.status, "error", "非截断诊断仍按故障处理");
        assert_eq!(agent.note, "仅保留 zcode 最新 30000 条用量记录");
    }

    /// C046: 用量合并失败必须可见 —— agent 降级为 partial 且 note 说明缺失,
    /// 不得继续对外报 ok 而静默丢数据。
    #[test]
    fn local_agent_merge_failure_is_visible_not_silent() {
        use collector_domain::{CollectionWindow, PricingTable, UsageContribution};

        let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let pricing = PricingTable::new(std::collections::HashMap::new());

        // 构造不可合并的 contribution: 某天不在当前窗口 day_list 内
        let mut invalid = UsageContribution {
            by_day: std::collections::BTreeMap::new(),
            models_by_month: std::collections::BTreeMap::new(),
            models_today: Vec::new(),
            projects_today: Vec::new(),
            hours: Vec::new(),
            models_by_day: std::collections::BTreeMap::new(),
            hour_models_today: std::collections::BTreeMap::new(),
        };
        invalid.by_day.insert(
            "1999-01-01".to_owned(),
            collector_domain::TokenBucket {
                input: 1,
                output: 1,
                cache_read: 0,
                cache_creation: 0,
                cache_creation_1h: 0,
                total: 2,
            },
        );

        let source = LocalAgentResult {
            found: true,
            contribution: invalid,
            diagnostic: None,
            capped: false,
        };
        let agent = finalize_local_agent(
            &window,
            "claude-code",
            "Claude Code",
            &source,
            "本机会话聚合",
            "unavailable",
            "未发现会话记录",
            &pricing,
        );
        assert_eq!(
            agent.status, "partial",
            "合并失败必须降级为 partial, 不得静默报 ok"
        );
        assert!(
            agent.note.contains("合并失败"),
            "note 必须说明数据不完整: {}",
            agent.note
        );
    }

    fn request(capabilities: &[&str]) -> BridgeRequest {
        serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {"capabilities": capabilities},
            "credentials": {}
        }))
        .expect("fixture request should deserialize")
    }

    struct FixtureHttp {
        calls: AtomicUsize,
        body: Vec<u8>,
    }

    impl HttpClient for FixtureHttp {
        fn send(
            &self,
            _request: HttpRequest,
            cancellation: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            cancellation.check().map_err(ProviderError::from_runtime)?;
            self.calls.fetch_add(1, Ordering::AcqRel);
            Ok(HttpResponse {
                status: 200,
                body: self.body.clone(),
            })
        }
    }

    struct EmptyCredentialSource;

    impl CredentialSource for EmptyCredentialSource {
        fn read_file(&self, _path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError> {
            Ok(None)
        }

        fn read_keychain(&self, _service: &str) -> Result<Option<String>, CredentialReadError> {
            Ok(None)
        }
    }

    struct HostCredentialAccessMustNotBeUsed;

    impl CredentialSource for HostCredentialAccessMustNotBeUsed {
        fn read_file(&self, _path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError> {
            panic!("collector must not read host credential files without injection")
        }

        fn read_keychain(&self, _service: &str) -> Result<Option<String>, CredentialReadError> {
            panic!("collector must not read host Keychain without injection")
        }
    }

    struct StatusFixtureHttp {
        calls: AtomicUsize,
        status: u16,
    }

    impl HttpClient for StatusFixtureHttp {
        fn send(
            &self,
            _request: HttpRequest,
            cancellation: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            cancellation.check().map_err(ProviderError::from_runtime)?;
            self.calls.fetch_add(1, Ordering::AcqRel);
            Ok(HttpResponse {
                status: self.status,
                body: br#"{"error":"fixture"}"#.to_vec(),
            })
        }
    }

    #[test]
    fn application_preserves_capability_denied_local_semantics() {
        let output = collect_agent_usage(&request(&[])).unwrap();
        let artifact = output.artifact.as_object().unwrap();
        assert_eq!(artifact["agents"][1]["status"], "unavailable");
        assert_eq!(artifact["services"][0]["status"], "partial");
    }

    fn local_or_skipped_request(context_extra: serde_json::Value) -> BridgeRequest {
        let mut request = request(&["localSessions", "localPricing", "externalQuotas"]);
        request.context.insert(
            "home".to_owned(),
            json!(std::env::temp_dir().to_string_lossy()),
        );
        request.credentials.insert(
            "claudeQuotaAccounts".to_owned(),
            json!({
                "acc": {
                    "display_name": "Claude",
                    "oauth": {"claudeAiOauth": {"accessToken": "tok"}}
                }
            }),
        );
        request.credentials.insert(
            "providerMeta".to_owned(),
            json!({"claude": {"enabled": true}}),
        );
        if let Some(extra) = context_extra.as_object() {
            for (key, value) in extra {
                request.context.insert(key.clone(), value.clone());
            }
        }
        request
    }

    #[test]
    fn local_usage_only_skips_quota_and_denied_placeholders() {
        let request = local_or_skipped_request(json!({"localUsageOnly": true}));
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: b"{}".to_vec(),
        };
        let output = collect_agent_usage_with_dependencies(
            &request,
            &http,
            &HostCredentialAccessMustNotBeUsed,
        )
        .unwrap();
        assert_eq!(http.calls.load(Ordering::Acquire), 0, "不得发起额度请求");
        let artifact = output.artifact.as_object().unwrap();
        assert!(
            artifact["services"].as_array().unwrap().is_empty(),
            "不得输出占位 service"
        );
        assert!(
            !output
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.code == "COLLECTOR_PARTIAL_RESULT"),
            "本地专用 run 不得被误报为 partial"
        );
    }

    #[test]
    fn quota_skip_providers_avoids_http_requests() {
        let request = local_or_skipped_request(json!({"quotaSkipProviders": ["claude"]}));
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: b"{}".to_vec(),
        };
        let output = collect_agent_usage_with_dependencies(
            &request,
            &http,
            &HostCredentialAccessMustNotBeUsed,
        )
        .unwrap();
        assert_eq!(
            http.calls.load(Ordering::Acquire),
            0,
            "跳过 provider 不得发起请求"
        );
        let artifact = output.artifact.as_object().unwrap();
        assert!(
            artifact["services"].as_array().unwrap().is_empty(),
            "跳过的 provider 不应出现在本轮 services"
        );
    }

    #[test]
    fn application_does_not_fallback_to_host_credentials_for_official_providers() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"]
            },
            "credentials": {
                "providerMeta": {
                    "claude": {"enabled": true},
                    "grok": {"enabled": true}
                }
            }
        }))
        .unwrap();
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{}"#.to_vec(),
        };
        let output = collect_agent_usage_with_dependencies(
            &request,
            &http,
            &HostCredentialAccessMustNotBeUsed,
        )
        .unwrap();
        assert_eq!(http.calls.load(Ordering::Acquire), 0);
        assert!(
            output
                .diagnostics
                .iter()
                .filter(|diagnostic| diagnostic.code == "CREDENTIAL_MISSING")
                .count()
                >= 2
        );
    }

    #[test]
    fn cancelled_local_run_returns_existing_diagnostic_without_artifact() {
        let home = std::env::temp_dir().join(format!(
            "bruce-cancelled-local-run-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".kimi-code/sessions")).unwrap();
        let mut request = request(&["localSessions"]);
        request.context.insert(
            "home".to_owned(),
            serde_json::Value::String(home.to_string_lossy().into_owned()),
        );
        request.timeouts.module_seconds = 0.0;

        let result = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        );

        assert_eq!(
            result.unwrap_err().code,
            "LOCAL_SOURCE_CANCELLED",
            "a cancelled local run must fail before publishing a partial artifact"
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn cancellation_after_last_source_is_fenced_before_artifact_publication() {
        let result = super::collect_agent_usage_with_final_probe(
            &request(&[]),
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
            |cancellation| cancellation.cancel(),
        );

        assert_eq!(
            result.unwrap_err().code,
            "LOCAL_SOURCE_CANCELLED",
            "final cancellation must prevent a new artifact from being returned"
        );
    }

    #[test]
    fn source_metrics_follow_the_stable_local_source_order() {
        let home =
            std::env::temp_dir().join(format!("bruce-source-metrics-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".kimi-code/sessions")).unwrap();
        let mut request = request(&["localSessions"]);
        request.context.insert(
            "home".to_owned(),
            serde_json::Value::String(home.to_string_lossy().into_owned()),
        );

        let output = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();

        assert_eq!(
            output
                .source_metrics
                .iter()
                .map(|metric| metric.source_id.as_str())
                .collect::<Vec<_>>(),
            vec![
                "kimi-code-cli",
                "kimi-work",
                "claude-code",
                "codex",
                "codebuddy",
                "grok",
                "opencode",
                "pi",
                "zcode",
            ]
        );
        assert!(output.artifact.get("sources").is_none());
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn warm_jsonl_sources_keep_agent_results_and_skip_body_parsing() {
        let home = std::env::temp_dir().join(format!(
            "bruce-warm-jsonl-sources-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&home);
        let kimi_work = home.join("kimi-work");
        let claude = home.join("claude/project");
        let codebuddy = home.join("codebuddy/project");
        let grok = home.join("grok/sessions/project/session");
        let pi = home.join("pi");
        for path in [&kimi_work, &claude, &codebuddy, &grok, &pi] {
            std::fs::create_dir_all(path).unwrap();
        }
        std::fs::write(
            kimi_work.join("session.jsonl"),
            json!({
                "type": "usage.record",
                "time": 1_788_912_000_000_i64,
                "model": "kimi-k2",
                "usage": {"inputOther": 10, "output": 2}
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            claude.join("session.jsonl"),
            json!({
                "type": "assistant",
                "timestamp": "2026-09-09T04:00:00Z",
                "message": {
                    "id": "warm-claude-message",
                    "model": "claude-sonnet",
                    "usage": {"input_tokens": 11, "output_tokens": 3}
                }
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            codebuddy.join("session.jsonl"),
            json!({
                "type": "message",
                "role": "assistant",
                "timestamp": 1_789_128_000_000_i64,
                "message": {"usage": {"input_tokens": 12, "output_tokens": 4}},
                "providerData": {"model": "codebuddy-model", "messageId": "warm-codebuddy-message"}
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            grok.join("conversation.jsonl"),
            json!({"type": "assistant", "content": "abcdefgh"}).to_string(),
        )
        .unwrap();
        std::fs::write(
            pi.join("session.jsonl"),
            json!({
                "type": "message",
                "message": {
                    "role": "assistant",
                    "timestamp": 1_789_128_000_000_i64,
                    "model": "pi-model",
                    "usage": {"input": 13, "output": 5}
                }
            })
            .to_string(),
        )
        .unwrap();

        let mut request = request(&["localSessions"]);
        request.context.insert(
            "home".to_owned(),
            serde_json::Value::String(home.to_string_lossy().into_owned()),
        );
        request
            .context
            .insert("now".to_owned(), json!("2026-09-09T12:00:00+08:00"));
        request
            .context
            .insert("timezone".to_owned(), json!("Asia/Shanghai"));
        request.context.insert("days".to_owned(), json!(14));
        request.context.insert(
            "paths".to_owned(),
            json!({
                "kimi_cli_sessions": home.join("kimi-cli").to_string_lossy(),
                "daimon_kimi_sessions": kimi_work,
                "claude_projects": home.join("claude"),
                "codex_sessions": home.join("codex"),
                "orca_home": home.join("orca"),
                "grok_home": home.join("grok"),
                "pi_sessions": pi,
                "opencode_db": home.join("opencode.db"),
                "zcode_db": home.join("zcode.db"),
                "codebuddy_projects": home.join("codebuddy")
            }),
        );

        let first = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();
        let second = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();

        assert_eq!(first.artifact["agents"], second.artifact["agents"]);
        assert!(second.scan_stats.cache_hits > 0);
        assert_eq!(second.scan_stats.json_lines_parsed, 0);
        for source_id in ["kimi-work", "claude-code", "codebuddy", "grok", "pi"] {
            let metric = second
                .source_metrics
                .iter()
                .find(|metric| metric.source_id == source_id)
                .expect("source metric should be present");
            assert!(metric.stats.cache_hits > 0, "{source_id} should be warm");
            assert_eq!(
                metric.stats.json_lines_parsed, 0,
                "{source_id} should not parse JSONL"
            );
        }
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn codex_warm_cache_preserves_found_status() {
        let home = std::env::temp_dir().join(format!(
            "bruce-codex-warm-cache-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&home);
        let codex_root = home.join("codex");
        let rollout = codex_root.join("2026/07/28/rollout-warm.jsonl");
        std::fs::create_dir_all(rollout.parent().unwrap()).unwrap();
        std::fs::write(
            &rollout,
            br#"{"timestamp":"2026-07-28T04:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3}}}}
"#,
        )
        .unwrap();

        let empty = home.join("empty");
        let empty_paths = [
            ("kimi_cli_sessions", empty.join("kimi-cli")),
            ("daimon_kimi_sessions", empty.join("kimi-work")),
            ("claude_projects", empty.join("claude")),
            ("orca_codex_sessions", empty.join("orca-sessions")),
            ("orca_home", empty.join("orca-home")),
            ("grok_home", empty.join("grok")),
            ("pi_sessions", empty.join("pi")),
            ("opencode_db", empty.join("opencode.db")),
            ("zcode_db", empty.join("zcode.db")),
            ("codebuddy_projects", empty.join("codebuddy")),
        ];
        let paths = empty_paths
            .into_iter()
            .map(|(key, path)| {
                (
                    key.to_owned(),
                    serde_json::Value::String(path.to_string_lossy().into_owned()),
                )
            })
            .chain(std::iter::once((
                "codex_sessions".to_owned(),
                serde_json::Value::String(codex_root.to_string_lossy().into_owned()),
            )))
            .collect();
        let mut request = request(&["localSessions"]);
        request.context.insert(
            "home".to_owned(),
            serde_json::Value::String(home.to_string_lossy().into_owned()),
        );
        request.context.insert(
            "now".to_owned(),
            serde_json::Value::String("2026-07-28T12:00:00+08:00".to_owned()),
        );
        request
            .context
            .insert("timezone".to_owned(), json!("Asia/Shanghai"));
        request.context.insert("days".to_owned(), json!(3));
        request
            .context
            .insert("paths".to_owned(), serde_json::Value::Object(paths));

        let first = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();
        let second = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();

        let first_codex = first.artifact["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["id"] == "codex")
            .unwrap();
        let second_codex = second.artifact["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["id"] == "codex")
            .unwrap();
        assert_ne!(first_codex["status"], "not_found");
        assert_ne!(second_codex["status"], "not_found");
        let _ = std::fs::remove_dir_all(home);
    }

    /// C119: Orca 内置 Codex 的会话计入 Orca 行 (此前并入 Codex, Orca 行恒为 not_found)。
    #[test]
    fn orca_sessions_populate_the_orca_row_instead_of_codex() {
        let home = std::env::temp_dir().join(format!(
            "bruce-orca-attribution-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&home);
        let rollout = |root: &std::path::Path, name: &str, input: u64, output: u64| {
            let path = root.join("2026/07/28").join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(
                &path,
                format!(
                    "{}\n",
                    json!({"timestamp": "2026-07-28T04:00:00Z", "type": "event_msg",
                        "payload": {"type": "token_count", "info": {"last_token_usage":
                            {"input_tokens": input, "cached_input_tokens": 0, "output_tokens": output}}}})
                ),
            )
            .unwrap();
        };
        let codex_root = home.join("codex");
        let orca_home = home.join("orca");
        let orca_sessions = orca_home.join("codex-runtime-home/home/sessions");
        rollout(&codex_root, "rollout-cli.jsonl", 10, 3);
        rollout(&orca_sessions, "rollout-orca.jsonl", 7, 2);

        let empty = home.join("empty");
        let mut paths = serde_json::Map::new();
        for (key, path) in [
            ("kimi_cli_sessions", empty.join("kimi-cli")),
            ("daimon_kimi_sessions", empty.join("kimi-work")),
            ("claude_projects", empty.join("claude")),
            ("grok_home", empty.join("grok")),
            ("pi_sessions", empty.join("pi")),
            ("opencode_db", empty.join("opencode.db")),
            ("zcode_db", empty.join("zcode.db")),
            ("codebuddy_projects", empty.join("codebuddy")),
            ("codex_sessions", codex_root),
            ("orca_home", orca_home),
            ("orca_codex_sessions", orca_sessions),
        ] {
            paths.insert(key.to_owned(), json!(path.to_string_lossy()));
        }
        let mut request = request(&["localSessions"]);
        for (key, value) in [
            ("home", json!(home.to_string_lossy())),
            ("now", json!("2026-07-28T12:00:00+08:00")),
            ("timezone", json!("Asia/Shanghai")),
            ("days", json!(3)),
            ("paths", serde_json::Value::Object(paths)),
        ] {
            request.context.insert(key.to_owned(), value);
        }
        let output = collect_agent_usage_with_dependencies(
            &request,
            &FixtureHttp {
                calls: AtomicUsize::new(0),
                body: Vec::new(),
            },
            &EmptyCredentialSource,
        )
        .unwrap();
        let agent = |id: &str| {
            output.artifact["agents"]
                .as_array()
                .unwrap()
                .iter()
                .find(|agent| agent["id"] == id)
                .unwrap()
                .clone()
        };
        let (codex, orca) = (agent("codex"), agent("orca"));
        assert_eq!(codex["status"], "ok");
        assert_eq!(orca["status"], "ok");
        assert_eq!(orca["note"], "Orca 内置 Codex 会话, 额度见下方 Codex 账号");
        assert_eq!(codex["today"]["total"], 13, "Codex 只含 CLI 会话");
        assert_eq!(orca["today"]["total"], 9, "Orca 会话计入 Orca 行");
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn application_executes_injected_quota_account_through_registry() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"]
            },
            "credentials": {
                "kimiQuotaAccounts": {
                    "acct-a": {"display_name": "Kimi A", "api_key": "fixture-key"}
                }
            }
        }))
        .unwrap();
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{"limits":[{"detail":{"limit":100,"remaining":25,"resetTime":"2026-08-21T09:00:00Z"}}]}"#.to_vec(),
        };
        let credentials = EmptyCredentialSource;
        let output = collect_agent_usage_with_dependencies(&request, &http, &credentials).unwrap();
        let services = output.artifact["services"].as_array().unwrap();
        assert_eq!(services.len(), 1);
        assert_eq!(services[0]["id"], "kimi_coding_acct-a");
        assert_eq!(services[0]["status"], "ok");
        assert_eq!(services[0]["windows"][0]["usedPercent"], 75.0);
        assert_eq!(output.metrics.http_request_count, 1);
        assert_eq!(http.calls.load(Ordering::Acquire), 1);
    }

    #[test]
    fn application_executes_ordered_codex_accounts_with_stable_services() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"],
                "codexQuotaAccountOrder": ["acc-z", "acc-a"]
            },
            "credentials": {
                "codexQuotaAccounts": {
                    "acc-a": {
                        "display_name": "Codex · A",
                        "access_token": "fixture-a"
                    },
                    "acc-z": {
                        "display_name": "Codex · Z",
                        "access_token": "fixture-z"
                    }
                }
            }
        }))
        .unwrap();
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{"plan_type":"fixture","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42,"reset_at":"2026-08-21T13:00:00Z"}}}"#.to_vec(),
        };
        let output =
            collect_agent_usage_with_dependencies(&request, &http, &EmptyCredentialSource).unwrap();
        let services = output.artifact["services"].as_array().unwrap();
        assert_eq!(services.len(), 2);
        assert_eq!(services[0]["id"], codex_service_id("acc-z"));
        assert_eq!(services[1]["id"], codex_service_id("acc-a"));
        assert_eq!(services[0]["name"], "Codex · Z");
        assert_eq!(services[0]["status"], "ok");
        assert_eq!(services[0]["windows"][0]["usedPercent"], 42.0);
        assert!(output.credential_challenges.is_empty());
        assert_eq!(output.metrics.http_request_count, 2);
        assert_eq!(http.calls.load(Ordering::Acquire), 2);
    }

    #[test]
    fn application_emits_codex_challenge_without_credentials_in_output() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"],
                "codexQuotaAccountOrder": ["acc-1"]
            },
            "credentials": {
                "codexQuotaAccounts": {
                    "acc-1": {
                        "display_name": "Codex · user",
                        "access_token": "fixture-secret-token"
                    }
                }
            }
        }))
        .unwrap();
        let http = StatusFixtureHttp {
            calls: AtomicUsize::new(0),
            status: 401,
        };
        let output =
            collect_agent_usage_with_dependencies(&request, &http, &EmptyCredentialSource).unwrap();
        let service = &output.artifact["services"][0];
        assert_eq!(service["id"], codex_service_id("acc-1"));
        assert_eq!(service["status"], "error");
        assert_eq!(service["freshness"], "unavailable");
        assert_eq!(service["failureKind"], "auth");
        assert_eq!(
            output.credential_challenges,
            vec![json!({
                "provider": "codex",
                "accountId": "acc-1",
                "reason": "accessRejected"
            })]
        );
        let serialized = serde_json::to_string(&output.artifact).unwrap();
        assert!(!serialized.contains("fixture-secret-token"));
        assert_eq!(http.calls.load(Ordering::Acquire), 1);
    }

    #[test]
    fn codex_retry_only_skips_local_agents_and_returns_only_codex_services() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"],
                "codexQuotaRetryOnly": true,
                "codexQuotaAccountOrder": ["acc-1"]
            },
            "credentials": {
                "codexQuotaAccounts": {
                    "acc-1": {
                        "display_name": "Codex · user",
                        "access_token": "fixture-token"
                    }
                }
            }
        }))
        .unwrap();
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{"plan_type":"fixture","rate_limit":{"primary_window":{"limit_window_seconds":18000,"used_percent":42}}}"#.to_vec(),
        };
        let output =
            collect_agent_usage_with_dependencies(&request, &http, &EmptyCredentialSource).unwrap();
        assert!(output.artifact["agents"].as_array().unwrap().is_empty());
        assert_eq!(output.artifact["services"].as_array().unwrap().len(), 1);
        assert_eq!(output.artifact["services"][0]["app"], "codex");
        assert_eq!(http.calls.load(Ordering::Acquire), 1);
    }

    #[test]
    fn external_quota_capability_denied_skips_http_and_credential_sources() {
        let mut request = request(&[]);
        request.credentials.insert(
            "kimiQuotaAccounts".to_owned(),
            json!({"acct-a": {"api_key": "must-not-be-read"}}),
        );
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{}"#.to_vec(),
        };
        let credentials = EmptyCredentialSource;
        let output = collect_agent_usage_with_dependencies(&request, &http, &credentials).unwrap();
        assert_eq!(http.calls.load(Ordering::Acquire), 0);
        assert_eq!(output.artifact["services"][0]["status"], "partial");
        assert_eq!(output.metrics.http_request_count, 0);
    }

    #[test]
    fn application_emits_credential_update_for_stepfun_refresh() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"]
            },
            "credentials": {
                "stepfunQuotaAccounts": {
                    "step-1": {
                        "display_name": "StepFun · user",
                        "token": "header.part1.sig...header.eyJhcHBfaWQiOjEwMzAwLCJkZXZpY2VfaWQiOiJkZXYtMSJ9.sig"
                    }
                }
            }
        }))
        .unwrap();

        struct StepFunMockHttp {
            calls: AtomicUsize,
        }
        impl HttpClient for StepFunMockHttp {
            fn send(
                &self,
                _req: HttpRequest,
                _cancellation: &collector_runtime::CancellationToken,
            ) -> Result<HttpResponse, ProviderError> {
                let call = self.calls.fetch_add(1, Ordering::SeqCst);
                match call {
                    0 => Ok(HttpResponse {
                        status: 401,
                        body: b"unauthenticated".to_vec(),
                    }),
                    1 => Ok(HttpResponse {
                        status: 200,
                        body: serde_json::to_vec(&json!({
                            "accessToken": {"raw": "header.refreshed_access.sig"},
                            "refreshToken": {"raw": "header.refreshed_refresh.sig"}
                        }))
                        .unwrap(),
                    }),
                    2 => Ok(HttpResponse {
                        status: 200,
                        body: serde_json::to_vec(&json!({
                            "status": 1,
                            "desc": "",
                            "plan_credit_rate_limit": {
                                "subscription_credit_left_rate": 0.9,
                                "subscription_credit_reset_time": "1792485144",
                                "credit_buckets": []
                            }
                        }))
                        .unwrap(),
                    }),
                    _ => panic!("unexpected call count"),
                }
            }
        }

        let http = StepFunMockHttp {
            calls: AtomicUsize::new(0),
        };
        let output =
            collect_agent_usage_with_dependencies(&request, &http, &EmptyCredentialSource).unwrap();
        assert_eq!(
            output.credential_updates,
            vec![json!({
                "provider": "stepfun",
                "accountId": "step-1",
                "kind": "oauthTokens",
                "operation": "replace",
                "credentials": {
                    "access_token": "header.refreshed_access.sig...header.refreshed_refresh.sig"
                }
            })]
        );
        let service = &output.artifact["services"][0];
        assert_eq!(service["app"], "stepfun");
        assert_eq!(service["status"], "ok");
        assert!(service.get("credential_update").is_none());
        assert_eq!(http.calls.load(Ordering::Acquire), 3);
    }
}
