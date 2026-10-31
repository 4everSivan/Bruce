#!/bin/zsh
# Preview / Release 打包共用同一份静态资源清单的回归检查 (C168)。
#
# 1. build-test-app.sh 与 build-release-app.sh 都经 Bruce_copy_bundle_resources 投放资源并
#    以 Bruce_validate_bundle_resources 校验, 不得再直接 ditto apps/macos/Assets/
#    (此前两份手写清单漂移, Release 漏了 Nothing 主题字体);
# 2. 按清单投放到临时 Bundle 后校验通过, 字体 / Agent 位图 / 图标齐全;
# 3. 删掉字体目录后校验必须失败 (校验本身不是空转)。
#
# 临时 Bundle 建在系统临时目录并在退出时删除, 不写入源码树与 local/。

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"

for script in build-test-app.sh build-release-app.sh; do
    script_path="$BRUCE_SCRIPT_DIR/$script"
    if ! rg -q '^Bruce_copy_bundle_resources ' "$script_path"; then
        echo "$script 未调用 Bruce_copy_bundle_resources" >&2
        exit 1
    fi
    if ! rg -q '^Bruce_validate_bundle_resources ' "$script_path"; then
        echo "$script 未调用 Bruce_validate_bundle_resources" >&2
        exit 1
    fi
    if rg -n 'ditto "\$BRUCE_REPO_ROOT/apps/macos/Assets/' "$script_path" >&2; then
        echo "$script 仍直接投放 apps/macos/Assets, 须改为登记到 BRUCE_BUNDLE_FILES" >&2
        exit 1
    fi
done

Bruce_validate_packaging_sources "$BRUCE_REPO_ROOT"

bundle_root=$(mktemp -d "${TMPDIR:-/tmp}/bruce-bundle-resources.XXXXXX")
trap 'rm -rf "$bundle_root"' EXIT
app_root="$bundle_root/Bruce.app"
mkdir -p "$app_root/Contents/Resources"

Bruce_copy_bundle_resources "$BRUCE_REPO_ROOT" "$app_root/Contents/Resources"
Bruce_validate_bundle_resources "$app_root"
for required in AppIcon.icns Fonts/SpaceMono-Regular.ttf 'Fonts/Doto[ROND,wght].ttf' 'Fonts/SpaceGrotesk[wght].ttf' AgentIcons/agent-codex.png; do
    if [[ ! -f "$app_root/Contents/Resources/$required" ]]; then
        echo "按清单投放后缺少 Resources/$required" >&2
        exit 1
    fi
done

rm -rf "$app_root/Contents/Resources/Fonts"
if Bruce_validate_bundle_resources "$app_root" 2>/dev/null; then
    echo "缺少 Fonts 时 Bruce_validate_bundle_resources 未报错" >&2
    exit 1
fi

echo "Bundle 静态资源清单检查通过 (${#BRUCE_BUNDLE_FILES[@]} 项, Preview / Release 同源)"
