#!/usr/bin/env python3
"""Run the Python collector through Bridge v1 with deterministic fixture I/O.

This benchmark-only entry point keeps the real Bridge validation and collector
implementation, but injects a bounded in-process HTTP seam. It never reads
the host Keychain or contacts a Provider service.
"""

import json
import os
import sys
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT))

from bridge.run_bridge import execute_request, _load_collector  # noqa: E402


_FIXTURE_HTTP_CALLS = 0


def _fixture_get_json(_url, _headers):
    global _FIXTURE_HTTP_CALLS
    _FIXTURE_HTTP_CALLS += 1
    delay_ms = int(os.environ.get("BRUCE_BENCHMARK_HTTP_DELAY_MS", "0"))
    if delay_ms > 0:
        time.sleep(delay_ms / 1000)
    if os.environ.get("BRUCE_BENCHMARK_PROVIDER_MODE") == "failure":
        raise RuntimeError("fixture provider failure")
    return {
        "limits": [
            {
                "detail": {
                    "limit": 100,
                    "remaining": 25,
                    "resetTime": "2026-08-21T09:00:00Z",
                }
            }
        ]
    }


def main():
    request = json.load(sys.stdin)
    collector = _load_collector("agent-usage")
    # The isolated HOME does not isolate macOS Keychain. Disable only the
    # collector's read-only Claude probe for this fixture process so an
    # operator's real login cannot affect the expiry case.
    original_security_find = collector.quota_official._security_find
    collector.quota_official._security_find = lambda _service: None
    try:
        response = execute_request(
            request,
            runtime_overrides={
                "agent-usage": {
                    "http": {"get_json": _fixture_get_json},
                }
            },
            collector_overrides={"agent-usage": collector.run_app},
        )
    finally:
        collector.quota_official._security_find = original_security_find
    metrics_path = os.environ.get("BRUCE_COLLECTOR_METRICS_PATH")
    if metrics_path:
        try:
            response["metrics"] = json.loads(
                Path(metrics_path).read_text(encoding="utf-8")
            )
        except (OSError, TypeError, ValueError):
            response["metrics"] = {}
    response.setdefault("metrics", {})["fixture_http_calls"] = _FIXTURE_HTTP_CALLS
    json.dump(response, sys.stdout, ensure_ascii=False, separators=(",", ":"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
