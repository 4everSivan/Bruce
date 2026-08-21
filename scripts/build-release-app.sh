#!/bin/zsh

# Bruce 正式版打包脚本 (08-production-packaging-and-release.md §3)
#
# 与 Preview 脚本 (build-test-app.sh) 分离: 正式版使用 Developer ID 签名 +
# Hardened Runtime + notarization, 版本来源为 Git tag, 产物带 SHA256 校验和.
#
# 前置条件 (08 §2):
#   - Git tag v<major>.<minor>.<patch>
#   - Developer ID Application 证书
#   - App Store Connect API Key (公证用)
#   - entitlement 文件 (scripts/entitlements-release.plist)
#
# 未配置前置条件时脚本在对应阶段清晰失败, 不会生成半成品或未签名包.
# 用法:
#   zsh scripts/build-release-app.sh <tag>            # 本机正式构建
#   CI: 由 .github/workflows/ci.yml 的 protected release job 调用

set -euo pipefail

BRUCE_SCRIPT_DIR=${0:A:h}
BRUCE_REPO_ROOT=${BRUCE_SCRIPT_DIR:h}
BRUCE_SWIFT_PACKAGE="$BRUCE_REPO_ROOT/macos/BruceApp"
BRUCE_DIST_DIR="$BRUCE_REPO_ROOT/dist"
BRUCE_ENTITLEMENTS="$BRUCE_REPO_ROOT/scripts/entitlements-release.plist"
BRUCE_STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/Bruce-release.XXXXXX")
BRUCE_STAGED_APP="$BRUCE_STAGING_ROOT/Bruce.app"
BRUCE_CONTENTS="$BRUCE_STAGED_APP/Contents"
BRUCE_RESOURCES="$BRUCE_CONTENTS/Resources"
BRUCE_RUNTIME="$BRUCE_RESOURCES/runtime"

# ---------------------------------------------------------------- 参数与配置

if [[ $# -lt 1 ]]; then
    echo "用法: zsh scripts/build-release-app.sh <tag>" >&2
    echo "  tag 形如 v1.2.3, 必须与 git 当前 HEAD 匹配" >&2
    exit 1
fi
BRUCE_TAG="$1"

if [[ ! "$BRUCE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "tag 格式无效: $BRUCE_TAG (需要 v<major>.<minor>.<patch>)" >&2
    exit 1
fi
BRUCE_VERSION="${BRUCE_TAG#v}"
BRUCE_BUILD_NUMBER="${CI_BUILD_NUMBER:-1}"

# 正式 bundle ID 与版本来源必须显式配置, 禁止沿用测试脚本的固定值
BRUCE_BUNDLE_ID="${BRUCE_RELEASE_BUNDLE_ID:-}"
if [[ -z "$BRUCE_BUNDLE_ID" ]]; then
    echo "缺少正式 bundle ID: 设置环境变量 BRUCE_RELEASE_BUNDLE_ID" >&2
    exit 1
fi

BRUCE_DEVELOPER_ID="${BRUCE_DEVELOPER_ID:-}"
BRUCE_NOTARY_KEY_ID="${BRUCE_NOTARY_KEY_ID:-}"
BRUCE_NOTARY_ISSUER_ID="${BRUCE_NOTARY_ISSUER_ID:-}"
BRUCE_NOTARY_KEY_PATH="${BRUCE_NOTARY_KEY_PATH:-}"
# 公证密钥路径为外部输入, 允许来自仓库外的受保护变量
BRUCE_NOTARY_KEY_RESOLVED="${BRUCE_NOTARY_KEY_PATH}"

cleanup() {
    rm -rf "$BRUCE_STAGING_ROOT"
}
trap cleanup EXIT

required_commands=(swift codesign plutil ditto strip rg xcrun spctl)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "缺少构建命令: $required_command" >&2
        exit 1
    fi
done

source "$BRUCE_SCRIPT_DIR/runtime-manifest.zsh"

# ---------------------------------------------------------------- 阶段 1: 清理和验证

echo "[1/5] 验证工作树与 tag"

if [[ -n "$(git -C "$BRUCE_REPO_ROOT" status --porcelain)" ]]; then
    echo "工作树不干净, 正式版构建要求干净工作树" >&2
    exit 1
fi

BRUCE_CURRENT_TAG=$(git -C "$BRUCE_REPO_ROOT" describe --exact-match --tags HEAD 2>/dev/null || true)
if [[ "$BRUCE_CURRENT_TAG" != "$BRUCE_TAG" ]]; then
    echo "HEAD 不匹配 tag $BRUCE_TAG (当前: ${BRUCE_CURRENT_TAG:-无})" >&2
    exit 1
fi

echo "运行完整验证套件 (verify-local.sh)"
zsh "$BRUCE_REPO_ROOT/scripts/verify-local.sh"

Bruce_validate_packaging_sources "$BRUCE_REPO_ROOT"

# ---------------------------------------------------------------- 阶段 2: Release 构建

echo "[2/5] Release 构建与 App 组装"

swift build \
    --package-path "$BRUCE_SWIFT_PACKAGE" \
    --configuration release \
    --product BruceApp
BRUCE_BIN_DIR=$(swift build \
    --package-path "$BRUCE_SWIFT_PACKAGE" \
    --configuration release \
    --show-bin-path)
BRUCE_EXECUTABLE="$BRUCE_BIN_DIR/BruceApp"

if [[ ! -x "$BRUCE_EXECUTABLE" ]]; then
    echo "Release 可执行文件不存在: $BRUCE_EXECUTABLE" >&2
    exit 1
fi

mkdir -p "$BRUCE_CONTENTS/MacOS" "$BRUCE_RESOURCES" \
    "$BRUCE_RUNTIME/bridge" \
    "$BRUCE_RUNTIME/agent-usage/collector"

ditto "$BRUCE_EXECUTABLE" "$BRUCE_CONTENTS/MacOS/BruceApp"
chmod 755 "$BRUCE_CONTENTS/MacOS/BruceApp"
strip -S "$BRUCE_CONTENTS/MacOS/BruceApp"
Bruce_copy_runtime "$BRUCE_REPO_ROOT" "$BRUCE_RUNTIME"

ditto "$BRUCE_REPO_ROOT/macos/BruceApp/Assets/AppIcon.icns" \
    "$BRUCE_RESOURCES/AppIcon.icns"

BRUCE_INFO_PLIST="$BRUCE_CONTENTS/Info.plist"
plutil -create xml1 "$BRUCE_INFO_PLIST"
plutil -insert CFBundleDevelopmentRegion -string "zh_CN" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleDisplayName -string "Bruce" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleExecutable -string "BruceApp" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleIdentifier -string "$BRUCE_BUNDLE_ID" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleName -string "Bruce" "$BRUCE_INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$BRUCE_VERSION" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleVersion -string "$BRUCE_BUILD_NUMBER" "$BRUCE_INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$BRUCE_INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "14.0" "$BRUCE_INFO_PLIST"
plutil -insert LSUIElement -bool YES "$BRUCE_INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$BRUCE_INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$BRUCE_INFO_PLIST"
plutil -lint "$BRUCE_INFO_PLIST"

# ---------------------------------------------------------------- 阶段 3: 签名

echo "[3/5] Hardened Runtime 签名"

if [[ -z "$BRUCE_DEVELOPER_ID" ]]; then
    echo "缺少 Developer ID: 设置环境变量 BRUCE_DEVELOPER_ID" >&2
    echo "未签名包不会写入 dist, 请配置证书后重试" >&2
    exit 1
fi
if [[ ! -f "$BRUCE_ENTITLEMENTS" ]]; then
    echo "缺少 entitlement 文件: $BRUCE_ENTITLEMENTS" >&2
    exit 1
fi

codesign --force --options runtime \
    --entitlements "$BRUCE_ENTITLEMENTS" \
    --sign "$BRUCE_DEVELOPER_ID" \
    "$BRUCE_STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$BRUCE_STAGED_APP"
codesign -dvv "$BRUCE_STAGED_APP" 2>&1 | grep -E "Signature|TeamIdentifier" \
    || echo "(codesign -dvv 输出格式随工具链变化)"

# ---------------------------------------------------------------- 阶段 4: 公证

echo "[4/5] notarization 与 stapler"

if [[ -z "$BRUCE_NOTARY_KEY_ID" || -z "$BRUCE_NOTARY_ISSUER_ID" \
    || -z "$BRUCE_NOTARY_KEY_RESOLVED" ]]; then
    echo "缺少公证 API Key 配置 (BRUCE_NOTARY_KEY_ID/BRUCE_NOTARY_ISSUER_ID/" >&2
    echo "BRUCE_NOTARY_KEY_PATH), 未公证包不会发布" >&2
    exit 1
fi

BRUCE_ZIP="$BRUCE_STAGING_ROOT/Bruce.zip"
ditto -c -k --sequesterRsrc --keepParent "$BRUCE_STAGED_APP" "$BRUCE_ZIP"

BRUCE_NOTARY_LOG="$BRUCE_STAGING_ROOT/notary-request.log"
if ! xcrun notarytool submit "$BRUCE_ZIP" \
    --key "$BRUCE_NOTARY_KEY_RESOLVED" \
    --key-id "$BRUCE_NOTARY_KEY_ID" \
    --issuer "$BRUCE_NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$BRUCE_NOTARY_LOG" 2>&1; then
    echo "公证失败, 详见: $BRUCE_NOTARY_LOG" >&2
    echo "不发布任何包" >&2
    exit 1
fi
xcrun stapler staple "$BRUCE_STAGED_APP"
xcrun stapler validate "$BRUCE_STAGED_APP"

# ---------------------------------------------------------------- 阶段 5: 验收与产物

echo "[5/5] Gatekeeper 验收与产物生成"

spctl --assess --type execute --verbose=4 "$BRUCE_STAGED_APP"

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

BRUCE_FINAL_APP="$BRUCE_DIST_DIR/Bruce-$BRUCE_VERSION-macos/Bruce.app"
BRUCE_FINAL_ZIP="$BRUCE_DIST_DIR/Bruce-$BRUCE_VERSION-macos/Bruce-$BRUCE_VERSION-macos.zip"
BRUCE_SHA256="$BRUCE_DIST_DIR/Bruce-$BRUCE_VERSION-macos/SHA256SUMS"
BRUCE_NOTES="$BRUCE_DIST_DIR/Bruce-$BRUCE_VERSION-macos/release-notes-$BRUCE_VERSION.md"

mkdir -p "$(dirname "$BRUCE_FINAL_APP")"
rm -rf "$(dirname "$BRUCE_FINAL_APP")"
mkdir -p "$(dirname "$BRUCE_FINAL_APP")"
ditto "$BRUCE_STAGED_APP" "$BRUCE_FINAL_APP"
ditto -c -k --sequesterRsrc --keepParent \
    "$BRUCE_FINAL_APP" "$BRUCE_FINAL_ZIP"
(
    cd "$(dirname "$BRUCE_FINAL_ZIP")"
    shasum -a 256 "$(basename "$BRUCE_FINAL_ZIP")" > "$BRUCE_SHA256"
)

# 发布说明从 CHANGELOG 生成 (风格与 v0.1/v0.2 一致), 不另写重复文案.
BRUCE_OUT="$BRUCE_NOTES" \
    zsh "$BRUCE_SCRIPT_DIR/release-notes.sh" "$BRUCE_VERSION"

echo "正式版已生成:"
echo "  $BRUCE_FINAL_APP"
echo "  $BRUCE_FINAL_ZIP"
echo "  $BRUCE_SHA256"
echo "  $BRUCE_NOTES"
