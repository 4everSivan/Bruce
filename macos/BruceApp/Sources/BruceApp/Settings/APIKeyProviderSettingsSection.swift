import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// API key 类订阅 provider 的通用管理区 (Kimi / DeepSeek / 火山引擎 / 智谱).
/// 收敛原本几乎逐行同构的四个 section: 凭证输入框数量与文案走字段描述,
/// 站点选择器 / CC Switch 导入走 `APIKeyProviderExtra` 封闭变体集, 其余
/// (编辑态判定, 保存并验证, 移除, 重新验证, 引导, 就地错误) 统一.
struct APIKeyProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    let id: SubscriptionProviderID
    let fields: [APIKeyFieldDescriptor]
    @Binding var values: [String: String]
    @Binding var isEditing: Bool
    let guide: ProviderCredentialGuide
    let footnote: String?
    let extra: APIKeyProviderExtra
    var onRemove: () -> Void
    /// 提交: 把当前 `values` 交给上层, 由 SettingsView 组装成具体保存调用.
    var onSave: ([String: String]) -> Void

    private var configured: Bool {
        model.subscriptionCredentialConfigured[id] ?? false
    }
    private var busy: Bool {
        model.busySubscriptionProviders.contains(id)
    }
    private var needsRelogin: Bool {
        model.subscriptionProviders[id]?.verificationStatus == .needsRelogin
    }
    /// 编辑态: 未配置, 或用户点"更换", 或验证过期需要重填.
    private var showsFields: Bool {
        isEditing || !configured || needsRelogin
    }
    private var allFilled: Bool {
        fields.allSatisfy { !((values[$0.id] ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty) }
    }

    var body: some View {
        managementStack {
            if showsFields {
                ForEach(fields) { field in
                    SecureField(field.placeholder, text: binding(for: field.id))
                        .textFieldStyle(.roundedBorder)
                        .disabled(busy)
                        .accessibilityLabel(field.accessibilityLabel)
                        .accessibilityHint("密钥只保存到本应用的 Keychain")
                }
                extraView
                actionRow {
                    Button("保存并验证") {
                        onSave(values)
                        values = [:]
                        isEditing = false
                    }
                    .disabled(busy || !allFilled)
                    .accessibilityHint("保存到 Keychain 并做本地格式校验")
                    if configured {
                        Button("取消") {
                            values = [:]
                            isEditing = false
                        }
                        .disabled(busy)
                    }
                    if busy {
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                actionRow {
                    Button("更换") { isEditing = true }
                        .disabled(busy)
                        .accessibilityHint("输入新的 \(id.displayName) 凭证")
                    Button("重新验证") { coordinator.reverify(id) }
                        .disabled(busy)
                        .accessibilityHint("用已保存凭证重新校验 \(id.displayName)")
                }
            }
            ProviderCredentialGuide.view(guide)
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SubscriptionInlineErrorView(provider: id)
        }
    }

    // 复用全局函数而非 ViewModifier, 保住 14pt 缩进与移除居右.
    private func actionRow<Primary: View>(
        @ViewBuilder primary: () -> Primary
    ) -> some View {
        managementActionRow(
            configured: model.subscriptionProviders[id] != nil,
            removeHint: "从列表移除 \(id.displayName) 订阅",
            remove: { onRemove(); isEditing = false },
            primary: primary
        )
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    @ViewBuilder
    private var extraView: some View {
        switch extra {
        case .none:
            EmptyView()
        case .sitePicker(let isCN):
            Picker("站点", selection: isCN) {
                Text("国内站 (open.bigmodel.cn)").tag(true)
                Text("国外站 (api.z.ai)").tag(false)
            }
            .pickerStyle(.radioGroup)
            .disabled(busy)
            .accessibilityLabel("\(id.displayName)站点")
        case .ccSwitchImport(let shows):
            if coordinator.ccSwitchDatabaseExists() {
                Button("从 CC Switch 导入") { shows.wrappedValue = true }
                    .disabled(busy)
                    .accessibilityHint("只读导入 CC Switch 中 \(id.displayName) 的 AK/SK")
            }
        }
    }
}
