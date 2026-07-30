import Foundation

/// 应用外观主题. rawValue 与持久化配置, Widget 端主题名保持一致.
package enum AppTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case classic
    case liquidGlass

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .classic:
            return "经典"
        case .liquidGlass:
            return "液态玻璃"
        }
    }

    /// Widget 端 (host-bootstrap.js / glass-theme.css) 使用的主题名.
    package var widgetThemeName: String {
        switch self {
        case .classic:
            return "classic"
        case .liquidGlass:
            return "liquid-glass"
        }
    }
}
