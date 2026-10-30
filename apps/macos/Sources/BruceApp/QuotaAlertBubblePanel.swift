import AppKit
import SwiftUI
import BruceAppCore
import BruceOnboardingCore

// MARK: - 订阅额度预警非激活无焦点浮层 Panel

/// 轻量非激活无焦点微气泡 Panel (方案 A)
/// 绝不抢占当前 IDE / 终端焦点, 满足全屏专注打字要求.
final class QuotaAlertBubblePanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // 由 SwiftUI 内部绘制自适应柔和阴影
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 气泡控制器

@MainActor
final class QuotaAlertBubbleController {
    private var panel: QuotaAlertBubblePanel?
    private var dismissTimer: Timer?
    private var isMouseHovering = false

    /// 外部回调: 点击气泡主体打开主看板
    var onOpenDashboard: (() -> Void)?

    init() {}

    /// 显示额度预警气泡
    func show(
        alerts: [QuotaAlert],
        theme: ResolvedTheme,
        colorScheme: ColorScheme? = nil,
        relativeTo button: NSStatusBarButton?
    ) {
        guard !alerts.isEmpty else { return }

        // 如果已有气泡，先取消旧的淡出定时器
        dismissTimer?.invalidate()
        dismissTimer = nil
        isMouseHovering = false

        let bubblePanel = panel ?? QuotaAlertBubblePanel()
        self.panel = bubblePanel

        let rootView = QuotaAlertBubbleView(
            alerts: alerts,
            onOpenDashboard: { [weak self] in
                self?.hide(animated: false)
                self?.onOpenDashboard?()
            },
            onClose: { [weak self] in
                self?.hide(animated: true)
            },
            onHoverChange: { [weak self] isHovered in
                self?.handleHoverChange(isHovered)
            }
        )
        .environment(\.BruceResolvedTheme, theme)
        .preferredColorScheme(colorScheme)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        bubblePanel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let targetSize = CGSize(
            width: max(280, fittingSize.width),
            height: max(50, fittingSize.height)
        )

        // 定位计算: 锚定状态项下方
        let screen = button?.window?.screen ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        var originX: CGFloat = screenFrame.maxX - targetSize.width - 20
        var originY: CGFloat = screenFrame.maxY - targetSize.height - 30

        if let button, let window = button.window {
            let buttonScreenRect = window.convertToScreen(button.convert(button.bounds, to: nil))
            originX = buttonScreenRect.midX - targetSize.width / 2.0
            // 夹取保证不超出屏幕
            originX = max(screenFrame.minX + 8, min(originX, screenFrame.maxX - targetSize.width - 8))
            originY = buttonScreenRect.minY - targetSize.height - 4
        }

        bubblePanel.setFrame(CGRect(origin: CGPoint(x: originX, y: originY), size: targetSize), display: true)
        bubblePanel.alphaValue = 1.0

        // 非激活无焦点展示，绝不抢占当前活动窗口焦点
        bubblePanel.orderFrontRegardless()

        // 启动 6 秒平滑淡出定时器 (T2 样式)
        scheduleDismiss(after: 6.0)
    }

    /// 隐藏气泡
    func hide(animated: Bool = true) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        isMouseHovering = false

        guard let panel, panel.isVisible else { return }

        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0.0
            }, completionHandler: {
                Task { @MainActor in
                    panel.orderOut(nil)
                    panel.alphaValue = 1.0
                }
            })
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
        }
    }

    private func handleHoverChange(_ isHovered: Bool) {
        isMouseHovering = isHovered
        if isHovered {
            // 鼠标悬停: 保持常亮，取消淡出
            dismissTimer?.invalidate()
            dismissTimer = nil
            panel?.alphaValue = 1.0
        } else {
            // 鼠标移出: 重新排队 3 秒平滑淡出
            scheduleDismiss(after: 3.0)
        }
    }

    private func scheduleDismiss(after interval: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isMouseHovering else { return }
                self.hide(animated: true)
            }
        }
    }
}
