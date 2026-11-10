#!/bin/zsh
# 仓库内禁 Python 资产门禁 (AGENTS.md「项目自定义规则」第 6 条; C231)。
#
# 只检查会进入仓库的文件: 已跟踪 + 未跟踪但未被 .gitignore 忽略
# (git ls-files --cached --others --exclude-standard)。被忽略的本机目录 (.agent/ 等
# AI 工具配置、local/、dist/、target/、.build/、_adflow_backup/) 不是仓库资产, 不再拦截;
# 此前 find 全盘扫描会被 .agent/skills/**/*.py 这类本机工具文件误伤, 在任何检查运行前
# 就 exit 1。已被强制跟踪 (git add -f) 的被忽略文件仍属仓库资产, 照常拦截。
# 唯一例外 scripts/adflow_verify.py: ad-flow 治理校验器, 规范要求逐字安装。
#
# 先在系统临时目录的一次性仓库里自检 (被忽略文件 / 白名单放行, 未忽略文件、强制跟踪
# 文件与 pyproject.toml 拦截), 保证门禁不是空转; 临时仓库在退出时删除, 不写入源码树与 local/。
#
# 用法: zsh scripts/check-no-python-assets.zsh [仓库根目录]

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${1:-${BRUCE_SCRIPT_DIR:h}}
BRUCE_PYTHON_ALLOWLIST=scripts/adflow_verify.py

# 输出 root 下第一个违规路径 (相对仓库根); 无违规时输出为空。
# 非 Git 工作树直接失败: 列不出文件时不能静默放行。
function Bruce_first_python_asset() {
    local root=$1
    if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "Python 资产门禁: $root 不是 Git 工作树, 无法列出仓库文件" >&2
        return 2
    fi
    local files
    files=$(git -C "$root" ls-files --cached --others --exclude-standard)
    print -r -- "$files" \
        | grep -E '(\.pyc?|(^|/)pyproject\.toml)$' \
        | grep -vxF "$BRUCE_PYTHON_ALLOWLIST" \
        | head -n 1 || true
}

function Bruce_gate_self_test_fail() {
    echo "Python 资产门禁自检失败: $1" >&2
    exit 1
}

BRUCE_GATE_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/bruce-no-python-gate.XXXXXX")
trap 'rm -rf "$BRUCE_GATE_SANDBOX"' EXIT

git -C "$BRUCE_GATE_SANDBOX" init -q
mkdir -p "$BRUCE_GATE_SANDBOX/.agent/tools" "$BRUCE_GATE_SANDBOX/scripts" "$BRUCE_GATE_SANDBOX/src"
print -r -- '.agent/' > "$BRUCE_GATE_SANDBOX/.gitignore"
: > "$BRUCE_GATE_SANDBOX/.agent/tools/tool.py"
: > "$BRUCE_GATE_SANDBOX/scripts/adflow_verify.py"
[[ -z $(Bruce_first_python_asset "$BRUCE_GATE_SANDBOX") ]] \
    || Bruce_gate_self_test_fail "被忽略目录或白名单校验器被误拦截"

: > "$BRUCE_GATE_SANDBOX/src/leak.py"
[[ $(Bruce_first_python_asset "$BRUCE_GATE_SANDBOX") == src/leak.py ]] \
    || Bruce_gate_self_test_fail "未被忽略的 .py 未被拦截"
rm "$BRUCE_GATE_SANDBOX/src/leak.py"

: > "$BRUCE_GATE_SANDBOX/src/pyproject.toml"
[[ $(Bruce_first_python_asset "$BRUCE_GATE_SANDBOX") == src/pyproject.toml ]] \
    || Bruce_gate_self_test_fail "pyproject.toml 未被拦截"
rm "$BRUCE_GATE_SANDBOX/src/pyproject.toml"

git -C "$BRUCE_GATE_SANDBOX" add -f .agent/tools/tool.py
[[ $(Bruce_first_python_asset "$BRUCE_GATE_SANDBOX") == .agent/tools/tool.py ]] \
    || Bruce_gate_self_test_fail "被忽略但已强制跟踪的 .py 未被拦截"

BRUCE_PYTHON_VIOLATION=$(Bruce_first_python_asset "$BRUCE_REPO_ROOT")
if [[ -n "$BRUCE_PYTHON_VIOLATION" ]]; then
    echo "检测到已移除的 Python 资产: $BRUCE_PYTHON_VIOLATION" >&2
    exit 1
fi
echo "Python 资产门禁通过 (自检 4 项; 仓库内仅白名单 $BRUCE_PYTHON_ALLOWLIST)"
