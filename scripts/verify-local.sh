#!/bin/zsh

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_SWIFT_PACKAGE="$BRUCE_REPO_ROOT/macos/BruceApp"
BRUCE_RUST_MANIFEST="$BRUCE_REPO_ROOT/rust/Bruce-collector/Cargo.toml"
BRUCE_RUST_BIN=${BRUCE_RUST_BIN:-$BRUCE_REPO_ROOT/rust/Bruce-collector/target/debug/Bruce-collector}

cd "$BRUCE_REPO_ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "缺少 Rust/Cargo, 无法执行标准验证" >&2
  exit 1
fi
source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
Bruce_prepare_cargo_home

BRUCE_LEGACY_SOURCE=$(find . \
  -path './.git' -prune -o \
  -path './.build' -prune -o \
  -path './dist' -prune -o \
  -path '*/target' -prune -o \
  \( -name '*.py' -o -name '*.pyc' -o -name 'pyproject.toml' \) -print -quit)
if [[ -n "$BRUCE_LEGACY_SOURCE" ]]; then
  echo "检测到已移除的 Python 资产: $BRUCE_LEGACY_SOURCE" >&2
  exit 1
fi

zsh -n "$BRUCE_SCRIPT_DIR/collector-release-smoke.sh"
zsh "$BRUCE_SCRIPT_DIR/check-collector-fixtures.sh"
echo "运行 Rust workspace 测试、格式与 Clippy"
cargo fmt --manifest-path "$BRUCE_RUST_MANIFEST" --all -- --check
cargo test --manifest-path "$BRUCE_RUST_MANIFEST" --workspace
cargo clippy --manifest-path "$BRUCE_RUST_MANIFEST" --workspace --all-targets -- -D warnings

if [[ ! -x "$BRUCE_RUST_BIN" ]]; then
  echo "Rust Collector 构建产物不存在: $BRUCE_RUST_BIN" >&2
  exit 1
fi

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
  CollectorRunnerHarness "$BRUCE_RUST_BIN"

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
  "$BRUCE_RUST_BIN"

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
