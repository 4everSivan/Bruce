"""Claude / Grok 官方订阅额度采集 (quota_official) 契约测试.

覆盖: 凭证解析 (Keychain/文件, 过期, OIDC 选择), Claude 窗口映射,
Grok gRPC-web 帧拆解与 protobuf 启发式扫描, grpc-status 错误映射,
以及 collect_usage CLI / App 模式接线.
"""

import importlib.util
import io
import json
import os
import struct
import sys
import tempfile
import unittest
import urllib.error
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COLLECTOR_DIR = REPO_ROOT / "agent-usage" / "collector"
sys.path.insert(0, str(COLLECTOR_DIR))


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NOW_TS = 1_800_000_000  # 固定时钟, 约 2027-01


def _varint(value):
    out = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def _tag(field, wire):
    return _varint((field << 3) | wire)


def _len_field(field, payload):
    return _tag(field, 2) + _varint(len(payload)) + payload


def _fixed32_field(field, value):
    return _tag(field, 5) + struct.pack("<f", value)


def _varint_field(field, value):
    return _tag(field, 0) + _varint(value)


def _grpc_web_frame(flags, payload):
    return bytes([flags]) + struct.pack(">I", len(payload)) + payload


class _FakeResponse:
    def __init__(self, body, headers=None):
        self._body = body
        self.headers = headers or {}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class QuotaOfficialModuleTests(unittest.TestCase):
    """quota_official 纯函数与凭证解析."""

    @classmethod
    def setUpClass(cls):
        cls.module = load_module(
            "quota_official_test", "agent-usage/collector/quota_official.py"
        )

    def setUp(self):
        self.module.runtime.set_http_overrides({})

    def tearDown(self):
        self.module.runtime.set_http_overrides({})

    # ---------------------------------------------------------- Claude 凭证

    def test_claude_credentials_primary_key_and_ms_expiry(self):
        content = json.dumps({
            "claudeAiOauth": {
                "accessToken": "sk-ant-test",
                "expiresAt": (NOW_TS + 3600) * 1000,
            }
        })
        self.assertEqual(
            self.module._parse_claude_credentials(content, NOW_TS), "sk-ant-test"
        )

    def test_claude_credentials_legacy_key_and_seconds_expiry(self):
        content = json.dumps({
            "claude.ai_oauth": {
                "accessToken": "tok-legacy",
                "expiresAt": NOW_TS + 3600,
            }
        })
        self.assertEqual(
            self.module._parse_claude_credentials(content, NOW_TS), "tok-legacy"
        )

    def test_claude_credentials_iso_expiry(self):
        content = json.dumps({
            "claudeAiOauth": {
                "accessToken": "tok-iso",
                "expiresAt": "2027-06-01T00:00:00+00:00",
            }
        })
        self.assertEqual(
            self.module._parse_claude_credentials(content, NOW_TS), "tok-iso"
        )

    def test_claude_credentials_expired_raises(self):
        content = json.dumps({
            "claudeAiOauth": {
                "accessToken": "tok-old",
                "expiresAt": (NOW_TS - 3600) * 1000,
            }
        })
        with self.assertRaises(RuntimeError):
            self.module._parse_claude_credentials(content, NOW_TS)

    def test_claude_credentials_missing_or_invalid(self):
        self.assertIsNone(self.module._parse_claude_credentials("{}", NOW_TS))
        self.assertIsNone(self.module._parse_claude_credentials("not json", NOW_TS))
        empty = json.dumps({"claudeAiOauth": {"accessToken": ""}})
        self.assertIsNone(self.module._parse_claude_credentials(empty, NOW_TS))

    def test_read_claude_token_keychain_preferred_over_file(self):
        with tempfile.TemporaryDirectory() as home:
            cred_dir = Path(home) / ".claude"
            cred_dir.mkdir()
            (cred_dir / ".credentials.json").write_text(json.dumps({
                "claudeAiOauth": {"accessToken": "from-file"}
            }))
            reader = lambda service: json.dumps({
                "claudeAiOauth": {"accessToken": "from-keychain"}
            })
            token = self.module.read_claude_token(home, NOW_TS, reader)
            self.assertEqual(token, "from-keychain")

    def test_read_claude_token_file_fallback_and_absent(self):
        with tempfile.TemporaryDirectory() as home:
            no_reader = lambda service: None
            self.assertIsNone(
                self.module.read_claude_token(home, NOW_TS, no_reader)
            )
            cred_dir = Path(home) / ".claude"
            cred_dir.mkdir()
            (cred_dir / ".credentials.json").write_text(json.dumps({
                "claudeAiOauth": {"accessToken": "file-tok"}
            }))
            self.assertEqual(
                self.module.read_claude_token(home, NOW_TS, no_reader), "file-tok"
            )

    # ---------------------------------------------------------- Grok 凭证

    def _write_grok_auth(self, home, root):
        grok_dir = Path(home) / ".grok"
        grok_dir.mkdir()
        (grok_dir / "auth.json").write_text(json.dumps(root))

    def test_grok_oidc_entry_preferred_over_legacy(self):
        with tempfile.TemporaryDirectory() as home:
            self._write_grok_auth(home, {
                "https://accounts.x.ai/sign-in": {"key": "legacy-tok"},
                "https://auth.x.ai::supergrok": {"key": "oidc-tok"},
            })
            self.assertEqual(self.module.read_grok_token(home, NOW_TS), "oidc-tok")

    def test_grok_legacy_sign_in_fallback(self):
        with tempfile.TemporaryDirectory() as home:
            self._write_grok_auth(home, {
                "https://accounts.x.ai/sign-in": {"key": "legacy-tok"},
            })
            self.assertEqual(
                self.module.read_grok_token(home, NOW_TS), "legacy-tok"
            )

    def test_grok_empty_key_entries_ignored(self):
        with tempfile.TemporaryDirectory() as home:
            self._write_grok_auth(home, {
                "https://auth.x.ai::supergrok": {"key": ""},
                "https://accounts.x.ai/sign-in": {"key": "legacy-tok"},
            })
            self.assertEqual(
                self.module.read_grok_token(home, NOW_TS), "legacy-tok"
            )

    def test_grok_expired_raises_and_missing_returns_none(self):
        with tempfile.TemporaryDirectory() as home:
            self.assertIsNone(self.module.read_grok_token(home, NOW_TS))
            self._write_grok_auth(home, {
                "https://auth.x.ai::supergrok": {
                    "key": "oidc-tok",
                    "expires_at": "2020-01-01T00:00:00+00:00",
                },
            })
            with self.assertRaises(RuntimeError):
                self.module.read_grok_token(home, NOW_TS)

    def test_grok_corrupt_auth_json_returns_none(self):
        with tempfile.TemporaryDirectory() as home:
            grok_dir = Path(home) / ".grok"
            grok_dir.mkdir()
            (grok_dir / "auth.json").write_text("{ not json")
            self.assertIsNone(self.module.read_grok_token(home, NOW_TS))

    # ---------------------------------------------------------- Claude 查询

    def test_service_claude_maps_windows_and_extra_usage(self):
        captured = {}

        def fake_get(url, headers):
            captured["url"] = url
            captured["headers"] = headers
            return {
                "five_hour": {"utilization": 42.0, "resets_at": "2027-01-15T10:00:00Z"},
                "seven_day": {"utilization": 10.0, "resets_at": "2027-01-20T10:00:00Z"},
                "seven_day_opus": {"utilization": 5.0, "resets_at": None},
                "extra_usage": {"is_enabled": True, "utilization": 77.0},
            }

        self.module.runtime.set_http_overrides({"get_json": fake_get})
        with tempfile.TemporaryDirectory() as home:
            cred_dir = Path(home) / ".claude"
            cred_dir.mkdir()
            (cred_dir / ".credentials.json").write_text(json.dumps({
                "claudeAiOauth": {"accessToken": "tok"}
            }))
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            result = self.module.service_claude(
                home, now, 8, keychain_reader=lambda service: None
            )
        self.assertEqual(captured["url"], self.module.CLAUDE_USAGE_URL)
        self.assertEqual(
            captured["headers"]["anthropic-beta"], self.module.CLAUDE_BETA_HEADER
        )
        self.assertEqual(captured["headers"]["Authorization"], "Bearer tok")
        self.assertEqual(result["kind"], "windows")
        by_label = {w["label"]: w for w in result["windows"]}
        self.assertEqual(by_label["每 5 小时"]["usedPercent"], 42.0)
        self.assertEqual(by_label["每 5 小时"]["windowMinutes"], 300)
        self.assertEqual(by_label["每周"]["windowMinutes"], 10080)
        self.assertEqual(by_label["每周 Opus"]["usedPercent"], 5.0)
        self.assertTrue(by_label["额外用量"]["ownRow"])
        self.assertIsNone(by_label["额外用量"]["windowMinutes"])

    def test_service_claude_without_credentials_returns_none(self):
        with tempfile.TemporaryDirectory() as home:
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            self.assertIsNone(
                self.module.service_claude(
                    home, now, 8, keychain_reader=lambda service: None
                )
            )

    # ---------------------------------------------------------- protobuf 扫描

    def test_parse_billing_payload_nested_percent_and_reset(self):
        reset_ts = NOW_TS + 7 * 86400
        payload = _len_field(
            1,
            _len_field(5, _varint_field(1, reset_ts))
            + _len_field(3, _fixed32_field(1, 68.0)),
        )
        percent, reset = self.module.parse_billing_payload(payload, NOW_TS)
        self.assertAlmostEqual(percent, 68.0)
        self.assertEqual(reset, reset_ts)

    def test_parse_billing_payload_grpc_web_frames(self):
        reset_ts = NOW_TS + 30 * 86400
        payload = _len_field(
            1, _len_field(3, _fixed32_field(1, 12.5))
            + _len_field(5, _varint_field(1, reset_ts))
        )
        body = _grpc_web_frame(0x00, payload) + _grpc_web_frame(
            0x80, b"grpc-status: 0\r\n"
        )
        percent, reset = self.module.parse_billing_payload(body, NOW_TS)
        self.assertAlmostEqual(percent, 12.5)
        self.assertEqual(reset, reset_ts)

    def test_parse_billing_payload_zero_usage_special_case(self):
        reset_ts = NOW_TS + 7 * 86400
        payload = _len_field(
            1,
            _len_field(5, _varint_field(1, reset_ts))
            + _len_field(6, _varint_field(1, 1)),
        )
        percent, reset = self.module.parse_billing_payload(payload, NOW_TS)
        self.assertEqual(percent, 0.0)
        self.assertEqual(reset, reset_ts)

    def test_parse_billing_payload_unlocatable_raises(self):
        payload = _len_field(1, _varint_field(2, 7))
        with self.assertRaises(RuntimeError):
            self.module.parse_billing_payload(payload, NOW_TS)
        with self.assertRaises(RuntimeError):
            self.module.parse_billing_payload(b"", NOW_TS)

    def test_trailer_fields_and_percent_decode(self):
        body = _grpc_web_frame(
            0x80, b"grpc-status: 16\r\ngrpc-message: bad%2Dcredentials\r\n"
        )
        fields = self.module._grpc_web_trailer_fields(body)
        self.assertEqual(fields["grpc-status"], "16")
        self.assertEqual(fields["grpc-message"], "bad-credentials")
        self.assertEqual(self.module._percent_decode("%ZZ"), "%ZZ")
        self.assertEqual(self.module._percent_decode("tail%2"), "tail%2")

    def test_grpc_status_error_mapping(self):
        self.assertTrue(self.module._grok_auth_failure(16, ""))
        self.assertTrue(self.module._grok_auth_failure(7, "bad-credentials"))
        self.assertFalse(self.module._grok_auth_failure(7, "permission denied"))
        self.assertFalse(self.module._grok_auth_failure(9, "no personal team"))
        with self.assertRaisesRegex(RuntimeError, "重新 grok login"):
            self.module._grok_raise_for_grpc_status(16, "")
        with self.assertRaisesRegex(RuntimeError, "团队账号"):
            self.module._grok_raise_for_grpc_status(9, "no personal team")
        with self.assertRaisesRegex(RuntimeError, "grpc-status 4"):
            self.module._grok_raise_for_grpc_status(4, "deadline exceeded")

    def test_grok_tier_label_thresholds(self):
        self.assertEqual(
            self.module._grok_tier_label(NOW_TS + 7 * 86400, NOW_TS), "每周"
        )
        self.assertEqual(
            self.module._grok_tier_label(NOW_TS + 30 * 86400, NOW_TS), "每月"
        )
        # < 1 天 -> 每 5 小时 (之前误判为"额度")
        self.assertEqual(
            self.module._grok_tier_label(NOW_TS + 3 * 3600, NOW_TS), "每 5 小时"
        )
        # 2 天 -> 额度 (非标准窗口)
        self.assertEqual(
            self.module._grok_tier_label(NOW_TS + 2 * 86400, NOW_TS), "额度"
        )
        self.assertEqual(self.module._grok_tier_label(None, NOW_TS), "额度")

    def test_grok_window_minutes_inference(self):
        """windowMinutes 供 Swift 精确映射 (300=5h, 10080=周, 43200=月)."""
        self.assertEqual(
            self.module._grok_window_minutes(NOW_TS + 3 * 3600, NOW_TS), 300
        )
        self.assertEqual(
            self.module._grok_window_minutes(NOW_TS + 7 * 86400, NOW_TS), 10080
        )
        self.assertEqual(
            self.module._grok_window_minutes(NOW_TS + 30 * 86400, NOW_TS), 43200
        )
        self.assertIsNone(
            self.module._grok_window_minutes(NOW_TS + 2 * 86400, NOW_TS)
        )
        self.assertIsNone(self.module._grok_window_minutes(None, NOW_TS))

    # ---------------------------------------------------------- Grok 查询

    def _grok_home(self, home):
        self._write_grok_auth(home, {
            "https://auth.x.ai::supergrok": {"key": "grok-tok"}
        })

    def test_service_grok_happy_path(self):
        reset_ts = NOW_TS + 7 * 86400
        payload = _len_field(
            1, _len_field(3, _fixed32_field(1, 55.0))
            + _len_field(5, _varint_field(1, reset_ts))
        )
        body = _grpc_web_frame(0x00, payload) + _grpc_web_frame(
            0x80, b"grpc-status: 0\r\n"
        )
        captured = {}

        def fake_urlopen(request, **kwargs):
            captured["url"] = request.full_url
            captured["headers"] = dict(request.header_items())
            captured["data"] = request.data
            return _FakeResponse(body)

        self.module.runtime.set_http_overrides({"urlopen": fake_urlopen})
        with tempfile.TemporaryDirectory() as home:
            self._grok_home(home)
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            result = self.module.service_grok(home, now, 8)
        self.assertEqual(captured["url"], self.module.GROK_BILLING_URL)
        self.assertEqual(
            captured["headers"].get("Content-type"), "application/grpc-web+proto"
        )
        self.assertEqual(captured["data"], b"\x00" * 5)
        window = result["windows"][0]
        self.assertEqual(window["label"], "每周")
        self.assertAlmostEqual(window["usedPercent"], 55.0)
        self.assertEqual(window["resetsAt"], reset_ts)

    def test_service_grok_trailer_auth_failure(self):
        body = _grpc_web_frame(
            0x80, b"grpc-status: 16\r\ngrpc-message: UNAUTHENTICATED\r\n"
        )

        def fake_urlopen(request, **kwargs):
            return _FakeResponse(body)

        self.module.runtime.set_http_overrides({"urlopen": fake_urlopen})
        with tempfile.TemporaryDirectory() as home:
            self._grok_home(home)
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            with self.assertRaisesRegex(RuntimeError, "重新 grok login"):
                self.module.service_grok(home, now, 8)

    def test_service_grok_http_401_and_no_credentials(self):
        def fake_urlopen(request, **kwargs):
            raise urllib.error.HTTPError(
                request.full_url, 401, "Unauthorized", {}, io.BytesIO(b"")
            )

        self.module.runtime.set_http_overrides({"urlopen": fake_urlopen})
        with tempfile.TemporaryDirectory() as home:
            self._grok_home(home)
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            with self.assertRaisesRegex(RuntimeError, "HTTP 401"):
                self.module.service_grok(home, now, 8)
        with tempfile.TemporaryDirectory() as home:
            now = datetime.fromtimestamp(NOW_TS, tz=timezone.utc)
            self.assertIsNone(self.module.service_grok(home, now, 8))


class CollectUsageOfficialWiringTests(unittest.TestCase):
    """collect_usage CLI / App 模式接线."""

    def setUp(self):
        self.module = load_module(
            "collect_usage_official_test",
            "agent-usage/collector/collect_usage.py",
        )
        self.quota = self.module.quota_official
        # 防测试触达真实登录 Keychain
        self._orig_security_find = self.quota._security_find
        self.quota._security_find = lambda service: None

    def tearDown(self):
        self.quota._security_find = self._orig_security_find
        self.module.runtime.set_http_overrides({})

    def _configure(self, home, **extra):
        ctx = {
            "home": home,
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "days": 2,
            "http": {
                "get_json": lambda *_: self.fail("unexpected GET"),
                "post_json": lambda *_: self.fail("unexpected POST"),
            },
        }
        ctx.update(extra)
        self.module._configure_runtime(ctx)

    def _fake_windows(self):
        return {
            "kind": "windows",
            "plan": None,
            "windows": [
                {
                    "label": "每 5 小时",
                    "usedPercent": 12.0,
                    "windowMinutes": 300,
                    "resetsAt": None,
                }
            ],
        }

    def test_cli_mode_official_services_appended_when_no_cc_db(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(home)
            original = self.quota.service_claude
            self.quota.service_claude = lambda h, n, t, **kw: self._fake_windows()
            try:
                cred_dir = Path(home) / ".claude"
                cred_dir.mkdir()
                (cred_dir / ".credentials.json").write_text(json.dumps({
                    "claudeAiOauth": {"accessToken": "tok"}
                }))
                services = self.module.collect_services()
            finally:
                self.quota.service_claude = original
        claude = [s for s in services if s["id"] == "claude"]
        self.assertEqual(len(claude), 1)
        self.assertEqual(claude[0]["status"], "ok")
        self.assertEqual(claude[0]["windows"][0]["label"], "每 5 小时")
        self.assertNotIn("grok", [s["id"] for s in services])

    def test_cli_mode_expired_credential_yields_error_entry(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(home)
            cred_dir = Path(home) / ".claude"
            cred_dir.mkdir()
            (cred_dir / ".credentials.json").write_text(json.dumps({
                "claudeAiOauth": {
                    "accessToken": "tok",
                    "expiresAt": 1_000_000_000,
                }
            }))
            services = self.module.collect_services()
        claude = [s for s in services if s["id"] == "claude"]
        self.assertEqual(len(claude), 1)
        self.assertEqual(claude[0]["status"], "error")
        self.assertIn("过期", claude[0]["note"])

    def test_cli_mode_no_credentials_no_official_entries(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(home)
            services = self.module.collect_services()
        self.assertEqual(services, [])

    def test_app_mode_enabled_flag_drives_query(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(
                home,
                app_mode=True,
                credentials={"provider_meta": {"claude": {"enabled": True}}},
            )
            original = self.quota.service_claude
            self.quota.service_claude = lambda h, n, t, **kw: self._fake_windows()
            try:
                services = self.module._collect_app_services()
            finally:
                self.quota.service_claude = original
        self.assertEqual([s["id"] for s in services], ["claude"])
        self.assertEqual(services[0]["status"], "ok")

    def test_app_mode_missing_local_credential_is_actionable_error(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(
                home,
                app_mode=True,
                credentials={"provider_meta": {"grok": {"enabled": True}}},
            )
            services = self.module._collect_app_services()
        self.assertEqual([s["id"] for s in services], ["grok"])
        self.assertEqual(services[0]["status"], "error")
        self.assertIn("Grok", services[0]["note"])

    def test_app_mode_disabled_flag_produces_no_entry(self):
        with tempfile.TemporaryDirectory() as home:
            self._configure(home, app_mode=True, credentials={"provider_meta": {}})
            services = self.module._collect_app_services()
        self.assertEqual(services, [])

    # Phase 5: App 模式注入凭证优先于本机文件

    def test_read_claude_token_injected_preferred_over_file(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".claude"), exist_ok=True)
            with open(
                os.path.join(home, ".claude", ".credentials.json"), "w", encoding="utf-8"
            ) as fh:
                json.dump({"claudeAiOauth": {"accessToken": "file-token"}}, fh)
            injected = json.dumps(
                {"claudeAiOauth": {"accessToken": "injected-token"}}
            )
            token = self.module.quota_official.read_claude_token(
                home, NOW_TS, injected=injected
            )
        self.assertEqual(token, "injected-token")

    def test_read_claude_token_injected_expired_raises(self):
        injected = json.dumps(
            {"claudeAiOauth": {"accessToken": "tok", "expiresAt": NOW_TS - 100}}
        )
        with tempfile.TemporaryDirectory() as home:
            with self.assertRaises(RuntimeError):
                self.module.quota_official.read_claude_token(
                    home, NOW_TS, injected=injected
                )

    def test_read_grok_token_injected_preferred_over_file(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".grok"), exist_ok=True)
            with open(os.path.join(home, ".grok", "auth.json"), "w", encoding="utf-8") as fh:
                json.dump({"https://auth.x.ai::file": {"key": "file-key"}}, fh)
            injected = json.dumps(
                {"https://auth.x.ai::injected": {"key": "injected-key"}}
            )
            token = self.module.quota_official.read_grok_token(
                home, NOW_TS, injected=injected
            )
        self.assertEqual(token, "injected-key")

    def test_read_grok_token_injected_expired_raises(self):
        injected = json.dumps(
            {"https://auth.x.ai::injected": {"key": "k", "expires_at": NOW_TS - 100}}
        )
        with tempfile.TemporaryDirectory() as home:
            with self.assertRaises(RuntimeError):
                self.module.quota_official.read_grok_token(
                    home, NOW_TS, injected=injected
                )

    def test_read_grok_token_injected_unparsable_falls_back_to_file(self):
        with tempfile.TemporaryDirectory() as home:
            os.makedirs(os.path.join(home, ".grok"), exist_ok=True)
            with open(os.path.join(home, ".grok", "auth.json"), "w", encoding="utf-8") as fh:
                json.dump({"https://auth.x.ai::file": {"key": "file-key"}}, fh)
            token = self.module.quota_official.read_grok_token(
                home, NOW_TS, injected="not-json"
            )
        self.assertEqual(token, "file-key")

    def test_app_mode_injected_claude_credential_produces_entry(self):
        injected = json.dumps(
            {"claudeAiOauth": {"accessToken": "tok", "expiresAt": NOW_TS + 3600}}
        )
        with tempfile.TemporaryDirectory() as home:
            self._configure(
                home,
                app_mode=True,
                credentials={
                    "provider_meta": {"claude": {"enabled": True}},
                    "claude_oauth": injected,
                },
                http={
                    "get_json": lambda *_a, **_k: {"five_hour": {"utilization": 10}}
                },
            )
            services = self.module._collect_app_services()
        self.assertEqual([s["id"] for s in services], ["claude"])
        self.assertEqual(services[0]["status"], "ok")

    def test_app_mode_injected_grok_credential_produces_entry(self):
        injected = json.dumps(
            {"https://auth.x.ai::injected": {"key": "k", "expires_at": NOW_TS + 3600}}
        )
        with tempfile.TemporaryDirectory() as home:
            self._configure(
                home,
                app_mode=True,
                credentials={
                    "provider_meta": {"grok": {"enabled": True}},
                    "grok_oauth": injected,
                },
                http={
                    "urlopen": lambda *_a, **_k: _FakeResponse(b"")
                },
            )
            # service_grok 需要 protobuf 载荷; 只验证凭证读取层不抛"未检测到"
            from unittest import mock
            with mock.patch.object(
                self.module.quota_official, "parse_billing_payload",
                return_value=(10.0, None),
            ):
                services = self.module._collect_app_services()
        self.assertEqual([s["id"] for s in services], ["grok"])


class OpenCodeGoServiceTests(unittest.TestCase):
    """OpenCode GO (opencode.ai 网页控制台 server function) 契约.

    覆盖: seroval 响应解析, 窗口语义 (每 5 小时/每周/每月),
    无窗口不输出, 凭证格式, 会话失效诊断, 多账号装配.
    """

    @classmethod
    def setUpClass(cls):
        cls.module = load_module(
            "quota_official_opencode_test",
            "agent-usage/collector/quota_official.py",
        )
        cls.now = datetime.fromtimestamp(NOW_TS, timezone.utc)

    def setUp(self):
        self.module.runtime.set_http_overrides({})

    def tearDown(self):
        self.module.runtime.set_http_overrides({})

    @staticmethod
    def _seroval(instance="server-fn:t1", **usage):
        """构造与真实响应同构的 seroval 载荷 (含 $R[n] 对象/数组引用)."""
        parts = []
        idx = 1
        for key, (status, reset_in, percent) in usage.items():
            parts.append(
                "%s:$R[%d]={status:%s,resetInSec:%d,usagePercent:%d}"
                % (key, idx, '"ok"' if status == "ok" else '"unavailable"', reset_in, percent)
            )
            idx += 1
        body = (
            ';0x14e;((self.$R=self.$R||{})["%s"]=[],'
            '($R=>$R[0]={mine:!0,useBalance:!1,region:$R[%d]=["us","eu"],%s})'
            '($R["%s"]))' % (instance, idx, ",".join(parts), instance)
        )
        return body.encode()

    def _urlopen(self, responses):
        calls = []

        def handler(request, *args, **kwargs):
            calls.append(request.full_url)
            body = responses[min(len(calls) - 1, len(responses) - 1)]
            return _FakeResponse(body if isinstance(body, bytes) else json.dumps(body).encode())

        return handler, calls

    def test_full_usage_map_to_unified_labels(self):
        body = self._seroval(
            rollingUsage=("ok", 8031, 3),
            weeklyUsage=("ok", 63831, 1),
            monthlyUsage=("ok", 2629986, 0),
        )
        handler, calls = self._urlopen([body])
        self.module.runtime.set_http_overrides({"urlopen": handler})
        svc = self.module.service_opencode_go(
            "/nonexistent", self.now, 8,
            injected={"auth": "Fe26.2**abc", "workspaceId": "wrk_01"},
        )
        self.assertEqual(svc["kind"], "windows")
        windows = svc["windows"]
        # 统一语义: 每 5 小时 / 每周 / 每月
        self.assertEqual(
            [w["label"] for w in windows],
            ["每 5 小时", "每周", "每月"],
        )
        self.assertEqual([w["windowMinutes"] for w in windows], [300, 10080, 43200])
        # usagePercent 透传
        self.assertEqual([w["usedPercent"] for w in windows], [3.0, 1.0, 0.0])
        # resetsAt = now + resetInSec
        self.assertEqual(windows[0]["resetsAt"], NOW_TS + 8031)
        self.assertEqual(windows[2]["resetsAt"], NOW_TS + 2629986)
        # 请求 URL 含 server fn 哈希与 seroval args
        self.assertIn(OpenCodeGoServiceTests.module.OPCODE_LITE_SUB_GET_HASH, calls[0])
        self.assertIn("wrk_01", calls[0])

    def test_missing_monthly_usage_omits_monthly_window(self):
        body = self._seroval(
            rollingUsage=("ok", 8031, 3),
            weeklyUsage=("ok", 63831, 1),
        )
        handler, _ = self._urlopen([body])
        self.module.runtime.set_http_overrides({"urlopen": handler})
        svc = self.module.service_opencode_go(
            "/nonexistent", self.now, 8,
            injected={"auth": "Fe26.2**abc", "workspaceId": "wrk_01"},
        )
        # 服务端没有 monthlyUsage -> 不显示每月
        self.assertEqual(
            [w["label"] for w in svc["windows"]],
            ["每 5 小时", "每周"],
        )

    def test_unavailable_usage_window_skipped(self):
        body = self._seroval(
            rollingUsage=("ok", 8031, 3),
            weeklyUsage=("unavailable", 0, 0),
            monthlyUsage=("ok", 2629986, 0),
        )
        handler, _ = self._urlopen([body])
        self.module.runtime.set_http_overrides({"urlopen": handler})
        svc = self.module.service_opencode_go(
            "/nonexistent", self.now, 8,
            injected={"auth": "Fe26.2**abc", "workspaceId": "wrk_01"},
        )
        # status != ok 的窗口不输出
        self.assertEqual(
            [w["label"] for w in svc["windows"]],
            ["每 5 小时", "每月"],
        )

    def test_no_credentials_returns_none(self):
        svc = self.module.service_opencode_go("/nonexistent", self.now, 8)
        self.assertIsNone(svc)

    def test_invalid_credential_shape_raises(self):
        with self.assertRaises(RuntimeError) as ctx:
            self.module.service_opencode_go(
                "/nonexistent", self.now, 8,
                injected={"auth": "Fe26.2**abc"},
            )
        self.assertIn("workspaceId", str(ctx.exception))

    def test_session_rejected_raises_auth_error(self):
        class _Unauthorized(_FakeResponse):
            def __enter__(self):
                raise urllib.error.HTTPError(
                    "https://opencode.ai/_server", 401, "Unauthorized", None, None
                )

        self.module.runtime.set_http_overrides(
            {"urlopen": lambda *_a, **_k: _Unauthorized(b"")}
        )
        with self.assertRaises(RuntimeError) as ctx:
            self.module.service_opencode_go(
                "/nonexistent", self.now, 8,
                injected={"auth": "Fe26.2**bad", "workspaceId": "wrk_01"},
            )
        self.assertIn("重新登录", str(ctx.exception))

    def test_unparsable_seroval_raises_diagnostic(self):
        handler, _ = self._urlopen([b"garbage-not-seroval"])
        self.module.runtime.set_http_overrides({"urlopen": handler})
        with self.assertRaises(RuntimeError) as ctx:
            self.module.service_opencode_go(
                "/nonexistent", self.now, 8,
                injected={"auth": "Fe26.2**abc", "workspaceId": "wrk_01"},
            )
        self.assertIn("解析失败", str(ctx.exception))
        self.assertIn("garbage", str(ctx.exception))

    def test_app_mode_multi_account_assembly(self):
        """App 模式多账号: opencode_go_quota_accounts 每账号一个 service 条目."""
        collector = load_module(
            "collect_usage_opencode_test",
            "agent-usage/collector/collect_usage.py",
        )
        original = collector.quota_official.service_opencode_go
        captured = []

        def fake_opencode_go(home, now, http_timeout, injected=None):
            captured.append(injected)
            return {
                "kind": "windows",
                "plan": None,
                "windows": [
                    {
                        "label": "每 5 小时",
                        "usedPercent": 0.0,
                        "windowMinutes": 300,
                        "resetsAt": None,
                    }
                ],
            }

        collector.quota_official.service_opencode_go = fake_opencode_go
        try:
            with tempfile.TemporaryDirectory() as home:
                ctx = {
                    "home": home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "days": 2,
                    "app_mode": True,
                    "credentials": {
                        "opencode_go_quota_accounts": {
                            "acct_a": {
                                "display_name": "Go · 个人",
                                "oauth": {"auth": "Fe26.2**a", "workspaceId": "wrk_a"},
                            },
                            "acct_b": {
                                "display_name": "Go · 团队",
                                "oauth": {"auth": "Fe26.2**b", "workspaceId": "wrk_b"},
                            },
                        }
                    },
                    "http": {},
                }
                collector._configure_runtime(ctx)
                services = collector._collect_app_services()
        finally:
            collector.quota_official.service_opencode_go = original
        ids = [s["id"] for s in services]
        self.assertIn("opencode_go_acct_a", ids)
        self.assertIn("opencode_go_acct_b", ids)
        self.assertEqual([s["status"] for s in services], ["ok", "ok"])
        # 每个账号的 cookie + workspaceId 独立传入
        self.assertEqual(len(captured), 2)
        self.assertEqual(captured[0]["auth"], "Fe26.2**a")
        self.assertEqual(captured[0]["workspaceId"], "wrk_a")
        self.assertEqual(captured[1]["workspaceId"], "wrk_b")


if __name__ == "__main__":
    unittest.main()
