#!/usr/bin/env python3
"""Run a deterministic, credential-free Python Collector baseline.

The benchmark creates synthetic Kimi JSONL sessions under an isolated HOME,
disables external quotas, and records Bridge metrics plus macOS ``time -l``
resource samples. It never reads the user's real Agent directories.
"""

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


REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE = REPO_ROOT / "bridge" / "run_bridge.py"
RUN_ID = "12345678-1234-4234-9234-123456789abc"
NOW = "2026-08-21T12:00:00+08:00"
SCENARIOS = {
    "small": (4, 32),
    "medium": (16, 128),
    "large": (64, 256),
}
ACCOUNT_SCALE_COUNTS = (4, 16, 32)


def _request(home):
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
            "capabilities": ["localSessions"],
        },
        "credentials": {},
    }


def _write_fixture(home, file_count, lines_per_file):
    root = home / ".kimi-code" / "sessions"
    root.mkdir(parents=True, exist_ok=True)
    base = dt.datetime.fromisoformat(NOW).timestamp()
    for file_index in range(file_count):
        path = root / ("benchmark-%03d.jsonl" % file_index)
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            for line_index in range(lines_per_file):
                timestamp_ms = int(
                    (base - ((line_index + file_index) % 14) * 86_400) * 1000
                )
                record = {
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
                handle.write(json.dumps(record, separators=(",", ":")))
                handle.write("\n")
        os.utime(path, (base, base))


def _parse_time_l(stderr):
    values = {}
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


def _canonical_hash(response):
    artifact = response.get("artifact") if isinstance(response, dict) else None
    normalized = {
        "status": response.get("status") if isinstance(response, dict) else None,
        "artifact": artifact,
        "diagnostics": response.get("diagnostics", [])
        if isinstance(response, dict)
        else [],
    }
    payload = json.dumps(
        normalized,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _run_once(home, metrics_path, command, implementation):
    request = json.dumps(_request(home), ensure_ascii=False).encode("utf-8")
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["BRUCE_COLLECTOR_METRICS_PATH"] = str(metrics_path)
    time_command = ["/usr/bin/time", "-l"] if Path("/usr/bin/time").exists() else []
    started = time.perf_counter_ns()
    completed = subprocess.run(
        time_command + command,
        cwd=REPO_ROOT,
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
        timeout=120,
    )
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
    if completed.returncode != 0:
        raise RuntimeError(
            "collector exited %d: %s"
            % (completed.returncode, completed.stderr.decode("utf-8", "replace"))
        )
    stdout = completed.stdout.decode("utf-8", "replace")
    try:
        response = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("collector stdout is not one JSON envelope") from exc
    if stdout.count("\n") != 1:
        raise RuntimeError("collector stdout contains more than one line")
    metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
    metrics["implementation"] = implementation
    metrics["parent_wall_time_ms"] = round(elapsed_ms, 3)
    metrics.update(_parse_time_l(completed.stderr.decode("utf-8", "replace")))
    metrics["artifact_sha256"] = _canonical_hash(response)
    return metrics


def _summary(values):
    ordered = sorted(values)
    if not ordered:
        return {}
    p50_index = max(0, min(len(ordered) - 1, int((len(ordered) - 1) * 0.50)))
    p95_index = max(0, min(len(ordered) - 1, int((len(ordered) - 1) * 0.95)))
    return {
        "count": len(ordered),
        "min": round(min(ordered), 3),
        "p50": round(ordered[p50_index], 3),
        "p95": round(ordered[p95_index], 3),
        "max": round(max(ordered), 3),
        "mean": round(statistics.mean(ordered), 3),
    }


def _run_scenario(name, file_count, lines_per_file, runs, command, implementation):
    samples = []
    with tempfile.TemporaryDirectory(prefix="bruce-collector-baseline-") as temp_dir:
        home = Path(temp_dir) / "home"
        home.mkdir()
        _write_fixture(home, file_count, lines_per_file)
        for index in range(runs):
            metrics_path = Path(temp_dir) / ("metrics-%d.json" % index)
            samples.append(_run_once(home, metrics_path, command, implementation))
    return {
        "name": name,
        "fixture": {
            "file_count": file_count,
            "lines_per_file": lines_per_file,
            "total_lines": file_count * lines_per_file,
        },
        "samples": samples,
        "summary": {
            key: _summary(
                [
                    sample[key]
                    for sample in samples
                    if isinstance(sample.get(key), (int, float))
                ]
            )
            for key in (
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
                "credential_refresh_count",
                "json_lines_parsed",
                "cache_hits",
                "cache_appends",
                "cache_rebuilds",
                "cache_invalidations",
                "cache_deletions",
            )
        },
    }


def _account_request(home, account_count):
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
            "capabilities": ["externalQuotas"],
        },
        "credentials": {
            "kimiQuotaAccounts": {
                "fixture-%03d" % index: {
                    "display_name": "Kimi fixture %03d" % index,
                    "api_key": "fixture-key-%03d" % index,
                }
                for index in range(account_count)
            }
        },
    }


def _run_account_once(home, account_count, command, implementation):
    request = json.dumps(
        _account_request(home, account_count), ensure_ascii=False
    ).encode("utf-8")
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["BRUCE_ACCOUNT_FIXTURE_DELAY_MS"] = "25"
    time_command = ["/usr/bin/time", "-l"] if Path("/usr/bin/time").exists() else []
    started = time.perf_counter_ns()
    completed = subprocess.run(
        time_command + command,
        cwd=REPO_ROOT,
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        check=False,
        timeout=120,
    )
    elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
    if completed.returncode != 0:
        raise RuntimeError(
            "account fixture exited %d: %s"
            % (completed.returncode, completed.stderr.decode("utf-8", "replace"))
        )
    stdout = completed.stdout.decode("utf-8", "replace")
    if stdout.count("\n") != 1:
        raise RuntimeError("account fixture stdout is not one JSON envelope")
    try:
        response = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError("account fixture stdout is not valid JSON") from exc
    metrics = dict(response.get("metrics") or {})
    metrics["implementation"] = implementation
    metrics["account_count"] = account_count
    metrics["parent_wall_time_ms"] = round(elapsed_ms, 3)
    metrics.update(_parse_time_l(completed.stderr.decode("utf-8", "replace")))
    metrics["artifact_sha256"] = _canonical_hash(response)
    return metrics


def _run_account_scale(runs, command, implementation):
    samples = []
    with tempfile.TemporaryDirectory(prefix="bruce-collector-account-scale-") as temp_dir:
        for account_count in ACCOUNT_SCALE_COUNTS:
            home = Path(temp_dir) / ("home-%03d" % account_count)
            home.mkdir()
            for _ in range(runs):
                samples.append(
                    _run_account_once(home, account_count, command, implementation)
                )
    summary_keys = (
        "account_count",
        "parent_wall_time_ms",
        "parent_cpu_user_ms",
        "parent_cpu_system_ms",
        "peak_rss_bytes",
        "http_request_count",
        "fixture_http_calls",
        "credential_refresh_count",
    )
    return {
        "account_counts": list(ACCOUNT_SCALE_COUNTS),
        "samples": samples,
        "summary": {
            key: _summary(
                [
                    sample[key]
                    for sample in samples
                    if isinstance(sample.get(key), (int, float))
                ]
            )
            for key in summary_keys
        },
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--scenario",
        choices=["all", *SCENARIOS, "account-scale"],
        default="all",
        help="fixture size to run (default: all)",
    )
    parser.add_argument("--runs", type=int, default=5, help="runs per scenario")
    parser.add_argument(
        "--output",
        type=Path,
        default=REPO_ROOT / "data" / "benchmarks" / "python-collector-baseline.json",
    )
    parser.add_argument(
        "--rust",
        type=Path,
        help="also benchmark a Rust Collector binary against the same fixtures",
    )
    parser.add_argument(
        "--rust-account-fixture",
        type=Path,
        help="deterministic Rust-only account-scale fixture binary",
    )
    args = parser.parse_args(argv)
    if args.runs < 1:
        parser.error("--runs must be at least 1")

    if args.scenario == "account-scale" and not args.rust_account_fixture:
        parser.error("--scenario account-scale requires --rust-account-fixture")
    if args.rust_account_fixture and (
        not args.rust_account_fixture.is_file()
        or not os.access(args.rust_account_fixture, os.X_OK)
    ):
        parser.error("--rust-account-fixture must point to an executable file")
    names = list(SCENARIOS) if args.scenario == "all" else [args.scenario]
    regular_names = [name for name in names if name in SCENARIOS]
    commands = {"python": ([sys.executable, str(BRIDGE)], "python")}
    if args.rust:
        if not args.rust.is_file() or not os.access(args.rust, os.X_OK):
            parser.error("--rust must point to an executable file")
        commands["rust"] = ([str(args.rust)], "rust")

    result_base = {
        "schemaVersion": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "runsPerScenario": args.runs,
        "network": "disabled",
        "credentials": "none",
    }
    if len(commands) == 1:
        command, implementation = commands["python"]
        result = {
            **result_base,
            "implementation": implementation,
            "scenarios": [
                _run_scenario(
                    name,
                    *SCENARIOS[name],
                    args.runs,
                    command,
                    implementation,
                )
                for name in regular_names
            ],
        }
    else:
        result = {
            **result_base,
            "implementation": "comparison",
            "implementations": {
                implementation: {
                    "scenarios": [
                        _run_scenario(
                            name,
                            *SCENARIOS[name],
                            args.runs,
                            command,
                            implementation,
                        )
                        for name in regular_names
                    ]
                }
                for command, implementation in commands.values()
            },
        }
    if args.scenario == "account-scale":
        result = {
            **result_base,
            "implementation": "rust-account-fixture",
            "scenarios": [],
        }
    if args.rust_account_fixture:
        result["account_scale"] = _run_account_scale(
            args.runs,
            [str(args.rust_account_fixture)],
            "rust-account-fixture",
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(
        json.dumps(
            {"output": str(args.output), "scenarios": names}, ensure_ascii=False
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
