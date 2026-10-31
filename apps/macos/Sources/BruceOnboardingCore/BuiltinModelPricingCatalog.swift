import Foundation

/// 价格表生效来源 (T20).
public enum PricingCatalogSource: String, Sendable, Equatable {
    case builtin
    case synced
}

/// 解析与校验后的模型价格表 (T20).
public struct ParsedPricingCatalogFile: Equatable, Sendable {
    public let schemaVersion: Int
    public let updatedAt: String
    public let models: [BuiltinModelPricing]
    public let source: PricingCatalogSource
    public let rawData: Data?

    public init(
        schemaVersion: Int,
        updatedAt: String,
        models: [BuiltinModelPricing],
        source: PricingCatalogSource,
        rawData: Data? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.models = models
        self.source = source
        self.rawData = rawData
    }
}

/// 价格表校验与加载错误 (T20).
public enum PricingCatalogError: LocalizedError, Equatable, Sendable {
    case fileNotFound
    case invalidJSON(String)
    case unsupportedSchemaVersion(Int)
    case invalidUpdatedAt(String)
    case emptyOrTooManyModels
    case invalidModel(String)
    case duplicateModel(String)
    case staleVersionComparedToBuiltin(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "价格表文件不存在"
        case .invalidJSON(let msg):
            return "价格表 JSON 解析失败: \(msg)"
        case .unsupportedSchemaVersion(let v):
            return "不支持的 schemaVersion: \(v) (期望 1)"
        case .invalidUpdatedAt(let s):
            return "updatedAt 格式无效: \(s)"
        case .emptyOrTooManyModels:
            return "模型列表为空或超出上限 (上限 2000)"
        case .invalidModel(let msg):
            return "模型定义无效: \(msg)"
        case .duplicateModel(let k):
            return "存在重复模型键: \(k)"
        case .staleVersionComparedToBuiltin(let s):
            return "价格表版本低于内置基线: \(s)"
        }
    }
}

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

/// 内置与动态模型基线目录 (Web Search 最新官方定价核对 / GitHub Raw 同步, C108, T19, T20).
public enum BuiltinModelPricingCatalog {
    // builtinModels 由 scripts/gen-pricing-catalog.mjs 生成于 BuiltinModelPricingCatalog+Data.swift (C108, T19):
    // 与采集端计费同源 (config/pricing-catalog.json), 不在此手写。

    private static let lock = NSLock()
    private nonisolated(unsafe) static var _activeCatalog: ParsedPricingCatalogFile?
    private nonisolated(unsafe) static var _isInitialized = false

    /// 编译期内置基线目录.
    public static var builtinBaseline: ParsedPricingCatalogFile {
        ParsedPricingCatalogFile(
            schemaVersion: builtinSchemaVersion,
            updatedAt: builtinUpdatedAt,
            models: builtinModels,
            source: .builtin,
            rawData: nil
        )
    }

    /// 当前生效的模型目录 (优先已同步文件, 兜底编译期内置).
    public static var activeCatalog: ParsedPricingCatalogFile {
        lock.lock()
        defer { lock.unlock() }
        if !_isInitialized {
            _isInitialized = true
            let url = defaultSyncedFileURL()
            if FileManager.default.fileExists(atPath: url.path) {
                if let data = try? Data(contentsOf: url),
                   let parsed = try? validateAndParse(data: data, source: .synced) {
                    if compareUpdatedAt(parsed.updatedAt, builtinUpdatedAt) == .orderedAscending {
                        try? FileManager.default.removeItem(at: url)
                        _activeCatalog = nil
                    } else {
                        _activeCatalog = parsed
                    }
                } else {
                    _activeCatalog = nil
                }
            }
        }
        return _activeCatalog ?? builtinBaseline
    }

    /// 当前生效的所有模型行 (展示列表与 ModelNormalizer 共用).
    public static var allModels: [BuiltinModelPricing] {
        activeCatalog.models
    }

    /// 当前价格表生效来源.
    public static var currentSource: PricingCatalogSource {
        activeCatalog.source
    }

    /// 当前价格表修订批次日期.
    public static var currentUpdatedAt: String {
        activeCatalog.updatedAt
    }

    /// 当前价格表模型数.
    public static var currentModelCount: Int {
        activeCatalog.models.count
    }

    /// 当前生效的同步文件原始数据 (用于向 Collector BridgeRequest 注入 context.pricingCatalog).
    public static var activeCatalogJSONData: Data? {
        activeCatalog.rawData
    }

    /// 默认本地已同步价格表路径 (`~/Library/Application Support/Bruce/config/pricing-catalog.json`).
    public static func defaultSyncedFileURL() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("Bruce", isDirectory: true)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("pricing-catalog.json", isDirectory: false)
    }

    /// 重新从本地磁盘加载价格表 (含防倒退比对与静默清理).
    public static func reloadActiveCatalog(fileURL: URL? = nil) {
        let url = fileURL ?? defaultSyncedFileURL()
        lock.lock()
        defer { lock.unlock() }
        _isInitialized = true

        guard FileManager.default.fileExists(atPath: url.path) else {
            _activeCatalog = nil
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let parsed = try validateAndParse(data: data, source: .synced)
            if compareUpdatedAt(parsed.updatedAt, builtinUpdatedAt) == .orderedAscending {
                try? FileManager.default.removeItem(at: url)
                _activeCatalog = nil
            } else {
                _activeCatalog = parsed
            }
        } catch {
            _activeCatalog = nil
        }
    }

    /// 显式设置内存态活动目录.
    public static func setActiveCatalog(_ catalog: ParsedPricingCatalogFile?) {
        lock.lock()
        defer { lock.unlock() }
        _isInitialized = true
        _activeCatalog = catalog
    }

    /// 恢复内置基线 (显式移除本地同步文件并回退内置).
    public static func resetToBuiltin(fileURL: URL? = nil) {
        let url = fileURL ?? defaultSyncedFileURL()
        lock.lock()
        defer { lock.unlock() }
        _isInitialized = true
        try? FileManager.default.removeItem(at: url)
        _activeCatalog = nil
    }

    // MARK: - 校验与版本比对

    /// 校验 updatedAt 格式 (`YYYY-MM-DD` 或 `YYYY-MM-DD.N`).
    public static func isValidUpdatedAt(_ s: String) -> Bool {
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let datePart = parts[0]
        let dateSubparts = datePart.split(separator: "-", omittingEmptySubsequences: false)
        guard dateSubparts.count == 3 else { return false }
        guard dateSubparts[0].count == 4 && dateSubparts[0].allSatisfy({ $0.isNumber }),
              dateSubparts[1].count == 2 && dateSubparts[1].allSatisfy({ $0.isNumber }),
              dateSubparts[2].count == 2 && dateSubparts[2].allSatisfy({ $0.isNumber })
        else { return false }

        if parts.count == 2 {
            let revPart = parts[1]
            guard !revPart.isEmpty && revPart.allSatisfy({ $0.isNumber }) else { return false }
        }
        return true
    }

    /// 比较两份价格表的 updatedAt 版本 (支持同日修订号 .N 整数比对).
    public static func compareUpdatedAt(_ a: String, _ b: String) -> ComparisonResult {
        guard isValidUpdatedAt(a), isValidUpdatedAt(b) else {
            return a.compare(b)
        }
        let aParts = a.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let bParts = b.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let aDate = String(aParts[0])
        let bDate = String(bParts[0])

        let dateCmp = aDate.compare(bDate)
        if dateCmp != .orderedSame {
            return dateCmp
        }

        let aRev = aParts.count == 2 ? (Int(aParts[1]) ?? 0) : 0
        let bRev = bParts.count == 2 ? (Int(bParts[1]) ?? 0) : 0
        if aRev < bRev {
            return .orderedAscending
        } else if aRev > bRev {
            return .orderedDescending
        }
        return .orderedSame
    }

    private struct RawCatalogModel: Decodable {
        let model: String
        let displayName: String
        let vendor: String
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: [Double]?
        let note: String?
        let listed: Bool?
    }

    private struct RawCatalogFile: Decodable {
        let schemaVersion: Int?
        let updatedAt: String?
        let models: [RawCatalogModel]?
    }

    /// 严格校验并解析 JSON 数据 (R3 规范).
    public static func validateAndParse(
        data: Data,
        source: PricingCatalogSource = .synced
    ) throws -> ParsedPricingCatalogFile {
        let file: RawCatalogFile
        do {
            file = try JSONDecoder().decode(RawCatalogFile.self, from: data)
        } catch {
            throw PricingCatalogError.invalidJSON(error.localizedDescription)
        }

        guard let schemaVersion = file.schemaVersion, schemaVersion == 1 else {
            throw PricingCatalogError.unsupportedSchemaVersion(file.schemaVersion ?? 0)
        }
        guard let updatedAt = file.updatedAt, isValidUpdatedAt(updatedAt) else {
            throw PricingCatalogError.invalidUpdatedAt(file.updatedAt ?? "")
        }
        guard let rawModels = file.models, !rawModels.isEmpty && rawModels.count <= 2000 else {
            throw PricingCatalogError.emptyOrTooManyModels
        }

        var models: [BuiltinModelPricing] = []
        var seenKeys = Set<String>()

        for (idx, entry) in rawModels.enumerated() {
            let key = entry.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.isEmpty {
                throw PricingCatalogError.invalidModel("第 \(idx) 条 model 键为空")
            }
            let displayName = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if displayName.isEmpty {
                throw PricingCatalogError.invalidModel("模型 \(key) displayName 为空")
            }
            let vendor = entry.vendor.trimmingCharacters(in: .whitespacesAndNewlines)
            if vendor.isEmpty {
                throw PricingCatalogError.invalidModel("模型 \(key) vendor 为空")
            }
            let lower = key.lowercased()
            if !seenKeys.insert(lower).inserted {
                throw PricingCatalogError.duplicateModel(key)
            }
            if !entry.input.isFinite || entry.input < 0 {
                throw PricingCatalogError.invalidModel("模型 \(key) input 价格无效: \(entry.input)")
            }
            if !entry.output.isFinite || entry.output < 0 {
                throw PricingCatalogError.invalidModel("模型 \(key) output 价格无效: \(entry.output)")
            }
            if let cacheRead = entry.cacheRead {
                if !cacheRead.isFinite || cacheRead < 0 {
                    throw PricingCatalogError.invalidModel("模型 \(key) cacheRead 价格无效: \(cacheRead)")
                }
            }
            if let cacheWrite = entry.cacheWrite {
                if cacheWrite.count != 2 || !cacheWrite[0].isFinite || cacheWrite[0] <= 0 || !cacheWrite[1].isFinite || cacheWrite[1] <= 0 {
                    throw PricingCatalogError.invalidModel("模型 \(key) cacheWrite 倍率无效")
                }
            }

            if entry.listed != false {
                models.append(
                    BuiltinModelPricing(
                        modelName: key,
                        displayName: displayName,
                        vendor: vendor,
                        inputPricePerMillion: entry.input,
                        outputPricePerMillion: entry.output,
                        cacheReadPricePerMillion: entry.cacheRead,
                        defaultNote: entry.note ?? ""
                    )
                )
            }
        }

        return ParsedPricingCatalogFile(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            models: models,
            source: source,
            rawData: data
        )
    }

    // MARK: - 覆盖合并

    /// 组合当前生效模型与自定义覆盖，生成用于展示与计算的完整模型列表.
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
    /// 同长按键名字典序最小。
    static func override(
        for modelName: String,
        in overrides: [String: ModelPricingOverride]
    ) -> ModelPricingOverride? {
        let normalized = normalize(modelName)
        if let exact = overrides[modelName] ?? overrides[normalized] {
            return exact
        }
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
