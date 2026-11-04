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

use account::{build_account_plan, validate_account_request};
use collector_aggregate::UsageAccumulator;
use collector_credential::{
    validate_credential_challenges, validate_credential_updates, CredentialSource,
    SystemCredentialSource,
};
use collector_domain::{
    AgentUsage, AgentUsageArtifact, BridgeRequest, CollectionWindow, Diagnostic,
    ModelPricingOverride, PricingTable, WindowError, AGENT_USAGE_MODULE,
    AGENT_USAGE_SCHEMA_VERSION, LOCAL_HISTORY_STORE_UNAVAILABLE, LOCAL_SOURCE_NOTICE,
};
use collector_history::HistoryStore;
use collector_local::{
    default_cache_root, remove_legacy_kimi_cache, scan_claude_cached, scan_codebuddy_cached,
    scan_codex_cached_with_cancellation, scan_dsh_cached, scan_grok_cached, scan_kimi_cli_cached,
    scan_kimi_tree_cached, scan_opencode_cached, scan_pi_cached, scan_zcode_cached, ScanStats,
    SourceScan, SourceScanError,
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
) -> Result<CollectionOutput, CollectionFailure> {
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
) -> Result<CollectionOutput, CollectionFailure> {
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
        .get("quotaRetryOnly")
        .and_then(Value::as_bool)
        == Some(true)
    {
        return collect_quota_retry_only(&context);
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
    // C171: 额度线程已完成, 其轮换令牌在服务端已生效; 此后任何一步失败都随错误带出。
    let pending_updates = quota_result
        .as_ref()
        .map(|quota| quota.credential_updates.clone())
        .unwrap_or_default();
    let failed = |diagnostic: Diagnostic| CollectionFailure {
        diagnostic,
        credential_updates: pending_updates.clone().into_boxed_slice(),
    };
    let local = local_result.map_err(failed)?;
    context
        .cancellation
        .check()
        .map_err(|error| failed(local_source_runtime_diagnostic(error)))?;
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
    let pricing_table = match request.context.get("pricingCatalog") {
        Some(raw) => {
            let bytes = serde_json::to_vec(raw).unwrap_or_default();
            match collector_domain::pricing::CatalogFile::parse_and_validate(&bytes) {
                Ok(catalog_file) => {
                    // 防倒退 Anti-Rollback: 若传入价格表早于内置基线版本，回退至内置基线
                    if catalog_file.is_older_than(collector_domain::pricing::builtin_updated_at()) {
                        PricingTable::new(pricing_overrides)
                    } else {
                        PricingTable::with_catalog(&catalog_file.models, pricing_overrides)
                    }
                }
                Err(_) => PricingTable::new(pricing_overrides),
            }
        }
        None => PricingTable::new(pricing_overrides),
    };
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
        // C124: 未授予 externalQuotas (无订阅凭证 / 未同意授权) 即不涉及云端额度, 不输出
        // 占位 service。旧版输出的「CC Switch 云端额度」/「Codex 账号额度」占位状态为
        // partial, 会让纯本机统计的每一轮都带 COLLECTOR_PARTIAL_RESULT 而显示为部分失败。
        (Vec::new(), Vec::new(), Vec::new())
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
        .map_err(|error| failed(local_source_runtime_diagnostic(error)))?;
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
        failed(Diagnostic::new(
            "ARTIFACT_SERIALIZATION_FAILED",
            "collector",
            "serialize",
            "artifact 序列化失败",
            false,
        ))
    })?;
    context
        .cancellation
        .check()
        .map_err(|error| failed(local_source_runtime_diagnostic(error)))?;
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
) -> Result<CollectionOutput, CollectionFailure>
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

#[cfg(test)]
mod tests {
    use super::{
        collect_agent_usage, collect_agent_usage_with_dependencies, finalize_local_agent,
        LocalAgentResult, LOCAL_HISTORY_STORE_UNAVAILABLE, LOCAL_SOURCE_NOTICE,
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
                ..Default::default()
            },
        );

        let source = LocalAgentResult {
            found: true,
            contribution: invalid,
            diagnostic: None,
            notice: None,
            history_note: None,
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

    struct EgressFixtureHttp {
        loc: &'static str,
        direct: AtomicUsize,
        proxy: AtomicUsize,
        probes: AtomicUsize,
    }

    impl HttpClient for EgressFixtureHttp {
        fn send(
            &self,
            _: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            self.direct.fetch_add(1, Ordering::SeqCst);
            Ok(HttpResponse {
                status: 200,
                body: b"{}".to_vec(),
            })
        }

        fn send_via_loopback_proxy(
            &self,
            port: u16,
            request: HttpRequest,
            _: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            assert_eq!(port, 12345);
            if request.url.contains("cdn-cgi/trace") {
                self.probes.fetch_add(1, Ordering::SeqCst);
                if self.loc == "FAIL" {
                    return Err(ProviderError::new(
                        "TEST_TIMEOUT",
                        "request",
                        "timeout",
                        true,
                    ));
                }
                return Ok(HttpResponse {
                    status: 200,
                    body: format!("ip=192.0.2.1\nloc={}\n", self.loc).into_bytes(),
                });
            }
            self.proxy.fetch_add(1, Ordering::SeqCst);
            Ok(HttpResponse {
                status: 200,
                body: br#"{"is_available":true,"balance_infos":[]}"#.to_vec(),
            })
        }
    }

    #[test]
    fn protected_quota_uses_proxy_and_blocks_mismatched_trace() {
        for (loc, expected_queries) in [("CN", 0), ("US", 0), ("FAIL", 0), ("JP", 1)] {
            let mut request = request(&["externalQuotas"]);
            request.context.insert(
                "egressRules".into(),
                json!({"deepseek":{"country":"JP","port":12345}}),
            );
            request.credentials.insert(
                "deepseekQuotaAccounts".into(),
                json!({
                    "account": {"display_name":"fixture", "api_key":"fixture"}
                }),
            );
            let http = EgressFixtureHttp {
                loc,
                direct: AtomicUsize::new(0),
                proxy: AtomicUsize::new(0),
                probes: AtomicUsize::new(0),
            };
            let window = super::CollectionWindow::from_context(&request.context).unwrap();
            let context = super::RunContext::new(
                &request,
                window,
                &http,
                &EmptyCredentialSource,
                super::RuntimeLimits::default(),
            )
            .unwrap();
            let result = super::collect_quota_usage(&context);
            assert_eq!(http.direct.load(Ordering::SeqCst), 0);
            assert_eq!(http.probes.load(Ordering::SeqCst), 1);
            assert_eq!(http.proxy.load(Ordering::SeqCst), expected_queries);
            let state = &result.services[0]["egress"];
            assert_eq!(
                state["status"],
                if expected_queries == 0 {
                    "blocked"
                } else {
                    "allowed"
                }
            );
            if expected_queries == 0 {
                assert_eq!(result.services[0]["failureKind"], "network");
                let code = match loc {
                    "CN" => "EGRESS_CN_DIRECT",
                    "US" => "EGRESS_COUNTRY_MISMATCH",
                    _ => "EGRESS_PROBE_TIMEOUT",
                };
                assert!(result.diagnostics.iter().any(|item| item.code == code));
                assert!(result.credential_challenges.is_empty());
            }
            assert!(!result.services[0].to_string().contains("192.0.2.1"));
        }
    }

    #[test]
    fn unmanaged_quota_stays_on_original_transport() {
        let mut request = request(&["externalQuotas"]);
        request.context.insert("egressRules".into(), json!({}));
        request.credentials.insert(
            "deepseekQuotaAccounts".into(),
            json!({
                "account": {"display_name":"fixture", "api_key":"fixture"}
            }),
        );
        let http = EgressFixtureHttp {
            loc: "CN",
            direct: AtomicUsize::new(0),
            proxy: AtomicUsize::new(0),
            probes: AtomicUsize::new(0),
        };
        let window = super::CollectionWindow::from_context(&request.context).unwrap();
        let context = super::RunContext::new(
            &request,
            window,
            &http,
            &EmptyCredentialSource,
            super::RuntimeLimits::default(),
        )
        .unwrap();
        let result = super::collect_quota_usage(&context);
        assert_eq!(http.direct.load(Ordering::SeqCst), 1);
        assert_eq!(http.probes.load(Ordering::SeqCst), 0);
        assert_eq!(http.proxy.load(Ordering::SeqCst), 0);
        assert!(result.services[0].get("egress").is_none());
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

    /// C171: 依次返回固定响应 (Claude 刷新 → usage)。
    struct SequenceHttp {
        responses: std::sync::Mutex<std::collections::VecDeque<HttpResponse>>,
    }

    impl HttpClient for SequenceHttp {
        fn send(
            &self,
            _request: HttpRequest,
            cancellation: &CancellationToken,
        ) -> Result<HttpResponse, ProviderError> {
            cancellation.check().map_err(ProviderError::from_runtime)?;
            Ok(self
                .responses
                .lock()
                .unwrap()
                .pop_front()
                .expect("unexpected extra request"))
        }
    }

    fn claude_refresh_then_usage_http() -> SequenceHttp {
        let refresh = json!({
            "token_type": "Bearer",
            "access_token": "sk-ant-oat01-fresh_token",
            "refresh_token": "sk-ant-ort01-new_refresh",
            "expires_in": 28800
        });
        let usage = json!({
            "five_hour": { "utilization": 5.0, "resets_at": null },
            "seven_day": { "utilization": 20.0, "resets_at": null }
        });
        SequenceHttp {
            responses: std::sync::Mutex::new(
                [refresh, usage]
                    .into_iter()
                    .map(|body| HttpResponse {
                        status: 200,
                        body: serde_json::to_vec(&body).unwrap(),
                    })
                    .collect(),
            ),
        }
    }

    fn expired_claude_request(capabilities: &[&str]) -> BridgeRequest {
        let mut request = request(capabilities);
        request.credentials.insert(
            "claudeQuotaAccounts".to_owned(),
            json!({
                "acc": {
                    "display_name": "Claude",
                    "oauth": {"claudeAiOauth": {
                        "accessToken": "sk-ant-oat01-stale_token",
                        "refreshToken": "sk-ant-ort01-refresh_me",
                        "expiresAt": 1_700_000_000_000_i64
                    }}
                }
            }),
        );
        request.credentials.insert(
            "providerMeta".to_owned(),
            json!({"claude": {"enabled": true}}),
        );
        request
    }

    fn assert_carries_rotated_claude_tokens(updates: &[serde_json::Value]) {
        assert_eq!(
            updates.len(),
            1,
            "rotated tokens dropped with the failed run"
        );
        assert_eq!(updates[0]["accountId"], "acc");
        assert_eq!(
            updates[0]["credentials"]["refresh_token"],
            "sk-ant-ort01-new_refresh"
        );
    }

    #[test]
    fn deadline_after_quota_refresh_still_returns_rotated_tokens() {
        let failure = super::collect_agent_usage_with_final_probe(
            &expired_claude_request(&["externalQuotas"]),
            &claude_refresh_then_usage_http(),
            &EmptyCredentialSource,
            |cancellation| cancellation.cancel(),
        )
        .unwrap_err();
        assert_eq!(failure.diagnostic.code, "LOCAL_SOURCE_CANCELLED");
        assert_carries_rotated_claude_tokens(&failure.credential_updates);
        let debug = format!("{failure:?}");
        assert!(!debug.contains("sk-ant-ort01-new_refresh"), "{debug}");
    }

    #[test]
    fn local_scan_failure_still_returns_rotated_tokens() {
        // 授权 localSessions 却缺 home: 本机通道失败, 额度通道照常完成并已刷新令牌
        let failure = collect_agent_usage_with_dependencies(
            &expired_claude_request(&["localSessions", "externalQuotas"]),
            &claude_refresh_then_usage_http(),
            &EmptyCredentialSource,
        )
        .unwrap_err();
        assert_eq!(failure.diagnostic.code, "BRIDGE_INVALID_REQUEST");
        assert_carries_rotated_claude_tokens(&failure.credential_updates);
    }

    #[test]
    fn application_preserves_capability_denied_local_semantics() {
        let output = collect_agent_usage(&request(&[])).unwrap();
        let artifact = output.artifact.as_object().unwrap();
        assert_eq!(artifact["agents"][1]["status"], "unavailable");
        // C124: 未授权云端额度不再输出 partial 占位 service
        assert_eq!(artifact["services"], json!([]));
    }

    fn local_or_skipped_request(context_extra: serde_json::Value) -> BridgeRequest {
        static LOCAL_SEQ: AtomicUsize = AtomicUsize::new(0);
        let home = std::env::temp_dir().join(format!(
            "bruce-local-or-skipped-{}-{}",
            std::process::id(),
            LOCAL_SEQ.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&home).unwrap();
        let mut request = request(&["localSessions", "externalQuotas"]);
        request
            .context
            .insert("home".to_owned(), json!(home.to_string_lossy()));
        request.context.insert(
            "paths".to_owned(),
            json!({"history_db": home.join("usage-history.sqlite").to_string_lossy()}),
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
            result.unwrap_err().diagnostic.code,
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
            result.unwrap_err().diagnostic.code,
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
        // 隔离 dsh: $DSH_HOME 会让默认路径指向开发者的真实 ~/.dsh, 用例必须显式覆盖。
        request.context.insert(
            "paths".to_owned(),
            json!({"dsh_sessions": home.join("dsh/sessions")}),
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
                "dsh",
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
        let dsh = home.join("dsh/sessions/workspace-dir/session-a");
        for path in [&kimi_work, &claude, &codebuddy, &grok, &pi, &dsh] {
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
        // C189: dsh 夹具用未压缩 .jsonl (生产环境为 .jsonl.zstd), 同样走按文件签名缓存。
        std::fs::write(
            dsh.join("session.v4.jsonl"),
            [
                json!({"type": "session", "version": 4, "cwd": "/workspace/warm-dsh-project"})
                    .to_string(),
                json!({
                    "type": "assistant/message",
                    "time": 1_788_912_000_000_i64,
                    "data": {
                        "message": {"id": "warm-dsh-message", "source": {"model": "deepseek-flash"}},
                        "usage": {"inputTokens": 14, "outputTokens": 6, "cacheReadTokens": 2}
                    }
                })
                .to_string(),
            ]
            .join("\n")
                + "\n",
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
                "codebuddy_projects": home.join("codebuddy"),
                "dsh_sessions": home.join("dsh/sessions")
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
        for source_id in ["kimi-work", "claude-code", "codebuddy", "grok", "pi", "dsh"] {
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
        let dsh_agent = second.artifact["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["id"] == "dsh")
            .unwrap();
        assert_ne!(dsh_agent["status"], "not_found", "dsh 行应产出用量");
        assert_eq!(dsh_agent["today"]["total"], 22, "14 + 6 + 2");
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
            ("dsh_sessions", empty.join("dsh")),
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

    /// C119: Orca 内置 Codex 的会话计入 Codex 行, artifact 不输出 Orca 行。
    #[test]
    fn orca_sessions_count_toward_codex_and_no_orca_row_is_emitted() {
        let home =
            std::env::temp_dir().join(format!("bruce-orca-into-codex-test-{}", std::process::id()));
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
            ("dsh_sessions", empty.join("dsh")),
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
        let agents = output.artifact["agents"].as_array().unwrap();
        assert!(
            agents.iter().all(|agent| agent["id"] != "orca"),
            "不再输出 Orca 行"
        );
        let codex = agents.iter().find(|agent| agent["id"] == "codex").unwrap();
        assert_eq!(codex["status"], "ok");
        assert_eq!(
            codex["today"]["total"], 22,
            "Codex CLI 13 + Orca 内置 Codex 9 均计入 Codex 行"
        );
        let _ = std::fs::remove_dir_all(home);
    }

    #[test]
    fn application_executes_injected_quota_account_through_registry() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
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
    fn quota_retry_only_skips_local_agents_and_returns_only_quota_services() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"],
                "quotaRetryOnly": true,
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

    /// C138 / TD-005: quotaRetryOnly 是通用契约 —— 非 codex provider 也能只重试额度,
    /// 不再经 codex 专属计划构建入口。
    #[test]
    fn quota_retry_only_is_provider_agnostic() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "externalRequestSeconds": 10,
                "moduleSeconds": 90
            },
            "context": {
                "now": "2026-08-21T08:00:00Z",
                "capabilities": ["externalQuotas"],
                "quotaRetryOnly": true
            },
            "credentials": {
                "kimiQuotaAccounts": {
                    "acct-a": {
                        "display_name": "Kimi fixture",
                        "api_key": "fixture-key"
                    }
                }
            }
        }))
        .unwrap();
        let http = FixtureHttp {
            calls: AtomicUsize::new(0),
            body: br#"{"limits":[{"detail":{"limit":100,"remaining":60}}]}"#.to_vec(),
        };
        let output =
            collect_agent_usage_with_dependencies(&request, &http, &EmptyCredentialSource).unwrap();
        assert!(output.artifact["agents"].as_array().unwrap().is_empty());
        assert_eq!(output.artifact["services"].as_array().unwrap().len(), 1);
        assert_eq!(output.artifact["services"][0]["app"], "kimi");
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
        assert_eq!(output.artifact["services"], json!([]));
        assert!(output
            .diagnostics
            .iter()
            .all(|diagnostic| diagnostic.code != "COLLECTOR_PARTIAL_RESULT"));
        assert_eq!(output.metrics.http_request_count, 0);
    }

    #[test]
    fn application_emits_credential_update_for_stepfun_refresh() {
        let request: BridgeRequest = serde_json::from_value(json!({
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
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

    #[test]
    fn application_pricing_table_selection_logic() {
        // Test 1: valid pricingCatalog is accepted and used
        let mut req = request(&[]);
        req.context.insert(
            "pricingCatalog".to_string(),
            json!({
                "schemaVersion": 1,
                "updatedAt": "2026-10-31",
                "models": [
                    {
                        "model": "dynamic-model",
                        "displayName": "Dynamic Model",
                        "vendor": "Dynamic",
                        "input": 10.0,
                        "output": 50.0,
                        "note": "dynamic"
                    }
                ]
            }),
        );
        let res = collect_agent_usage(&req);
        assert!(res.is_ok());

        // Test 2: invalid pricingCatalog falls back to builtin without failing
        let mut bad_req = request(&[]);
        bad_req.context.insert(
            "pricingCatalog".to_string(),
            json!({
                "schemaVersion": 999,
                "updatedAt": "invalid",
                "models": []
            }),
        );
        let bad_res = collect_agent_usage(&bad_req);
        assert!(bad_res.is_ok());

        // Test 3: older updatedAt falls back to builtin baseline
        let mut stale_req = request(&[]);
        stale_req.context.insert(
            "pricingCatalog".to_string(),
            json!({
                "schemaVersion": 1,
                "updatedAt": "2020-01-01",
                "models": [
                    {
                        "model": "stale-model",
                        "displayName": "Stale",
                        "vendor": "Stale",
                        "input": 1.0,
                        "output": 1.0,
                        "note": "stale"
                    }
                ]
            }),
        );
        let stale_res = collect_agent_usage(&stale_req);
        assert!(stale_res.is_ok());
    }

    #[test]
    fn finalize_local_agent_with_dynamic_catalog_and_overrides() {
        use collector_domain::{
            CollectionWindow, PricingTable, UsageContributionBuilder, UsageSample,
        };
        use std::collections::HashMap;

        let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 1
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let mut builder = UsageContributionBuilder::new(window.clone());
        assert!(builder.record(UsageSample {
            timestamp_millis: 1_785_211_200_000,
            model: Some("dynamic-test-model"),
            project: None,
            input: 1_000_000,
            output: 1_000_000,
            cache_read: 0,
            cache_creation: 0,
            cache_creation_1h: 0,
        }));
        let contribution = builder.contribution();
        let local_result = LocalAgentResult {
            found: true,
            contribution,
            diagnostic: None,
            notice: None,
            history_note: None,
        };

        // Construct dynamic catalog: dynamic-test-model @ $2 / $10
        let dynamic_catalog = vec![collector_domain::pricing::CatalogModel {
            model: "dynamic-test-model".to_string(),
            display_name: "Dynamic Test".to_string(),
            vendor: "Dynamic".to_string(),
            input: 2.0,
            output: 10.0,
            cache_read: None,
            cache_write: None,
            note: "Dynamic".to_string(),
            listed: true,
            peak: None,
            long_context: None,
        }];

        let pricing_table = PricingTable::with_catalog(&dynamic_catalog, HashMap::new());
        let agent = finalize_local_agent(
            &window,
            "test_agent",
            "Test Agent",
            &local_result,
            "note",
            "unavailable",
            "missing",
            &pricing_table,
        );

        // 1M in * $2 + 1M out * $10 = $12
        assert_eq!(agent.today_cost_usd, Some(12.0));

        // Now with user override: input $5 -> 1M * $5 + 1M * $10 = $15
        let mut overrides = HashMap::new();
        overrides.insert(
            "dynamic-test-model".to_string(),
            collector_domain::ModelPricingOverride {
                input_price_per_million: Some(5.0),
                ..Default::default()
            },
        );
        let overridden_table = PricingTable::with_catalog(&dynamic_catalog, overrides);
        let overridden_agent = finalize_local_agent(
            &window,
            "test_agent",
            "Test Agent",
            &local_result,
            "note",
            "unavailable",
            "missing",
            &overridden_table,
        );
        assert_eq!(overridden_agent.today_cost_usd, Some(15.0));
    }

    // MARK: - T26: 用量历史台账

    fn history_test_home(name: &str) -> std::path::PathBuf {
        let home = std::env::temp_dir().join(format!("bruce-t26-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        home
    }

    fn history_request(home: &std::path::Path, history_db: &std::path::Path) -> BridgeRequest {
        let paths = json!({
            "claude_projects": home.join("claude").to_string_lossy(),
            "kimi_cli_sessions": home.join("kimi-cli").to_string_lossy(),
            "daimon_kimi_sessions": home.join("kimi-work").to_string_lossy(),
            "codex_sessions": home.join("codex").to_string_lossy(),
            "orca_home": home.join("orca").to_string_lossy(),
            "grok_home": home.join("grok").to_string_lossy(),
            "pi_sessions": home.join("pi").to_string_lossy(),
            "opencode_db": home.join("opencode.db").to_string_lossy(),
            "zcode_db": home.join("zcode.db").to_string_lossy(),
            "codebuddy_projects": home.join("codebuddy").to_string_lossy(),
            "dsh_sessions": home.join("dsh").to_string_lossy(),
            "history_db": history_db.to_string_lossy(),
        });
        let mut request = request(&["localSessions"]);
        for (key, value) in [
            ("home", json!(home.to_string_lossy())),
            ("now", json!("2026-07-28T12:00:00+08:00")),
            ("timezone", json!("Asia/Shanghai")),
            ("days", json!(7)),
            ("paths", paths),
        ] {
            request.context.insert(key.to_owned(), value);
        }
        request
    }

    fn claude_agent(artifact: &serde_json::Value) -> &serde_json::Value {
        artifact["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["id"] == "claude-code")
            .unwrap()
    }

    fn daily_total(agent: &serde_json::Value) -> u64 {
        agent["daily"]
            .as_array()
            .unwrap()
            .iter()
            .map(|day| day["total"].as_u64().unwrap_or(0))
            .sum()
    }

    fn write_claude_history(home: &std::path::Path) {
        let claude = home.join("claude");
        std::fs::create_dir_all(&claude).unwrap();
        let lines = [
            json!({
                "type": "assistant",
                "timestamp": "2026-07-28T03:00:00Z",
                "message": {
                    "id": "t26-history-today",
                    "model": "claude-sonnet",
                    "usage": {"input_tokens": 100, "output_tokens": 10}
                }
            })
            .to_string(),
            json!({
                "type": "assistant",
                "timestamp": "2026-07-27T03:00:00Z",
                "message": {
                    "id": "t26-history-yesterday",
                    "model": "claude-sonnet",
                    "usage": {"input_tokens": 200, "output_tokens": 20}
                }
            })
            .to_string(),
        ]
        .join("\n")
            + "\n";
        std::fs::write(claude.join("session.jsonl"), lines).unwrap();
    }

    fn empty_http() -> FixtureHttp {
        FixtureHttp {
            calls: AtomicUsize::new(0),
            body: b"{}".to_vec(),
        }
    }

    /// T26: 来源被删除后, 该 agent 的历史用量必须从台账继续输出, 且状态区分于 ok。
    #[test]
    fn history_survives_source_removal() {
        let home = history_test_home("source-removal");
        let history_db = home.join("usage-history.sqlite");
        write_claude_history(&home);
        let request = history_request(&home, &history_db);

        let first =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        let first_agent = claude_agent(&first.artifact);
        assert_eq!(first_agent["status"], "ok");
        let first_total = daily_total(first_agent);
        assert_eq!(first_total, 330, "两次调用应完整计入: {first_total}");
        assert!(!first
            .diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == LOCAL_HISTORY_STORE_UNAVAILABLE));

        // 清理来源 (卸载/删除会话目录)
        std::fs::remove_dir_all(home.join("claude")).unwrap();
        let second =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        let second_agent = claude_agent(&second.artifact);
        assert_eq!(
            second_agent["status"], "history",
            "来源消失后应显示历史状态而非 not_found"
        );
        assert!(
            second_agent["note"]
                .as_str()
                .unwrap_or_default()
                .contains("历史用量"),
            "note 应说明来源未发现但展示历史: {}",
            second_agent["note"]
        );
        assert_eq!(
            daily_total(second_agent),
            first_total,
            "来源删除不得减少台账历史"
        );
        assert_eq!(second_agent["today"]["total"], 110, "今日历史仍应保留");

        std::fs::remove_dir_all(&home).ok();
    }

    /// T26: 台账不可用时只降级为「仅扫描贡献」, artifact 与诊断码均可解释。
    #[test]
    fn history_store_unavailable_falls_back_to_scan() {
        let home = history_test_home("store-unavailable");
        write_claude_history(&home);
        let blocked_path = home.join("history-as-directory");
        std::fs::create_dir_all(&blocked_path).unwrap();
        let request = history_request(&home, &blocked_path);

        let output =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        assert!(
            output
                .diagnostics
                .iter()
                .any(|diagnostic| diagnostic.code == LOCAL_HISTORY_STORE_UNAVAILABLE),
            "台账不可用必须输出信息级诊断"
        );
        let agent = claude_agent(&output.artifact);
        assert_eq!(agent["status"], "ok", "台账故障不得影响扫描结果");
        assert_eq!(daily_total(agent), 330, "回退路径仍应输出扫描贡献");

        std::fs::remove_dir_all(&home).ok();
    }

    fn has_diagnostic(
        diagnostics: &[collector_domain::Diagnostic],
        code: &str,
        stage: &str,
    ) -> bool {
        diagnostics
            .iter()
            .any(|diagnostic| diagnostic.code == code && diagnostic.stage == stage)
    }

    fn agent<'a>(artifact: &'a serde_json::Value, id: &str) -> &'a serde_json::Value {
        artifact["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|agent| agent["id"] == id)
            .unwrap()
    }

    /// C198: 来源说明 (Codex 会话副本分叉合并, C190) 只输出信息级 LOCAL_SOURCE_NOTICE —— agent 保持 ok、
    /// note 附说明、envelope 不升级为 Partial; 同一轮的真实读取故障 (OpenCode 库不可解析)
    /// 仍为 error + LOCAL_SOURCE_SCHEMA_INCOMPATIBLE。
    #[test]
    fn source_notice_stays_informational_while_source_fault_stays_error() {
        let home = history_test_home("source-notice");
        let history_db = home.join("usage-history.sqlite");
        for (copy, input) in [("a", 100_u64), ("b", 1_000)] {
            let dir = home.join("codex").join(copy);
            std::fs::create_dir_all(&dir).unwrap();
            let line = json!({
                "timestamp": "2026-07-28T03:00:00Z",
                "type": "event_msg",
                "payload": {"type": "token_count", "info": {"last_token_usage": {
                    "input_tokens": input, "cached_input_tokens": 0, "output_tokens": 5
                }}}
            });
            std::fs::write(dir.join("rollout-c198.jsonl"), format!("{line}\n")).unwrap();
        }
        std::fs::write(home.join("opencode.db"), b"not a sqlite database").unwrap();
        let request = history_request(&home, &history_db);

        let output =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        let codex = agent(&output.artifact, "codex");
        assert_eq!(
            codex["status"], "ok",
            "副本取舍是说明, 不得把 Codex 置 error"
        );
        let note = codex["note"].as_str().unwrap_or_default();
        assert!(
            note.starts_with("额度见下方 Codex 账号") && note.contains("会话副本已分叉"),
            "note 保留来源原说明并附上副本说明: {note}"
        );
        assert!(codex["today"]["total"].as_u64().unwrap_or(0) > 0);
        assert!(
            has_diagnostic(&output.diagnostics, LOCAL_SOURCE_NOTICE, "codex"),
            "副本取舍须以信息级诊断输出"
        );
        let schema_fault = "LOCAL_SOURCE_SCHEMA_INCOMPATIBLE";
        assert!(!has_diagnostic(&output.diagnostics, schema_fault, "codex"));

        let opencode = agent(&output.artifact, "opencode");
        assert_eq!(opencode["status"], "error", "真实读取故障不得被降级");
        assert!(has_diagnostic(
            &output.diagnostics,
            schema_fault,
            "opencode"
        ));
        assert_eq!(
            collector_domain::response_status(true, &output.diagnostics),
            collector_domain::ResponseStatus::Partial,
            "故障仍使 envelope 为 Partial"
        );

        // 只剩说明时 envelope 为 Success。
        std::fs::remove_file(home.join("opencode.db")).unwrap();
        let output =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        assert!(has_diagnostic(
            &output.diagnostics,
            LOCAL_SOURCE_NOTICE,
            "codex"
        ));
        assert_eq!(
            collector_domain::response_status(true, &output.diagnostics),
            collector_domain::ResponseStatus::Success,
            "信息级说明不得触发 Partial: {:?}",
            output.diagnostics
        );

        std::fs::remove_dir_all(&home).ok();
    }

    /// C194: Grok 07-26 写入 300、07-27 追加 40 —— 旧实现追加时把已有观测重打为新 mtime,
    /// 叠加台账按日取大得 07-26=300、07-27=340 (7 日合计 640, 月行 340); 现在日 / 月一致为 340。
    #[test]
    fn grok_cross_day_append_is_not_double_counted_by_the_ledger() {
        let home = history_test_home("grok-cross-day");
        let history_db = home.join("usage-history.sqlite");
        let session = home.join("grok/sessions/project/session/conversation.jsonl");
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        let line = |kind: &str, chars: usize| {
            json!({"type": kind, "content": "x".repeat(chars)}).to_string() + "\n"
        };
        let set_mtime = |epoch_seconds: u64| {
            std::fs::File::options()
                .write(true)
                .open(&session)
                .unwrap()
                .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(epoch_seconds))
                .unwrap();
        };
        let run = |now: &str| {
            let mut request = history_request(&home, &history_db);
            request.context.insert("now".to_owned(), json!(now));
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap()
        };
        std::fs::write(&session, line("user", 800) + &line("assistant", 400)).unwrap();
        set_mtime(1_785_038_400); // 2026-07-26 12:00 +08
        run("2026-07-26T18:00:00+08:00");
        let mut content = std::fs::read_to_string(&session).unwrap();
        content.push_str(&line("assistant", 160));
        std::fs::write(&session, content).unwrap();
        set_mtime(1_785_124_800); // 2026-07-27 12:00 +08
        let output = run("2026-07-27T18:00:00+08:00");

        let grok = agent(&output.artifact, "grok");
        let daily: std::collections::BTreeMap<&str, u64> = grok["daily"]
            .as_array()
            .unwrap()
            .iter()
            .map(|day| {
                (
                    day["date"].as_str().unwrap(),
                    day["total"].as_u64().unwrap_or(0),
                )
            })
            .collect();
        assert_eq!(daily.get("2026-07-26"), Some(&300));
        assert_eq!(daily.get("2026-07-27"), Some(&40));
        assert_eq!(daily_total(grok), 340, "7 日合计等于真实值");
        let month: u64 = grok["modelMonths"]["2026-07"]
            .as_object()
            .unwrap()
            .values()
            .map(|value| value.as_u64().unwrap_or(0))
            .sum();
        assert_eq!(month, 340, "日与月一致");
        std::fs::remove_dir_all(&home).ok();
    }

    /// C199: 旧口径 (C194 前) 已把 Grok 跨日追加写成 07-26=300、07-27=340 (7 日合计 640);
    /// Grok 声明派生口径版本 2 后的首个来源可见轮按扫描窗口修正为 340, 之后恢复单调。
    #[test]
    fn grok_inflated_history_is_corrected_once_after_version_bump() {
        let home = history_test_home("grok-correction");
        let history_db = home.join("usage-history.sqlite");
        let session = home.join("grok/sessions/project/session/conversation.jsonl");
        std::fs::create_dir_all(session.parent().unwrap()).unwrap();
        let line = |kind: &str, chars: usize| {
            json!({"type": kind, "content": "x".repeat(chars)}).to_string() + "\n"
        };
        std::fs::write(
            &session,
            line("user", 800) + &line("assistant", 400) + &line("assistant", 160),
        )
        .unwrap();
        std::fs::File::options()
            .write(true)
            .open(&session)
            .unwrap()
            .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_785_124_800))
            .unwrap(); // 2026-07-27 12:00 +08
        {
            // 按旧实现逐轮写入 (基线口径版本 1): 07-26 一轮 300, 07-27 追加后整体漂到 07-27 记 340。
            let mut store = collector_history::HistoryStore::open(&history_db).unwrap();
            for (now, today, millis, input) in [
                (
                    "2026-07-26T18:00:00+08:00",
                    "2026-07-26",
                    1_785_038_400_000_i64,
                    300,
                ),
                (
                    "2026-07-27T18:00:00+08:00",
                    "2026-07-27",
                    1_785_124_800_000,
                    340,
                ),
            ] {
                let window_context: serde_json::Map<String, serde_json::Value> =
                    serde_json::from_value(json!({
                        "now": now,
                        "timezone": "Asia/Shanghai",
                        "days": 7
                    }))
                    .unwrap();
                let window =
                    collector_domain::CollectionWindow::from_context(&window_context).unwrap();
                let mut builder = collector_domain::UsageContributionBuilder::new(window);
                builder.record(collector_domain::UsageSample {
                    timestamp_millis: millis,
                    model: Some("grok"),
                    project: None,
                    input,
                    output: 0,
                    cache_read: 0,
                    cache_creation: 0,
                    cache_creation_1h: 0,
                });
                store
                    .merge("grok", &builder.contribution(), true, today, now)
                    .unwrap();
            }
        }
        let mut request = history_request(&home, &history_db);
        request
            .context
            .insert("now".to_owned(), json!("2026-07-27T18:00:00+08:00"));
        let run = || {
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap()
        };
        let corrected = run();
        let grok = agent(&corrected.artifact, "grok");
        assert_eq!(daily_total(grok), 340, "已落库的重复值被修正: 640 → 340");
        let month: u64 = grok["modelMonths"]["2026-07"]
            .as_object()
            .unwrap()
            .values()
            .map(|value| value.as_u64().unwrap_or(0))
            .sum();
        assert_eq!(month, 340, "日与月一致");
        // 修正只发生一次: 之后恢复单调 (来源被删除也不抹历史)。
        std::fs::remove_dir_all(home.join("grok")).unwrap();
        let after = run();
        let grok = agent(&after.artifact, "grok");
        assert_eq!(grok["status"], "history");
        assert_eq!(daily_total(grok), 340);
        std::fs::remove_dir_all(&home).ok();
    }

    /// C193: 来源 usage 键改名 (Claude message.usage → message.token_usage) → 口径哨兵说明经
    /// LOCAL_SOURCE_NOTICE 输出, Claude 仍为 ok、envelope 不 Partial。
    #[test]
    fn usage_drift_sentinel_is_a_notice_not_an_error() {
        let home = history_test_home("usage-drift");
        let history_db = home.join("usage-history.sqlite");
        let claude = home.join("claude").join("demo");
        std::fs::create_dir_all(&claude).unwrap();
        let lines: String = (0..5)
            .map(|index| {
                json!({
                    "type": "assistant",
                    "timestamp": format!("2026-07-28T03:0{index}:00Z"),
                    "message": {
                        "id": format!("drift-{index}"),
                        "model": "claude-sonnet",
                        "token_usage": {"input_tokens": 100, "output_tokens": 10}
                    }
                })
                .to_string()
                    + "\n"
            })
            .collect();
        std::fs::write(claude.join("session.jsonl"), lines).unwrap();
        let request = history_request(&home, &history_db);
        let output =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        let claude = claude_agent(&output.artifact);
        assert_eq!(claude["status"], "ok", "哨兵说明不得把 agent 置 error");
        assert!(
            claude["note"]
                .as_str()
                .unwrap_or_default()
                .contains("疑似来源 usage 字段口径变化"),
            "{}",
            claude["note"]
        );
        assert!(has_diagnostic(
            &output.diagnostics,
            LOCAL_SOURCE_NOTICE,
            "claude-code"
        ));
        assert_eq!(
            collector_domain::response_status(true, &output.diagnostics),
            collector_domain::ResponseStatus::Success
        );
        std::fs::remove_dir_all(&home).ok();
    }

    /// C198: 说明附在 note 后且不改变状态; 故障优先, 说明不覆盖故障说明。
    #[test]
    fn finalize_local_agent_appends_notice_without_changing_status() {
        use collector_domain::{CollectionWindow, PricingTable, UsageContributionBuilder};

        let context: serde_json::Map<String, serde_json::Value> = serde_json::from_value(json!({
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 3
        }))
        .unwrap();
        let window = CollectionWindow::from_context(&context).unwrap();
        let pricing = PricingTable::new(std::collections::HashMap::new());
        let finalize = |diagnostic: Option<&str>, history_note: Option<&str>| {
            let source = LocalAgentResult {
                found: history_note.is_none(),
                contribution: UsageContributionBuilder::new(window.clone()).contribution(),
                diagnostic: diagnostic.map(str::to_owned),
                notice: Some("缓存已重建".to_owned()),
                history_note: history_note.map(str::to_owned),
            };
            finalize_local_agent(
                &window,
                "codex",
                "Codex",
                &source,
                "本机会话聚合",
                "not_found",
                "未发现会话记录",
                &pricing,
            )
        };

        let ok = finalize(None, None);
        assert_eq!(ok.status, "ok");
        assert_eq!(ok.note, "本机会话聚合 (缓存已重建)");

        let history = finalize(None, Some("显示已保存的历史用量"));
        assert_eq!(history.status, "history");
        assert_eq!(history.note, "显示已保存的历史用量 (缓存已重建)");

        let fault = finalize(Some("本机 codex 数据库schema 不兼容"), None);
        assert_eq!(fault.status, "error");
        assert_eq!(fault.note, "本机 codex 数据库schema 不兼容");
    }

    /// T26: 从未使用的 agent 不得因占位而写入 0 行或变成 history。
    #[test]
    fn empty_sources_keep_placeholder_status() {
        let home = history_test_home("empty-sources");
        let history_db = home.join("usage-history.sqlite");
        let request = history_request(&home, &history_db);

        let output =
            collect_agent_usage_with_dependencies(&request, &empty_http(), &EmptyCredentialSource)
                .unwrap();
        let agent = claude_agent(&output.artifact);
        assert_eq!(agent["status"], "not_found");
        assert_eq!(agent["note"], "未发现会话记录");
        assert_eq!(daily_total(agent), 0);

        std::fs::remove_dir_all(&home).ok();
    }
}
