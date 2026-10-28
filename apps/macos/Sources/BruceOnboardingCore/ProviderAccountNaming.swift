import Foundation

// MARK: - ProviderAccountNamingError

/// 账号显示名校验错误. 文案由 UI 直接呈现, 不含任何凭据内容.
public enum ProviderAccountNamingError: Error, Equatable, Sendable {
    case empty
    case tooLong
    case controlCharacters
    case duplicate

    public var message: String {
        switch self {
        case .empty:
            return "账号名称不能为空"
        case .tooLong:
            return "账号名称最多 \(ProviderAccountNaming.maxLabelCharacters) 个字符"
        case .controlCharacters:
            return "账号名称不能包含换行或控制字符"
        case .duplicate:
            return "该名称已被同 Provider 的其他账号使用"
        }
    }
}

// MARK: - ProviderAccountNaming

/// 订阅多账号的显示名规范 (T18).
///
/// 存储值固定为 `<Provider 前缀> · <标签>`: 前缀由系统维护、不可编辑,
/// 用户只编辑标签. 默认标签为「账号 N」, N 是该 Provider 内最小未占用正整数.
/// 账号 ID、凭据键与 collector service ID 均不参与命名, 改名前后保持不变.
public enum ProviderAccountNaming {
    public static let maxLabelCharacters = 32
    public static let maxDisplayNameBytes = 256

    /// 默认标签.
    public static func defaultLabel(_ number: Int) -> String {
        "账号 \(number)"
    }

    /// Provider 前缀. StepFun 国际站使用独立的站点前缀.
    public static func displayPrefix(
        for provider: SubscriptionProviderID,
        stepFunGlobal: Bool = false
    ) -> String {
        if provider == .stepfun && stepFunGlobal {
            return "StepFun (国际)"
        }
        return provider.displayName
    }

    /// 该 Provider 可能出现在存量显示名里的前缀, 长前缀优先匹配.
    public static func knownPrefixes(for provider: SubscriptionProviderID) -> [String] {
        if provider == .stepfun {
            // 兼容历史写法: 国际站曾使用 "StepFun (国际)" 与 "StepFun 国际站".
            return ["StepFun (国际)", "StepFun 国际站", "StepFun 国际", "StepFun"]
        }
        return [provider.displayName]
    }

    /// 从完整显示名剥离已知 Provider 前缀, 返回标签.
    /// 只识别精确的 `<前缀> · `, 不做全局 `" · "` 切分, 避免自定义标签被误切.
    /// 无法识别前缀时原样返回, 让调用方仍可按完整名做唯一性判断.
    public static func label(
        from displayName: String,
        provider: SubscriptionProviderID
    ) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in knownPrefixes(for: provider).sorted(by: { $0.count > $1.count }) {
            if trimmed == prefix {
                return ""
            }
            let separator = prefix + " · "
            if trimmed.hasPrefix(separator) {
                return String(trimmed.dropFirst(separator.count))
            }
        }
        return trimmed
    }

    /// 组合完整显示名. 调用方应先经 `validateLabel` 校验标签.
    public static func compose(
        provider: SubscriptionProviderID,
        label: String,
        stepFunGlobal: Bool = false
    ) -> String {
        let prefix = displayPrefix(for: provider, stepFunGlobal: stepFunGlobal)
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? prefix : "\(prefix) · \(trimmed)"
    }

    /// 新建账号的默认显示名: 「账号 N」, N 为同 Provider 内最小未占用序号.
    /// - Parameter existingDisplayNames: 该 Provider 现有账号的全部显示名.
    /// - Parameter excludingDisplayName: 「恢复默认」时排除账号自身现有名, 避免
    ///   把已被自己占用的序号误判为冲突而顺延.
    public static func defaultDisplayName(
        for provider: SubscriptionProviderID,
        existingDisplayNames: [String],
        stepFunGlobal: Bool = false,
        excludingDisplayName: String? = nil
    ) -> String {
        let excluded = excludingDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let used = Set(
            existingDisplayNames
                .filter { name in
                    guard let excluded else { return true }
                    return name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased() != excluded
                }
                .map { label(from: $0, provider: provider).lowercased() }
        )
        var number = 1
        while used.contains(defaultLabel(number).lowercased()) {
            number += 1
        }
        return compose(
            provider: provider,
            label: defaultLabel(number),
            stepFunGlobal: stepFunGlobal
        )
    }

    /// 校验并归一化标签 (trim). 空输入抛 `.empty`, 由 UI 转成「恢复默认」.
    public static func validateLabel(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderAccountNamingError.empty
        }
        guard trimmed.count <= maxLabelCharacters else {
            throw ProviderAccountNamingError.tooLong
        }
        let hasControl = trimmed.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
        }
        guard !hasControl else {
            throw ProviderAccountNamingError.controlCharacters
        }
        return trimmed
    }

    /// 目标显示名是否与同 Provider 的其他账号重复 (大小写不敏感).
    /// - Parameter excludingDisplayName: 被重命名账号的现有显示名, 允许改成自身原名.
    public static func isDuplicate(
        _ displayName: String,
        provider: SubscriptionProviderID,
        existingDisplayNames: [String],
        excludingDisplayName: String? = nil
    ) -> Bool {
        let key = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let excluded = excludingDisplayName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return existingDisplayNames.contains { existing in
            let existingKey = existing
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return existingKey == key && existingKey != excluded
        }
    }

    /// StepFun 站点判定: 只认名称开头的站点前缀, 不用 contains.
    /// 兼容历史写法 `StepFun (国际) · x` 与 `StepFun 国际站 · x`;
    /// 自定义标签位于 `StepFun · <标签>`, 不会误命中.
    public static func isStepFunGlobalDisplayName(_ displayName: String) -> Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("StepFun (国际)") || trimmed.hasPrefix("StepFun 国际")
    }

    /// StepFun 换站点重存时的名称协调: 站点前缀取新站点, 标签保留原标签.
    /// 其他 Provider 不走此函数 (upsert 直接保留现有显示名).
    public static func reconciledStepFunDisplayName(
        existingDisplayName: String,
        newDisplayName: String
    ) -> String {
        let label = label(from: existingDisplayName, provider: .stepfun)
        let isGlobal = isStepFunGlobalDisplayName(newDisplayName)
        return compose(provider: .stepfun, label: label, stepFunGlobal: isGlobal)
    }

    /// 校验完整显示名未超过 collector 的字节上限.
    public static func fitsCollectorLimit(_ displayName: String) -> Bool {
        displayName.utf8.count <= maxDisplayNameBytes
    }
}
