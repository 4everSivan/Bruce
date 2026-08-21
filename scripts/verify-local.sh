#!/bin/zsh

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_SWIFT_PACKAGE="$BRUCE_REPO_ROOT/macos/BruceApp"
BRUCE_BRIDGE="$BRUCE_REPO_ROOT/bridge/run_bridge.py"
BRUCE_PYTHON_BIN=${BRUCE_PYTHON_BIN:-$(command -v python3)}

cd "$BRUCE_REPO_ROOT"

echo "检查 Python 语法"
"$BRUCE_PYTHON_BIN" - <<'PY'
import ast
from pathlib import Path

paths = sorted(Path(".").glob("*/collector/*.py"))
paths.extend(sorted(Path("bridge").glob("*.py")))
for path in paths:
    ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
print("Python syntax passed:", len(paths))
PY

echo "运行 Python 契约、schema、Widget 与安全测试"
"$BRUCE_PYTHON_BIN" -m pytest -q

echo "构建 Swift 应用与全部 Harness"
swift build --package-path "$BRUCE_SWIFT_PACKAGE"

echo "运行 Onboarding Core Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" BruceOnboardingCoreHarness

echo "运行 PanelViewModel Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" PanelViewModelHarness

echo "运行 ArtifactStore Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  ArtifactStoreHarness "$BRUCE_REPO_ROOT"

echo "运行 CollectorRunner Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  CollectorRunnerHarness "$BRUCE_PYTHON_BIN" "$BRUCE_BRIDGE"

echo "运行 RefreshScheduler Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  RefreshSchedulerHarness "$BRUCE_REPO_ROOT"

echo "运行 NativeLifecycle Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" NativeLifecycleHarness

echo "运行 Diagnostics Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" DiagnosticsHarness

echo "运行隔离的本地集成 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  LocalIntegrationHarness \
  "$BRUCE_REPO_ROOT" \
  "$BRUCE_PYTHON_BIN" \
  "$BRUCE_BRIDGE"

echo "运行 DeepSeek 月度账本 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  DeepSeekUsageLedgerHarness

echo "运行订阅凭证注入 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" SubscriptionCredentialsHarness

echo "运行全局快捷键 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" GlobalHotkeyHarness

echo "运行 AppModel 缓存 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" AppModelCacheHarness

echo "运行 Dashboard 玻璃材质矩阵 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" DashboardGlassSurfaceHarness

echo "运行订阅刷新控件 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" SubscriptionRefreshControlHarness

echo "Bruce 本地验证全部通过"
