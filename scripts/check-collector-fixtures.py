#!/usr/bin/env python3
"""Canonicalize and scan Collector parity fixtures without exposing secrets."""

import argparse
import hashlib
import json
import re
from pathlib import Path


DEFAULT_ROOT = Path(__file__).resolve().parents[1] / "tests" / "fixtures"
SENSITIVE_KEYS = {
    "access_token",
    "refresh_token",
    "id_token",
    "api_key",
    "apikey",
    "client_secret",
    "password",
    "secret",
}
REDACTED_VALUES = {"<redacted>", "[REDACTED]", "[REDACTED_TOKEN]"}
SECRET_PATTERNS = (
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"),
    re.compile(r"(?i)\b(?:sk|ghp|xox[baprs])[-_][A-Za-z0-9_-]{12,}"),
    re.compile(r"/Users/[^/\s]+"),
    re.compile(r"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b", re.I),
)
RUNTIME_FIELDS = {"runId", "generatedAt"}


def canonicalize(value):
    if isinstance(value, dict):
        return {
            key: canonicalize(item)
            for key, item in sorted(value.items())
            if key not in RUNTIME_FIELDS
        }
    if isinstance(value, list):
        # Array order is part of the artifact contract and is intentionally
        # preserved; only object keys are canonicalized.
        return [canonicalize(item) for item in value]
    return value


def _find_secrets(value, path=()):
    findings = []
    if isinstance(value, dict):
        for key, item in value.items():
            current = path + (str(key),)
            if key in SENSITIVE_KEYS:
                if not isinstance(item, str) or item not in REDACTED_VALUES:
                    findings.append("%s contains a non-redacted credential" % "/".join(current))
            findings.extend(_find_secrets(item, current))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            findings.extend(_find_secrets(item, path + (str(index),)))
    elif isinstance(value, str):
        for pattern in SECRET_PATTERNS:
            if pattern.search(value):
                findings.append("%s matches a sensitive pattern" % "/".join(path))
                break
    return findings


def inspect_file(path):
    value = json.loads(path.read_text(encoding="utf-8"))
    findings = _find_secrets(value)
    canonical = canonicalize(value)
    encoded = json.dumps(
        canonical,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return {
        "path": str(path),
        "sha256": hashlib.sha256(encoded).hexdigest(),
        "secretFindings": findings,
        "canonical": canonical,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", nargs="?", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--print-canonical", type=Path)
    args = parser.parse_args(argv)

    paths = sorted(args.root.rglob("*.json"))
    results = [inspect_file(path) for path in paths]
    findings = [
        finding
        for result in results
        for finding in ([result["path"] + ": " + item for item in result["secretFindings"]])
    ]
    if args.print_canonical:
        selected = inspect_file(args.print_canonical)
        print(json.dumps(selected["canonical"], ensure_ascii=False, indent=2))
    summary = {
        "files": len(results),
        "secretFindings": findings,
        "canonicalHashes": {
            result["path"]: result["sha256"] for result in results
        },
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
