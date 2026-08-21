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
        }
    }
}
