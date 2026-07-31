import re
import subprocess
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULES = ("agent-usage",)


class WidgetSecurityTests(unittest.TestCase):
    def test_widgets_block_network_and_have_no_native_message_channel(self):
        for module in MODULES:
            with self.subTest(module=module):
                html = (
                    REPO_ROOT / module / "widget" / "index.html"
                ).read_text(encoding="utf-8")
                self.assertIn("connect-src 'none'", html)
                self.assertIn("object-src 'none'", html)
                self.assertNotIn("fetch(", html)
                self.assertNotIn("XMLHttpRequest", html)
                self.assertNotIn("WebSocket", html)
                self.assertNotIn("webkit.messageHandlers", html)

    def test_dynamic_strings_are_escaped_or_rendered_as_text(self):
        agent = (
            REPO_ROOT / "agent-usage" / "widget" / "index.html"
        ).read_text(encoding="utf-8")
        self.assertIn("function esc(value)", agent)
        for unsafe_expression in (
            "+ lead.name +",
            "+ a.name +",
            "+ entry.name +",
            "+ entry.plan +",
            "+ entry.extra +",
            "+ s.name +",
            "+ m.model +",
            "+ p.name +",
        ):
            self.assertNotIn(unsafe_expression, agent)

    def test_host_states_use_text_content_and_cover_required_conditions(self):
        bootstrap = (
            REPO_ROOT / "tests" / "visual" / "host-bootstrap.js"
        ).read_text(encoding="utf-8")
        for state in (
            "loading",
            "refreshing",
            "stale",
            "authRequired",
            "offline",
            "partial",
            "error",
            "notConfigured",
        ):
            self.assertRegex(bootstrap, r"\b%s:" % state)
        self.assertIn("element.textContent = label", bootstrap)
        self.assertNotIn("innerHTML", bootstrap)
        self.assertNotIn("webkit.messageHandlers", bootstrap)

    def test_all_widget_javascript_parses(self):
        scripts = []
        for module in MODULES:
            html = (
                REPO_ROOT / module / "widget" / "index.html"
            ).read_text(encoding="utf-8")
            scripts.extend(
                re.findall(
                    r"<script(?:\s[^>]*)?>(.*?)</script>",
                    html,
                    flags=re.DOTALL | re.IGNORECASE,
                )
            )
        scripts.append(
            (
                REPO_ROOT / "tests" / "visual" / "host-bootstrap.js"
            ).read_text(encoding="utf-8")
        )
        for index, script in enumerate(scripts):
            with self.subTest(script=index):
                result = subprocess.run(
                    ["node", "--check", "-"],
                    input=script,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
