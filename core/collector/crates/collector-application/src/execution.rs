use crate::account::AccountPlan;
use crate::context::RunContext;
use crate::egress::{decide, rule_for, ProbeCache, ProbeError, Trace};
use collector_domain::Diagnostic;
use collector_provider::{
    catalog_entry_for_app, failure_kind_for_code, provider_for_app, service_template, HttpClient,
    HttpRequest, HttpResponse, ProviderError, ProviderRequest,
};
use collector_runtime::RuntimeError;
use serde_json::Value;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug, Default)]
pub(crate) struct QuotaExecution {
    pub services: Vec<Value>,
    pub diagnostics: Vec<Diagnostic>,
    pub credential_updates: Vec<Value>,
    pub credential_challenges: Vec<Value>,
}

#[derive(Debug)]
struct ServiceExecution {
    service: Value,
    diagnostics: Vec<Diagnostic>,
    credential_updates: Vec<Value>,
    credential_challenges: Vec<Value>,
}

struct CountingHttpClient<'a> {
    inner: &'a dyn HttpClient,
    requests: Arc<crate::context::RuntimeCounters>,
}

impl HttpClient for CountingHttpClient<'_> {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &collector_runtime::CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        self.requests
            .http_request_count
            .fetch_add(1, Ordering::AcqRel);
        self.inner.send(request, cancellation)
    }

    fn send_via_loopback_proxy(
        &self,
        port: u16,
        request: HttpRequest,
        cancellation: &collector_runtime::CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        self.requests
            .http_request_count
            .fetch_add(1, Ordering::AcqRel);
        self.inner
            .send_via_loopback_proxy(port, request, cancellation)
    }
}

struct ProxyHttpClient<'a> {
    inner: CountingHttpClient<'a>,
    port: u16,
}

impl HttpClient for ProxyHttpClient<'_> {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &collector_runtime::CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        self.inner
            .send_via_loopback_proxy(self.port, request, cancellation)
    }
}

pub(crate) fn execute_quota_accounts(
    context: &RunContext<'_>,
    plans: &[AccountPlan],
) -> QuotaExecution {
    if plans.is_empty() {
        return QuotaExecution::default();
    }
    // C122: 工作线程数即账号并发上限 (account_tasks); 账号计划按 account id 唯一
    // (build_account_plan / build_codex_account_plans 均由 map 键生成), 且每轮只执行一次,
    // 不再叠加永不阻塞的账号许可与两层永不合并的 single-flight。
    let worker_count = context.limits.account_tasks.min(plans.len());
    let next = Arc::new(AtomicUsize::new(0));
    let egress_cache = ProbeCache::default();
    let results = Arc::new(Mutex::new(
        (0..plans.len()).map(|_| None).collect::<Vec<_>>(),
    ));

    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let next = Arc::clone(&next);
            let results = Arc::clone(&results);
            let egress_cache = &egress_cache;
            scope.spawn(move || loop {
                let index = next.fetch_add(1, Ordering::AcqRel);
                if index >= plans.len() {
                    break;
                }
                let result = execute_one(context, &plans[index], egress_cache);
                results.lock().expect("quota result mutex poisoned")[index] = Some(result);
            });
        }
    });

    let mut output = QuotaExecution::default();
    let results = Arc::try_unwrap(results)
        .expect("quota result references should be released")
        .into_inner()
        .expect("quota result mutex poisoned");
    for result in results.into_iter().flatten() {
        output.services.push(result.service);
        output.diagnostics.extend(result.diagnostics);
        output.credential_updates.extend(result.credential_updates);
        output
            .credential_challenges
            .extend(result.credential_challenges);
    }
    output
}

fn execute_one(
    context: &RunContext<'_>,
    plan: &AccountPlan,
    egress_cache: &ProbeCache,
) -> ServiceExecution {
    let mut diagnostics = Vec::new();
    let service = service_template(&plan.service, &context.captured_at);
    // 取消 / 超时先于凭证判定 (与原账号许可获取时的检查次序一致)
    if let Err(error) = context.cancellation.check() {
        let diagnostic = runtime_diagnostic(error);
        diagnostics.push(diagnostic.clone());
        return ServiceExecution {
            service: failed_service(service, &diagnostic),
            diagnostics,
            credential_updates: Vec::new(),
            credential_challenges: Vec::new(),
        };
    }
    let credential = match resolve_credential(plan) {
        Ok(credential) => credential,
        Err(diagnostic) => {
            diagnostics.push(diagnostic.clone());
            return ServiceExecution {
                service: failed_service(service, &diagnostic),
                diagnostics,
                credential_updates: Vec::new(),
                credential_challenges: Vec::new(),
            };
        }
    };

    let Some(provider) = provider_for_app(&plan.service.app) else {
        let diagnostic = Diagnostic::new(
            "PROVIDER_UNSUPPORTED",
            "provider",
            "catalog",
            "Provider 未注册",
            false,
        );
        diagnostics.push(diagnostic.clone());
        return ServiceExecution {
            service: failed_service(service, &diagnostic),
            diagnostics,
            credential_updates: Vec::new(),
            credential_challenges: Vec::new(),
        };
    };
    let network_permit = match context.budgets.acquire_network(&context.cancellation) {
        Ok(permit) => permit,
        Err(error) => {
            let diagnostic = runtime_diagnostic(error);
            diagnostics.push(diagnostic.clone());
            return ServiceExecution {
                service: failed_service(service, &diagnostic),
                diagnostics,
                credential_updates: Vec::new(),
                credential_challenges: Vec::new(),
            };
        }
    };
    let request = ProviderRequest {
        account_id: plan.account_id.clone(),
        captured_at: context.captured_at.clone(),
        timeout: context.external_timeout,
        max_response_body_bytes: context.limits.response_body_bytes,
        credential,
    };
    let http = CountingHttpClient {
        inner: context.http,
        requests: Arc::clone(&context.metrics),
    };
    let provider_id = collector_provider::subscription_provider_id(&plan.service.app);
    let rule = rule_for(context.request.context.get("egressRules"), provider_id);
    let mut egress_state = None;
    let result = match rule {
        Err(error) => Err(egress_error(error, None, None, &mut egress_state)),
        Ok(None) => provider.query(&request, &http, &context.cancellation),
        Ok(Some(rule)) => match egress_cache.probe(rule.port, &http, &context.cancellation) {
            Err(error) => Err(egress_error(
                error,
                Some(&rule.country),
                None,
                &mut egress_state,
            )),
            Ok(trace) => match decide(&rule.country, &trace) {
                Err(error) => Err(egress_error(
                    error,
                    Some(&rule.country),
                    Some(&trace),
                    &mut egress_state,
                )),
                Ok(()) => {
                    egress_state = Some(serde_json::json!({
                        "status": "allowed", "expected": rule.country,
                        "observed": trace.country, "maskedIp": trace.masked_ip
                    }));
                    let proxy_http = ProxyHttpClient {
                        inner: http,
                        port: rule.port,
                    };
                    provider.query(&request, &proxy_http, &context.cancellation)
                }
            },
        },
    };
    drop(network_permit);
    if let Err(error) = &result {
        diagnostics.push(error.diagnostic.clone());
    }
    let mut outcome = provider.finalize_outcome(service, plan.account_id.as_deref(), result);
    if let (Some(state), Some(service)) = (egress_state, outcome.service.as_object_mut()) {
        service.insert("egress".to_owned(), state);
    }
    ServiceExecution {
        service: outcome.service,
        diagnostics,
        credential_updates: outcome.credential_updates,
        credential_challenges: outcome.credential_challenges,
    }
}

fn egress_error(
    error: ProbeError,
    expected: Option<&str>,
    trace: Option<&Trace>,
    state: &mut Option<Value>,
) -> ProviderError {
    let (code, message) = match error {
        ProbeError::Timeout => ("EGRESS_PROBE_TIMEOUT", "网络出口探测失败，已拦截查额"),
        ProbeError::UnknownCountry => ("EGRESS_COUNTRY_UNKNOWN", "无法识别出口国家，已拦截查额"),
        ProbeError::InvalidConfig => ("EGRESS_CONFIG_INVALID", "出口保护配置无效，已拦截查额"),
        ProbeError::China => ("EGRESS_CN_DIRECT", "当前线路出口为国内，已拦截查额"),
        ProbeError::Mismatch => ("EGRESS_COUNTRY_MISMATCH", "出口国家不匹配，已拦截查额"),
    };
    *state = Some(serde_json::json!({
        "status": "blocked", "reason": code, "expected": expected,
        "observed": trace.map(|value| &value.country), "maskedIp": trace.map(|value| &value.masked_ip),
    }));
    ProviderError::new(code, "egress", message, true)
}

fn resolve_credential(plan: &AccountPlan) -> Result<Option<Value>, Diagnostic> {
    if plan.credential.is_some() {
        return Ok(plan.credential.clone());
    }
    if let Some(entry) = catalog_entry_for_app(&plan.service.app) {
        if let Some(source) = entry.missing_credential_source {
            return Err(missing_credential(entry.display_prefix, source));
        }
    }
    Ok(None)
}

fn missing_credential(provider: &str, source: &str) -> Diagnostic {
    Diagnostic::new(
        "CREDENTIAL_MISSING",
        "security",
        "resolve",
        format!("未检测到 {provider} 本机凭证 ({source})"),
        false,
    )
}

fn runtime_diagnostic(error: RuntimeError) -> Diagnostic {
    ProviderError::from_runtime(error).diagnostic
}

fn failed_service(mut service: Value, diagnostic: &Diagnostic) -> Value {
    if let Some(object) = service.as_object_mut() {
        object.insert("status".to_owned(), Value::String("error".to_owned()));
        object.insert(
            "failureKind".to_owned(),
            Value::String(failure_kind_for_code(&diagnostic.code).to_owned()),
        );
        let message = diagnostic.message.chars().take(60).collect::<String>();
        object.insert(
            "note".to_owned(),
            Value::String(if message.is_empty() {
                "查询失败".to_owned()
            } else {
                format!("查询失败: {message}")
            }),
        );
    }
    service
}
