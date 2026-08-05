import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// DeepSeek 订阅管理区: API key 录入 / 更换 / 验证 (layout-identical extract).
struct DeepSeekProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var deepseekKeyText: String
    @Binding var deepseekEditing: Bool
    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.deepseek] ?? false
        let busy = model.busySubscriptionProviders.contains(.deepseek)
        let editing = deepseekEditing || !configured

        return managementStack {
            if editing {
                SecureField("API key (输入后不回显)", text: $deepseekKeyText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("DeepSeek API key")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                managementActionRow(
                    configured: model.subscriptionProviders[.deepseek] != nil,
                    removeHint: "从列表移除 DeepSeek 订阅",
                    remove: onRemove
                ) {
                    Button("保存并验证") {
                        coordinator.saveAndVerifyDeepSeek(apiKey: deepseekKeyText)
                        // API key 只进 Keychain, 提交后清空输入框
                        deepseekKeyText = ""
                        deepseekEditing = false
                    }
                    .disabled(busy || deepseekKeyText.isEmpty)
                    .accessibilityHint("保存到 Keychain 并联网验证 DeepSeek 余额接口")
                    if configured {
                        Button("取消") {
                            deepseekKeyText = ""
                            deepseekEditing = false
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } else {
                managementActionRow(
                    configured: model.subscriptionProviders[.deepseek] != nil,
                    removeHint: "从列表移除 DeepSeek 订阅",
                    remove: onRemove
                ) {
                    Button("更换") { deepseekEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的 DeepSeek API key")
                }
            }
        }
    }
}
