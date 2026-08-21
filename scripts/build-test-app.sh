#!/bin/zsh

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_SWIFT_PACKAGE="$BRUCE_REPO_ROOT/macos/BruceApp"
BRUCE_DIST_DIR="$BRUCE_REPO_ROOT/dist"
BRUCE_OUTPUT_APP="$BRUCE_DIST_DIR/Bruce.app"
BRUCE_OUTPUT_ZIP="$BRUCE_DIST_DIR/Bruce.zip"
BRUCE_STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/Bruce-build.XXXXXX")
BRUCE_STAGED_APP="$BRUCE_STAGING_ROOT/Bruce.app"
BRUCE_CONTENTS="$BRUCE_STAGED_APP/Contents"
BRUCE_RESOURCES="$BRUCE_CONTENTS/Resources"

cleanup() {
    rm -rf "$BRUCE_STAGING_ROOT"
}
trap cleanup EXIT

required_commands=(swift cargo codesign plutil ditto strip rg)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "缺少构建命令: $required_command" >&2
        exit 1
    fi
done

source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"
Bruce_validate_packaging_sources "$BRUCE_REPO_ROOT"
echo "编译 Rust Collector (Preview 使用同一 binary 来源)"
Bruce_build_rust_collector "$BRUCE_REPO_ROOT" release
Bruce_validate_rust_source "$BRUCE_REPO_ROOT" release

echo "编译 Bruce Preview 可执行文件"
swift build \
    --package-path "$BRUCE_SWIFT_PACKAGE" \
    --configuration debug \
    --product BruceApp
BRUCE_BIN_DIR=$(swift build \
    --package-path "$BRUCE_SWIFT_PACKAGE" \
    --configuration debug \
    --show-bin-path)
BRUCE_EXECUTABLE="$BRUCE_BIN_DIR/BruceApp"

if [[ ! -x "$BRUCE_EXECUTABLE" ]]; then
    echo "Release 可执行文件不存在: $BRUCE_EXECUTABLE" >&2
    exit 1
fi

echo "组装 Bruce.app"
mkdir -p "$BRUCE_CONTENTS/MacOS" "$BRUCE_RESOURCES"

ditto "$BRUCE_EXECUTABLE" "$BRUCE_CONTENTS/MacOS/BruceApp"
chmod 755 "$BRUCE_CONTENTS/MacOS/BruceApp"
strip -S "$BRUCE_CONTENTS/MacOS/BruceApp"
Bruce_copy_rust_collector "$BRUCE_REPO_ROOT" "$BRUCE_RESOURCES" release

ditto "$BRUCE_REPO_ROOT/macos/BruceApp/Assets/AppIcon.icns" \
    "$BRUCE_RESOURCES/AppIcon.icns"

BRUCE_INFO_PLIST="$BRUCE_CONTENTS/Info.plist"
plutil -create xml1 "$BRUCE_INFO_PLIST"
plutil -insert CFBundleDevelopmentRegion -string "zh_CN" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleDisplayName -string "Bruce" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleExecutable -string "BruceApp" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleIdentifier -string "io.bruce.dashboard" \
    "$BRUCE_INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" \
    "$BRUCE_INFO_PLIST"
plutil -insert CFBundleName -string "Bruce" "$BRUCE_INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$BRUCE_INFO_PLIST"
# 版本号单一事实源: 从仓库根 VERSION 读取.
BRUCE_VERSION=$(tr -d '[:space:]' < "$BRUCE_REPO_ROOT/VERSION")
if [[ -z "$BRUCE_VERSION" ]]; then
    echo "无法从 VERSION 读取版本号" >&2
    exit 1
fi
plutil -insert CFBundleShortVersionString -string "$BRUCE_VERSION" \
    "$BRUCE_INFO_PLIST"
plutil -insert CFBundleVersion -string "1" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$BRUCE_INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "14.0" "$BRUCE_INFO_PLIST"
plutil -insert LSUIElement -bool YES "$BRUCE_INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$BRUCE_INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$BRUCE_INFO_PLIST"

echo "签名并校验 App Bundle"
plutil -lint "$BRUCE_INFO_PLIST"
codesign --force --deep --sign - --timestamp=none "$BRUCE_STAGED_APP"
codesign --verify --deep --strict "$BRUCE_STAGED_APP"

if [[ ! -x "$BRUCE_CONTENTS/MacOS/BruceApp" ]]; then
    echo "App 主可执行文件不可执行" >&2
    exit 1
fi

packaged_resources=("$BRUCE_RESOURCES/Bruce-collector")
for packaged_resource in "${packaged_resources[@]}"; do
    if [[ ! -f "$packaged_resource" ]]; then
        echo "App Bundle 缺少资源: $packaged_resource" >&2
        exit 1
    fi
done

if rg -a -F -q "$BRUCE_REPO_ROOT" "$BRUCE_STAGED_APP"; then
    echo "App Bundle 包含源码仓库绝对路径" >&2
    rg -a -F -l "$BRUCE_REPO_ROOT" "$BRUCE_STAGED_APP" >&2
    exit 1
fi
if rg -a -q "gzky\\.com|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY" \
    "$BRUCE_STAGED_APP"; then
    echo "App Bundle 疑似包含敏感信息" >&2
    exit 1
fi
Bruce_validate_release_bundle "$BRUCE_STAGED_APP"

echo "写入 dist 打包产物"
mkdir -p "$BRUCE_DIST_DIR"
if [[ "$BRUCE_OUTPUT_APP" != "$BRUCE_REPO_ROOT/dist/Bruce.app" ]] \
    || [[ "$BRUCE_OUTPUT_ZIP" != "$BRUCE_REPO_ROOT/dist/Bruce.zip" ]]; then
    echo "拒绝替换非预期输出路径" >&2
    exit 1
fi
rm -rf "$BRUCE_OUTPUT_APP"
rm -f "$BRUCE_OUTPUT_ZIP"
mv "$BRUCE_STAGED_APP" "$BRUCE_OUTPUT_APP"
ditto -c -k --sequesterRsrc --keepParent \
    "$BRUCE_OUTPUT_APP" "$BRUCE_OUTPUT_ZIP"

echo "运行 Collector 安装/升级/回滚与旧 cache smoke (Preview 证据)"
zsh "$BRUCE_SCRIPT_DIR/collector-release-smoke.sh" \
    "$BRUCE_OUTPUT_APP" --local-preview

echo "Bruce App 已生成:"
echo "  $BRUCE_OUTPUT_APP"
echo "  $BRUCE_OUTPUT_ZIP"
