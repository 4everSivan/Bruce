import Foundation

/// 应用版本号: 只读 Bundle 短版本字符串 (CFBundleShortVersionString).
/// 与诊断导出同源, 打包脚本从仓库根 VERSION 写入同一值.
public enum AppVersion {
    /// 读取当前 Bundle 版本; 缺失或非字符串回落 "unknown" (不阻断 UI).
    public static func current(bundle: Bundle = .main) -> String {
        current(raw: bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ))
    }

    /// 纯逻辑: 从原始值派生版本字符串 (测试注入, 不依赖真实 Bundle).
    public static func current(raw: Any?) -> String {
        guard let value = raw as? String, !value.isEmpty else {
            return "unknown"
        }
        return value
    }
}
