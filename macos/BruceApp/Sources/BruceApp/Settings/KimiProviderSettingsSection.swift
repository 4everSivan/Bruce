import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Kimi For Coding 订阅管理区: API key 录入 / 更换 / 验证 (layout-identical extract).
struct KimiProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var kimiKeyText: String
    @Binding var kimiEditing: Bool
    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.kimi] ?? false
        let busy = model.busySubscriptionProviders.contains(.kimi)
        let editing = kimiEditing || !configured

        return managementStack {
            if editing {
                SecureField("API key (输入后不回显)", text: $kimiKeyText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("Kimi For Coding API key")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                managementActionRow(
                    configured: model.subscriptionProviders[.kimi] != nil,
                    removeHint: "从列表移除 Kimi 订阅",
                    remove: onRemove
                ) {
                    Button("保存并验证") {
                        coordinator.saveAndVerifyKimi(apiKey: kimiKeyText)
                        kimiKeyText = ""
                        kimiEditing = false
                    }
                    .disabled(busy || kimiKeyText.isEmpty)
                    .accessibilityHint("保存到 Keychain 并做本地格式校验")
                    if configured {
                        Button("取消") {
                            kimiKeyText = ""
                            kimiEditing = false
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("在 kimi.com/code 申请 Kimi For Coding API key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                managementActionRow(
                    configured: model.subscriptionProviders[.kimi] != nil,
                    removeHint: "从列表移除 Kimi 订阅",
                    remove: onRemove
                ) {
                    Button("更换") { kimiEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的 Kimi For Coding API key")
                }
            }
        }
    }
}
