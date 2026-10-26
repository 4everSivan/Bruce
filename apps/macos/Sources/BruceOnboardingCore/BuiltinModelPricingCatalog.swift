import Foundation

/// 内置基准模型定价定义.
public struct BuiltinModelPricing: Identifiable, Equatable, Sendable {
    public var id: String { modelName }
    public let modelName: String
    public let displayName: String
    public let vendor: String
    public let inputPricePerMillion: Double
    public let outputPricePerMillion: Double
    public let cacheReadPricePerMillion: Double?
    public let defaultNote: String

    public init(
        modelName: String,
        displayName: String,
        vendor: String,
        inputPricePerMillion: Double,
        outputPricePerMillion: Double,
        cacheReadPricePerMillion: Double? = nil,
        defaultNote: String = ""
    ) {
        self.modelName = modelName
        self.displayName = displayName
        self.vendor = vendor
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
        self.cacheReadPricePerMillion = cacheReadPricePerMillion
        self.defaultNote = defaultNote
    }
}

/// 解析后的有效模型定价 (融合内置基准与用户覆盖).
public struct EffectiveModelPricing: Identifiable, Equatable, Sendable {
    public var id: String { modelName }
    public let modelName: String
    public let displayName: String
    public let vendor: String
    public let inputPrice: Double
    public let outputPrice: Double
    public let cacheReadPrice: Double?
    public let currency: String
    public let isCustom: Bool
    public let note: String?

    public init(
        modelName: String,
        displayName: String,
        vendor: String,
        inputPrice: Double,
        outputPrice: Double,
        cacheReadPrice: Double? = nil,
        currency: String = "USD",
        isCustom: Bool = false,
        note: String? = nil
    ) {
        self.modelName = modelName
        self.displayName = displayName
        self.vendor = vendor
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
        self.cacheReadPrice = cacheReadPrice
        self.currency = currency
        self.isCustom = isCustom
        self.note = note
    }
}

/// 内置模型基线目录 (Web Search 最新官方定价核对).
public enum BuiltinModelPricingCatalog {
    // allModels 由 scripts/gen-pricing-catalog.mjs 生成于 BuiltinModelPricingCatalog+Data.swift (C108):
    // 与采集端计费同源 (core/collector/crates/collector-domain/pricing-catalog.json), 不在此手写。

    /// 组合内置模型与自定义覆盖，生成用于展示与计算的完整模型列表.
    public static func resolveAll(
        overrides: [String: ModelPricingOverride] = [:]
    ) -> [EffectiveModelPricing] {
        var result: [EffectiveModelPricing] = []
        var processedKeys = Set<String>()

        for builtin in allModels {
            processedKeys.insert(builtin.modelName.lowercased())
            let matchedOverride = override(for: builtin.modelName, in: overrides)

            let input = matchedOverride?.inputPricePerMillion ?? builtin.inputPricePerMillion
            let output = matchedOverride?.outputPricePerMillion ?? builtin.outputPricePerMillion
            let cache = matchedOverride?.cacheReadPricePerMillion ?? builtin.cacheReadPricePerMillion
            let currency = matchedOverride?.currency ?? "USD"
            let isCustom = matchedOverride != nil
            let note = matchedOverride?.note ?? builtin.defaultNote

            result.append(
                EffectiveModelPricing(
                    modelName: builtin.modelName,
                    displayName: builtin.displayName,
                    vendor: builtin.vendor,
                    inputPrice: input,
                    outputPrice: output,
                    cacheReadPrice: cache,
                    currency: currency,
                    isCustom: isCustom,
                    note: note
                )
            )
        }

        // 查找用户自定义且不在内置列表中的模型
        for (customKey, customOverride) in overrides {
            let keyLower = customKey.lowercased()
            if !processedKeys.contains(keyLower) && !allModels.contains(where: { matchesModel($0.modelName, target: keyLower) }) {
                if let input = customOverride.inputPricePerMillion,
                   let output = customOverride.outputPricePerMillion {
                    result.append(
                        EffectiveModelPricing(
                            modelName: customKey,
                            displayName: customKey,
                            vendor: "自定义模型",
                            inputPrice: input,
                            outputPrice: output,
                            cacheReadPrice: customOverride.cacheReadPricePerMillion,
                            currency: customOverride.currency ?? "USD",
                            isCustom: true,
                            note: customOverride.note ?? "用户自定义校准单价"
                        )
                    )
                }
            }
        }

        return result
    }

    /// 与采集端 `PricingTable::resolve` 的覆盖项选择同序 (C108): 原样键 → 规范键 →
    /// 前缀候选中「目录键是模型名前缀」者取最长、否则「模型名是目录键前缀」者取最短,
    /// 同长按键名字典序最小。旧实现取字典遍历首个前缀命中, 结果随哈希种子漂移,
    /// 设置页可能展示与实际计费不同的覆盖单价。
    static func override(
        for modelName: String,
        in overrides: [String: ModelPricingOverride]
    ) -> ModelPricingOverride? {
        let normalized = normalize(modelName)
        if let exact = overrides[modelName] ?? overrides[normalized] {
            return exact
        }
        // 排序键 (越大越优): (是否基础型号, 基础型号取键长 / 扩展型号取负键长); 同秩取字典序最小的键
        var best: (rank: (Int, Int), key: String, value: ModelPricingOverride)?
        for (key, value) in overrides where matchesModel(normalized, target: key) {
            let target = normalize(key)
            let isBase = normalized.hasPrefix(target)
            let rank = (isBase ? 1 : 0, isBase ? target.count : -target.count)
            if let current = best,
               rank < current.rank || (rank == current.rank && key >= current.key) {
                continue
            }
            best = (rank, key, value)
        }
        return best?.value
    }

    private static func matchesModel(_ a: String, target b: String) -> Bool {
        let normA = normalize(a)
        let normB = normalize(b)
        return !normA.isEmpty && !normB.isEmpty && (normA == normB || normA.hasPrefix(normB) || normB.hasPrefix(normA))
    }

    private static func normalize(_ s: String) -> String {
        var str = s.lowercased()
        if let idx = str.firstIndex(of: "[") {
            str = String(str[..<idx])
        }
        if let idx = str.lastIndex(of: "/") {
            str = String(str[str.index(after: idx)...])
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
