#!/bin/zsh

# Verify the bundled Rust runtime and exercise install/upgrade/rollback against
# an isolated temporary application directory. Strict mode is intended for a
# signed, notarized Release app; --local-preview only proves the deterministic
# file-level and collector-runtime parts with the local adhoc Preview bundle.

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_ALLOW_PREVIEW=0

usage() {
    echo "用法: zsh scripts/collector-release-smoke.sh <Bruce.app> [--local-preview]" >&2
    echo "  strict: 校验 Release bundle、Developer ID、staple、spctl 和 universal arch" >&2
    echo "  --local-preview: 允许当前本地 adhoc/单架构 Preview, 仅验证 runtime/install/cache" >&2
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 2
fi

BRUCE_APP_PATH=${1:A}
if [[ $# -eq 2 ]]; then
    if [[ "$2" != "--local-preview" ]]; then
        usage
        exit 2
    fi
    BRUCE_ALLOW_PREVIEW=1
fi

if [[ ! -d "$BRUCE_APP_PATH/Contents" ]]; then
    echo "不是有效的 App bundle: $BRUCE_APP_PATH" >&2
    exit 1
fi

for required_command in codesign ditto find grep lipo plutil rg shasum; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "缺少 smoke 命令: $required_command" >&2
        exit 1
    fi
done

source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"

BRUCE_RUST_RUNTIME="$BRUCE_APP_PATH/Contents/Resources/$BRUCE_RUST_BINARY_NAME"
BRUCE_APP_RUNTIME="$BRUCE_APP_PATH/Contents/MacOS/BruceApp"
if [[ ! -x "$BRUCE_RUST_RUNTIME" || ! -x "$BRUCE_APP_RUNTIME" ]]; then
    echo "App bundle 缺少可执行 runtime: $BRUCE_APP_PATH" >&2
    exit 1
fi

if [[ "$BRUCE_ALLOW_PREVIEW" == 0 ]]; then
    BRUCE_EXPECTED_ARCHS="${BRUCE_EXPECTED_ARCHS:-arm64 x86_64}"
else
    BRUCE_EXPECTED_ARCHS="${BRUCE_EXPECTED_ARCHS:-${BRUCE_RUST_TARGET_ARCHS:-$(uname -m)}}"
fi
for expected_arch in ${(s: :)BRUCE_EXPECTED_ARCHS}; do
    if ! lipo "$BRUCE_RUST_RUNTIME" -verify_arch "$expected_arch" >/dev/null 2>&1; then
        echo "Rust Collector 缺少目标架构: $expected_arch" >&2
        exit 1
    fi
done

if [[ "$BRUCE_ALLOW_PREVIEW" == 0 ]]; then
    export BRUCE_EXPECTED_ARCHS
    Bruce_validate_release_bundle "$BRUCE_APP_PATH"
    codesign --verify --deep --strict "$BRUCE_APP_PATH"
    BRUCE_SIGNATURE_INFO=$(codesign -dv --verbose=4 "$BRUCE_APP_PATH" 2>&1)
    if ! grep -q '^Authority=Developer ID Application:' <<<"$BRUCE_SIGNATURE_INFO"; then
        echo "Release App 不是 Developer ID Application 签名" >&2
        exit 1
    fi
    if grep -q '^Signature=adhoc' <<<"$BRUCE_SIGNATURE_INFO"; then
        echo "Release App 不得使用 adhoc 签名" >&2
        exit 1
    fi
    xcrun stapler validate "$BRUCE_APP_PATH"
    spctl --assess --type execute --verbose=4 "$BRUCE_APP_PATH"
else
    codesign --verify --deep --strict "$BRUCE_APP_PATH"
    echo "LOCAL PREVIEW: 跳过签名、公证和 Gatekeeper 门禁"
fi

BRUCE_SMOKE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/Bruce-release-smoke.XXXXXX")
trap 'rm -rf "$BRUCE_SMOKE_ROOT"' EXIT

BRUCE_HOME="$BRUCE_SMOKE_ROOT/home"
BRUCE_SESSIONS="$BRUCE_HOME/.kimi-code/sessions"
mkdir -p "$BRUCE_SESSIONS"
printf '%s\n' '{"type":"usage.record","time":1785211200000,"model":"smoke-model","usage":{"inputOther":10,"output":2}}' > "$BRUCE_SESSIONS/smoke.jsonl"

make_request() {
    local home_path="$1"
    local request_path="$2"
    cat > "$request_path" <<'JSON'
{"schemaVersion":1,"runId":"12345678-1234-4234-9234-123456789abc","module":"agent-usage","timeouts":{"localScanSeconds":30,"externalRequestSeconds":10,"moduleSeconds":90},"context":{"home":"","now":"2026-07-28T12:00:00+08:00","timezone":"Asia/Shanghai","days":14,"capabilities":["localSessions"]},"credentials":{}}
JSON
    plutil -replace context.home -string "$home_path" "$request_path"
}

json_raw() {
    local key_path="$1"
    local json_path="$2"
    plutil -extract "$key_path" raw -o - "$json_path" 2>/dev/null
}

json_raw_or_zero() {
    local key_path="$1"
    local json_path="$2"
    json_raw "$key_path" "$json_path" || print 0
}

run_runtime_smoke() {
    local app_path="$1"
    local label="$2"
    local expected_rebuilds="$3"
    local expected_parsed="${4:-1}"
    local runtime="$app_path/Contents/Resources/$BRUCE_RUST_BINARY_NAME"
    local request="$BRUCE_SMOKE_ROOT/$label.request.json"
    local response="$BRUCE_SMOKE_ROOT/$label.response.json"
    local stderr_path="$BRUCE_SMOKE_ROOT/$label.stderr"
    local metrics="$BRUCE_SMOKE_ROOT/$label.metrics.json"

    [[ -x "$runtime" ]] || { echo "[$label] Rust runtime 不可执行" >&2; return 1; }
    make_request "$BRUCE_HOME" "$request"
    BRUCE_COLLECTOR_METRICS_PATH="$metrics" "$runtime" \
        < "$request" > "$response" 2> "$stderr_path"
    [[ "$(wc -l < "$response" | tr -d ' ')" == "1" ]] || {
        echo "[$label] stdout 不是单行 Bridge envelope" >&2
        return 1
    }
    [[ ! -s "$stderr_path" ]] || {
        echo "[$label] stderr 有未预期输出:" >&2
        sed -n '1,20p' "$stderr_path" >&2
        return 1
    }
    local schema_version
    local response_run_id
    local disk_scope
    local parsed_lines
    local disk_read_bytes
    local cache_rebuilds
    local cache_invalidations
    schema_version=$(json_raw schemaVersion "$response")
    response_run_id=$(json_raw runId "$response")
    if [[ "$schema_version" != 1 ]]; then
        echo "[$label] response schema 不正确" >&2
        return 1
    fi
    if [[ "$response_run_id" != "12345678-1234-4234-9234-123456789abc" ]]; then
        echo "[$label] runId 不一致" >&2
        return 1
    fi
    if ! plutil -extract artifact json -o /dev/null "$response" >/dev/null 2>&1; then
        echo "[$label] artifact 缺失" >&2
        return 1
    fi
    disk_scope=$(json_raw disk_read_scope "$metrics")
    parsed_lines=$(json_raw_or_zero json_lines_parsed "$metrics")
    disk_read_bytes=$(json_raw_or_zero disk_read_bytes "$metrics")
    cache_rebuilds=$(json_raw_or_zero cache_rebuilds "$metrics")
    cache_invalidations=$(json_raw_or_zero cache_invalidations "$metrics")
    if [[ "$disk_scope" != "logical_source_bytes" ]]; then
        echo "[$label] disk_read_scope=$disk_scope 不是 logical_source_bytes" >&2
        return 1
    fi
    if (( parsed_lines < expected_parsed )); then
        echo "[$label] json_lines_parsed=$parsed_lines < expected $expected_parsed" >&2
        return 1
    fi
    if (( expected_parsed > 0 && disk_read_bytes <= 0 )); then
        echo "[$label] disk_read_bytes=$disk_read_bytes 未记录源 JSONL 读取" >&2
        return 1
    fi
    if (( cache_rebuilds < expected_rebuilds )); then
        echo "[$label] cache_rebuilds=$cache_rebuilds < expected $expected_rebuilds" >&2
        return 1
    fi
    echo "$label: schema/runId/artifact/stdout/cache OK (parsed=$parsed_lines, disk=$disk_read_bytes, rebuilds=$cache_rebuilds, invalidations=$cache_invalidations)"
}

echo "校验 Rust runtime: $BRUCE_RUST_RUNTIME"
run_runtime_smoke "$BRUCE_APP_PATH" initial 1

BRUCE_CACHE_ROOT="$BRUCE_HOME/Library/Application Support/Bruce/collector-cache-v1"
BRUCE_CACHE_FILE=$(find "$BRUCE_CACHE_ROOT" -type f -name '*.json' \
    ! -name 'manifest-*' -print -quit)
if [[ -z "$BRUCE_CACHE_FILE" ]]; then
    echo "没有生成 cache entry, 无法执行旧 cache rebuild smoke" >&2
    exit 1
fi

# Simulate a supported old entry whose parser version predates the current
# compact contribution format. The collector must rebuild, not publish empty.
plutil -replace parserVersion -integer 1 "$BRUCE_CACHE_FILE"
run_runtime_smoke "$BRUCE_APP_PATH" old-cache-rebuild 1

BRUCE_INSTALL_ROOT="$BRUCE_SMOKE_ROOT/Applications"
BRUCE_INSTALLED_APP="$BRUCE_INSTALL_ROOT/Bruce.app"
BRUCE_UPGRADE_APP="$BRUCE_INSTALL_ROOT/Bruce.upgrade.app"
BRUCE_ROLLBACK_APP="$BRUCE_SMOKE_ROOT/rollback/Bruce.app"
mkdir -p "$BRUCE_INSTALL_ROOT" "$BRUCE_SMOKE_ROOT/rollback"

ditto "$BRUCE_APP_PATH" "$BRUCE_INSTALLED_APP"
    run_runtime_smoke "$BRUCE_INSTALLED_APP" install 0 0

ditto "$BRUCE_APP_PATH" "$BRUCE_UPGRADE_APP"
rm -rf "$BRUCE_INSTALLED_APP"
mv "$BRUCE_UPGRADE_APP" "$BRUCE_INSTALLED_APP"
    run_runtime_smoke "$BRUCE_INSTALLED_APP" upgrade 0 0

ditto "$BRUCE_INSTALLED_APP" "$BRUCE_ROLLBACK_APP"
rm -rf "$BRUCE_INSTALLED_APP"
ditto "$BRUCE_ROLLBACK_APP" "$BRUCE_INSTALLED_APP"
    run_runtime_smoke "$BRUCE_INSTALLED_APP" rollback 0 0

echo "collector release smoke: install/upgrade/rollback/cache rebuild passed"
if [[ "$BRUCE_ALLOW_PREVIEW" == 0 ]]; then
    echo "collector release smoke: strict signed Release gates passed"
else
    echo "collector release smoke: local evidence only; Release signing gates remain pending"
fi
