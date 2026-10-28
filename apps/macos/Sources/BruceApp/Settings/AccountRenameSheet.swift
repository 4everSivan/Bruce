import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - AccountRenameRequest

/// 账号重命名请求: 只携带非敏感展示信息与同 Provider 现有名称,
/// 供弹窗做即时重名校验. 不含任何凭证.
struct AccountRenameRequest: Identifiable {
    let provider: SubscriptionProviderID
    let accountID: String
    let displayName: String
    /// 同 Provider 其他账号的完整显示名 (含当前账号自身, 校验时按 displayName 排除).
    let existingDisplayNames: [String]

    var id: String { "\(provider.rawValue):\(accountID)" }

    /// StepFun 站点前缀从现有名称判定; 其他 Provider 忽略.
    var stepFunGlobal: Bool {
        provider == .stepfun
            && ProviderAccountNaming.isStepFunGlobalDisplayName(displayName)
    }
}

// MARK: - AccountRenameSheet

/// 账号重命名弹窗 (T18): 用户只编辑标签, Provider 前缀只读.
/// 保存时做长度/控制字符/重名校验; 留空或「恢复默认」回到「账号 N」默认名.
struct AccountRenameSheet: View {
    let request: AccountRenameRequest

    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var errorMessage: String?

    init(request: AccountRenameRequest) {
        self.request = request
        _label = State(
            initialValue: ProviderAccountNaming.label(
                from: request.displayName,
                provider: request.provider
            )
        )
    }

    private var prefix: String {
        ProviderAccountNaming.displayPrefix(
            for: request.provider,
            stepFunGlobal: request.stepFunGlobal
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名账号")
                .font(.system(size: 15, weight: .semibold))
            Text("只修改显示名称, 不影响凭证、账号标识与额度查询; \(prefix) 前缀由系统维护")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(prefix + " ·")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("账号名称", text: $label)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("账号名称")
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("恢复默认") {
                    rename(to: "")
                }
                .accessibilityHint("恢复为系统默认名称")
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// 留空保存 = 恢复默认名; 非空则校验长度/字符/重名后提交.
    private func save() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rename(to: "")
            return
        }
        do {
            let normalized = try ProviderAccountNaming.validateLabel(trimmed)
            let candidate = ProviderAccountNaming.compose(
                provider: request.provider,
                label: normalized,
                stepFunGlobal: request.stepFunGlobal
            )
            guard ProviderAccountNaming.fitsCollectorLimit(candidate) else {
                throw ProviderAccountNamingError.tooLong
            }
            guard !ProviderAccountNaming.isDuplicate(
                candidate,
                provider: request.provider,
                existingDisplayNames: request.existingDisplayNames,
                excludingDisplayName: request.displayName
            ) else {
                throw ProviderAccountNamingError.duplicate
            }
            errorMessage = nil
            rename(to: normalized)
        } catch let error as ProviderAccountNamingError {
            errorMessage = error.message
        } catch {
            errorMessage = "账号名称无效"
        }
    }

    private func rename(to label: String) {
        coordinator.renameAccount(
            accountID: request.accountID,
            from: request.provider,
            label: label
        )
        dismiss()
    }
}
