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
    public static let allModels: [BuiltinModelPricing] = [
        // Kimi
        BuiltinModelPricing(
            modelName: "k3-agent",
            displayName: "Kimi K3 (Agent)",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.30,
            defaultNote: "Kimi 官方标准包"
        ),
        BuiltinModelPricing(
            modelName: "k3",
            displayName: "Kimi K3",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.30,
            defaultNote: "Kimi 官方标准包"
        ),
        BuiltinModelPricing(
            modelName: "k3-256k",
            displayName: "Kimi K3 (256k)",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.30,
            defaultNote: "长上下文 256k 窗口"
        ),
        BuiltinModelPricing(
            modelName: "kimi-code",
            displayName: "Kimi Code",
            vendor: "Moonshot Kimi",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.30,
            defaultNote: "Kimi Code 编程补全"
        ),

        // OpenAI / Codex
        BuiltinModelPricing(
            modelName: "gpt-5.6-luna",
            displayName: "GPT-5.6 Luna",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 0.20,
            outputPricePerMillion: 1.20,
            cacheReadPricePerMillion: 0.02,
            defaultNote: "高频极速轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.6-sol",
            displayName: "GPT-5.6 Sol",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 4.00,
            outputPricePerMillion: 20.00,
            cacheReadPricePerMillion: 0.40,
            defaultNote: "旗舰推理大模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.6-terra",
            displayName: "GPT-5.6 Terra",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 2.00,
            outputPricePerMillion: 12.00,
            cacheReadPricePerMillion: 0.20,
            defaultNote: "主力平衡型编程模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.4",
            displayName: "GPT-5.4",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 2.50,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.25,
            defaultNote: "标准通用模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.4-mini",
            displayName: "GPT-5.4 mini",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.60,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "轻量高吞吐模型"
        ),
        BuiltinModelPricing(
            modelName: "gpt-5.2-codex",
            displayName: "GPT-5.2 Codex",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 1.75,
            outputPricePerMillion: 14.00,
            cacheReadPricePerMillion: 0.175,
            defaultNote: "经典专用代码模型"
        ),
        BuiltinModelPricing(
            modelName: "codex-auto-review",
            displayName: "Codex Auto Review",
            vendor: "OpenAI / Codex",
            inputPricePerMillion: 1.75,
            outputPricePerMillion: 14.00,
            cacheReadPricePerMillion: 0.175,
            defaultNote: "自动化审查分析"
        ),

        // DeepSeek
        BuiltinModelPricing(
            modelName: "deepseek-v4-flash",
            displayName: "DeepSeek V4.1 Flash",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.60,
            cacheReadPricePerMillion: 0.003,
            defaultNote: "闲时基准单价 (忙时自动按两倍核算)"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-v4-pro",
            displayName: "DeepSeek V4 Pro",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.66,
            outputPricePerMillion: 1.98,
            cacheReadPricePerMillion: 0.022,
            defaultNote: "深度推理主力"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-chat",
            displayName: "DeepSeek Chat",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.14,
            outputPricePerMillion: 0.28,
            cacheReadPricePerMillion: 0.014,
            defaultNote: "经典通用对话"
        ),
        BuiltinModelPricing(
            modelName: "deepseek-reasoner",
            displayName: "DeepSeek Reasoner",
            vendor: "DeepSeek",
            inputPricePerMillion: 0.55,
            outputPricePerMillion: 2.19,
            cacheReadPricePerMillion: 0.14,
            defaultNote: "经典推理思考模型"
        ),

        // Zhipu GLM
        BuiltinModelPricing(
            modelName: "glm-5.3",
            displayName: "GLM-5.3",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 1.40,
            outputPricePerMillion: 4.40,
            cacheReadPricePerMillion: 0.26,
            defaultNote: "国产旗舰通用模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-5.3-flash",
            displayName: "GLM-5.3 Flash",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.50,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "高吞吐量轻量模型"
        ),
        BuiltinModelPricing(
            modelName: "glm-4-plus",
            displayName: "GLM-4 Plus",
            vendor: "智谱 AI (Zhipu)",
            inputPricePerMillion: 1.40,
            outputPricePerMillion: 1.40,
            cacheReadPricePerMillion: 0.26,
            defaultNote: "高阶对话模型"
        ),

        // StepFun
        BuiltinModelPricing(
            modelName: "step-3.7-flash",
            displayName: "Step-3.7 Flash",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 0.20,
            outputPricePerMillion: 1.15,
            cacheReadPricePerMillion: 0.03,
            defaultNote: "高性价比编程模型"
        ),
        BuiltinModelPricing(
            modelName: "step-5-preview",
            displayName: "Step-5 Preview",
            vendor: "阶跃星辰 (StepFun)",
            inputPricePerMillion: 1.00,
            outputPricePerMillion: 2.70,
            cacheReadPricePerMillion: 0.05,
            defaultNote: "阶跃新一代旗舰推理"
        ),

        // Tencent Hunyuan
        BuiltinModelPricing(
            modelName: "hy3",
            displayName: "Hunyuan 3",
            vendor: "腾讯混元",
            inputPricePerMillion: 0.15,
            outputPricePerMillion: 0.60,
            cacheReadPricePerMillion: 0.015,
            defaultNote: "腾讯混元基础模型 (~1.0/4.0 CNY)"
        ),
        BuiltinModelPricing(
            modelName: "hy4-preview",
            displayName: "Hunyuan 4 Preview",
            vendor: "腾讯混元",
            inputPricePerMillion: 0.85,
            outputPricePerMillion: 2.55,
            cacheReadPricePerMillion: 0.08,
            defaultNote: "新一代大语言模型 (~6.0/18.0 CNY)"
        ),

        // Anthropic Claude
        BuiltinModelPricing(
            modelName: "claude-sonnet-5",
            displayName: "Claude Sonnet 5",
            vendor: "Anthropic",
            inputPricePerMillion: 2.00,
            outputPricePerMillion: 10.00,
            cacheReadPricePerMillion: 0.20,
            defaultNote: "Claude 5 代主力模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-haiku-4-5",
            displayName: "Claude Haiku 4.5",
            vendor: "Anthropic",
            inputPricePerMillion: 1.00,
            outputPricePerMillion: 5.00,
            cacheReadPricePerMillion: 0.10,
            defaultNote: "极速轻量补全模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-5-sonnet",
            displayName: "Claude 3.5 Sonnet",
            vendor: "Anthropic",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.30,
            defaultNote: "经典通用编程大模型"
        ),
        BuiltinModelPricing(
            modelName: "claude-3-5-haiku",
            displayName: "Claude 3.5 Haiku",
            vendor: "Anthropic",
            inputPricePerMillion: 0.80,
            outputPricePerMillion: 4.00,
            cacheReadPricePerMillion: 0.08,
            defaultNote: "高性价比快速响应"
        ),

        // Grok
        BuiltinModelPricing(
            modelName: "grok-3",
            displayName: "Grok 3",
            vendor: "xAI",
            inputPricePerMillion: 3.00,
            outputPricePerMillion: 15.00,
            cacheReadPricePerMillion: 0.75,
            defaultNote: "全功能推理模型"
        ),
        BuiltinModelPricing(
            modelName: "grok-3-mini",
            displayName: "Grok 3 Mini",
            vendor: "xAI",
            inputPricePerMillion: 0.30,
            outputPricePerMillion: 1.50,
            cacheReadPricePerMillion: 0.075,
            defaultNote: "极速思考模型"
        ),
    ]

    /// 组合内置模型与自定义覆盖，生成用于展示与计算的完整模型列表.
    public static func resolveAll(
        overrides: [String: ModelPricingOverride] = [:]
    ) -> [EffectiveModelPricing] {
        var result: [EffectiveModelPricing] = []
        var processedKeys = Set<String>()

        for builtin in allModels {
            processedKeys.insert(builtin.modelName.lowercased())
            let matchedOverride = overrides.first(where: {
                matchesModel(builtin.modelName, target: $0.key)
            })?.value

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
