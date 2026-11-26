import BruceAppCore
import BruceOnboardingCore
import SwiftUI

// 订阅卡空状态 (C157): 未配置 / 已配置但无数据两态.
// 只排内容, 卡片容器 (PanelCardContainer) 由面板装配层统一提供, 与其余卡片同构.
// 不读取凭证或 artifact, 全部展示值来自 SubscriptionEmptyStateViewModel.

/// Nothing 主题本文件级颜色 token: 数值与 SubscriptionCard.swift 同源 (定稿原型).
private enum EmptyNothingTokens {
    static func display(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#FFFFFF") : Color(hex: "#000000")
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#999999") : Color(hex: "#666666")
    }

    static func disabled(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#666666") : Color(hex: "#999999")
    }

    static func borderVisible(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: "#333333") : Color(hex: "#CCCCCC")
    }
}

struct SubscriptionEmptyCard: View {
    let viewModel: SubscriptionEmptyStateViewModel
    var isCollapsed: Bool = false
    var onToggleCollapse: () -> Void = {}
    var onAction: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.motionSuppressed) private var motionSuppressed
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CollapsibleCardHeader(
                title: "订阅用量",
                isCollapsed: isCollapsed,
                onToggle: onToggleCollapse,
                cardID: .subscription
            ) {
                statusLabel
            } mini: {
                statusLabel
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            ZStack(alignment: .top) {
                if !isCollapsed {
                    expandedContent
                        .readingNaturalHeight(into: $expandedHeight)
                        .transition(.opacity.animation(motionSuppressed ? nil : .easeOut(duration: 0.22)))
                }
            }
            .frame(
                height: isCollapsed
                    ? DashboardSwapHeight.collapsed
                    : DashboardSwapHeight.target(measured: expandedHeight),
                alignment: .top
            )
            .clipped()
        }
        .clipped()
    }

    // MARK: - 标题行状态词

    private var statusLabel: some View {
        Text(viewModel.statusText)
            .font(NothingFont.mono(9))
            .foregroundStyle(AnyShapeStyle(EmptyNothingTokens.disabled(colorScheme)))
    }

    // MARK: - 展开态

    private var expandedContent: some View {
        VStack(spacing: 7) {
            emptyMessage
            Button(action: onAction) {
                Text(viewModel.actionTitle)
                    .font(NothingFont.mono(10))
                    .tracking(0.6)
            }
            .panelGlassButtonStyle()
            .accessibilityLabel(viewModel.actionTitle)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    /// 图标 + 标题 + 说明合并为一个无障碍元素, 按钮保持独立可操作.
    private var emptyMessage: some View {
        VStack(spacing: 7) {
            Image(systemName: viewModel.systemImage)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(AnyShapeStyle(EmptyNothingTokens.secondary(colorScheme)))
                .frame(width: 36, height: 36)
                .overlay {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(
                            EmptyNothingTokens.borderVisible(colorScheme),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                }

            Text(viewModel.title)
                .font(NothingFont.ui(11.5, weight: .semibold))
                .foregroundStyle(AnyShapeStyle(EmptyNothingTokens.display(colorScheme)))

            Text(viewModel.message)
                .font(NothingFont.ui(10))
                .foregroundStyle(AnyShapeStyle(EmptyNothingTokens.secondary(colorScheme)))
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
                .frame(maxWidth: 258)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "订阅用量，\(viewModel.statusText)。\(viewModel.title)，\(viewModel.message)"
        )
    }
}
