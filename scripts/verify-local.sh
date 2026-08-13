#!/bin/zsh

set -euo pipefail

MDDD_SCRIPT_DIR=${0:A:h}
MDDD_REPO_ROOT=${MDDD_SCRIPT_DIR:h}
MDDD_SWIFT_PACKAGE="$MDDD_REPO_ROOT/macos/MdddApp"
MDDD_BRIDGE="$MDDD_REPO_ROOT/bridge/run_bridge.py"
MDDD_PYTHON_BIN=${MDDD_PYTHON_BIN:-$(command -v python3)}

cd "$MDDD_REPO_ROOT"

echo "检查 Python 语法"
"$MDDD_PYTHON_BIN" - <<'PY'
import ast
from pathlib import Path

paths = sorted(Path(".").glob("*/collector/*.py"))
paths.extend(sorted(Path("bridge").glob("*.py")))
for path in paths:
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print("Python syntax passed:", len(paths))
PY

echo "运行 Python 契约、schema、Widget 与安全测试"
"$MDDD_PYTHON_BIN" -m pytest -q

echo "构建 Swift 应用与全部 Harness"
swift build --package-path "$MDDD_SWIFT_PACKAGE"

echo "运行 Onboarding Core Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" MdddOnboardingCoreHarness

echo "运行 PanelViewModel Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" PanelViewModelHarness

echo "运行 ArtifactStore Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" \
  ArtifactStoreHarness "$MDDD_REPO_ROOT"

echo "运行 CollectorRunner Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" \
  CollectorRunnerHarness "$MDDD_PYTHON_BIN" "$MDDD_BRIDGE"

echo "运行 RefreshScheduler Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" \
  RefreshSchedulerHarness "$MDDD_REPO_ROOT"

echo "运行 NativeLifecycle Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" NativeLifecycleHarness

echo "运行 Diagnostics Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" DiagnosticsHarness

echo "运行隔离的本地集成 Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" \
  LocalIntegrationHarness \
  "$MDDD_REPO_ROOT" \
  "$MDDD_PYTHON_BIN" \
  "$MDDD_BRIDGE"

echo "运行 DeepSeek 月度账本 Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" \
  DeepSeekUsageLedgerHarness

echo "运行订阅凭证注入 Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" SubscriptionCredentialsHarness

echo "运行全局快捷键 Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" GlobalHotkeyHarness

echo "运行 AppModel 缓存 Harness"
swift run --package-path "$MDDD_SWIFT_PACKAGE" AppModelCacheHarness

echo "mddd 本地验证全部通过"
