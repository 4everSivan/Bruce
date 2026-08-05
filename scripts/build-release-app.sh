#!/bin/zsh

# mddd 正式版打包脚本 (08-production-packaging-and-release.md §3)
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

MDDD_SCRIPT_DIR=${0:A:h}
MDDD_REPO_ROOT=${MDDD_SCRIPT_DIR:h}
MDDD_SWIFT_PACKAGE="$MDDD_REPO_ROOT/macos/MdddApp"
MDDD_DIST_DIR="$MDDD_REPO_ROOT/dist"
MDDD_ENTITLEMENTS="$MDDD_REPO_ROOT/scripts/entitlements-release.plist"
MDDD_STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mddd-release.XXXXXX")
MDDD_STAGED_APP="$MDDD_STAGING_ROOT/Mddd.app"
MDDD_CONTENTS="$MDDD_STAGED_APP/Contents"
MDDD_RESOURCES="$MDDD_CONTENTS/Resources"
MDDD_RUNTIME="$MDDD_RESOURCES/runtime"

# ---------------------------------------------------------------- 参数与配置

if [[ $# -lt 1 ]]; then
    echo "用法: zsh scripts/build-release-app.sh <tag>" >&2
    echo "  tag 形如 v1.2.3, 必须与 git 当前 HEAD 匹配" >&2
    exit 1
fi
MDDD_TAG="$1"

if [[ ! "$MDDD_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "tag 格式无效: $MDDD_TAG (需要 v<major>.<minor>.<patch>)" >&2
    exit 1
fi
MDDD_VERSION="${MDDD_TAG#v}"
MDDD_BUILD_NUMBER="${CI_BUILD_NUMBER:-1}"

# 正式 bundle ID 与版本来源必须显式配置, 禁止沿用测试脚本的固定值
MDDD_BUNDLE_ID="${MDDD_RELEASE_BUNDLE_ID:-}"
if [[ -z "$MDDD_BUNDLE_ID" ]]; then
    echo "缺少正式 bundle ID: 设置环境变量 MDDD_RELEASE_BUNDLE_ID" >&2
    exit 1
fi

MDDD_DEVELOPER_ID="${MDDD_DEVELOPER_ID:-}"
MDDD_NOTARY_KEY_ID="${MDDD_NOTARY_KEY_ID:-}"
MDDD_NOTARY_ISSUER_ID="${MDDD_NOTARY_ISSUER_ID:-}"
MDDD_NOTARY_KEY_PATH="${MDDD_NOTARY_KEY_PATH:-}"
# 公证密钥路径为外部输入, 允许来自仓库外的受保护变量
MDDD_NOTARY_KEY_RESOLVED="${MDDD_NOTARY_KEY_PATH}"

cleanup() {
    rm -rf "$MDDD_STAGING_ROOT"
}
trap cleanup EXIT

required_commands=(swift codesign plutil ditto strip rg xcrun spctl)
for required_command in "${required_commands[@]}"; do
    if ! command -v "$required_command" >/dev/null 2>&1; then
        echo "缺少构建命令: $required_command" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------- 阶段 1: 清理和验证

echo "[1/5] 验证工作树与 tag"

if [[ -n "$(git -C "$MDDD_REPO_ROOT" status --porcelain)" ]]; then
    echo "工作树不干净, 正式版构建要求干净工作树" >&2
    exit 1
fi

MDDD_CURRENT_TAG=$(git -C "$MDDD_REPO_ROOT" describe --exact-match --tags HEAD 2>/dev/null || true)
if [[ "$MDDD_CURRENT_TAG" != "$MDDD_TAG" ]]; then
    echo "HEAD 不匹配 tag $MDDD_TAG (当前: ${MDDD_CURRENT_TAG:-无})" >&2
    exit 1
fi

echo "运行完整验证套件 (verify-local.sh)"
zsh "$MDDD_REPO_ROOT/scripts/verify-local.sh"

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
)
for required_source in "${required_sources[@]}"; do
    if [[ ! -e "$required_source" ]]; then
        echo "缺少打包资源: $required_source" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------- 阶段 2: Release 构建

echo "[2/5] Release 构建与 App 组装"

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
for module in pricing runtime quota_services local_usage codex_compat quota_official; do
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
plutil -insert CFBundleIdentifier -string "$MDDD_BUNDLE_ID" "$MDDD_INFO_PLIST"
plutil -insert CFBundleInfoDictionaryVersion -string "6.0" "$MDDD_INFO_PLIST"
plutil -insert CFBundleName -string "mddd" "$MDDD_INFO_PLIST"
plutil -insert CFBundlePackageType -string "APPL" "$MDDD_INFO_PLIST"
plutil -insert CFBundleShortVersionString -string "$MDDD_VERSION" "$MDDD_INFO_PLIST"
plutil -insert CFBundleVersion -string "$MDDD_BUILD_NUMBER" "$MDDD_INFO_PLIST"
plutil -insert CFBundleIconFile -string "AppIcon" "$MDDD_INFO_PLIST"
plutil -insert LSMinimumSystemVersion -string "26.0" "$MDDD_INFO_PLIST"
plutil -insert LSUIElement -bool YES "$MDDD_INFO_PLIST"
plutil -insert NSHighResolutionCapable -bool YES "$MDDD_INFO_PLIST"
plutil -insert NSPrincipalClass -string "NSApplication" "$MDDD_INFO_PLIST"
plutil -lint "$MDDD_INFO_PLIST"

# ---------------------------------------------------------------- 阶段 3: 签名

echo "[3/5] Hardened Runtime 签名"

if [[ -z "$MDDD_DEVELOPER_ID" ]]; then
    echo "缺少 Developer ID: 设置环境变量 MDDD_DEVELOPER_ID" >&2
    echo "未签名包不会写入 dist, 请配置证书后重试" >&2
    exit 1
fi
if [[ ! -f "$MDDD_ENTITLEMENTS" ]]; then
    echo "缺少 entitlement 文件: $MDDD_ENTITLEMENTS" >&2
    exit 1
fi

codesign --force --options runtime \
    --entitlements "$MDDD_ENTITLEMENTS" \
    --sign "$MDDD_DEVELOPER_ID" \
    "$MDDD_STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$MDDD_STAGED_APP"
codesign -dvv "$MDDD_STAGED_APP" 2>&1 | grep -E "Signature|TeamIdentifier" \
    || echo "(codesign -dvv 输出格式随工具链变化)"

# ---------------------------------------------------------------- 阶段 4: 公证

echo "[4/5] notarization 与 stapler"

if [[ -z "$MDDD_NOTARY_KEY_ID" || -z "$MDDD_NOTARY_ISSUER_ID" \
    || -z "$MDDD_NOTARY_KEY_RESOLVED" ]]; then
    echo "缺少公证 API Key 配置 (MDDD_NOTARY_KEY_ID/MDDD_NOTARY_ISSUER_ID/" >&2
    echo "MDDD_NOTARY_KEY_PATH), 未公证包不会发布" >&2
    exit 1
fi

MDDD_ZIP="$MDDD_STAGING_ROOT/Mddd.zip"
ditto -c -k --sequesterRsrc --keepParent "$MDDD_STAGED_APP" "$MDDD_ZIP"

MDDD_NOTARY_LOG="$MDDD_STAGING_ROOT/notary-request.log"
if ! xcrun notarytool submit "$MDDD_ZIP" \
    --key "$MDDD_NOTARY_KEY_RESOLVED" \
    --key-id "$MDDD_NOTARY_KEY_ID" \
    --issuer "$MDDD_NOTARY_ISSUER_ID" \
    --wait \
    --output-format json > "$MDDD_NOTARY_LOG" 2>&1; then
    echo "公证失败, 详见: $MDDD_NOTARY_LOG" >&2
    echo "不发布任何包" >&2
    exit 1
fi
xcrun stapler staple "$MDDD_STAGED_APP"
xcrun stapler validate "$MDDD_STAGED_APP"

# ---------------------------------------------------------------- 阶段 5: 验收与产物

echo "[5/5] Gatekeeper 验收与产物生成"

spctl --assess --type execute --verbose=4 "$MDDD_STAGED_APP"

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

MDDD_FINAL_APP="$MDDD_DIST_DIR/mddd-$MDDD_VERSION-macos/Mddd.app"
MDDD_FINAL_ZIP="$MDDD_DIST_DIR/mddd-$MDDD_VERSION-macos/mddd-$MDDD_VERSION-macos.zip"
MDDD_SHA256="$MDDD_DIST_DIR/mddd-$MDDD_VERSION-macos/SHA256SUMS"
MDDD_NOTES="$MDDD_DIST_DIR/mddd-$MDDD_VERSION-macos/release-notes-$MDDD_VERSION.md"

mkdir -p "$(dirname "$MDDD_FINAL_APP")"
rm -rf "$(dirname "$MDDD_FINAL_APP")"
mkdir -p "$(dirname "$MDDD_FINAL_APP")"
ditto "$MDDD_STAGED_APP" "$MDDD_FINAL_APP"
ditto -c -k --sequesterRsrc --keepParent \
    "$MDDD_FINAL_APP" "$MDDD_FINAL_ZIP"
(
    cd "$(dirname "$MDDD_FINAL_ZIP")"
    shasum -a 256 "$(basename "$MDDD_FINAL_ZIP")" > "$MDDD_SHA256"
)

cat > "$MDDD_NOTES" <<EOF
# mddd $MDDD_VERSION 发布说明

- 版本: $MDDD_VERSION (构建号 $MDDD_BUILD_NUMBER)
- 渠道: Release (Developer ID + notarization)
- 变更: 以 Git tag 与提交历史为准
- 已知限制: 见仓库 docs/development/08-production-packaging-and-release.md
- 回滚版本: 上一通过验收的正式版本
EOF

echo "正式版已生成:"
echo "  $MDDD_FINAL_APP"
echo "  $MDDD_FINAL_ZIP"
echo "  $MDDD_SHA256"
echo "  $MDDD_NOTES"
