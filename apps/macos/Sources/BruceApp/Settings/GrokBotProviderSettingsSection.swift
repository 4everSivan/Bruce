import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Grok Bot 订阅管理区 (T39, design/02 规则 18): 连接 / 重新连接客户端当前登录账号.
/// 额度读自 Grok Bot 本机缓存的周用量, 不读取登录令牌、不触碰钥匙串、不联网查询.
struct GrokBotProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    var onRemove: () -> Void

    private var configured: Bool {
        model.subscriptionCredentialConfigured[.grokBot] ?? false
    }
    private var busy: Bool {
        model.busySubscriptionProviders.contains(.grokBot)
    }

    var body: some View {
        managementStack {
            Text(configured
                 ? "已连接 Grok Bot 账号。Grok Bot 切换到其他账号时停止展示, 需在此重新连接"
                 : "连接 Grok Bot 当前登录的账号, 读取其本机缓存的周用量; 不读取登录令牌, 不联网查询")
                .font(.caption)
                .foregroundStyle(.secondary)
            managementActionRow(
                configured: model.subscriptionProviders[.grokBot] != nil,
                removeHint: "从列表移除 Grok Bot 订阅并清除已连接账号",
                remove: onRemove
            ) {
                Button(configured ? "重新连接" : "连接当前账号") {
                    coordinator.connectGrokBot()
                }
                .disabled(busy)
                .accessibilityHint("读取 Grok Bot 当前登录的账号并绑定到 Bruce")
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
            SubscriptionInlineErrorView(provider: .grokBot)
        }
    }
}
