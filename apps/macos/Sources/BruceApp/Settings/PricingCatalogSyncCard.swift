import AppKit
import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// MARK: - 维护页「模型价格表」卡 (09-模型价格表远端同步 §4.2 R5, 布局 1)

private enum PricingCardTokens {
    static let okTick = Color(hex: "5EC273")
}

/// 三行 (自动同步 / 当前价格表 / 同步价格表) + 底部状态区 (pricing-sync-stage).
struct PricingCatalogSyncCard: View {
    @EnvironmentObject var pricingSync: PricingCatalogSyncService

    var body: some View {
        TimelineView(.everyMinute) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        FluentCard {
            // 行 1: 自动同步价格表
            FluentRow(PricingCopy.autoSyncTitle, sub: PricingCopy.autoSyncSubtitle) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { pricingSync.autoSyncEnabled },
                        set: { pricingSync.setAutoSyncEnabled($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
            }

            // 行 2: 当前价格表
            FluentRow(
                PricingCopy.currentCatalogTitle,
                sub: PricingCatalogPresentation.currentCatalogSubtitle(
                    source: pricingSync.currentSource,
                    modelCount: pricingSync.currentModelCount
                ),
                divided: true
            ) {
                HStack(spacing: 8) {
                    Text(pricingSync.currentUpdatedAt)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(SettingsDemoTokens.text2)
                    if pricingSync.currentSource == .synced {
                        Button(PricingCopy.restoreButton) {
                            pricingSync.restoreBuiltin()
                        }
                        .fluentButton()
                        .disabled(!PricingCatalogPresentation.isRestoreButtonEnabled(for: pricingSync.stage))
                    }
                }
            }

            // 行 3: 同步价格表
            FluentRow(
                PricingCopy.syncCatalogTitle,
                sub: PricingCatalogPresentation.lastSyncSubtitle(
                    pricingSync.lastSyncAt,
                    now: now,
                    calendar: .current
                ),
                divided: true
            ) {
                Button(PricingCopy.syncButton) {
                    pricingSync.syncNow()
                }
                .fluentButton()
                .disabled(!PricingCatalogPresentation.isSyncButtonEnabled(for: pricingSync.stage))
            }

            // 底部状态区 (pricing-sync-stage)
            stage()
        }
    }

    @ViewBuilder
    private func stage() -> some View {
        let display = PricingCatalogPresentation.stageDisplay(for: pricingSync.stage)
        if display != .hidden {
            stageBody(display)
                .font(.system(size: 12))
                .foregroundStyle(SettingsDemoTokens.text2)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) {
                    SettingsDemoTokens.separator.frame(height: 1)
                }
        }
    }

    @ViewBuilder
    private func stageBody(_ display: PricingStageDisplay) -> some View {
        switch display {
        case .hidden:
            EmptyView()
        case .spinner(let text):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(text)
            }
        case .confirmation(let text):
            HStack(spacing: 8) {
                Text("✓")
                    .fontWeight(.semibold)
                    .foregroundStyle(PricingCardTokens.okTick)
                Text(text)
            }
        case .failure(let title, let detail, _):
            HStack(spacing: 8) {
                Text(title)
                    .foregroundStyle(SettingsDemoTokens.warn)
                Text(detail)
                Button(PricingCopy.retry) {
                    pricingSync.syncNow()
                }
                .buttonStyle(.plain)
                .foregroundStyle(SettingsDemoTokens.accent)
                .underline()
            }
        }
    }
}
