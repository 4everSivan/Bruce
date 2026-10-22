#!/bin/zsh

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_SWIFT_PACKAGE="$BRUCE_REPO_ROOT/apps/macos"
BRUCE_RUST_BIN=${BRUCE_RUST_BIN:-$BRUCE_REPO_ROOT/core/collector/target/debug/Bruce-collector}

cd "$BRUCE_REPO_ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "缺少 Rust/Cargo, 无法执行标准验证" >&2
  exit 1
fi
source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
source "$BRUCE_SCRIPT_DIR/swift-sdk.zsh"
Bruce_prepare_swift_sdk
Bruce_prepare_cargo_home

# 例外: ad-flow 治理校验器 scripts/adflow_verify.py —— ad-flow v1.5.0 规范要求逐字安装,
# 且 --mode init 校验其版本与 docs/index.json 的 adflow_version 一致, 属治理工具链而非
# Python 构建/工具资产。仅放行这一个受管路径, 其余任何 Python 资产仍一律禁止
# (见 AGENTS.md「项目自定义规则」第 6 条)。
BRUCE_LEGACY_SOURCE=$(find . \
  -path './.git' -prune -o \
  -path './.build' -prune -o \
  -path './dist' -prune -o \
  -path './local' -prune -o \
  -path '*/target' -prune -o \
  -path './scripts/adflow_verify.py' -prune -o \
  \( -name '*.py' -o -name '*.pyc' -o -name 'pyproject.toml' \) -print -quit)
if [[ -n "$BRUCE_LEGACY_SOURCE" ]]; then
  echo "检测到已移除的 Python 资产: $BRUCE_LEGACY_SOURCE" >&2
  exit 1
fi

zsh -n "$BRUCE_SCRIPT_DIR/collector-release-smoke.sh"
zsh "$BRUCE_SCRIPT_DIR/verify-rust.sh"

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

echo "运行 Widget 像素动画性能 Harness"
node "$BRUCE_REPO_ROOT/scripts/widget-performance-harness.mjs"

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

echo "运行订阅品牌图形 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" SubscriptionBrandGlyphHarness

echo "校验 Provider 品牌图形产物与源文件一致"
node "$BRUCE_REPO_ROOT/scripts/gen-provider-glyphs.mjs" --check

echo "校验变更总账一致性 (topic 归属下限与路径映射)"
node "$BRUCE_REPO_ROOT/scripts/check-change-ledger.mjs"

echo "运行 Panel 视图模型双端对拍 Harness"
swift run --package-path "$BRUCE_SWIFT_PACKAGE" \
  PanelParityHarness "$BRUCE_REPO_ROOT"

echo "Bruce 本地验证全部通过"
