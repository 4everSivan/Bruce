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
        artifact = load_fixture("github")
        expected_artifact = dict(artifact)
        expected_artifact.update({"schemaVersion": 1, "module": "github"})
        request = bridge_request("github")
        response = execute_request(
            request,
            collector_overrides={
                "github": lambda _ctx: {"artifact": artifact}
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
                    "github": lambda _ctx: {"artifact": artifact}
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
        missing = bridge_request("github")
        missing.pop("credentials")
        missing_response = execute_request(missing)
        self.assertEqual(missing_response["status"], "error")
        self.assertEqual(
            missing_response["diagnostics"][0]["code"],
            "BRIDGE_INVALID_REQUEST",
        )

        unknown = bridge_request("github")
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
            return {"artifact": load_fixture("github")}

        response = execute_request(
            bridge_request("github"),
            collector_overrides={"github": noisy_collector},
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
            bridge_request("github"),
            collector_overrides={"github": failed_collector},
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
            bridge_request("github"),
            collector_overrides={
                "github": lambda _ctx: {
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
                "github",
                credentials={"gitlabToken": "must-not-be-routed"},
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
    def test_all_collectors_run_with_isolated_inputs(self):
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
                        "codexOAuthAccounts": {"accounts": {}},
                        "codexAuth": {"tokens": {}},
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

            github_payload = {
                "data": {
                    "viewer": {
                        "login": "fixture-user",
                        "contributionsCollection": {
                            "contributionCalendar": {
                                "totalContributions": 0,
                                "weeks": [],
                            }
                        },
                    }
                }
            }
            github_response = execute_request(
                bridge_request("github", context=common_context),
                runtime_overrides={
                    "github": {"graphql": lambda _query: github_payload}
                },
            )

            def gitlab_http(path, token):
                self.assertEqual(token, "fixture-gitlab-token")
                if path == "/api/v4/user":
                    return {
                        "id": 7,
                        "username": "fixture-user",
                        "name": "Fixture",
                    }
                return []

            gitlab_context = dict(common_context)
            gitlab_context["baseUrl"] = "https://gitlab.example.test"
            gitlab_response = execute_request(
                bridge_request(
                    "gitlab",
                    context=gitlab_context,
                    credentials={"gitlabToken": "fixture-gitlab-token"},
                ),
                runtime_overrides={
                    "gitlab": {"http_get_json": gitlab_http}
                },
            )

        self.assertEqual(before, after)
        self.assertEqual(agent_response["status"], "partial")
        self.assertEqual(github_response["status"], "success")
        self.assertEqual(gitlab_response["status"], "success")
        self.assertNotIn(
            "fixture-gitlab-token",
            json.dumps(gitlab_response),
        )


if __name__ == "__main__":
    unittest.main()
