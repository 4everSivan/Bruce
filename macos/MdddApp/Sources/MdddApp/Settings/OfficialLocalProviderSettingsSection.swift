import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// Claude / Grok 共用管理组 (Phase 4): 支持手动粘贴导入与从本机 CLI 导入.
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

    var body: some View {
        let needsRelogin = model.subscriptionProviders[id]?
            .verificationStatus == .needsRelogin
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
            Text("粘贴 \(id.displayName) 访问令牌或凭证 JSON")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteText)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 48, maxHeight: 80)
                .accessibilityLabel("\(id.displayName) 凭证粘贴框")
            // 移除按钮基于"已添加"(配置条目存在), 而非凭证是否有效;
            // 过期/无效时用户仍需能删除订阅回到"未添加".
            managementActionRow(
                configured: model.subscriptionProviders[id] != nil,
                removeHint: "从列表移除 \(id.displayName) 订阅",
                remove: onRemove
            ) {
                Button("验证并保存") {
                    savePaste(pasteText)
                    pasteText = ""
                }
                .disabled(pasteText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityHint("校验后保存到本应用的 Keychain")
            }
            Button("重新检测") {
                coordinator.refreshOfficialLocalAvailability()
            }
            .accessibilityHint("重新读取本机 \(id.displayName) CLI 登录态")
        }
    }
}
