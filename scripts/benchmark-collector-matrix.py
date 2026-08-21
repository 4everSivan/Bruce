#!/usr/bin/env python3
"""Run the release-gate Python/Rust Collector performance matrix.

All network and credential operations are deterministic fixture seams. The
runner uses isolated HOME directories, records only redacted numeric metrics,
and emits one JSON evidence file suitable for the Rust migration review.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
PYTHON_FIXTURE = REPO_ROOT / "scripts" / "benchmark-python-fixture.py"
RUN_ID = "12345678-1234-4234-9234-123456789abc"
NOW = "2026-08-21T12:00:00+08:00"
SIZES = {
    "small": (4, 32),
    "medium": (16, 128),
    "large": (64, 256),
}
WINDOWS = (14, 182)
VARIANTS = ("cold", "warm-unchanged", "append", "rewrite-truncate")
ACCOUNT_COUNTS = (1, 10, 64)
SUMMARY_KEYS = (
    "parent_wall_time_ms",
    "wall_time_ms",
    "cpu_user_ms",
    "cpu_system_ms",
    "parent_cpu_user_ms",
    "parent_cpu_system_ms",
    "peak_rss_bytes",
    "disk_read_bytes",
    "physical_disk_read_bytes",
    "disk_read_operations",
    "http_request_count",
    "retry_count",
    "credential_refresh_count",
    "files_visited",
    "files_changed",
    "json_lines_parsed",
    "sqlite_rows_read",
    "cache_hits",
    "cache_appends",
    "cache_rebuilds",
    "cache_invalidations",
    "cache_deletions",
)


def _record(file_index: int, line_index: int, days: int) -> Dict[str, Any]:
    base = dt.datetime.fromisoformat(NOW).timestamp()
    timestamp_ms = int(
        (base - ((line_index + file_index) % days) * 86_400) * 1000
    )
    return {
        "type": "usage.record",
        "time": timestamp_ms,
        "model": "benchmark-model",
        "usage": {
            "inputOther": 100 + file_index,
            "output": 20 + line_index,
            "inputCacheRead": 5,
            "inputCacheCreation": 2,
        },
    }


def _write_fixture(home: Path, file_count: int, lines_per_file: int, days: int) -> None:
    root = home / ".kimi-code" / "sessions"
    root.mkdir(parents=True, exist_ok=True)
    base = dt.datetime.fromisoformat(NOW).timestamp()
    for file_index in range(file_count):
        path = root / ("benchmark-%03d.jsonl" % file_index)
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            for line_index in range(lines_per_file):
                handle.write(
                    json.dumps(
                        _record(file_index, line_index, days),
                        separators=(",", ":"),
                    )
                )
                handle.write("\n")
        os.utime(path, (base, base))


def _first_fixture(home: Path) -> Path:
    paths = sorted((home / ".kimi-code" / "sessions").glob("*.jsonl"))
    if not paths:
        raise RuntimeError("benchmark fixture has no JSONL files")
    return paths[0]


def _append_fixture(home: Path, days: int) -> None:
    path = _first_fixture(home)
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(_record(0, 100_000, days), separators=(",", ":")) + "\n")
    os.utime(path, (dt.datetime.fromisoformat(NOW).timestamp() + 1,) * 2)


def _rewrite_fixture(home: Path, days: int) -> None:
    path = _first_fixture(home)
    with path.open("w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(_record(0, 7, days), separators=(",", ":")) + "\n")
    os.utime(path, (dt.datetime.fromisoformat(NOW).timestamp() + 2,) * 2)


def _local_request(home: Path, days: int) -> Dict[str, Any]:
    return {
        "schemaVersion": 1,
        "runId": RUN_ID,
        "module": "agent-usage",
        "timeouts": {
            "localScanSeconds": 30,
            "externalRequestSeconds": 10,
            "moduleSeconds": 90,
        },
        "context": {
            "home": str(home),
            "now": NOW,
            "timezone": "Asia/Shanghai",
            "days": days,
            "capabilities": ["localSessions"],
        },
        "credentials": {},
    }


def _account_request(home: Path, account_count: int) -> Dict[str, Any]:
    return {
        "schemaVersion": 1,
        "runId": RUN_ID,
        "module": "agent-usage",
        "timeouts": {
            "localScanSeconds": 30,
            "externalRequestSeconds": 10,
            "moduleSeconds": 90,
        },
        "context": {
            "home": str(home),
            "now": NOW,
            "timezone": "Asia/Shanghai",
            "days": 14,
            "capabilities": ["externalQuotas"],
        },
        "credentials": {
            "kimiQuotaAccounts": {
                "fixture-%03d" % index: {
                    "display_name": "Kimi fixture %03d" % index,
                    "api_key": "synthetic-key-%03d" % index,
                }
                for index in range(account_count)
            }
        },
    }


def _provider_request(home: Path, mode: str) -> Dict[str, Any]:
    request = _account_request(home, 1)
    if mode == "credential-expired":
        request["credentials"] = {"providerMeta": {"claude": {"enabled": True}}}
    return request


def _write_expired_claude(home: Path) -> None:
    path = home / ".claude" / ".credentials.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(
            {
                "claudeAiOauth": {
                    "accessToken": "synthetic-expired-value",
                    "expiresAt": 1,
                }
            },
            separators=(",", ":"),
        )
        + "\n",
        encoding="utf-8",
    )
    os.chmod(path, 0o600)


def _parse_time_l(stderr: str) -> Dict[str, Any]:
    values: Dict[str, Any] = {}
    patterns = {
        "peak_rss_bytes": r"^\s*(\d+)\s+maximum resident set size$",
        "wrapper_physical_disk_read_bytes": r"^\s*(\d+)\s+bytes read from disk$",
        "wrapper_physical_disk_read_operations": r"^\s*(\d+)\s+block input operations$",
    }
    for line in stderr.splitlines():
        cpu_match = re.match(
            r"^\s*([0-9.]+) real\s+([0-9.]+) user\s+([0-9.]+) sys$",
            line,
        )
        if cpu_match:
            values["parent_cpu_user_ms"] = round(float(cpu_match.group(2)) * 1000, 3)
            values["parent_cpu_system_ms"] = round(float(cpu_match.group(3)) * 1000, 3)
        for key, pattern in patterns.items():
            match = re.match(pattern, line)
            if match:
                values[key] = int(match.group(1))
    return values


def _canonical_hash(response: Mapping[str, Any]) -> str:
    normalized = {
        "status": response.get("status"),
        "artifact": response.get("artifact"),
        "diagnostics": response.get("diagnostics", []),
    }
    payload = json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _semantic_value(value: Any) -> Any:
    if isinstance(value, list):
        return [_semantic_value(item) for item in value]
    if isinstance(value, dict):
        return {
            key: _semantic_value(item)
            for key, item in value.items()
            if key not in {"note", "capturedAt", "generatedAt"}
        }
    return value


def _semantic_hash(response: Mapping[str, Any]) -> str:
    # Provider error wording and diagnostic layering are intentionally allowed
    # to differ while the migration is converging. The artifact status and
    # windows are the behavioral parity surface; diagnostics remain reported
    # separately in every sample.
    normalized = {
        "status": response.get("status"),
        "artifact": _semantic_value(response.get("artifact")),
    }
    payload = json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _run_process(
    command: Sequence[str],
    request: Mapping[str, Any],
    home: Path,
    implementation: str,
    mode: str = "",
) -> Dict[str, Any]:
    metrics_path = home.parent / ("metrics-%d-%d.json" % (os.getpid(), time.time_ns()))
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["BRUCE_COLLECTOR_METRICS_PATH"] = str(metrics_path)
    environment["BRUCE_BENCHMARK_PROVIDER_MODE"] = mode
    environment["BRUCE_BENCHMARK_HTTP_DELAY_MS"] = "25" if mode in {"success", "failure"} else "0"
    environment["BRUCE_ACCOUNT_FIXTURE_DELAY_MS"] = "25"
    time_command = ["/usr/bin/time", "-l"] if Path("/usr/bin/time").exists() else []
    started = time.perf_counter_ns()
    completed = subprocess.run(
        time_command + list(command),
        cwd=REPO_ROOT,
        input=(json.dumps(request, ensure_ascii=False) + "\n").encode("utf-8"),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
        timeout=180,
    )
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
    stderr = completed.stderr.decode("utf-8", "replace")
    if completed.returncode != 0:
        raise RuntimeError(
            "%s exited %d: %s" % (implementation, completed.returncode, stderr)
        )
    stdout = completed.stdout.decode("utf-8", "replace")
    if stdout.count("\n") != 1:
        raise RuntimeError("%s stdout is not exactly one JSON line" % implementation)
    try:
        response = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("%s stdout is not valid JSON" % implementation) from exc
    embedded = response.get("metrics") if isinstance(response, dict) else None
    if isinstance(embedded, dict):
        metrics = dict(embedded)
    else:
        try:
            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise RuntimeError("%s did not produce metrics" % implementation) from exc
    metrics["implementation"] = implementation
    metrics["parent_wall_time_ms"] = round(elapsed_ms, 3)
    metrics.update(_parse_time_l(stderr))
    if metrics.get("peak_rss_bytes") is None:
        metrics["peak_rss_bytes"] = metrics.get("peak_rss_bytes")
    metrics["phase_timings_ms"] = metrics.get("phase_timings_ms") or metrics.get("phases_ms") or {}
    metrics["artifact_sha256"] = _canonical_hash(response)
    metrics["semantic_sha256"] = _semantic_hash(response)
    metrics["status"] = response.get("status")
    metrics["diagnostic_codes"] = sorted(
        diagnostic.get("code")
        for diagnostic in response.get("diagnostics", []) or []
        if isinstance(diagnostic, dict) and diagnostic.get("code")
    )
    for key in SUMMARY_KEYS:
        metrics.setdefault(key, 0 if key.endswith("count") else None)
    try:
        metrics_path.unlink()
    except OSError:
        pass
    return metrics


def _summary(values: Iterable[Any]) -> Dict[str, Any]:
    numbers = sorted(
        float(value)
        for value in values
        if isinstance(value, (int, float)) and not isinstance(value, bool)
    )
    if not numbers:
        return {}
    p50_index = max(0, min(len(numbers) - 1, int((len(numbers) - 1) * 0.50)))
    p95_index = max(0, min(len(numbers) - 1, int((len(numbers) - 1) * 0.95)))
    return {
        "count": len(numbers),
        "min": round(min(numbers), 3),
        "p50": round(numbers[p50_index], 3),
        "p95": round(numbers[p95_index], 3),
        "max": round(max(numbers), 3),
        "mean": round(statistics.mean(numbers), 3),
    }


def _summarize_samples(samples: Sequence[Mapping[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {
        key: _summary(sample.get(key) for sample in samples)
        for key in SUMMARY_KEYS
    }
    phases = sorted(
        {
            phase
            for sample in samples
            for phase in (sample.get("phase_timings_ms") or {})
        }
    )
    result["phase_timings_ms"] = {
        phase: _summary(
            (sample.get("phase_timings_ms") or {}).get(phase)
            for sample in samples
        )
        for phase in phases
    }
    result["statuses"] = sorted(
        {
            str(sample.get("status"))
            for sample in samples
            if sample.get("status") is not None
        }
    )
    result["diagnostic_codes"] = sorted(
        {
            code
            for sample in samples
            for code in sample.get("diagnostic_codes", [])
        }
    )
    return result


def _local_case(
    command: Sequence[str],
    implementation: str,
    size_name: str,
    days: int,
    variant: str,
    runs: int,
) -> Dict[str, Any]:
    file_count, lines_per_file = SIZES[size_name]
    samples: List[Dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="bruce-matrix-local-") as temp_dir:
        root = Path(temp_dir)
        if variant == "cold":
            for index in range(runs):
                home = root / ("home-cold-%03d" % index)
                home.mkdir()
                _write_fixture(home, file_count, lines_per_file, days)
                samples.append(
                    _run_process(
                        command,
                        _local_request(home, days),
                        home,
                        implementation,
                    )
                )
        else:
            home = root / "home-warm"
            home.mkdir()
            _write_fixture(home, file_count, lines_per_file, days)
            _run_process(command, _local_request(home, days), home, implementation)
            if variant == "append":
                _append_fixture(home, days)
            elif variant == "rewrite-truncate":
                _rewrite_fixture(home, days)
            elif variant != "warm-unchanged":
                raise ValueError("unknown local variant: %s" % variant)
            for _ in range(runs):
                samples.append(
                    _run_process(
                        command,
                        _local_request(home, days),
                        home,
                        implementation,
                    )
                )
    return {
        "implementation": implementation,
        "window_days": days,
        "size": size_name,
        "variant": variant,
        "fixture": {
            "file_count": file_count,
            "lines_per_file": lines_per_file,
            "total_lines": file_count * lines_per_file,
        },
        "samples": samples,
        "summary": _summarize_samples(samples),
    }


def _account_case(
    command: Sequence[str],
    implementation: str,
    account_count: int,
    runs: int,
) -> Dict[str, Any]:
    samples: List[Dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="bruce-matrix-accounts-") as temp_dir:
        home = Path(temp_dir) / "home"
        home.mkdir()
        request = _account_request(home, account_count)
        for _ in range(runs):
            sample = _run_process(command, request, home, implementation, mode="success")
            sample["account_count"] = account_count
            samples.append(sample)
    return {
        "implementation": implementation,
        "account_count": account_count,
        "samples": samples,
        "summary": _summarize_samples(samples),
        "invariants": {
            "http_requests_match_accounts": all(
                sample.get("http_request_count") == account_count
                for sample in samples
            ),
            "fixture_http_calls_match_accounts": all(
                sample.get("fixture_http_calls") == account_count
                for sample in samples
                if "fixture_http_calls" in sample
            ),
            "credential_refresh_is_zero": all(
                sample.get("credential_refresh_count") == 0
                for sample in samples
            ),
        },
    }


def _provider_case(
    command: Sequence[str], implementation: str, mode: str, runs: int
) -> Dict[str, Any]:
    samples: List[Dict[str, Any]] = []
    with tempfile.TemporaryDirectory(prefix="bruce-matrix-provider-") as temp_dir:
        home = Path(temp_dir) / "home"
        home.mkdir()
        if mode == "credential-expired":
            _write_expired_claude(home)
        request = _provider_request(home, mode)
        for _ in range(runs):
            sample = _run_process(command, request, home, implementation, mode=mode)
            samples.append(sample)
    return {
        "implementation": implementation,
        "mode": mode,
        "samples": samples,
        "summary": _summarize_samples(samples),
        "invariants": {
            "provider_has_http": mode not in {"success", "failure"}
            or all(sample.get("http_request_count", 0) >= 1 for sample in samples),
            "provider_failure_is_partial": mode != "failure"
            or all(sample.get("status") == "partial" for sample in samples),
            "credential_expiry_does_not_call_http": mode != "credential-expired"
            or all(sample.get("http_request_count", 0) == 0 for sample in samples),
            "credential_expiry_is_diagnosed": mode != "credential-expired"
            or all(
                sample.get("diagnostic_codes")
                or sample.get("status") in {"partial", "error"}
                for sample in samples
            ),
        },
    }


def _compare_results(
    left: Mapping[str, Any], right: Mapping[str, Any], semantic: bool = False
) -> Dict[str, Any]:
    key = "semantic_sha256" if semantic else "artifact_sha256"
    left_hashes = sorted(
        {sample.get(key) for sample in left.get("samples", []) if sample.get(key)}
    )
    right_hashes = sorted(
        {sample.get(key) for sample in right.get("samples", []) if sample.get(key)}
    )
    return {
        "mode": "semantic" if semantic else "exact",
        "left": left.get("implementation"),
        "right": right.get("implementation"),
        "left_hashes": left_hashes,
        "right_hashes": right_hashes,
        "parity": left_hashes == right_hashes and bool(left_hashes),
    }


def _aggregate_ratio(
    result: Mapping[str, Any], variant: str, metric: str, percentile: str
) -> Dict[str, Any]:
    python_values = []
    rust_values = []
    for days in result["local"].values():
        for size in days.values():
            case = size[variant]
            for implementation, target in (("python", python_values), ("rust", rust_values)):
                value = (
                    case[implementation]["summary"].get(metric, {}).get(percentile)
                )
                if isinstance(value, (int, float)) and (
                    value > 0 or metric == "disk_read_bytes"
                ):
                    target.append(float(value))
    if not python_values or not rust_values:
        return {
            "status": "not-measured",
            "python_median": None,
            "rust_median": None,
            "ratio": None,
        }
    python_median = statistics.median(python_values)
    rust_median = statistics.median(rust_values)
    return {
        "status": "measured",
        "python_median": round(python_median, 3),
        "rust_median": round(rust_median, 3),
        "ratio": round(rust_median / python_median, 4),
    }


def _require_executable(path: Path, name: str) -> None:
    if not path.is_file() or not os.access(path, os.X_OK):
        raise SystemExit("--%s must point to an executable file" % name)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rust", type=Path, required=True, help="Rust matrix-fixture executable")
    parser.add_argument("--runs", type=int, default=5, help="recorded runs per case")
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "data" / "benchmarks" / "rust-collector-matrix.json",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero for parity or fixture invariant failures",
    )
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    _require_executable(args.rust, "rust")
    if not PYTHON_FIXTURE.is_file():
        raise SystemExit("missing Python fixture: %s" % PYTHON_FIXTURE)

    commands = {
        "python": ([sys.executable, str(PYTHON_FIXTURE)], "python"),
        "rust": ([str(args.rust)], "rust"),
    }
    result: Dict[str, Any] = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "runsPerCase": args.runs,
        "windows": list(WINDOWS),
        "sizes": SIZES,
        "accountCounts": list(ACCOUNT_COUNTS),
        "network": "injected-fixture-only",
        "credentials": "synthetic-and-expired-fixture-only",
        "local": {},
        "accountScale": {},
        "provider": {},
        "comparisons": [],
        "invariants": [],
    }

    for days in WINDOWS:
        day_key = str(days)
        result["local"][day_key] = {}
        for size_name in SIZES:
            result["local"][day_key][size_name] = {}
            for variant in VARIANTS:
                cases = {
                    implementation: _local_case(
                        command,
                        implementation,
                        size_name,
                        days,
                        variant,
                        args.runs,
                    )
                    for command, implementation in commands.values()
                }
                result["local"][day_key][size_name][variant] = cases
                result["comparisons"].append(
                    {
                        "scope": "local",
                        "window_days": days,
                        "size": size_name,
                        "variant": variant,
                        **_compare_results(cases["python"], cases["rust"]),
                    }
                )

    for account_count in ACCOUNT_COUNTS:
        cases = {
            implementation: _account_case(
                command, implementation, account_count, args.runs
            )
            for command, implementation in commands.values()
        }
        result["accountScale"][str(account_count)] = cases
        result["comparisons"].append(
            {
                "scope": "account-scale",
                "account_count": account_count,
                **_compare_results(cases["python"], cases["rust"], semantic=True),
            }
        )
        for implementation, case in cases.items():
            result["invariants"].append(
                {
                    "scope": "account-scale",
                    "implementation": implementation,
                    "account_count": account_count,
                    **case["invariants"],
                }
            )

    for mode in ("success", "failure", "credential-expired"):
        cases = {
            implementation: _provider_case(
                command, implementation, mode, args.runs
            )
            for command, implementation in commands.values()
        }
        result["provider"][mode] = cases
        result["comparisons"].append(
            {
                "scope": "provider",
                "mode": mode,
                **_compare_results(cases["python"], cases["rust"], semantic=True),
            }
        )
        for implementation, case in cases.items():
            result["invariants"].append(
                {
                    "scope": "provider",
                    "implementation": implementation,
                    "mode": mode,
                    **case["invariants"],
                }
            )

    target_specs = [
        ("full_cold_wall_p50", "cold", "parent_wall_time_ms", "p50", 0.60),
        ("full_cold_wall_p95", "cold", "parent_wall_time_ms", "p95", 0.70),
        (
            "warm_unchanged_wall_p50",
            "warm-unchanged",
            "parent_wall_time_ms",
            "p50",
            0.40,
        ),
        ("cold_cpu_p50", "cold", "parent_cpu_user_ms", "p50", 0.70),
        ("cold_rss_p50", "cold", "peak_rss_bytes", "p50", 0.70),
        (
            "warm_disk_read_p50",
            "warm-unchanged",
            "disk_read_bytes",
            "p50",
            0.40,
        ),
    ]
    targets = {}
    for name, variant, metric, percentile, limit in target_specs:
        target = _aggregate_ratio(result, variant, metric, percentile)
        target["limit_ratio"] = limit
        target["passed"] = target["status"] == "measured" and target["ratio"] <= limit
        targets[name] = target
    result["targets"] = targets
    parity_failures = [item for item in result["comparisons"] if not item["parity"]]
    invariant_failures = [
        item
        for item in result["invariants"]
        if not all(value for key, value in item.items() if key not in {"scope", "implementation", "account_count", "mode"})
    ]
    result["gate"] = {
        "parity_failures": len(parity_failures),
        "invariant_failures": len(invariant_failures),
        "target_failures": sum(
            1 for target in targets.values() if target.get("passed") is False
        ),
        "measurement_gaps": [
            name for name, target in targets.items() if target["status"] == "not-measured"
        ],
        "passed": not parity_failures
        and not invariant_failures
        and not any(target.get("passed") is False for target in targets.values()),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        json.dumps(
            {
                "output": str(args.output),
                "cases": len(result["comparisons"]),
                "parityFailures": len(parity_failures),
                "invariantFailures": len(invariant_failures),
                "targetFailures": result["gate"]["target_failures"],
                "passed": result["gate"]["passed"],
            },
            ensure_ascii=False,
        )
    )
    return 0 if result["gate"]["passed"] or not args.strict else 2


if __name__ == "__main__":
    raise SystemExit(main())
