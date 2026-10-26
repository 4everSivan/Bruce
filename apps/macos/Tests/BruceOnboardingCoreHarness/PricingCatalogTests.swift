import Foundation
@testable import BruceOnboardingCore

/// C108: mac 设置页价卡由 pricing-catalog.json 生成, 与采集端计费同源。
@MainActor
func pricingCatalogMatchesCollectorRows() throws {
    let rows = Dictionary(
        uniqueKeysWithValues: BuiltinModelPricingCatalog.allModels.map { ($0.modelName, $0) }
    )
    try coreExpect(rows.count == BuiltinModelPricingCatalog.allModels.count, "价卡键不得重复")
    let opus = rows["claude-opus-5-5"]
    try coreExpect(
        opus?.inputPricePerMillion == 4.0 && opus?.outputPricePerMillion == 20.0
            && opus?.cacheReadPricePerMillion == 0.20,
        "Opus 5.5 展示单价须与采集端一致 ($4/$20/$0.20)"
    )
    let flash = rows["deepseek-v4.1-flash"]
    try coreExpect(
        flash?.inputPricePerMillion == 0.30 && flash?.outputPricePerMillion == 1.20
            && flash?.cacheReadPricePerMillion == 0.006,
        "deepseek-v4.1-flash 展示单价须与采集端 ClinePass 档一致"
    )
    try coreExpect(rows["claude-sonnet-5-5"] != nil, "现行 Claude 型号须在设置页列出")
    try coreExpect(rows["deepseek-flash"] == nil && rows["jev"] == nil, "listed=false 的别名不单列")
}

/// C108: 覆盖项选择与采集端 PricingTable::resolve 同序 —— 精确键优先, 否则取最具体前缀,
/// 不再依赖字典遍历顺序。
@MainActor
func pricingOverrideSelectionMatchesCollector() throws {
    let base = ModelPricingOverride(inputPricePerMillion: 9)
    let mini = ModelPricingOverride(inputPricePerMillion: 1)
    let both = BuiltinModelPricingCatalog.resolveAll(overrides: ["gpt-5.4": base, "gpt-5.4-mini": mini])
    let pick = { (rows: [EffectiveModelPricing], name: String) in
        rows.first { $0.modelName == name }?.inputPrice
    }
    try coreExpect(pick(both, "gpt-5.4-mini") == 1, "精确覆盖键优先于前缀键")
    try coreExpect(pick(both, "gpt-5.4") == 9, "gpt-5.4 取自身覆盖")

    let onlyBase = BuiltinModelPricingCatalog.resolveAll(overrides: ["gpt-5.4": base])
    try coreExpect(pick(onlyBase, "gpt-5.4-mini") == 9, "无精确键时与采集端同样按前缀命中")

    let dated = BuiltinModelPricingCatalog.override(
        for: "claude-opus-5-5-20261001",
        in: ["claude-opus-5": base, "claude-opus-5-5": mini]
    )
    try coreExpect(dated?.inputPricePerMillion == 1, "多个基础型号前缀命中时取最长者")
}
