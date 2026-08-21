import Foundation
import BruceOnboardingCore

// MARK: - DeepSeekMonthlyUsage

/// DeepSeek 月度账本的派生结果, 供 PanelViewModelMapper 映射为订阅卡展示.
package enum DeepSeekMonthlyUsage: Equatable, Sendable {
    /// 账本不可用 (损坏, 写入失败或尚未建立基线).
    case unavailable
    /// 仅有首次基线, 趋势图尚未建立.
    case baseline(BaselineSummary)
    /// 存在两条以上有效观察, 可绘制累计趋势线.
    case trend(TrendSummary)
}

/// 仅基线状态的摘要.
package struct BaselineSummary: Equatable, Sendable {
    /// 当前余额 (Decimal, 由 Artifact Double 转换).
    package let currentBalance: Decimal
    package let currency: String
    /// 覆盖起点文案, 如 "自 2026-08-03 起首次记录".
    package let coverageStartText: String

    package init(
        currentBalance: Decimal,
        currency: String,
        coverageStartText: String
    ) {
        self.currentBalance = currentBalance
        self.currency = currency
        self.coverageStartText = coverageStartText
    }
}

/// 趋势摘要.
package struct TrendSummary: Equatable, Sendable {
    /// 本月累计推算消费 (余额下降之和, 单调递增).
    package let estimatedConsumption: Decimal
    package let currentBalance: Decimal
    package let currency: String
    /// 覆盖说明文案.
    package let coverageText: String
    /// 累计趋势点 (时间 -> 累计消费); 下降追加点取累计后值, 上升追加点取同值.
    package let trendPoints: [TrendPoint]
    /// 最近非消费入账注记; nil 表示无入账.
    package let recentCreditNote: String?

    package init(
        estimatedConsumption: Decimal,
        currentBalance: Decimal,
        currency: String,
        coverageText: String,
        trendPoints: [TrendPoint],
        recentCreditNote: String?
    ) {
        self.estimatedConsumption = estimatedConsumption
        self.currentBalance = currentBalance
        self.currency = currency
        self.coverageText = coverageText
        self.trendPoints = trendPoints
        self.recentCreditNote = recentCreditNote
    }
}

/// 累计趋势点.
package struct TrendPoint: Codable, Equatable, Sendable {
    /// ISO-8601 观察时间.
    package let observedAt: String
    /// 该时刻的累计推算消费.
    package let cumulativeConsumption: Decimal

    package init(observedAt: String, cumulativeConsumption: Decimal) {
        self.observedAt = observedAt
        self.cumulativeConsumption = cumulativeConsumption
    }
}

// MARK: - DeepSeekUsageObservation

/// 已校验的 DeepSeek 余额观察, 由 AppModel 从有效 Artifact 中提取后喂给账本.
package struct DeepSeekUsageObservation: Codable, Equatable, Sendable {
    /// Artifact generatedAt (ISO-8601), 作为观察时间.
    package let observedAt: String
    package let balance: Decimal
    package let currency: String

    package init(observedAt: String, balance: Decimal, currency: String) {
        self.observedAt = observedAt
        self.balance = balance
        self.currency = currency
    }
}

// MARK: - UsageLedgerFileSystem

/// 账本文件系统边界, 便于测试注入隔离文件系统.
package protocol UsageLedgerFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws
    func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws
    func createFile(
        atPath path: String,
        contents: Data?,
        attributes: [FileAttributeKey: Any]?
    ) -> Bool
    func contents(atPath path: String) -> Data?
    func replaceItemAt(
        _ originalItemURL: URL,
        withItemAt newItemURL: URL,
        backupItemName: String?,
        options: FileManager.ItemReplacementOptions
    ) throws -> URL?
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at URL: URL) throws
}

extension FileManager: UsageLedgerFileSystem {}

extension UsageLedgerFileSystem {
    /// 原子替换的便捷封装, 隐藏 backupItemName/options 默认值.
    func atomicReplace(
        _ original: URL, with new: URL
    ) throws -> URL? {
        try replaceItemAt(
            original,
            withItemAt: new,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }
}

// MARK: - DeepSeekUsageLedger

/// DeepSeek 私有月度账本.
///
/// 仅处理已校验的成功余额快照 (AppModel 从有效 Artifact 提取). 同月同币种
/// 余额下降累加为推算消费, 余额上升记为非消费入账. 跨月, 币种变化或追踪 ID
/// 变化时重建零消费基线, 不回填未知期间. 账本不可读或写入失败时保守恢复,
/// 下一次有效观察重建基线.
///
/// 持久化状态非敏感: 不保存 API Key, Token, 账号名, 会话或完整 Artifact.
/// 目录权限 0700, 文件权限 0600, 写入用临时文件 + 同步 + 重读校验 + 原子替换.
@MainActor
package final class DeepSeekUsageLedger {
    /// 账本 schema 版本. 未来字段变更时递增并在 load 时迁移或拒绝.
    private static let schemaVersion = 1

    private let rootURL: URL
    private let fileManager: any UsageLedgerFileSystem
    private let calendar: Calendar
    private let now: () -> Date

    /// 当前内存中的账本状态; nil 表示尚未加载或已因故障置为不可用.
    private var state: LedgerState?

    /// 当前生效的追踪 ID; 与注入的配置 ID 不一致时重建基线.
    private var activeTrackingID: String?

    package init(
        rootURL: URL,
        fileManager: any UsageLedgerFileSystem = FileManager.default,
        calendar: Calendar,
        now: @escaping () -> Date = Date.init
    ) {
        self.rootURL = rootURL
            .appendingPathComponent("usage-ledger", isDirectory: true)
        self.fileManager = fileManager
        self.calendar = calendar
        self.now = now
    }

    // MARK: - 公开入口

    /// 注入当前 DeepSeek 配置的追踪 ID. 与账本持久化的追踪 ID 不一致时,
    /// 丢弃当前内存状态并重建基线 (不删除磁盘文件, 下次有效观察自然覆盖).
    package func setTrackingID(_ trackingID: String?) {
        if activeTrackingID != trackingID {
            state = nil
            activeTrackingID = trackingID
        }
    }

    /// 处理一条有效观察, 返回更新后的月度派生结果.
    /// 观察无效 (时间无法解析或余额为负/非有限) 时返回当前状态而不写盘.
    package func record(
        _ observation: DeepSeekUsageObservation
    ) -> DeepSeekMonthlyUsage {
        guard let trackingID = activeTrackingID,
              let observedDate = parseDate(observation.observedAt),
              observation.balance >= 0 else {
            return currentUsage()
        }

        ensureLoaded(trackingID: trackingID)

        // 重复或乱序: generatedAt + currency + balance 与最后观察相同,
        // 或时间不晚于最后观察 -> 不记账.
        if let state,
           let last = state.lastObservation,
           isDuplicateOrOutOfOrder(
               observation: observation,
               last: last
           ) {
            return currentUsage()
        }

        let monthKey = monthKey(for: observedDate)
        let needRebaseline = state == nil
            || state?.trackingID != trackingID
            || state?.monthKey != monthKey
            || state?.currency != observation.currency

        if needRebaseline {
            state = LedgerState(
                schemaVersion: Self.schemaVersion,
                trackingID: trackingID,
                monthKey: monthKey,
                currency: observation.currency,
                coverageStart: observation.observedAt,
                lastObservation: observation,
                estimatedConsumption: 0,
                trendPoints: [
                    TrendPoint(
                        observedAt: observation.observedAt,
                        cumulativeConsumption: 0
                    ),
                ],
                recentCreditNote: nil
            )
        } else {
            applyDelta(
                state: &state!,
                observation: observation,
                observedDate: observedDate
            )
        }

        if !persist() {
            // 写入失败: 保守恢复, 丢弃内存状态使下次观察重建基线.
            state = nil
        }
        return currentUsage()
    }

    /// 返回当前派生结果 (不触发写入).
    package func currentUsage() -> DeepSeekMonthlyUsage {
        guard let state else {
            return .unavailable
        }
        if state.trendPoints.count >= 2 {
            return .trend(TrendSummary(
                estimatedConsumption: state.estimatedConsumption,
                currentBalance: state.lastObservation?.balance ?? 0,
                currency: state.currency,
                coverageText: coverageText(for: state),
                trendPoints: state.trendPoints,
                recentCreditNote: state.recentCreditNote
            ))
        }
        return .baseline(BaselineSummary(
            currentBalance: state.lastObservation?.balance ?? 0,
            currency: state.currency,
            coverageStartText: baselineText(for: state)
        ))
    }

    // MARK: - 差分推算

    private func applyDelta(
        state: inout LedgerState,
        observation: DeepSeekUsageObservation,
        observedDate: Date
    ) {
        guard let last = state.lastObservation else { return }
        let delta = last.balance - observation.balance
        if delta > 0 {
            // 余额下降: 累加消费, 追加累计点.
            state.estimatedConsumption += delta
            state.trendPoints.append(TrendPoint(
                observedAt: observation.observedAt,
                cumulativeConsumption: state.estimatedConsumption
            ))
            state.recentCreditNote = nil
        } else if delta < 0 {
            // 余额上升: 非消费入账, 累计值不变, 追加同值点保持时间轴连续.
            state.trendPoints.append(TrendPoint(
                observedAt: observation.observedAt,
                cumulativeConsumption: state.estimatedConsumption
            ))
            state.recentCreditNote = "入账未计入消费"
        }
        // 余额不变: 只更新去重状态, 不扩展趋势.
        state.lastObservation = observation
    }

    private func isDuplicateOrOutOfOrder(
        observation: DeepSeekUsageObservation,
        last: DeepSeekUsageObservation
    ) -> Bool {
        // 完全相同 -> 重复 (缓存重放)
        if observation == last { return true }
        // 时间不晚于最后观察 -> 乱序
        guard let obsDate = parseDate(observation.observedAt),
              let lastDate = parseDate(last.observedAt) else {
            return false
        }
        return obsDate <= lastDate
    }

    // MARK: - 月份与文案

    private func monthKey(for date: Date) -> String {
        let year = calendar.component(.year, from: date)
        let month = calendar.component(.month, from: date)
        return String(format: "%04d-%02d", year, month)
    }

    private func coverageText(for state: LedgerState) -> String {
        "自 \(shortDateText(state.coverageStart)) 起累计推算"
    }

    private func baselineText(for state: LedgerState) -> String {
        "自 \(shortDateText(state.coverageStart)) 起首次记录"
    }

    /// 覆盖起点日期文案: YY/MM/DD 短格式, 解析失败时原样透传.
    private func shortDateText(_ iso: String) -> String {
        guard let date = parseDate(iso) else { return iso }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yy/MM/dd"
        return formatter.string(from: date)
    }

    private func parseDate(_ iso: String) -> Date? {
        ISO8601DateFormatter().date(from: iso)
    }

    // MARK: - 持久化

    private func ensureLoaded(trackingID: String) {
        if state != nil { return }
        if let loaded = loadFromDisk(),
           loaded.trackingID == trackingID {
            state = loaded
        }
        // 磁盘不可读或追踪 ID 不匹配: 保持 nil, 由 record 重建基线.
    }

    private func persist() -> Bool {
        guard let state else { return false }
        do {
            try prepareDirectory()
            let data = try JSONEncoder().encode(state)
            return atomicWrite(data)
        } catch {
            return false
        }
    }

    private func prepareDirectory() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    /// 原子写入: 临时文件 0600 -> 同步 -> 重读解码校验 -> 原子替换.
    /// 失败不留下可被当作有效账本的半写入内容.
    private func atomicWrite(_ data: Data) -> Bool {
        let targetURL = rootURL
            .appendingPathComponent("deepseek-monthly.json")
        let tempURL = rootURL.appendingPathComponent(
            ".deepseek-monthly.\(UUID().uuidString).tmp"
        )
        do {
            guard fileManager.createFile(
                atPath: tempURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return false
            }
            let handle = try FileHandle(forWritingTo: tempURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: tempURL.path
            )
            // 重读解码校验
            guard let reread = fileManager.contents(atPath: tempURL.path) else {
                try? fileManager.removeItem(at: tempURL)
                return false
            }
            let verified = try JSONDecoder().decode(
                LedgerState.self, from: reread
            )
            guard verified == state else {
                try? fileManager.removeItem(at: tempURL)
                return false
            }
            if fileManager.fileExists(atPath: targetURL.path) {
                _ = try fileManager.atomicReplace(targetURL, with: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: targetURL)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: targetURL.path
            )
            return true
        } catch {
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    private func loadFromDisk() -> LedgerState? {
        let targetURL = rootURL
            .appendingPathComponent("deepseek-monthly.json")
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return nil
        }
        do {
            guard let data = fileManager.contents(atPath: targetURL.path) else {
                return nil
            }
            let loaded = try JSONDecoder().decode(
                LedgerState.self, from: data
            )
            guard loaded.schemaVersion == Self.schemaVersion else {
                return nil
            }
            return loaded
        } catch {
            return nil
        }
    }

    // MARK: - 持久化模型

    // LedgerState 移至文件级 (见文件末尾), 避免 private 嵌套类型 Codable 合成限制.
}

// MARK: - LedgerState

/// 账本持久化状态. 非敏感: 仅时间, 币种, 余额, 派生金额和趋势点.
private struct LedgerState: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let trackingID: String
    let monthKey: String
    let currency: String
    let coverageStart: String
    var lastObservation: DeepSeekUsageObservation?
    var estimatedConsumption: Decimal
    var trendPoints: [TrendPoint]
    var recentCreditNote: String?
}
