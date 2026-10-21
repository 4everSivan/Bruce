import Foundation
import BruceOnboardingCore

/// 跨源模型名归一化 (design 06 §4.1, C070 修订).
///
/// 只收敛「同一型号的不同写法」—— 渠道 / 厂商前缀、`[标记]`、快照日期与 `-latest` 后缀;
/// **不做跨型号别名合并** (C070 前的子串别名表会把 `glm-4.5` 记为 GLM 5.3、把任何含 `opus`
/// 的模型记为 Claude Opus 5.5、把 `deepseek-chat` 并入 `deepseek-v4.1-flash`, 不同单价的
/// 模型被混算). 费用不在这里计算: 采集端已按单价表为每个明细桶计价.
/// Windows 侧 `apps/win/viewmodel/src/analytics.rs` 逐条镜像本文件规则.
package enum ModelNormalizer {

    // MARK: - 规范键

    /// 规范键 (Canonical Key):
    /// 1. 小写、去首尾空白; 2. 截去第一个 `[` 起的标记; 3. 以最后一个 `/` 为界剥离前缀;
    /// 4. 剥离尾部 `-YYYYMMDD`, 其次 `-MMDD`; 5. 剥离尾部 `-latest`.
    /// 例: "cline-pass/deepseek-v4.1-flash" -> "deepseek-v4.1-flash";
    ///     "anthropic/claude-3-7-sonnet-20250219" -> "claude-3-7-sonnet";
    ///     "deepseek-r1[thinking]" -> "deepseek-r1"; "gpt-5.4-preview" 保持不变.
    package static func canonicalKey(for rawName: String) -> String {
        var key = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = key.firstIndex(of: "[") {
            key = String(key[..<bracket]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let slash = key.lastIndex(of: "/") {
            key = String(key[key.index(after: slash)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = key.range(of: #"-\d{8}$"#, options: .regularExpression) {
            key.removeSubrange(range)
        } else if let range = key.range(of: #"-\d{4}$"#, options: .regularExpression) {
            key.removeSubrange(range)
        }
        if key.hasSuffix("-latest") {
            key.removeLast("-latest".count)
        }
        return key.isEmpty ? "unknown" : key
    }

    // MARK: - 展示元数据

    /// 内置价格目录中与规范键精确相等 (目录模型名按同一规则归一) 的条目.
    private static func catalogEntry(for canonicalKey: String) -> BuiltinModelPricing? {
        BuiltinModelPricingCatalog.allModels.first {
            Self.canonicalKey(for: $0.modelName) == canonicalKey
        }
    }

    /// 展示名: 目录精确命中取目录展示名, 否则即规范键本身 (不臆造名称).
    package static func displayName(for canonicalKey: String) -> String {
        catalogEntry(for: canonicalKey)?.displayName ?? canonicalKey
    }

    /// 厂商: 目录精确命中取目录厂商, 否则按规范键前缀推断, 未知为「其他」.
    package static func vendor(for canonicalKey: String) -> String {
        if let entry = catalogEntry(for: canonicalKey) {
            return entry.vendor
        }
        for (prefixes, vendor) in vendorPrefixes where prefixes.contains(where: { canonicalKey.hasPrefix($0) }) {
            return vendor
        }
        return "其他"
    }

    /// 前缀 → 厂商 (目录未收录时的兜底, 按序匹配).
    private static let vendorPrefixes: [([String], String)] = [
        (["claude"], "Anthropic"),
        (["gpt", "o1", "o3", "o4", "codex"], "OpenAI"),
        (["deepseek"], "DeepSeek"),
        (["glm", "codegeex"], "智谱 AI (Zhipu)"),
        (["kimi", "k2", "k3", "moonshot"], "Moonshot"),
        (["gemini"], "Google"),
        (["qwen"], "阿里云 (Qwen)"),
        (["doubao"], "字节跳动 (Doubao)"),
        (["step"], "StepFun"),
        (["grok"], "xAI"),
        (["minimax", "abab"], "MiniMax"),
        (["hunyuan", "hy3", "hy4"], "腾讯混元"),
    ]

    /// 模型品牌识别色 (纯展示, 不参与统计; 按规范键子串匹配, 按序取首个).
    package static func colorHex(for canonicalKey: String) -> String {
        for (needles, hex) in brandColors where needles.contains(where: { canonicalKey.contains($0) }) {
            return hex
        }
        return "#8E8E93"
    }

    private static let brandColors: [([String], String)] = [
        (["claude", "sonnet", "opus"], "#FF9F0A"),
        (["deepseek"], "#30D158"),
        (["glm", "zhipu"], "#40C8E0"),
        (["gpt", "openai", "codex"], "#0A84FF"),
        (["gemini", "google"], "#1A73E8"),
        (["qwen", "tongyi"], "#624AFF"),
        (["doubao", "bytedance"], "#007AFF"),
        (["kimi", "k3"], "#BF5AF2"),
        (["step"], "#FF375F"),
        (["grok", "xai"], "#FFFFFF"),
        (["minimax", "abab"], "#E03E2D"),
        (["mimo", "xiaomi"], "#FF6900"),
        (["hunyuan", "tencent", "hy3", "hy4"], "#00A3FF"),
        (["baichuan"], "#E64A19"),
    ]
}
