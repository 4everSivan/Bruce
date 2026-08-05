import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// Codex 订阅管理区: 设备码登录 / 本机与 CC Switch 发现 / 账号状态 (layout-identical extract).
struct CodexProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var showsCodexCCImportConfirm: Bool
    var onRemove: () -> Void

    var body: some View {
        let busy = model.busySubscriptionProviders.contains(.codex)

        return managementStack {
            if let summary = model.codexAccountSummary, summary.count > 0 {
                let shown = summary.emailPrefixes.prefix(5).joined(separator: ", ")
                let suffix = summary.emailPrefixes.count > 5 ? " 等" : ""
                Text("已发现 \(summary.count) 个账号: \(shown)\(suffix)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            managementActionRow(
                configured: model.subscriptionProviders[.codex] != nil,
                removeHint: "从列表移除 Codex 订阅",
                remove: onRemove
            ) {
                Button("登录新账号") {
                    coordinator.loginCodexNewAccount()
                }
                .disabled(busy)
                .accessibilityHint("在浏览器中完成 Codex 官方设备码登录并入库")
                if coordinator.codexCLIAuthFileExists() {
                    Button("发现本机 CLI 账号") {
                        coordinator.importCodexFromLocalCLI()
                    }
                    .disabled(busy)
                    .accessibilityHint("只读发现 Codex CLI 的当前登录账号元数据, 不导入登录令牌")
                }
            }
            if coordinator.codexCCAccountsFileExists() {
                Button("发现 CC Switch 账号") {
                    showsCodexCCImportConfirm = true
                }
                .disabled(busy)
                .accessibilityHint("只读发现 CC Switch 管理的 Codex 账号元数据, 不导入登录令牌")
            }
            codexAccountStatusesList
            // 迁移结果提示 (任务 7): 阻断性错误显示可操作提示, 不泄露
            // 账号 ID/邮箱/token 或 Keychain 名称.
            if let message = model.codexMigrationStatus.userMessage {
                Label(message, systemImage: model.codexMigrationStatus.isBlocking
                    ? "xmark.octagon.fill"
                    : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(model.codexMigrationStatus.isBlocking
                        ? Color.orange
                        : Color.secondary)
                    .padding(.vertical, 2)
            }
            if let login = coordinator.codexDeviceLogin {
                deviceLoginView(
                    login,
                    openPage: { coordinator.reopenCodexLoginPage() },
                    cancel: { coordinator.cancelCodexLogin() }
                )
            }
        }
    }

    /// Codex 账号级状态列表: 区分 connected / needsReauthorization /
    /// storageBlocked; needsReauthorization 提供"在 mddd 中重新授权"操作
    /// (复用设备码登录流程). 只展示脱敏账号名与状态, 不显示 token 或完整账号 ID.
    @ViewBuilder
    private var codexAccountStatusesList: some View {
        let statuses = model.codexAccountStatuses
        if !statuses.isEmpty {
            ForEach(Array(statuses.enumerated()), id: \.element.accountID) {
                _, status in
                HStack(spacing: 6) {
                    Text(status.displayName)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    accountStatusLabel(status)
                    if status.authorizationState == .needsReauthorization {
                        Button("重新授权") {
                            coordinator.loginCodexNewAccount()
                        }
                        .font(.caption)
                        .accessibilityHint("在浏览器中重新完成该账号的 Codex 官方设备码登录")
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 账号授权状态文案 (非敏感, 不含 token/完整账号 ID).
    private func accountStatusLabel(_ status: CodexAccountStatus) -> some View {
        let (text, icon): (String, String)
        switch status.authorizationState {
        case .connected:
            if status.storageBlocked {
                text = "存储异常, 正在重试"
                icon = "exclamationmark.triangle.fill"
            } else {
                text = "已连接"
                icon = "checkmark.circle.fill"
            }
        case .needsReauthorization:
            text = "需要重新授权"
            icon = "exclamationmark.triangle.fill"
        case .revoked:
            text = "已撤销"
            icon = "xmark.circle.fill"
        }
        let isHealthy = status.authorizationState == .connected
            && !status.storageBlocked
        return Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(isHealthy ? Color.secondary : Color.orange)
            .accessibilityLabel("\(status.displayName) 状态: \(text)")
    }

    /// 设备码登录展示: 一次性验证码大字 + 打开登录页 + 轮询状态.
    /// 验证码由服务端下发, 可展示可复制; token 不进入 UI.
    private func deviceLoginView(
        _ login: DeviceLoginPresentation,
        openPage: @escaping () -> Void,
        cancel: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("一次性验证码")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(login.userCode)
                .font(.system(.title3, design: .monospaced).weight(.semibold))
                .textSelection(.enabled)
                .accessibilityLabel("一次性验证码 \(login.userCode)")
            HStack {
                Button("打开登录页", action: openPage)
                    .accessibilityHint("在浏览器中打开验证页并输入验证码")
                switch login.stage {
                case .waitingAuthorization, .finishing:
                    Button("取消", role: .cancel, action: cancel)
                        .accessibilityHint("停止等待授权")
                case .succeeded, .failed, .timedOut:
                    Button("关闭", action: cancel)
                        .accessibilityHint("收起登录状态")
                }
            }
            switch login.stage {
            case .waitingAuthorization:
                Label("等待浏览器授权…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .finishing:
                Label("正在完成登录…", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .succeeded:
                Label("登录成功", systemImage: "checkmark.circle.fill")
                    .font(.caption)
            case .failed(let reason):
                Label("登录失败: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .timedOut:
                Label("等待授权超时, 请重新点击登录", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
