import CoreText
import SwiftUI

/// Nothing 主题字体入口 (Doto / Space Grotesk / Space Mono).
///
/// 契约: 视图代码仅在 `theme.interfaceStyle == .nothing` 分支内调用,
/// 其余主题绝不可触碰. 字体注册失败或缺名时对应 API 永久回退 `.system`,
/// dev 模式 (`swift run`, 资源不在 bundle) 静默降级, 不崩溃不打印噪音.
enum NothingFont {
    /// 展示级数字字体: Doto (ROND+wght 双轴可变字体).
    static func display(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        customFont(family: "Doto", size: size, weight: weight)
    }

    /// 界面文本字体: Space Grotesk.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        customFont(family: "Space Grotesk", size: size, weight: weight)
    }

    /// 等宽数据字体: Space Mono.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        customFont(family: "Space Mono", size: size, weight: weight)
    }

    /// 启动早期调用一次 (UI 构建前), 提前触发字体注册; 幂等.
    static func activate() {
        _ = FontRegistry.registrationResults
    }

    private static func customFont(
        family: String,
        size: CGFloat,
        weight: Font.Weight
    ) -> Font {
        guard FontRegistry.isRegistered(family: family) else {
            return .system(size: size, weight: weight)
        }
        // Font.custom 无 weight 重载, 用 .weight 挂权重 (对可变字体映射 wght 轴).
        return .custom(family, size: size).weight(weight)
    }
}

/// 进程内字体注册器: 扫描 Bundle 的 Fonts 目录并注册全部 ttf,
/// 结果缓存为静态状态, 之后不再重试.
enum FontRegistry {
    /// 族名 → 是否注册成功. `static let` 惰性初始化只执行一次且线程安全;
    /// 目录缺失 (dev 直跑裸可执行) 时全部为 false, 对应 API 走回退.
    fileprivate static let registrationResults: [String: Bool] = registerBundledFonts()

    static func isRegistered(family: String) -> Bool {
        registrationResults[family] ?? false
    }

    private static func registerBundledFonts() -> [String: Bool] {
        let families = ["Doto", "Space Grotesk", "Space Mono"]
        guard let fontsDirectory = fontsDirectoryURL() else {
            return Dictionary(uniqueKeysWithValues: families.map { ($0, false) })
        }
        registerFontFiles(in: fontsDirectory)
        // 以族名实际可用性为准: 任一文件注册失败或缺名时该族走回退.
        let availableFamilies = Set(
            (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        )
        return Dictionary(
            uniqueKeysWithValues: families.map { ($0, availableFamilies.contains($0)) }
        )
    }

    /// 定位打包后的字体目录: Contents/Resources/Fonts;
    /// 兜底再试 bundle 根目录下的同一路径.
    private static func fontsDirectoryURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Fonts"),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    private static func registerFontFiles(in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in contents where url.pathExtension.lowercased() == "ttf" {
            // .process scope: 仅本进程可见, 不污染系统字体库.
            _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
