import importlib.util
import unittest
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


if __name__ == "__main__":
    unittest.main()
