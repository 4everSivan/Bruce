import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Antigravity 订阅管理区: 本机 OAuth 导入 (layout-identical extract).
struct AntigravityProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.antigravity] ?? false

        return managementStack {
            if !configured && !model.antigravityLocalAvailable {
                Text("未检测到 Antigravity 登录态, 请先通过 Antigravity CLI 登录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // 凭证获取引导: 本机 OAuth 文件优先, 其次 agy 登录 Keychain 条目.
            ProviderCredentialGuide.view(ProviderCredentialGuide(
                summary: "先通过 Antigravity CLI 完成登录, 再由本应用只读导入本机 OAuth 令牌; 未检测到登录态时无法导入.",
                linkTitle: nil,
                linkURL: nil
            ))
            managementActionRow(
                configured: model.subscriptionProviders[.antigravity] != nil,
                removeHint: "从列表移除 Antigravity 订阅",
                remove: onRemove
            ) {
                if model.antigravityLocalAvailable {
                    Button("从本机导入") {
                        coordinator.importAntigravityFromLocalFile()
                    }
                    .accessibilityHint("读取 Antigravity CLI 的本机 OAuth 令牌 (文件或钥匙串)")
                }
            }
            // 就地错误: 导入 / 解码 / 校验失败均按 provider 归因, 不回显 token.
            SubscriptionInlineErrorView(provider: .antigravity)
        }
    }
}
