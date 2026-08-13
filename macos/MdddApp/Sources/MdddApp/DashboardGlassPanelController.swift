import AppKit
import MdddOnboardingCore
import SwiftUI

/// AppKit 视觉承载层: 系统材质在窗口层渲染, SwiftUI 只负责仪表盘内容.
@MainActor
final class DashboardGlassPanelController: NSViewController {
    private let hostingController: NSHostingController<AnyView>
    private let rootView = DashboardGlassRootView()
    private var surfaceView: NSView?
    private var surfacePlan: DashboardGlassSurfacePlan

    init<Content: View>(
        rootView: Content,
        theme: ResolvedTheme
    ) {
        self.hostingController = NSHostingController(rootView: AnyView(rootView))
        self.surfacePlan = DashboardGlassSurfacePlan.resolve(theme: theme)
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
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installSurface()
    }

    /// 主题变化时只更新视觉层, 不重建面板和 SwiftUI 状态.
    func updateSurface(theme: ResolvedTheme) {
        let nextPlan = DashboardGlassSurfacePlan.resolve(theme: theme)
        guard nextPlan != surfacePlan else { return }
        surfacePlan = nextPlan
        guard isViewLoaded else { return }
        installSurface()
    }

    private func installSurface() {
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
        let appearance = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        if appearance == .darkAqua {
            switch surfacePlan.panelMaterial {
            case .clear:
                // A clear surface can sample a white browser/document window
                // even while the app content is in dark appearance. Keep the
                // backdrop visible, but anchor it to a readable dark range.
                return NSColor.black.withAlphaComponent(0.42)
            case .standard:
                return NSColor.black.withAlphaComponent(0.30)
            case .matte, .classic:
                return NSColor.black.withAlphaComponent(0.16)
            }
        }

        switch surfacePlan.panelMaterial {
        case .clear:
            return NSColor.windowBackgroundColor.withAlphaComponent(0.34)
        case .standard:
            return NSColor.windowBackgroundColor.withAlphaComponent(0.46)
        case .matte, .classic:
            return NSColor.clear
        }
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
    override var isFlipped: Bool { true }
}

private final class DashboardOpaqueSurfaceView: NSView {
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
