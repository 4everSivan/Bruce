#!/bin/zsh

# 平台无关的 Rust 验证入口: fixture 契约扫描 + fmt + test + clippy。
# 覆盖 core/collector workspace 与 apps/win 纯 Rust 视图模型 crate;
# 供 verify-local.sh (mac) 与 CI 复用; Windows 环境由 ci.yml 的 verify-windows
# job 直接执行等价 cargo 命令 (zsh 依赖不适用于 Windows)。

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_RUST_MANIFEST="$BRUCE_REPO_ROOT/core/collector/Cargo.toml"
BRUCE_WIN_VIEWMODEL_MANIFEST="$BRUCE_REPO_ROOT/apps/win/viewmodel/Cargo.toml"
BRUCE_WIN_SHELL_MANIFEST="$BRUCE_REPO_ROOT/apps/win/src-tauri/Cargo.toml"

cd "$BRUCE_REPO_ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "缺少 Rust/Cargo, 无法执行 Rust 验证" >&2
  exit 1
fi
source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
Bruce_prepare_cargo_home

verify_rust_manifest() {
  local manifest=$1
  echo "-- Rust 验证: $manifest"
  cargo fmt --manifest-path "$manifest" --all -- --check
  cargo test --manifest-path "$manifest"
  cargo clippy --manifest-path "$manifest" --all-targets -- -D warnings
}

zsh "$BRUCE_SCRIPT_DIR/check-collector-fixtures.sh"
# Windows 前端结构冒烟 (app.js 语法 + DOM id 交叉 + demo 残留哨兵);
# CI 双侧 runner 均预装 node, 本地缺 node 时警告跳过不阻塞 Rust 验证。
if command -v node >/dev/null 2>&1; then
  node "$BRUCE_REPO_ROOT/scripts/check-win-frontend.mjs"
else
  echo "警告: 缺少 node, 跳过 Windows 前端结构冒烟" >&2
fi
verify_rust_manifest "$BRUCE_RUST_MANIFEST"
verify_rust_manifest "$BRUCE_WIN_VIEWMODEL_MANIFEST"
# Tauri 壳: 编译面大放最后; local_collection 冒烟会在 CI 临时环境落缓存, 幂等无害。
verify_rust_manifest "$BRUCE_WIN_SHELL_MANIFEST"

echo "Bruce Rust 验证全部通过"
