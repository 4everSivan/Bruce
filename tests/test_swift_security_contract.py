from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
APP_CORE = (
    REPO_ROOT / "macos" / "MdddApp" / "Sources" / "MdddAppCore"
)


def test_collector_subprocess_uses_an_environment_allowlist():
    source = (APP_CORE / "CollectorRunner.swift").read_text()
    launch_start = source.index("process.executableURL = executableURL")
    launch_end = source.index("process.standardInput = stdinPipe")
    launch = source[launch_start:launch_end]
    assert "process.environment = [" in launch
    assert '"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"' in launch
    assert '"LANG": "en_US.UTF-8"' in launch
    assert '"LC_ALL": "en_US.UTF-8"' in launch
    assert '"TMPDIR": FileManager.default.temporaryDirectory.path' in launch
    assert "ProcessInfo.processInfo.environment" not in launch


def test_diagnostics_model_never_declares_business_or_identity_fields():
    source = (APP_CORE / "Diagnostics.swift").read_text()
    report_start = source.index("private struct DiagnosticApplication")
    report_end = source.index("package enum DiagnosticExportError")
    report_models = source[report_start:report_end].lower()
    for forbidden in (
        "artifact",
        "credential",
        "token",
        "email",
        "repository",
        "hostname",
        "baseurl",
        "filepath",
    ):
        assert forbidden not in report_models


def test_diagnostics_archive_is_reexpanded_and_allowlisted_before_publish():
    source = (APP_CORE / "Diagnostics.swift").read_text()
    assert "try archiver.expand(" in source
    assert "try validateExpandedArchive(at: verificationURL)" in source
    assert '"mddd-diagnostics/README.txt"' in source
    assert '"mddd-diagnostics/report.json"' in source
    assert "isSymbolicLink" in source
