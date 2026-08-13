"""Pi 会话扫描 (local_usage.scan_pi) 契约测试.

覆盖: 字段映射 (reasoning 并入 output, cacheWrite→cacheCreation),
message.timestamp 毫秒分桶, 顶层 ISO 回退, cwd 项目提取, 忽略规则,
窗口过滤, 目录缺失, UTC 跨日边界.
"""

import importlib.util
import json
import os
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
CWD = "/Users/sivan/orca/workspaces/dbops/前端仪表盘"


def _configure_runtime(now=None, tz=None):
    now = now or NOW
    tz = tz or now.tzinfo
    runtime.set_timezone(tz)
    runtime.set_date_buckets(
        now.strftime("%Y-%m-%d"),
        (now.timestamp() - 15 * 86400),
        [(now - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(13, -1, -1)],
    )


def _session_record(cwd=CWD):
    return json.dumps(
        {
            "type": "session",
            "version": 1,
            "id": "s1",
            "timestamp": "2026-08-12T06:34:55.363Z",
            "cwd": cwd,
        },
        ensure_ascii=False,
    )


def _assistant_msg(ts_ms, model="deepseek-v4-flash", inp=100, out=200,
                   reason=50, cache_read=5000, cache_write=10,
                   top_ts="2026-08-12T06:34:55.363Z"):
    """构造 Pi assistant message 记录; ts_ms=None 时省略 message.timestamp
    (测试顶层 ISO 回退)."""
    msg = {
        "role": "assistant",
        "content": [{"type": "text", "text": "ok"}],
        "provider": "opencode-go",
        "model": model,
        "usage": {
            "input": inp,
            "output": out,
            "cacheRead": cache_read,
            "cacheWrite": cache_write,
            "reasoning": reason,
            "totalTokens": inp + out + reason + cache_read + cache_write,
            "cost": {"total": 0.001},
        },
    }
    if ts_ms is not None:
        msg["timestamp"] = ts_ms
    return json.dumps(
        {
            "type": "message",
            "id": "m1",
            "parentId": "p1",
            "timestamp": top_ts,
            "message": msg,
        },
        ensure_ascii=False,
    )


def _user_msg():
    return json.dumps(
        {
            "type": "message",
            "id": "m2",
            "parentId": "p1",
            "timestamp": "2026-08-12T06:34:55.363Z",
            "message": {"role": "user", "content": [{"type": "text", "text": "hi"}],
                        "timestamp": 1786516727556},
        },
        ensure_ascii=False,
    )


def _write_jsonl(path, lines, mtime=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


class ScanPiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.module = load_module("local_usage_pi_test",
                                 "agent-usage/collector/local_usage.py")

    def setUp(self):
        _configure_runtime()

    def test_scan_collects_assistant_usage_by_message_timestamp(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            am = int(datetime(2026, 8, 9, 10, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            pm = int(datetime(2026, 8, 9, 15, 0, 0, tzinfo=NOW.tzinfo).timestamp() * 1000)
            _write_jsonl(root / "proj-a" / "s.jsonl", [
                _session_record(),
                _assistant_msg(am),
                _assistant_msg(pm),
            ])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        today = agent["_by_day"][NOW.strftime("%Y-%m-%d")]
        self.assertEqual(today["total"], 2 * 5360)
        self.assertEqual(agent["_hours"][10], 5360)
        self.assertEqual(agent["_hours"][15], 5360)

    def test_scan_field_mapping_reasoning_into_output(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            ts = int(NOW.timestamp() * 1000)
            _write_jsonl(root / "proj-a" / "s.jsonl",
                         [_session_record(), _assistant_msg(ts)])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        b = agent["_models_today"]["deepseek-v4-flash"]
        self.assertEqual(b["input"], 100)
        self.assertEqual(b["output"], 250)  # output 200 + reasoning 50
        self.assertEqual(b["cacheRead"], 5000)
        self.assertEqual(b["cacheCreation"], 10)  # cacheWrite 10
        self.assertEqual(b["total"], 5360)

    def test_scan_project_from_session_cwd_basename(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            ts = int(NOW.timestamp() * 1000)
            _write_jsonl(root / "proj-a" / "s.jsonl",
                         [_session_record(), _assistant_msg(ts)])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        self.assertEqual(agent["_projects_today"].get("前端仪表盘"), 5360)

    def test_scan_ignores_user_and_usage_missing(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            _write_jsonl(root / "proj-a" / "s.jsonl",
                         [_session_record(), _user_msg()])
            found = self.module.scan_pi(agent, root)
        # 有窗口内文件: found=True; 无 assistant usage: 不计入
        self.assertTrue(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_corrupted_line_skipped(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            ts = int(NOW.timestamp() * 1000)
            _write_jsonl(root / "proj-a" / "s.jsonl", [
                _session_record(),
                '{"type": "message", broken',
                _assistant_msg(ts),
            ])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        today = agent["_by_day"][NOW.strftime("%Y-%m-%d")]
        self.assertEqual(today["total"], 5360)

    def test_scan_missing_header_project_is_none(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            ts = int(NOW.timestamp() * 1000)
            _write_jsonl(root / "proj-a" / "s.jsonl", [_assistant_msg(ts)])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        today = agent["_by_day"][NOW.strftime("%Y-%m-%d")]
        self.assertEqual(today["total"], 5360)
        self.assertNotIn("前端仪表盘", agent["_projects_today"])

    def test_scan_timestamp_fallback_to_top_level_iso(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            top_ts = NOW.isoformat(timespec="seconds")
            _write_jsonl(root / "proj-a" / "s.jsonl", [
                _session_record(),
                _assistant_msg(None, top_ts=top_ts),
            ])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        today = agent["_by_day"][NOW.strftime("%Y-%m-%d")]
        self.assertEqual(today["total"], 5360)

    def test_scan_missing_root_returns_false(self):
        agent = self.module.make_agent("pi", "Pi")
        found = self.module.scan_pi(agent, "/nonexistent/pi-sessions")
        self.assertFalse(found)

    def test_scan_outside_window_files_skipped(self):
        agent = self.module.make_agent("pi", "Pi")
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            ts = int(NOW.timestamp() * 1000)
            old_mtime = (NOW - timedelta(days=30)).timestamp()
            _write_jsonl(root / "proj-a" / "s.jsonl",
                         [_session_record(), _assistant_msg(ts)],
                         mtime=old_mtime)
            found = self.module.scan_pi(agent, root)
        self.assertFalse(found)
        self.assertEqual(dict(agent["_by_day"]), {})

    def test_scan_utc_cross_day_bucket(self):
        # UTC 配置下, 本地 (上海) 已跨日的时刻应落在 UTC 当天的桶
        utc_now = datetime(2026, 8, 9, 15, 0, 0, tzinfo=ZoneInfo("UTC"))
        _configure_runtime(now=utc_now, tz=ZoneInfo("UTC"))
        agent = self.module.make_agent("pi", "Pi")
        # 2026-08-09 15:30 UTC = 上海 08-09 23:30; 08-09 16:30 UTC = 上海 08-10 00:30
        shanghai_border = int(datetime(2026, 8, 9, 16, 30, 0,
                                       tzinfo=ZoneInfo("UTC")).timestamp() * 1000)
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "sessions"
            _write_jsonl(root / "proj-a" / "s.jsonl",
                         [_session_record(), _assistant_msg(shanghai_border)])
            found = self.module.scan_pi(agent, root)
        self.assertTrue(found)
        # 按 UTC 分桶: 该时刻在上海已是 08-10 00:30, 若误用上海时区分桶
        # 会超出 TODAY 被 record_usage 丢弃 (day > TODAY 分支), 08-09 桶应为 0
        self.assertEqual(agent["_by_day"]["2026-08-09"]["total"], 5360)


if __name__ == "__main__":
    unittest.main()
