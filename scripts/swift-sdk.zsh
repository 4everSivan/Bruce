#!/bin/zsh

# macOS 27 的 Command Line Tools 目前提供 Swift 6.4, 但其默认
# MacOSX27.0 SDK 在没有完整 Xcode 时可能找不到 SwiftUI 宏插件.
# 只要用户没有显式指定 SDK, 在本机仍安装旧 CLT SDK 时回退到
# MacOSX26.5; 该 SDK 足够覆盖 Bruce 的 macOS 14/26 API 范围, 也不需要
# 安装约 10 GB 的 Xcode. 显式 SDKROOT 始终优先, 不被脚本覆盖.
function Bruce_prepare_swift_sdk() {
    if [[ -n "${SDKROOT:-}" ]]; then
        echo "使用显式 Swift SDK: $SDKROOT"
        return 0
    fi

    local detected_sdk=""
    if command -v xcrun >/dev/null 2>&1; then
        detected_sdk=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)
    fi
    if [[ -z "$detected_sdk" || ! -f "$detected_sdk/SDKSettings.plist" ]]; then
        echo "无法解析 macOS Swift SDK, 使用 Swift 默认配置" >&2
        return 0
    fi

    local canonical_name=""
    canonical_name=$(plutil -extract CanonicalName raw -o - \
        "$detected_sdk/SDKSettings.plist" 2>/dev/null || true)
    local compatible_sdk="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
    if [[ "$canonical_name" == "macosx27.0" && -d "$compatible_sdk" ]]; then
        export SDKROOT="$compatible_sdk"
        echo "macOS 27 CLT 宏插件兼容性回退: SDKROOT=$SDKROOT"
    else
        export SDKROOT="$detected_sdk"
        echo "使用 Swift SDK: $SDKROOT"
    fi
}
