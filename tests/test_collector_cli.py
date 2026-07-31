import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COLLECTORS = {
    "agent-usage": "agent-usage/collector/collect_usage.py",
}


def cli_args(module_name, *extra):
    args = []
    args.extend(extra)
    return args


def load_module(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CollectorCliCompatibilityTests(unittest.TestCase):
    def test_out_writes_compatible_artifact_envelope_atomically(self):
        for index, (module_name, relative_path) in enumerate(COLLECTORS.items()):
            with self.subTest(module=module_name):
                collector = load_module(
                    "collector_cli_out_%s_%d"
                    % (module_name.replace("-", "_"), index),
                    relative_path,
                )
                expected = json.loads(
                    (
                        REPO_ROOT
                        / "tests"
                        / "fixtures"
                        / "artifacts"
                        / module_name
                        / "valid.json"
                    ).read_text(encoding="utf-8")
                )

                with tempfile.TemporaryDirectory() as temp_dir:
                    output_path = Path(temp_dir) / "nested" / "artifact.json"
                    stdout = io.StringIO()
                    with contextlib.redirect_stdout(stdout):
                        collector.main(
                            cli_args(
                                module_name,
                                "--out",
                                str(output_path),
                            ),
                            run_func=lambda _ctx, value=expected: value,
                        )

                    self.assertEqual(
                        json.loads(output_path.read_text(encoding="utf-8")),
                        expected,
                    )
                    self.assertFalse(Path(str(output_path) + ".tmp").exists())
                    self.assertEqual(
                        stdout.getvalue().strip(),
                        "written: %s" % output_path,
                    )

    def test_stdout_is_one_compatible_json_document(self):
        expected = {"artifact": {"generatedAt": "2026-07-28T12:00:00+08:00"}}
        for index, (module_name, relative_path) in enumerate(COLLECTORS.items()):
            with self.subTest(module=module_name):
                collector = load_module(
                    "collector_cli_stdout_%s_%d"
                    % (module_name.replace("-", "_"), index),
                    relative_path,
                )
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    collector.main(
                        cli_args(module_name),
                        run_func=lambda _ctx: expected,
                    )

                self.assertEqual(json.loads(stdout.getvalue()), expected)


if __name__ == "__main__":
    unittest.main()
