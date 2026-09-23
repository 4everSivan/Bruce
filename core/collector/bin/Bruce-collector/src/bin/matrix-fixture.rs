#![deny(unsafe_code)]

//! Deterministic, non-production fixture transport for the full benchmark
//! matrix. The real application orchestration is exercised with injected HTTP
//! and credential sources; no network or host Keychain access is possible.

use collector_application::collect_agent_usage_with_dependencies;
use collector_credential::{CredentialReadError, CredentialSource};
use collector_domain::BridgeRequest;
use collector_provider::{HttpClient, HttpRequest, HttpResponse, ProviderError};
use collector_runtime::CancellationToken;
use serde_json::{json, Value};
use std::io::{self, Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

struct FixtureHttp {
    calls: AtomicUsize,
    delay: Duration,
    failure: bool,
}

impl HttpClient for FixtureHttp {
    fn send(
        &self,
        request: HttpRequest,
        cancellation: &CancellationToken,
    ) -> Result<HttpResponse, ProviderError> {
        cancellation.check().map_err(ProviderError::from_runtime)?;
        if !self.delay.is_zero() {
            std::thread::sleep(self.delay);
        }
        cancellation.check().map_err(ProviderError::from_runtime)?;
        self.calls.fetch_add(1, Ordering::AcqRel);
        if self.failure {
            return Err(ProviderError::new(
                "FIXTURE_PROVIDER_FAILURE",
                "request",
                "fixture provider failure",
                true,
            ));
        }
        let body = if request.url.contains("anthropic.com") {
            br#"{"five_hour":{"utilization":25.0,"resets_at":"2026-08-21T09:00:00Z"}}"#.to_vec()
        } else {
            br#"{"limits":[{"detail":{"limit":100,"remaining":25,"resetTime":"2026-08-21T09:00:00Z"}}]}"#.to_vec()
        };
        Ok(HttpResponse { status: 200, body })
    }
}

struct FixtureCredentialSource {
    expired_claude: bool,
}

impl CredentialSource for FixtureCredentialSource {
    fn read_file(&self, path: &Path) -> Result<Option<Vec<u8>>, CredentialReadError> {
        if self.expired_claude && path.ends_with(".claude/.credentials.json") {
            return Ok(Some(
                br#"{"claudeAiOauth":{"accessToken":"fixture-expired-token","expiresAt":1}}"#
                    .to_vec(),
            ));
        }
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
    let mode = std::env::var("BRUCE_BENCHMARK_PROVIDER_MODE").unwrap_or_default();
    let delay_ms = std::env::var("BRUCE_BENCHMARK_HTTP_DELAY_MS")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(0);
    let http = FixtureHttp {
        calls: AtomicUsize::new(0),
        delay: Duration::from_millis(delay_ms),
        failure: mode == "failure",
    };
    let credentials = FixtureCredentialSource {
        expired_claude: mode == "credential-expired",
    };
    let started = Instant::now();
    let physical_disk_read_start = collector_bridge::physical_disk_read_bytes();
    let output = collect_agent_usage_with_dependencies(&request, &http, &credentials)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error.message))?;
    let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
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
        "credentialUpdates": output.credential_updates,
        "credentialChallenges": output.credential_challenges,
        "metrics": {
            "wall_time_ms": elapsed_ms,
            "phase_timings_ms": {"collector.total": elapsed_ms},
            "files_visited": output.scan_stats.files_visited,
            "files_changed": output
                .scan_stats
                .cache_rebuilds
                .saturating_add(output.scan_stats.cache_appends),
            "json_lines_parsed": output.scan_stats.json_lines_parsed,
            "disk_read_bytes": output.scan_stats.bytes_read,
            "disk_read_scope": "logical_source_bytes",
            "physical_disk_read_bytes": physical_disk_read_bytes,
            "sqlite_rows_read": output.scan_stats.sqlite_rows_read,
            "cache_hits": output.scan_stats.cache_hits,
            "cache_appends": output.scan_stats.cache_appends,
            "cache_rebuilds": output.scan_stats.cache_rebuilds,
            "cache_corruptions": output.scan_stats.cache_corruptions,
            "cache_invalidations": output.scan_stats.cache_invalidations,
            "cache_deletions": output.scan_stats.cache_deletions,
            "http_request_count": output.metrics.http_request_count,
            "retry_count": output.metrics.retry_count,
            "credential_refresh_count": output.metrics.credential_refresh_count,
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
