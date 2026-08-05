#!/bin/zsh

set -euo pipefail

MDDD_SCRIPT_DIR=${0:A:h}
MDDD_REPO_ROOT=${MDDD_SCRIPT_DIR:h}
MDDD_SWIFT_PACKAGE="$MDDD_REPO_ROOT/macos/MdddApp"
MDDD_DIST_DIR="$MDDD_REPO_ROOT/dist"
MDDD_OUTPUT_APP="$MDDD_DIST_DIR/mddd.app"
MDDD_OUTPUT_ZIP="$MDDD_DIST_DIR/mddd.zip"
MDDD_STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mddd-build.XXXXXX")
MDDD_STAGED_APP="$MDDD_STAGING_ROOT/mddd.app"
MDDD_CONTENTS="$MDDD_STAGED_APP/Contents"
MDDD_RESOURCES="$MDDD_CONTENTS/Resources"
MDDD_RUNTIME="$MDDD_RESOURCES/runtime"

cleanup() {
    rm -rf "$MDDD_STAGING_ROOT"
}
trap cleanup EXIT

required_commands=(swift codesign plutil ditto strip rg)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "缺少构建命令: $required_command" >&2
        exit 1
    fi
done

required_sources=(
    "$MDDD_REPO_ROOT/bridge/__init__.py"
    "$MDDD_REPO_ROOT/bridge/run_bridge.py"
    "$MDDD_REPO_ROOT/bridge/security.py"
    "$MDDD_REPO_ROOT/bridge/schemas"
    "$MDDD_REPO_ROOT/agent-usage/collector/collect_usage.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/pricing.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/runtime.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/quota_services.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/local_usage.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/codex_compat.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/quota_official.py"
    "$MDDD_REPO_ROOT/agent-usage/collector/service_catalog.py"
    "$MDDD_REPO_ROOT/macos/MdddApp/Assets/AppIcon.icns"
)
for required_source in "${required_sources[@]}"; do
    if [[ ! -e "$required_source" ]]; then
        echo "缺少打包资源: $required_source" >&2
        exit 1
    fi
done

echo "编译 mddd Release 可执行文件"
swift build \
    --package-path "$MDDD_SWIFT_PACKAGE" \
    --configuration release \
    --product MdddApp
MDDD_BIN_DIR=$(swift build \
    --package-path "$MDDD_SWIFT_PACKAGE" \
    --configuration release \
    --show-bin-path)
MDDD_EXECUTABLE="$MDDD_BIN_DIR/MdddApp"

if [[ ! -x "$MDDD_EXECUTABLE" ]]; then
    echo "Release 可执行文件不存在: $MDDD_EXECUTABLE" >&2
    exit 1
fi

echo "组装 mddd.app"
mkdir -p "$MDDD_CONTENTS/MacOS" "$MDDD_RESOURCES" \
    "$MDDD_RUNTIME/bridge" \
    "$MDDD_RUNTIME/agent-usage/collector"

ditto "$MDDD_EXECUTABLE" "$MDDD_CONTENTS/MacOS/MdddApp"
chmod 755 "$MDDD_CONTENTS/MacOS/MdddApp"
strip -S "$MDDD_CONTENTS/MacOS/MdddApp"
ditto "$MDDD_REPO_ROOT/bridge/__init__.py" \
    "$MDDD_RUNTIME/bridge/__init__.py"
ditto "$MDDD_REPO_ROOT/bridge/run_bridge.py" \
    "$MDDD_RUNTIME/bridge/run_bridge.py"
ditto "$MDDD_REPO_ROOT/bridge/security.py" \
    "$MDDD_RUNTIME/bridge/security.py"
ditto "$MDDD_REPO_ROOT/bridge/schemas" \
    "$MDDD_RUNTIME/bridge/schemas"
ditto "$MDDD_REPO_ROOT/agent-usage/collector/collect_usage.py" \
    "$MDDD_RUNTIME/agent-usage/collector/collect_usage.py"
# 阶段 D 拆分出的 collector 子模块必须一并打包, 否则运行时 import 失败
for module in pricing runtime quota_services local_usage codex_compat quota_official service_catalog; do
    ditto "$MDDD_REPO_ROOT/agent-usage/collector/$module.py" \
        "$MDDD_RUNTIME/agent-usage/collector/$module.py"
done

ditto "$MDDD_REPO_ROOT/macos/MdddApp/Assets/AppIcon.icns" \
    "$MDDD_RESOURCES/AppIcon.icns"

MDDD_INFO_PLIST="$MDDD_CONTENTS/Info.plist"
plutil -create xml1 "$MDDD_INFO_PLIST"
plutil -insert CFBundleDevelopmentRegion -string "zh_CN" "$MDDD_INFO_PLIST"
plutil -insert CFBundleDisplayName -string "mddd" "$MDDD_INFO_PLIST"
plutil -insert CFBundleExecutable -string "MdddApp" "$MDDD_INFO_PLIST"
plutil -insert CFBundleIdentifier -string "io.mddd.dashboard" \
    "$MDDD_INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" \
    "$MDDD_INFO_PLIST"
plutil -insert CFBundleName -string "mddd" "$MDDD_INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$MDDD_INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "0.1.0" \
    "$MDDD_INFO_PLIST"
plutil -insert CFBundleVersion -string "1" "$MDDD_INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$MDDD_INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "14.0" "$MDDD_INFO_PLIST"
plutil -insert LSUIElement -bool YES "$MDDD_INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$MDDD_INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$MDDD_INFO_PLIST"

echo "签名并校验 App Bundle"
plutil -lint "$MDDD_INFO_PLIST"
codesign --force --deep --sign - --timestamp=none "$MDDD_STAGED_APP"
codesign --verify --deep --strict "$MDDD_STAGED_APP"

if [[ ! -x "$MDDD_CONTENTS/MacOS/MdddApp" ]]; then
    echo "App 主可执行文件不可执行" >&2
    exit 1
fi

packaged_resources=(
    "$MDDD_RUNTIME/bridge/run_bridge.py"
    "$MDDD_RUNTIME/agent-usage/collector/collect_usage.py"
)
for packaged_resource in "${packaged_resources[@]}"; do
    if [[ ! -f "$packaged_resource" ]]; then
        echo "App Bundle 缺少资源: $packaged_resource" >&2
        exit 1
    fi
done

if rg -a -F -q "$MDDD_REPO_ROOT" "$MDDD_STAGED_APP"; then
    echo "App Bundle 包含源码仓库绝对路径" >&2
    rg -a -F -l "$MDDD_REPO_ROOT" "$MDDD_STAGED_APP" >&2
    exit 1
fi
if rg -a -q "gzky\\.com|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY" \
    "$MDDD_STAGED_APP"; then
    echo "App Bundle 疑似包含敏感信息" >&2
    exit 1
fi

echo "写入 dist 打包产物"
mkdir -p "$MDDD_DIST_DIR"
if [[ "$MDDD_OUTPUT_APP" != "$MDDD_REPO_ROOT/dist/mddd.app" ]] \
    || [[ "$MDDD_OUTPUT_ZIP" != "$MDDD_REPO_ROOT/dist/mddd.zip" ]]; then
    echo "拒绝替换非预期输出路径" >&2
    exit 1
fi
rm -rf "$MDDD_OUTPUT_APP"
rm -f "$MDDD_OUTPUT_ZIP"
mv "$MDDD_STAGED_APP" "$MDDD_OUTPUT_APP"
ditto -c -k --sequesterRsrc --keepParent \
    "$MDDD_OUTPUT_APP" "$MDDD_OUTPUT_ZIP"

echo "mddd App 已生成:"
echo "  $MDDD_OUTPUT_APP"
echo "  $MDDD_OUTPUT_ZIP"
