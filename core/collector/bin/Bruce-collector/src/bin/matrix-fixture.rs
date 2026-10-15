#![deny(unsafe_code)]

//! Deterministic, non-production fixture transport for the full benchmark
//! matrix. The real application orchestration is exercised with injected HTTP
//! and credential sources; no network or host Keychain access is possible.

use collector_application::{collect_agent_usage_with_dependencies, SourcePerformanceMetric};
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
            "sources": source_metrics_payload(&output.source_metrics),
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

fn source_metrics_payload(source_metrics: &[SourcePerformanceMetric]) -> Value {
    source_metrics
        .iter()
        .map(source_metric_payload)
        .collect::<Vec<_>>()
        .into()
}

fn source_metric_payload(source: &SourcePerformanceMetric) -> Value {
    json!({
        "id": source.source_id,
        "elapsed_time_ms": source.elapsed_ms,
        "files_visited": source.stats.files_visited,
        "files_scanned": source.stats.files_scanned,
        "files_skipped": source.stats.files_skipped,
        "duplicate_files_skipped": source.stats.duplicate_files_skipped,
        "duplicate_session_groups": source.stats.duplicate_session_groups,
        "conflict_session_groups": source.stats.conflict_session_groups,
        "io_errors": source.stats.io_errors,
        "cache_hits": source.stats.cache_hits,
        "cache_appends": source.stats.cache_appends,
        "cache_rebuilds": source.stats.cache_rebuilds,
        "cache_corruptions": source.stats.cache_corruptions,
        "cache_invalidations": source.stats.cache_invalidations,
        "cache_deletions": source.stats.cache_deletions,
        "sqlite_rows_read": source.stats.sqlite_rows_read,
        "lines_seen": source.stats.lines_seen,
        "json_lines_parsed": source.stats.json_lines_parsed,
        "usage_records": source.stats.usage_records,
        "malformed_lines": source.stats.malformed_lines,
        "ignored_lines": source.stats.ignored_lines,
        "truncated_lines": source.stats.truncated_lines,
        "bytes_read": source.stats.bytes_read,
    })
}

#[cfg(test)]
mod tests {
    use super::source_metrics_payload;
    use collector_application::{CollectionScanStats, SourcePerformanceMetric};

    #[test]
    fn matrix_metrics_include_stable_source_fields_without_sensitive_values() {
        let payload = source_metrics_payload(&[
            SourcePerformanceMetric {
                source_id: "kimi-work".to_owned(),
                elapsed_ms: 17,
                stats: CollectionScanStats {
                    files_visited: 3,
                    json_lines_parsed: 9,
                    bytes_read: 512,
                    ..CollectionScanStats::default()
                },
            },
            SourcePerformanceMetric {
                source_id: "claude-code".to_owned(),
                elapsed_ms: 19,
                stats: CollectionScanStats::default(),
            },
        ]);
        assert_eq!(payload[0]["id"], "kimi-work");
        assert_eq!(payload[0]["elapsed_time_ms"], 17);
        assert_eq!(payload[0]["json_lines_parsed"], 9);
        assert_eq!(payload[1]["id"], "claude-code");
        let text = payload.to_string();
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("refresh_token"));
    }
}
