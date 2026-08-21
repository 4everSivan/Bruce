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

for required_command in codesign ditto find grep lipo python3 rg shasum strings; do
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
    echo "LOCAL PREVIEW: 跳过 Release-only Python/source、Developer ID、公证和 Gatekeeper 门禁"
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
    python3 - "$home_path" "$request_path" <<'PY'
import json
import sys
from pathlib import Path

home = sys.argv[1]
output = Path(sys.argv[2])
request = {
    "schemaVersion": 1,
    "runId": "12345678-1234-4234-9234-123456789abc",
    "module": "agent-usage",
    "timeouts": {
        "localScanSeconds": 30,
        "externalRequestSeconds": 10,
        "moduleSeconds": 90,
    },
    "context": {
        "home": home,
        "now": "2026-07-28T12:00:00+08:00",
        "timezone": "Asia/Shanghai",
        "days": 14,
        "capabilities": ["localSessions"],
    },
    "credentials": {},
}
output.write_text(json.dumps(request, separators=(",", ":")) + "\n", encoding="utf-8")
PY
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
    python3 - "$response" "$metrics" "$label" "$expected_rebuilds" "$expected_parsed" <<'PY'
import json
import sys
from pathlib import Path

response = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
metrics = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
label = sys.argv[3]
expected_rebuilds = int(sys.argv[4])
expected_parsed = int(sys.argv[5])
if response.get("schemaVersion") != 1:
    raise SystemExit(f"[{label}] response schema 不正确")
if response.get("runId") != "12345678-1234-4234-9234-123456789abc":
    raise SystemExit(f"[{label}] runId 不一致")
if response.get("artifact") is None:
    raise SystemExit(f"[{label}] artifact 缺失")
if metrics.get("disk_read_scope") != "logical_source_bytes":
    raise SystemExit(
        f"[{label}] disk_read_scope={metrics.get('disk_read_scope')!r} "
        "不是 logical_source_bytes"
    )
if metrics.get("json_lines_parsed", 0) < expected_parsed:
    raise SystemExit(
        f"[{label}] json_lines_parsed={metrics.get('json_lines_parsed')} "
        f"< expected {expected_parsed}"
    )
if expected_parsed and metrics.get("disk_read_bytes", 0) <= 0:
    raise SystemExit(
        f"[{label}] disk_read_bytes={metrics.get('disk_read_bytes')} "
        "未记录源 JSONL 读取"
    )
if metrics.get("cache_rebuilds", 0) < expected_rebuilds:
    raise SystemExit(
        f"[{label}] cache_rebuilds={metrics.get('cache_rebuilds')} "
        f"< expected {expected_rebuilds}"
    )
print(
    f"{label}: schema/runId/artifact/stdout/cache OK "
    f"(parsed={metrics.get('json_lines_parsed')}, "
    f"disk={metrics.get('disk_read_bytes')}, "
    f"rebuilds={metrics.get('cache_rebuilds')}, "
    f"invalidations={metrics.get('cache_invalidations')})"
)
PY
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

python3 - "$BRUCE_CACHE_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = json.loads(path.read_text(encoding="utf-8"))
# Simulate a supported old entry whose parser version predates the current
# compact contribution format. The collector must rebuild, not publish empty.
value["parserVersion"] = 1
path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
PY
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
