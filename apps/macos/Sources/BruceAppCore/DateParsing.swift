import Foundation

/// 热路径 ISO 8601 解析/格式化 (C106): 复用格式器实例, 不在每次调用时新建.
///
/// 每次 `ISO8601DateFormatter()` 都要重新装配 ICU 格式器, artifact 校验与额度
/// 节流按 service / 按日调用时累积成主线程可感知的耗时. 格式器在初始化闭包内
/// 配置完毕后不再变更, 且 Foundation 格式器在 macOS 上线程安全, 故以
/// `nonisolated(unsafe)` 共享.
package enum ISODate {
    /// 与 `ISO8601DateFormatter()` 默认配置一致: `.withInternetDateTime`, GMT.
    nonisolated(unsafe) private static let internet = ISO8601DateFormatter()

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 与 `ISO8601DateFormatter().date(from:)` 同义.
    package static func parse(_ value: String) -> Date? {
        internet.date(from: value)
    }

    /// 先按带小数秒解析, 失败再按不带小数秒解析.
    package static func parseAllowingFractionalSeconds(_ value: String) -> Date? {
        fractional.date(from: value) ?? internet.date(from: value)
    }

    /// 与 `ISO8601DateFormatter().string(from:)` 同义 (秒级, UTC, `Z` 结尾).
    package static func string(from date: Date) -> String {
        internet.string(from: date)
    }
}

/// 严格 `yyyy-MM-dd` 公历日期校验 (C106).
///
/// 与旧实现「非宽松 gregorian/UTC `DateFormatter` 解析后回写比对」同义:
/// 必须恰为 4 位年 (≥ 0001)、2 位月 (01–12)、2 位日 (01–当月天数, 含闰年),
/// 不接受多余空白或单位数月日. 纯字节判断, 不分配格式器.
package enum CalendarDay {
    package static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-") else {
            return false
        }
        guard let year = number(bytes[0..<4]),
              let month = number(bytes[5..<7]),
              let day = number(bytes[8..<10]),
              year >= 1,
              (1...12).contains(month) else {
            return false
        }
        return day >= 1 && day <= daysInMonth(month, year: year)
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for byte in digits {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    private static func daysInMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}
