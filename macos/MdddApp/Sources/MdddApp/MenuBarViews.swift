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

/// 菜单栏原生液态玻璃面板: 纵向五卡 (按 PanelViewModel 非 nil 渲染) + 底栏.
/// 无 ScrollView, 高度自适应内容; 五卡全空时展示未配置引导.
struct MenuBarDashboardView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var coordinator: OnboardingCoordinator
    @Environment(\.colorScheme) private var colorScheme

    let openSettings: @MainActor () -> Void
    let terminateApplication: @MainActor () -> Void

    var body: some View {
        let panel = model.makePanelViewModel()
        VStack(spacing: 0) {
            cardStack(panel)
            footerHairline
            actionFooter
        }
        .frame(width: 440)
        .background { panelGlassBackground }
    }

    // MARK: 面板玻璃背景

    /// macOS 26 用 Liquid Glass, 低系统退化为材料质感; 圆角 22 对齐 mockup.
    @ViewBuilder
    private var panelGlassBackground: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        }
    }

    // MARK: 卡片栈

    @ViewBuilder
    private func cardStack(_ panel: PanelViewModel) -> some View {
        let hasCards = panel.usage != nil
            || panel.subscription != nil
            || panel.hourly != nil
            || panel.github != nil
            || panel.gitlab != nil
        VStack(spacing: 10) {
            if let usage = panel.usage {
                PanelCardContainer {
                    UsageHeroCard(viewModel: usage)
                }
            }
            if let subscription = panel.subscription {
                PanelCardContainer {
                    SubscriptionCard(viewModel: subscription)
                }
            }
            if let hourly = panel.hourly {
                PanelCardContainer {
                    HourlyLineCard(viewModel: hourly)
                }
            }
            if let github = panel.github {
                PanelCardContainer {
                    HeatmapCardView(viewModel: github)
                }
            }
            if let gitlab = panel.gitlab {
                PanelCardContainer {
                    HeatmapCardView(viewModel: gitlab)
                }
            }
            if !hasCards {
                emptyPanelState
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 五卡全 nil 时的兜底: 居中玻璃卡 + 设置入口.
    private var emptyPanelState: some View {
        PanelCardContainer {
            VStack(spacing: 10) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("未配置模块, 前往设置")
                    .font(.headline)
                Button("打开设置", action: openSettings)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    // MARK: 底栏

    /// mockup 底栏顶部分隔: 白 0.5 发线, 深色下弱化为常规分隔色.
    private var footerHairline: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? Color.primary.opacity(0.15)
                    : Color.white.opacity(0.5)
            )
            .frame(height: 1)
    }

    private var actionFooter: some View {
        let refreshableModules = CollectorModule.allCases.filter {
            model.canRunCollector(for: $0)
        }
        return HStack(spacing: 8) {
            Button {
                for module in refreshableModules {
                    coordinator.refresh(module)
                }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshableModules.isEmpty)
            .accessibilityLabel("刷新全部模块")
            .accessibilityHint("使用当前授权重新采集全部已就绪模块")
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
        .panelGlassButtonStyle()
    }
}
