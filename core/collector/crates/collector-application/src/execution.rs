use crate::account::AccountPlan;
use crate::context::RunContext;
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
    let results = Arc::new(Mutex::new(
        (0..plans.len()).map(|_| None).collect::<Vec<_>>(),
    ));

    std::thread::scope(|scope| {
        for _ in 0..worker_count {
            let next = Arc::clone(&next);
            let results = Arc::clone(&results);
            scope.spawn(move || loop {
                let index = next.fetch_add(1, Ordering::AcqRel);
                if index >= plans.len() {
                    break;
                }
                let result = execute_one(context, &plans[index]);
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

fn execute_one(context: &RunContext<'_>, plan: &AccountPlan) -> ServiceExecution {
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
    let result = provider.query(&request, &http, &context.cancellation);
    drop(network_permit);
    if let Err(error) = &result {
        diagnostics.push(error.diagnostic.clone());
    }
    let outcome = provider.finalize_outcome(service, plan.account_id.as_deref(), result);
    ServiceExecution {
        service: outcome.service,
        diagnostics,
        credential_updates: outcome.credential_updates,
        credential_challenges: outcome.credential_challenges,
    }
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
