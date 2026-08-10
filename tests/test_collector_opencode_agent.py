"""OpenCode agent 会话扫描 (local_usage.scan_opencode, 只读 db) 契约测试.

覆盖: session 表读取, token/模型/时间分桶, schema 不兼容诊断,
db 缺失 not_found, _collect 接线 (能力门禁).
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


def _configure_runtime():
    runtime.set_timezone(NOW.tzinfo)
    runtime.set_date_buckets(
        NOW.strftime("%Y-%m-%d"),
        (NOW.timestamp() - 15 * 86400),
        [(NOW - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(13, -1, -1)],
    )


def _make_opencode_db(path, rows):
    """构造 opencode.db fixture (session 表 + 指定行)."""
    db = sqlite3.connect(path)
    db.execute(
        "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, "
        "directory TEXT, title TEXT, cost REAL DEFAULT 0, "
        "tokens_input INTEGER DEFAULT 0, tokens_output INTEGER DEFAULT 0, "
        "tokens_reasoning INTEGER DEFAULT 0, "
        "tokens_cache_read INTEGER DEFAULT 0, tokens_cache_write INTEGER DEFAULT 0, "
        "model TEXT, time_created INTEGER, time_updated INTEGER)"
    )
    for row in rows:
        if len(row) == 7:
            row = row + (None,)
        db.execute(
            "INSERT INTO session (id, model, tokens_input, tokens_output, "
            "tokens_cache_read, tokens_cache_write, time_created, directory) "
            "VALUES (?,?,?,?,?,?,?,?)",
            row,
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

    def test_scan_collects_today_usage(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            _make_opencode_db(db, [
                ("ses_x", json.dumps({"id": "deepseek-v4-flash", "providerID": "opencode-go"}),
                 1000, 200, 5000, 10, int(NOW.timestamp() * 1000), "/proj/mddd"),
            ])
            found = self.module.scan_opencode(agent, db)
        self.assertTrue(found)
        self.assertEqual(agent["_by_day"][NOW.strftime("%Y-%m-%d")]["total"], 6210)
        self.assertEqual(agent["_models_today"]["deepseek-v4-flash"]["total"], 6210)
        # 项目名取目录末段
        self.assertEqual(agent["_projects_today"], {"mddd": 6210})

    def test_scan_model_missing_falls_back_to_opencode(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            _make_opencode_db(db, [
                ("ses_x", None, 100, 50, 0, 0, int(NOW.timestamp() * 1000)),
            ])
            found = self.module.scan_opencode(agent, db)
        self.assertTrue(found)
        self.assertEqual(agent["_models_today"]["opencode"]["total"], 150)

    def test_scan_old_sessions_outside_window_skipped(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "opencode.db")
            _make_opencode_db(db, [
                ("ses_old", None, 100, 50, 0, 0,
                 int((NOW - timedelta(days=30)).timestamp() * 1000), "/proj/old"),
            ])
            found = self.module.scan_opencode(agent, db)
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_db_missing_returns_false(self):
        agent = self.module.make_agent("opencode", "OpenCode")
        found = self.module.scan_opencode(
            agent, "/nonexistent/opencode.db"
        )
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
            # 临时 home 无 opencode.db -> opencode agent not_found, 不影响其他
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
        from unittest import mock as _mock
        with tempfile.TemporaryDirectory() as home:
            db = os.path.join(home, "opencode.db")
            _make_opencode_db(db, [
                ("ses_x", None, 100, 50, 0, 0, int(NOW.timestamp() * 1000)),
            ])
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
        self.assertEqual(opencode["today"]["total"], 150)


if __name__ == "__main__":
    unittest.main()
