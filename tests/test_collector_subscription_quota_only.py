"""订阅额度定向刷新 (quota-only) 的 Python Collector 契约测试 (TASK-6C).

覆盖范围:
- 只调用目标 Provider 的现有 handler, 不扫描本机会话、不加载定价.
- artifact v1 形状: agents=[] / totalCostUsd=null / services 只含目标 Provider.
- Provider 内多账号独立结果, 单账号失败不阻断其他账号.
- Codex 目标复用既有 recovery / challenge 边界 (至多一次 forced refresh + 一次 retry).
- 目标集合非法或凭证未装配时返回可诊断失败, 不伪造空的 success artifact.

注意: run_app 接收的是 Bridge 已映射的 snake_case 凭证 (codex_quota_accounts /
deepseek_quota_accounts ...), codex_quota_account_order 在 ctx 顶层.

fixture / 日志 / 断言均不含 token、secret 或 OAuth 原文; 不使用真实账号或外部网络.
"""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(
        name, REPO_ROOT / relative_path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SubscriptionQuotaOnlyCollectorTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_sq",
            "agent-usage/collector/collect_usage.py",
        )

    def _ctx(self, providers, credentials=None, meta=None, extra=None):
        ctx = {
            "app_mode": True,
            "home": tempfile.mkdtemp(),
            "now": "2026-07-28T12:00:00+08:00",
            "timezone": "Asia/Shanghai",
            "capabilities": ["externalQuotas"],
            "subscription_quota_only": True,
            "subscription_providers": providers,
        }
        creds = dict(credentials or {})
        if meta is not None:
            creds["provider_meta"] = meta
        if creds:
            ctx["credentials"] = creds
        ctx.update(extra or {})
        return ctx

    def test_single_provider_returns_only_target_services(self):
        with mock.patch.object(self.module, "service_codex_accounts") as m_codex, \
                mock.patch.object(self.module, "service_antigravity") as m_agy, \
                mock.patch.object(
                    self.module.service_catalog, "build_quota_services"
                ) as m_cat, \
                mock.patch.object(self.module, "load_pricing") as m_price:
            m_cat.return_value = [
                {
                    "id": "deepseek_a",
                    "app": "deepseek",
                    "status": "ok",
                    "windows": [],
                }
            ]
            m_codex.return_value = []
            m_agy.return_value = []
            result = self.module.run_app(
                self._ctx(
                    ["deepseek"],
                    credentials={
                        "deepseek_quota_accounts": {
                            "a": {"display_name": "d", "api_key": "k"}
                        }
                    },
                )
            )

        artifact = result["artifact"]
        self.assertEqual(artifact["agents"], [])
        self.assertEqual(artifact["totalCostUsd"], None)
        services = artifact["services"]
        self.assertEqual(len(services), 1)
        self.assertEqual(services[0]["app"], "deepseek")
        # 只走目标 Provider 的 catalog handler, 不触碰 codex/antigravity
        m_cat.assert_called_once()
        m_codex.assert_not_called()
        m_agy.assert_not_called()
        # 不扫描会话、不加载定价
        m_price.assert_not_called()

    def test_multi_provider_calls_multiple_handlers(self):
        with mock.patch.object(self.module, "service_codex_accounts") as m_codex, \
                mock.patch.object(self.module, "service_antigravity") as m_agy, \
                mock.patch.object(
                    self.module.service_catalog, "build_quota_services"
                ) as m_cat:
            m_cat.return_value = [
                {"id": "deepseek_a", "app": "deepseek", "status": "ok", "windows": []}
            ]
            m_codex.return_value = [
                {"id": "codex_x", "app": "codex", "status": "ok", "windows": []}
            ]
            m_agy.return_value = [
                {"id": "antigravity", "app": "antigravity", "status": "ok", "windows": []}
            ]
            result = self.module.run_app(
                self._ctx(
                    ["deepseek", "codex", "antigravity"],
                    credentials={
                        "deepseek_quota_accounts": {
                            "a": {"display_name": "d", "api_key": "k"}
                        },
                        "codex_quota_accounts": {
                            "x": {"display_name": "c", "access_token": "t"}
                        },
                    },
                    extra={"codex_quota_account_order": ["x"]},
                )
            )

        self.assertEqual(len(result["artifact"]["services"]), 3)
        m_codex.assert_called_once()
        m_agy.assert_called_once()
        m_cat.assert_called_once()

    def test_multi_account_output_and_per_account_failure(self):
        """多账号独立结果; 单账号失败不阻断其他账号 (部分成功)."""
        with mock.patch.object(
            self.module.service_catalog, "build_quota_services"
        ) as m_cat:
            m_cat.return_value = [
                {
                    "id": "deepseek_a",
                    "app": "deepseek",
                    "status": "ok",
                    "windows": [],
                },
                {
                    "id": "deepseek_b",
                    "app": "deepseek",
                    "status": "error",
                    "note": "查询失败",
                    "kind": None,
                    "plan": None,
                    "windows": [],
                    "balance": None,
                    "currency": None,
                    "freshness": "unavailable",
                    "failureKind": "fixture",
                },
            ]
            result = self.module.run_app(
                self._ctx(
                    ["deepseek"],
                    credentials={
                        "deepseek_quota_accounts": {
                            "a": {"display_name": "d", "api_key": "k"},
                            "b": {"display_name": "e", "api_key": "bad"},
                        }
                    },
                )
            )

        services = result["artifact"]["services"]
        self.assertEqual(len(services), 2)
        status_by_id = {s["id"]: s["status"] for s in services}
        self.assertEqual(status_by_id["deepseek_a"], "ok")
        self.assertEqual(status_by_id["deepseek_b"], "error")

    def test_codex_target_preserves_recovery_challenge(self):
        """Codex 定向复用既有 recovery: 401 仅返回白名单 accessRejected challenge."""
        with mock.patch.object(
            self.module, "http_get_json", side_effect=RuntimeError("HTTP 401")
        ):
            result = self.module.run_app(
                self._ctx(
                    ["codex"],
                    credentials={
                        "codex_quota_accounts": {
                            "x": {
                                "display_name": "c",
                                "access_token": "fixture-short-lived-token",
                            }
                        }
                    },
                    extra={"codex_quota_account_order": ["x"]},
                )
            )

        self.assertEqual(
            result["credentialChallenges"],
            [{"provider": "codex", "accountId": "x", "reason": "accessRejected"}],
        )
        serialized = json.dumps(result)
        self.assertNotIn("fixture-short-lived-token", serialized)

    def test_unknown_provider_raises_diagnosable(self):
        """未知 Provider 直接经 collector 入口也拒绝 (Bridge 之外再一层防御)."""
        with self.assertRaises(ValueError):
            self.module.collect_subscription_quota_only(self._ctx(["ghost"]))

    def test_empty_providers_raises_diagnosable(self):
        with self.assertRaises(ValueError):
            self.module.collect_subscription_quota_only(self._ctx([]))

    def test_duplicate_providers_raises_diagnosable(self):
        with self.assertRaises(ValueError):
            self.module.collect_subscription_quota_only(self._ctx(["deepseek", "deepseek"]))

    def test_missing_external_quotas_capability_fails_closed(self):
        """未授权 externalQuotas 的 quota-only 请求不调用任何 handler."""
        ctx = self._ctx(
            ["deepseek"],
            credentials={
                "deepseek_quota_accounts": {"a": {"display_name": "d", "api_key": "k"}}
            },
        )
        ctx["capabilities"] = ["localSessions"]
        with mock.patch.object(
            self.module.service_catalog, "build_quota_services"
        ) as m_cat:
            with self.assertRaises(RuntimeError):
                self.module.collect_subscription_quota_only(ctx)
            m_cat.assert_not_called()

    def test_no_assembled_credentials_raises_diagnosable(self):
        """目标集合合法但没有任何 Provider 装配凭证: 可诊断失败, 不伪造空 success."""
        with mock.patch.object(
            self.module.service_catalog, "build_quota_services", return_value=[]
        ), mock.patch.object(
            self.module, "service_codex_accounts", return_value=[]
        ), mock.patch.object(
            self.module, "service_antigravity", return_value=[]
        ):
            with self.assertRaises(RuntimeError):
                self.module.collect_subscription_quota_only(
                    self._ctx(["deepseek"], credentials={})
                )


if __name__ == "__main__":
    unittest.main()
