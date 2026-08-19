"""智谱 Coding Plan 个人版额度查询 (service_zhipu) 契约测试.

覆盖范围:
- base_url 路由 (国内站 open.bigmodel.cn / 国外站 api.z.ai).
- TOKENS_LIMIT 按 unit 分类 (3->每 5 小时, 6->每周), 忽略 TIME_LIMIT.
- nextResetTime 毫秒转秒, 非正数置 None.
- 老套餐单条降级 / unit 缺失兜底.
- service_zhipu: 无凭证 None, 业务失败/鉴权失败可诊断, data 缺失报错.
- 端点与 Authorization 头 (裸 API key, 不加 Bearer).

fixture / 断言均不含真实 token 或外部网络.
"""

import importlib.util
import unittest
import urllib.error
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


def _http_error(code):
    return urllib.error.HTTPError("https://example.invalid", code, "msg", None, None)


class ZhipuQuotaBaseTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_zhipu", "agent-usage/collector/collect_usage.py"
        )
        self.qs = self.module.quota_services

    def test_bigmodel_routes_to_cn(self):
        self.assertEqual(
            self.qs._zhipu_quota_base("https://open.bigmodel.cn/api/paas/v4"),
            "open.bigmodel.cn",
        )

    def test_z_ai_routes_to_en(self):
        self.assertEqual(
            self.qs._zhipu_quota_base("https://api.z.ai/api/paas/v4"),
            "api.z.ai",
        )


class ZhipuParseWindowsTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_zhipu_parse", "agent-usage/collector/collect_usage.py"
        )
        self.parse = self.module.quota_services._parse_zhipu_windows

    def test_unit_classification(self):
        windows = self.parse([
            {"type": "TOKENS_LIMIT", "unit": 3, "number": 5,
             "percentage": 1.0, "nextResetTime": 1774967594803},
            {"type": "TOKENS_LIMIT", "unit": 6, "number": 7,
             "percentage": 42.0, "nextResetTime": 1775067594803},
        ])
        self.assertEqual(
            [(w["label"], w["windowMinutes"], w["usedPercent"]) for w in windows],
            [("每 5 小时", 300, 1.0), ("每周", 10080, 42.0)],
        )
        # 毫秒 -> 秒
        self.assertEqual(windows[0]["resetsAt"], 1774967594)
        self.assertEqual(windows[1]["resetsAt"], 1775067594)

    def test_ignores_time_limit(self):
        windows = self.parse([
            {"type": "TIME_LIMIT", "percentage": 0.0},
            {"type": "TOKENS_LIMIT", "unit": 3, "percentage": 10.0},
        ])
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["label"], "每 5 小时")

    def test_credit_limit_type(self):
        # 实测 2026-08: 智谱已改用 CREDIT_LIMIT (credit 制度), level=pro.
        # usage/currentValue/remaining 是 credit 数, percentage 是已用百分比.
        windows = self.parse([
            {"type": "CREDIT_LIMIT", "unit": 3, "number": 5,
             "usage": 12000, "currentValue": 2344, "remaining": 9655,
             "percentage": 19, "nextResetTime": 1787120950639},
            {"type": "CREDIT_LIMIT", "unit": 6, "number": 1,
             "usage": 60000, "currentValue": 2344, "remaining": 57655,
             "percentage": 3, "nextResetTime": 1787707653998},
        ])
        self.assertEqual(
            [(w["label"], w["usedPercent"], w["windowMinutes"]) for w in windows],
            [("每 5 小时", 19.0, 300), ("每周", 3.0, 10080)],
        )
        self.assertEqual(windows[0]["resetsAt"], 1787120950)
        self.assertEqual(windows[1]["resetsAt"], 1787707653)

    def test_case_insensitive_type(self):
        windows = self.parse([
            {"type": "tokens_limit", "unit": 6, "percentage": 5.0},
        ])
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["label"], "每周")

    def test_legacy_single_limit_degrades_to_five_hour(self):
        # 老套餐只回 1 条 TOKENS_LIMIT, 自然降级为仅每 5 小时
        windows = self.parse([
            {"type": "TOKENS_LIMIT", "unit": 3, "percentage": 20.0},
        ])
        self.assertEqual([w["label"] for w in windows], ["每 5 小时"])

    def test_unit_missing_fallback_without_reset_first(self):
        # unit 缺失: 无 reset 的优先归每 5 小时, 有 reset 的按升序填每周
        windows = self.parse([
            {"type": "TOKENS_LIMIT", "percentage": 30.0,
             "nextResetTime": 1775067594803},
            {"type": "TOKENS_LIMIT", "percentage": 8.0},
        ])
        self.assertEqual(
            [(w["label"], w["usedPercent"]) for w in windows],
            [("每 5 小时", 8.0), ("每周", 30.0)],
        )

    def test_non_positive_reset_becomes_none(self):
        windows = self.parse([
            {"type": "TOKENS_LIMIT", "unit": 3, "percentage": 5.0,
             "nextResetTime": -1},
        ])
        self.assertIsNone(windows[0]["resetsAt"])

    def test_empty_limits(self):
        self.assertEqual(self.parse(None), [])
        self.assertEqual(self.parse([]), [])


class ZhipuServiceTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_zhipu_service", "agent-usage/collector/collect_usage.py"
        )
        self.service = self.module.quota_services.service_zhipu
        self.runtime = self.module.quota_services.runtime

    def _env(self, key="id.secret", base_url="https://open.bigmodel.cn/api/paas/v4"):
        return {"ANTHROPIC_AUTH_TOKEN": key, "ANTHROPIC_BASE_URL": base_url}

    def test_no_credential_returns_none(self):
        self.assertIsNone(self.service({}, 8.0))
        self.assertIsNone(self.service({"ANTHROPIC_AUTH_TOKEN": "k"}, 8.0))
        self.assertIsNone(
            self.service({"ANTHROPIC_BASE_URL": "https://open.bigmodel.cn"}, 8.0)
        )

    def test_success_returns_kind_plan_windows(self):
        payload = {
            "success": True,
            "data": {
                "level": "Pro",
                "limits": [
                    {"type": "TOKENS_LIMIT", "unit": 3, "percentage": 1.0,
                     "nextResetTime": 1774967594803},
                    {"type": "TOKENS_LIMIT", "unit": 6, "percentage": 42.0,
                     "nextResetTime": 1775067594803},
                ],
            },
        }
        with mock.patch.object(self.runtime, "http_get_json", return_value=payload) as m:
            result = self.service(self._env(), 8.0)
        # 端点与请求头 (裸 API key, 不加 Bearer)
        url, headers = m.call_args[0][0], m.call_args[0][1]
        self.assertEqual(url, "https://open.bigmodel.cn/api/monitor/usage/quota/limit")
        self.assertEqual(headers["Authorization"], "id.secret")
        self.assertNotIn("Bearer", headers["Authorization"])

        self.assertEqual(result["kind"], "windows")
        self.assertEqual(result["plan"], "Pro")
        self.assertEqual(len(result["windows"]), 2)

    def test_en_host_routes_to_z_ai(self):
        payload = {"success": True, "data": {"level": "Lite", "limits": []}}
        with mock.patch.object(self.runtime, "http_get_json", return_value=payload) as m:
            self.service(self._env(base_url="https://api.z.ai/api/paas/v4"), 8.0)
        self.assertEqual(
            m.call_args[0][0], "https://api.z.ai/api/monitor/usage/quota/limit"
        )

    def test_business_error_raises_msg(self):
        payload = {"success": False, "msg": "invalid api key"}
        with mock.patch.object(self.runtime, "http_get_json", return_value=payload):
            with self.assertRaises(RuntimeError) as ctx:
                self.service(self._env(), 8.0)
        self.assertIn("invalid api key", str(ctx.exception))

    def test_http_401_raises_diagnosable(self):
        with mock.patch.object(
            self.runtime, "http_get_json", side_effect=_http_error(401)
        ):
            with self.assertRaises(RuntimeError) as ctx:
                self.service(self._env(), 8.0)
        self.assertIn("401", str(ctx.exception))

    def test_http_403_raises_diagnosable(self):
        with mock.patch.object(
            self.runtime, "http_get_json", side_effect=_http_error(403)
        ):
            with self.assertRaises(RuntimeError) as ctx:
                self.service(self._env(), 8.0)
        self.assertIn("403", str(ctx.exception))

    def test_missing_data_raises(self):
        payload = {"success": True}
        with mock.patch.object(self.runtime, "http_get_json", return_value=payload):
            with self.assertRaises(RuntimeError) as ctx:
                self.service(self._env(), 8.0)
        self.assertIn("data", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
