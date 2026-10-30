import Foundation

/// 设置窗口侧边栏分类 (C157): 从 SettingsView 私有枚举上移,
/// 供菜单栏仪表盘的空态 CTA 做深链；标题与图标仍是跨平台同构的展示值.
package enum SettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case general, agentUsage, modelPricing, subscription, consent, maintenance

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .general: return "通用"
        case .agentUsage: return "模型用量"
        case .modelPricing: return "模型计费"
        case .subscription: return "订阅额度"
        case .consent: return "授权与隐私"
        case .maintenance: return "维护"
        }
    }

    package var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .agentUsage: return "chart.bar"
        case .modelPricing: return "dollarsign.circle"
        case .subscription: return "cloud"
        case .consent: return "checkmark.shield"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}
