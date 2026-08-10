"""OpenCode agent 会话扫描 (local_usage.scan_opencode, 只读 db) 契约测试.

覆盖: message 表逐消息用量 (时间精确分桶), token/模型解析,
窗口过滤, schema 不兼容诊断, db 缺失 not_found, _collect 接线.
"""

import importlib.util
import json
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

REPO_ROOT = Path(__file__).resolve().parents[1]
COLLECTOR_DIR = REPO_ROOT / "agent-usage" / "collector"
sys.path.insert(0, str(COLLECTOR_DIR))

import runtime  # noqa: E402


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


NOW = datetime(2026, 8, 9, 15, 0, 0, tzinfo=ZoneInfo("Asia/Shanghai"))


def _configure_runtime(now=None):
    now = now or NOW
    runtime.set_timezone(now.tzinfo)
    runtime.set_date_buckets(
        now.strftime("%Y-%m-%d"),
        (now.timestamp() - 15 * 86400),
        [(now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(13, -1, -1)],
    )


def _msg(created_ms, role="assistant", model="deepseek-v4-flash", inp=1000, out=200,
         reason=50, cache_read=5000, cache_write=10):
    """构造 opencode message.data JSON (assistant 带 tokens)."""
    d = {
        "role": role,
        "modelID": model,
        "providerID": "opencode-go",
        "time": {"created": created_ms},
    }
    if role == "assistant":
        d["tokens"] = {
            "total": inp + out + reason + cache_read + cache_write,
            "input": inp,
            "output": out,
            "reasoning": reason,
            "cache": {"read": cache_read, "write": cache_write},
        }
        d["cost"] = 0.001
    return json.dumps(d, ensure_ascii=False)


def _make_opencode_db(path, messages):
    """构造 opencode.db fixture (message 表 + 指定消息)."""
    db = sqlite3.connect(path)
    db.execute(
        "CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, "
        "time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, "
        "data TEXT NOT NULL)"
    )
    for i, data in enumerate(messages):
        db.execute(
            "INSERT INTO message (id, session_id, time_created, time_updated, data) "
            "VALUES (?,?,?,?,?)",
            ("msg_%d" % i, "ses_x", int(NOW.timestamp() * 1000),
             int(NOW.timestamp() * 1000), data),
        )
    db.commit()
    db.close()


class ScanOpencodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module(
            "local_usage_opencode_test", "agent-usage/collector/local_usage.py"
        )

    def setUp(self):
        _configure_runtime()

    def test_scan_collects_by_message_time(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            # 上午一条, 下午一条 (相同会话, 不同时刻)
            am = int(datetime(2026, 8, 9, 10, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            pm = int(datetime(2026, 8, 9, 15, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            _make_opencode_db(db, [
                _msg(am, inp=1000, out=200),
                _msg(pm, inp=3000, out=400),
            ])
            found = self.module.scan_opencode(agent, db)
        self.assertTrue(found)
        # 总量 = 两条消息 (各自 input+output+reasoning+cacheRead+cacheWrite)
        self.assertEqual(agent["_by_day"][NOW.strftime("%Y-%m-%d")]["total"], 14720)
        # 上午消息落在 10 点时段, 下午消息落在 15 点时段
        self.assertEqual(agent["_hours"][10], 6260)
        self.assertEqual(agent["_hours"][15], 8460)

    def test_scan_models_and_fields(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            ts = int(NOW.timestamp() * 1000)
            _make_opencode_db(db, [
                _msg(ts, model="gpt-5", inp=100, out=50, reason=0, cache_read=0, cache_write=0),
            ])
            found = self.module.scan_opencode(agent, db)
        self.assertTrue(found)
        self.assertEqual(agent["_models_today"]["gpt-5"]["total"], 150)
        self.assertEqual(agent["_models_today"]["gpt-5"]["input"], 100)
        self.assertEqual(agent["_models_today"]["gpt-5"]["output"], 50)

    def test_scan_user_messages_ignored(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            ts = int(NOW.timestamp() * 1000)
            _make_opencode_db(db, [
                _msg(ts, role="user"),  # 无 tokens, 不产生用量
            ])
            found = self.module.scan_opencode(agent, db)
        # db 有消息即视为发现; user 消息不产生用量
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_old_messages_outside_window_skipped(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            old = int((NOW - timedelta(days=30)).timestamp() * 1000)
            _make_opencode_db(db, [_msg(old)])
            found = self.module.scan_opencode(agent, db)
        # 窗口外消息: 数据源有会话但无窗口内用量 -> found=True, 不计入
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_db_missing_returns_false(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        found = self.module.scan_opencode(agent, "/nonexistent/opencode.db")
        self.assertFalse(found)

    def test_scan_schema_incompatible_is_diagnosable(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE other (x TEXT)")
            conn.commit()
            conn.close()
            found = self.module.scan_opencode(agent, db)
        self.assertFalse(found)
        self.assertEqual(agent["status"], "error")
        self.assertIn("schema", agent["note"])

    def test_scan_empty_db_returns_false(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            _make_opencode_db(db, [])
            found = self.module.scan_opencode(agent, db)
        self.assertFalse(found)
        self.assertEqual(agent["status"], "ok")


class OpenCodeCollectWiringTests(unittest.TestCase):
    """_collect 中 opencode agent 的接线: 能力门禁与 db 缺失降级."""

    def setUp(self):
        self.module = load_module(
            "collect_usage_opencode_wiring", "agent-usage/collector/collect_usage.py"
        )
        self.module.runtime.set_http_overrides({})

    def tearDown(self):
        self.module.runtime.set_http_overrides({})

    def test_opencode_agent_built_in_collect(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = {
                "home": home,
                "now": "2026-08-09T15:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "days": 14,
                "http": {},
            }
            self.module._configure_runtime(ctx)
            agents = self.module._collect(self.module._ACTIVE_RUN_CONTEXT)["agents"]
        opencode = [a for a in agents if a["id"] == "opencode"]
        self.assertEqual(len(opencode), 1)
        self.assertEqual(opencode[0]["status"], "not_found")

    def test_opencode_agent_denied_without_local_sessions_capability(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = {
                "home": home,
                "now": "2026-08-09T15:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "days": 14,
                "capabilities": {"externalQuotas"},
                "http": {},
            }
            self.module._configure_runtime(ctx)
            agents = self.module._collect(self.module._ACTIVE_RUN_CONTEXT)["agents"]
        opencode = [a for a in agents if a["id"] == "opencode"][0]
        self.assertEqual(opencode["status"], "unavailable")
        self.assertIn("未授权", opencode["note"])

    def test_opencode_agent_reads_injected_db(self):
        with tempfile.TemporaryDirectory() as home:
            db = os.path.join(home, "opencode.db")
            ts = int(NOW.timestamp() * 1000)
            _make_opencode_db(db, [_msg(ts, inp=100, out=50)])
            ctx = {
                "home": home,
                "now": "2026-08-09T15:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "days": 14,
                "paths": {"opencode_db": db},
                "http": {},
            }
            self.module._configure_runtime(ctx)
            agents = self.module._collect(self.module._ACTIVE_RUN_CONTEXT)["agents"]
        opencode = [a for a in agents if a["id"] == "opencode"][0]
        self.assertEqual(opencode["status"], "ok")
        # input+output+reasoning (默认 cache 5000+10 也计入 total)
        self.assertEqual(opencode["today"]["total"], 5210)


if __name__ == "__main__":
    unittest.main()
