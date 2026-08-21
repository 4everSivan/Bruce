import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from bridge.run_bridge import execute_request


RUN_ID = "12345678-1234-4234-9234-123456789abc"


def bridge_request():
    return {
        "schemaVersion": 1,
        "runId": RUN_ID,
        "module": "agent-usage",
        "timeouts": {
            "localScanSeconds": 30,
            "externalRequestSeconds": 10,
            "moduleSeconds": 90,
        },
        "context": {},
        "credentials": {},
    }


class BridgeMetricsTests(unittest.TestCase):
    def test_metrics_are_opt_in_and_do_not_change_response(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            metrics_path = Path(temp_dir) / "metrics.json"
            with mock.patch.dict(
                os.environ,
                {"BRUCE_COLLECTOR_METRICS_PATH": str(metrics_path)},
                clear=False,
            ):
                response = execute_request(
                    bridge_request(),
                    collector_overrides={
                        "agent-usage": lambda _ctx: {
                            "artifact": {"agents": [], "services": []}
                        }
                    },
                )

            metrics = json.loads(metrics_path.read_text(encoding="utf-8"))

        self.assertEqual(response["status"], "success")
        self.assertNotIn("metrics", response)
        self.assertNotIn("_metrics", response["artifact"])
        self.assertEqual(metrics["implementation"], "python")
        self.assertEqual(metrics["status"], "success")
        self.assertIn("bridge.validate", metrics["phases_ms"])
        self.assertIn("collector.execute", metrics["phases_ms"])
        self.assertEqual(metrics["disk_read_scope"], "logical_source_bytes")
        self.assertIn("physical_disk_read_bytes", metrics)
        self.assertEqual(metrics["http_request_count"], 0)
        self.assertEqual(metrics["credential_refresh_count"], 0)
        self.assertNotIn("access_token", json.dumps(metrics))

    def test_metrics_write_failure_cannot_break_collection(self):
        with mock.patch.dict(
            os.environ,
            {"BRUCE_COLLECTOR_METRICS_PATH": "/dev/null/metrics.json"},
            clear=False,
        ):
            response = execute_request(
                bridge_request(),
                collector_overrides={
                    "agent-usage": lambda _ctx: {
                        "artifact": {"agents": [], "services": []}
                    }
                },
            )

        self.assertEqual(response["status"], "success")

    def test_metrics_are_disabled_by_default(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            metrics_path = Path(temp_dir) / "metrics.json"
            with mock.patch.dict(os.environ, {}, clear=True):
                response = execute_request(
                    bridge_request(),
                    collector_overrides={
                        "agent-usage": lambda _ctx: {
                            "artifact": {"agents": [], "services": []}
                        }
                    },
                )

            self.assertEqual(response["status"], "success")
            self.assertFalse(metrics_path.exists())


if __name__ == "__main__":
    unittest.main()
