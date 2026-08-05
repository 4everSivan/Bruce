import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// 火山引擎订阅管理区: AK/SK 录入 / 更换 / 本地校验 / CC Switch 导入 (layout-identical extract).
struct VolcengineProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var volcengineAKText: String
    @Binding var volcengineSKText: String
    @Binding var volcengineEditing: Bool
    @Binding var showsVolcengineCCImportConfirm: Bool
    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.volcengine] ?? false
        let busy = model.busySubscriptionProviders.contains(.volcengine)
        let editing = volcengineEditing || !configured

        return managementStack {
            if editing {
                SecureField("AccessKey (输入后不回显)", text: $volcengineAKText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("火山引擎 AccessKey")
                SecureField("SecretKey (输入后不回显)", text: $volcengineSKText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("火山引擎 SecretKey")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                managementActionRow(
                    configured: model.subscriptionProviders[.volcengine] != nil,
                    removeHint: "从列表移除火山引擎订阅",
                    remove: onRemove
                ) {
                    Button("保存并验证") {
                        coordinator.saveAndVerifyVolcengine(
                            accessKey: volcengineAKText,
                            secretKey: volcengineSKText
                        )
                        volcengineAKText = ""
                        volcengineSKText = ""
                        volcengineEditing = false
                    }
                    .disabled(
                        busy || volcengineAKText.isEmpty || volcengineSKText.isEmpty
                    )
                    .accessibilityHint("保存到 Keychain 并做本地格式校验")
                    if configured {
                        Button("取消") {
                            volcengineAKText = ""
                            volcengineSKText = ""
                            volcengineEditing = false
                        }
                        .disabled(busy)
                    }
                }
                Text("此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                managementActionRow(
                    configured: model.subscriptionProviders[.volcengine] != nil,
                    removeHint: "从列表移除火山引擎订阅",
                    remove: onRemove
                ) {
                    Button("更换") { volcengineEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的火山引擎 AK/SK")
                }
            }
            if coordinator.ccSwitchDatabaseExists() {
                Button("从 CC Switch 导入") {
                    showsVolcengineCCImportConfirm = true
                }
                .disabled(busy)
                .accessibilityHint("只读导入 CC Switch 中火山 Codingplan 的 AK/SK")
            }
        }
    }
}
