import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Claude 订阅管理区: 本机 CLI / 粘贴凭证 (layout-identical extract).
struct ClaudeProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var claudePasteText: String
    @Binding var claudeEditing: Bool
    var onRemove: () -> Void

    var body: some View {
        OfficialLocalProviderSettingsSection(
            id: .claude,
            available: model.claudeLocalAvailable,
            missingHint: "未检测到 Claude 登录态, 请先登录 Claude CLI",
            pasteText: $claudePasteText,
            onRemove: onRemove,
            importFromLocal: { coordinator.importClaudeFromLocal() },
            savePaste: { coordinator.importClaudeFromPaste($0) },
            pasteHint: nil,
            showsLocalRedetect: true,
            isEditing: $claudeEditing
        )
    }
}
