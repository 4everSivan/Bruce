import Foundation

/// 国家分组只保存订阅的路由归属，不持有或修改账号凭据。
public struct EgressCountryGroup: Codable, Equatable, Sendable {
    public let country: String
    public fileprivate(set) var providers: [SubscriptionProviderID]
    /// 回环 HTTP 专用代理端口；nil 表示尚未配置，不能放行查额。
    public fileprivate(set) var proxyPort: UInt16?
    /// 上次线路测试的脱敏结果；nil 表示尚未测试。
    public fileprivate(set) var lastTestResult: String?

    /// 对应的国旗 Emoji (例如 "🇯🇵")。
    public var flag: String {
        EgressCountryGroups.flagEmoji(for: country)
    }

    fileprivate init(country: String) {
        self.country = country
        self.providers = []
        self.proxyPort = nil
        self.lastTestResult = nil
    }
}

/// 分组输入或归属关系不符合约束。
public enum EgressCountryGroupError: Error, Equatable {
    case invalidCountry
    case duplicateCountry
    case countryNotFound
    case duplicateProvider
    case invalidPort
}

/// 管理国家与 provider 的一对多关系。跨组移动在一个值修改中完成。
/// 该模型本身不执行网络探测，也不表示出口保护已经生效。
public struct EgressCountryGroups: Codable, Equatable, Sendable {
    public private(set) var groups: [EgressCountryGroup]

    /// 创建空分组集合。
    public init() {
        groups = []
    }

    /// 判定是否为大写的 ISO 3166-1 两位国家代码。
    public static func isValidCountryCode(_ country: String) -> Bool {
        // Foundation 的 region 列表还包含 CLDR 宏地区及保留代码，并非 ISO 国家。
        let nonISOCodes: Set<String> = ["AC", "CP", "CQ", "DG", "EA", "EU", "EZ", "IC", "QO", "TA", "UN", "XK"]
        return country.utf8.count == 2
            && country.utf8.allSatisfy({ (65...90).contains($0) })
            && !nonISOCodes.contains(country)
            && Locale.Region.isoRegions.contains(where: { $0.identifier == country })
    }

    /// 计算两位 ISO 国家代码对应的国旗 Emoji 字符串；非有效两位字母时返回空字符串。
    public static func flagEmoji(for country: String) -> String {
        guard country.utf8.count == 2,
              country.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }) else {
            return ""
        }
        let upper = country.uppercased()
        return upper.utf8.compactMap { UnicodeScalar(127397 + UInt32($0)) }
            .map(String.init).joined()
    }

    /// 添加 ISO 两位国家代码；忽略首尾空白和大小写，非法或重复时抛错。
    public mutating func addCountry(_ input: String) throws {
        let country = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isValidCountryCode(country) else {
            throw EgressCountryGroupError.invalidCountry
        }
        guard !groups.contains(where: { $0.country == country }) else {
            throw EgressCountryGroupError.duplicateCountry
        }
        groups.append(EgressCountryGroup(country: country))
    }

    /// 解散指定大写国家代码的分组，不删除订阅或凭据。
    public mutating func removeCountry(_ country: String) throws {
        guard let index = groups.firstIndex(where: { $0.country == country }) else {
            throw EgressCountryGroupError.countryNotFound
        }
        groups.remove(at: index)
    }

    /// 设置或清除专用端口。0 不是有效端口；调用方负责确认其绑定固定节点。
    public mutating func setProxyPort(_ port: UInt16?, for country: String) throws {
        guard let index = groups.firstIndex(where: { $0.country == country }) else {
            throw EgressCountryGroupError.countryNotFound
        }
        guard port != 0 else { throw EgressCountryGroupError.invalidPort }
        if groups[index].proxyPort != port {
            groups[index].proxyPort = port
            groups[index].lastTestResult = nil
        }
    }

    /// 记录指定国家的最近线路测试结果；目标不存在时忽略。
    public mutating func setLastTestResult(_ result: String?, for country: String) {
        guard let index = groups.firstIndex(where: { $0.country == country }) else {
            return
        }
        groups[index].lastTestResult = result
    }

    /// 将 provider 分配至指定大写国家代码；目标不存在时保持原归属。
    public mutating func assign(_ provider: SubscriptionProviderID, to country: String) throws {
        guard let destination = groups.firstIndex(where: { $0.country == country }) else {
            throw EgressCountryGroupError.countryNotFound
        }
        for index in groups.indices {
            groups[index].providers.removeAll(where: { $0 == provider })
        }
        groups[destination].providers.append(provider)
    }

    /// 解除 provider 的分组归属，不删除订阅或凭据。
    public mutating func remove(_ provider: SubscriptionProviderID) {
        for index in groups.indices {
            groups[index].providers.removeAll(where: { $0 == provider })
        }
    }

    /// 解码时重新验证国家和唯一归属，拒绝无效或冲突的数据。
    public init(from decoder: Decoder) throws {
        let decoded = try [EgressCountryGroup](from: decoder)
        self.init()
        var providers = Set<String>()
        for group in decoded {
            try addCountry(group.country)
            let country = groups[groups.count - 1].country
            try setProxyPort(group.proxyPort, for: country)
            setLastTestResult(group.lastTestResult, for: country)
            for provider in group.providers {
                guard providers.insert(provider.rawValue).inserted else {
                    throw EgressCountryGroupError.duplicateProvider
                }
                try assign(provider, to: country)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        try groups.encode(to: encoder)
    }
}
