#!/bin/zsh

# 生成 Release 发布说明 (从 CHANGELOG 提取当前版本块, 转 Release 风格).
# 风格与 v0.1/v0.2 一致: "## Bruce vX 发布说明" + 中文小节
# (新功能 (Added) / 调整与优化 (Changed)).
# 用法: release-notes.sh <version> [changelog-path]
# 输出: dist/release-notes-<version>.md (可用 BRUCE_OUT 覆盖)

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_VERSION="$1"
BRUCE_CHANGELOG="${2:-$BRUCE_REPO_ROOT/CHANGELOG.md}"
BRUCE_OUT="${BRUCE_OUT:-$BRUCE_REPO_ROOT/dist/release-notes-$BRUCE_VERSION.md}"

mkdir -p "$(dirname "$BRUCE_OUT")"

BRUCE_BODY=$(mktemp "${TMPDIR:-/tmp}/Bruce-release-notes.XXXXXX")
trap 'rm -f "$BRUCE_BODY"' EXIT
if ! awk -v version="$BRUCE_VERSION" '
    BEGIN {
        target = "## [" version "] - "
        in_block = 0
        found = 0
    }
    /^## \[/ {
        if (in_block) exit
        if (index($0, target) == 1) {
            in_block = 1
            found = 1
            next
        }
    }
    in_block {
        if ($0 ~ /^---[[:space:]]*$/) next
        if ($0 == "### Added") print "### 新功能 (Added)"
        else if ($0 == "### Changed") print "### 调整与优化 (Changed)"
        else if ($0 == "### Fixed") print "### 修复 (Fixed)"
        else if ($0 == "### Removed") print "### 移除 (Removed)"
        else print
    }
    END {
        if (!found) exit 1
    }
' "$BRUCE_CHANGELOG" > "$BRUCE_BODY"; then
    echo "CHANGELOG 中未找到版本块 [$BRUCE_VERSION]" >&2
    exit 1
fi

{
    printf '## Bruce %s 发布说明\n\n' "$BRUCE_VERSION"
    sed -e 's/[[:space:]]*$//' "$BRUCE_BODY"
    printf '\n'
} > "$BRUCE_OUT"
echo "生成: $BRUCE_OUT"
