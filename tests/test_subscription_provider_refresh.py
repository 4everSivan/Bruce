"""订阅额度 Provider 定向刷新契约测试 (subscription-provider-refresh).

覆盖 Bridge v1 白名单 / fail-closed 校验, 以及 Python Collector 的
quota-only 定向采集隔离 (只查询目标 Provider, agents=[] / 仅含目标 services).

参考 openspec/changes/subscription-provider-refresh/design.md 的
Input/Collector/Snapshot 契约与 tasks.md 第 2 节验收点.
"""

import io
import json
import tempfile
import unittest
from pathlib import Path

from bridge.run_bridge import execute_request
from bridge.security import SUBSCRIPTION_PROVIDER_IDS

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


CODEX_ACCOUNTS = {
    "acc-1": {
        "display_name": "Codex · user",
        "access_token": "fixture-short-lived-token",
    }
}


def codex_quota_context(home, now="2026-07-28T12:00:00+08:00"):
    return {
        "home": home,
        "now": now,
        "timezone": "Asia/Shanghai",
        "capabilities": ["externalQuotas"],
        "codexQuotaAccountOrder": ["acc-1"],
        "subscriptionQuotaOnly": True,
        "subscriptionProviders": ["codex"],
    }


def codex_fake_get_json(url, headers):
    assert headers["Authorization"] == "Bearer fixture-short-lived-token"
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


class BridgeSubscriptionQuotaOnlyValidationTests(unittest.TestCase):
    """Input/Bridge 契约: 白名单 / fail-closed (tasks.md 2.1)."""

    def test_known_provider_ids_match_subscriptionproviderid(self):
        # 与 Swift SubscriptionProviderID.rawValue 对齐的单一事实来源检查.
        self.assertEqual(
            SUBSCRIPTION_PROVIDER_IDS,
            {
                "kimi",
                "deepseek",
                "volcengine",
                "codex",
                "antigravity",
                "claude",
                "grok",
                "opencodeGo",
            },
        )

    def test_valid_single_provider_passes_validation(self):
        captured = {}

        def collector(ctx):
            captured.update(ctx)
            return {"artifact": load_fixture("agent-usage")}

        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["externalQuotas"],
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": ["deepseek"],
                },
                credentials={"deepseekQuotaAccounts": {"acc-1": {
                    "display_name": "DeepSeek · 1", "api_key": "sk-x"}}},
            ),
            collector_overrides={"agent-usage": collector},
        )
        # 校验通过后到达 collector; 凭证校验在 collector 内部完成.
        self.assertNotEqual(response["status"], "error")
        self.assertNotEqual(
            response["diagnostics"][0]["code"]
            if response["diagnostics"]
            else "",
            "BRIDGE_UNKNOWN_SUBSCRIPTION_PROVIDER",
        )
        # 运行时上下文按 snake_case 映射.
        self.assertIs(captured.get("subscription_quota_only"), True)
        self.assertEqual(captured.get("subscription_providers"), ["deepseek"])

    def test_valid_multiple_providers_passes_validation(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["externalQuotas"],
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": ["deepseek", "codex"],
                    "codexQuotaAccountOrder": ["acc-1"],
                },
                credentials={
                    "deepseekQuotaAccounts": {"acc-1": {
                        "display_name": "DeepSeek · 1", "api_key": "sk-x"}},
                    "codexQuotaAccounts": CODEX_ACCOUNTS,
                },
            )
        )
        self.assertNotEqual(response["status"], "error")
        self.assertNotEqual(
            response["diagnostics"][0]["code"]
            if response["diagnostics"]
            else "",
            "BRIDGE_UNKNOWN_SUBSCRIPTION_PROVIDER",
        )

    def test_unknown_provider_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["externalQuotas"],
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": ["notAProvider"],
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_UNKNOWN_SUBSCRIPTION_PROVIDER",
        )

    def test_empty_provider_array_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": [],
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_wrong_type_provider_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": "deepseek",
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_non_boolean_quota_only_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "subscriptionQuotaOnly": "yes",
                    "subscriptionProviders": ["deepseek"],
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_quota_only_without_providers_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"subscriptionQuotaOnly": True},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_providers_without_quota_only_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"subscriptionProviders": ["deepseek"]},
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"], "BRIDGE_INVALID_REQUEST"
        )

    def test_local_sessions_with_providers_is_rejected(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={
                    "capabilities": ["localSessions", "externalQuotas"],
                    "subscriptionQuotaOnly": True,
                    "subscriptionProviders": ["deepseek"],
                },
            )
        )
        self.assertEqual(response["status"], "error")
        self.assertEqual(
            response["diagnostics"][0]["code"],
            "BRIDGE_SUBSCRIPTION_NOT_QUOTA_ONLY",
        )

    def test_full_request_without_fields_still_valid(self):
        response = execute_request(
            bridge_request(
                "agent-usage",
                context={"capabilities": ["localSessions", "externalQuotas"]},
            )
        )
        self.assertNotEqual(response["status"], "error")


class BridgeSubscriptionCollectorIsolationTests(unittest.TestCase):
    """Collector 契约: 定向采集隔离 (tasks.md 2.3 / 2.4)."""

    def test_codex_target_isolated_to_only_codex_services(self):
        with tempfile.TemporaryDirectory() as temp_home:
            response = execute_request(
                bridge_request(
                    "agent-usage",
                    context=codex_quota_context(temp_home),
                    credentials={"codexQuotaAccounts": CODEX_ACCOUNTS},
                ),
                runtime_overrides={
                    "agent-usage": {"http": {"get_json": codex_fake_get_json}}
                },
            )
        self.assertEqual(response["status"], "success")
        artifact = response["artifact"]
        # 定向路径: 不扫描本地会话/价格.
        self.assertEqual(artifact["agents"], [])
        self.assertIsNone(artifact["totalCostUsd"])
        self.assertTrue(artifact["services"])
        for svc in artifact["services"]:
            self.assertEqual(svc["app"], "codex")
        self.assertEqual(len(artifact["services"]), 1)

    def test_deepseek_target_isolated_to_only_target_services(self):
        def fake_get_json(url, headers):
            self.assertIn("api.deepseek.com", url)
            return {"balance_infos": [{"total_balance": 1.5, "currency": "CNY"}]}

        with tempfile.TemporaryDirectory() as temp_home:
            response = execute_request(
                bridge_request(
                    "agent-usage",
                    context={
                        "home": temp_home,
                        "now": "2026-07-28T12:00:00+08:00",
                        "timezone": "Asia/Shanghai",
                        "capabilities": ["externalQuotas"],
                        "subscriptionQuotaOnly": True,
                        "subscriptionProviders": ["deepseek"],
                    },
                    credentials={
                        "deepseekQuotaAccounts": {
                            "acc-1": {
                                "display_name": "DeepSeek · 1",
                                "api_key": "sk-fixture",
                            }
                        }
                    },
                ),
                runtime_overrides={
                    "agent-usage": {"http": {"get_json": fake_get_json}}
                },
            )
        self.assertEqual(response["status"], "success")
        artifact = response["artifact"]
        self.assertEqual(artifact["agents"], [])
        self.assertIsNone(artifact["totalCostUsd"])
        self.assertTrue(artifact["services"])
        for svc in artifact["services"]:
            self.assertEqual(svc["app"], "deepseek")

    def test_codex_401_in_target_keeps_scoped_shape_and_emits_challenge(self):
        with tempfile.TemporaryDirectory() as temp_home:
            response = execute_request(
                bridge_request(
                    "agent-usage",
                    context=codex_quota_context(temp_home),
                    credentials={"codexQuotaAccounts": CODEX_ACCOUNTS},
                ),
                runtime_overrides={
                    "agent-usage": {
                        "http": {
                            "get_json": lambda url, headers: (_ for _ in ()).throw(
                                RuntimeError("HTTP 401")
                            )
                        }
                    }
                },
            )
        self.assertIn(response["status"], ("partial", "error"))
        artifact = response["artifact"]
        self.assertEqual(artifact["agents"], [])
        # 至少产出目标 Codex service (状态为 error/unavailable), 不伪造 success.
        codex = [s for s in artifact["services"] if s.get("app") == "codex"]
        self.assertTrue(codex)
        self.assertNotEqual(codex[0]["status"], "ok")
        self.assertEqual(
            response["credentialChallenges"],
            [{"provider": "codex", "accountId": "acc-1", "reason": "accessRejected"}],
        )
        self.assertNotIn("fixture-short-lived-token", json.dumps(response))


class CollectorSubscriptionQuotaOnlyUnitTests(unittest.TestCase):
    """直接调用 collector façade 的单元级契约."""

    def test_invalid_provider_raises_diagnosable_error(self):
        # 避免 import 时路径问题: 从文件加载模块
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "collect_usage_sub_test",
            REPO_ROOT
            / "agent-usage"
            / "collector"
            / "collect_usage.py",
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with self.assertRaises(ValueError):
            module._collect_subscription_quota_only(
                module._configure_runtime(
                    {
                        "app_mode": True,
                        "subscription_quota_only": True,
                        "subscription_providers": ["bogus"],
                    }
                )
            )


if __name__ == "__main__":
    unittest.main()
