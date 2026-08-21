import BruceAppCore
import BruceOnboardingCore
import SwiftUI

/// Grok 订阅管理区: 本机 CLI / 粘贴凭证 (layout-identical extract).
struct GrokProviderSettingsSection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    @Binding var grokPasteText: String
    var onRemove: () -> Void

    var body: some View {
        OfficialLocalProviderSettingsSection(
            id: .grok,
            available: model.grokLocalAvailable,
            missingHint: "未检测到 Grok 登录态, 请先通过 Grok CLI 登录 (~/.grok/auth.json)",
            pasteText: $grokPasteText,
            onRemove: onRemove,
            importFromLocal: { coordinator.importGrokFromLocal() },
            savePaste: { coordinator.importGrokFromPaste($0) }
        )
    }
}
