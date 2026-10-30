# Shared runtime manifest for Preview and Release App bundles.
# The caller supplies the repository root and destination Resources.

BRUCE_RUST_PACKAGE_DIR="core/collector"
BRUCE_RUST_BINARY_NAME="Bruce-collector"

# Static resources copied into Contents/Resources/<basename> by both bundles.
# Preview 与 Release 只经 Bruce_copy_bundle_resources 投放, 清单只此一份 (C168):
# 此前两个脚本各自 ditto, Release 漏了 Nothing 主题字体.
BRUCE_BUNDLE_FILES=(
    apps/macos/Assets/AppIcon.icns
    apps/macos/Assets/Fonts
    apps/macos/Assets/AgentIcons
)

Bruce_validate_packaging_sources() {
    local repo_root="$1"
    local relative_path
    for relative_path in "${BRUCE_BUNDLE_FILES[@]}"; do
        if [[ ! -e "$repo_root/$relative_path" ]]; then
            echo "缺少打包资源: $repo_root/$relative_path" >&2
            return 1
        fi
    done
}

Bruce_copy_bundle_resources() {
    local repo_root="$1"
    local resources_root="$2"
    local relative_path
    for relative_path in "${BRUCE_BUNDLE_FILES[@]}"; do
        ditto "$repo_root/$relative_path" "$resources_root/${relative_path:t}" || return 1
    done
}

# 组装后的 Bundle 必须带齐清单内全部静态资源; 目录型资源不得为空 (C168).
Bruce_validate_bundle_resources() {
    local app_root="$1"
    local resources_root="$app_root/Contents/Resources"
    local relative_path target
    for relative_path in "${BRUCE_BUNDLE_FILES[@]}"; do
        target="$resources_root/${relative_path:t}"
        if [[ -d "$target" ]]; then
            if [[ -z "$(ls -A "$target")" ]]; then
                echo "Bundle 静态资源目录为空: $target" >&2
                return 1
            fi
        elif [[ ! -f "$target" ]]; then
            echo "Bundle 缺少静态资源: $target" >&2
            return 1
        fi
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
            RUSTFLAGS="$rustflags" cargo build \
                --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
                --target "$target_triple" \
                --release \
                --bin "$BRUCE_RUST_BINARY_NAME"
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

    RUSTFLAGS="$rustflags" cargo build \
        --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
        --release \
        --bin "$BRUCE_RUST_BINARY_NAME"
}

# T16: 共享策略静态库 (collector-policy-ffi, design/08 第二期)。mac 的 SwiftPM 以
# -L local/build/policy-ffi 链接 libbruce_policy.a; 架构取 BRUCE_RUST_TARGET_ARCHS
# (Universal 2 打包时为 "arm64 x86_64"), 缺省只构建本机架构。产物收拢到 local/。
BRUCE_POLICY_FFI_PACKAGE="collector-policy-ffi"
BRUCE_POLICY_FFI_LIBRARY="libbruce_policy.a"
BRUCE_POLICY_FFI_OUTPUT_DIR="local/build/policy-ffi"

Bruce_build_policy_ffi() {
    local repo_root="$1"
    Bruce_prepare_cargo_home
    local rustflags="${RUSTFLAGS:-}"
    if [[ -n "$rustflags" ]]; then
        rustflags+=" "
    fi
    rustflags+="--remap-path-prefix=$repo_root=."

    local requested_archs="${BRUCE_RUST_TARGET_ARCHS:-$(uname -m)}"
    local output_dir="$repo_root/$BRUCE_POLICY_FFI_OUTPUT_DIR"
    mkdir -p "$output_dir"
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
                echo "不支持的策略静态库目标架构: $target_arch" >&2
                return 1
                ;;
        esac
        RUSTFLAGS="$rustflags" cargo build \
            --manifest-path "$repo_root/$BRUCE_RUST_PACKAGE_DIR/Cargo.toml" \
            --target "$target_triple" \
            --release \
            --package "$BRUCE_POLICY_FFI_PACKAGE"
        input_path="$repo_root/$BRUCE_RUST_PACKAGE_DIR/target/$target_triple/release/$BRUCE_POLICY_FFI_LIBRARY"
        if [[ ! -f "$input_path" ]]; then
            echo "缺少策略静态库产物: $input_path" >&2
            return 1
        fi
        input_paths+=("$input_path")
    done
    lipo -create "${input_paths[@]}" -output "$output_dir/$BRUCE_POLICY_FFI_LIBRARY"
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
