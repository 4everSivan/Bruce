import AppKit
import MdddAppCore
import MdddOnboardingCore
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(DashboardModule.allCases, selection: $model.selectedModule) {
                module in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title)
                        if module != .settings {
                            Text(model.status(for: module).state.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: module.systemImage)
                }
                .tag(module)
                .accessibilityLabel(
                    module == .settings
                        ? module.title
                        : "\(module.title), \(model.status(for: module).state.title)"
                )
                .accessibilityHint("选择后打开\(module.title)")
            }
            .navigationTitle("mddd")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            ModuleDetailView(module: model.selectedModule)
        }
        .frame(minWidth: 760, minHeight: 540)
    }
}

private struct ModuleDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    let module: DashboardModule

    var body: some View {
        let status = model.status(for: module)
        let hasArtifact = model.moduleArtifacts[module] != nil
        let isReady = if let collectorModule = module.collectorModule {
            model.canRunCollector(for: collectorModule)
        } else {
            true
        }
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(module.title)
                    .font(.largeTitle.weight(.semibold))
                Spacer()
                Label(status.state.title, systemImage: status.state.symbolName)
                    .foregroundStyle(.secondary)
                    .glassStatusPill(theme: model.theme)
                    .accessibilityLabel("模块状态: \(status.state.title)")
                if let collectorModule = module.collectorModule {
                    Button {
                        coordinator.refresh(collectorModule)
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!isReady)
                    .accessibilityLabel("刷新\(module.title)")
                    .accessibilityHint(
                        status.state == .refreshing
                            ? "当前刷新完成后再执行一次"
                            : "使用当前授权重新采集此模块"
                    )
                }
            }
            Group {
                if module == .settings {
                    SettingsView()
                } else if let collectorModule = module.collectorModule,
                          hasArtifact || isReady {
                    WidgetHostView(
                        module: collectorModule,
                        artifact: model.moduleArtifacts[module],
                        state: WidgetDisplayState(
                            moduleState: status.state
                        ),
                        theme: model.theme
                    )
                    .background {
                        WidgetGlassBacking(theme: model.theme)
                    }
                } else {
                    WidgetPlaceholder(
                        module: module, status: status, theme: model.theme
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .navigationTitle(module.title)
    }
}

struct WidgetPlaceholder: View {
    let module: DashboardModule
    let status: ModuleStatus
    var theme: AppTheme = .classic

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: module.systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("WidgetHost 将在此加载现有视觉")
                .font(.headline)
            if let guidance = status.detail {
                Text(guidance)
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            } else {
                Text(status.state.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassCardBackground(theme: theme)
        .accessibilityElement(children: .combine)
    }
}

struct MainWindowRegistration: NSViewRepresentable {    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.identifier = MainWindow.identifier
            window.isReleasedWhenClosed = false
        }
    }
}
