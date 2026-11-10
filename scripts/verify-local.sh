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

# 仓库内禁 Python 资产 (AGENTS.md「项目自定义规则」第 6 条): 只检查已跟踪与未被忽略的
# 文件, 唯一例外是 ad-flow 治理校验器 scripts/adflow_verify.py (C231)。
zsh "$BRUCE_SCRIPT_DIR/check-no-python-assets.zsh" "$BRUCE_REPO_ROOT"

zsh -n "$BRUCE_SCRIPT_DIR/collector-release-smoke.sh"
zsh -n "$BRUCE_SCRIPT_DIR/build-test-app.sh"
zsh -n "$BRUCE_SCRIPT_DIR/build-release-app.sh"
zsh "$BRUCE_SCRIPT_DIR/check-bundle-resources.zsh"
node "$BRUCE_REPO_ROOT/scripts/check-ci-tool-deps.mjs"
zsh "$BRUCE_SCRIPT_DIR/verify-rust.sh"

if [[ ! -x "$BRUCE_RUST_BIN" ]]; then
  echo "Rust Collector 构建产物不存在: $BRUCE_RUST_BIN" >&2
  exit 1
fi

echo "构建共享策略静态库 (T16, local/build/policy-ffi)"
Bruce_build_policy_ffi "$BRUCE_REPO_ROOT"

# 每个 *Harness target 都必须由本脚本运行 (C231): 新增 Harness 却漏接时直接失败,
# 让 AGENTS.md「全部 Harness」的承诺不随手写计数漂移。
BRUCE_SELF_PATH=${0:A}
BRUCE_HARNESS_TARGETS=(${(f)"$(grep -oE 'name: "[A-Za-z]+Harness"' "$BRUCE_SWIFT_PACKAGE/Package.swift" | sed -E 's/^name: "(.*)"$/\1/')"})
if (( ${#BRUCE_HARNESS_TARGETS} == 0 )); then
  echo "未从 Package.swift 解析到任何 Harness target" >&2
  exit 1
fi
for BRUCE_HARNESS_TARGET in $BRUCE_HARNESS_TARGETS; do
  if ! grep -qF "\"\$BRUCE_SWIFT_BIN_DIR/$BRUCE_HARNESS_TARGET\"" "$BRUCE_SELF_PATH"; then
    echo "Harness target 未接入 verify-local: $BRUCE_HARNESS_TARGET" >&2
    exit 1
  fi
done
echo "Harness 接入完整: ${#BRUCE_HARNESS_TARGETS} 个 target 均由本脚本运行"

echo "构建 Swift 应用与全部 Harness"
swift build --package-path "$BRUCE_SWIFT_PACKAGE" --build-tests
BRUCE_SWIFT_BIN_DIR=$(swift build --package-path "$BRUCE_SWIFT_PACKAGE" --show-bin-path)

echo "运行 Onboarding Core Harness"
"$BRUCE_SWIFT_BIN_DIR/BruceOnboardingCoreHarness"

echo "运行 PanelViewModel Harness"
"$BRUCE_SWIFT_BIN_DIR/PanelViewModelHarness"

echo "运行 ArtifactStore Harness"
"$BRUCE_SWIFT_BIN_DIR/ArtifactStoreHarness" "$BRUCE_REPO_ROOT"

echo "运行 CollectorRunner Harness"
"$BRUCE_SWIFT_BIN_DIR/CollectorRunnerHarness" "$BRUCE_RUST_BIN"

echo "运行 RefreshScheduler Harness"
"$BRUCE_SWIFT_BIN_DIR/RefreshSchedulerHarness" "$BRUCE_REPO_ROOT"

echo "运行 NativeLifecycle Harness"
"$BRUCE_SWIFT_BIN_DIR/NativeLifecycleHarness"

echo "运行 Diagnostics Harness"
"$BRUCE_SWIFT_BIN_DIR/DiagnosticsHarness"

echo "运行隔离的本地集成 Harness"
"$BRUCE_SWIFT_BIN_DIR/LocalIntegrationHarness" \
  "$BRUCE_REPO_ROOT" \
  "$BRUCE_RUST_BIN"

echo "运行 Widget 像素动画性能 Harness"
node "$BRUCE_REPO_ROOT/scripts/widget-performance-harness.mjs"

echo "运行订阅凭证注入 Harness"
"$BRUCE_SWIFT_BIN_DIR/SubscriptionCredentialsHarness"

echo "运行全局快捷键 Harness"
"$BRUCE_SWIFT_BIN_DIR/GlobalHotkeyHarness"

echo "运行 AppModel 缓存 Harness"
"$BRUCE_SWIFT_BIN_DIR/AppModelCacheHarness"

echo "运行 Dashboard 玻璃材质矩阵 Harness"
"$BRUCE_SWIFT_BIN_DIR/DashboardGlassSurfaceHarness"

echo "运行订阅刷新控件 Harness"
"$BRUCE_SWIFT_BIN_DIR/SubscriptionRefreshControlHarness"

echo "运行订阅品牌图形 Harness"
"$BRUCE_SWIFT_BIN_DIR/SubscriptionBrandGlyphHarness"

echo "运行顶部四色状态灯 Harness"
"$BRUCE_SWIFT_BIN_DIR/DashboardStatusToneHarness" "$BRUCE_REPO_ROOT"

echo "运行设置窗口比例锁定 Harness"
"$BRUCE_SWIFT_BIN_DIR/SettingsWindowMetricsHarness"

echo "运行软件更新 Harness (清单 / 状态机 / 安装器 / 双端文案对拍)"
"$BRUCE_SWIFT_BIN_DIR/SoftwareUpdateHarness" "$BRUCE_REPO_ROOT"

echo "运行模型价格表远端同步 Harness (T20)"
"$BRUCE_SWIFT_BIN_DIR/PricingCatalogSyncHarness" "$BRUCE_REPO_ROOT"

echo "校验 Provider 品牌图形产物与源文件一致"
node "$BRUCE_REPO_ROOT/scripts/gen-provider-glyphs.mjs" --check

echo "校验 mac 内置价卡与采集端价卡同源 (C108)"
node "$BRUCE_REPO_ROOT/scripts/gen-pricing-catalog.mjs" --check

echo "校验变更总账一致性 (topic 归属下限与路径映射)"
node "$BRUCE_REPO_ROOT/scripts/check-change-ledger.mjs"

echo "校验官网源码与仓库事实源同步 (T27)"
node "$BRUCE_REPO_ROOT/scripts/check-site-sync.mjs"

echo "运行 Panel 视图模型双端对拍 Harness"
"$BRUCE_SWIFT_BIN_DIR/PanelParityHarness" "$BRUCE_REPO_ROOT"

echo "Bruce 本地验证全部通过"
