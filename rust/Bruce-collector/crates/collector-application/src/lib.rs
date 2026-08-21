#![deny(unsafe_code)]

//! Rust collection application orchestration.
//!
//! The Bridge owns protocol validation and the response envelope. This module
//! owns the collection flow and keeps local aggregation details out of that
//! protocol seam.

mod account;
mod aggregation;
mod context;
mod execution;

use account::{build_account_plan, build_codex_account_plans};
use aggregation::consume_source_changes;
use collector_aggregate::UsageAccumulator;
use collector_credential::{
    validate_credential_challenges, validate_credential_updates, CredentialSource,
    SystemCredentialSource,
};
use collector_domain::{
    AgentUsage, AgentUsageArtifact, BridgeRequest, CollectionWindow, Diagnostic, WindowError,
    AGENT_USAGE_MODULE, AGENT_USAGE_SCHEMA_VERSION,
};
use collector_local::{
    default_cache_root, scan_claude, scan_codex, scan_grok, scan_kimi_tree, scan_opencode, scan_pi,
    scan_tree_cached_with_sink, scan_zcode, CacheConfig, ScanStats,
};
use collector_provider::{HttpClient, ProviderError, UreqHttpClient};
use collector_runtime::{BoundedQueue, RuntimeError, RuntimeLimits};
use context::RunContext;
use execution::{execute_quota_accounts, QuotaExecution};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub use collector_local::ScanStats as CollectionScanStats;
pub use context::CollectionMetrics;

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
    let window = CollectionWindow::from_context(&request.context).map_err(window_diagnostic)?;
    let context = RunContext::new(request, window, http, credentials, RuntimeLimits::default())?;
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
        let quota = context
            .capability_allowed("externalQuotas")
            .then(|| scope.spawn(|| collect_quota_usage(&context)));
        let local = local.join().expect("local collection worker panicked");
        let quota = quota.map(|worker| worker.join().expect("quota worker panicked"));
        (local, quota)
    });
    let local = local_result?;
    let mut diagnostics = local.diagnostics;
    let scan_stats = local.scan_stats;
    let window = context.window.clone();
    let sessions_allowed = context.capability_allowed("localSessions");
    let mut kimi_cli = local
        .accumulator
        .finalize("kimi-code-cli", "Kimi Code CLI", None);
    if !sessions_allowed {
        kimi_cli.status = "unavailable".to_owned();
        kimi_cli.note = "未授权 localSessions 能力, 已跳过本机会话扫描".to_owned();
    } else if !local.found {
        kimi_cli.status = "not_found".to_owned();
        kimi_cli.note = "未发现会话记录".to_owned();
    } else {
        kimi_cli.note = "额度见下方 Kimi 服务".to_owned();
    }
    let mut kimi_cli = Some(kimi_cli);

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
            "opencode",
            "OpenCode",
            "本机 opencode 会话, 精确 token 计数",
            "未发现 opencode 会话记录",
        ),
        (
            "pi",
            "Pi",
            "本机 Pi 会话, 精确 token 计数",
            "未发现会话记录",
        ),
        (
            "zcode",
            "ZCode",
            "本机 ZCode 会话, 精确 token 计数",
            "未发现 ZCode 会话记录",
        ),
    ];
    let mut agents = Vec::with_capacity(agent_specs.len());
    for (id, name, note, not_found_note) in agent_specs {
        if id == "kimi-code-cli" {
            agents.push(kimi_cli.take().expect("Kimi Code agent is emitted once"));
            continue;
        }
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
            ));
        } else {
            agents.push(placeholder_agent(
                &window,
                id,
                name,
                placeholder_status,
                missing_note,
            ));
        }
    }
    let (services, credential_updates, credential_challenges) =
        if context.capability_allowed("externalQuotas") {
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
                    denied_service("antigravity", "Antigravity", "antigravity", &window),
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
    Ok(CollectionOutput {
        artifact,
        diagnostics,
        generated_at: window.generated_at(),
        scan_stats,
        metrics: context.metrics.snapshot(),
        credential_updates,
        credential_challenges,
    })
}

struct LocalCollection {
    accumulator: UsageAccumulator,
    agents: BTreeMap<String, LocalAgentResult>,
    diagnostics: Vec<Diagnostic>,
    scan_stats: ScanStats,
    found: bool,
}

struct LocalAgentResult {
    found: bool,
    contribution: collector_domain::UsageContribution,
    diagnostic: Option<String>,
}

fn collect_local_usage(context: &RunContext<'_>) -> Result<LocalCollection, Diagnostic> {
    let mut accumulator = UsageAccumulator::new(context.window.clone());
    let mut agents = BTreeMap::new();
    let mut diagnostics = Vec::new();
    let mut scan_stats = ScanStats::default();
    let sessions_allowed = context.capability_allowed("localSessions");
    let root = session_root(&context.request.context);
    let mut found = false;
    if sessions_allowed {
        let home = context.request.context.get("home").and_then(Value::as_str);
        let Some(home) = home else {
            return Err(Diagnostic::new(
                "BRIDGE_INVALID_REQUEST",
                "protocol",
                "context",
                "本地会话扫描需要 home",
                false,
            ));
        };
        if let Some(root) = root.as_deref() {
            let _permit = context
                .budgets
                .acquire_local(&context.cancellation)
                .map_err(runtime_diagnostic)?;
            let config = CacheConfig {
                cache_root: default_cache_root(Path::new(home)),
                window: context.window.clone(),
                pricing_version: 1,
            };
            let queue = Arc::new(
                BoundedQueue::new(context.limits.aggregate_queue_capacity)
                    .map_err(runtime_diagnostic)?,
            );
            let cancellation = context.cancellation.clone();
            let (scan_result, aggregation) = std::thread::scope(|scope| {
                let consumer_queue = Arc::clone(&queue);
                let consumer_window = context.window.clone();
                let consumer_cancellation = cancellation.clone();
                let consumer = scope.spawn(move || {
                    consume_source_changes(consumer_queue, consumer_window, consumer_cancellation)
                });
                let scan_result = scan_tree_cached_with_sink(root, &config, |change| {
                    queue.push(change, &context.cancellation).map_err(|error| {
                        std::io::Error::new(
                            std::io::ErrorKind::Interrupted,
                            format!("bounded local change stream stopped: {error:?}"),
                        )
                    })
                });
                queue.close();
                let aggregation = consumer.join().expect("local aggregation worker panicked");
                (scan_result, aggregation)
            });
            accumulator = aggregation.accumulator;
            diagnostics.extend(aggregation.diagnostics);
            match scan_result {
                Ok(stats) => {
                    found = stats.files_scanned > 0;
                    scan_stats = stats;
                    if scan_stats.io_errors > 0 {
                        diagnostics.push(Diagnostic::new(
                            "LOCAL_SOURCE_PARTIAL",
                            "local",
                            "scan",
                            "部分本机会话文件无法读取",
                            true,
                        ));
                    }
                }
                Err(_) if context.cancellation.is_cancelled() => diagnostics.push(Diagnostic::new(
                    "LOCAL_SOURCE_CANCELLED",
                    "local",
                    "cancel",
                    "本机会话扫描因取消或超时提前停止, 已保留已聚合结果",
                    true,
                )),
                Err(_) => diagnostics.push(Diagnostic::new(
                    "LOCAL_SOURCE_ERROR",
                    "local",
                    "scan",
                    "本机会话目录无法读取",
                    true,
                )),
            }

            let home = PathBuf::from(home);
            let kimi_work = source_path(
                context,
                "daimon_kimi_sessions",
                home.join(
                    "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions",
                ),
            );
            let claude = source_path(context, "claude_projects", home.join(".claude/projects"));
            let codex = source_path(context, "codex_sessions", home.join(".codex/sessions"));
            let orca_home = source_path(
                context,
                "orca_home",
                home.join("Library/Application Support/orca"),
            );
            let orca_sessions = source_path(
                context,
                "orca_codex_sessions",
                orca_home.join("codex-runtime-home/home/sessions"),
            );
            let orca_accounts = source_path(
                context,
                "orca_codex_accounts",
                orca_home.join("codex-accounts"),
            );
            let mut codex_roots = vec![codex, orca_sessions];
            if let Ok(entries) = fs::read_dir(&orca_accounts) {
                for entry in entries.flatten() {
                    let sessions = entry.path().join("home/sessions");
                    if sessions.is_dir() {
                        codex_roots.push(sessions);
                    }
                }
            }
            let grok_root = source_path(context, "grok_home", home.join(".grok"));
            let pi = source_path(context, "pi_sessions", home.join(".pi/agent/sessions"));
            let opencode = source_path(
                context,
                "opencode_db",
                home.join(".local/share/opencode/opencode.db"),
            );
            let zcode = source_path(context, "zcode_db", home.join(".zcode/cli/db/db.sqlite"));

            let source_results = [
                (
                    "kimi-work",
                    scan_kimi_tree(&kimi_work, &context.window, false),
                ),
                ("claude-code", scan_claude(&claude, &context.window)),
                ("codex", scan_codex(&codex_roots, &context.window)),
                (
                    "grok",
                    scan_grok(
                        &[
                            grok_root.join("sessions"),
                            grok_root.join("archived_sessions"),
                        ],
                        &context.window,
                    ),
                ),
                ("opencode", scan_opencode(&opencode, &context.window)),
                ("pi", scan_pi(&pi, &context.window)),
                ("zcode", scan_zcode(&zcode, &context.window)),
            ];
            for (id, source) in source_results {
                scan_stats.merge(source.stats.clone());
                if let Some(message) = source.diagnostic.clone() {
                    diagnostics.push(Diagnostic::new(
                        "LOCAL_SOURCE_SCHEMA_INCOMPATIBLE",
                        "local",
                        id,
                        message,
                        true,
                    ));
                }
                agents.insert(
                    id.to_owned(),
                    LocalAgentResult {
                        found: source.found,
                        contribution: source.contribution,
                        diagnostic: source.diagnostic,
                    },
                );
            }
        }
    }
    Ok(LocalCollection {
        accumulator,
        agents,
        diagnostics,
        scan_stats,
        found,
    })
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
        credential_updates: quota.credential_updates,
        credential_challenges: quota.credential_challenges,
    })
}

fn runtime_diagnostic(error: RuntimeError) -> Diagnostic {
    ProviderError::from_runtime(error).diagnostic
}

fn placeholder_agent(
    window: &CollectionWindow,
    id: &str,
    name: &str,
    status: &str,
    note: &str,
) -> AgentUsage {
    let mut agent = UsageAccumulator::new(window.clone()).finalize(id, name, None);
    agent.status = status.to_owned();
    agent.note = note.to_owned();
    agent
}

fn finalize_local_agent(
    window: &CollectionWindow,
    id: &str,
    name: &str,
    source: &LocalAgentResult,
    note: &str,
    placeholder_status: &str,
    placeholder_note: &str,
) -> AgentUsage {
    let mut accumulator = UsageAccumulator::new(window.clone());
    let _ = accumulator.merge_delta(&source.contribution);
    let mut agent = accumulator.finalize(id, name, None);
    if let Some(diagnostic) = &source.diagnostic {
        agent.status = "error".to_owned();
        agent.note = diagnostic.clone();
    } else if source.found {
        agent.note = note.to_owned();
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

fn session_root(context: &serde_json::Map<String, Value>) -> Option<PathBuf> {
    let home = context.get("home").and_then(Value::as_str)?;
    if let Some(path) = context
        .get("paths")
        .and_then(Value::as_object)
        .and_then(|paths| paths.get("kimi_cli_sessions"))
        .and_then(Value::as_str)
    {
        return Some(PathBuf::from(path));
    }
    Some(Path::new(home).join(".kimi-code/sessions"))
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
    use super::{collect_agent_usage, collect_agent_usage_with_dependencies};
    use collector_credential::{CredentialReadError, CredentialSource};
    use collector_domain::BridgeRequest;
    use collector_provider::{
        codex_service_id, HttpClient, HttpRequest, HttpResponse, ProviderError,
    };
    use collector_runtime::CancellationToken;
    use serde_json::json;
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};

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
}
