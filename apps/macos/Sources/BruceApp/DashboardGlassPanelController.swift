import AppKit
import BruceGlassSurfaceCore
import BruceOnboardingCore
import SwiftUI

/// AppKit 视觉承载层: 系统材质在窗口层渲染, SwiftUI 只负责仪表盘内容.
@MainActor
final class DashboardGlassPanelController: NSViewController {
    private let hostingController: NSHostingController<AnyView>
    private let rootView = DashboardGlassRootView()
    private var theme: ResolvedTheme
    private var surfaceView: NSView?
    private var surfaceStyle: DashboardGlassSurfaceStyle
    /// 面板配色模式映射; nil 表示跟随系统, 由 effectiveAppearance 决定 tint 明暗.
    private var preferredColorScheme: ColorScheme?

    init<Content: View>(
        rootView: Content,
        theme: ResolvedTheme,
        preferredColorScheme: ColorScheme? = nil
    ) {
        self.hostingController = NSHostingController(rootView: AnyView(rootView))
        self.theme = theme
        self.surfaceStyle = DashboardGlassSurfaceStyle.resolve(
            appearance: preferredColorScheme == .dark ? .dark : .light
        )
        self.preferredColorScheme = preferredColorScheme
        super.init(nibName: nil, bundle: nil)
        // C256: NSHostingController 作为子控制器纳入 AppKit 控制器树，
        // 保证生命周期与外观环境正确传递（此前仅 addSubview，违反嵌套契约）。
        addChild(hostingController)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DashboardGlassPanelController does not support NSCoder initialization")
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.cornerRadius = panelCornerRadius
        rootView.layer?.masksToBounds = true
        rootView.onEffectiveAppearanceChange = { [weak self] in
            self?.refreshSurfaceForEffectiveAppearance()
        }
        view = rootView
    }

    /// 面板圆角: 全风格统一升级为 14pt 呼吸感协同圆角 (协同 8pt 卡片体系, 覆盖所有主题包含 Nothing).
    private var panelCornerRadius: CGFloat {
        14
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSurface()
    }

    /// 主题变化时只更新视觉层, 不重建面板和 SwiftUI 状态.
    func updateSurface(theme: ResolvedTheme, preferredColorScheme: ColorScheme?) {
        self.theme = theme
        let nextStyle = DashboardGlassSurfaceStyle.resolve(
            appearance: dashboardAppearance(for: preferredColorScheme)
        )
        let appearanceChanged = preferredColorScheme != self.preferredColorScheme
        self.preferredColorScheme = preferredColorScheme
        guard nextStyle != surfaceStyle || appearanceChanged else {
            return
        }
        surfaceStyle = nextStyle
        guard isViewLoaded else { return }
        installSurface()
    }

    private func refreshSurfaceForEffectiveAppearance() {
        guard preferredColorScheme == nil, isViewLoaded else { return }
        let nextStyle = DashboardGlassSurfaceStyle.resolve(
            appearance: dashboardAppearance(for: nil)
        )
        guard nextStyle != surfaceStyle else { return }
        surfaceStyle = nextStyle
        installSurface()
    }

    private func installSurface() {
        surfaceStyle = DashboardGlassSurfaceStyle.resolve(
            appearance: dashboardAppearance(for: preferredColorScheme)
        )
        // 主题切换后圆角跟随 (nothing=10, 其余=22); updateSurface 的
        // 相等性短路对 nothing↔其他主题恒不命中 (plan 的 backend/material
        // 必不相同), 此处重设即可覆盖所有到达路径.
        rootView.layer?.cornerRadius = panelCornerRadius
        surfaceView?.removeFromSuperview()
        hostingController.view.removeFromSuperview()

        let surface = makeSurface()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = panelCornerRadius
        surface.layer?.masksToBounds = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        surfaceView = surface

        // Native surface is deliberately a sibling behind SwiftUI content.
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        // C148: 宿主视图四边贴合窗口 (不再用显式高度约束). 面板高度由控制器
        // 唯一驱动, 窗口 frame 每帧变化时宿主视图随之重排 —— 底栏因此贴着窗口
        // 下边缘同步移动, 不会出现「底栏先跳到位、窗口边缘随后追赶」的错位.
        // 摘掉 `fixedSize` 后 SwiftUI 内容按窗口高度布局, 视口过短时向下溢出、
        // 由根视图裁切, 不存在内容被强制平移 (C147 的 Header 顶出问题).
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.cornerRadius = panelCornerRadius
        hostingController.view.layer?.masksToBounds = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    /// C271: Nothing 纯色不透明平面, 吃主题 panelTint, 零模糊零阴影.
    private func makeSurface() -> NSView {
        DashboardOpaqueSurfaceView(
            backgroundColor: nsColor(for: surfaceStyle.panelTint)
        )
    }

    /// tint 明暗判定: 显式配色模式 (light/dark) 优先, 跟随系统 (nil) 时读 effectiveAppearance.
    /// 不用 effectiveAppearance 作为唯一来源: 启动时 install 先于 applyAppearance 执行,
    /// 首次 viewDidLoad 时 NSApp.appearance 尚未设置深色, 会误判为浅色导致深色通透首帧白闪.
    private var isDarkAppearance: Bool {
        if let preferredColorScheme {
            return preferredColorScheme == .dark
        }
        return view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func dashboardAppearance(for colorScheme: ColorScheme?) -> DashboardGlassAppearance {
        if let colorScheme {
            return colorScheme == .dark ? .dark : .light
        }
        guard isViewLoaded else { return .light }
        return isDarkAppearance ? .dark : .light
    }

    private func nsColor(for token: DashboardGlassColorToken) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(token.red),
            green: CGFloat(token.green),
            blue: CGFloat(token.blue),
            alpha: CGFloat(token.alpha)
        )
    }

    /// C271: 面板窗口恒使用 Nothing 面板色, 供 MenuBarStatusItemController 刷新窗口级属性.
    var panelWindowTintColor: NSColor? {
        nsColor(for: surfaceStyle.panelTint)
    }
}

private final class DashboardGlassRootView: NSView {
    var onEffectiveAppearanceChange: (() -> Void)?

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }
}

private final class DashboardOpaqueSurfaceView: NSView {
    private let backgroundColor: NSColor

    /// 默认系统 windowBackgroundColor (无障碍降级路径保持原行为);
    /// Nothing 主题传入主题 panelTint.
    init(backgroundColor: NSColor = .windowBackgroundColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DashboardOpaqueSurfaceView does not support NSCoder initialization")
    }

    override var isOpaque: Bool { false }
}
