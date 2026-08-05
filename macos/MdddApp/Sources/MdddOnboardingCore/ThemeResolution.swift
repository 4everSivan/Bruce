import Foundation

// MARK: - InterfaceStylePreference

/// 界面风格: 经典 (全版本) 与 液态玻璃 (需 macOS 26+).
public enum InterfaceStylePreference: String, Codable, Equatable, Sendable, CaseIterable {
    case classic
    case liquidGlass
}

// MARK: - LiquidGlassCapability

/// 液态玻璃能力探测. 生产默认读系统版本; 测试可注入固定布尔.
public enum LiquidGlassCapability: Sendable {
    /// 当前进程是否支持系统液态玻璃 API (macOS 26+).
    public static var isSupported: Bool {
        if #available(macOS 26, *) {
            return true
        }
        return false
    }
}

// MARK: - ResolvedTheme

/// 运行时已解析的主题: 始终可安全驱动渲染分支.
public struct ResolvedTheme: Equatable, Sendable {
    public let interfaceStyle: InterfaceStylePreference
    /// 仅当 interfaceStyle == .liquidGlass 时用于玻璃变体; classic 下仍可有值但不驱动玻璃 API.
    public let glassStyle: GlassStylePreference
    public let usesLiquidGlassEffects: Bool

    public init(
        interfaceStyle: InterfaceStylePreference,
        glassStyle: GlassStylePreference,
        usesLiquidGlassEffects: Bool
    ) {
        self.interfaceStyle = interfaceStyle
        self.glassStyle = glassStyle
        self.usesLiquidGlassEffects = usesLiquidGlassEffects
    }
}

// MARK: - ThemeResolution

/// 纯函数主题解析: stored 偏好 + 能力旗标 -> ResolvedTheme.
public enum ThemeResolution: Sendable {
    /// - Parameters:
    ///   - interfaceStyle: 磁盘存储的界面风格; nil 表示缺键.
    ///   - glassStyle: 磁盘存储的模糊风格; nil 表示缺键.
    ///   - isSupported: 是否支持液态玻璃 (可注入).
    public static func resolve(
        interfaceStyle: InterfaceStylePreference?,
        glassStyle: GlassStylePreference?,
        isSupported: Bool
    ) -> ResolvedTheme {
        let blur = glassStyle ?? .regular
        let interface: InterfaceStylePreference
        if !isSupported {
            interface = .classic
        } else if let interfaceStyle {
            interface = interfaceStyle
        } else {
            // 26+ 且无 interfaceStyle: 旧配置默认液态玻璃 (保持现网体验)
            interface = .liquidGlass
        }
        let usesEffects = isSupported && interface == .liquidGlass && blur.usesGlassMaterial
        return ResolvedTheme(
            interfaceStyle: interface,
            glassStyle: blur,
            usesLiquidGlassEffects: usesEffects
        )
    }
}

extension GlassStylePreference {
    /// 是否在液态玻璃模式下走真实 glassEffect (material 为材质退化).
    public var usesGlassMaterial: Bool {
        self != .material
    }
}
