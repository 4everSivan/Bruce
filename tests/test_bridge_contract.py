import hashlib
import io
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path

from bridge.run_bridge import execute_request, main
from bridge.security import redact_text


REPO_ROOT = Path(__file__).resolve().parents[1]
RUN_ID = "12345678-1234-4234-9234-123456789abc"


def bridge_request(module, context=None, credentials=None):
    return {
        "schemaVersion": 1,
        "runId": RUN_ID,
        "module": module,
        "timeouts": {
            "localScanSeconds": 30,
            "externalRequestSeconds": 10,
            "moduleSeconds": 90,
        },
        "context": context or {},
        "credentials": credentials or {},
    }


def load_fixture(module, variant="valid"):
    return json.loads(
        (
            REPO_ROOT
            / "tests"
            / "fixtures"
            / "artifacts"
            / module
            / ("%s.json" % variant)
        ).read_text(encoding="utf-8")
    )["artifact"]


class BridgeSchemaTests(unittest.TestCase):
    def test_checked_in_schemas_define_required_v1_envelope_fields(self):
        request_schema = json.loads(
            (
                REPO_ROOT / "bridge" / "schemas" / "request-v1.schema.json"
            ).read_text(encoding="utf-8")
        )
        response_schema = json.loads(
            (
                REPO_ROOT / "bridge" / "schemas" / "response-v1.schema.json"
            ).read_text(encoding="utf-8")
        )
        self.assertEqual(request_schema["properties"]["schemaVersion"]["const"], 1)
        self.assertEqual(
            set(request_schema["required"]),
            {
                "schemaVersion",
                "runId",
                "module",
                "timeouts",
                "context",
                "credentials",
            },
        )
        self.assertEqual(
            set(response_schema["required"]),
            {
                "schemaVersion",
                "runId",
                "generatedAt",
                "status",
                "artifact",
                "credentialUpdates",
                "diagnostics",
            },
        )


class BridgeContractTests(unittest.TestCase):
    def test_success_response_uses_one_versioned_envelope(self):
        artifact = load_fixture("agent-usage")
        expected_artifact = dict(artifact)
        expected_artifact.update({"schemaVersion": 1, "module": "agent-usage"})
        request = bridge_request("agent-usage")
        response = execute_request(
            request,
            collector_overrides={
                "agent-usage": lambda _ctx: {"artifact": artifact}
            },
        )
        self.assertEqual(response["status"], "success")
        self.assertEqual(response["schemaVersion"], 1)
        self.assertEqual(response["runId"], RUN_ID)
        self.assertEqual(response["artifact"], expected_artifact)
        self.assertEqual(response["credentialUpdates"], [])
        self.assertEqual(response["diagnostics"], [])

        stdout = io.StringIO()
        exit_code = main(
            io.StringIO(json.dumps(request)),
            stdout,
            executor=lambda value: execute_request(
                value,
                collector_overrides={
                    "agent-usage": lambda _ctx: {"artifact": artifact}
                },
            ),
        )
        self.assertEqual(exit_code, 0)
        self.assertEqual(stdout.getvalue().count("\n"), 1)
        self.assertEqual(
            json.loads(stdout.getvalue())["artifact"],
            expected_artifact,
        )

    def test_partial_agent_result_is_explicit(self):
        artifact = load_fixture("agent-usage", "partial")
        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {"artifact": artifact}
            },
        )
        self.assertEqual(response["status"], "partial")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "COLLECTOR_PARTIAL_RESULT",
        )

    def test_missing_field_and_unknown_version_are_protocol_errors(self):
        missing = bridge_request("agent-usage")
        missing.pop("credentials")
        missing_response = execute_request(missing)
        self.assertEqual(missing_response["status"], "error")
        self.assertEqual(
            missing_response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_REQUEST",
        )

        unknown = bridge_request("agent-usage")
        unknown["schemaVersion"] = 2
        unknown_response = execute_request(unknown)
        self.assertEqual(unknown_response["status"], "error")
        self.assertEqual(
            unknown_response["diagnostics"][0]["code"],
            "BRIDGE_UNSUPPORTED_SCHEMA",
        )

    def test_collector_stdout_is_captured_and_rejected(self):
        def noisy_collector(_ctx):
            print("token=must-not-escape")
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={"agent-usage": noisy_collector},
        )
        serialized = json.dumps(response)
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "COLLECTOR_STDOUT_CONTAMINATION",
        )
        self.assertNotIn("must-not-escape", serialized)

    def test_collector_exception_is_generic_and_redacted(self):
        def failed_collector(_ctx):
            raise RuntimeError(
                "Bearer raw-secret /Users/example/private fixture@example.test"
            )

        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={"agent-usage": failed_collector},
        )
        serialized = json.dumps(response)
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "COLLECTOR_FAILED",
        )
        self.assertNotIn("raw-secret", serialized)
        self.assertNotIn("/Users/example", serialized)
        self.assertNotIn("fixture@example.test", serialized)

    def test_invalid_json_or_input_pollution_returns_one_error_envelope(self):
        stdout = io.StringIO()
        main(io.StringIO("debug-prefix\n{}"), stdout)
        response = json.loads(stdout.getvalue())
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_JSON",
        )
        self.assertEqual(stdout.getvalue().count("\n"), 1)

    def test_sensitive_artifact_and_invalid_update_are_rejected(self):
        sensitive = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": {"access_token": "must-not-publish"}
                }
            },
        )
        self.assertEqual(
            sensitive["diagnostics"][0]["code"],
            "ARTIFACT_SENSITIVE_FIELD",
        )
        self.assertNotIn("must-not-publish", json.dumps(sensitive))

        invalid_update = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": load_fixture("agent-usage"),
                    "credentialUpdates": [
                        {
                            "provider": "unknown",
                            "accountId": "default",
                            "kind": "oauthTokens",
                            "operation": "replace",
                            "credentials": {"access_token": "hidden"},
                        }
                    ],
                }
            },
        )
        self.assertEqual(
            invalid_update["diagnostics"][0]["code"],
            "BRIDGE_INVALID_CREDENTIAL_UPDATE",
        )
        self.assertNotIn("hidden", json.dumps(invalid_update))

    def test_credentials_are_scoped_to_the_selected_module(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={"unknownCredential": "must-not-be-routed"},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_CREDENTIAL_SCOPE",
        )
        self.assertNotIn("must-not-be-routed", json.dumps(response))

    def test_claude_and_grok_oauth_credentials_accepted(self):
        """Phase 5: claudeOAuth/grokOAuth 新注入键必须通过 Bridge 白名单校验."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={
                    "claudeOAuth": {"claudeAiOauth": {"accessToken": "ct"}},
                    "grokOAuth": {"https://auth.x.ai::injected": {"key": "gk"}},
                },
            )
        )
        # 校验通过后进入 collector 执行 (partial = 凭证被接受, 无真实额度数据);
        # 若是白名单拒绝会返回 BRIDGE_CREDENTIAL_SCOPE 错误.
        self.assertNotEqual(response["status"], "error")
        self.assertNotEqual(
            response["diagnostics"][0]["code"], "BRIDGE_CREDENTIAL_SCOPE"
        )

    def test_redaction_removes_common_diagnostic_secrets(self):
        redacted = redact_text(
            "Bearer abc.def token=my-token fixture@example.test "
            "/Users/example/private "
            "https://example.test/path?access_token=secret"
        )
        self.assertNotIn("abc.def", redacted)
        self.assertNotIn("my-token", redacted)
        self.assertNotIn("fixture@example.test", redacted)
        self.assertNotIn("/Users/example", redacted)
        self.assertNotIn("access_token=secret", redacted)


class BridgeCodexAccessOnlyContractTests(unittest.TestCase):
    """任务 1 冻结契约: App 请求只接受短期 access token 形态的 Codex 凭证.

    预期红灯 (生产代码尚未支持): App 请求必须接受 codexQuotaAccounts
    (access-only), 同时拒绝 codexOAuthAccounts / codexAuth 中的可旋转凭证.
    """

    def test_app_request_accepts_codex_quota_accounts_only(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["localSessions", "externalQuotas"],
                    "codexQuotaAccountOrder": ["acc-1"],
                },
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "fixture-short-lived-token",
                        }
                    },
                },
            ),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        routed = captured["credentials"]["codex_quota_accounts"]
        self.assertEqual(
            routed["acc-1"]["access_token"],
            "fixture-short-lived-token",
        )
        self.assertNotIn("refresh_token", json.dumps(routed))
        self.assertNotIn("id_token", json.dumps(routed))

    def test_app_request_rejects_codex_oauth_accounts(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={
                    "codexOAuthAccounts": {
                        "accounts": {
                            "acc-1": {"refresh_token": "rotatable-rt"}
                        }
                    }
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_CREDENTIAL_SCOPE",
        )

    def test_app_request_rejects_codex_auth(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={
                    "codexAuth": {
                        "tokens": {
                            "account_id": "acc-1",
                            "refresh_token": "rotatable-rt",
                        }
                    }
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_CREDENTIAL_SCOPE",
        )

    def test_codex_quota_accounts_are_absent_from_artifact(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaAccountOrder": ["acc-1"]},
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "fixture-short-lived-token",
                        }
                    },
                },
            ),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        self.assertNotIn("fixture-short-lived-token", json.dumps(response))
        self.assertNotIn("codexQuotaAccounts", json.dumps(response["artifact"]))

    def test_context_rejects_non_boolean_codex_quota_retry_only(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaRetryOnly": "yes"},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_REQUEST",
        )

    def test_context_accepts_boolean_codex_quota_retry_only(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["externalQuotas"],
                    "codexQuotaRetryOnly": True,
                },
            ),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        self.assertIs(captured["codex_quota_retry_only"], True)


class BridgeCredentialChallengesContractTests(unittest.TestCase):
    """任务 1 冻结契约: credentialChallenges 可选且白名单严格.

    预期红灯 (生产代码尚未实现): response schema 尚未声明 credentialChallenges,
    run_bridge 也尚未校验该字段.
    """

    def test_response_schema_allows_optional_credential_challenges(self):
        schema = json.loads(
            (
                REPO_ROOT / "bridge" / "schemas" / "response-v1.schema.json"
            ).read_text(encoding="utf-8")
        )
        self.assertNotIn(
            "credentialChallenges",
            schema["required"],
            "credentialChallenges 必须保持可选 (向后兼容旧 Bridge v1 响应)",
        )
        challenge = schema["$defs"]["credentialChallenge"]
        self.assertFalse(challenge.get("additionalProperties", True))
        self.assertEqual(
            set(challenge["required"]),
            {"provider", "accountId", "reason"},
        )
        self.assertEqual(challenge["properties"]["provider"]["const"], "codex")
        self.assertEqual(
            challenge["properties"]["reason"]["const"],
            "accessRejected",
        )
        self.assertGreaterEqual(
            challenge["properties"]["accountId"]["minLength"], 1
        )
        self.assertLessEqual(
            challenge["properties"]["accountId"]["maxLength"], 256
        )

    def test_response_rejects_challenge_with_unknown_reason(self):
        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": load_fixture("agent-usage"),
                    "credentialChallenges": [
                        {
                            "provider": "codex",
                            "accountId": "acc-1",
                            "reason": "refreshExpired",
                        }
                    ],
                }
            },
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
        )

    def test_response_rejects_challenge_with_extra_fields(self):
        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": load_fixture("agent-usage"),
                    "credentialChallenges": [
                        {
                            "provider": "codex",
                            "accountId": "acc-1",
                            "reason": "accessRejected",
                            "email": "fixture@example.test",
                        }
                    ],
                }
            },
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
        )

    def test_response_rejects_challenge_with_overlong_account_id(self):
        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": load_fixture("agent-usage"),
                    "credentialChallenges": [
                        {
                            "provider": "codex",
                            "accountId": "a" * 257,
                            "reason": "accessRejected",
                        }
                    ],
                }
            },
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_CREDENTIAL_CHALLENGE",
        )

    def test_response_forwards_valid_challenge(self):
        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={
                "agent-usage": lambda _ctx: {
                    "artifact": load_fixture("agent-usage"),
                    "credentialChallenges": [
                        {
                            "provider": "codex",
                            "accountId": "acc-1",
                            "reason": "accessRejected",
                        }
                    ],
                }
            },
        )
        self.assertEqual(response["status"], "success")
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

    def test_error_response_returns_empty_challenges(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={"unknownCredential": {}},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(response["credentialChallenges"], [])


class BridgeCapabilityTests(unittest.TestCase):
    def test_unknown_capability_is_rejected_as_security_error(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"capabilities": ["localSessions", "readEverything"]},
            )
        )
        self.assertEqual(response["status"], "error")
        diagnostic = response["diagnostics"][0]
        self.assertEqual(diagnostic["code"], "BRIDGE_UNKNOWN_CAPABILITY")
        self.assertEqual(diagnostic["category"], "security")

    def test_non_list_capabilities_are_protocol_errors(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"capabilities": "localSessions"},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_REQUEST",
        )

    def test_valid_capabilities_are_passed_to_collector_context(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["localSessions", "localPricing"],
                },
            ),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        self.assertEqual(
            captured["capabilities"],
            ["localSessions", "localPricing"],
        )

    def test_missing_capabilities_default_to_deny_all(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        self.assertEqual(captured["capabilities"], [])


class BridgeIsolationTests(unittest.TestCase):
    def test_agent_collector_runs_with_isolated_inputs(self):
        with tempfile.TemporaryDirectory() as temp_home:
            temp_root = Path(temp_home)
            db_path = temp_root / ".cc-switch" / "cc-switch.db"
            db_path.parent.mkdir(parents=True)
            with sqlite3.connect(db_path):
                pass
            os.chmod(db_path, 0o444)
            before = hashlib.sha256(db_path.read_bytes()).hexdigest()
            common_context = {
                "home": temp_home,
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
            }

            agent_response = execute_request(
                bridge_request(
                    "agent-usage",
                    context=common_context,
                    credentials={
                        "kimiWebTokens": {},
                        "antigravityOAuth": {},
                    },
                ),
                runtime_overrides={
                    "agent-usage": {
                        "http": {
                            "get_json": lambda *_: self.fail(
                                "unexpected agent GET"
                            ),
                            "post_json": lambda *_: self.fail(
                                "unexpected agent POST"
                            ),
                            "urlopen": lambda *_args, **_kwargs: self.fail(
                                "unexpected agent urlopen"
                            ),
                        }
                    }
                },
            )
            after = hashlib.sha256(db_path.read_bytes()).hexdigest()

        self.assertEqual(before, after)
        self.assertEqual(agent_response["status"], "partial")


class BridgeCodexQuotaIsolationTests(unittest.TestCase):
    """任务 11 契约: App quota 路径只消费注入的短期 access token,
    不因磁盘上存在旧认证文件而触发任何读取或刷新.

    这些是 fail-closed 证据: 即使 fake CC Switch / Codex CLI 文件在
    HOME 中存在, 有 codex_quota_accounts 注入时 Bridge 运行时也必须
    完全不触碰它们 (hash/size/mtime 不变), 且绝不访问真实 OAuth 端点.
    """

    def _hash_and_size_and_mtime(self, path):
        stat = os.stat(path)
        return (
            hashlib.sha256(path.read_bytes()).hexdigest(),
            stat.st_size,
            stat.st_mtime_ns,
        )

    def test_quota_path_does_not_touch_cc_switch_or_cli_auth_files(self):
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
            before = {
                str(path): self._hash_and_size_and_mtime(path)
                for path in (cc_auth, cli_auth)
            }

            usage_hits = []

            def get_json(url, headers):
                usage_hits.append(url)
                self.assertEqual(
                    headers["Authorization"],
                    "Bearer fixture-short-lived-token",
                )
                return {
                    "plan_type": "fixture",
                    "rate_limit": {
                        "primary_window": {
                            "limit_window_seconds": 18000,
                            "used_percent": 42,
                            "reset_at": "2026-07-28T17:00:00+08:00",
                        }
                    },
                    "credits": {"unlimited": True},
                }

            response = execute_request(
                bridge_request(
                    "agent-usage",
                    context={
                        "home": temp_home,
                        "now": "2026-07-28T12:00:00+08:00",
                        "timezone": "Asia/Shanghai",
                        "capabilities": ["localSessions", "externalQuotas"],
                        "codexQuotaAccountOrder": ["acc-1"],
                    },
                    credentials={
                        "codexQuotaAccounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "fixture-short-lived-token",
                            }
                        },
                    },
                ),
                runtime_overrides={
                    "agent-usage": {
                        "http": {
                            "get_json": get_json,
                            "urlopen": lambda *_a, **_k: self.fail(
                                "quota 路径不得发起直接 urlopen (OAuth 端点)"
                            ),
                        }
                    }
                },
            )
            after = {
                str(path): self._hash_and_size_and_mtime(path)
                for path in (cc_auth, cli_auth)
            }

        self.assertEqual(response["status"], "success")
        self.assertEqual(len(usage_hits), 1)
        services = response["artifact"]["services"]
        codex = [s for s in services if s.get("app") == "codex"]
        self.assertEqual(len(codex), 1)
        self.assertEqual(codex[0]["status"], "ok")
        self.assertEqual(before, after)

    def test_quota_401_with_legacy_files_emits_only_whitelisted_challenge(self):
        """quota 401 时即使磁盘存在旧认证文件, 也只返回白名单 challenge,
        响应体中不含旧 refresh token 或任何认证文件内容."""
        with tempfile.TemporaryDirectory() as temp_home:
            cc_auth = Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            cc_auth.parent.mkdir(parents=True)
            cc_auth.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "acc-1": {
                                "refresh_token": "cc-rotatable-rt",
                            }
                        }
                    }
                ),
                encoding="utf-8",
            )

            def get_json(url, headers):
                raise RuntimeError("HTTP 401")

            response = execute_request(
                bridge_request(
                    "agent-usage",
                    context={
                        "home": temp_home,
                        "now": "2026-07-28T12:00:00+08:00",
                        "timezone": "Asia/Shanghai",
                        "capabilities": ["localSessions", "externalQuotas"],
                        "codexQuotaAccountOrder": ["acc-1"],
                    },
                    credentials={
                        "codexQuotaAccounts": {
                            "acc-1": {
                                "display_name": "Codex · user",
                                "access_token": "fixture-short-lived-token",
                            }
                        },
                    },
                ),
                runtime_overrides={
                    "agent-usage": {"http": {"get_json": get_json}}
                },
            )

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
        serialized = json.dumps(response)
        self.assertNotIn("cc-rotatable-rt", serialized)
        self.assertNotIn("fixture-short-lived-token", serialized)


class BridgeCodexQuotaOrderContractTests(unittest.TestCase):
    """任务 6 契约: codexQuotaAccountOrder 校验, 长度限制, 端点覆盖拒绝."""

    def test_order_must_match_account_keys(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "codexQuotaAccountOrder": ["acc-1"],
                },
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "at",
                        },
                        "acc-2": {
                            "display_name": "Codex · other",
                            "access_token": "at2",
                        },
                    },
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_order_rejects_duplicates(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "codexQuotaAccountOrder": ["acc-1", "acc-1"],
                },
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "at",
                        },
                    },
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_order_accepts_matching_keys(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "codexQuotaAccountOrder": ["acc-1", "acc-2"],
                },
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "at",
                        },
                        "acc-2": {
                            "display_name": "Codex · other",
                            "access_token": "at2",
                        },
                    },
                },
            ),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "success")
        self.assertEqual(
            captured["codex_quota_account_order"], ["acc-1", "acc-2"]
        )

    def test_map_without_order_rejected(self):
        """ORD-03: 有 codexQuotaAccounts 无 codexQuotaAccountOrder 拒绝."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "Codex · user",
                            "access_token": "at",
                        }
                    },
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_order_without_map_rejected(self):
        """ORD-04: 有 codexQuotaAccountOrder 无 codexQuotaAccounts 拒绝."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaAccountOrder": ["acc-1"]},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_empty_map_rejected(self):
        """ORD-05: 空 codexQuotaAccounts 拒绝 (不再静默降级为空服务)."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaAccountOrder": []},
                credentials={"codexQuotaAccounts": {}},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_entry_missing_display_name_rejected(self):
        """ORD-06: 账号条目缺 display_name 拒绝."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaAccountOrder": ["acc-1"]},
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {"access_token": "at"},
                    }
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_display_name_over_protocol_limit_rejected(self):
        """schema 与运行时 validator 都拒绝超过 256 字符的展示名."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexQuotaAccountOrder": ["acc-1"]},
                credentials={
                    "codexQuotaAccounts": {
                        "acc-1": {
                            "display_name": "x" * 257,
                            "access_token": "at",
                        }
                    }
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_request_rejects_codex_usage_url_override(self):
        """正式 Bridge 请求拒绝 codexUsageUrl 端点覆盖."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexUsageUrl": "http://127.0.0.1:9999/usage"},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_request_rejects_codex_token_url_override(self):
        """正式 Bridge 请求拒绝 codexTokenUrl 端点覆盖."""
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"codexTokenUrl": "http://127.0.0.1:9999/token"},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_response_rejects_codex_credential_update(self):
        """response schema 不再接受 codex provider 的 credentialUpdate."""
        def collector(ctx):
            return {
                "artifact": load_fixture("agent-usage"),
                "credentialUpdates": [
                    {
                        "provider": "codex",
                        "accountId": "acc-1",
                        "kind": "oauthTokens",
                        "operation": "replace",
                        "credentials": {
                            "access_token": "at",
                            "refresh_token": "rt",
                        },
                    }
                ],
            }

        response = execute_request(
            bridge_request("agent-usage"),
            collector_overrides={"agent-usage": collector},
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_CREDENTIAL_UPDATE",
        )


class AppCoreResidualContractTests(unittest.TestCase):
    """任务 10 残留扫描契约: AppCore 关键路径不得出现旧 Codex auth
    契约或可旋转凭证字段; App 层不得读取第三方 Codex 凭证文件 (除
    用户点击触发的元数据发现)."""

    APP_CORE = REPO_ROOT / "macos" / "MdddApp" / "Sources" / "MdddAppCore"
    APP_LAYER = REPO_ROOT / "macos" / "MdddApp" / "Sources" / "MdddApp"

    def test_app_core_has_no_legacy_codex_auth_contracts(self):
        """CollectorRunner/RefreshScheduler/Merger 不得出现旧 Codex auth
        注入键与 URL 覆盖字符串."""
        files = [
            "CollectorRunner.swift",
            "RefreshScheduler.swift",
            "CodexQuotaSnapshotMerger.swift",
        ]
        for name in files:
            source = (self.APP_CORE / name).read_text(encoding="utf-8")
            for forbidden in (
                "codexOAuthAccounts",
                "codexAuth",
                "codexUsageUrl",
                "codexTokenUrl",
            ):
                self.assertNotIn(forbidden, source, "%s 含 %s" % (name, forbidden))

    def test_app_core_has_no_rotatable_token_fields(self):
        """CollectorRunner/RefreshScheduler/Merger/CollectorRunInput 不得
        出现 refresh_token / id_token 字段契约."""
        files = [
            "CollectorRunner.swift",
            "RefreshScheduler.swift",
            "CodexQuotaSnapshotMerger.swift",
            "CollectorRunInput.swift",
        ]
        for name in files:
            source = (self.APP_CORE / name).read_text(encoding="utf-8")
            for forbidden in ("refresh_token", "id_token"):
                self.assertNotIn(forbidden, source, "%s 含 %s" % (name, forbidden))

    def test_app_does_not_read_third_party_codex_credential_files(self):
        """App 层读取 ~/.codex/auth.json 只发生在用户点击触发的元数据
        发现 (importCodexFromLocalCLI), 无自动读取回退.
        Task 9 后实现落在 SubscriptionService + LocalCredentialProbe."""
        service = (self.APP_LAYER / "SubscriptionService.swift").read_text(
            encoding="utf-8"
        )
        probe = (self.APP_LAYER / "LocalCredentialProbe.swift").read_text(
            encoding="utf-8"
        )
        # 三处: 发现注释 + importCodexFromLocalCLI 实际读取 (用户点击触发)
        # + codexCLIAuthFileExists 存在性检查 (不读取令牌内容).
        # 均不是自动读取第三方认证文件的回退.
        total = service.count(".codex/auth.json") + probe.count(".codex/auth.json")
        self.assertEqual(total, 3)
        # 无读取第三方认证文件的自动回退 (死代码已删)
        app_layer = "\n".join(
            p.read_text(encoding="utf-8")
            for p in self.APP_LAYER.rglob("*.swift")
        )
        self.assertNotIn("readCodexCLIActiveAccountID", app_layer)

    def test_collector_orca_label_disk_oauth_fallback_is_cli_only(self):
        """任务 11 契约: orca_account_label 读取 ~/.cc-switch/codex_oauth_auth.json
        的磁盘回退必须受 not _APP_MODE 保护 (App 模式只消费注入凭证)."""
        source = (
            REPO_ROOT / "agent-usage" / "collector" / "collect_usage.py"
        ).read_text(encoding="utf-8")
        label_start = source.index("def orca_account_label")
        label_end = source.index("    # 5 个本地扫描互不共享状态")
        label = source[label_start:label_end]
        self.assertIn("not _APP_MODE", label)
        # 磁盘回退是受保护的单点; App 模式注入 orca_codex_auth 时
        # 不得存在任何无 _APP_MODE guard 的 CODEX_OAUTH_AUTH 打开路径
        self.assertIn("and not _APP_MODE", label)


if __name__ == "__main__":
    unittest.main()
