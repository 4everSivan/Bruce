import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// 智谱 Coding Plan 订阅管理区: API key 录入 + 站点选择 (国内站/国外站, 默认国内站).
struct ZhipuProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var zhipuKeyText: String
    @Binding var zhipuSiteIsCN: Bool
    @Binding var zhipuEditing: Bool
    var onRemove: () -> Void

    /// 智谱个人版推理端点 (Anthropic 兼容), 国内站 / 国外站.
    static let cnBaseURL = "https://open.bigmodel.cn/api/paas/v4"
    static let enBaseURL = "https://api.z.ai/api/paas/v4"

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.zhipu] ?? false
        let busy = model.busySubscriptionProviders.contains(.zhipu)
        let editing = zhipuEditing || !configured

        return managementStack {
            if editing {
                SecureField("API key (输入后不回显)", text: $zhipuKeyText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(busy)
                    .accessibilityLabel("智谱 API key")
                    .accessibilityHint("密钥只保存到本应用的 Keychain")
                Picker("站点", selection: $zhipuSiteIsCN) {
                    Text("国内站 (open.bigmodel.cn)").tag(true)
                    Text("国外站 (api.z.ai)").tag(false)
                }
                .pickerStyle(.radioGroup)
                .disabled(busy)
                .accessibilityLabel("智谱站点")
                managementActionRow(
                    configured: model.subscriptionProviders[.zhipu] != nil,
                    removeHint: "从列表移除智谱订阅",
                    remove: onRemove
                ) {
                    Button("保存并验证") {
                        let baseURL = zhipuSiteIsCN ? Self.cnBaseURL : Self.enBaseURL
                        coordinator.saveAndVerifyZhipu(apiKey: zhipuKeyText, baseURL: baseURL)
                        zhipuKeyText = ""
                        zhipuEditing = false
                    }
                    .disabled(busy || zhipuKeyText.isEmpty)
                    .accessibilityHint("保存到 Keychain 并做本地格式校验")
                    if configured {
                        Button("取消") {
                            zhipuKeyText = ""
                            zhipuEditing = false
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                Text("此处仅做本地格式校验, 完整额度试查由 Collector 运行时承担")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                managementActionRow(
                    configured: model.subscriptionProviders[.zhipu] != nil,
                    removeHint: "从列表移除智谱订阅",
                    remove: onRemove
                ) {
                    Button("更换") { zhipuEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的智谱 API key")
                }
            }
        }
    }
}
