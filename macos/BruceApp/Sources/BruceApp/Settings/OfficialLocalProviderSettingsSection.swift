import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Claude / Grok / OpenCode GO 共用管理组 (Phase 4): 支持手动粘贴导入与从本机 CLI 导入.
/// 应用持有凭证存 Keychain; 本机登录态检测作为"从本机导入"按钮的显隐条件.
struct OfficialLocalProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    let id: SubscriptionProviderID
    let available: Bool
    let missingHint: String
    @Binding var pasteText: String
    var onRemove: () -> Void
    var importFromLocal: () -> Void
    var savePaste: (String) -> Void
    /// 粘贴框上方的引导文案; nil 时回退默认提示.
    var pasteHint: String?
    /// 是否显示"重新检测"本机登录态按钮 (Claude / Grok = true, OpenCode GO = false).
    var showsLocalRedetect: Bool
    /// 编辑态: 默认 `editing || !configured`, needsRelogin 时强制展开粘贴入口.
    @Binding var isEditing: Bool

    private var configured: Bool {
        model.subscriptionCredentialConfigured[id] ?? false
    }
    private var busy: Bool {
        model.busySubscriptionProviders.contains(id)
    }
    private var needsRelogin: Bool {
        model.subscriptionProviders[id]?.verificationStatus == .needsRelogin
    }
    private var showPaste: Bool {
        isEditing || !configured || needsRelogin
    }

    var body: some View {
        return managementStack {
            if available {
                Button("从本机导入") {
                    importFromLocal()
                }
                .accessibilityHint("读取本机 \(id.displayName) CLI 登录凭证")
            } else if !needsRelogin {
                Text(missingHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if needsRelogin {
                Text("登录已过期, 请重新粘贴 \(id.displayName) 凭证或重新登录 CLI")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if showPaste {
                Text(pasteHint
                     ?? "粘贴 \(id.displayName) 访问令牌或凭证 JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $pasteText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 48, maxHeight: 80)
                    .accessibilityLabel("\(id.displayName) 凭证粘贴框")
                managementActionRow(
                    configured: model.subscriptionProviders[id] != nil,
                    removeHint: "从列表移除 \(id.displayName) 订阅",
                    remove: {
                        onRemove()
                        isEditing = false
                    }
                ) {
                    Button("验证并保存") {
                        savePaste(pasteText)
                        pasteText = ""
                        isEditing = false
                    }
                    .disabled(pasteText
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("校验后保存到本应用的 Keychain")
                    if configured {
                        Button("取消") {
                            pasteText = ""
                            isEditing = false
                        }
                    }
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                managementActionRow(
                    configured: model.subscriptionProviders[id] != nil,
                    removeHint: "从列表移除 \(id.displayName) 订阅",
                    remove: { onRemove(); isEditing = false }
                ) {
                    Button("更换") { isEditing = true }
                        .accessibilityHint("重新粘贴 \(id.displayName) 凭证")
                    Button("重新验证") { coordinator.reverify(id) }
                        .accessibilityHint("用已保存凭证重新验证 \(id.displayName) 订阅")
                }
            }
            if showsLocalRedetect {
                Button("重新检测") {
                    coordinator.refreshOfficialLocalAvailability()
                }
                .accessibilityHint("重新读取本机 \(id.displayName) CLI 登录态")
            }
            SubscriptionInlineErrorView(provider: id)
        }
    }
}
