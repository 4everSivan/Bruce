import AppKit
import Combine
import BruceAppCore
import os

/// 菜单栏状态项 + 仪表盘弹出面板控制器. 替换 MenuBarExtra, 提供程序化开/关.
///
/// 面板用无边框 `NSPanel` 承载 (而非 `NSPopover`):
/// - `NSPopover` 无公开 API 隐藏箭头, 也无法去掉开合动画; 无边框面板两者皆无.
/// - 面板可成为 key 窗口, 支持 ⌘R 等快捷键; 点击其他应用时经 resignActive 关闭,
///   行为与 `.transient` popover 的点外关闭一致.
/// - toggle 关闭时把前台归还给打开前的应用, 避免焦点留在 Bruce.
@MainActor
final class MenuBarStatusItemController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let coordinator: OnboardingCoordinator
    private let openSettings: @MainActor () -> Void
    private let openSubscriptionSettings: @MainActor () -> Void
    private let terminateApplication: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private let panel = DashboardPanel(
        contentRect: .zero,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    private var installed = false
    /// 打开面板前的前台应用; toggle 关闭时归还前台. 打开时前台已是 Bruce 则为 nil.
    private var previousFrontmostApp: NSRunningApplication?
    /// AppKit updates `NSPanel.isVisible` asynchronously around activation and
    /// order-out. Keep the user's two-click intent in a synchronous state.
    private var dashboardToggleState: DashboardPanelToggleState = .closed
    /// AppKit 可能在状态项 action 前后发送 didResignActive; 在这一轮事件
    /// 内禁止外部失焦路径抢先改变 toggle 结果.
    private var statusItemActionInProgress = false
    /// 模型变化时重绘状态栏图像 (指标值, 刷新状态, 警示符号均驱动显示).
    private var labelSubscription: AnyCancellable?
    /// 观察系统是否接受了状态项的可见性请求. 只记录布尔状态, 不记录用户数据.
    private var statusItemVisibilityObservation: NSKeyValueObservation?
    private let logger = Logger(
        subsystem: "io.bruce.dashboard",
        category: "menu-bar"
    )
    /// Keep the status item geometry stable while macOS rebuilds the menu-bar
    /// accessibility tree. The image contains both icon and metric, so AppKit
    /// never has to re-layout an image/title pair.
    private static let statusItemLength: CGFloat = 74
    private static let iconOnlyLength: CGFloat = 28

    /// 菜单栏指标文本排版字体 (T-0 / T-4 主题各一), 控制器级缓存避免高频重绘反复构造 (C203).
    private static let classicMetricFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let nothingMetricFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)

    private static func metricFont(nothingTheme: Bool) -> NSFont {
        nothingTheme ? nothingMetricFont : classicMetricFont
    }
    private var lastRenderedContent: MenuBarStatusItemContent?
    private var refreshTimer: Timer?
    private var refreshPhase: CGFloat = 0
    /// 额度预警气泡控制器 (方案 A 胶囊微卡)
    private let quotaAlertBubbleController = QuotaAlertBubbleController()
    /// 仪表盘 AppKit 系统材质宿主; 与业务模型和刷新流程隔离.
    private var dashboardGlassController: DashboardGlassPanelController?
    /// 物理卷轴抽屉动画执行中标志 (C137). 动画期间抑制动态尺寸重排, 避免布局竞态.
    private var isTransitioning = false
    /// 最近一次 SwiftUI 上报的内容尺寸 (C147). 打开面板与过渡结束后都以此为准,
    /// 不再依赖会被布局时序污染的 `fittingSize` 或上一次窗口 frame.
    private var lastContentSize: CGSize?
    /// 过度中/隐藏期间被抑制的上报尺寸 (C147); 动画结束或面板重新可见时补应用一次,
    /// 避免「值只在变化时上报」把错位永久固化.
    private var pendingContentSize: CGSize?
    /// 高度应用是否已排队 (C147/C148). `onGeometryChange` 在 SwiftUI 布局过程中回调,
    /// 在同一轮里合并、并在布局周期结束后再改窗口, 避免重入把动画中间态写成最终态;
    /// C148 起窗口自己承担高度动画, 排队只负责把一次交互的多条上报并成一个目标.
    private var contentSizeApplyScheduled = false
    private var contentSizeApplyWorkItem: DispatchWorkItem?

    init(
        model: AppModel,
        coordinator: OnboardingCoordinator,
        openSettings: @escaping @MainActor () -> Void,
        openSubscriptionSettings: @escaping @MainActor () -> Void,
        terminateApplication: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.coordinator = coordinator
        self.openSettings = openSettings
        self.openSubscriptionSettings = openSubscriptionSettings
        self.terminateApplication = terminateApplication
        super.init()
        quotaAlertBubbleController.onOpenDashboard = { [weak self] in
            self?.openDashboardIfNeeded()
        }
        quotaAlertBubbleController.onOpenSettings = { [weak self] in
            guard let self else { return }
            // C187: 气泡在 .statusBar 层级的下拉面板可见时也可弹出, 直接打开设置会被
            // 仪表盘遮挡; 统一走 关闭仪表盘 → 写入出口深链 → 打开设置 的顺序.
            DashboardSettingsRoute.open(
                deepLink: { self.coordinator.requestedEgressSettings = true },
                closeDashboard: { self.closeDashboard(restorePreviousFrontmostApp: false) },
                openSettings: { self.openSubscriptionSettings() }
            )
        }
    }

    isolated deinit {
        refreshTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// 创建状态项与仪表盘面板. 幂等; 在 applicationDidFinishLaunching 调用.
    func install() {
        guard !installed else { return }
        installed = true

        // 使用固定长度的标准按钮. 图标和指标随后绘制成一张 image, 避免
        // NSStatusBarButton 在 image/title 两套 intrinsic size 之间反复布局.
        let item = NSStatusBar.system.statusItem(withLength: Self.statusItemLength)
        // 不使用 AppKit 自动生成的 autosave key. 自动 key 会随状态项的
        // 创建顺序变化, 让系统把本次启动误认为另一个历史状态项; 在
        // macOS 27 的菜单栏重建后, 这会表现为 `isVisible == true` 但实际
        // 没有可点击节点. 固定 key 让可见性状态只属于 Bruce 这一项.
        item.autosaveName = "io.bruce.dashboard.menu-bar"
        // 先保存引用, 确保状态项在后续刷新和可见性诊断中始终可达.
        statusItem = item
        guard let button = item.button else {
            logger.error("status item button unavailable")
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
            installed = false
            return
        }

        // 先把按钮内容和点击行为挂好, 再让系统把状态项置为可见.
        configureStatusItemButton(button, forceRender: false)
        // 模型与协调器任何 @Published / 偏好变化都重绘标签 (包含主题切换联动);
        // objectWillChange 在值应用前发出, 调度到下一轮 main-actor 取到新值再渲染.
        labelSubscription = Publishers.Merge(model.objectWillChange, coordinator.objectWillChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.refreshLabelImage()
                }
            }

        // 请求显示并观察系统最终状态. macOS 仍可能因用户菜单栏策略或空间
        // 管理而暂时隐藏状态项, 但此处能区分创建失败和系统侧不可见.
        statusItemVisibilityObservation = item.observe(
            \NSStatusItem.isVisible,
            options: [.initial, .new]
        ) { [weak self] observedItem, _ in
            let visible = observedItem.isVisible
            Task { @MainActor [weak self] in
                self?.logger.debug(
                    "status item visibility changed; visible=\(visible, privacy: .public)"
                )
                // macOS 27 / Pelmet 重排时可能重建按钮的绘制状态, 但不改变
                // MenuBarStatusItemContent. 内容未变时的普通刷新会被缓存短路,
                // 因而这里必须强制恢复 image + action + AX label.
                if visible {
                    self?.restoreStatusItemPresentation()
                }
            }
        }
        item.isVisible = true
        // `isVisible = true` 只改变状态项归属; 菜单栏按钮的最终窗口/AX 节点
        // 可能在下一轮 run loop 才完成. 额外恢复一次, 覆盖这段重排窗口.
        DispatchQueue.main.async { [weak self] in
            self?.restoreStatusItemPresentation()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.restoreStatusItemPresentation()
        }

        let hasImage = button.image != nil
        let titleLength = button.title.utf8.count
        let buttonWidth = button.frame.width
        let windowVisible = button.window?.isVisible ?? false
        logger.info("status item ready; image=\(hasImage, privacy: .public)")
        logger.info("status item title length=\(titleLength, privacy: .public)")
        logger.info("status item button width=\(buttonWidth, privacy: .public)")
        logger.info("status item window visible=\(windowVisible, privacy: .public)")

        let rootView = MenuBarDashboardView(
            openSettings: { [weak self] in
                // 打开设置前先关面板, 避免 statusBar 层级面板浮在设置窗口之上.
                self?.closeDashboard(restorePreviousFrontmostApp: false)
                self?.openSettings()
            },
            openSubscriptionSettings: { [weak self] in
                self?.closeDashboard(restorePreviousFrontmostApp: false)
                self?.openSubscriptionSettings()
            },
            terminateApplication: terminateApplication,
            onContentSizeChange: { [weak self] size in
                // onGeometryChange 回调运行在主线程, 安全.
                MainActor.assumeIsolated { self?.resizePanel(to: size) }
            },
            onSurfaceThemeChange: { [weak self] theme, colorScheme in
                self?.dashboardGlassController?.updateSurface(theme: theme, preferredColorScheme: colorScheme)
                // 面板级属性 (hasShadow/backgroundColor) 不在 updateSurface
                // 职责范围内, 由本控制器在主题变化后一并刷新.
                self?.refreshPanelWindowAttributes()
                self?.refreshLabelImage()
            }
        )
        .environmentObject(model)
        .environmentObject(coordinator)
        let glassController = DashboardGlassPanelController(
            // C145: 全局动效抑制开关经宿主根注入, 子树一律读 \.motionSuppressed.
            rootView: MotionEnvironmentRoot(coordinator: coordinator, content: rootView),
            theme: coordinator.resolvedTheme,
            preferredColorScheme: coordinator.appearanceMode.colorScheme
        )
        dashboardGlassController = glassController
        panel.contentViewController = glassController
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // 启动即是 Nothing 主题时, 覆盖为无阴影 + 主题纯色窗口背景.
        refreshPanelWindowAttributes()
        // 点击其他应用时关闭面板 (模拟 transient popover 的点外关闭).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        // 屏幕参数变化 (换屏/分辨率/菜单栏高度) 后重新按可见区夹取面板;
        // C148 起内容理想高度不再依赖屏幕, 这里只需把已记录的尺寸再落一次.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // 监听系统深色/浅色外观切换, 立即触发状态项重绘
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func screenParametersDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.pendingContentSize = self.lastContentSize
            self.scheduleContentSizeApply()
        }
    }

    @objc private func systemAppearanceDidChange() {
        Task { @MainActor [weak self] in
            guard let self, let button = self.statusItem?.button else { return }
            self.refreshLabelImage(on: button, force: true)
        }
    }

    // MARK: - 状态栏标签图像

    /// 重绘状态项按钮图像 (当前按钮).
    private func refreshLabelImage() {
        guard let button = statusItem?.button else { return }
        refreshLabelImage(on: button)
    }

    private func configureStatusItemButton(
        _ button: NSStatusBarButton,
        forceRender: Bool
    ) {
        refreshLabelImage(on: button, force: forceRender)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.setAccessibilityLabel("Bruce")
    }

    /// 状态栏宿主重排后恢复按钮内容. AppKit 可能保留同一个 NSStatusItem,
    /// 但清掉 button.image 或 action; 不能只依赖业务内容变化来触发重绘.
    private func restoreStatusItemPresentation() {
        guard installed, let button = statusItem?.button else { return }
        configureStatusItemButton(button, forceRender: true)
    }

    /// 使用一张固定尺寸的模板图像绘制图标和指标.
    ///
    /// 不把指标放进 `NSStatusBarButton.title`: title 和 image 分开交给
    /// AppKit 会让按钮在占位符和真实数据之间重新测量. image-only 让状态项
    /// 的 AX 节点和几何尺寸保持稳定, 同时保留菜单栏上的今日用量.
    private func refreshLabelImage(
        on button: NSStatusBarButton,
        force: Bool = false
    ) {
        let summary = model.makeMenuBarSummary()
        let isNothing = coordinator.resolvedTheme.interfaceStyle == .nothing
        let content = MenuBarStatusItemContentBuilder().build(
            metrics: model.menuBarMetrics,
            summary: summary,
            isRefreshing: isRefreshing,
            iconOnly: model.menuBarIconOnly,
            isNothingTheme: isNothing
        )

        if isRefreshing {
            startRefreshAnimationIfNeeded(on: button)
        } else {
            stopRefreshAnimation()
        }

        guard force || lastRenderedContent != content else {
            return
        }
        lastRenderedContent = content

        let isIconOnly = content.metricText.isEmpty
        let targetLength = isIconOnly ? Self.iconOnlyLength : targetStatusItemLength(for: content)
        if statusItem?.length != targetLength {
            statusItem?.length = targetLength
        }

        button.image = makeStatusItemImage(
            for: content,
            width: targetLength
        )
        button.title = ""
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.alignment = .center
        button.isEnabled = true
        button.appearsDisabled = false
        button.alphaValue = 1
        button.contentTintColor = nil
        button.toolTip = content.metricText.isEmpty
            ? content.accessibilityLabel
            : "\(content.accessibilityLabel) · \(content.metricText)"
    }

    private func startRefreshAnimationIfNeeded(on button: NSStatusBarButton) {
        // C145: 抑制动效时刷新环停在固定相位 (与 Windows 侧停掉 foot-spin 同口径),
        // 不启动逐帧定时器.
        guard !coordinator.motionSuppressed else { return }
        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRefreshing, let btn = self.statusItem?.button else {
                    self?.stopRefreshAnimation()
                    return
                }
                self.refreshPhase = (self.refreshPhase + 18).truncatingRemainder(dividingBy: 360)
                self.refreshLabelImage(on: btn, force: true)
            }
        }
    }

    private func stopRefreshAnimation() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshPhase = 0
    }

    /// 根据当前指标文本动态测量状态项所需总宽度,
    /// 确保 1 至 3 项指标与双同心环规完整展示, 不发生右侧截断.
    /// 引入 4pt 步进量化防抖, 消除邻居图标在微小数值变化时左右颤动.
    private func targetStatusItemLength(for content: MenuBarStatusItemContent) -> CGFloat {
        guard !content.metricText.isEmpty else {
            return Self.iconOnlyLength
        }
        let font = Self.metricFont(nothingTheme: content.isNothingTheme)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
        ]
        let textSize = (content.metricText as NSString).size(withAttributes: attributes)
        // 25 为左侧同心环规与留白, 右侧保留 8pt 舒适内边距; 下限 64pt; 采用 4pt 步进量化防抖
        let rawWidth = 25 + textSize.width + 8
        let steppedWidth = ceil(rawWidth / 4.0) * 4.0
        return max(64, steppedWidth)
    }

    /// 方案 B (德系包豪斯单轨星规 The Orbit & Satellite · C183) 与主题联动排版 (T-0 / T-4) 绘制:
    /// - 单轨圆规 (Orbit Track): r=6.4pt / w=1.4pt, 完整映射整体订阅剩余额度 (subscriptionQuotaRatio)
    /// - 卫星定位点 (The Satellite): r=1.8pt 锚定于当前弧端 (内核点缀 0.75pt 高光微核)
    /// - 动态色阶: 绿 (>50%) / 警示橙 (20%~50%) / 科技红 (<20% 或异常)
    /// - 刷新态: 卫星定位点在 refreshPhase 驱动下沿轨顺时针 60fps 平滑自旋，呈现机械陀飞轮秒针滑过的精密质感
    /// - 排版联动: 经典/液态玻璃为 T-0 (12pt monospacedDigit + 双空格),
    ///   Nothing 主题自动切换为 T-4 (12.5pt SF Mono Semibold + 弱化斜杠分隔)
    private func makeStatusItemImage(
        for content: MenuBarStatusItemContent,
        width: CGFloat
    ) -> NSImage {
        let size = NSSize(width: width, height: 22)
        let isIconOnly = content.metricText.isEmpty
        let iconCenterX: CGFloat = isIconOnly ? (size.width / 2) : 13
        let center = NSPoint(x: iconCenterX, y: size.height / 2)
        let radiusOrbit: CGFloat = 6.4
        let lineWidthOrbit: CGFloat = 1.4
        let radiusSatellite: CGFloat = 1.8
        let radiusSatelliteCore: CGFloat = 0.75

        let image = NSImage(size: size, flipped: false) { [weak self] _ in
            guard let self else { return false }

            // 1. 获取菜单栏当前宿主的真实深浅色外观 (优先当前按钮的 effectiveAppearance)
            let isDark: Bool
            if let button = self.statusItem?.button {
                isDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            } else {
                isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }

            // 2. 配色系统 (三色阶动力学 + 深浅双向高对比):
            // - 翡翠绿 (>50%): 深色 #30D158 / 浅色 #15803D (WCAG 对比度 > 4.8:1)
            // - 警示琥珀 (20%~50%): 深色 #FFB800 / 浅色 #D97706
            // - 科技红 (<20% 或 failed): 深色 #FF453A / 浅色 #DC2626
            let trackColor: NSColor
            let greenColor: NSColor
            let amberColor: NSColor
            let redColor: NSColor
            let labelTextColor: NSColor
            let separatorColor: NSColor

            if isDark {
                trackColor = NSColor(white: 1.0, alpha: 0.22)
                greenColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1.0)
                amberColor = NSColor(srgbRed: 1.0, green: 0.72, blue: 0.0, alpha: 1.0)
                redColor = NSColor(srgbRed: 1.0, green: 0.27, blue: 0.23, alpha: 1.0)
                labelTextColor = NSColor(white: 1.0, alpha: 0.95)
                separatorColor = NSColor(white: 1.0, alpha: 0.36)
            } else {
                trackColor = NSColor(white: 0.0, alpha: 0.18)
                greenColor = NSColor(srgbRed: 0.08, green: 0.50, blue: 0.24, alpha: 1.0)
                amberColor = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.02, alpha: 1.0)
                redColor = NSColor(srgbRed: 0.86, green: 0.15, blue: 0.15, alpha: 1.0)
                labelTextColor = NSColor(white: 0.0, alpha: 0.90)
                separatorColor = NSColor(white: 0.0, alpha: 0.34)
            }

            let isWarningIcon = content.iconName == "exclamationmark.triangle"
            let isFailedIcon = content.iconName == "xmark.circle"
            let isUnconfigured = content.iconName == "circle.dashed"

            func tierColor(for ratio: Double?) -> NSColor {
                if isFailedIcon { return redColor }
                if isWarningIcon { return amberColor }
                guard let ratio else { return greenColor }
                let tier = MenuBarQuotaTier.tier(for: ratio)
                switch tier {
                case .healthy: return greenColor
                case .warning: return amberColor
                case .critical: return redColor
                }
            }

            let quotaRatio = content.subscriptionQuotaRatio ?? content.outerQuotaRatio
            let orbitColor = tierColor(for: quotaRatio)

            // 3. 底轨 (Track): 德系极简 1.4pt 单轨圆规
            let orbitTrack = NSBezierPath()
            orbitTrack.appendArc(withCenter: center, radius: radiusOrbit, startAngle: 0, endAngle: 360)
            orbitTrack.lineWidth = lineWidthOrbit
            if isUnconfigured {
                let dash: [CGFloat] = [2.2, 2.2]
                orbitTrack.setLineDash(dash, count: 2, phase: 0)
            }
            trackColor.setStroke()
            orbitTrack.stroke()

            if self.isRefreshing {
                // 4. 刷新中: 卫星定位点沿单轨顺时针 60fps 平滑自旋，呈现机械陀飞轮秒针滑过的精密质感
                let currentAngle = (90.0 - self.refreshPhase).truncatingRemainder(dividingBy: 360)
                let rad = currentAngle * .pi / 180.0
                let satCenter = NSPoint(x: center.x + radiusOrbit * cos(rad), y: center.y + radiusOrbit * sin(rad))

                let satOuter = NSBezierPath(ovalIn: NSRect(
                    x: satCenter.x - radiusSatellite,
                    y: satCenter.y - radiusSatellite,
                    width: radiusSatellite * 2,
                    height: radiusSatellite * 2
                ))
                greenColor.setFill()
                satOuter.fill()

                let coreColor = isDark ? NSColor.white : NSColor(white: 0.96, alpha: 1.0)
                let satCore = NSBezierPath(ovalIn: NSRect(
                    x: satCenter.x - radiusSatelliteCore,
                    y: satCenter.y - radiusSatelliteCore,
                    width: radiusSatelliteCore * 2,
                    height: radiusSatelliteCore * 2
                ))
                coreColor.setFill()
                satCore.fill()
            } else if !isUnconfigured {
                // 5. 就绪态: 单轨星规额度填充与卫星定位点
                if let ratio = quotaRatio {
                    let fillRatio = max(0.0, min(1.0, ratio))
                    if fillRatio > 0.005 {
                        let orbitArc = NSBezierPath()
                        let startAngle: CGFloat = 90
                        let endAngle = startAngle - CGFloat(fillRatio * 360)
                        orbitArc.appendArc(withCenter: center, radius: radiusOrbit, startAngle: startAngle, endAngle: endAngle, clockwise: true)
                        orbitArc.lineWidth = lineWidthOrbit
                        orbitArc.lineCapStyle = .round
                        orbitColor.setStroke()
                        orbitArc.stroke()

                        // 卫星定位点锚定于弧端 endAngle
                        let rad = endAngle * .pi / 180.0
                        let satCenter = NSPoint(x: center.x + radiusOrbit * cos(rad), y: center.y + radiusOrbit * sin(rad))

                        let satOuter = NSBezierPath(ovalIn: NSRect(
                            x: satCenter.x - radiusSatellite,
                            y: satCenter.y - radiusSatellite,
                            width: radiusSatellite * 2,
                            height: radiusSatellite * 2
                        ))
                        orbitColor.setFill()
                        satOuter.fill()

                        let coreColor = isDark ? NSColor.white : NSColor(white: 0.96, alpha: 1.0)
                        let satCore = NSBezierPath(ovalIn: NSRect(
                            x: satCenter.x - radiusSatelliteCore,
                            y: satCenter.y - radiusSatelliteCore,
                            width: radiusSatelliteCore * 2,
                            height: radiusSatelliteCore * 2
                        ))
                        coreColor.setFill()
                        satCore.fill()
                    } else {
                        // 零额度微型警告点
                        let dotRect = NSRect(x: center.x - 0.9, y: center.y + radiusOrbit - 0.9, width: 1.8, height: 1.8)
                        let dotPath = NSBezierPath(ovalIn: dotRect)
                        orbitColor.setFill()
                        dotPath.fill()
                    }
                }
            }

            // 6. 指标文本绘制 (非仅图标模式时)
            // C203: 闭包内严禁文本测量 API —— NSAttributedString.size() 走
            // NSStringDrawingEngine 的 CoreText 排版路径, 在 NSCustomImageRep 离屏
            // 上下文中偶发属性字典插 nil (NSInvalidArgumentException/SIGABRT).
            // 排版尺寸一律经闭包外测量 (targetStatusItemLength) 或字体度量推导;
            // 字体取控制器级缓存, 避免高频重绘时反复构造.
            if !content.metricText.isEmpty {
                let font = Self.metricFont(nothingTheme: content.isNothingTheme)

                let attrString = NSMutableAttributedString(
                    string: content.metricText,
                    attributes: [
                        .font: font,
                        .foregroundColor: labelTextColor,
                    ]
                )

                // Nothing T-4 模式下弱化 " / " 斜杠分隔符
                if content.isNothingTheme {
                    let fullString = content.metricText as NSString
                    var searchRange = NSRange(location: 0, length: fullString.length)
                    while searchRange.location < fullString.length {
                        let foundRange = fullString.range(of: " / ", options: [], range: searchRange)
                        if foundRange.location != NSNotFound {
                            attrString.addAttribute(.foregroundColor, value: separatorColor, range: foundRange)
                            let nextLoc = foundRange.location + foundRange.length
                            searchRange = NSRange(location: nextLoc, length: fullString.length - nextLoc)
                        } else {
                            break
                        }
                    }
                }

                // Cap-Height 光学垂直居中: 使文字大写字形中心与画布中心严格重合
                let baselineY = round((size.height - font.capHeight) / 2.0 + font.descender)
                let textRect = NSRect(
                    x: 25,
                    y: max(0, baselineY),
                    width: max(0, size.width - 25),
                    height: ceil(font.ascender + abs(font.descender))
                )
                attrString.draw(in: textRect)
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    private var isRefreshing: Bool {
        model.moduleStatuses.values.contains { $0.state == .refreshing }
    }

    /// 切换仪表盘开/关 (全局快捷键与状态项点击共用).
    func toggleDashboard() {
        guard installed else {
            logger.error("dashboard toggle ignored; status item not installed")
            return
        }
        guard let button = statusItem?.button else {
            logger.error("dashboard toggle ignored; status item button unavailable")
            return
        }
        if dashboardToggleState == .open {
            closeDashboard(restorePreviousFrontmostApp: true)
        } else {
            openDashboard(relativeTo: button)
        }
    }

    /// 弹出通用状态预警气泡 (方案 A · 280pt 胶囊微卡，支持额度超限与网络出口阻断多态)
    func showStatusAlertBubble(items: [StatusBubbleAlertItem], force: Bool = false) {
        if !force {
            guard coordinator.systemNotificationsEnabled else { return }
        }
        // 设计 03 §14: 主面板可见时静默跳过气泡, 避免与仪表盘卡片叠加 (C187).
        guard StatusBubblePresentationPolicy.shouldPresent(
            dashboardOpen: dashboardToggleState == .open
        ) else { return }
        guard let button = statusItem?.button else { return }
        quotaAlertBubbleController.show(
            items: items,
            theme: coordinator.resolvedTheme,
            colorScheme: coordinator.appearanceMode.colorScheme,
            relativeTo: button
        )
    }

    /// 弹出额度预警气泡 (方案 A · 280pt 胶囊微卡，兼容旧接口)
    func showQuotaAlertBubble(alerts: [QuotaAlert], force: Bool = false) {
        showStatusAlertBubble(items: alerts.map { .quota($0) }, force: force)
    }

    /// 若主看板未处于打开状态则展开主看板
    func openDashboardIfNeeded() {
        guard installed, let button = statusItem?.button else { return }
        if dashboardToggleState != .open {
            openDashboard(relativeTo: button)
        }
    }

    /// 退出时清理.
    func teardown() {
        NotificationCenter.default.removeObserver(self)
        labelSubscription?.cancel()
        labelSubscription = nil
        statusItemVisibilityObservation?.invalidate()
        statusItemVisibilityObservation = nil
        contentSizeApplyWorkItem?.cancel()
        contentSizeApplyWorkItem = nil
        quotaAlertBubbleController.hide(animated: false)
        closeDashboard(restorePreviousFrontmostApp: false)
        panel.delegate = nil
        dashboardGlassController = nil
        panel.contentViewController = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        installed = false
        isTransitioning = false
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        statusItemActionInProgress = true
        DispatchQueue.main.async { [weak self] in
            self?.statusItemActionInProgress = false
        }
        toggleDashboard()
    }

    // MARK: - 面板开关

    /// 按当前主题刷新面板窗口级属性. install() 只设一次的 hasShadow /
    /// backgroundColor 在主题切换后不会自动跟随: Nothing 要求零阴影,
    /// 其余主题恢复透明窗口 + 阴影. isOpaque 恒为 false (面板圆角依赖
    /// 窗口四角透明, 内容不透明度由 surface 视图自身保证).
    private func refreshPanelWindowAttributes() {
        if dashboardGlassController?.panelWindowTintColor != nil {
            panel.hasShadow = false
        } else {
            panel.hasShadow = true
        }
        panel.backgroundColor = .clear
    }

    private func openDashboard(relativeTo button: NSStatusBarButton) {
        quotaAlertBubbleController.hide(animated: false)
        dashboardToggleState = .open
        // 先记录打开前的前台应用 (打开路径会把 Bruce 激活, 前台切到 Bruce).
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousFrontmostApp = (frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier)
            ? nil
            : frontmost
        let fittingSize = panel.contentViewController?.view.fittingSize ?? .zero
        let initialSize = openContentSize(fittingSize: fittingSize)
        let screen = button.window?.screen ?? NSScreen.main
        let screenRect = button.window?.convertToScreen(button.convert(button.bounds, to: nil))
            ?? button.convert(button.bounds, to: nil)
        let placement = DashboardPanelPlacementResolver.resolve(
            anchorRect: screenRect,
            panelSize: initialSize,
            visibleFrame: screen?.visibleFrame ?? .zero,
            screenFrame: screen?.frame ?? .zero
        )
        // C147: 目标 frame 与窗口高度同源, 并夹取进屏, 保证顶栏/底栏都不会被推出屏幕.
        let targetFrame = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: placement.origin.y + initialSize.height,
            contentSize: initialSize,
            currentX: placement.origin.x,
            visibleFrame: screen?.visibleFrame ?? .zero
        )

        // 面板关闭期间主题可能已切换且 SwiftUI onChange 尚未触发 (视图未加载),
        // 打开前兜底刷新一次面板级属性.
        refreshPanelWindowAttributes()
        NSApp.activate(ignoringOtherApps: true)
        model.setDashboardPanelVisible(true)

        // C145: 动效是否播放由应用内偏好与系统无障碍偏好共同裁决,
        // 裁决点在 OnboardingCoordinator.motionSuppressed.
        guard DashboardPanelAnimationPolicy.allowsCurtainTransition(
            motionSuppressed: coordinator.motionSuppressed
        ) else {
            panel.setFrame(targetFrame, display: false)
            panel.alphaValue = 1.0
            panel.makeKeyAndOrderFront(nil)
            return
        }

        // 物理卷轴抽屉下拉 (流派 B · C137): 顶边 Y 固定, 高度由 20pt 垂直展开至目标高度
        let topY = targetFrame.maxY
        let collapsedHeight = CGFloat(DashboardPanelAnimationPolicy.curtainCollapsedHeight)
        let startFrame = NSRect(
            x: targetFrame.origin.x,
            y: topY - collapsedHeight,
            width: targetFrame.width,
            height: collapsedHeight
        )

        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        isTransitioning = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DashboardPanelAnimationPolicy.curtainOpenDuration
            // C145: 原 (0.16, 1.0, 0.3, 1.0) 前 45ms 即走完 74.5% 行程, 读作瞬移.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.61, 0.36, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 1.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                if self.dashboardToggleState == .open {
                    self.panel.alphaValue = 1.0
                    // 动画期间被抑制的内容高度上报在此补应用, 不再回落到可能过期的 targetFrame.
                    self.flushPendingContentSize()
                        }
            }
        })
    }

    /// 打开面板时采用的内容尺寸: 优先最近一次实测上报, 仅在从未收到上报时用 fittingSize 兜底.
    /// C147: 宿主视图高度改为显式约束后, `fittingSize` 在视图尚未上报时会退化成约束常量,
    /// 因此对兜底值做下限保护, 避免首开窗口被压成一条窄条.
    private func openContentSize(fittingSize: CGSize) -> CGSize {
        if let lastContentSize, lastContentSize.width > 0, lastContentSize.height > 0 {
            return DashboardPanelSizingPolicy.resolvedContentSize(lastContentSize)
        }
        let hasUsableFittingSize = fittingSize.width > 0 && fittingSize.height >= 120
        let fallback = hasUsableFittingSize
            ? fittingSize
            : CGSize(width: max(panel.frame.width, 440), height: 640)
        let resolved = DashboardPanelSizingPolicy.resolvedContentSize(fallback)
        lastContentSize = hasUsableFittingSize ? resolved : nil
        return resolved
    }

    /// 关闭面板; toggle 关闭时把前台归还给打开前的应用,
    /// 因点击其他应用而关闭 (resignActive) 时不归还 (对方已是前台).
    private func closeDashboard(restorePreviousFrontmostApp: Bool) {
        dashboardToggleState = .closed
        let transition = DashboardPanelVisibilityTransition.close(
            panelIsVisible: panel.isVisible
        )
        model.setDashboardPanelVisible(transition.visible)

        let previousPID = restorePreviousFrontmostApp ? previousFrontmostApp?.processIdentifier : nil
        previousFrontmostApp = nil
        let restoreFocus = {
            if let pid = previousPID, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [])
            }
        }

        guard transition.shouldOrderOut else {
            restoreFocus()
            return
        }

        // C145: 同 openDashboard, 动效裁决点收敛到 coordinator.
        guard DashboardPanelAnimationPolicy.allowsCurtainTransition(
            motionSuppressed: coordinator.motionSuppressed
        ) else {
            panel.orderOut(nil)
            panel.alphaValue = 1.0
            restoreFocus()
            return
        }

        // 物理卷轴抽屉逆向回卷 (流派 B · C137): 顶边固定向上收拢至 20pt 后离窗
        isTransitioning = true
        let topY = panel.frame.maxY
        let collapsedHeight = CGFloat(DashboardPanelAnimationPolicy.curtainCollapsedHeight)
        let collapseFrame = NSRect(
            x: panel.frame.origin.x,
            y: topY - collapsedHeight,
            width: panel.frame.width,
            height: collapsedHeight
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DashboardPanelAnimationPolicy.curtainCloseDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapseFrame, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isTransitioning = false
                if self.dashboardToggleState == .closed {
                    self.panel.orderOut(nil)
                    // 恢复默认不透明度, 避免下次打开闪烁
                    self.panel.alphaValue = 1.0
                }
                if let pid = previousPID, let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [])
                }
            }
        })
    }

    /// SwiftUI 内容理想尺寸变化时跟随调整面板 (顶边固定, 高度变化向下延伸, 屏幕底部安全吸附保护).
    /// C147: 上报只记录并排队, 由 `flushPendingContentSize` 在布局周期结束后统一应用 ——
    /// 过渡中/隐藏期间暂存, 动画结束或面板重新可见时补应用, 避免被吞掉的上报
    /// 或动画逐帧重入把窗口与内容高度永久拉偏.
    private func resizePanel(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        lastContentSize = DashboardPanelSizingPolicy.resolvedContentSize(size)
        pendingContentSize = lastContentSize
        scheduleContentSizeApply()
    }

    /// 合并同一轮布局内的多帧上报, 延后到当前布局周期之后再应用 (C147/C148).
    /// C148: 一次交互可能在一拍内连报两次 (终值 + 修正值), 这里用 30ms 小窗口合并成
    /// 一个目标再起一次窗口动画; 每条上报各起一条动画会让窗口边缘反复重新起步,
    /// 读起来就是弹簧回弹.
    private func scheduleContentSizeApply() {
        contentSizeApplyWorkItem?.cancel()
        contentSizeApplyScheduled = true
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.contentSizeApplyScheduled = false
            self.flushPendingContentSize()
        }
        contentSizeApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
    }

    /// 把内容尺寸落成面板 frame: 顶边锚定 + 屏幕夹取.
    ///
    /// C148: 面板高度是**唯一**的高度动画源 —— SwiftUI 侧的高度变化在布局上只是
    /// 跳到终值 (几何上报只给终值), 所以由窗口自己用一条与内容同长的曲线过渡;
    /// 宿主视图四边贴合窗口, 底栏与视口因此逐帧跟着窗口下边缘一起走, 不会出现
    /// 「底栏先跳到位、窗口边缘随后追赶」的错位.
    private func applyContentSize(_ size: CGSize) {
        let screen = panel.screen ?? NSScreen.main
        let frame = DashboardPanelSizingPolicy.topAnchoredFrame(
            topY: panel.frame.maxY,
            contentSize: size,
            currentX: panel.frame.minX,
            visibleFrame: screen?.visibleFrame ?? .zero
        )
        let heightDelta = abs(frame.height - panel.frame.height)
        let yDelta = abs(frame.minY - panel.frame.minY)
        let xDelta = abs(frame.minX - panel.frame.minX)
        guard heightDelta > 1.0 || yDelta > 1.0 || xDelta > 1.0 else { return }

        let shouldAnimate = panel.isVisible
            && !coordinator.motionSuppressed
            && heightDelta > 2.0
            && xDelta <= 1.0
        guard shouldAnimate else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DashboardMotionTiming.contentResize
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// 补应用被过渡/隐藏抑制的高度上报 (C147). 同一轮里最多应用一次.
    private func flushPendingContentSize() {
        guard !isTransitioning, panel.isVisible else { return }
        guard let size = pendingContentSize ?? lastContentSize else { return }
        pendingContentSize = nil
        applyContentSize(size)
    }

    @objc private func applicationDidResignActive(_ note: Notification) {
        // 状态项点击本身也可能触发 didResignActive. 只有鼠标不在 Bruce
        // 状态项上、且当前不是状态项 action 事件时, 才认定为点击了其他应用.
        let pointerIsInsideStatusItem: Bool
        if let button = statusItem?.button,
           let window = button.window {
            let itemRect = window.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            pointerIsInsideStatusItem = itemRect.contains(NSEvent.mouseLocation)
        } else {
            pointerIsInsideStatusItem = false
        }
        guard DashboardPanelDismissalPolicy.shouldDismissOnApplicationResign(
            panelIsVisible: panel.isVisible,
            pointerIsInsideStatusItem: pointerIsInsideStatusItem,
            statusItemActionInProgress: statusItemActionInProgress
        ) else {
            return
        }
        // 用户点击了其他应用 → 关闭面板, 不强制归还前台.
        contentSizeApplyWorkItem?.cancel()
        contentSizeApplyWorkItem = nil
        quotaAlertBubbleController.hide(animated: false)
        closeDashboard(restorePreviousFrontmostApp: false)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        let visible = DashboardPanelVisibilityTransition.isActuallyVisible(
            panelIsVisible: panel.isVisible,
            occlusionStateIsVisible: panel.occlusionState.contains(.visible)
        )
        dashboardToggleState = visible ? .open : .closed
        model.setDashboardPanelVisible(visible)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else {
            return
        }
        dashboardToggleState = .closed
        model.setDashboardPanelVisible(false)
    }
}

/// 无边框面板默认不能成为 key; 仪表盘需要 key 窗口支持 ⌘R 等快捷键.
private final class DashboardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
