use collector_application::{CollectionMetrics, CollectionScanStats, SourcePerformanceMetric};
use collector_domain::BridgeResponse;
use serde_json::json;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy)]
pub(crate) struct ProcessResourceSnapshot {
    user_cpu_ns: u64,
    system_cpu_ns: u64,
    physical_footprint_bytes: u64,
    disk_read_bytes: u64,
}

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
pub(crate) fn process_resource_snapshot() -> Option<ProcessResourceSnapshot> {
    let mut usage = std::mem::MaybeUninit::<libc::rusage_info_v4>::zeroed();
    let result = unsafe {
        libc::proc_pid_rusage(
            std::process::id() as libc::c_int,
            libc::RUSAGE_INFO_V4,
            usage.as_mut_ptr().cast(),
        )
    };
    if result != 0 {
        return None;
    }
    let usage = unsafe { usage.assume_init() };
    Some(ProcessResourceSnapshot {
        user_cpu_ns: usage.ri_user_time,
        system_cpu_ns: usage.ri_system_time,
        physical_footprint_bytes: usage.ri_phys_footprint,
        disk_read_bytes: usage.ri_diskio_bytesread,
    })
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn process_resource_snapshot() -> Option<ProcessResourceSnapshot> {
    None
}

pub fn physical_disk_read_bytes() -> Option<u64> {
    process_resource_snapshot().map(|usage| usage.disk_read_bytes)
}

pub(crate) fn write_if_enabled(
    started: Instant,
    response: &BridgeResponse,
    stats: &CollectionScanStats,
    metrics: &CollectionMetrics,
    source_metrics: &[SourcePerformanceMetric],
    resource_start: Option<ProcessResourceSnapshot>,
    resource_end: Option<ProcessResourceSnapshot>,
) {
    let Some(path) = env::var_os("BRUCE_COLLECTOR_METRICS_PATH").map(PathBuf::from) else {
        return;
    };
    let mut payload = build_metrics_payload(stats, metrics, source_metrics);
    apply_resource_usage(&mut payload, resource_start, resource_end);
    let status = serde_json::to_value(&response.status)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned));
    let elapsed = started.elapsed();
    let payload_object = payload
        .as_object_mut()
        .expect("metrics payload is always a JSON object");
    payload_object.insert(
        "wall_time_ms".to_owned(),
        serde_json::Value::from(duration_ms(elapsed)),
    );
    payload_object.insert(
        "phase_timings_ms".to_owned(),
        json!({"collector.local": duration_ms(elapsed)}),
    );
    payload_object.insert(
        "diagnostic_count".to_owned(),
        serde_json::Value::from(response.diagnostics.len()),
    );
    payload_object.insert("status".to_owned(), json!(status));
    payload_object.insert(
        "artifact_present".to_owned(),
        serde_json::Value::from(response.artifact.is_some()),
    );
    let _ = write_atomic(&path, payload.to_string().as_bytes());
}

pub(crate) fn build_metrics_payload(
    stats: &CollectionScanStats,
    metrics: &CollectionMetrics,
    source_metrics: &[SourcePerformanceMetric],
) -> serde_json::Value {
    json!({
        "cpu_user_ms": null,
        "cpu_system_ms": null,
        "peak_rss_bytes": null,
        "disk_read_bytes": stats.bytes_read,
        "disk_read_scope": "logical_source_bytes",
        "physical_disk_read_bytes": null,
        "disk_read_operations": null,
        "files_visited": stats.files_visited,
        "duplicate_files_skipped": stats.duplicate_files_skipped,
        "duplicate_session_groups": stats.duplicate_session_groups,
        "conflict_session_groups": stats.conflict_session_groups,
        "files_changed": stats.cache_rebuilds.saturating_add(stats.cache_appends),
        "json_lines_parsed": stats.json_lines_parsed,
        "sqlite_rows_read": stats.sqlite_rows_read,
        "http_request_count": metrics.http_request_count,
        "retry_count": metrics.retry_count,
        "credential_refresh_count": metrics.credential_refresh_count,
        "cache_hits": stats.cache_hits,
        "cache_appends": stats.cache_appends,
        "cache_rebuilds": stats.cache_rebuilds,
        "cache_corruptions": stats.cache_corruptions,
        "cache_invalidations": stats.cache_invalidations,
        "cache_deletions": stats.cache_deletions,
        "sources": source_metrics.iter().map(source_metric_payload).collect::<Vec<_>>(),
    })
}

fn source_metric_payload(source: &SourcePerformanceMetric) -> serde_json::Value {
    let mut payload = serde_json::Map::new();
    for (key, value) in [
        ("id", serde_json::Value::from(source.source_id.clone())),
        (
            "elapsed_time_ms",
            serde_json::Value::from(source.elapsed_ms),
        ),
        (
            "files_visited",
            serde_json::Value::from(source.stats.files_visited),
        ),
        (
            "files_scanned",
            serde_json::Value::from(source.stats.files_scanned),
        ),
        (
            "files_skipped",
            serde_json::Value::from(source.stats.files_skipped),
        ),
        (
            "duplicate_files_skipped",
            serde_json::Value::from(source.stats.duplicate_files_skipped),
        ),
        (
            "duplicate_session_groups",
            serde_json::Value::from(source.stats.duplicate_session_groups),
        ),
        (
            "conflict_session_groups",
            serde_json::Value::from(source.stats.conflict_session_groups),
        ),
        ("io_errors", serde_json::Value::from(source.stats.io_errors)),
        (
            "cache_hits",
            serde_json::Value::from(source.stats.cache_hits),
        ),
        (
            "cache_appends",
            serde_json::Value::from(source.stats.cache_appends),
        ),
        (
            "cache_rebuilds",
            serde_json::Value::from(source.stats.cache_rebuilds),
        ),
        (
            "cache_corruptions",
            serde_json::Value::from(source.stats.cache_corruptions),
        ),
        (
            "cache_invalidations",
            serde_json::Value::from(source.stats.cache_invalidations),
        ),
        (
            "cache_deletions",
            serde_json::Value::from(source.stats.cache_deletions),
        ),
        (
            "sqlite_rows_read",
            serde_json::Value::from(source.stats.sqlite_rows_read),
        ),
        (
            "lines_seen",
            serde_json::Value::from(source.stats.lines_seen),
        ),
        (
            "json_lines_parsed",
            serde_json::Value::from(source.stats.json_lines_parsed),
        ),
        (
            "usage_records",
            serde_json::Value::from(source.stats.usage_records),
        ),
        (
            "malformed_lines",
            serde_json::Value::from(source.stats.malformed_lines),
        ),
        (
            "ignored_lines",
            serde_json::Value::from(source.stats.ignored_lines),
        ),
        (
            "truncated_lines",
            serde_json::Value::from(source.stats.truncated_lines),
        ),
        (
            "bytes_read",
            serde_json::Value::from(source.stats.bytes_read),
        ),
    ] {
        payload.insert(key.to_owned(), value);
    }
    serde_json::Value::Object(payload)
}

fn apply_resource_usage(
    payload: &mut serde_json::Value,
    start: Option<ProcessResourceSnapshot>,
    end: Option<ProcessResourceSnapshot>,
) {
    let Some(payload) = payload.as_object_mut() else {
        return;
    };
    if let Some(end) = end {
        payload.insert(
            "peak_rss_bytes".to_owned(),
            serde_json::Value::from(end.physical_footprint_bytes),
        );
        if let Some(start) = start {
            payload.insert(
                "cpu_user_ms".to_owned(),
                serde_json::Value::from(nanoseconds_to_milliseconds(
                    end.user_cpu_ns.saturating_sub(start.user_cpu_ns),
                )),
            );
            payload.insert(
                "cpu_system_ms".to_owned(),
                serde_json::Value::from(nanoseconds_to_milliseconds(
                    end.system_cpu_ns.saturating_sub(start.system_cpu_ns),
                )),
            );
            payload.insert(
                "physical_disk_read_bytes".to_owned(),
                serde_json::Value::from(end.disk_read_bytes.saturating_sub(start.disk_read_bytes)),
            );
        }
    }
}

fn nanoseconds_to_milliseconds(value: u64) -> f64 {
    value as f64 / 1_000_000.0
}

fn duration_ms(value: Duration) -> f64 {
    value.as_secs_f64() * 1000.0
}

fn write_atomic(path: &PathBuf, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "metrics path"))?;
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.tmp-{}-{}",
        path.file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("metrics"),
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    ));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
        }
        file.write_all(bytes)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::build_metrics_payload;
    use collector_application::{CollectionMetrics, CollectionScanStats, SourcePerformanceMetric};

    #[test]
    fn metrics_payload_exposes_source_counts_without_sensitive_values() {
        let source = SourcePerformanceMetric {
            source_id: "claude-code".to_owned(),
            elapsed_ms: 17,
            stats: CollectionScanStats {
                files_visited: 3,
                json_lines_parsed: 9,
                bytes_read: 512,
                ..CollectionScanStats::default()
            },
        };

        let payload = build_metrics_payload(
            &CollectionScanStats::default(),
            &CollectionMetrics::default(),
            &[source],
        );

        assert_eq!(payload["sources"][0]["id"], "claude-code");
        assert_eq!(payload["sources"][0]["elapsed_time_ms"], 17);
        assert_eq!(payload["sources"][0]["files_visited"], 3);
        assert_eq!(payload["sources"][0]["json_lines_parsed"], 9);
        assert_eq!(payload["sources"][0]["bytes_read"], 512);
        let text = payload.to_string();
        assert!(!text.contains("/Users/"));
        assert!(!text.contains("refresh_token"));
    }
}
