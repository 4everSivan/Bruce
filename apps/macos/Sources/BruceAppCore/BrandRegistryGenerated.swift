// 本文件由 scripts/gen-brand-registry.mjs 生成, 请勿手改 (C263)。
// 修改 config/brand-registry.json 后运行 node scripts/gen-brand-registry.mjs;
// verify-local 以 --check 拦截漂移。
package enum BrandRegistryGenerated {
    /// 注册表版本 (与 JSON schemaVersion 一致)。
    package static let schemaVersion = 1

    /// Nothing 深色档 (亮→暗)。
    package static let nothingRampDark: [String] = [
        "#8CCB98",
        "#5FAF6E",
        "#4A9E5C",
        "#35854A",
        "#2A6B3C",
    ]

    /// Nothing 浅色档 (杏色, 深→浅)。
    package static let nothingRampLight: [String] = [
        "#946A08",
        "#B8860B",
        "#D4A843",
        "#E3BE6B",
        "#F0D69A",
    ]

    /// 已知 agent 的固定档位; 未知 agent 由调用方用 FNV-1a 散列落档。
    package static let nothingAgentTiers: [String: Int] = [
        "antigravity": 3,
        "claude-code": 1,
        "codebuddy": 2,
        "codex": 2,
        "dsh": 1,
        "grok": 2,
        "kimi-code-cli": 0,
        "kimi-work": 4,
        "opencode": 4,
        "pi": 4,
        "zcode": 3,
    ]
}
