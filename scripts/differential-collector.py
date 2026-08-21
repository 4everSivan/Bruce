#!/usr/bin/env python3
"""Compare Python Bridge and Rust Collector outputs without printing secrets.

Only explicitly approved runtime fields are normalized.  Mismatch details use
type, length, and SHA-256 summaries instead of echoing string values or JSON
payloads, so the runner is safe for redacted fixtures and local diagnostics.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
from typing import Any


RUNTIME_FIELDS = {"runId", "generatedAt"}
COMPARE_FIELDS = (
    "status",
    "artifact",
    "diagnostics",
    "credentialUpdates",
    "credentialChallenges",
)


def _canonical(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _canonical(item)
            for key, item in sorted(value.items())
            if key not in RUNTIME_FIELDS
        }
    if isinstance(value, list):
        return [_canonical(item) for item in value]
    return value


def _digest(value: Any) -> str:
    payload = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()[:16]


def _summary(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return f"bool:{value}"
    if isinstance(value, (int, float)):
        return f"number:{value}"
    if isinstance(value, str):
        return f"string(len={len(value)},sha256={_digest(value)})"
    if isinstance(value, list):
        return f"array(len={len(value)},sha256={_digest(value)})"
    if isinstance(value, dict):
        keys = ",".join(sorted(value.keys())[:12])
        return f"object(keys=[{keys}],sha256={_digest(value)})"
    return f"type:{type(value).__name__},sha256={_digest(str(value))}"


def _first_difference(left: Any, right: Any, path: str = "$") -> tuple[str, Any, Any] | None:
    if type(left) is not type(right):
        return path, left, right
    if isinstance(left, dict):
        keys = sorted(set(left) | set(right))
        for key in keys:
            if key not in left or key not in right:
                return f"{path}.{key}", left.get(key), right.get(key)
            difference = _first_difference(left[key], right[key], f"{path}.{key}")
            if difference:
                return difference
        return None
    if isinstance(left, list):
        if len(left) != len(right):
            return path, left, right
        for index, (left_item, right_item) in enumerate(zip(left, right)):
            difference = _first_difference(left_item, right_item, f"{path}[{index}]")
            if difference:
                return difference
        return None
    return None if left == right else (path, left, right)


def _run(command: list[str], payload: bytes, cwd: pathlib.Path) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=cwd,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"collector exited with code {completed.returncode}")
    lines = completed.stdout.splitlines()
    if len(lines) != 1:
        raise RuntimeError("collector stdout did not contain exactly one JSON line")
    try:
        value = json.loads(lines[0])
    except json.JSONDecodeError as error:
        raise RuntimeError("collector stdout was not valid JSON") from error
    if not isinstance(value, dict):
        raise RuntimeError("collector response was not a JSON object")
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", required=True, type=pathlib.Path)
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--bridge", type=pathlib.Path)
    parser.add_argument("--rust", type=pathlib.Path, required=True)
    args = parser.parse_args()

    repository = pathlib.Path(__file__).resolve().parents[1]
    bridge = args.bridge or repository / "bridge/run_bridge.py"
    request = json.loads(args.request.read_text(encoding="utf-8"))
    payload = json.dumps(request, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    python_response = _run([args.python, str(bridge)], payload, repository)
    rust_response = _run([str(args.rust)], payload, repository)

    python_canonical = _canonical(python_response)
    rust_canonical = _canonical(rust_response)
    for field in COMPARE_FIELDS:
        difference = _first_difference(
            python_canonical.get(field),
            rust_canonical.get(field),
            f"$.{field}",
        )
        if difference:
            path, python_value, rust_value = difference
            print(
                "PARITY MISMATCH "
                f"path={path} "
                f"python={_summary(python_value)} "
                f"rust={_summary(rust_value)}"
            )
            return 1
    print(f"PARITY OK request={args.request.name}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"PARITY ERROR {type(error).__name__}")
        raise SystemExit(2)
