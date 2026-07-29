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


class ContributionAggregationTests(unittest.TestCase):
    def setUp(self):
        self.github = load_module(
            "collect_github_aggregation_test",
            "github/collector/collect_github.py",
        )
        self.gitlab = load_module(
            "collect_gitlab_aggregation_test",
            "gitlab/collector/collect_gitlab.py",
        )

    def test_github_streak_allows_today_to_be_empty(self):
        days = [
            ("2026-07-24", 1),
            ("2026-07-25", 2),
            ("2026-07-26", 0),
            ("2026-07-27", 3),
            ("2026-07-28", 0),
        ]
        payload = {
            "data": {
                "viewer": {
                    "login": "fixture-user",
                    "contributionsCollection": {
                        "contributionCalendar": {
                            "totalContributions": 6,
                            "weeks": [
                                {
                                    "contributionDays": [
                                        {
                                            "date": date,
                                            "contributionCount": count,
                                            "contributionLevel": (
                                                "FIRST_QUARTILE"
                                                if count
                                                else "NONE"
                                            ),
                                            "weekday": index,
                                        }
                                        for index, (date, count) in enumerate(days)
                                    ]
                                }
                            ],
                        }
                    },
                }
            }
        }
        artifact = self.github.build_artifact(
            payload,
            datetime.fromisoformat("2026-07-28T12:00:00+08:00"),
        )
        self.assertEqual(artifact["today"], 0)
        self.assertEqual(artifact["currentStreak"], 1)
        self.assertEqual(artifact["longestStreak"], 2)
        self.assertEqual(artifact["bestDay"], {"date": "2026-07-27", "count": 3})

    def test_gitlab_event_timestamp_uses_configured_timezone(self):
        shanghai = self.gitlab.ZoneInfo("Asia/Shanghai")
        self.assertEqual(
            self.gitlab._event_date("2026-07-27T16:30:00Z", shanghai),
            "2026-07-28",
        )
        self.assertEqual(self.gitlab.bucket(0), 0)
        self.assertEqual(self.gitlab.bucket(2), 1)
        self.assertEqual(self.gitlab.bucket(5), 2)
        self.assertEqual(self.gitlab.bucket(9), 3)
        self.assertEqual(self.gitlab.bucket(10), 4)


if __name__ == "__main__":
    unittest.main()
