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
                        "codexQuotaAccounts": {},
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


if __name__ == "__main__":
    unittest.main()
