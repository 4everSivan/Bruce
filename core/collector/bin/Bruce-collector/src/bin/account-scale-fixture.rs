#![deny(unsafe_code)]

//! Deterministic, non-production account-scale benchmark transport.
//!
//! This target is intentionally separate from `Bruce-collector`: it injects a
//! fixture HTTP client and an empty credential source so benchmark runs never
//! contact Provider services or read the host Keychain.

use collector_application::collect_agent_usage_with_dependencies;
use collector_credential::{CredentialReadError, CredentialSource};
use collector_domain::BridgeRequest;
use collector_provider::{HttpClient, HttpRequest, HttpResponse, ProviderError};
use collector_runtime::CancellationToken;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

struct FixtureHttp {
    calls: AtomicUsize,
    delay: Duration,
}

impl HttpClient for FixtureHttp {
    fn send(
        &self,
        _request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        std::thread::sleep(self.delay);
        cancellation.check().map_err(ProviderError::from_runtime)?;
        self.calls.fetch_add(1, Ordering::AcqRel);
        Ok(HttpResponse {
            status: 200,
            body: br#"{"limits":[{"detail":{"limit":100,"remaining":25,"resetTime":"2026-08-21T09:00:00Z"}}]}"#.to_vec(),
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

fn main() -> io::Result<()> {
    let mut input = Vec::new();
    io::stdin().read_to_end(&mut input)?;
    let request: BridgeRequest = serde_json::from_slice(&input)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let delay_ms = std::env::var("BRUCE_ACCOUNT_FIXTURE_DELAY_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(25);
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        delay: Duration::from_millis(delay_ms),
    };
    let credentials = EmptyCredentialSource;
    let physical_disk_read_start = collector_bridge::physical_disk_read_bytes();
    let output = collect_agent_usage_with_dependencies(&request, &http, &credentials)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.message))?;
    let physical_disk_read_bytes = physical_disk_read_start.and_then(|start| {
        collector_bridge::physical_disk_read_bytes().map(|end| end.saturating_sub(start))
    });
    let diagnostics = output
        .diagnostics
        .iter()
        .map(|diagnostic| serde_json::to_value(diagnostic).expect("diagnostic is serializable"))
        .collect::<Vec<Value>>();
    let status = if diagnostics.is_empty() {
        "success"
    } else {
        "partial"
    };
    let response = json!({
        "status": status,
        "artifact": output.artifact,
        "diagnostics": diagnostics,
        "metrics": {
            "http_request_count": output.metrics.http_request_count,
            "retry_count": output.metrics.retry_count,
            "credential_refresh_count": output.metrics.credential_refresh_count,
            "physical_disk_read_bytes": physical_disk_read_bytes,
            "fixture_http_calls": http.calls.load(Ordering::Acquire),
        },
    });
    let stdout = io::stdout();
    let mut handle = stdout.lock();
    serde_json::to_writer(&mut handle, &response)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    handle.write_all(b"\n")?;
    handle.flush()
}
