"""Opt-in, redacted runtime metrics for Collector baseline benchmarks.

Metrics are disabled unless ``BRUCE_COLLECTOR_METRICS_PATH`` is set. The
record contains timing and numeric counters only; it is never part of the
Bridge response or artifact.
"""

import contextlib
import ctypes
import json
import os
import resource
import struct
import sys
import tempfile
import time
from pathlib import Path


_COUNTER_NAMES = (
    "http_request_count",
    "retry_count",
    "credential_refresh_count",
    "disk_read_bytes",
    "files_visited",
    "files_changed",
    "json_lines_parsed",
    "sqlite_rows_read",
)


def _rss_bytes(value):
    # macOS reports ru_maxrss in bytes; Linux reports KiB.
    return int(value if sys.platform == "darwin" else value * 1024)


def _physical_disk_read_bytes():
    """Return macOS per-process disk-read bytes when the kernel exposes it."""
    if sys.platform != "darwin":
        return None
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        libproc.proc_pid_rusage.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_void_p,
        ]
        libproc.proc_pid_rusage.restype = ctypes.c_int
        buffer = ctypes.create_string_buffer(512)
        result = libproc.proc_pid_rusage(
            os.getpid(),
            4,  # RUSAGE_INFO_V4
            ctypes.byref(buffer),
        )
        if result != 0:
            return None
        # rusage_info_v4: uuid (16 bytes) + 15 uint64 fields before
        # ri_diskio_bytesread. Keep the ABI-specific offset local and bounded.
        return int(struct.unpack_from("Q", buffer.raw, 136)[0])
    except (AttributeError, OSError, struct.error, TypeError, ValueError):
        return None


class MetricsRecorder:
    """Small no-op-by-default recorder that cannot affect collection output."""

    def __init__(self, path=None):
        self.path = Path(path).expanduser() if path else None
        self.enabled = self.path is not None
        usage = resource.getrusage(resource.RUSAGE_SELF)
        self._started_ns = time.perf_counter_ns()
        self._start_user = usage.ru_utime
        self._start_system = usage.ru_stime
        self._start_inblock = usage.ru_inblock
        self._start_physical_disk_read_bytes = _physical_disk_read_bytes()
        self._counters = {name: 0 for name in _COUNTER_NAMES}
        self._phases = {}
        self._values = {}

    @classmethod
    def from_env(cls):
        return cls(os.environ.get("BRUCE_COLLECTOR_METRICS_PATH"))

    @classmethod
    def disabled(cls):
        return cls()

    @contextlib.contextmanager
    def phase(self, name):
        if not self.enabled:
            yield
            return
        started_ns = time.perf_counter_ns()
        try:
            yield
        finally:
            self._phases[name] = self._phases.get(name, 0.0) + (
                time.perf_counter_ns() - started_ns
            ) / 1_000_000

    def increment(self, name, amount=1):
        if self.enabled and name in self._counters:
            self._counters[name] += int(amount)

    def set_value(self, name, value):
        if self.enabled:
            self._values[name] = value

    def record_result(self, response):
        if not self.enabled or not isinstance(response, dict):
            return
        self.set_value("status", response.get("status"))
        self.set_value("diagnostic_count", len(response.get("diagnostics") or []))
        self.set_value(
            "credential_update_count",
            len(response.get("credentialUpdates") or []),
        )
        self.set_value(
            "credential_challenge_count",
            len(response.get("credentialChallenges") or []),
        )

    def _snapshot(self):
        usage = resource.getrusage(resource.RUSAGE_SELF)
        physical_disk_read_bytes = _physical_disk_read_bytes()
        if (
            self._start_physical_disk_read_bytes is not None
            and physical_disk_read_bytes is not None
        ):
            physical_disk_read_bytes = max(
                0,
                physical_disk_read_bytes - self._start_physical_disk_read_bytes,
            )
        else:
            physical_disk_read_bytes = None
        result = {
            "schemaVersion": 1,
            "implementation": "python",
            "wall_time_ms": round(
                (time.perf_counter_ns() - self._started_ns) / 1_000_000,
                3,
            ),
            "cpu_user_ms": round((usage.ru_utime - self._start_user) * 1000, 3),
            "cpu_system_ms": round(
                (usage.ru_stime - self._start_system) * 1000,
                3,
            ),
            "peak_rss_bytes": _rss_bytes(usage.ru_maxrss),
            # This is the logical byte size of JSONL source files opened by
            # the scanner, not physical disk traffic.
            "disk_read_bytes": self._counters["disk_read_bytes"],
            "disk_read_scope": "logical_source_bytes",
            "physical_disk_read_bytes": physical_disk_read_bytes,
            "disk_read_operations": max(
                0,
                int(usage.ru_inblock - self._start_inblock),
            ),
            "phases_ms": {
                key: round(value, 3)
                for key, value in sorted(self._phases.items())
            },
        }
        result.update(self._counters)
        result.update(self._values)
        return result

    def write(self):
        """Best-effort atomic write; metrics never break a collector run."""
        if not self.enabled:
            return
        temporary_path = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                dir=self.path.parent,
                prefix=".collector-metrics-",
                suffix=".tmp",
                delete=False,
            ) as handle:
                temporary_path = Path(handle.name)
                os.chmod(handle.name, 0o600)
                json.dump(
                    self._snapshot(),
                    handle,
                    ensure_ascii=False,
                    separators=(",", ":"),
                )
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_path, self.path)
        except (OSError, TypeError, ValueError):
            if temporary_path is not None:
                try:
                    temporary_path.unlink()
                except OSError:
                    pass
