import Foundation
import BruceOnboardingCore

// MARK: - SubscriptionPresentationPolicy

/// 订阅卡纯展示规则 (S5a): 从 Panel 映射器拆出, 便于表驱动锁定.
/// 冻结: kimi_coding→kimi 排序键; volcengine 显示名剥离; 加量包文案隐藏;
/// deepseek 月度挂载; codex 分组判定; partial 占位 skip.
package enum SubscriptionPresentationPolicy: Sendable {
    /// 把 artifact service ID 归一化为 SubscriptionProviderID rawValue,
    /// 供用户自定义顺序查找. Kimi 的 service ID 是 "kimi_coding" 而
    /// provider rawValue 是 "kimi"; 其他 service ID 与 provider rawValue 一致.
    package static func providerID(forServiceID serviceID: String) -> String {
        switch serviceID {
        case "kimi_coding": return "kimi"
        default:
            // 多账号 service ID 格式: <provider>_<accountID> (如 codex_a1b2c3d4).
            // 按 provider rawValue 前缀分组.
            for provider in SubscriptionProviderID.allCases {
                let prefix = provider.rawValue + "_"
                if serviceID.hasPrefix(prefix) {
                    return provider.rawValue
                }
            }
            // collector 连字符命名 (opencode_go_xxx): 归一为 rawValue
            // (与 providerOrder 配置键一致, 供自定义顺序查找).
            if serviceID.hasPrefix("opencode_go_") {
                return SubscriptionProviderID.opencodeGo.rawValue
            }
            return serviceID
        }
    }

    /// 服务所属 provider (C118): 优先 collector 显式下发的 `provider`, 旧 artifact 缺省时
    /// 回退按 service id 前缀推断。
    package static func providerID(for service: AgentServiceItem) -> String {
        if let provider = service.provider, !provider.isEmpty {
            return provider
        }
        return providerID(forServiceID: service.id)
    }

    /// 同 `providerID(for:)`, 供以 JSONValue 处理 artifact 的合并 / 节流路径使用。
    package static func providerID(forServiceObject object: [String: JSONValue]) -> String? {
        if let provider = object["provider"]?.stringIdValue, !provider.isEmpty {
            return provider
        }
        return object["id"]?.stringIdValue.map(providerID(forServiceID:))
    }

    /// 订阅展示名: 火山引擎剥离 collector 名称里的 Coding Plan 后缀, 仅显示层覆盖.
    package static func displayName(serviceID: String, serviceName: String) -> String {
        guard serviceID == "volcengine" else { return serviceName }
        return serviceName.replacingOccurrences(of: "（Coding Plan）", with: "")
    }

    /// 附加文案: 「加量包未启用」对用户无信息量, 不展示; 余额等其他文案保留.
    /// - Parameter extra: 已归一化 (空串视为 nil) 的 extra 字段.
    package static func extraText(_ extra: String?) -> String? {
        extra == "加量包未启用" ? nil : extra
    }

    /// 未授权占位 (status partial, 无窗口无余额, kind 为空) 视为未启用, 排除.
    /// 仅 partial 是占位; empty 是查询未取到数据的真实诊断状态, 必须渲染.
    package static func shouldSkipPlaceholder(
        kind: String?,
        hasWindows: Bool,
        hasBalance: Bool,
        status: String
    ) -> Bool {
        kind == nil && !hasWindows && !hasBalance && status == "partial"
    }

    /// 订阅 Provider「移除服务」入口门禁 (C019).
    /// 只要已添加进列表 (配置条目存在) 即可移除——凭证存在与否不作为移除前提,
    /// 否则「添加后未保存凭证」的半添加行会既不能启用 (开关随未配置禁用)
    /// 也不能移除, 形成死锁态; 凭证存在而列表无条目时同样允许 (防御性清理).
    package static func showsProviderRemoval(
        isAdded: Bool,
        isConfigured: Bool
    ) -> Bool {
        isAdded || isConfigured
    }

    /// 仪表盘订阅段展示门禁 (C020): 仅验证状态 ok 的 Provider 才进入订阅段.
    /// 未验证 (none) / 验证失败 (failed) / 需重新登录 (needsRelogin) 一律不展示,
    /// 与设置页「已配置」状态联动, 避免未验证订阅出现在仪表盘.
    package static func isVerifiedForDashboard(
        _ status: SubscriptionVerificationStatus
    ) -> Bool {
        status == .ok
    }

    /// 暂时屏蔽的 Provider 列表（Jev 因官方未开放查额 API 暂作界面隐藏，底层保留）.
    package static func isProviderTemporarilyDisabled(_ providerID: String) -> Bool {
        providerID == "jev"
    }

    /// app=="codex" 的 service 进入 Codex 多账号分组.
    package static func isCodex(app: String?) -> Bool {
        app == "codex"
    }

    /// 从 "Codex · <短名>" 中只删除开头固定前缀, 不用 replacingOccurrences
    /// 全局替换, 避免账号名内部包含相同文本时被误改.
    package static func codexAccountShortName(from displayName: String) -> String {
        let prefix = "Codex · "
        if displayName.hasPrefix(prefix) {
            return String(displayName.dropFirst(prefix.count))
        }
        return displayName
    }

    /// 多账号分组的展示名: 按 provider ID 取固定名称.
    package static func groupDisplayName(providerID: String) -> String {
        switch providerID {
        case "codex": return "ChatGPT"
        case "kimi": return "Kimi"
        case "deepseek": return "DeepSeek"
        case "volcengine": return "火山引擎"
        case "zhipu": return "Z.ai"
        case "claude": return "Claude"
        case "grok": return "Grok"
        case "opencodeGo", "opencode-go": return "OpenCode GO"
        case "stepfun": return "StepFun"
        case "jev": return "Jev"
        case "cline": return "Cline"
        default: return providerID
        }
    }

    /// 通用账号短名: 按 provider 剥离前缀. Codex 剥离 "Codex · ",
    /// 其他 provider 剥离 "<Provider displayName> · " 前缀 (如有).
    package static func accountShortName(
        from displayName: String, providerID: String
    ) -> String {
        if providerID == "codex" {
            return codexAccountShortName(from: displayName)
        }
        // 通用: 剥离 "X · " 前缀 (X 为 provider 显示名或 service 名)
        if let range = displayName.range(of: " · ") {
            return String(displayName[range.upperBound...])
        }
        return displayName
    }

    /// 账号标记 (例如国外站/国际站标记):
    /// 仅当该 Provider 存在多个账号 (totalAccountCount > 1) 时为国外站添加 "国际" 标记;
    /// 如果只有一个账号则不做标记 (返回 nil).
    package static func accountTag(
        from displayName: String,
        providerID: String,
        totalAccountCount: Int
    ) -> String? {
        guard totalAccountCount > 1 else { return nil }
        if providerID == "stepfun",
           ProviderAccountNaming.isStepFunGlobalDisplayName(displayName) {
            return "国际"
        }
        return nil
    }

    /// Codex 分组状态: 取账号中最差状态 (ok < partial < error).
    package static func codexGroupStatus(from statuses: [String]) -> String {
        let statusRank = ["ok": 0, "partial": 1, "error": 2]
        let worst = statuses.map { statusRank[$0] ?? 1 }.max() ?? 0
        return statusRank.first(where: { $0.value == worst })?.key ?? "partial"
    }

    /// 多账号折叠态窗口摘要: 取所有账号中 usedPercent 最高的
    /// 最短重置周期窗口 (windowMinutes 最小).
    package static func collapsedWindow(
        from accounts: [CodexAccountViewModel]
    ) -> SubscriptionWindowRow? {
        let allWindows = accounts.flatMap { account in
            account.windows.map { (window: $0, account: account) }
        }
        guard !allWindows.isEmpty else { return nil }
        // 先按 windowMinutes 升序 (最短窗口优先), 再按 usedPercent 降序 (最高用量优先)
        let sorted = allWindows.sorted { lhs, rhs in
            let lhsMin = lhs.window.windowMinutes ?? Int.max
            let rhsMin = rhs.window.windowMinutes ?? Int.max
            if lhsMin != rhsMin {
                return lhsMin < rhsMin
            }
            return lhs.window.usedPercent > rhs.window.usedPercent
        }
        return sorted.first?.window
    }
}
