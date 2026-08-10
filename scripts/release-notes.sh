#!/bin/zsh

# 生成 Release 发布说明 (从 CHANGELOG 提取当前版本块, 转 Release 风格).
# 风格与 v0.1/v0.2 一致: "## mddd vX 发布说明" + 中文小节
# (新功能 (Added) / 调整与优化 (Changed)).
# 用法: release-notes.sh <version> [changelog-path]
# 输出: dist/release-notes-<version>.md (可用 MDDD_OUT 覆盖)

set -euo pipefail

MDDD_SCRIPT_DIR=${0:A:h}
MDDD_REPO_ROOT=${MDDD_SCRIPT_DIR:h}
MDDD_VERSION="$1"
MDDD_CHANGELOG="${2:-$MDDD_REPO_ROOT/CHANGELOG.md}"
MDDD_OUT="${MDDD_OUT:-$MDDD_REPO_ROOT/dist/release-notes-$MDDD_VERSION.md}"

mkdir -p "$(dirname "$MDDD_OUT")"

python3 - "$MDDD_CHANGELOG" "$MDDD_VERSION" "$MDDD_OUT" <<'PYEOF'
import re
import sys

path, version, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
pattern = re.compile(
    r"^## \[%s\] - \d{4}-\d{2}-\d{2}\n(.*?)(?=\n## \[|\Z)"
    % re.escape(version),
    re.S | re.M,
)
m = pattern.search(text)
if not m:
    raise SystemExit("CHANGELOG 中未找到版本块 [%s]" % version)
block = m.group(1)

section_map = {
    "### Added": "### 新功能 (Added)",
    "### Changed": "### 调整与优化 (Changed)",
    "### Fixed": "### 修复 (Fixed)",
    "### Removed": "### 移除 (Removed)",
}
body = [
    section_map.get(line.strip(), line)
    for line in block.strip("\n").split("\n")
]
# 去掉块尾部的 `---` 分隔符 (CHANGELOG 版本块间的分隔, 不属于正文)
while body and body[-1].strip() in ("---", ""):
    body.pop()

with open(out_path, "w", encoding="utf-8") as f:
    f.write("## mddd %s 发布说明\n\n" % version)
    f.write("\n".join(body).strip() + "\n")
print("生成:", out_path)
PYEOF
