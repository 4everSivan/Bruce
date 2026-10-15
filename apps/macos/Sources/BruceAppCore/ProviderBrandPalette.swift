import Foundation

// MARK: - ProviderBrandPalette

/// 订阅 Provider 品牌色板 (双端唯一事实源)。
///
/// Windows 端 apps/win/src/app.js 的 `PROVIDER_COLORS` 镜像本表 (既有约定:
/// 品牌色板以 mac 侧为唯一事实源)。Z.ai 自 C026 起改用官方锁版深色
/// #2D2D2D (取代旧蓝 #3859ff), 与 z.ai 官方 logo 的深色瓷砖保持一致。
package enum ProviderBrandPalette {
    /// 品牌色十六进制值; 未知 provider 返回中性灰 (与徽章兜底同一语义)。
    package static func hex(for providerID: String) -> String {
        switch providerID {
        case "kimi":
            return "#0a84ff"
        case "deepseek":
            return "#4d6bfe"
        case "volcengine":
            return "#ff6a00"
        case "zhipu":
            return "#2D2D2D"
        case "codex", "openai":
            return "#10a37f"
        case "claude":
            return "#d97757"
        case "grok":
            return "#111111"
        case "opencodeGo", "opencode-go", "opencode":
            return "#8a63d2"
        case "stepfun":
            return "#0c5efc"
        case "jev":
            return "#e551ba"
        case "cline":
            return "#18181b"
        default:
            return "#8e8e93"
        }
    }

    /// 深色品牌色 (grok / zhipu / cline): Nothing 主题深色表面不可读,
    /// 图形与字母退回 secondary 灰 (定稿于 grok, C026 起覆盖同色系品牌)。
    package static func isDarkBrand(_ providerID: String) -> Bool {
        switch providerID {
        case "grok", "zhipu", "cline":
            return true
        default:
            return false
        }
    }
}
