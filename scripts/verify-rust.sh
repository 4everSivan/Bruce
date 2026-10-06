#!/bin/zsh

# 平台无关的 Rust Collector 验证入口: fixture 契约扫描 + fmt + test + clippy。
# 供 verify-local.sh (mac) 与 CI 复用; Windows 环境由 ci.yml 的 verify-windows
# job 直接执行等价 cargo 命令 (zsh 依赖不适用于 Windows)。

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_RUST_MANIFEST="$BRUCE_REPO_ROOT/core/collector/Cargo.toml"

cd "$BRUCE_REPO_ROOT"

if ! command -v cargo >/dev/null 2>&1; then
  echo "缺少 Rust/Cargo, 无法执行 Rust 验证" >&2
  exit 1
fi
source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
Bruce_prepare_cargo_home

zsh "$BRUCE_SCRIPT_DIR/check-collector-fixtures.sh"

echo "运行 Rust workspace 测试、格式与 Clippy"
cargo fmt --manifest-path "$BRUCE_RUST_MANIFEST" --all -- --check
cargo test --manifest-path "$BRUCE_RUST_MANIFEST" --workspace
cargo clippy --manifest-path "$BRUCE_RUST_MANIFEST" --workspace --all-targets -- -D warnings

echo "Bruce Rust 验证全部通过"
