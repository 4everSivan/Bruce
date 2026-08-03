import base64
import hashlib
import importlib.util
import json
import os
import sqlite3
import ssl
import sys
import tempfile
import unittest
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AgentCollectorContextTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_context_test",
            "agent-usage/collector/collect_usage.py",
        )

    def test_empty_home_and_clock_are_injectable(self):
        with tempfile.TemporaryDirectory() as temp_home:
            result = self.module.run(
                {
                    "home": temp_home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "days": 2,
                    "http": {
                        "get_json": lambda *_: self.fail("unexpected GET"),
                        "post_json": lambda *_: self.fail("unexpected POST"),
                    },
                }
            )

        artifact = result["artifact"]
        self.assertEqual(artifact["generatedAt"], "2026-07-28T12:00:00+08:00")
        self.assertEqual(self.module.DAY_LIST, ["2026-07-27", "2026-07-28"])
        self.assertTrue(
            all(
                [entry["date"] for entry in agent["daily"]]
                == ["2026-07-27", "2026-07-28"]
                for agent in artifact["agents"]
            )
        )
        self.assertTrue(self.module.CC_SWITCH_DB.startswith(temp_home))

    def test_timezone_controls_day_and_hour_buckets(self):
        self.module._configure_runtime(
            {
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
            }
        )
        timestamp = datetime(
            2026, 7, 27, 16, 30, tzinfo=timezone.utc
        ).timestamp()
        self.assertEqual(self.module.day_of(timestamp), "2026-07-28")
        self.assertEqual(self.module.hour_of(timestamp), 0)

    def test_kimi_credentials_and_http_are_injectable(self):
        def post_json(url, payload, headers):
            self.assertIn("Authorization", headers)
            if url == self.module.KIMI_STATS_URL:
                return {
                    "ratelimitCode5h": {"ratio": 0.25},
                    "ratelimitCode7d": {"ratio": 0.5},
                }
            if url == self.module.KIMI_SUB_URL:
                return {"plan": "Moderato"}
            self.fail("unexpected URL: %s" % url)

        self.module._configure_runtime(
            {
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "credentials": {
                    "kimi_web_tokens": {
                        "access_token": "fixture-access",
                        "refresh_token": "fixture-refresh",
                    }
                },
                "http": {"post_json": post_json},
            }
        )
        result = self.module.service_kimi_coding({})
        self.assertEqual(result["kind"], "windows")
        self.assertEqual(result["plan"], "Moderato")
        self.assertEqual(len(result["windows"]), 2)

    def test_app_mode_returns_kimi_update_without_writing_auth_file(self):
        with tempfile.TemporaryDirectory() as temp_home:
            token_path = (
                Path(temp_home)
                / ".config"
                / "kimi-dashboard"
                / "kimi-web-tokens.json"
            )
            token_path.parent.mkdir(parents=True)
            token_path.write_text(
                json.dumps(
                    {
                        "access_token": "old-access",
                        "refresh_token": "old-refresh",
                    }
                ),
                encoding="utf-8",
            )
            before = hashlib.sha256(token_path.read_bytes()).hexdigest()
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "http": {
                        "post_json": lambda *_: {
                            "access_token": "new-access",
                            "refresh_token": "new-refresh",
                        }
                    },
                }
            )

            refreshed = self.module._kimi_web_refresh(
                {
                    "access_token": "old-access",
                    "refresh_token": "old-refresh",
                }
            )
            after = hashlib.sha256(token_path.read_bytes()).hexdigest()

        self.assertEqual(refreshed["access_token"], "new-access")
        self.assertEqual(before, after)
        self.assertEqual(
            self.module._RUNTIME_CREDENTIAL_UPDATES,
            [
                {
                    "provider": "kimi",
                    "accountId": "default",
                    "kind": "oauthTokens",
                    "operation": "replace",
                    "credentials": {
                        "access_token": "new-access",
                        "refresh_token": "new-refresh",
                    },
                }
            ],
        )

    def test_app_mode_returns_codex_update_without_writing_auth_files(self):
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth_path = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cli_auth_path = Path(temp_home) / ".codex" / "auth.json"
            cc_auth_path.parent.mkdir(parents=True)
            cli_auth_path.parent.mkdir(parents=True)
            cc_auth_path.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "account-1": {
                                "email": "fixture@example.test",
                                "refresh_token": "old-cc-refresh",
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            cli_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "account_id": "account-1",
                            "refresh_token": "old-cli-refresh",
                        }
                    }
                ),
                encoding="utf-8",
            )
            before = {
                str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (cc_auth_path, cli_auth_path)
            }
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "credentials": {
                        "codex_oauth_auth": json.loads(
                            cc_auth_path.read_text(encoding="utf-8")
                        ),
                        "codex_auth": json.loads(
                            cli_auth_path.read_text(encoding="utf-8")
                        ),
                    },
                    "http": {
                        "get_json": lambda *_: {
                            "plan_type": "fixture",
                            "rate_limit": {},
                        }
                    },
                }
            )
            original_refresh = self.module._codex_refresh
            self.module._codex_refresh = lambda _token: {
                "access_token": "new-access",
                "id_token": "new-id",
                "refresh_token": "new-refresh",
            }
            try:
                services = self.module.service_codex_accounts()
            finally:
                self.module._codex_refresh = original_refresh
            after = {
                str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (cc_auth_path, cli_auth_path)
            }

        self.assertEqual(services[0]["status"], "empty")
        self.assertEqual(before, after)
        self.assertEqual(
            self.module._RUNTIME_CREDENTIAL_UPDATES[0]["credentials"],
            {
                "access_token": "new-access",
                "refresh_token": "new-refresh",
                "id_token": "new-id",
            },
        )

    def test_app_mode_does_not_read_cli_auth_from_disk(self):
        """App 模式未注入 codex_auth 时不得回退读 ~/.codex/auth.json."""
        with tempfile.TemporaryDirectory() as temp_home:
            cli_auth_path = Path(temp_home) / ".codex" / "auth.json"
            cli_auth_path.parent.mkdir(parents=True)
            cli_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "account_id": "account-1",
                            "refresh_token": "cli-refresh",
                        }
                    }
                ),
                encoding="utf-8",
            )
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "credentials": {
                        "codex_oauth_auth": {
                            "accounts": {
                                "account-1": {"refresh_token": "cc-refresh"}
                            }
                        },
                    },
                    "http": {
                        "get_json": lambda *_: {
                            "plan_type": "fixture",
                            "rate_limit": {},
                        }
                    },
                }
            )
            attempts = []
            original_refresh = self.module._codex_refresh
            self.module._codex_refresh = lambda token: attempts.append(
                token
            ) or {"access_token": "a", "refresh_token": "r"}
            try:
                services = self.module.service_codex_accounts()
            finally:
                self.module._codex_refresh = original_refresh

        self.assertEqual(services[0]["status"], "empty")
        self.assertEqual(
            attempts,
            ["cc-refresh"],
            "App 模式未注入 codex_auth 时不得使用磁盘 CLI 令牌",
        )

    def test_app_mode_returns_antigravity_update_without_writing_auth_file(self):
        class FakeResponse:
            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps(self.payload).encode("utf-8")

        with tempfile.TemporaryDirectory() as temp_home:
            token_path = (
                Path(temp_home)
                / ".gemini"
                / "antigravity-cli"
                / "antigravity-oauth-token"
            )
            token_path.parent.mkdir(parents=True)
            token_path.write_text(
                json.dumps(
                    {
                        "token": {
                            "access_token": "old-access",
                            "refresh_token": "old-refresh",
                        }
                    }
                ),
                encoding="utf-8",
            )
            responses = iter(
                [
                    {"access_token": "new-access", "expires_in": 3600},
                    {"groups": []},
                ]
            )
            before = hashlib.sha256(token_path.read_bytes()).hexdigest()
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "antigravity_oauth": json.loads(
                            token_path.read_text(encoding="utf-8")
                        )
                    },
                    "http": {
                        "urlopen": lambda *_args, **_kwargs: FakeResponse(
                            next(responses)
                        )
                    },
                }
            )
            services = self.module.service_antigravity()
            after = hashlib.sha256(token_path.read_bytes()).hexdigest()

        self.assertEqual(services[0]["status"], "empty")
        self.assertEqual(before, after)
        self.assertEqual(
            self.module._RUNTIME_CREDENTIAL_UPDATES[0]["credentials"][
                "access_token"
            ],
            "new-access",
        )

    def test_load_agy_oauth_keychain_fallback_decodes_go_keyring(self):
        payload = {
            "token": {"access_token": "a", "refresh_token": "r"},
            "auth_method": "oauth",
        }
        encoded = base64.b64encode(json.dumps(payload).encode("utf-8")).decode("ascii")
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {"home": temp_home, "now": "2026-07-28T12:00:00+08:00"}
            )
            original = self.module._security_find_generic_password
            self.module._security_find_generic_password = (
                lambda service, account: "go-keyring-base64:" + encoded
            )
            try:
                data, source = self.module._load_agy_oauth()
            finally:
                self.module._security_find_generic_password = original

        self.assertEqual(source, "keychain")
        self.assertEqual(data, payload)

    def test_load_agy_oauth_prefers_file_over_keychain(self):
        payload = {"token": {"access_token": "file-access"}}
        with tempfile.TemporaryDirectory() as temp_home:
            token_path = (
                Path(temp_home)
                / ".gemini"
                / "antigravity-cli"
                / "antigravity-oauth-token"
            )
            token_path.parent.mkdir(parents=True)
            token_path.write_text(json.dumps(payload), encoding="utf-8")
            self.module._configure_runtime(
                {"home": temp_home, "now": "2026-07-28T12:00:00+08:00"}
            )
            original = self.module._security_find_generic_password
            self.module._security_find_generic_password = (
                lambda service, account: "go-keyring-base64:should-not-be-used"
            )
            try:
                data, source = self.module._load_agy_oauth()
            finally:
                self.module._security_find_generic_password = original

        self.assertEqual(source, "file")
        self.assertEqual(data, payload)

    def test_service_antigravity_keychain_source_no_writeback(self):
        class FakeResponse:
            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps(self.payload).encode("utf-8")

        keychain_payload = {
            "token": {"access_token": "old-access", "refresh_token": "old-refresh"}
        }
        encoded = base64.b64encode(
            json.dumps(keychain_payload).encode("utf-8")
        ).decode("ascii")
        responses = iter(
            [
                {"access_token": "new-access", "expires_in": 3600},
                {"groups": []},
            ]
        )
        request_bodies = []

        def fake_urlopen(req, *_args, **_kwargs):
            request_bodies.append(req.data or b"")
            return FakeResponse(next(responses))

        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "http": {"urlopen": fake_urlopen},
                }
            )
            original_pass = self.module._security_find_generic_password
            original_client_id = self.module.AGY_CLIENT_ID
            self.module._security_find_generic_password = (
                lambda service, account: "go-keyring-base64:" + encoded
            )
            self.module.AGY_CLIENT_ID = "mock-client-id"
            try:
                services = self.module.service_antigravity()
            finally:
                self.module._security_find_generic_password = original_pass
                self.module.AGY_CLIENT_ID = original_client_id
            token_path = (
                Path(temp_home)
                / ".gemini"
                / "antigravity-cli"
                / "antigravity-oauth-token"
            )

        self.assertEqual(services[0]["status"], "empty")
        self.assertFalse(
            token_path.exists(), "Keychain 来源不得创建或写回令牌文件"
        )
        self.assertIn(
            "client_id=mock-client-id",
            request_bodies[0].decode("utf-8"),
            "刷新请求必须携带运行时注入的 client_id",
        )

    def test_service_antigravity_merges_model_groups_by_window(self):
        class FakeResponse:
            def __init__(self, payload):
                self.payload = payload

            def __enter__(self):
                return self

            def __exit__(self, *_args):
                return False

            def read(self):
                return json.dumps(self.payload).encode("utf-8")

        quota = {
            "groups": [
                {
                    "displayName": "Gemini",
                    "buckets": [
                        {"window": "5h", "remainingFraction": 0.4, "resetTime": None},
                        {"window": "weekly", "remainingFraction": 0.9, "resetTime": None},
                    ],
                },
                {
                    "displayName": "Claude/GPT",
                    "buckets": [
                        {"window": "5h", "remainingFraction": 0.7, "resetTime": None},
                        {"window": "weekly", "remainingFraction": 0.2, "resetTime": None},
                    ],
                },
            ]
        }
        responses = iter([{"access_token": "a", "expires_in": 3600}, quota])
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "antigravity_oauth": {
                            "token": {"access_token": "x", "refresh_token": "r"}
                        }
                    },
                    "http": {
                        "urlopen": lambda *_a, **_k: FakeResponse(next(responses))
                    },
                }
            )
            services = self.module.service_antigravity()

        svc = services[0]
        self.assertEqual(svc["status"], "ok")
        labels = [w["label"] for w in svc["windows"]]
        self.assertEqual(labels, ["5小时窗口", "每周窗口"])
        used = {w["label"]: w["usedPercent"] for w in svc["windows"]}
        # 跨模型取用量最高的池: 5h -> Gemini 60%, weekly -> Claude/GPT 80%
        self.assertAlmostEqual(used["5小时窗口"], 60.0)
        self.assertAlmostEqual(used["每周窗口"], 80.0)
        minutes = {w["label"]: w["windowMinutes"] for w in svc["windows"]}
        self.assertEqual(minutes["5小时窗口"], 300)
        self.assertIsNone(minutes["每周窗口"])

    def test_run_app_returns_updates_separate_from_artifact(self):
        original_collect = self.module.collect

        def fake_collect(ctx):
            self.module._configure_runtime(ctx)
            self.module._record_credential_update(
                "fixture",
                "account-1",
                {"access_token": "fixture-secret"},
            )
            return {"generatedAt": "2026-07-28T12:00:00+08:00"}

        self.module.collect = fake_collect
        try:
            result = self.module.run_app({})
        finally:
            self.module.collect = original_collect

        self.assertNotIn("credentialUpdates", result["artifact"])
        self.assertEqual(
            result["credentialUpdates"][0]["provider"],
            "fixture",
        )

    # ---- 任务 1 冻结契约: App 路径不刷新 Codex token, 不读第三方认证文件 ----

    def test_app_mode_quota_uses_injected_access_token_without_refresh(self):
        """App 模式注入有效 access token 时直接查额度, _codex_refresh 调用数为 0."""
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth_path = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cli_auth_path = Path(temp_home) / ".codex" / "auth.json"
            cc_auth_path.parent.mkdir(parents=True)
            cli_auth_path.parent.mkdir(parents=True)
            cc_auth_path.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "acc-1": {
                                "email": "fixture@example.test",
                                "refresh_token": "rotatable-rt",
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            cli_auth_path.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "account_id": "acc-1",
                            "refresh_token": "rotatable-cli-rt",
                        }
                    }
                ),
                encoding="utf-8",
            )
            before = {
                str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (cc_auth_path, cli_auth_path)
            }
            refresh_attempts = []
            original_refresh = self.module._codex_refresh
            self.module._codex_refresh = lambda token: refresh_attempts.append(
                token
            ) or {"access_token": "rotated"}
            usage_hits = []
            original_get = self.module.http_get_json
            self.module.http_get_json = (
                lambda url, headers: usage_hits.append(url)
                or {"plan_type": "fixture", "rate_limit": {}}
            )
            try:
                self.module._configure_runtime(
                    {
                        "home": temp_home,
                        "app_mode": True,
                        "now": "2026-07-28T12:00:00+08:00",
                        "credentials": {
                            "codex_quota_accounts": {
                                "acc-1": {
                                    "display_name": "Codex · user",
                                    "access_token": "short-lived-at",
                                }
                            },
                        },
                        "http": {"get_json": self.module.http_get_json},
                    }
                )
                services = self.module.service_codex_accounts()
            finally:
                self.module._codex_refresh = original_refresh
                self.module.http_get_json = original_get
            after = {
                str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (cc_auth_path, cli_auth_path)
            }

        self.assertEqual(refresh_attempts, [])
        self.assertEqual(len(usage_hits), 1)
        self.assertEqual(services[0]["id"], "codex_acc-1")
        self.assertEqual(before, after)

    def test_app_mode_without_codex_quota_accounts_returns_empty(self):
        """App 模式未注入 codex_quota_accounts 时不得读取任何磁盘认证文件."""
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth_path = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cli_auth_path = Path(temp_home) / ".codex" / "auth.json"
            cc_auth_path.parent.mkdir(parents=True)
            cli_auth_path.parent.mkdir(parents=True)
            cc_auth_path.write_text(
                json.dumps({"accounts": {"acc-1": {"refresh_token": "rt"}}}),
                encoding="utf-8",
            )
            cli_auth_path.write_text(
                json.dumps({"tokens": {"refresh_token": "cli-rt"}}),
                encoding="utf-8",
            )
            refresh_attempts = []
            original_refresh = self.module._codex_refresh
            self.module._codex_refresh = lambda token: refresh_attempts.append(
                token
            ) or {"access_token": "rotated"}
            try:
                self.module._configure_runtime(
                    {
                        "home": temp_home,
                        "app_mode": True,
                        "now": "2026-07-28T12:00:00+08:00",
                    }
                )
                services = self.module.service_codex_accounts()
            finally:
                self.module._codex_refresh = original_refresh

        self.assertEqual(services, [])
        self.assertEqual(refresh_attempts, [])

    def test_run_app_never_emits_codex_credential_updates(self):
        """App 模式 run_app 不返回 Codex rotation update."""
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "codex_quota_accounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "short-lived-at",
                            }
                        },
                    },
                    "http": {
                        "get_json": lambda *_: {"plan_type": "fixture", "rate_limit": {}}
                    },
                }
            )
            result = self.module.run_app({})
            updates = result.get("credentialUpdates") or []
            self.assertFalse(
                [u for u in updates if u.get("provider") == "codex"],
                "run_app 不得返回 Codex rotation update",
            )

    def test_app_mode_quota_first_401_generates_access_rejected_challenge(self):
        """quota 首次 401 只生成白名单 challenge, 不解析响应体进 note."""
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "codex_quota_accounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "short-lived-at",
                            }
                        },
                    },
                    "http": {
                        "get_json": lambda *_a, **_k: (_ for _ in ()).throw(
                            RuntimeError("HTTP 401")
                        )
                    },
                }
            )
            services = self.module.service_codex_accounts()
            challenges = self.module._RUNTIME_CREDENTIAL_CHALLENGES

        self.assertEqual(services[0]["status"], "error")
        self.assertEqual(
            challenges,
            [
                {
                    "provider": "codex",
                    "accountId": "acc-1",
                    "reason": "accessRejected",
                }
            ],
        )
        self.assertNotIn("HTTP 401", services[0]["note"])

    def test_app_mode_quota_403_does_not_generate_challenge(self):
        """quota 403 返回权限/套餐错误, 不生成 challenge, 不触发重新登录."""
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "codex_quota_accounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "short-lived-at",
                            }
                        },
                    },
                    "http": {
                        "get_json": lambda *_a, **_k: (_ for _ in ()).throw(
                            RuntimeError("HTTP 403")
                        )
                    },
                }
            )
            services = self.module.service_codex_accounts()
            challenges = self.module._RUNTIME_CREDENTIAL_CHALLENGES

        self.assertEqual(services[0]["status"], "error")
        self.assertEqual(challenges, [])

    def test_app_mode_quota_transient_failure_does_not_generate_challenge(self):
        """quota 429/5xx/断网/超时返回暂时失败, 不生成 challenge, 不在同轮重试."""
        for message in ("HTTP 429", "HTTP 503", "timed out"):
            with self.subTest(message=message):
                self.module._configure_runtime(
                    {
                        "home": tempfile.mkdtemp(),
                        "app_mode": True,
                        "now": "2026-07-28T12:00:00+08:00",
                        "credentials": {
                            "codex_quota_accounts": {
                                "acc-1": {
                                    "display_name": "Codex · user",
                                    "access_token": "short-lived-at",
                                }
                            },
                        },
                        "http": {
                            "get_json": lambda *_a, **_k: (_ for _ in ()).throw(
                                RuntimeError(message)
                            )
                        },
                    }
                )
                services = self.module.service_codex_accounts()
                self.assertEqual(services[0]["status"], "error")
                self.assertEqual(
                    self.module._RUNTIME_CREDENTIAL_CHALLENGES,
                    [],
                )

    def test_codex_quota_retry_only_mode_skips_local_scan_and_other_services(self):
        """codex_quota_retry_only=true 时不扫描本地会话, 不调用其他 provider."""
        with tempfile.TemporaryDirectory() as temp_home:
            scan_calls = []
            original_scan = self.module.scan_codex
            self.module.scan_codex = lambda *a, **k: scan_calls.append(1) or (
                False, None
            )
            original_services = self.module._collect_app_services
            self.module._collect_app_services = (
                lambda: scan_calls.append(2) or []
            )
            original_antigravity = self.module.service_antigravity
            self.module.service_antigravity = (
                lambda: scan_calls.append(3) or []
            )
            try:
                artifact = self.module.run_app(
                    {
                        "home": temp_home,
                        "app_mode": True,
                        "now": "2026-07-28T12:00:00+08:00",
                        "codex_quota_retry_only": True,
                        "credentials": {
                            "codex_quota_accounts": {
                                "acc-1": {
                                    "display_name": "Codex · user",
                                    "access_token": "short-lived-at",
                                }
                            },
                        },
                        "http": {
                            "get_json": lambda *_: {
                                "plan_type": "fixture",
                                "rate_limit": {},
                            }
                        },
                    }
                )["artifact"]
            finally:
                self.module.scan_codex = original_scan
                self.module._collect_app_services = original_services
                self.module.service_antigravity = original_antigravity

        self.assertEqual(scan_calls, [])
        service_ids = [s["id"] for s in artifact["services"]]
        self.assertEqual(service_ids, ["codex_acc-1"])
        self.assertEqual(artifact["agents"], [])
        self.assertIsNone(artifact["totalCostUsd"])

    def test_cc_switch_schema_error_is_not_reported_as_empty(self):
        with tempfile.TemporaryDirectory() as temp_home:
            db_path = Path(temp_home) / ".cc-switch" / "cc-switch.db"
            db_path.parent.mkdir(parents=True)
            with sqlite3.connect(db_path):
                pass
            before = hashlib.sha256(db_path.read_bytes()).hexdigest()

            artifact = self.module.run(
                {
                    "home": temp_home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                }
            )["artifact"]
            after = hashlib.sha256(db_path.read_bytes()).hexdigest()

        status = next(
            service
            for service in artifact["services"]
            if service["id"] == "cc_switch_schema"
        )
        self.assertEqual(status["status"], "error")
        self.assertEqual(before, after)


    def test_concurrent_account_refreshes_do_not_lose_credential_updates(self):
        """跨账号并行 refresh 时 _RUNTIME_CREDENTIAL_UPDATES 不丢条目 (C1)."""
        accounts = {
            "acc-one-0001": {"email": "one@example.test", "refresh_token": "rt-one"},
            "acc-two-0002": {"email": "two@example.test", "refresh_token": "rt-two"},
            "acc-three-03": {"email": "three@example.test", "refresh_token": "rt-three"},
        }
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "credentials": {
                        "codex_oauth_auth": {"accounts": accounts},
                        "codex_auth": {
                            "tokens": {
                                "account_id": "acc-one-0001",
                                "refresh_token": "rt-one-cli",
                            }
                        },
                    },
                    "http": {
                        "get_json": lambda *_: {
                            "plan_type": "fixture",
                            "rate_limit": {},
                        }
                    },
                }
            )
            original_refresh = self.module._codex_refresh
            self.module._codex_refresh = lambda token: {
                "access_token": "access-" + token,
                "refresh_token": "rotated-" + token,
            }
            try:
                services = self.module.service_codex_accounts()
            finally:
                self.module._codex_refresh = original_refresh

        # pool.map 保持账号顺序
        self.assertEqual(
            [svc["id"] for svc in services],
            ["codex_" + acc_id[:8] for acc_id in accounts],
        )
        updates = self.module._RUNTIME_CREDENTIAL_UPDATES
        self.assertEqual(len(updates), 3)
        self.assertEqual(
            {u["accountId"] for u in updates}, set(accounts)
        )
        for update in updates:
            self.assertEqual(update["provider"], "codex")
            self.assertEqual(update["operation"], "replace")


class AgentCollectorCapabilityTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_capability_test",
            "agent-usage/collector/collect_usage.py",
        )

    def _make_cc_switch_db(self, temp_home):
        db_path = Path(temp_home) / ".cc-switch" / "cc-switch.db"
        db_path.parent.mkdir(parents=True)
        with sqlite3.connect(db_path) as db:
            db.execute(
                "CREATE TABLE providers (id TEXT, name TEXT, app_type TEXT,"
                " settings_config TEXT, meta TEXT, is_current INTEGER)"
            )
            db.execute(
                "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?)",
                ("p1", "Kimi For Coding", "kimi", '{"env": {}}', "{}", 1),
            )
        return db_path

    def _deny_all_http(self, calls):
        def counting(name):
            def call(*_args, **_kwargs):
                calls.append(name)
                raise AssertionError("unexpected external HTTP: %s" % name)

            return call

        return {
            "get_json": counting("get_json"),
            "post_json": counting("post_json"),
            "urlopen": counting("urlopen"),
        }

    def _assert_artifact_shape(self, artifact):
        # 对齐 bridge/schemas/artifacts/agent-usage-v1.schema.json 的必需结构
        self.assertIsInstance(artifact["generatedAt"], str)
        self.assertIsInstance(artifact["agents"], list)
        self.assertIsInstance(artifact["services"], list)
        self.assertTrue(
            artifact["totalCostUsd"] is None
            or artifact["totalCostUsd"] >= 0
        )
        for agent in artifact["agents"]:
            for key in ("id", "name", "status", "today", "daily", "hours"):
                self.assertIn(key, agent)
            for key in ("input", "output", "cacheRead", "cacheCreation", "total"):
                self.assertIn(key, agent["today"])
            self.assertEqual(len(agent["hours"]), 24)
            self.assertTrue(
                agent["todayCostUsd"] is None or agent["todayCostUsd"] >= 0
            )
        for service in artifact["services"]:
            for key in ("id", "name", "status", "windows"):
                self.assertIn(key, service)
            self.assertIsInstance(service["windows"], list)

    def test_missing_external_quotas_skips_network_and_returns_warnings(self):
        http_calls = []
        with tempfile.TemporaryDirectory() as temp_home:
            self._make_cc_switch_db(temp_home)
            artifact = self.module.run(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "capabilities": ["localSessions", "localPricing"],
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "credentials": {
                        "kimi_web_tokens": {
                            "access_token": "fixture-access",
                            "refresh_token": "fixture-refresh",
                        },
                        "antigravity_oauth": {
                            "token": {
                                "access_token": "fixture-access",
                                "refresh_token": "fixture-refresh",
                            }
                        },
                        "codex_oauth_auth": {
                            "accounts": {
                                "account-1": {
                                    "email": "fixture@example.test",
                                    "refresh_token": "fixture-refresh",
                                }
                            }
                        },
                        "codex_auth": {
                            "tokens": {
                                "account_id": "account-1",
                                "refresh_token": "fixture-refresh",
                            }
                        },
                    },
                    "http": self._deny_all_http(http_calls),
                }
            )["artifact"]

        self.assertEqual(http_calls, [])
        self.assertEqual(
            {service["id"] for service in artifact["services"]},
            {"cc_switch_providers", "antigravity", "codex_accounts"},
        )
        for service in artifact["services"]:
            self.assertEqual(service["status"], "partial")
            self.assertIn("externalQuotas", service["note"])
        self._assert_artifact_shape(artifact)

    def test_missing_local_sessions_marks_agents_unavailable(self):
        http_calls = []
        with tempfile.TemporaryDirectory() as temp_home:
            self._make_cc_switch_db(temp_home)
            artifact = self.module.run(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "capabilities": [],
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "http": self._deny_all_http(http_calls),
                }
            )["artifact"]

        self.assertEqual(http_calls, [])
        self.assertTrue(artifact["agents"])
        for agent in artifact["agents"]:
            self.assertEqual(agent["status"], "unavailable")
            self.assertIn("localSessions", agent["note"])
            self.assertIsNone(agent["todayCostUsd"])
        self.assertIsNone(artifact["totalCostUsd"])
        for service in artifact["services"]:
            self.assertEqual(service["status"], "partial")
        self._assert_artifact_shape(artifact)

    def test_without_capabilities_key_cli_behavior_is_unchanged(self):
        def post_json(url, payload, headers):
            if url == self.module.KIMI_STATS_URL:
                return {"ratelimitCode5h": {"ratio": 0.25}}
            if url == self.module.KIMI_SUB_URL:
                return {"plan": "Moderato"}
            self.fail("unexpected URL: %s" % url)

        with tempfile.TemporaryDirectory() as temp_home:
            self._make_cc_switch_db(temp_home)
            artifact = self.module.run(
                {
                    "home": temp_home,
                    "app_mode": True,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "credentials": {
                        "kimi_web_tokens": {
                            "access_token": "fixture-access",
                            "refresh_token": "fixture-refresh",
                        }
                    },
                    "http": {"post_json": post_json},
                }
            )["artifact"]

        kimi = next(
            service
            for service in artifact["services"]
            if service["id"] == "kimi_coding"
        )
        self.assertEqual(kimi["status"], "ok")
        self.assertTrue(kimi["windows"])


class AgentCollectorAppServicesTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_app_services_test",
            "agent-usage/collector/collect_usage.py",
        )

    def _kimi_post_json(self, url, payload, headers):
        self.assertIn("Authorization", headers)
        if url == self.module.KIMI_STATS_URL:
            return {
                "ratelimitCode5h": {"ratio": 0.25},
                "ratelimitCode7d": {"ratio": 0.5},
            }
        if url == self.module.KIMI_SUB_URL:
            return {"plan": "Moderato"}
        self.fail("unexpected POST URL: %s" % url)

    def _quota_get_json(self, url, headers):
        if "deepseek" in url:
            return {
                "balance_infos": [
                    {"total_balance": "12.34", "currency": "CNY"}
                ]
            }
        if "volcengineapi" in url:
            self.assertIn("Authorization", headers)
            return {
                "Result": {
                    "Status": "active",
                    "QuotaUsage": [
                        {"Level": "session", "Percent": 40},
                        {"Level": "weekly", "Percent": 10},
                    ],
                }
            }
        self.fail("unexpected GET URL: %s" % url)

    def _configure_app(self, temp_home, credentials, http):
        self.module._configure_runtime(
            {
                "home": temp_home,
                "app_mode": True,
                "capabilities": [
                    "localSessions",
                    "localPricing",
                    "externalQuotas",
                ],
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "credentials": credentials,
                "http": http,
            }
        )

    def _full_credentials(self):
        return {
            "kimi_web_tokens": {
                "access_token": "fixture-access",
                "refresh_token": "fixture-refresh",
            },
            "provider_env": {
                "deepseek": {"ANTHROPIC_AUTH_TOKEN": "fixture-deepseek-key"}
            },
            "provider_meta": {
                "volcengine": {
                    "usage_script": {
                        "accessKeyId": "fixture-ak",
                        "secretAccessKey": "fixture-sk",
                    }
                }
            },
        }

    def _assert_service_shape(self, svc):
        for key in (
            "id",
            "name",
            "app",
            "isCurrent",
            "status",
            "kind",
            "plan",
            "windows",
            "balance",
            "currency",
            "capturedAt",
            "note",
        ):
            self.assertIn(key, svc)
        self.assertFalse(svc["isCurrent"])
        self.assertIsInstance(svc["windows"], list)

    def test_app_mode_synthesizes_three_services_without_cc_db(self):
        with tempfile.TemporaryDirectory() as temp_home:
            # 不创建 ~/.cc-switch/cc-switch.db, 证明 App 模式不依赖 CC
            self._configure_app(
                temp_home,
                self._full_credentials(),
                {
                    "post_json": self._kimi_post_json,
                    "get_json": self._quota_get_json,
                },
            )
            self.assertFalse(os.path.exists(self.module.CC_SWITCH_DB))
            services = self.module.collect_services()

        self.assertEqual(
            [svc["id"] for svc in services],
            ["kimi_coding", "deepseek", "volcengine"],
        )
        for svc in services:
            self._assert_service_shape(svc)
            self.assertEqual(svc["status"], "ok")

        kimi, deepseek, volc = services
        self.assertEqual(kimi["name"], "Kimi")
        self.assertEqual(kimi["kind"], "windows")
        self.assertEqual(kimi["plan"], "Moderato")
        self.assertEqual(len(kimi["windows"]), 2)

        self.assertEqual(deepseek["name"], "DeepSeek")
        self.assertEqual(deepseek["kind"], "balance")
        self.assertAlmostEqual(deepseek["balance"], 12.34)
        self.assertEqual(deepseek["currency"], "CNY")

        self.assertEqual(volc["name"], "火山引擎（Coding Plan）")
        self.assertEqual(volc["kind"], "windows")
        # 订阅生命周期 Status (active/running) 不作为套餐展示
        self.assertIsNone(volc["plan"])
        self.assertEqual(
            [w["label"] for w in volc["windows"]], ["5小时窗口", "每周窗口"]
        )

    def test_app_mode_partial_injection_yields_only_matching_services(self):
        with tempfile.TemporaryDirectory() as temp_home:
            self._configure_app(
                temp_home,
                {
                    "provider_env": {
                        "deepseek": {
                            "ANTHROPIC_AUTH_TOKEN": "fixture-deepseek-key"
                        }
                    }
                },
                {"get_json": self._quota_get_json},
            )
            services = self.module.collect_services()

        self.assertEqual([svc["id"] for svc in services], ["deepseek"])
        self._assert_service_shape(services[0])
        self.assertEqual(services[0]["status"], "ok")

    def test_app_mode_without_injection_returns_empty_services(self):
        calls = []

        def deny(name):
            def call(*_args, **_kwargs):
                calls.append(name)
                raise AssertionError("unexpected external HTTP: %s" % name)

            return call

        with tempfile.TemporaryDirectory() as temp_home:
            self._configure_app(
                temp_home,
                {},
                {
                    "get_json": deny("get_json"),
                    "post_json": deny("post_json"),
                    "urlopen": deny("urlopen"),
                },
            )
            services = self.module.collect_services()

        self.assertEqual(services, [])
        self.assertEqual(calls, [])

    def test_app_mode_network_failure_marks_error_with_diagnostic_note(self):
        def failing_get_json(_url, _headers):
            raise OSError("fixture network down")

        with tempfile.TemporaryDirectory() as temp_home:
            self._configure_app(
                temp_home,
                {
                    "provider_env": {
                        "deepseek": {
                            "ANTHROPIC_AUTH_TOKEN": "fixture-deepseek-key"
                        }
                    },
                    "provider_meta": {
                        "volcengine": {
                            "usage_script": {
                                "accessKeyId": "fixture-ak",
                                "secretAccessKey": "fixture-sk",
                            }
                        }
                    },
                },
                {"get_json": failing_get_json},
            )
            services = self.module.collect_services()

        self.assertEqual(
            [svc["id"] for svc in services], ["deepseek", "volcengine"]
        )
        for svc in services:
            self._assert_service_shape(svc)
            self.assertEqual(svc["status"], "error")
            self.assertIn("查询失败: ", svc["note"])
            self.assertIn("fixture network down", svc["note"])

    def test_cli_mode_cc_db_driven_behavior_unchanged(self):
        post_json = self._kimi_post_json
        get_json = self._quota_get_json

        with tempfile.TemporaryDirectory() as temp_home:
            db_path = Path(temp_home) / ".cc-switch" / "cc-switch.db"
            db_path.parent.mkdir(parents=True)
            with sqlite3.connect(db_path) as db:
                db.execute(
                    "CREATE TABLE providers (id TEXT, name TEXT, app_type TEXT,"
                    " settings_config TEXT, meta TEXT, is_current INTEGER)"
                )
                db.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?)",
                    ("p1", "Kimi For Coding", "claude", '{"env": {}}', "{}", 1),
                )
                db.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        "p2",
                        "DeepSeek",
                        "claude",
                        '{"env": {"ANTHROPIC_AUTH_TOKEN": "cc-deepseek-key"}}',
                        "{}",
                        0,
                    ),
                )
                db.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        "p3",
                        "火山Codingplan",
                        "claude",
                        '{"env": {}}',
                        '{"usage_script": {"accessKeyId": "cc-ak",'
                        ' "secretAccessKey": "cc-sk"}}',
                        0,
                    ),
                )
                db.execute(
                    "INSERT INTO providers VALUES (?, ?, ?, ?, ?, ?)",
                    ("p4", "无关 Provider", "claude", '{"env": {}}', "{}", 0),
                )
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "credentials": {
                        "kimi_web_tokens": {
                            "access_token": "fixture-access",
                            "refresh_token": "fixture-refresh",
                        }
                    },
                    "http": {"post_json": post_json, "get_json": get_json},
                }
            )
            services = self.module.collect_services()

        self.assertEqual(
            [svc["id"] for svc in services],
            ["kimi_coding", "deepseek", "volcengine"],
        )
        kimi, deepseek, volc = services
        # app/isCurrent 来自 CC 行, 名称走 display_names 映射
        self.assertEqual(kimi["name"], "Kimi")
        self.assertEqual(kimi["app"], "claude")
        self.assertTrue(kimi["isCurrent"])
        self.assertEqual(kimi["status"], "ok")
        self.assertEqual(deepseek["name"], "DeepSeek")
        self.assertFalse(deepseek["isCurrent"])
        self.assertEqual(deepseek["status"], "ok")
        self.assertAlmostEqual(deepseek["balance"], 12.34)
        self.assertEqual(volc["name"], "火山引擎（Coding Plan）")
        self.assertEqual(volc["status"], "ok")
        self.assertEqual(
            [w["label"] for w in volc["windows"]], ["5小时窗口", "每周窗口"]
        )

    def test_cli_mode_without_cc_db_returns_empty_services(self):
        with tempfile.TemporaryDirectory() as temp_home:
            self.module._configure_runtime(
                {
                    "home": temp_home,
                    "now": "2026-07-28T12:00:00+08:00",
                    "timezone": "Asia/Shanghai",
                    "credentials": self._full_credentials(),
                    "http": {},
                }
            )
            self.assertFalse(os.path.exists(self.module.CC_SWITCH_DB))
            services = self.module.collect_services()

        self.assertEqual(services, [])


class VolcengineResetTimestampTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_volc_reset_test",
            "agent-usage/collector/collect_usage.py",
        )

    def test_unstarted_window_reset_timestamp_minus_one_becomes_none(self):
        # 真实响应证据: 火山 GetCodingPlanUsage 对未开始的 5 小时窗口返回
        # ResetTimestamp=-1, 透传会被面板解析成 1970 误判「已到期」
        result = self.module._volc_parse(
            {
                "Status": "active",
                "QuotaUsage": [
                    {
                        "Level": "session",
                        "Percent": 0,
                        "ResetTimestamp": -1,
                    },
                    {
                        "Level": "weekly",
                        "Percent": 10,
                        "ResetTimestamp": 1785000000,
                    },
                ],
            }
        )

        windows = result["windows"]
        self.assertEqual(
            [w["label"] for w in windows], ["5小时窗口", "每周窗口"]
        )
        self.assertIsNone(windows[0]["resetsAt"])
        self.assertEqual(windows[1]["resetsAt"], 1785000000)

    def test_missing_reset_timestamp_becomes_none(self):
        result = self.module._volc_parse(
            {
                "QuotaUsage": [
                    {"Level": "session", "Percent": 5},
                ],
            }
        )

        self.assertIsNone(result["windows"][0]["resetsAt"])


class BridgeSubprocessCodexQuotaIntegrationTests(unittest.TestCase):
    """任务 11 端到端隔离: 真实子进程 (python3 -> run_bridge.py ->
    collect_usage.py) + 本地 fake HTTP server (loopback), 不触碰任何
    真实文件或网络.

    fake server 路径经 Bridge 白名单 (context 键由 security.py 映射) 到达
    collector; 旧认证文件只作为磁盘存在的 fixture 验证「不被触碰」.
    """

    def _fake_server(self, usage_status=200):
        """loopback fake server: /wham/usage 返回配额, /oauth/token 计数
        (本地测试预期不被调用)."""
        import http.server
        import threading

        calls = {"usage": 0, "token": 0}
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                calls["usage"] += 1
                if usage_status == 401:
                    self.send_response(401)
                    self.send_header("Content-Type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"error": "unauthorized"}')
                    return
                body = json.dumps(
                    {
                        "plan_type": "fixture-plan",
                        "rate_limit": {
                            "primary_window": {
                                "limit_window_seconds": 18000,
                                "used_percent": 42,
                                "reset_at": "2026-07-28T17:00:00+08:00",
                            }
                        },
                    }
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                calls["token"] += 1
                body = json.dumps(
                    {"access_token": "rotated", "refresh_token": "rotated-rt"}
                ).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(body)

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        return server, calls, "http://127.0.0.1:%d" % port

    def _run_bridge(
        self,
        temp_home,
        credentials,
        usage_url,
        token_url=None,
        context_extra=None,
    ):
        import subprocess

        context = {
            "home": temp_home,
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "capabilities": ["localSessions", "localPricing", "externalQuotas"],
            "codexUsageUrl": usage_url,
        }
        if token_url:
            context["codexTokenUrl"] = token_url
        context.update(context_extra or {})
        request = {
            "schemaVersion": 1,
            "runId": "12345678-1234-4234-9234-123456789abc",
            "module": "agent-usage",
            "timeouts": {
                "localScanSeconds": 30,
                "externalRequestSeconds": 10,
                "moduleSeconds": 90,
            },
            "context": context,
            "credentials": credentials,
        }
        result = subprocess.run(
            [
                sys.executable,
                str(REPO_ROOT / "bridge" / "run_bridge.py"),
            ],
            input=json.dumps(request),
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(
            result.returncode, 0, "bridge subprocess failed: %s" % result.stderr
        )
        return json.loads(result.stdout)

    def _file_snapshot(self, paths):
        snapshot = {}
        for path in paths:
            stat = os.stat(path)
            snapshot[str(path)] = (
                hashlib.sha256(path.read_bytes()).hexdigest(),
                stat.st_size,
                stat.st_mtime_ns,
            )
        return snapshot

    def test_quota_only_path_hits_fake_server_and_never_touches_auth_files(self):
        """App quota 全流程: 真实子进程 + loopback fake server, 磁盘上的
        fake CC Switch / Codex CLI 文件哈希与元数据不变, token endpoint
        不被调用."""
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cli_auth = Path(temp_home) / ".codex" / "auth.json"
            cc_auth.parent.mkdir(parents=True)
            cli_auth.parent.mkdir(parents=True)
            cc_auth.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "acc-1": {
                                "email": "fixture@example.test",
                                "refresh_token": "cc-rotatable-rt",
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )
            cli_auth.write_text(
                json.dumps(
                    {
                        "tokens": {
                            "account_id": "acc-1",
                            "refresh_token": "cli-rotatable-rt",
                        }
                    }
                ),
                encoding="utf-8",
            )
            before = self._file_snapshot([cc_auth, cli_auth])
            server, calls, base = self._fake_server()
            try:
                response = self._run_bridge(
                    temp_home,
                    {
                        "codexQuotaAccounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "fixture-short-lived-token",
                            }
                        },
                    },
                    base + "/wham/usage",
                    token_url=base + "/oauth/token",
                )
                after = self._file_snapshot([cc_auth, cli_auth])
            finally:
                server.shutdown()
        self.assertEqual(response["status"], "success")
        codex = [
            s for s in response["artifact"]["services"] if s.get("app") == "codex"
        ]
        self.assertEqual(len(codex), 1)
        self.assertEqual(codex[0]["status"], "ok")
        self.assertEqual(codex[0]["plan"], "fixture-plan")
        self.assertEqual(calls["usage"], 1)
        self.assertEqual(calls["token"], 0)
        serialized = json.dumps(response)
        self.assertNotIn("cc-rotatable-rt", serialized)
        self.assertNotIn("cli-rotatable-rt", serialized)
        self.assertNotIn("fixture-short-lived-token", serialized)
        # 全流程前后 hash/size/mtime 不变 (快照值在 temp 目录内采集)
        self.assertEqual(after, before)

    def test_quota_401_via_fake_server_returns_only_whitelisted_challenge(self):
        """真实子进程 + 401 fake server: 响应只有白名单 challenge,
        不含 token 或旧认证文件内容."""
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cc_auth.parent.mkdir(parents=True)
            cc_auth.write_text(
                json.dumps(
                    {"accounts": {"acc-1": {"refresh_token": "cc-rotatable-rt"}}}
                ),
                encoding="utf-8",
            )
            server, calls, base = self._fake_server(usage_status=401)
            try:
                response = self._run_bridge(
                    temp_home,
                    {
                        "codexQuotaAccounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "fixture-short-lived-token",
                            }
                        },
                    },
                    base + "/wham/usage",
                    token_url=base + "/oauth/token",
                )
            finally:
                server.shutdown()

        self.assertEqual(response["status"], "partial")
        self.assertEqual(
            response["credentialChallenges"],
            [
                {
                    "provider": "codex",
                    "accountId": "acc-1",
                    "reason": "accessRejected",
                }
            ],
        )
        self.assertEqual(calls["token"], 0)
        serialized = json.dumps(response)
        self.assertNotIn("cc-rotatable-rt", serialized)
        self.assertNotIn("fixture-short-lived-token", serialized)


if __name__ == "__main__":
    unittest.main()
