import Darwin
import Foundation

/// 将线路测试响应转换为不含完整 IP 的展示文案。
public enum EgressTracePresentation {
    public static func describe(_ text: String, expected: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        let countries = lines.compactMap { $0.hasPrefix("loc=") ? String($0.dropFirst(4)) : nil }
        let addresses = lines.compactMap { $0.hasPrefix("ip=") ? String($0.dropFirst(3)) : nil }
        guard countries.count == 1, addresses.count == 1,
              EgressCountryGroups.isValidCountryCode(countries[0]) else {
            return "无法识别出口国家"
        }
        let parts = addresses[0].split(separator: ".")
        let masked: String
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        let validIPv4 = addresses[0].withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
        let validIPv6 = addresses[0].withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
        if validIPv4 && parts.count == 4 {
            masked = "\(parts[0]).\(parts[1]).***.***"
        } else if validIPv6 {
            masked = "IPv6 已隐藏"
        } else {
            return "无法识别出口地址"
        }
        let label = countries[0] == expected ? "线路探测匹配" : "出口国家不匹配"
        return "\(label) · \(masked) (\(countries[0]))"
    }
}
