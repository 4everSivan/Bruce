#!/bin/zsh

# Bruce macOS DMG 磁盘镜像打包脚本 (C114 / design/00 §3.3)
#
# 将已构建好的 Bruce.app 封装为带 /Applications 软链接的 UDZO 压缩 DMG 磁盘镜像,
# 作为 GitHub Release 供用户首次下载拖拽安装的附加资产。
# 应用内自动更新 (T10) 仍继续消费 Bruce.zip, 二者在 Release 页面共存并共享同一版本基线。
#
# 用法:
#   zsh scripts/package-dmg.sh [APP_PATH] [DMG_PATH] [VOLUME_NAME]
#   若省略参数, 默认从 dist/Bruce.app 打包至 dist/Bruce-<VERSION>.dmg, 卷名为 "Bruce"

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}

APP_PATH="${1:-$BRUCE_REPO_ROOT/dist/Bruce.app}"
if [[ -z "${2:-}" ]]; then
    VERSION_FILE="$BRUCE_REPO_ROOT/VERSION"
    if [[ ! -f "$VERSION_FILE" ]]; then
        echo "版本文件不存在: $VERSION_FILE" >&2
        exit 1
    fi
    BRUCE_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE")
    DMG_PATH="$BRUCE_REPO_ROOT/dist/Bruce-${BRUCE_VERSION}.dmg"
else
    DMG_PATH="$2"
fi
VOL_NAME="${3:-Bruce}"

required_commands=(hdiutil ditto)
for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "缺少必要命令: $cmd" >&2
        exit 1
    fi
done

if [[ ! -d "$APP_PATH" || ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    echo "目标 App Bundle 不存在或不完整: $APP_PATH" >&2
    exit 1
fi

STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bruce-dmg-staging.XXXXXX")
cleanup() {
    rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

echo "准备 DMG 镜像暂存目录: $STAGING_ROOT"
ditto "$APP_PATH" "$STAGING_ROOT/Bruce.app"
ln -s /Applications "$STAGING_ROOT/Applications"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

echo "创建 UDZO 压缩 DMG: $DMG_PATH (卷名: $VOL_NAME)"
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$STAGING_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ ! -s "$DMG_PATH" ]]; then
    echo "DMG 产物为空或创建失败: $DMG_PATH" >&2
    exit 1
fi

hdiutil imageinfo "$DMG_PATH" >/dev/null

DMG_SIZE=$(ls -lh "$DMG_PATH" | awk '{print $5}')
echo "Bruce DMG 镜像已生成:"
echo "  路径: $DMG_PATH"
echo "  大小: $DMG_SIZE"
