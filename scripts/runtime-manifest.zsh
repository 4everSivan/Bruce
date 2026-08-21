# Shared runtime manifest for Preview and Release App bundles.
# The caller supplies the repository root and destination Resources.

BRUCE_RUST_PACKAGE_DIR="rust/Bruce-collector"
BRUCE_RUST_BINARY_NAME="Bruce-collector"

BRUCE_PREVIEW_RUNTIME_FILES=(
    bridge/__init__.py
    bridge/run_bridge.py
    bridge/security.py
    bridge/schemas
    agent-usage/collector/collect_usage.py
    agent-usage/collector/pricing.py
    agent-usage/collector/runtime.py
    agent-usage/collector/quota_services.py
    agent-usage/collector/local_usage.py
    agent-usage/collector/codex_compat.py
    agent-usage/collector/quota_official.py
    agent-usage/collector/service_catalog.py
)

BRUCE_BUNDLE_FILES=(
    macos/BruceApp/Assets/AppIcon.icns
)

Bruce_validate_packaging_sources() {
    local repo_root="$1"
    local relative_path
    for relative_path in "${BRUCE_BUNDLE_FILES[@]}" "${BRUCE_PREVIEW_RUNTIME_FILES[@]}"; do
        if [[ ! -e "$repo_root/$relative_path" ]]; then
            echo "缺少打包资源: $repo_root/$relative_path" >&2
            return 1
        fi
    done
}

Bruce_copy_runtime() {
    local repo_root="$1"
    local runtime_root="$2"
    local relative_path

    mkdir -p "$runtime_root/bridge" "$runtime_root/agent-usage/collector"
    for relative_path in "${BRUCE_PREVIEW_RUNTIME_FILES[@]}"; do
        ditto "$repo_root/$relative_path" "$runtime_root/$relative_path"
    done
}

Bruce_prepare_cargo_home() {
    local cargo_home_candidate="${CARGO_HOME:-}"
    if [[ -n "$cargo_home_candidate" && -d "$cargo_home_candidate" \
        && -w "$cargo_home_candidate" ]]; then
        export BRUCE_CARGO_HOME="$cargo_home_candidate"
    else
        export BRUCE_CARGO_HOME="${TMPDIR:-/tmp}/bruce-cargo-home"
        export CARGO_HOME="$BRUCE_CARGO_HOME"
    fi
    mkdir -p "$BRUCE_CARGO_HOME"
}

Bruce_build_rust_collector() {
    local repo_root="$1"
    local configuration="${2:-release}"
    # macOS CI/受限环境可能把默认 Cargo 缓存指向不可写位置.
    Bruce_prepare_cargo_home
    unset BRUCE_RUST_BINARY_OVERRIDE

    # Rust panic locations and debug metadata may otherwise embed the source
    # checkout path in the bundled binary. Keep the existing caller flags and
    # remap only this repository path so bundle source-path validation remains
    # meaningful without hiding third-party diagnostics.
    local rustflags="${RUSTFLAGS:-}"
    if [[ -n "$rustflags" ]]; then
        rustflags+=" "
    fi
    rustflags+="--remap-path-prefix=$repo_root=."

    local requested_archs="${BRUCE_RUST_TARGET_ARCHS:-}"
    if [[ -n "$requested_archs" ]]; then
        if ! command -v lipo >/dev/null 2>&1; then
            echo "构建 universal Rust Collector 需要 lipo" >&2
            return 1
        fi
        local universal_root="$repo_root/$BRUCE_RUST_PACKAGE_DIR/target/universal/$configuration"
        local universal_binary="$universal_root/$BRUCE_RUST_BINARY_NAME"
        mkdir -p "$universal_root"
        local -a input_paths=()
        local target_arch target_triple input_path
        for target_arch in ${(s: :)requested_archs}; do
            case "$target_arch" in
                arm64|aarch64)
                    target_triple="aarch64-apple-darwin"
                    ;;
                x86_64|amd64)
                    target_triple="x86_64-apple-darwin"
                    ;;
                *)
                    echo "不支持的 Rust 目标架构: $target_arch" >&2
                    return 1
                    ;;
            esac
            if [[ "$configuration" == "release" ]]; then
                RUSTFLAGS="$rustflags" cargo build \
                    --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
                    --target "$target_triple" \
                    --release \
                    --bin "$BRUCE_RUST_BINARY_NAME"
            else
                RUSTFLAGS="$rustflags" cargo build \
                    --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
                    --target "$target_triple" \
                    --bin "$BRUCE_RUST_BINARY_NAME"
            fi
            input_path="$repo_root/$BRUCE_RUST_PACKAGE_DIR/target/$target_triple/$configuration/$BRUCE_RUST_BINARY_NAME"
            if [[ ! -x "$input_path" ]]; then
                echo "缺少 Rust 目标架构产物: $input_path" >&2
                return 1
            fi
            input_paths+=("$input_path")
        done
        lipo -create "${input_paths[@]}" -output "$universal_binary"
        chmod 755 "$universal_binary"
        export BRUCE_RUST_BINARY_OVERRIDE="$universal_binary"
        return 0
    fi

    if [[ "$configuration" == "release" ]]; then
        RUSTFLAGS="$rustflags" cargo build \
            --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
            --release \
            --bin "$BRUCE_RUST_BINARY_NAME"
    else
        RUSTFLAGS="$rustflags" cargo build \
            --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
            --bin "$BRUCE_RUST_BINARY_NAME"
    fi
}

Bruce_rust_binary_path() {
    local repo_root="$1"
    local configuration="${2:-release}"
    if [[ -n "${BRUCE_RUST_BINARY_OVERRIDE:-}" ]]; then
        echo "$BRUCE_RUST_BINARY_OVERRIDE"
        return 0
    fi
    echo "$repo_root/$BRUCE_RUST_PACKAGE_DIR/target/$configuration/$BRUCE_RUST_BINARY_NAME"
}

Bruce_validate_rust_source() {
    local repo_root="$1"
    local configuration="${2:-release}"
    local binary_path
    binary_path=$(Bruce_rust_binary_path "$repo_root" "$configuration")
    if [[ ! -x "$binary_path" ]]; then
        echo "缺少 Rust Collector binary: $binary_path" >&2
        return 1
    fi
}

Bruce_copy_rust_collector() {
    local repo_root="$1"
    local resources_root="$2"
    local configuration="${3:-release}"
    local binary_path
    binary_path=$(Bruce_rust_binary_path "$repo_root" "$configuration")
    Bruce_validate_rust_source "$repo_root" "$configuration"
    ditto "$binary_path" "$resources_root/$BRUCE_RUST_BINARY_NAME"
    chmod 755 "$resources_root/$BRUCE_RUST_BINARY_NAME"
}

Bruce_validate_release_bundle() {
    local app_root="$1"
    local resources_root="$app_root/Contents/Resources"
    local rust_binary="$resources_root/$BRUCE_RUST_BINARY_NAME"
    local app_executable="$app_root/Contents/MacOS/BruceApp"
    if [[ ! -x "$app_executable" ]]; then
        echo "Release Bundle 缺少 BruceApp 可执行文件: $app_executable" >&2
        return 1
    fi
    if [[ ! -x "$rust_binary" ]]; then
        echo "Release Bundle 缺少可执行 Rust Collector: $rust_binary" >&2
        return 1
    fi
    if [[ -d "$resources_root/runtime" ]]; then
        echo "Release Bundle 不得包含 Python runtime fallback" >&2
        return 1
    fi
    if rg --files "$app_root" -g '*.py' -g 'run_bridge.py' | rg -q '.'; then
        echo "Release Bundle 包含 Python source/fallback" >&2
        return 1
    fi
    if rg --files "$app_root" \
        | rg -q '(^|/)(data|fixtures?)(/|$)'; then
        echo "Release Bundle 不得包含运行数据或测试 fixture" >&2
        return 1
    fi
    if rg --files "$app_root" \
        | rg -q '(^|/)(sessions?|debug|target|\.build)(/|$)|\.(sqlite3?|db|jsonl?)$'; then
        echo "Release Bundle 不得包含会话、数据库或 Debug 产物" >&2
        return 1
    fi
    if strings "$app_executable" \
        | rg -q 'PythonPreviewAdapter|PythonPreview|run_bridge\.py|pythonURL|bridgeURL'; then
        echo "Release Bundle 的 BruceApp 可执行文件包含 Python fallback 标记" >&2
        return 1
    fi
    # Optimized Rust may place adjacent static header labels in one strings
    # segment ("Bearer AuthorizationAcceptKimi"). Exclude that known
    # non-secret sequence while retaining the bearer-token scan.
    if rg -a -P -q 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY|Bearer[[:space:]]+(?!AuthorizationAcceptKimi(?:[[:space:]]|$))[A-Za-z0-9._~+/=-]{16,}' \
        "$app_root"; then
        echo "Release Bundle 疑似包含凭证或私钥" >&2
        return 1
    fi
    if command -v lipo >/dev/null 2>&1; then
        local expected_arch
        local expected_archs="${BRUCE_EXPECTED_ARCHS:-${BRUCE_RUST_TARGET_ARCHS:-$(uname -m)}}"
        for expected_arch in ${(s: :)expected_archs}; do
            if ! lipo "$rust_binary" -verify_arch "$expected_arch" >/dev/null 2>&1; then
                echo "Rust Collector 缺少目标架构: $expected_arch" >&2
                return 1
            fi
        done
    fi
}
