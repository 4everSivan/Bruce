import AppKit
import MdddAppCore
import MdddOnboardingCore
import SwiftUI

struct MenuBarLabelView: View {
    @ObservedObject var model: AppModel

    private var summary: MenuBarSummary {
        MenuBarSummaryBuilder().build(
            agentArtifact: model.moduleArtifacts[.agentUsage],
            moduleStatuses: model.moduleStatuses
        )
    }

    var body: some View {
        let formatter = MenuBarMetricFormatter()
        HStack(spacing: 5) {
            Image(systemName: summary.overallStatus.symbolName)
            ForEach(model.menuBarMetrics) { metric in
                Text(formatter.string(for: metric, summary: summary))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(formatter: formatter))
    }

    private func accessibilitySummary(
        formatter: MenuBarMetricFormatter
    ) -> String {
        let metrics = model.menuBarMetrics.map {
            "\($0.title) \(formatter.string(for: $0, summary: summary))"
        }
        return (["mddd", summary.overallStatus.title] + metrics)
            .joined(separator: ", ")
    }
}

struct MenuBarDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator

    let openSettings: @MainActor () -> Void
    let terminateApplication: @MainActor () -> Void

    private let modules: [DashboardModule] = [
        .agentUsage,
        .github,
        .gitlab,
    ]

    private var selectedModule: DashboardModule {
        modules.contains(model.selectedModule)
            ? model.selectedModule
            : .agentUsage
    }

    var body: some View {
        HStack(spacing: 0) {
            moduleRail
            Divider()
            VStack(spacing: 0) {
                moduleHeader
                Divider()
                moduleContent
                Divider()
                actionFooter
            }
        }
        .frame(width: 440, height: 500)
        .background {
            if GlassTheme.usesGlass(model.theme) {
                WidgetGlassBacking(theme: model.theme)
            }
        }
    }

    private var moduleRail: some View {
        VStack(spacing: 10) {
            ForEach(modules) { module in
                Button {
                    model.selectedModule = module
                } label: {
                    Image(systemName: module.systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(
                                    selectedModule == module
                                        ? Color.accentColor
                                        : Color.clear
                                )
                        }
                        .foregroundStyle(
                            selectedModule == module
                                ? Color.white
                                : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .help(module.title)
                .accessibilityLabel(module.title)
                .accessibilityValue(
                    model.status(for: module).state.title
                )
            }
            Spacer()
        }
        .padding(.vertical, 14)
        .frame(width: 52)
    }

    private var moduleHeader: some View {
        let status = model.status(for: selectedModule)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedModule.title)
                    .font(.headline)
                Text(lastUpdatedText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(status.state.title, systemImage: status.state.symbolName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .glassStatusPill(theme: model.theme)
                .accessibilityLabel("模块状态: \(status.state.title)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var moduleContent: some View {
        let module = selectedModule
        let status = model.status(for: module)
        let hasArtifact = model.moduleArtifacts[module] != nil
        if let collectorModule = module.collectorModule,
           hasArtifact || model.canRunCollector(for: collectorModule) {
            WidgetHostView(
                module: collectorModule,
                artifact: model.moduleArtifacts[module],
                state: WidgetDisplayState(moduleState: status.state),
                theme: model.theme
            )
            .background {
                WidgetGlassBacking(theme: model.theme)
            }
        } else {
            WidgetPlaceholder(
                module: module,
                status: status,
                theme: model.theme
            )
            .padding(12)
        }
    }

    private var actionFooter: some View {
        let module = selectedModule
        let canRefresh = module.collectorModule.map {
            model.canRunCollector(for: $0)
        } ?? false
        return HStack(spacing: 8) {
            Button {
                if let collectorModule = module.collectorModule {
                    coordinator.refresh(collectorModule)
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(!canRefresh)
            .accessibilityHint("使用当前授权重新采集\(module.title)")
            Spacer()
            Button(action: openSettings) {
                Label("设置", systemImage: "gearshape")
            }
            Button(action: terminateApplication) {
                Label("退出", systemImage: "power")
            }
        }
        .labelStyle(.iconOnly)
        .help("刷新、设置或退出 mddd")
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassButtonStyle(theme: model.theme)
    }

    private var lastUpdatedText: String {
        guard let artifact = model.moduleArtifacts[selectedModule],
              case .object(let object) = artifact,
              case .string(let generatedAt)? = object["generatedAt"],
              let date = ISO8601DateFormatter().date(from: generatedAt) else {
            return "尚无数据"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
