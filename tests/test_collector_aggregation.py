import importlib.util
import json
import os
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


def _ts(iso):
    return datetime.fromisoformat(iso).timestamp()


def _token_count_record(ts_iso, rate_limits=None, usage=None):
    payload = {"type": "token_count"}
    if rate_limits is not None:
        payload["rate_limits"] = rate_limits
    if usage is not None:
        payload["info"] = {"last_token_usage": usage}
    return {"timestamp": ts_iso, "payload": payload}


def _write_rollout(path, records, mtime):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8"
    )
    os.utime(path, (mtime, mtime))


class AgentAggregationTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module(
            "collect_usage_aggregation_test",
            "agent-usage/collector/collect_usage.py",
        )
        self.module._configure_runtime(
            {
                "now": "2026-07-28T12:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "days": 2,
            }
        )

    def test_token_buckets_models_projects_hours_and_cost(self):
        agent = self.module.make_agent("fixture", "Fixture")
        timestamp = datetime(
            2026, 7, 28, 2, 0, tzinfo=timezone.utc
        ).timestamp()
        self.module.record_usage(
            agent,
            timestamp,
            "fixture-model",
            1_000_000,
            200_000,
            100_000,
            0,
            "fixture/project",
        )
        result = self.module.finalize(
            agent,
            {"fixture-model": (1.0, 2.0, 0.5, 0.0)},
        )

        self.assertEqual(result["today"]["total"], 1_300_000)
        self.assertEqual(result["daily"][-1]["input"], 1_100_000)
        self.assertEqual(result["daily"][-1]["output"], 200_000)
        self.assertEqual(result["todayModels"][0]["total"], 1_300_000)
        self.assertEqual(result["projects"][0]["name"], "fixture/project")
        self.assertEqual(result["hours"][10], 1_300_000)
        self.assertEqual(result["todayCostUsd"], 1.45)

    def test_usage_outside_configured_window_is_ignored(self):
        agent = self.module.make_agent("fixture", "Fixture")
        old_timestamp = datetime(
            2026, 7, 20, 10, 0, tzinfo=timezone.utc
        ).timestamp()
        self.module.record_usage(
            agent, old_timestamp, "fixture-model", 100, 10, 0, 0
        )
        result = self.module.finalize(agent, {})
        self.assertEqual(result["today"]["total"], 0)
        self.assertTrue(all(day["total"] == 0 for day in result["daily"]))

    def test_claude_skeleton_usage_writes_take_complete_value(self):
        """Claude Code (>= 2.1.228) 会把流式骨架 (usage=0) 与完整记录写入同一
        message id. scan_claude 必须取完整值 (max per id), 不能保留首次出现的
        usage=0, 否则 input/output 被大量丢弃.
        """
        agent = self.module.make_agent("claude-code", "Claude Code")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "claude-projects"
            session = root / "fixture-project" / "session.jsonl"
            skeleton = {
                "type": "assistant",
                "message": {
                    "id": "msg-skeleton",
                    "model": "deepseek-v4-flash",
                    "content": [],
                    "usage": {"input_tokens": 0, "output_tokens": 0},
                },
                "timestamp": "2026-07-28T02:00:00.000Z",
            }
            complete = {
                "type": "assistant",
                "message": {
                    "id": "msg-skeleton",
                    "model": "deepseek-v4-flash",
                    "content": [{"type": "text", "text": "x"}],
                    "usage": {
                        "input_tokens": 1000,
                        "output_tokens": 500,
                        "cache_read_input_tokens": 200,
                        "cache_creation_input_tokens": 0,
                    },
                },
                "timestamp": "2026-07-28T02:00:01.000Z",
            }
            single = {
                "type": "assistant",
                "message": {
                    "id": "msg-single",
                    "model": "deepseek-v4-flash",
                    "content": [{"type": "text", "text": "y"}],
                    "usage": {
                        "input_tokens": 500,
                        "output_tokens": 300,
                        "cache_read_input_tokens": 0,
                        "cache_creation_input_tokens": 0,
                    },
                },
                "timestamp": "2026-07-28T02:00:02.000Z",
            }
            session.parent.mkdir(parents=True, exist_ok=True)
            session.write_text(
                "\n".join(json.dumps(r) for r in [skeleton, complete, single])
                + "\n",
                encoding="utf-8",
            )
            os.utime(session, (_ts("2026-07-27T00:00:00+00:00"),) * 2)
            self.module.scan_claude(agent, str(root))
            result = self.module.finalize(agent, {})
            # 骨架 (usage=0) 与完整记录同属一个 message id: 必须取完整值
            self.assertEqual(result["today"]["input"], 1500)
            self.assertEqual(result["today"]["output"], 800)
            self.assertEqual(result["today"]["cacheRead"], 200)
            self.assertEqual(result["today"]["total"], 2500)


class CodexMergedAgentTests(unittest.TestCase):
    """Codex CLI 与 Orca 托管会话合并为单个 codex agent 的采集层测试."""

    NOW = "2026-07-28T12:00:00+08:00"

    def setUp(self):
        self.module = load_module(
            "collect_usage_codex_merge_test",
            "agent-usage/collector/collect_usage.py",
        )
        # opencode agent 扫描隔离: 本套件聚焦 Codex 合并语义,
        # 不触发真实 opencode CLI.
        from unittest import mock
        self._opencode_mock = mock.patch.object(
            self.module.local_usage,
            "scan_opencode",
            return_value=False,
        )
        self._opencode_mock.start()

    def tearDown(self):
        self._opencode_mock.stop()

    def _ctx(self, temp_home):
        return {
            "home": temp_home,
            "capabilities": ["localSessions", "localPricing"],
            "now": self.NOW,
            "timezone": "Asia/Shanghai",
            "days": 2,
        }

    def _cli_rollout(self, temp_home, records, mtime_iso):
        _write_rollout(
            Path(temp_home)
            / ".codex"
            / "sessions"
            / "2026"
            / "07"
            / "28"
            / "rollout-cli.jsonl",
            records,
            _ts(mtime_iso),
        )

    def _orca_rollout(self, temp_home, records, mtime_iso):
        _write_rollout(
            Path(temp_home)
            / "Library"
            / "Application Support"
            / "orca"
            / "codex-runtime-home"
            / "home"
            / "sessions"
            / "rollout-orca.jsonl",
            records,
            _ts(mtime_iso),
        )

    def _codex_agent(self, artifact):
        ids = [agent["id"] for agent in artifact["agents"]]
        self.assertEqual(
            ids, ["kimi-work", "kimi-code-cli", "claude-code", "codex", "grok", "opencode", "pi"]
        )
        return artifact["agents"][3]

    def test_cli_and_orca_sessions_merge_into_single_agent(self):
        with tempfile.TemporaryDirectory() as temp_home:
            # CLI 文件 mtime 更新但 quota ts 更旧, 证明跨来源按 ts 取最新
            self._cli_rollout(
                temp_home,
                [
                    _token_count_record(
                        "2026-07-28T09:00:00+08:00",
                        rate_limits={
                            "plan_type": "plus",
                            "primary": {
                                "used_percent": 10,
                                "window_minutes": 300,
                                "resets_at": 1785000000,
                            },
                        },
                        usage={
                            "input_tokens": 1000,
                            "cached_input_tokens": 200,
                            "output_tokens": 100,
                        },
                    )
                ],
                "2026-07-28T11:45:00+08:00",
            )
            self._orca_rollout(
                temp_home,
                [
                    _token_count_record(
                        "2026-07-28T11:00:00+08:00",
                        rate_limits={
                            "plan_type": "team",
                            "primary": {
                                "used_percent": 40,
                                "window_minutes": 300,
                                "resets_at": 1785003600,
                            },
                        },
                        usage={
                            "input_tokens": 2000,
                            "cached_input_tokens": 0,
                            "output_tokens": 300,
                        },
                    )
                ],
                "2026-07-28T11:30:00+08:00",
            )
            artifact = self.module.run(self._ctx(temp_home))["artifact"]

        codex = self._codex_agent(artifact)
        self.assertEqual(codex["name"], "Codex")
        self.assertEqual(codex["status"], "ok")
        self.assertIn("含 Orca 托管会话", codex["note"])
        # daily/hours/模型桶跨来源累加
        self.assertEqual(codex["today"]["total"], 3400)
        self.assertEqual(codex["daily"][-1]["total"], 3400)
        self.assertEqual(codex["hours"][9], 1100)
        self.assertEqual(codex["hours"][11], 2300)
        self.assertEqual(codex["todayModels"][0]["total"], 3400)
        # 成本基于合并桶估算 (codex 模型回落匹配内置 codex-mini 价目)
        self.assertIsNotNone(codex["todayCostUsd"])
        self.assertAlmostEqual(codex["todayCostUsd"], 0.0033, places=6)
        # quota 取两侧候选中 ts 最大者 (Orca 11:00 > CLI 09:00)
        self.assertEqual(codex["quota"]["plan"], "team")
        self.assertEqual(
            codex["quota"]["capturedAt"], "2026-07-28T11:00:00+08:00"
        )
        self.assertEqual(codex["quota"]["windows"][0]["usedPercent"], 40.0)

    def test_orca_only_sessions_keep_codex_ok_with_account_label(self):
        with tempfile.TemporaryDirectory() as temp_home:
            self._orca_rollout(
                temp_home,
                [
                    _token_count_record(
                        "2026-07-28T10:00:00+08:00",
                        usage={
                            "input_tokens": 500,
                            "cached_input_tokens": 0,
                            "output_tokens": 50,
                        },
                    )
                ],
                "2026-07-28T10:30:00+08:00",
            )
            orca_home = (
                Path(temp_home) / "Library" / "Application Support" / "orca"
            )
            auth_path = orca_home / "codex-runtime-home" / "home" / "auth.json"
            auth_path.parent.mkdir(parents=True, exist_ok=True)
            auth_path.write_text(
                json.dumps({"tokens": {"account_id": "acc-12345678"}}),
                encoding="utf-8",
            )
            oauth_path = (
                Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            )
            oauth_path.parent.mkdir(parents=True, exist_ok=True)
            oauth_path.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "acc-12345678": {"email": "fixture@example.test"}
                        }
                    }
                ),
                encoding="utf-8",
            )
            artifact = self.module.run(self._ctx(temp_home))["artifact"]

        codex = self._codex_agent(artifact)
        self.assertEqual(codex["status"], "ok")
        self.assertEqual(codex["today"]["total"], 550)
        self.assertIn("含 Orca 托管会话", codex["note"])
        self.assertIn("账号 fixture", codex["note"])

    def test_app_mode_orca_label_does_not_read_cc_switch_oauth_from_disk(
        self,
    ):
        """任务 11 契约: App 模式注入 orca_codex_auth 时, 账号标签只能来自
        注入的 codex_oauth_auth; 磁盘 ~/.cc-switch/codex_oauth_auth.json
        存在也不得读取 (标签显示同样受 _APP_MODE 磁盘隔离)."""
        with tempfile.TemporaryDirectory() as temp_home:
            self._orca_rollout(
                temp_home,
                [
                    _token_count_record(
                        "2026-07-28T10:00:00+08:00",
                        usage={
                            "input_tokens": 500,
                            "cached_input_tokens": 0,
                            "output_tokens": 50,
                        },
                    )
                ],
                "2026-07-28T10:30:00+08:00",
            )
            # 磁盘上存在唯一含 email 的 oauth 文件; App 模式不得读取
            oauth_path = (
                Path(temp_home) / ".cc-switch" / "codex_oauth_auth.json"
            )
            oauth_path.parent.mkdir(parents=True, exist_ok=True)
            oauth_path.write_text(
                json.dumps(
                    {
                        "accounts": {
                            "acc-12345678": {"email": "fixture@example.test"}
                        }
                    }
                ),
                encoding="utf-8",
            )
            ctx = self._ctx(temp_home)
            ctx["app_mode"] = True
            ctx["credentials"] = {
                "orca_codex_auth": {
                    "tokens": {"account_id": "acc-12345678"}
                },
                # 不注入 codex_oauth_auth: 若实现读取磁盘 oauth 文件,
                # 唯一能拿到 email 的途径就是磁盘, 测试才能暴露违规读取
            }
            artifact = self.module.run(ctx)["artifact"]

        codex = self._codex_agent(artifact)
        self.assertEqual(codex["status"], "ok")
        self.assertIn("含 Orca 托管会话", codex["note"])
        self.assertNotIn(
            "账号 fixture",
            codex["note"],
            "App 模式不得读取 ~/.cc-switch/codex_oauth_auth.json 获取标签",
        )
        # 标签回落为注入 account_id 前缀, 不依赖磁盘
        self.assertIn("· 账号 acc-1234", codex["note"])

    def test_no_sessions_marks_codex_not_found(self):
        with tempfile.TemporaryDirectory() as temp_home:
            artifact = self.module.run(self._ctx(temp_home))["artifact"]

        codex = self._codex_agent(artifact)
        self.assertEqual(codex["status"], "not_found")
        self.assertEqual(codex["note"], "未发现会话记录")
        self.assertIsNone(codex["quota"])


class ParallelEquivalenceTests(unittest.TestCase):
    """并行采集与串行执行结果等价 (C1/C2 回归)."""

    NOW = "2026-07-28T12:00:00+08:00"

    class _SerialExecutor:
        """与 ThreadPoolExecutor 同接口的串行替身: submit 立即执行,
        map 退化为内置 map, 用于构造串行参照结果."""

        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def submit(self, fn, *args, **kwargs):
            class _Done:
                def __init__(self, value):
                    self._value = value

                def result(self):
                    return self._value

            return _Done(fn(*args, **kwargs))

        def map(self, fn, iterable):
            return map(fn, iterable)

    def setUp(self):
        self.module = load_module(
            "collect_usage_parallel_equiv_test",
            "agent-usage/collector/collect_usage.py",
        )

    def _build_fixture_home(self, temp_home):
        _write_rollout(
            Path(temp_home)
            / ".codex"
            / "sessions"
            / "rollout-cli.jsonl",
            [
                _token_count_record(
                    "2026-07-28T09:00:00+08:00",
                    rate_limits={
                        "plan_type": "plus",
                        "primary": {
                            "used_percent": 10,
                            "window_minutes": 300,
                            "resets_at": 1785000000,
                        },
                    },
                    usage={
                        "input_tokens": 1000,
                        "cached_input_tokens": 0,
                        "output_tokens": 100,
                    },
                )
            ],
            _ts("2026-07-28T11:45:00+08:00"),
        )
        _write_rollout(
            Path(temp_home)
            / "Library"
            / "Application Support"
            / "orca"
            / "codex-runtime-home"
            / "home"
            / "sessions"
            / "rollout-orca.jsonl",
            [
                _token_count_record(
                    "2026-07-28T11:00:00+08:00",
                    usage={
                        "input_tokens": 2000,
                        "cached_input_tokens": 0,
                        "output_tokens": 300,
                    },
                )
            ],
            _ts("2026-07-28T11:30:00+08:00"),
        )

    def _ctx(self, temp_home):
        return {
            "home": temp_home,
            "app_mode": True,
            "capabilities": ["localSessions", "localPricing", "externalQuotas"],
            "now": self.NOW,
            "timezone": "Asia/Shanghai",
            "days": 2,
            "credentials": {
                "codex_oauth_auth": {
                    "accounts": {
                        "acc-one-0001": {
                            "email": "one@example.test",
                            "refresh_token": "rt-one",
                        },
                        "acc-two-0002": {
                            "email": "two@example.test",
                            "refresh_token": "rt-two",
                        },
                    }
                },
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
                    "rate_limit": {
                        "primary_window": {
                            "limit_window_seconds": 18000,
                            "used_percent": 12,
                            "reset_at": 1785000000,
                        }
                    },
                }
            },
        }

    def test_parallel_collect_matches_serial_reference(self):
        original_refresh = self.module._codex_refresh
        self.module._codex_refresh = lambda token: {
            "access_token": "access-" + token,
            "refresh_token": "rotated-" + token,
        }
        original_executor = self.module.ThreadPoolExecutor
        try:
            with tempfile.TemporaryDirectory() as temp_home:
                self._build_fixture_home(temp_home)
                self.module.ThreadPoolExecutor = self._SerialExecutor
                try:
                    serial = self.module.run(self._ctx(temp_home))["artifact"]
                finally:
                    self.module.ThreadPoolExecutor = original_executor
                parallel = self.module.run(self._ctx(temp_home))["artifact"]
        finally:
            self.module._codex_refresh = original_refresh

        self.assertEqual(
            json.dumps(serial, sort_keys=True, ensure_ascii=False),
            json.dumps(parallel, sort_keys=True, ensure_ascii=False),
        )


if __name__ == "__main__":
    unittest.main()
