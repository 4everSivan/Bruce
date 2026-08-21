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
    private var surfacePlan: DashboardGlassSurfacePlan
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
        self.surfacePlan = DashboardGlassSurfacePlan.resolve(theme: theme)
        self.surfaceStyle = DashboardGlassSurfaceStyle.resolve(
            theme: theme,
            appearance: preferredColorScheme == .dark ? .dark : .light,
            capabilities: .current
        )
        self.preferredColorScheme = preferredColorScheme
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DashboardGlassPanelController does not support NSCoder initialization")
    }

    override func loadView() {
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.cornerRadius = 22
        rootView.layer?.masksToBounds = true
        rootView.onEffectiveAppearanceChange = { [weak self] in
            self?.refreshSurfaceForEffectiveAppearance()
        }
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSurface()
    }

    /// 主题变化时只更新视觉层, 不重建面板和 SwiftUI 状态.
    func updateSurface(theme: ResolvedTheme, preferredColorScheme: ColorScheme?) {
        self.theme = theme
        let nextPlan = DashboardGlassSurfacePlan.resolve(theme: theme)
        let nextStyle = DashboardGlassSurfaceStyle.resolve(
            theme: theme,
            appearance: dashboardAppearance(for: preferredColorScheme),
            capabilities: .current
        )
        let appearanceChanged = preferredColorScheme != self.preferredColorScheme
        self.preferredColorScheme = preferredColorScheme
        guard nextPlan != surfacePlan || nextStyle != surfaceStyle || appearanceChanged else {
            return
        }
        surfacePlan = nextPlan
        surfaceStyle = nextStyle
        guard isViewLoaded else { return }
        installSurface()
    }

    private func refreshSurfaceForEffectiveAppearance() {
        guard preferredColorScheme == nil, isViewLoaded else { return }
        let nextStyle = DashboardGlassSurfaceStyle.resolve(
            theme: theme,
            appearance: dashboardAppearance(for: nil),
            capabilities: .current
        )
        guard nextStyle != surfaceStyle else { return }
        surfaceStyle = nextStyle
        installSurface()
    }

    private func installSurface() {
        surfaceStyle = DashboardGlassSurfaceStyle.resolve(
            theme: theme,
            appearance: dashboardAppearance(for: preferredColorScheme),
            capabilities: .current
        )
        surfaceView?.removeFromSuperview()
        hostingController.view.removeFromSuperview()

        let surface = makeSurface()
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
        // NSGlassEffectView.contentView embeds content in the effect itself and
        // makes text/chart rendering too soft for this dashboard.
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    private func makeSurface() -> NSView {
        if surfacePlan.reduceTransparencyFallback {
            return DashboardOpaqueSurfaceView()
        }

        switch surfacePlan.backend {
        case .nativeLiquidGlass:
            if #available(macOS 26, *) {
                let glass = NSGlassEffectView()
                glass.style = surfacePlan.panelMaterial == .clear ? .clear : .regular
                glass.cornerRadius = 22
                // Keep the native backdrop visible while anchoring its
                // luminance to the content appearance. A clear surface can
                // otherwise sample a white document window and turn the dark
                // dashboard content into white-on-white text.
                glass.tintColor = nativeGlassTintColor()
                return glass
            }
            return makeMaterialSurface()
        case .appKitMaterial:
            return makeMaterialSurface()
        case .swiftUIFallback:
            let fallback = NSView()
            fallback.wantsLayer = true
            fallback.layer?.backgroundColor = NSColor.clear.cgColor
            return fallback
        }
    }

    private func makeMaterialSurface() -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = material(for: surfacePlan.panelMaterial)
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }

    @available(macOS 26, *)
    private func nativeGlassTintColor() -> NSColor {
        nsColor(for: surfaceStyle.panelTint)
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

    private func material(
        for material: DashboardGlassMaterial
    ) -> NSVisualEffectView.Material {
        switch material {
        case .standard:
            return .hudWindow
        case .clear:
            return .underWindowBackground
        case .matte:
            return .windowBackground
        case .classic:
            return .contentBackground
        }
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
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
