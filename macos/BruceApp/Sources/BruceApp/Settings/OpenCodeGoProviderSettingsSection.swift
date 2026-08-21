import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// OpenCode GO 订阅管理区: 粘贴 console OAuth 凭证 (多账号, 仿 Kimi).
struct OpenCodeGoProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var opencodeGoPasteText: String
    @Binding var opencodeGoEditing: Bool
    var onRemove: () -> Void

    var body: some View {
        let configured = model.subscriptionCredentialConfigured[.opencodeGo] ?? false
        let needsRelogin = model.subscriptionProviders[.opencodeGo]?
            .verificationStatus == .needsRelogin
        // needsRelogin 时必须显示粘贴入口, 否则用户无法重新登录
        let showPaste = opencodeGoEditing || !configured || needsRelogin

        return managementStack {
            if !showPaste {
                managementActionRow(
                    configured: model.subscriptionProviders[.opencodeGo] != nil,
                    removeHint: "从列表移除 OpenCode GO 订阅",
                    remove: {
                        onRemove()
                        opencodeGoEditing = false
                    }
                ) {
                    Button("更换") { opencodeGoEditing = true }
                        .accessibilityHint("重新粘贴 OpenCode GO 访问令牌")
                    Button("重新验证") { coordinator.reverifyOpenCodeGo() }
                        .accessibilityHint("用已保存凭证重新验证 OpenCode GO 订阅")
                }
            }
            if showPaste {
                Text("打开 opencode.ai → 登录 → 开发者工具 → Application → Cookies → 复制 auth 值 (Fe26.2**...) 与 workspace URL 中的 wrk_ ID, 粘贴 JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $opencodeGoPasteText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 56, maxHeight: 96)
                    .accessibilityLabel("OpenCode GO 会话凭证粘贴框")
                managementActionRow(
                    configured: model.subscriptionProviders[.opencodeGo] != nil,
                    removeHint: "从列表移除 OpenCode GO 订阅",
                    remove: {
                        onRemove()
                        opencodeGoEditing = false
                    }
                ) {
                    Button("验证并保存") {
                        coordinator.importOpenCodeGoFromPaste(opencodeGoPasteText)
                        opencodeGoPasteText = ""
                        opencodeGoEditing = false
                    }
                    .disabled(opencodeGoPasteText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("校验后保存到本应用的 Keychain")
                    if configured {
                        Button("取消") {
                            opencodeGoPasteText = ""
                            opencodeGoEditing = false
                        }
                    }
                }
            }
        }
    }
}
