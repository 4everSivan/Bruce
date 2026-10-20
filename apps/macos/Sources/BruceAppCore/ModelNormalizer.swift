import Foundation
import BruceOnboardingCore

/// 跨源多模型智能归一化与合并引擎.
/// 负责自动剥离渠道前缀 (如 cline-pass/, zhipu/, openrouter/)、版本后缀 (-20250219, -preview)，
/// 并将同一模型的异构来源合并为一个规范主模型条目，同时保留底层来源渠道树.
package enum ModelNormalizer {

    // MARK: - 基础规范化规则

    /// 提取模型规范键 (Canonical Key).
    /// 例: "cline-pass/deepseek-v4.1-flash" -> "deepseek-v4.1-flash"
    /// 例: "zhipu/glm-5.3" -> "glm-5.3"
    /// 例: "anthropic/claude-3-7-sonnet-20250219" -> "claude-3-7-sonnet"
    package static func canonicalKey(for rawName: String) -> String {
        var str = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 去除方括号标签如 [thinking], [online]
        if let idx = str.firstIndex(of: "[") {
            str = String(str[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. 剥离厂商或中转渠道前缀 (以最后一个 / 为界)
        if let idx = str.lastIndex(of: "/") {
            str = String(str[str.index(after: idx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 3. 去除常见日期后缀 (如 -20250219, -20241022)
        if let match = str.range(of: #"-\d{8}$"#, options: .regularExpression) {
            str.removeSubrange(match)
        } else if let match = str.range(of: #"-\d{4}$"#, options: .regularExpression) {
            str.removeSubrange(match)
        }

        // 4. 去除常见变体后缀 (如 -preview, -latest)
        if str.hasSuffix("-preview") && str != "step-5-preview" && str != "hy4-preview" {
            str = String(str.dropLast(8))
        } else if str.hasSuffix("-latest") {
            str = String(str.dropLast(7))
        }

        // 5. 别名词典精准归集对齐
        if str.contains("glm") {
            if str.contains("5") || str.contains("5.3") {
                return "glm-5.3"
            }
            if str.contains("4") {
                return "glm-4"
            }
            return "glm-5.3"
        }
        if str.contains("deepseek") {
            if str.contains("r1") {
                return "deepseek-r1"
            }
            if str.contains("reasoner") {
                return "deepseek-reasoner"
            }
            if str.contains("pro") {
                return "deepseek-v4-pro"
            }
            if str == "deepseek-chat" || (str.contains("chat") && !str.contains("flash")) {
                return "deepseek-chat"
            }
            // 归并 deepseek-flash, deepseek-v4-flash, deepseek-v4.1-flash, cline-pass/deepseek-v4.1-flash 等
            return "deepseek-v4.1-flash"
        }
        if str.contains("claude-opus") || str.contains("opus") {
            return "claude-opus-5-5"
        }
        if str.contains("claude-3-7-sonnet") || str.contains("claude-3.7-sonnet") {
            return "claude-3-7-sonnet"
        }
        if str.contains("claude-3-5-sonnet") || str.contains("claude-3.5-sonnet") {
            return "claude-3-5-sonnet"
        }
        if str.contains("claude-3-5-haiku") || str.contains("claude-3.5-haiku") {
            return "claude-3-5-haiku"
        }
        if str.contains("gpt-6.1-sol") {
            return "gpt-6.1-sol"
        }
        if str.contains("gpt-6-sol") {
            return "gpt-6-sol"
        }
        if str.contains("gpt-6-luna") {
            return "gpt-6-luna"
        }
        if str.contains("gpt-5.4") {
            return "gpt-5.4"
        }
        if str.contains("gpt-5.6-sol") {
            return "gpt-5.6-sol"
        }
        if str.contains("gpt-5.6-luna") {
            return "gpt-5.6-luna"
        }
        if str.contains("kimi-k3") || str == "k3-agent" || str == "k3" || str == "kimi-code" {
            return "k3-agent"
        }

        return str
    }

    // MARK: - 元数据提取

    /// 获取模型规范显示名 (Display Name).
    package static func displayName(for canonicalKey: String) -> String {
        if let builtin = BuiltinModelPricingCatalog.allModels.first(where: {
            matches($0.modelName, canonicalKey)
        }) {
            return builtin.displayName
        }

        // 兜底友好展示转换
        switch canonicalKey {
        case "glm-5.3": return "GLM 5.3"
        case "glm-4": return "GLM 4"
        case "deepseek-v4.1-flash": return "DeepSeek V4.1 Flash"
        case "deepseek-v4-pro": return "DeepSeek V4 Pro"
        case "deepseek-r1": return "DeepSeek R1"
        case "deepseek-reasoner": return "DeepSeek Reasoner"
        case "deepseek-chat": return "DeepSeek V3 (Chat)"
        case "claude-3-7-sonnet": return "Claude 3.7 Sonnet"
        case "claude-3-5-sonnet": return "Claude 3.5 Sonnet"
        case "claude-opus-5-5": return "Claude Opus 5.5"
        case "gpt-6.1-sol": return "GPT 6.1 Sol"
        case "gpt-6-sol": return "GPT 6 Sol"
        case "gpt-6-luna": return "GPT 6 Luna"
        case "gpt-5.4": return "GPT 5.4"
        case "k3-agent": return "Kimi K3 (Agent)"
        default:
            return canonicalKey.capitalized
        }
    }

    /// 获取模型所属厂商 (Vendor).
    package static func vendor(for canonicalKey: String) -> String {
        if let builtin = BuiltinModelPricingCatalog.allModels.first(where: {
            matches($0.modelName, canonicalKey)
        }) {
            return builtin.vendor
        }

        if canonicalKey.hasPrefix("claude") { return "Anthropic" }
        if canonicalKey.hasPrefix("gpt") || canonicalKey.hasPrefix("codex") { return "OpenAI" }
        if canonicalKey.hasPrefix("deepseek") { return "DeepSeek" }
        if canonicalKey.hasPrefix("glm") { return "智谱 AI (Zhipu)" }
        if canonicalKey.hasPrefix("k3") || canonicalKey.hasPrefix("kimi") { return "Moonshot" }
        return "通用模型"
    }

    /// 获取模型品牌识别色彩 Hex (用于折线图与占比条).
    package static func colorHex(for canonicalKey: String) -> String {
        let key = canonicalKey.lowercased()
        if key.contains("claude") || key.contains("sonnet") || key.contains("opus") {
            return "#FF9F0A" // Anthropic Orange
        }
        if key.contains("deepseek") {
            return "#30D158" // DeepSeek Emerald
        }
        if key.contains("glm") || key.contains("zhipu") {
            return "#40C8E0" // GLM Teal
        }
        if key.contains("gpt") || key.contains("openai") || key.contains("codex") {
            return "#0A84FF" // OpenAI Blue
        }
        if key.contains("gemini") || key.contains("google") {
            return "#1A73E8" // Google Blue
        }
        if key.contains("qwen") || key.contains("tongyi") {
            return "#624AFF" // Qwen Purple
        }
        if key.contains("doubao") || key.contains("bytedance") {
            return "#007AFF" // Doubao Blue
        }
        if key.contains("kimi") || key.contains("k3") {
            return "#BF5AF2" // Kimi Purple
        }
        if key.contains("step") {
            return "#FF375F" // StepFun Pink
        }
        if key.contains("grok") || key.contains("xai") {
            return "#FFFFFF" // xAI Monochrome White
        }
        if key.contains("minimax") || key.contains("abab") {
            return "#E03E2D" // MiniMax Red
        }
        if key.contains("mimo") || key.contains("xiaomi") {
            return "#FF6900" // Xiaomi Orange
        }
        if key.contains("hunyuan") || key.contains("tencent") || key.contains("hy3") || key.contains("hy4") {
            return "#00A3FF" // Tencent Cyan Blue
        }
        if key.contains("yi") || key.contains("01.ai") {
            return "#2B5876" // 01.AI Slate
        }
        if key.contains("baichuan") {
            return "#E64A19" // Baichuan Amber
        }
        return "#8E8E93" // Neutral Gray
    }

    private static func matches(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased()
        let nb = b.lowercased()
        if na == nb || na.contains(nb) || nb.contains(na) {
            return true
        }
        if na.contains("deepseek-v4") && nb.contains("deepseek-v4") {
            if (na.contains("flash") && nb.contains("flash")) || (na.contains("pro") && nb.contains("pro")) {
                return true
            }
        }
        return false
    }

    // MARK: - 跨源归并与聚合算法

    /// 将 AgentUsageArtifact 中的模型用量跨 Agent、跨源进行智能归一化合并.
    package static func aggregateCanonicalModels(
        from artifact: AgentUsageArtifact,
        range: AnalyticsTimeRange = .sevenDays,
        overrides: [String: ModelPricingOverride]? = nil
    ) -> [CanonicalModelSummary] {
        let effectivePricings = BuiltinModelPricingCatalog.resolveAll(overrides: overrides ?? [:])

        struct AggEntry {
            var totalTokens: Int = 0
            var sources: [ModelSourceContribution] = []
        }
        var aggMap: [String: AggEntry] = [:]

        let currentMonthKey: String = {
            if artifact.generatedAt.count >= 7 {
                return String(artifact.generatedAt.prefix(7))
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM"
            return formatter.string(from: Date())
        }()

        for agent in artifact.agents {
            let agentID = agent.id
            let agentName = agent.name

            struct AgentRawModel {
                let rawName: String
                let total: Int
                let input: Int
                let output: Int
                let costUsd: Double?
            }
            var agentRawModels: [AgentRawModel] = []

            switch range {
            case .today:
                if let todayModels = agent.todayModels, !todayModels.isEmpty {
                    for item in todayModels where item.total > 0 {
                        agentRawModels.append(AgentRawModel(
                            rawName: item.model,
                            total: item.total,
                            input: item.input,
                            output: item.output,
                            costUsd: item.costUsd
                        ))
                    }
                } else if let models = agent.models, !models.isEmpty {
                    for (raw, total) in models where total > 0 {
                        agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                    }
                }

            case .thisMonth:
                if let monthMap = agent.modelMonths?[currentMonthKey], !monthMap.isEmpty {
                    for (raw, total) in monthMap where total > 0 {
                        agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                    }
                } else {
                    let monthDaily = agent.daily.filter { $0.date.hasPrefix(currentMonthKey) }
                    let monthTokens = monthDaily.reduce(0) { $0 + $1.total }
                    if monthTokens > 0 {
                        if let todayModels = agent.todayModels, !todayModels.isEmpty {
                            let todayTotal = todayModels.reduce(0) { $0 + $1.total }
                            if todayTotal > 0 {
                                for item in todayModels {
                                    let scaled = Int(round(Double(item.total) * Double(monthTokens) / Double(todayTotal)))
                                    if scaled > 0 {
                                        agentRawModels.append(AgentRawModel(rawName: item.model, total: scaled, input: 0, output: 0, costUsd: nil))
                                    }
                                }
                            }
                        } else if let models = agent.models, !models.isEmpty {
                            let mTotal = models.values.reduce(0, +)
                            if mTotal > 0 {
                                for (raw, total) in models {
                                    let scaled = Int(round(Double(total) * Double(monthTokens) / Double(mTotal)))
                                    if scaled > 0 {
                                        agentRawModels.append(AgentRawModel(rawName: raw, total: scaled, input: 0, output: 0, costUsd: nil))
                                    }
                                }
                            }
                        }
                    } else if let todayModels = agent.todayModels, !todayModels.isEmpty {
                        for item in todayModels where item.total > 0 {
                            agentRawModels.append(AgentRawModel(rawName: item.model, total: item.total, input: item.input, output: item.output, costUsd: item.costUsd))
                        }
                    } else if let models = agent.models, !models.isEmpty {
                        for (raw, total) in models where total > 0 {
                            agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                        }
                    }
                }

            case .allTime:
                if let modelMonths = agent.modelMonths, !modelMonths.isEmpty {
                    var allMap: [String: Int] = [:]
                    for (_, monthModels) in modelMonths {
                        for (raw, total) in monthModels {
                            allMap[raw, default: 0] += total
                        }
                    }
                    for (raw, total) in allMap where total > 0 {
                        agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                    }
                } else if let models = agent.models, !models.isEmpty {
                    let allTokens = agent.daily.reduce(0) { $0 + $1.total }
                    let mTotal = models.values.reduce(0, +)
                    if allTokens > 0 && mTotal > 0 {
                        for (raw, total) in models {
                            let scaled = Int(round(Double(total) * Double(allTokens) / Double(mTotal)))
                            if scaled > 0 {
                                agentRawModels.append(AgentRawModel(rawName: raw, total: scaled, input: 0, output: 0, costUsd: nil))
                            }
                        }
                    } else {
                        for (raw, total) in models where total > 0 {
                            agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                        }
                    }
                } else if let todayModels = agent.todayModels, !todayModels.isEmpty {
                    for item in todayModels where item.total > 0 {
                        agentRawModels.append(AgentRawModel(rawName: item.model, total: item.total, input: item.input, output: item.output, costUsd: item.costUsd))
                    }
                }

            case .sevenDays, .thirtyDays:
                let limit = (range == .sevenDays) ? 7 : 30
                let windowDaily = agent.daily.suffix(limit)
                let windowTokens = windowDaily.reduce(0) { $0 + $1.total }

                if windowTokens > 0 {
                    if let monthMap = agent.modelMonths?[currentMonthKey], !monthMap.isEmpty {
                        let monthTotal = monthMap.values.reduce(0, +)
                        if monthTotal > 0 {
                            for (raw, total) in monthMap {
                                let scaled = Int(round(Double(total) * Double(windowTokens) / Double(monthTotal)))
                                if scaled > 0 {
                                    agentRawModels.append(AgentRawModel(rawName: raw, total: scaled, input: 0, output: 0, costUsd: nil))
                                }
                            }
                        }
                    } else if let todayModels = agent.todayModels, !todayModels.isEmpty {
                        let todayTotal = todayModels.reduce(0) { $0 + $1.total }
                        if todayTotal > 0 {
                            for item in todayModels {
                                let scaled = Int(round(Double(item.total) * Double(windowTokens) / Double(todayTotal)))
                                if scaled > 0 {
                                    agentRawModels.append(AgentRawModel(rawName: item.model, total: scaled, input: 0, output: 0, costUsd: nil))
                                }
                            }
                        }
                    } else if let models = agent.models, !models.isEmpty {
                        let mTotal = models.values.reduce(0, +)
                        if mTotal > 0 {
                            for (raw, total) in models {
                                let scaled = Int(round(Double(total) * Double(windowTokens) / Double(mTotal)))
                                if scaled > 0 {
                                    agentRawModels.append(AgentRawModel(rawName: raw, total: scaled, input: 0, output: 0, costUsd: nil))
                                }
                            }
                        }
                    }
                } else {
                    // 若 daily 均为 0 (如测试 fixture), 优雅兜底至 models 或 todayModels
                    if let todayModels = agent.todayModels, !todayModels.isEmpty {
                        for item in todayModels where item.total > 0 {
                            agentRawModels.append(AgentRawModel(rawName: item.model, total: item.total, input: item.input, output: item.output, costUsd: item.costUsd))
                        }
                    } else if let models = agent.models, !models.isEmpty {
                        for (raw, total) in models where total > 0 {
                            agentRawModels.append(AgentRawModel(rawName: raw, total: total, input: 0, output: 0, costUsd: nil))
                        }
                    }
                }
            }

            for item in agentRawModels {
                let raw = item.rawName
                let cKey = canonicalKey(for: raw)
                let pricing = effectivePricings.first { matches($0.modelName, cKey) }
                let cost: Double? = item.costUsd ?? (pricing.map { p in
                    if item.input > 0 || item.output > 0 {
                        return (Double(item.input) * p.inputPrice + Double(item.output) * p.outputPrice) / 1_000_000.0
                    } else {
                        // 预估输入 70% 输出 30% 典型配比
                        return Double(item.total) * (0.7 * p.inputPrice + 0.3 * p.outputPrice) / 1_000_000.0
                    }
                })

                var entry = aggMap[cKey, default: AggEntry()]
                entry.totalTokens += item.total
                entry.sources.append(ModelSourceContribution(
                    rawModelName: raw,
                    agentID: agentID,
                    agentDisplayName: agentName,
                    tokens: item.total,
                    tokensText: PanelFormat.tokenCount(item.total),
                    costUsd: cost,
                    costText: cost.map { String(format: "$%.2f", $0) },
                    shareOfModelPercent: 0.0
                ))
                aggMap[cKey] = entry
            }
        }

        let grandTotal = aggMap.values.reduce(0) { $0 + $1.totalTokens }

        var result: [CanonicalModelSummary] = []
        for (cKey, entry) in aggMap {
            let modelTotal = entry.totalTokens
            let share = grandTotal > 0 ? (Double(modelTotal) / Double(grandTotal) * 100.0) : 0.0

            // 归拢同一个 agentID 下同 rawModelName 的渠道贡献
            var mergedSources: [String: ModelSourceContribution] = [:]
            for src in entry.sources {
                let srcKey = src.id
                if let existing = mergedSources[srcKey] {
                    let combinedTokens = existing.tokens + src.tokens
                    let combinedCost = (existing.costUsd ?? 0.0) + (src.costUsd ?? 0.0)
                    mergedSources[srcKey] = ModelSourceContribution(
                        rawModelName: src.rawModelName,
                        agentID: src.agentID,
                        agentDisplayName: src.agentDisplayName,
                        tokens: combinedTokens,
                        tokensText: PanelFormat.tokenCount(combinedTokens),
                        costUsd: combinedCost > 0 ? combinedCost : nil,
                        costText: combinedCost > 0 ? String(format: "$%.2f", combinedCost) : nil,
                        shareOfModelPercent: 0.0
                    )
                } else {
                    mergedSources[srcKey] = src
                }
            }

            // 计算内部各来源的贡献百分比
            let sourcesWithShare = mergedSources.values.map { src -> ModelSourceContribution in
                let pct = modelTotal > 0 ? (Double(src.tokens) / Double(modelTotal) * 100.0) : 0.0
                return ModelSourceContribution(
                    rawModelName: src.rawModelName,
                    agentID: src.agentID,
                    agentDisplayName: src.agentDisplayName,
                    tokens: src.tokens,
                    tokensText: src.tokensText,
                    costUsd: src.costUsd,
                    costText: src.costText,
                    shareOfModelPercent: pct
                )
            }.sorted { $0.tokens > $1.tokens }

            let totalModelCost = sourcesWithShare.reduce(0.0) { $0 + ($1.costUsd ?? 0.0) }
            let costVal: Double? = totalModelCost > 0 ? totalModelCost : nil

            result.append(CanonicalModelSummary(
                canonicalKey: cKey,
                displayName: displayName(for: cKey),
                vendor: vendor(for: cKey),
                colorHex: colorHex(for: cKey),
                totalTokens: modelTotal,
                totalTokensText: PanelFormat.tokenCount(modelTotal),
                estimatedCostUsd: costVal,
                costText: costVal.map { String(format: "$%.2f", $0) },
                sharePercent: share,
                sources: sourcesWithShare
            ))
        }

        result.sort { $0.totalTokens > $1.totalTokens }
        return result
    }

    // MARK: - 时序趋势数据生成

    /// 构建时序折线图数据点.
    package static func buildTimelinePoints(
        from artifact: AgentUsageArtifact,
        range: AnalyticsTimeRange,
        overrides: [String: ModelPricingOverride]? = nil
    ) -> (points: [AnalyticsTimelinePoint], peakSummary: String, avgSummary: String) {
        if range == .today {
            // 24 小时逐小时走势 (00:00 - 23:00)
            var points: [AnalyticsTimelinePoint] = []
            var peakHour = 0
            var peakTokens = 0
            var sumTokens = 0
            let todayModels = aggregateCanonicalModels(from: artifact, range: .today, overrides: overrides)

            for hour in 0..<24 {
                var hourTokens = 0
                var byAgent: [String: Int] = [:]

                for agent in artifact.agents {
                    let agentHour = hour < agent.hours.count ? agent.hours[hour] : 0
                    hourTokens += agentHour
                    if agentHour > 0 {
                        byAgent[agent.id] = agentHour
                    }
                }

                if hourTokens > peakTokens {
                    peakTokens = hourTokens
                    peakHour = hour
                }
                sumTokens += hourTokens

                var series = byAgent
                series["type_input"] = Int(Double(hourTokens) * 0.42)
                series["type_output"] = Int(Double(hourTokens) * 0.18)
                series["type_cache"] = Int(Double(hourTokens) * 0.40)

                for m in todayModels.prefix(5) {
                    let modelTokens = Int((Double(hourTokens) * (m.sharePercent / 100.0)).rounded())
                    series["model_" + m.canonicalKey] = modelTokens
                }

                let costUsd = Double(hourTokens) * 0.0000028
                let label = String(format: "%02d:00", hour)
                points.append(AnalyticsTimelinePoint(
                    label: label,
                    totalTokens: hourTokens,
                    costUsd: costUsd,
                    seriesValues: series
                ))
            }

            let avgTokens = sumTokens / 24
            let peakSummary = "🔥 峰值时段: **\(String(format: "%02d:00", peakHour))** (\(PanelFormat.tokenCount(peakTokens)) Tokens)"
            let avgSummary = "时均: **\(PanelFormat.tokenCount(avgTokens))** Tokens"
            return (points, peakSummary, avgSummary)

        } else {
            // 预先建立 O(1) 字典索引
            var agentDailyMap: [String: [String: AgentDailyUsage]] = [:]
            var allDates = Set<String>()
            for agent in artifact.agents {
                var dict: [String: AgentDailyUsage] = [:]
                for day in agent.daily {
                    dict[day.date] = day
                    allDates.insert(day.date)
                }
                agentDailyMap[agent.id] = dict
            }

            var sortedDates = allDates.sorted()
            let currentMonthKey: String = {
                if artifact.generatedAt.count >= 7 {
                    return String(artifact.generatedAt.prefix(7))
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM"
                return formatter.string(from: Date())
            }()

            let topModels = aggregateCanonicalModels(from: artifact, range: range, overrides: overrides)

            if range == .sevenDays {
                sortedDates = Array(sortedDates.suffix(7))
            } else if range == .thirtyDays {
                sortedDates = Array(sortedDates.suffix(30))
            } else if range == .thisMonth {
                sortedDates = sortedDates.filter { $0.hasPrefix(currentMonthKey) }
            }

            var points: [AnalyticsTimelinePoint] = []
            var peakDate = ""
            var peakTokens = 0
            var sumTokens = 0

            if range == .allTime && sortedDates.count > 28 {
                // 全部历史降采样分桶 (按周聚集为 ~26 个平滑数据点)
                var chunks: [[String]] = []
                var currentChunk: [String] = []
                for d in sortedDates {
                    currentChunk.append(d)
                    if currentChunk.count == 7 {
                        chunks.append(currentChunk)
                        currentChunk = []
                    }
                }
                if !currentChunk.isEmpty {
                    chunks.append(currentChunk)
                }

                for chunk in chunks {
                    var chunkTokens = 0
                    var chunkInput = 0
                    var chunkOutput = 0
                    var byAgent: [String: Int] = [:]

                    for date in chunk {
                        for agent in artifact.agents {
                            if let d = agentDailyMap[agent.id]?[date] {
                                chunkTokens += d.total
                                chunkInput += d.input
                                chunkOutput += d.output
                                if d.total > 0 {
                                    byAgent[agent.id, default: 0] += d.total
                                }
                            }
                        }
                    }

                    let chunkCache = max(0, chunkTokens - chunkInput - chunkOutput)
                    if chunkTokens > peakTokens {
                        peakTokens = chunkTokens
                        peakDate = chunk.first ?? ""
                    }
                    sumTokens += chunkTokens

                    var series = byAgent
                    series["type_input"] = chunkInput
                    series["type_output"] = chunkOutput
                    series["type_cache"] = chunkCache

                    for m in topModels.prefix(5) {
                        let modelTokens = Int((Double(chunkTokens) * (m.sharePercent / 100.0)).rounded())
                        series["model_" + m.canonicalKey] = modelTokens
                    }

                    let label = String((chunk.first ?? "").suffix(5)) // "04-20"
                    let costUsd = Double(chunkTokens) * 0.0000027
                    points.append(AnalyticsTimelinePoint(
                        label: label,
                        totalTokens: chunkTokens,
                        costUsd: costUsd,
                        seriesValues: series
                    ))
                }

                let avgTokens = chunks.isEmpty ? 0 : (sumTokens / chunks.count)
                let peakSummary = peakDate.isEmpty
                    ? "—"
                    : "🔥 峰值周: **\(String(peakDate.suffix(5)))** (\(PanelFormat.tokenCount(peakTokens)) Tokens)"
                let avgSummary = "周均: **\(PanelFormat.tokenCount(avgTokens))** Tokens"
                return (points, peakSummary, avgSummary)

            } else {
                // 逐日走势 (7d / 30d / thisMonth)
                for date in sortedDates {
                    var dayTokens = 0
                    var dayInput = 0
                    var dayOutput = 0
                    var byAgent: [String: Int] = [:]

                    for agent in artifact.agents {
                        if let d = agentDailyMap[agent.id]?[date] {
                            dayTokens += d.total
                            dayInput += d.input
                            dayOutput += d.output
                            if d.total > 0 {
                                byAgent[agent.id] = d.total
                            }
                        }
                    }

                    let dayCache = max(0, dayTokens - dayInput - dayOutput)
                    if dayTokens > peakTokens {
                        peakTokens = dayTokens
                        peakDate = date
                    }
                    sumTokens += dayTokens

                    var series = byAgent
                    series["type_input"] = dayInput
                    series["type_output"] = dayOutput
                    series["type_cache"] = dayCache

                    for m in topModels.prefix(5) {
                        let modelTokens = Int((Double(dayTokens) * (m.sharePercent / 100.0)).rounded())
                        series["model_" + m.canonicalKey] = modelTokens
                    }

                    let label = String(date.suffix(5)) // "10-17"
                    let costUsd = Double(dayTokens) * 0.0000027
                    points.append(AnalyticsTimelinePoint(
                        label: label,
                        totalTokens: dayTokens,
                        costUsd: costUsd,
                        seriesValues: series
                    ))
                }

                let avgTokens = sortedDates.isEmpty ? 0 : (sumTokens / sortedDates.count)
                let peakSummary = peakDate.isEmpty
                    ? "—"
                    : "🔥 峰值: **\(String(peakDate.suffix(5)))** (\(PanelFormat.tokenCount(peakTokens)) Tokens)"
                let avgSummary = "日均: **\(PanelFormat.tokenCount(avgTokens))** Tokens"
                return (points, peakSummary, avgSummary)
            }
        }
    }
}
