use collector_credential::CredentialSource;
use collector_domain::{BridgeRequest, CollectionWindow, Diagnostic};
use collector_provider::HttpClient;
use collector_runtime::{AccountSingleFlight, CancellationToken, RuntimeBudgets, RuntimeLimits};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, Default)]
pub struct CollectionMetrics {
    pub http_request_count: u64,
    pub retry_count: u64,
    pub credential_refresh_count: u64,
}

#[derive(Debug, Default)]
pub(crate) struct RuntimeCounters {
    pub http_request_count: AtomicUsize,
    pub retry_count: AtomicUsize,
    pub credential_refresh_count: AtomicUsize,
}

impl RuntimeCounters {
    pub fn snapshot(&self) -> CollectionMetrics {
        CollectionMetrics {
            http_request_count: self.http_request_count.load(Ordering::Acquire) as u64,
            retry_count: self.retry_count.load(Ordering::Acquire) as u64,
            credential_refresh_count: self.credential_refresh_count.load(Ordering::Acquire) as u64,
        }
    }
}

/// Per-run dependencies and resource budgets. The application owns this
/// context so adapters cannot create unbounded work or bypass cancellation.
pub(crate) struct RunContext<'a> {
    pub request: &'a BridgeRequest,
    pub window: CollectionWindow,
    pub limits: RuntimeLimits,
    pub budgets: RuntimeBudgets,
    pub cancellation: CancellationToken,
    pub http: &'a dyn HttpClient,
    pub credential_source: &'a dyn CredentialSource,
    pub account_single_flight: Arc<AccountSingleFlight<String, Option<Value>, Diagnostic>>,
    pub metrics: Arc<RuntimeCounters>,
    pub home: PathBuf,
    pub captured_at: String,
    pub external_timeout: Duration,
}

impl<'a> RunContext<'a> {
    pub fn new(
        request: &'a BridgeRequest,
        window: CollectionWindow,
        http: &'a dyn HttpClient,
        credential_source: &'a dyn CredentialSource,
        limits: RuntimeLimits,
    ) -> Result<Self, Diagnostic> {
        let budgets = limits.budgets().map_err(|_| {
            Diagnostic::new(
                "RUNTIME_INVALID_LIMITS",
                "runtime",
                "setup",
                "运行时资源限制无效",
                false,
            )
        })?;
        let deadline = Instant::now()
            .checked_add(Duration::from_secs_f64(request.timeouts.module_seconds))
            .unwrap_or_else(Instant::now);
        let home = request
            .context
            .get("home")
            .and_then(Value::as_str)
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("."));
        Ok(Self {
            request,
            captured_at: window.generated_at(),
            window,
            limits,
            budgets,
            cancellation: CancellationToken::with_deadline(deadline),
            http,
            credential_source,
            account_single_flight: Arc::new(AccountSingleFlight::default()),
            metrics: Arc::new(RuntimeCounters::default()),
            home,
            external_timeout: Duration::from_secs_f64(request.timeouts.external_request_seconds),
        })
    }

    pub fn capability_allowed(&self, name: &str) -> bool {
        self.request
            .context
            .get("capabilities")
            .and_then(Value::as_array)
            .map(|values| values.iter().any(|value| value.as_str() == Some(name)))
            .unwrap_or(true)
    }
}
