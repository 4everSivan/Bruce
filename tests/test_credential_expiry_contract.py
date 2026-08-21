"""Shared credential-expiry fixtures: Python side of dual-end contract.

Locks `quota_official._is_expired` / Claude / Grok credential semantics against
`tests/fixtures/credential-expiry/*.json`. Swift
`SubscriptionCredentialEvaluator` consumes the same files in
BruceOnboardingCoreHarness. Changing either side requires updating fixtures or
both tests in the same PR.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COLLECTOR_DIR = REPO_ROOT / "agent-usage" / "collector"
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "credential-expiry"

sys.path.insert(0, str(COLLECTOR_DIR))


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _load_fixtures():
    paths = sorted(FIXTURES.glob("*.json"))
    assert paths, "expected shared credential-expiry fixtures under %s" % FIXTURES
    fixtures = []
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        data["_path"] = path.name
        fixtures.append(data)
    return fixtures


def _claude_status(module, credential, now_ts):
    raw = json.dumps(credential)
    try:
        token = module._parse_claude_credentials(raw, now_ts)
    except RuntimeError:
        return "expired"
    if token is None:
        return "missing"
    return "valid"


def _grok_status(module, credential, now_ts):
    if not isinstance(credential, dict):
        return "malformed"
    entry = module._select_grok_entry(credential)
    if entry is None:
        return "missing"
    if module._is_expired(entry.get("expires_at"), now_ts):
        return "expired"
    return "valid"


def _provider_status(module, fixture):
    provider = fixture["provider"]
    credential = fixture["credential"]
    now_ts = fixture["now_ts"]
    if provider == "claude":
        return _claude_status(module, credential, now_ts)
    if provider == "grok":
        return _grok_status(module, credential, now_ts)
    raise AssertionError("unknown provider in fixture %s: %s" % (fixture["_path"], provider))


REQUIRED_IDS = {
    "claude_valid",
    "claude_expired_ms",
    "claude_expired_s",
    "claude_bad_date",
    "grok_valid",
    "grok_expired",
}


class TestCredentialExpiryContract:
    @classmethod
    def setup_class(cls):
        cls.module = load_module(
            "quota_official_expiry_contract",
            "agent-usage/collector/quota_official.py",
        )
        cls.fixtures = _load_fixtures()

    def test_required_fixture_matrix_present(self):
        ids = {item["id"] for item in self.fixtures}
        missing = REQUIRED_IDS - ids
        assert not missing, "missing required expiry fixtures: %s" % sorted(missing)

    def test_is_expired_matches_fixture_matrix(self):
        for fixture in self.fixtures:
            got = self.module._is_expired(fixture["expires_value"], fixture["now_ts"])
            assert got is fixture["expected_is_expired"], (
                "%s: _is_expired(%r, %s) = %s, expected %s"
                % (
                    fixture["_path"],
                    fixture["expires_value"],
                    fixture["now_ts"],
                    got,
                    fixture["expected_is_expired"],
                )
            )

    def test_provider_status_matches_fixture_matrix(self):
        for fixture in self.fixtures:
            got = _provider_status(self.module, fixture)
            assert got == fixture["expected_status"], (
                "%s: status = %s, expected %s"
                % (fixture["_path"], got, fixture["expected_status"])
            )

    def test_claude_expired_ms_raises_like_collector(self):
        path = FIXTURES / "claude_expired_ms.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        raw = json.dumps(fixture["credential"])
        try:
            self.module._parse_claude_credentials(raw, fixture["now_ts"])
            raise AssertionError("expected RuntimeError for expired Claude ms token")
        except RuntimeError as exc:
            assert "过期" in str(exc)

    def test_grok_expired_raises_on_injected_read(self):
        path = FIXTURES / "grok_expired.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        try:
            self.module.read_grok_token(
                home="/tmp/Bruce-no-home",
                now_ts=fixture["now_ts"],
                injected=fixture["credential"],
            )
            raise AssertionError("expected RuntimeError for expired Grok token")
        except RuntimeError as exc:
            assert "过期" in str(exc)
