import Foundation
@testable import MdddAppCore
import MdddOnboardingCore

private enum LedgerTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

@MainActor
private func ledgerExpect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw LedgerTestFailure.expectation(message)
    }
}

/// 固定时区的公历 Calendar.
private func calendar(timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let utc = TimeZone(identifier: "UTC")!

/// 构造观察.
private func observation(
    _ iso: String, balance: Double, currency: String = "CNY"
) -> DeepSeekUsageObservation {
    DeepSeekUsageObservation(
        observedAt: iso,
        balance: Decimal(balance),
        currency: currency
    )
}

@main
@MainActor
struct DeepSeekUsageLedgerHarness {
    static func main() throws {
        // 5.1: 账本领域
        try firstObservationEstablishesBaseline()
        try balanceDecreaseAddsConsumption()
        try balanceIncreaseIsCreditOnly()
        try balanceUnchangedDoesNotExtendTrend()
        try duplicateAndOutOfOrderObservationsIgnored()
        try monthChangeRebaselines()
        try currencyChangeRebaselines()
        try trackingIDChangeRebaselines()

        // 5.2: 日历与时区边界
        try shanghaiMonthBoundary()
        try utcMonthBoundary()
        try cacheReplayDoesNotDoubleCount()
        try noBackfillBeforeFirstOrAcrossGap()

        // 5.3: 存储安全
        try privatePermissionsAndAtomicWrite()
        try corruptedFileRecoversSafely()
        try writeFailureKeepsBalanceAvailable()
        try onDiskDataHasNoSensitiveFields()

        print("DeepSeekUsageLedger tests passed: 17")
    }

    // MARK: - 5.1 账本领域

    /// 首次观察建立基线: 累计消费 0, 覆盖起点为首个观察时间.
    private static func firstObservationEstablishesBaseline() throws {
        let root = try temporaryRoot("ledger-baseline")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-A")
        let result = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("首次观察必须是 baseline, got \(result)")
        }
        try ledgerExpect(baseline.currentBalance == 100, "基线余额不符")
        try ledgerExpect(baseline.currency == "CNY", "基线币种不符")
    }

    /// 同月余额下降: 差额累加到推算消费, 追加累计趋势点.
    private static func balanceDecreaseAddsConsumption() throws {
        let root = try temporaryRoot("ledger-decrease")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-B")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        let result = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        guard case .trend(let trend) = result else {
            throw LedgerTestFailure.expectation("两次观察必须是 trend, got \(result)")
        }
        try ledgerExpect(trend.estimatedConsumption == 20, "推算消费应为 20, got \(trend.estimatedConsumption)")
        try ledgerExpect(trend.currentBalance == 80, "当前余额应为 80")
        try ledgerExpect(trend.trendPoints.count == 2, "趋势点应为 2 个")
        try ledgerExpect(
            trend.trendPoints.last?.cumulativeConsumption == 20,
            "最后趋势点累计值应为 20"
        )
    }

    /// 同月余额上升: 记为入账, 不冲减累计消费, 累计趋势点同值.
    private static func balanceIncreaseIsCreditOnly() throws {
        let root = try temporaryRoot("ledger-increase")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-C")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        let result = ledger.record(
            observation("2026-08-04T04:00:00+08:00", balance: 150)
        )
        guard case .trend(let trend) = result else {
            throw LedgerTestFailure.expectation("上升观察必须是 trend, got \(result)")
        }
        try ledgerExpect(trend.estimatedConsumption == 0, "上升不得增加消费")
        try ledgerExpect(trend.currentBalance == 150, "当前余额应为 150")
        try ledgerExpect(
            trend.recentCreditNote != nil,
            "上升必须记录入账注记"
        )
        try ledgerExpect(trend.trendPoints.count == 2, "上升应追加同值点保持时间轴连续")
        try ledgerExpect(
            trend.trendPoints.last?.cumulativeConsumption == 0,
            "上升点累计值必须不变"
        )
    }

    /// 余额不变: 只更新去重状态, 不扩展趋势.
    private static func balanceUnchangedDoesNotExtendTrend() throws {
        let root = try temporaryRoot("ledger-unchanged")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-D")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        let result = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 100)
        )
        // 两次余额相同但时间不同: 更新最后观察但不扩展趋势点
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("余额不变不产生第二条可绘制观察, got \(result)")
        }
        try ledgerExpect(baseline.currentBalance == 100, "余额不变时余额不符")
    }

    /// 重复观察 (缓存重放) 和乱序观察不重复记账.
    private static func duplicateAndOutOfOrderObservationsIgnored() throws {
        let root = try temporaryRoot("ledger-dedup")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-E")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        _ = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        let trendResult = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        guard case .trend = trendResult else {
            throw LedgerTestFailure.expectation("重放前必须是 trend")
        }
        // 缓存重放: 相同 generatedAt+currency+balance -> 不记账
        _ = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        let afterReplay = ledger.currentUsage()
        guard case .trend(let after) = afterReplay else {
            throw LedgerTestFailure.expectation("重放后仍应为 trend")
        }
        try ledgerExpect(
            after.estimatedConsumption == 20,
            "缓存重放不得重复记账, got \(after.estimatedConsumption)"
        )
        try ledgerExpect(after.trendPoints.count == 2, "重放不得扩展趋势点")

        // 乱序: 时间早于最后观察 -> 忽略
        _ = ledger.record(
            observation("2026-08-03T08:00:00+08:00", balance: 90)
        )
        let afterOutOfOrder = ledger.currentUsage()
        guard case .trend(let afterOrder) = afterOutOfOrder else {
            throw LedgerTestFailure.expectation("乱序后仍应为 trend")
        }
        try ledgerExpect(
            afterOrder.estimatedConsumption == 20,
            "乱序观察不得记账, got \(afterOrder.estimatedConsumption)"
        )
    }

    /// 跨月: 新月份以首个观察重建基线, 不回填间隔消费.
    private static func monthChangeRebaselines() throws {
        let root = try temporaryRoot("ledger-month")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-F")
        _ = ledger.record(
            observation("2026-07-31T23:00:00+08:00", balance: 100)
        )
        _ = ledger.record(
            observation("2026-08-01T10:00:00+08:00", balance: 90)
        )
        let result = ledger.currentUsage()
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("跨月重建必须回到 baseline, got \(result)")
        }
        try ledgerExpect(
            baseline.currentBalance == 90,
            "跨月基线余额应为 90"
        )
    }

    /// 币种变化: 重建基线, 不换算.
    private static func currencyChangeRebaselines() throws {
        let root = try temporaryRoot("ledger-currency")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-G")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100, currency: "CNY")
        )
        let result = ledger.record(
            observation("2026-08-04T04:00:00+08:00", balance: 50, currency: "USD")
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("币种变化必须重建基线, got \(result)")
        }
        try ledgerExpect(baseline.currency == "USD", "币种变化后币种应为 USD")
        try ledgerExpect(baseline.currentBalance == 50, "币种变化后余额应为 50")
    }

    /// 追踪 ID 更换: 重建基线 (API Key 更换隔离).
    private static func trackingIDChangeRebaselines() throws {
        let root = try temporaryRoot("ledger-tracking")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-H")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        _ = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        // 更换追踪 ID (保存新 API key)
        ledger.setTrackingID("tracking-I")
        let result = ledger.record(
            observation("2026-08-04T04:00:00+08:00", balance: 60)
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("追踪 ID 更换必须重建基线, got \(result)")
        }
        try ledgerExpect(
            baseline.currentBalance == 60,
            "新追踪 ID 基线余额应为 60"
        )
        // 新 ID 的账本不继承旧 ID 的消费
        try ledgerExpect(
            baseline.coverageStartText.contains("2026-08-04"),
            "新基线覆盖起点应为新观察时间"
        )
    }

    // MARK: - 5.2 日历与时区边界

    /// Asia/Shanghai 跨日边界: 8 月 1 日 00:30 (+08) 与 7 月 31 日 16:30 UTC 是同一时刻.
    /// 本地月份按 +08 计算, 因此 8 月 1 日 00:30 (+08) 属于 8 月.
    private static func shanghaiMonthBoundary() throws {
        let root = try temporaryRoot("ledger-shanghai")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-SH")
        // 7 月 31 日 23:00 (+08) -> 7 月
        _ = ledger.record(
            observation("2026-07-31T23:00:00+08:00", balance: 100)
        )
        // 8 月 1 日 00:30 (+08) -> 8 月 (同一 UTC 时刻跨过本地月界)
        let result = ledger.record(
            observation("2026-08-01T00:30:00+08:00", balance: 95)
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("上海时区跨月必须重建基线, got \(result)")
        }
        try ledgerExpect(baseline.currentBalance == 95, "上海跨月基线余额应为 95")
    }

    /// UTC 时区: 8 月 1 日 00:30 UTC 属于 8 月; 7 月 31 日 23:00 UTC 属于 7 月.
    private static func utcMonthBoundary() throws {
        let root = try temporaryRoot("ledger-utc")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: utc)
        )
        ledger.setTrackingID("tracking-UTC")
        _ = ledger.record(
            observation("2026-07-31T23:00:00+00:00", balance: 100)
        )
        let result = ledger.record(
            observation("2026-08-01T00:30:00+00:00", balance: 95)
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("UTC 跨月必须重建基线, got \(result)")
        }
        try ledgerExpect(baseline.currentBalance == 95, "UTC 跨月基线余额应为 95")
    }

    /// 重启后缓存快照重放: 同一 Artifact 重放不重复记账.
    private static func cacheReplayDoesNotDoubleCount() throws {
        let root = try temporaryRoot("ledger-replay")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-J")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        _ = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )

        // 模拟重启: 新建账本实例指向同一目录, 从磁盘加载
        let restarted = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        restarted.setTrackingID("tracking-J")
        // 重放最后一条观察 (缓存快照)
        _ = restarted.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )
        let result = restarted.currentUsage()
        guard case .trend(let trend) = result else {
            throw LedgerTestFailure.expectation("重启重放后应为 trend, got \(result)")
        }
        try ledgerExpect(
            trend.estimatedConsumption == 20,
            "重启重放不得重复记账, got \(trend.estimatedConsumption)"
        )
    }

    /// 首次记录前, 跨月间隔和账本中断期间不回填未知消费.
    private static func noBackfillBeforeFirstOrAcrossGap() throws {
        let root = try temporaryRoot("ledger-nobackfill")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-K")
        // 8 月 3 日首次观察: 不推算 8 月 1-2 日的消费 (从 0 开始)
        let first = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        guard case .baseline(let baseline) = first else {
            throw LedgerTestFailure.expectation("首次观察必须是 baseline")
        }
        try ledgerExpect(
            baseline.coverageStartText.contains("2026-08-03"),
            "覆盖起点必须从首次记录开始"
        )

        // 8 月 5 日观察: 8 月 3-5 日之间的变化计入 (同月连续观察),
        // 但 8 月 4 日 (无观察) 的未知消费不会被回填.
        _ = ledger.record(
            observation("2026-08-05T04:00:00+08:00", balance: 90)
        )
        let result = ledger.currentUsage()
        guard case .trend(let trend) = result else {
            throw LedgerTestFailure.expectation("同月连续观察应为 trend")
        }
        try ledgerExpect(
            trend.estimatedConsumption == 10,
            "间隔后的首次下降计入消费, got \(trend.estimatedConsumption)"
        )
    }

    // MARK: - 5.3 存储安全

    /// 私有权限: 目录 0700, 文件 0600; 原子写入不留半写入文件.
    private static func privatePermissionsAndAtomicWrite() throws {
        let root = try temporaryRoot("ledger-permissions")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-P")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )

        let ledgerDir = root.appendingPathComponent("usage-ledger")
        let fileURL = ledgerDir.appendingPathComponent("deepseek-monthly.json")
        try ledgerExpect(
            FileManager.default.fileExists(atPath: fileURL.path),
            "账本文件必须存在"
        )
        let dirAttrs = try FileManager.default.attributesOfItem(
            atPath: ledgerDir.path
        )
        let fileAttrs = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
        let filePerms = (fileAttrs[.posixPermissions] as? NSNumber)?.intValue
        try ledgerExpect(dirPerms == 0o700, "目录权限必须 0700, got \(String(describing: dirPerms))")
        try ledgerExpect(filePerms == 0o600, "文件权限必须 0600, got \(String(describing: filePerms))")

        // 无半写入的 .tmp 文件残留
        let tmpFiles = try FileManager.default.contentsOfDirectory(
            atPath: ledgerDir.path
        ).filter { $0.hasSuffix(".tmp") }
        try ledgerExpect(tmpFiles.isEmpty, "不得残留临时文件: \(tmpFiles)")
    }

    /// 损坏文件: 不使用损坏数据, 下一次有效观察以新基线恢复.
    private static func corruptedFileRecoversSafely() throws {
        let root = try temporaryRoot("ledger-corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-C1")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )

        // 损坏账本文件
        let ledgerDir = root.appendingPathComponent("usage-ledger")
        let fileURL = ledgerDir.appendingPathComponent("deepseek-monthly.json")
        try Data("not-json".utf8).write(to: fileURL)

        // 新实例 (模拟重启) 加载损坏文件 -> 账本不可用
        let restarted = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        restarted.setTrackingID("tracking-C1")
        guard case .unavailable = restarted.currentUsage() else {
            throw LedgerTestFailure.expectation("损坏文件加载后必须不可用")
        }
        // 下一次有效观察以新基线恢复
        let result = restarted.record(
            observation("2026-08-03T12:00:00+08:00", balance: 90)
        )
        guard case .baseline(let baseline) = result else {
            throw LedgerTestFailure.expectation("损坏恢复后必须是 baseline, got \(result)")
        }
        try ledgerExpect(baseline.currentBalance == 90, "损坏恢复基线余额应为 90")
    }

    /// 账本失败不影响当前余额: 磁盘错误时 currentUsage 返回不可用,
    /// 但余额卡 (由 artifact 提供) 不受影响.
    private static func writeFailureKeepsBalanceAvailable() throws {
        let root = try temporaryRoot("ledger-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-W")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        // 模拟写入失败: 把 usage-ledger 目录变成文件 (写入会失败)
        let ledgerDir = root.appendingPathComponent("usage-ledger")
        try? FileManager.default.removeItem(at: ledgerDir)
        try "blocked".data(using: .utf8)?.write(to: ledgerDir)

        let result = ledger.record(
            observation("2026-08-04T04:00:00+08:00", balance: 80)
        )
        guard case .unavailable = result else {
            throw LedgerTestFailure.expectation("写入失败后月度统计必须不可用, got \(result)")
        }
    }

    /// 落盘数据不含敏感字段: 无 API Key, Token, 账号名, 会话, 认证响应或完整 Artifact.
    private static func onDiskDataHasNoSensitiveFields() throws {
        let root = try temporaryRoot("ledger-sensitive")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = DeepSeekUsageLedger(
            rootURL: root,
            calendar: calendar(timeZone: shanghai)
        )
        ledger.setTrackingID("tracking-S")
        _ = ledger.record(
            observation("2026-08-03T04:00:00+08:00", balance: 100)
        )
        _ = ledger.record(
            observation("2026-08-03T12:00:00+08:00", balance: 80)
        )

        let ledgerDir = root.appendingPathComponent("usage-ledger")
        let fileURL = ledgerDir.appendingPathComponent("deepseek-monthly.json")
        let data = try Data(contentsOf: fileURL)
        let text = String(data: data, encoding: .utf8) ?? ""
        let sensitivePatterns = [
            "apiKey", "api_key", "token", "access_token", "refresh_token",
            "password", "secret", "account", "email", "session", "auth",
            "artifact", "agents", "services",
        ]
        for pattern in sensitivePatterns {
            try ledgerExpect(
                !text.localizedCaseInsensitiveContains(pattern),
                "落盘数据不得包含敏感字段: \(pattern)"
            )
        }
        // 必须包含追踪 ID 与月份 (非敏感追踪信息)
        try ledgerExpect(
            text.contains("tracking-S"),
            "落盘数据必须包含追踪 ID"
        )
    }

    // MARK: - 辅助

    private static func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mddd-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        return root
    }
}
