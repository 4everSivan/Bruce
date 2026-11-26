import Foundation

// MARK: - InterfaceStylePreference

/// 界面风格 (C271): 产品仅保留 Nothing 单色点阵仪器面板风.
/// 经典 (高斯云母) 与液态玻璃 (系统玻璃 / 材质退化) 已产品级退役,
/// 磁盘上遗留的 `classic` / `liquidGlass` 字符串不再能解码为可选项.
public enum InterfaceStylePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case nothing
}

// MARK: - ResolvedTheme

/// 运行时已解析的主题: C271 起只有 Nothing 一种, 恒可安全驱动渲染.
public struct ResolvedTheme: Equatable, Sendable {
    public let interfaceStyle: InterfaceStylePreference

    public init(interfaceStyle: InterfaceStylePreference = .nothing) {
        self.interfaceStyle = interfaceStyle
    }

    /// 唯一运行态主题.
    public static let nothing = ResolvedTheme()
}

// MARK: - ThemeResolution

/// 纯函数主题解析 (C271): 任何 stored 偏好都收敛为 Nothing.
public enum ThemeResolution: Sendable {
    /// - Parameter interfaceStyle: 磁盘存储的界面风格; 旧值 / nil 一律忽略.
    public static func resolve(
        interfaceStyle: InterfaceStylePreference?
    ) -> ResolvedTheme {
        .nothing
    }
}
