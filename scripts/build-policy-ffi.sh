#!/bin/zsh

# 构建 mac 进程内调用的共享策略静态库 (T16, design/08 第二期) 到 local/build/policy-ffi。
# 直接 `swift build` / `swift run` 前需先运行一次 (verify-local / build-test-app 已自动调用)。
# 默认只构建本机架构; BRUCE_RUST_TARGET_ARCHS="arm64 x86_64" 时构建 Universal 2。

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}

source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
Bruce_build_policy_ffi "$BRUCE_REPO_ROOT"
lipo -info "$BRUCE_REPO_ROOT/$BRUCE_POLICY_FFI_OUTPUT_DIR/$BRUCE_POLICY_FFI_LIBRARY"
