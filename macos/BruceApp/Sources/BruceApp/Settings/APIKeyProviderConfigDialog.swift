import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - 状态横幅 (demo statusbanner)

/// P2 配置对话框顶部状态横幅: 圆点 + 文案, ok 绿底 / warn 黄底 / 未配置灰底,
/// 配色取自 docs/design/settings-layout-demo.html 的 statusbanner token.
struct ProviderStatusBanner: View {
    let configured: Bool
    let status: SubscriptionVerificationStatus
    let lastVerifiedAt: String?

    private var resolved: (text: String, tint: Color) {
        if !configured {
            return ("未配置", .secondary)
        }
        switch status {
        case .ok:
            var text = "已配置"
            if let when = Self.formatVerified(lastVerifiedAt) {
                text += " · 上次验证 \(when)"
            }
            text += " · 验证通过"
            return (text, SettingsDemoTokens.ok)
        case .failed(let reason):
            return ("验证失败: \(reason)", SettingsDemoTokens.warn)
        case .needsRelogin:
            return ("需要重新登录", SettingsDemoTokens.warn)
        case .none:
            return ("已配置 · 未验证", .secondary)
        }
    }

    var body: some View {
        let (text, tint) = resolved
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            tint.opacity(configured ? 0.13 : 0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// ISO8601 → 「M月d日 HH:mm」; 解析失败不显示时间.
    private static func formatVerified(_ iso: String?) -> String? {
        guard let iso,
              let date = ISO8601DateFormatter().date(from: iso) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - API key 类 provider 配置对话框 (demo CFG_DIALOG 1:1)

/// demo P2 对话框结构: dg-head 纯标题 / dg-body 状态横幅 + 字段组
/// (label 在上, 输入框全宽, hint 在下) + 引导行 / dg-foot 单排分极按钮
/// (移除服务居左, 取消 + 保存并验证居右, 主按钮 accent). 供 Kimi / DeepSeek /
/// 火山引擎 / 智谱共用; 高度随内容自适应, 不写死.
struct APIKeyProviderConfigDialog: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    let id: SubscriptionProviderID
    let fields: [APIKeyFieldDescriptor]
    @Binding var values: [String: String]
    let guide: ProviderCredentialGuide
    let footnote: String?
    let extra: APIKeyProviderExtra
    var onRemove: () -> Void
    var onSave: ([String: String]) -> Void
    var onDismiss: () -> Void

    private var configured: Bool {
        model.subscriptionCredentialConfigured[id] ?? false
    }
    private var busy: Bool {
        model.busySubscriptionProviders.contains(id)
    }
    private var allFilled: Bool {
        fields.allSatisfy { !((values[$0.id] ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // dg-head
            Text("配置 \(id.displayName)")
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            // dg-body
            VStack(alignment: .leading, spacing: 12) {
                ProviderStatusBanner(
                    configured: configured,
                    status: model.subscriptionProviders[id]?.verificationStatus ?? .none,
                    lastVerifiedAt: model.subscriptionProviders[id]?.lastVerifiedAt
                )
                ForEach(fields) { field in
                    fieldGroup(field)
                }
                Text("只保存到本应用的 Keychain, 不会写入其他应用的数据库")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                extraView
                guideLine
                if let footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SubscriptionInlineErrorView(provider: id)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
            // dg-foot
            HStack(spacing: 8) {
                if configured {
                    Button("移除服务", role: .destructive) {
                        onRemove()
                        onDismiss()
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityHint("移除 \(id.displayName) 的全部凭证与配置")
                    Button("重新验证") { coordinator.reverify(id) }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .accessibilityHint("用已保存凭证重新校验 \(id.displayName)")
                }
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                }
                Button("取消") {
                    values = [:]
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("保存并验证") {
                    onSave(values)
                    values = [:]
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy || !allFilled)
                .accessibilityHint("保存到 Keychain 并做本地格式校验")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 430)
    }

    /// demo .field: label (12px semibold secondary) 在上, 全宽输入框居中.
    private func fieldGroup(_ field: APIKeyFieldDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(field.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            SecureField(field.placeholder, text: binding(for: field.id))
                .textFieldStyle(.roundedBorder)
                .disabled(busy)
                .accessibilityLabel(field.accessibilityLabel)
                .accessibilityHint("密钥只保存到本应用的 Keychain")
        }
    }

    /// demo .guide-line: 地球图标 + 灰字 + 可选 accent 外链.
    private var guideLine: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(guide.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
            if let linkURL = guide.linkURL, let linkTitle = guide.linkTitle {
                Link(linkTitle, destination: linkURL)
                    .font(.system(size: 11.5))
            }
        }
        .accessibilityElement(children: .combine)
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

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }
}
