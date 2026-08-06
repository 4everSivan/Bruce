import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// Kimi 订阅管理区: 本机导入 / 粘贴令牌 / 验证 (layout-identical extract).
struct KimiProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var kimiPasteText: String
    @Binding var kimiEditing: Bool
    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.kimi] ?? false
        let needsRelogin = model.subscriptionProviders[.kimi]?
            .verificationStatus == .needsRelogin
        let localFileExists = coordinator.kimiLocalTokensFileExists()
        // needsRelogin 时必须显示粘贴入口 (无论本机文件是否存在),
        // 否则用户无法重新登录 (重新导入仍是旧 token).
        let showPaste = kimiEditing || !configured || needsRelogin

        return managementStack {
            if localFileExists || (configured && !showPaste) {
                managementActionRow(
                    configured: model.subscriptionProviders[.kimi] != nil,
                    removeHint: "从列表移除 Kimi 订阅",
                    remove: {
                        onRemove()
                        kimiEditing = false
                    }
                ) {
                    if localFileExists {
                        Button("从本机导入") {
                            coordinator.importKimiFromLocalFile()
                        }
                        .accessibilityHint("读取 kimi-dashboard 保存的本机浏览器令牌")
                    }
                    if needsRelogin {
                        Button("重新粘贴令牌") { kimiEditing = true }
                            .accessibilityHint("打开粘贴框, 重新输入 Kimi 访问令牌")
                    }
                }
            }
            if showPaste {
                Text("打开 kimi.com 并登录 → 开发者工具 → Application → 复制 access_token 与 refresh_token, 粘贴整段 JSON 或两段 token")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $kimiPasteText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 96)
                    .accessibilityLabel("Kimi 令牌粘贴框")
                managementActionRow(
                    configured: model.subscriptionProviders[.kimi] != nil,
                    removeHint: "从列表移除 Kimi 订阅",
                    remove: {
                        onRemove()
                        kimiEditing = false
                    }
                ) {
                    Button("验证并保存") {
                        coordinator.importKimiFromPaste(kimiPasteText)
                        kimiPasteText = ""
                        kimiEditing = false
                    }
                    .disabled(kimiPasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("校验后保存到本应用的 Keychain")
                    if configured {
                        Button("取消") {
                            kimiPasteText = ""
                            kimiEditing = false
                        }
                    }
                }
            }
        }
    }
}
