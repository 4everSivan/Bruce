"""ZCode agent 会话扫描 (local_usage.scan_zcode, 只读 db) 契约测试.

覆盖: model_usage 逐请求用量 (时间精确分桶), input 含 cache 分量的扣减,
reasoning 并入 output, 模型名小写化, 项目/子代理归因, 窗口过滤,
零 token 行跳过, schema 不兼容诊断, db 缺失 not_found, _collect 接线.
"""

import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path
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


def _usage(started_ms, session_id="sess_a", model="GLM-5.3", inp=10000, out=200,
           reason=50, cache_read=5000, cache_creation=0):
    """构造 model_usage 计量行 (input_tokens 语义: 已含 cache 读/写分量)."""
    return {
        "session_id": session_id,
        "started_at": started_ms,
        "model": model,
        "inp": inp,
        "out": out,
        "reason": reason,
        "cache_read": cache_read,
        "cache_creation": cache_creation,
    }


def _make_zcode_db(path, usages, sessions=None):
    """构造 zcode db fixture (session + model_usage 最小 schema)."""
    if sessions is None:
        sessions = [("sess_a", "/Users/x/Bruce", "interactive")]
    db = sqlite3.connect(path)
    db.execute(
        "CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT, task_type TEXT)"
    )
    db.execute(
        "CREATE TABLE model_usage (id TEXT PRIMARY KEY, session_id TEXT,"
        " started_at INTEGER, model_id TEXT, input_tokens INTEGER DEFAULT 0,"
        " output_tokens INTEGER DEFAULT 0, reasoning_tokens INTEGER DEFAULT 0,"
        " cache_creation_input_tokens INTEGER DEFAULT 0,"
        " cache_read_input_tokens INTEGER DEFAULT 0)"
    )
    for sid, directory, task_type in sessions:
        db.execute(
            "INSERT INTO session (id, directory, task_type) VALUES (?,?,?)",
            (sid, directory, task_type),
        )
    for i, u in enumerate(usages):
        db.execute(
            "INSERT INTO model_usage (id, session_id, started_at, model_id,"
            " input_tokens, output_tokens, reasoning_tokens,"
            " cache_creation_input_tokens, cache_read_input_tokens)"
            " VALUES (?,?,?,?,?,?,?,?,?)",
            (
                "mu_%d" % i,
                u["session_id"],
                u["started_at"],
                u["model"],
                u["inp"],
                u["out"],
                u["reason"],
                u["cache_creation"],
                u["cache_read"],
            ),
        )
    db.commit()
    db.close()


class ScanZcodeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module(
            "local_usage_zcode_test", "agent-usage/collector/local_usage.py"
        )

    def setUp(self):
        _configure_runtime()

    def test_scan_collects_by_request_time(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            am = int(datetime(2026, 8, 9, 10, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            pm = int(datetime(2026, 8, 9, 15, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            _make_zcode_db(db, [
                _usage(am, inp=10000, out=200, reason=50, cache_read=5000),
                _usage(pm, inp=30000, out=400, reason=0, cache_read=20000),
            ])
            found = self.module.scan_zcode(agent, db)
        self.assertTrue(found)
        # input 含 cache: 总量 = (input-cache) + (output+reasoning) + cacheRead
        self.assertEqual(agent["_by_day"][NOW.strftime("%Y-%m-%d")]["total"], 40650)
        self.assertEqual(agent["_hours"][10], 10250)
        self.assertEqual(agent["_hours"][15], 30400)

    def test_cache_deducted_from_input(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            ts = int(NOW.timestamp() * 1000)
            _make_zcode_db(db, [
                _usage(ts, inp=10000, out=200, reason=50,
                       cache_read=6000, cache_creation=1000),
            ])
            found = self.module.scan_zcode(agent, db)
        self.assertTrue(found)
        b = agent["_by_day"][NOW.strftime("%Y-%m-%d")]
        self.assertEqual(b["input"], 3000)  # 10000 - 6000 - 1000
        self.assertEqual(b["output"], 250)  # 200 + reasoning 50
        self.assertEqual(b["cacheRead"], 6000)
        self.assertEqual(b["cacheCreation"], 1000)
        self.assertEqual(b["total"], 10250)

    def test_model_lowercased_and_project_attribution(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            ts = int(NOW.timestamp() * 1000)
            _make_zcode_db(db, [_usage(ts, model="GLM-5.3")])
            found = self.module.scan_zcode(agent, db)
        self.assertTrue(found)
        self.assertEqual(agent["_models_today"]["glm-5.3"]["total"], 10250)
        self.assertEqual(agent["_projects_today"]["Bruce"], 10250)

    def test_subagent_session_labeled(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            ts = int(NOW.timestamp() * 1000)
            _make_zcode_db(
                db,
                [_usage(ts, session_id="sess_sub")],
                sessions=[
                    ("sess_a", "/Users/x/Bruce", "interactive"),
                    ("sess_sub", "/Users/x/Bruce", "subagent_child"),
                ],
            )
            found = self.module.scan_zcode(agent, db)
        self.assertTrue(found)
        self.assertEqual(agent["_projects_today"]["Bruce ·子代理"], 10250)

    def test_zero_token_rows_skipped(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            ts = int(NOW.timestamp() * 1000)
            _make_zcode_db(db, [_usage(ts, inp=0, out=0, reason=0,
                                       cache_read=0, cache_creation=0)])
            found = self.module.scan_zcode(agent, db)
        # db 有计量行即视为发现; 全零行 (error/cancelled) 不产生用量
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_old_rows_outside_window_skipped(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            old = int((NOW - timedelta(days=30)).timestamp() * 1000)
            _make_zcode_db(db, [_usage(old)])
            found = self.module.scan_zcode(agent, db)
        # 窗口外计量行: 数据源可用但无窗口内用量
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_db_missing_returns_false(self):
        agent = self.module.make_agent("zcode", "ZCode")
        found = self.module.scan_zcode(agent, "/nonexistent/db.sqlite")
        self.assertFalse(found)

    def test_scan_schema_incompatible_is_diagnosable(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            conn = sqlite3.connect(db)
            conn.execute("CREATE TABLE other (x TEXT)")
            conn.commit()
            conn.close()
            found = self.module.scan_zcode(agent, db)
        self.assertFalse(found)
        self.assertEqual(agent["status"], "error")
        self.assertIn("schema", agent["note"])

    def test_scan_empty_db_returns_false(self):
        agent = self.module.make_agent("zcode", "ZCode")
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "db.sqlite")
            _make_zcode_db(db, [])
            found = self.module.scan_zcode(agent, db)
        self.assertFalse(found)
        self.assertEqual(agent["status"], "ok")


class ZcodeCollectWiringTests(unittest.TestCase):
    """_collect 中 zcode agent 的接线: 能力门禁与 db 缺失降级."""

    def setUp(self):
        self.module = load_module(
            "collect_usage_zcode_wiring", "agent-usage/collector/collect_usage.py"
        )
        self.module.runtime.set_http_overrides({})

    def tearDown(self):
        self.module.runtime.set_http_overrides({})

    def test_zcode_agent_built_in_collect(self):
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
        zcode = [a for a in agents if a["id"] == "zcode"]
        self.assertEqual(len(zcode), 1)
        self.assertEqual(zcode[0]["status"], "not_found")

    def test_zcode_agent_denied_without_local_sessions_capability(self):
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
        zcode = [a for a in agents if a["id"] == "zcode"][0]
        self.assertEqual(zcode["status"], "unavailable")
        self.assertIn("未授权", zcode["note"])

    def test_zcode_agent_reads_injected_db(self):
        with tempfile.TemporaryDirectory() as home:
            db = os.path.join(home, "db.sqlite")
            ts = int(NOW.timestamp() * 1000)
            _make_zcode_db(db, [_usage(ts, inp=10000, out=200, reason=50,
                                       cache_read=5000)])
            ctx = {
                "home": home,
                "now": "2026-08-09T15:00:00+08:00",
                "timezone": "Asia/Shanghai",
                "days": 14,
                "paths": {"zcode_db": db},
                "http": {},
            }
            self.module._configure_runtime(ctx)
            agents = self.module._collect(self.module._ACTIVE_RUN_CONTEXT)["agents"]
        zcode = [a for a in agents if a["id"] == "zcode"][0]
        self.assertEqual(zcode["status"], "ok")
        # (10000-5000) + (200+50) + 5000 cacheRead
        self.assertEqual(zcode["today"]["total"], 10250)


if __name__ == "__main__":
    unittest.main()
