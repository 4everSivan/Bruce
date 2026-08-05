import MdddAppCore
import MdddOnboardingCore
import SwiftUI

/// Claude 订阅管理区: 本机 CLI / 粘贴凭证 (layout-identical extract).
struct ClaudeProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var claudePasteText: String
    var onRemove: () -> Void

    var body: some View {
        OfficialLocalProviderSettingsSection(
            id: .claude,
            available: model.claudeLocalAvailable,
            missingHint: "未检测到 Claude 登录态, 请先登录 Claude CLI",
            pasteText: $claudePasteText,
            onRemove: onRemove,
            importFromLocal: { coordinator.importClaudeFromLocal() },
            savePaste: { coordinator.importClaudeFromPaste($0) }
        )
    }
}
