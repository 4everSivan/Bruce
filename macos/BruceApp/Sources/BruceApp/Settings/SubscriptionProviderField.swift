import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - 订阅 provider 凭证字段与引导描述

/// 单个凭证输入框的描述 (API key / AK / SK 共用同一组件).
struct APIKeyFieldDescriptor: Identifiable {
    let id: String // 取值键, 如 "apiKey" / "accessKey" / "secretKey"
    let placeholder: String
    let accessibilityLabel: String
}

/// 凭证获取引导: 文案 + 可选外链. linkURL 为 nil 时只显示文案.
/// 外链未经核实的不填, 由调用方确认 (见每个 provider 的 guide 构造).
struct ProviderCredentialGuide {
    let summary: String
    let linkTitle: String?
    let linkURL: URL?

    /// 引导文案 + 可点击外链 (Link 内部即 NSWorkspace.open, 无需 entitlement).
    /// destination 必须为 https, 否则系统静默拒绝, 故 URL 类型在构造期暴露错误.
    @ViewBuilder
    static func view(_ guide: ProviderCredentialGuide) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(guide.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let linkURL = guide.linkURL, let linkTitle = guide.linkTitle {
                Link(linkTitle, destination: linkURL)
                    .font(.caption)
            }
        }
    }
}

/// 参数化 section 的额外自定义 UI, 封闭变体集避免泛型传染.
enum APIKeyProviderExtra {
    case none
    /// 智谱站点选择器: true = 国内站.
    case sitePicker(Binding<Bool>)
    /// 火山引擎: 从 CC Switch 导入 (拉起确认对话框).
    case ccSwitchImport(Binding<Bool>)
}

/// 设置页 provider 行的就地错误提示 (橙色, 可诊断, 不回显凭证).
struct SubscriptionInlineErrorView: View {
    let provider: SubscriptionProviderID
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.subscriptionErrorMessages[provider] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("\(provider.displayName) 错误: \(message)")
        }
    }
}
