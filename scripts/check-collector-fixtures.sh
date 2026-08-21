#!/bin/zsh

# Validate JSON fixtures and reject credentials, personal paths or account
# identifiers. The collector implementation is Rust-only; this check is
# intentionally implemented with macOS-native tools.

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_FIXTURE_ROOT="${1:-$BRUCE_REPO_ROOT/tests/fixtures}"
BRUCE_FINDINGS=0
BRUCE_FILE_COUNT=0

if [[ ! -d "$BRUCE_FIXTURE_ROOT" ]]; then
    echo "fixture 目录不存在: $BRUCE_FIXTURE_ROOT" >&2
    exit 1
fi

while IFS= read -r fixture_path; do
    (( BRUCE_FILE_COUNT += 1 ))
    if ! plutil -p "$fixture_path" >/dev/null 2>&1; then
        echo "fixture 不是有效 JSON: $fixture_path" >&2
        BRUCE_FINDINGS=1
    fi

    if rg -n -P '"(access_token|refresh_token|id_token|api_key|apikey|client_secret|password|secret)"\s*:\s*"(?!<redacted>|\[REDACTED\]|\[REDACTED_TOKEN\])[^" ]+' "$fixture_path" >/dev/null 2>&1; then
        echo "fixture 含未脱敏凭证字段: $fixture_path" >&2
        BRUCE_FINDINGS=1
    fi

    if rg -n -i -P '(Bearer\s+[A-Za-z0-9._~+/=-]+|\b(?:sk|ghp|xox[baprs])[-_][A-Za-z0-9_-]{12,}|/Users/[^/\s]+|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b)' "$fixture_path" >/dev/null 2>&1; then
        echo "fixture 含疑似个人信息或密钥模式: $fixture_path" >&2
        BRUCE_FINDINGS=1
    fi
done < <(find "$BRUCE_FIXTURE_ROOT" -type f -name '*.json' -print)

if (( BRUCE_FILE_COUNT == 0 )); then
    echo "fixture 目录没有 JSON 文件: $BRUCE_FIXTURE_ROOT" >&2
    exit 1
fi
if (( BRUCE_FINDINGS != 0 )); then
    exit 1
fi

echo "Collector fixture scan passed: files=$BRUCE_FILE_COUNT secretFindings=[]"
