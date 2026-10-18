import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Claude 订阅管理区 (C059, 对照 cc-switch 零配置范式):
/// 启用后自动只读跟随本机 CLI 登录态 (钥匙串静默 + 凭证文件), 无需手动导入;
/// 粘贴凭证收进「高级」次级入口, 仅作多账号/兜底路径。
struct ClaudeProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var claudePasteText: String
    @Binding var claudeEditing: Bool
    var onRemove: () -> Void

    private var busy: Bool {
        model.busySubscriptionProviders.contains(.claude)
    }

    private var available: Bool {
        model.claudeLocalAvailable
    }

    private var needsRelogin: Bool {
        model.subscriptionProviders[.claude]?.verificationStatus == .needsRelogin
    }

    private var storedAccountCount: Int {
        model.providerAccountSummaries[.claude]?.count ?? 0
    }

    /// 登录态状态行文案: 就绪 / 待刷新 (运行一次 CLI 即恢复) / 过期 / 未检测到。
    private var statusText: String {
        if needsRelogin {
            return "登录已过期, 运行一次 Claude CLI 可自动恢复, Bruce 会重新跟随"
        }
        if available {
            return storedAccountCount > 0
                ? "已存 \(storedAccountCount) 个账号凭证, 正在使用"
                : "已启用, 自动跟随本机 Claude CLI 登录态"
        }
        return "未检测到本机 Claude 登录态, 登录 Claude CLI 后自动跟随"
    }

    private var statusIcon: String {
        if needsRelogin {
            return "exclamationmark.triangle.fill"
        }
        if available {
            return "checkmark.circle.fill"
        }
        return "questionmark.circle"
    }

    private var statusColor: Color {
        if needsRelogin {
            return .orange
        }
        if available {
            return .secondary
        }
        return .secondary
    }

    var body: some View {
        managementStack {
            Label(statusText, systemImage: statusIcon)
                .font(.caption)
                .foregroundStyle(statusColor)
                .accessibilityLabel("Claude 本机登录态: \(statusText)")

            managementActionRow(
                configured: model.subscriptionProviders[.claude] != nil,
                removeHint: "从列表移除 Claude 订阅",
                remove: {
                    onRemove()
                    claudeEditing = false
                }
            ) {
                if !available {
                    Button("立即检测") {
                        coordinator.refreshOfficialLocalAvailability()
                    }
                    .disabled(busy)
                    .accessibilityHint("重新探测本机 Claude CLI 登录态")
                }
                Button("重新验证") {
                    coordinator.reverify(.claude)
                }
                .disabled(busy)
                .accessibilityHint("用当前跟随的登录态重新验证 Claude 订阅")
                if busy {
                    ProgressView().controlSize(.small)
                }
            }

            advancedPasteGroup

            ProviderCredentialGuide.view(ProviderCredentialGuide(
                summary: "在终端登录 Claude CLI 即可: Bruce 只读跟随本机登录态"
                    + " (钥匙串静默读取 + 凭证文件), 不回写、不弹窗, 无需手动配置。",
                linkTitle: nil,
                linkURL: nil
            ))

            SubscriptionInlineErrorView(provider: .claude)
        }
    }

    /// 高级入口: 粘贴凭证 (多账号 / 兜底路径)。needsRelogin 时强制展开,
    /// 与旧表单的兜底语义一致 (C059 前的行为)。
    private var advancedPasteGroup: some View {
        let expanded = Binding(
            get: { claudeEditing || needsRelogin },
            set: { claudeEditing = $0 }
        )
        return DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("粘贴 Claude 访问令牌或凭证 JSON (通常无需手动粘贴)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $claudePasteText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 48, maxHeight: 80)
                    .accessibilityLabel("Claude 凭证粘贴框")
                HStack {
                    Button("验证并保存") {
                        coordinator.importClaudeFromPaste(claudePasteText)
                        claudePasteText = ""
                        claudeEditing = false
                    }
                    .disabled(
                        claudePasteText
                            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityHint("校验后保存到本应用的凭证库")
                    Button("取消") {
                        claudePasteText = ""
                        claudeEditing = false
                    }
                }
            }
            .padding(.top, 2)
        } label: {
            Text("高级: 粘贴凭证 (多账号)")
                .font(.caption)
        }
    }
}
