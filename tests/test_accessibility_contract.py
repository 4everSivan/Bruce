import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULES = ("agent-usage", "github", "gitlab")
SOURCE_WIDGETS = {
    module: REPO_ROOT / module / "widget" / "index.html"
    for module in MODULES
}
PACKAGED_WIDGETS = {
    module: (
        REPO_ROOT
        / "macos"
        / "MdddApp"
        / "Sources"
        / "MdddApp"
        / "Resources"
        / "Widgets"
        / module
        / "index.html"
    )
    for module in MODULES
}


def test_packaged_widgets_match_canonical_sources():
    for module in MODULES:
        assert PACKAGED_WIDGETS[module].read_text() == SOURCE_WIDGETS[
            module
        ].read_text()


def test_every_widget_has_reduced_motion_fallback():
    for path in SOURCE_WIDGETS.values():
        source = path.read_text()
        assert "prefers-reduced-motion: reduce" in source
        assert "transition: none" in source


def test_repository_heatmaps_have_keyboard_and_non_color_labels():
    for module in ("github", "gitlab"):
        source = SOURCE_WIDGETS[module].read_text()
        assert 'role="grid"' in source
        assert 'role="gridcell" tabindex="0" aria-label="' in source
        assert ":focus-visible" in source
        assert "强度 " in source


def test_host_state_matrix_is_live_and_textual():
    source = (
        REPO_ROOT
        / "macos"
        / "MdddApp"
        / "Sources"
        / "MdddApp"
        / "Resources"
        / "Widgets"
        / "host-bootstrap.js"
    ).read_text()
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
        assert f"{state}:" in source
    assert 'element.setAttribute("role", "status")' in source
    assert 'element.setAttribute("aria-live", "polite")' in source


def test_native_primary_actions_have_keyboard_and_accessibility_contracts():
    menu_bar = (
        REPO_ROOT
        / "macos"
        / "MdddApp"
        / "Sources"
        / "MdddApp"
        / "MenuBarViews.swift"
    ).read_text()
    settings = (
        REPO_ROOT
        / "macos"
        / "MdddApp"
        / "Sources"
        / "MdddApp"
        / "SettingsView.swift"
    ).read_text()
    assert '.keyboardShortcut("r", modifiers: .command)' in menu_bar
    assert 'accessibilityLabel("刷新\\(module.title)")' in menu_bar
    assert ".accessibilityValue(" in menu_bar
    assert "model.status(for: module).state.title" in menu_bar
    assert "NSAccessibility.post(" in settings
    assert 'accessibilityLabel("GitLab 个人访问令牌")' in settings
    assert 'accessibilityLabel("脱敏诊断 JSON 预览")' in settings


def test_visual_harness_supports_deterministic_state_matrix():
    harness = (
        REPO_ROOT / "tests" / "visual" / "widget_harness.html"
    ).read_text()
    assert 'params.get("variant")' in harness
    assert 'params.get("state")' in harness
    assert "host-bootstrap.js" in harness
    assert "prefers-reduced-motion" in harness
    script = re.search(r"<script>(.*)</script>", harness, flags=re.DOTALL)
    assert script is not None
    result = subprocess.run(
        ["node", "--check", "-"],
        input=script.group(1),
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
