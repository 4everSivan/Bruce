import BruceOnboardingCore
import SwiftUI

/// 外部 CLI Keychain 来源的显式开关管理, 不在打开或切换时读取凭证.
struct ExternalKeychainSourceManagerView: View {
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("外部 CLI 来源")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SettingsDemoTokens.text)
                    Text("仅在启用后读取对应 CLI 的本机登录态")
                        .font(.system(size: 11.5))
                        .foregroundStyle(SettingsDemoTokens.text2)
                }
                Spacer(minLength: 12)
                Button("完成") {
                    dismiss()
                }
                .fluentButton(.primary)
            }

            FluentCard {
                FluentRow(
                    "Claude CLI",
                    sub: "读取 Claude Code 本机登录态",
                    divided: false
                ) {
                    Toggle(
                        "Claude CLI",
                        isOn: Binding(
                            get: {
                                coordinator.externalKeychainSources.contains(.claudeCLI)
                            },
                            set: {
                                coordinator.setExternalKeychainSource(.claudeCLI, enabled: $0)
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                FluentRow(
                    "Grok CLI",
                    sub: "读取 Grok CLI 本机登录态",
                    divided: true
                ) {
                    Toggle(
                        "Grok CLI",
                        isOn: Binding(
                            get: {
                                coordinator.externalKeychainSources.contains(.grokCLI)
                            },
                            set: {
                                coordinator.setExternalKeychainSource(.grokCLI, enabled: $0)
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }
        }
        .padding(20)
        .frame(width: 430)
        .background(SettingsDemoTokens.window)
    }
}
