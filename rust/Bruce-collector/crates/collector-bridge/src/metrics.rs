use collector_application::{CollectionMetrics, CollectionScanStats};
use collector_domain::BridgeResponse;
use serde_json::json;
use std::env;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "macos")]
#[allow(unsafe_code)]
pub fn physical_disk_read_bytes() -> Option<u64> {
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
    Some(usage.ri_diskio_bytesread)
}

#[cfg(not(target_os = "macos"))]
pub fn physical_disk_read_bytes() -> Option<u64> {
    None
}

pub(crate) fn write_if_enabled(
    started: Instant,
    response: &BridgeResponse,
    stats: &CollectionScanStats,
    metrics: &CollectionMetrics,
    physical_disk_read_start: Option<u64>,
) {
    let Some(path) = env::var_os("BRUCE_COLLECTOR_METRICS_PATH").map(PathBuf::from) else {
        return;
    };
    let elapsed = started.elapsed();
    let status = serde_json::to_value(&response.status)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned));
    let physical_disk_read_bytes = physical_disk_read_start
        .and_then(|start| physical_disk_read_bytes().map(|end| end.saturating_sub(start)));
    let payload = json!({
        "wall_time_ms": duration_ms(elapsed),
        "cpu_user_ms": null,
        "cpu_system_ms": null,
        "peak_rss_bytes": null,
        "disk_read_bytes": stats.bytes_read,
        "disk_read_scope": "logical_source_bytes",
        "physical_disk_read_bytes": physical_disk_read_bytes,
        "disk_read_operations": null,
        "files_visited": stats.files_visited,
        "files_changed": stats.cache_rebuilds.saturating_add(stats.cache_appends),
        "json_lines_parsed": stats.json_lines_parsed,
        "sqlite_rows_read": stats.sqlite_rows_read,
        "phase_timings_ms": {"collector.local": duration_ms(elapsed)},
        "http_request_count": metrics.http_request_count,
        "retry_count": metrics.retry_count,
        "credential_refresh_count": metrics.credential_refresh_count,
        "cache_hits": stats.cache_hits,
        "cache_appends": stats.cache_appends,
        "cache_rebuilds": stats.cache_rebuilds,
        "cache_corruptions": stats.cache_corruptions,
        "cache_invalidations": stats.cache_invalidations,
        "cache_deletions": stats.cache_deletions,
        "diagnostic_count": response.diagnostics.len(),
        "status": status,
        "artifact_present": response.artifact.is_some(),
    });
    let _ = write_atomic(&path, payload.to_string().as_bytes());
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
