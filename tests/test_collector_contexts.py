import hashlib
import importlib.util
import json
import sqlite3
import ssl
import tempfile
import unittest
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


class GitHubCollectorContextTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_github_context_test",
            "github/collector/collect_github.py",
        )

    def test_graphql_clock_and_timezone_are_injectable(self):
        payload = {
            "data": {
                "viewer": {
                    "login": "fixture-user",
                    "contributionsCollection": {
                        "contributionCalendar": {
                            "totalContributions": 3,
                            "weeks": [
                                {
                                    "contributionDays": [
                                        {
                                            "date": "2026-07-28",
                                            "contributionCount": 3,
                                            "contributionLevel": "SECOND_QUARTILE",
                                            "weekday": 2,
                                        }
                                    ]
                                }
                            ],
                        }
                    },
                }
            }
        }
        result = self.module.run(
            {
                "graphql": lambda query: payload,
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
            }
        )["artifact"]
        self.assertEqual(result["generatedAt"], "2026-07-28T12:00:00+08:00")
        self.assertEqual(result["login"], "fixture-user")
        self.assertEqual(result["today"], 3)


class GitLabCollectorContextTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_gitlab_context_test",
            "gitlab/collector/collect_gitlab.py",
        )

    def test_http_token_base_url_and_clock_are_injectable(self):
        paths = []

        def http_get_json(path, token):
            self.assertEqual(token, "fixture-token")
            paths.append(path)
            if path == "/api/v4/user":
                return {"id": 7, "username": "fixture-user", "name": "Fixture"}
            return [
                {"created_at": "2026-07-28T08:00:00Z"},
                {"created_at": "2026-07-27T08:00:00Z"},
            ]

        result = self.module.run(
            {
                "base_url": "https://gitlab.example.test",
                "credentials": {"gitlab_token": "fixture-token"},
                "http_get_json": http_get_json,
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
            }
        )["artifact"]

        self.assertEqual(result["generatedAt"], "2026-07-28T12:00:00+08:00")
        self.assertEqual(result["login"], "fixture-user")
        self.assertEqual(result["today"], 1)
        self.assertEqual(paths[0], "/api/v4/user")
        self.assertIn("/api/v4/users/7/events", paths[1])

    def test_default_tls_context_verifies_certificate_and_hostname(self):
        context = self.module._ssl_context({})
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_app_mode_without_token_raises_auth_error_before_legacy_file(self):
        with tempfile.TemporaryDirectory() as temp_home:
            token_file = (
                Path(temp_home)
                / ".config"
                / "kimi-dashboard"
                / "gitlab-gzky-token"
            )
            token_file.parent.mkdir(parents=True)
            token_file.write_text("legacy-token\n", encoding="utf-8")
            with self.assertRaises(PermissionError) as caught:
                self.module._resolve_token(
                    {"home": temp_home, "app_mode": True}
                )
        # 只有新增分支会报这条信息, 证明未触碰旧 token 文件
        self.assertEqual(str(caught.exception), "App 模式缺少 gitlab_token 凭证")

    def test_cli_mode_keeps_legacy_token_file_fallback(self):
        with tempfile.TemporaryDirectory() as temp_home:
            token_file = (
                Path(temp_home)
                / ".config"
                / "kimi-dashboard"
                / "gitlab-gzky-token"
            )
            token_file.parent.mkdir(parents=True)
            token_file.write_text("legacy-token\n", encoding="utf-8")
            token = self.module._resolve_token({"home": temp_home})
        self.assertEqual(token, "legacy-token")


if __name__ == "__main__":
    unittest.main()
