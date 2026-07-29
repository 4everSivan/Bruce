import SwiftUI
import MdddOnboardingCore
import WebKit

enum WidgetDisplayState: String, Equatable, Sendable {
    case loading
    case refreshing
    case fresh
    case stale
    case authRequired
    case offline
    case partial
    case error
    case notConfigured

    init(moduleState: ModuleRunState) {
        switch moduleState {
        case .notConfigured:
            self = .notConfigured
        case .ready:
            self = .loading
        case .refreshing:
            self = .refreshing
        case .fresh:
            self = .fresh
        case .partial:
            self = .partial
        case .stale:
            self = .stale
        case .authRequired:
            self = .authRequired
        case .offline:
            self = .offline
        case .failed:
            self = .error
        }
    }
}

struct WidgetSecurityPolicy {
    let resourceRoot: URL

    func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme == "about" && url.absoluteString == "about:blank" {
            return true
        }
        guard url.isFileURL else { return false }
        let rootPath = resourceRoot.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath + "/")
    }
}

enum WidgetResourceError: Error {
    case missingResource
    case invalidModule
}

struct BundledWidgetResources {
    static func pageURL(for module: CollectorModule) throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "Widgets/\(module.rawValue)"
        ) else {
            throw WidgetResourceError.missingResource
        }
        return url
    }

    static func bootstrapSource() throws -> String {
        guard let url = Bundle.module.url(
            forResource: "host-bootstrap",
            withExtension: "js",
            subdirectory: "Widgets"
        ) else {
            throw WidgetResourceError.missingResource
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 液态玻璃主题 CSS 文本. 共享文件位于 Widgets/ 根目录,
    /// 超出 loadFileURL 的读取范围, 由原生侧读入后经 JS 注入.
    static func glassThemeCSS() -> String? {
        guard let url = Bundle.module.url(
            forResource: "glass-theme",
            withExtension: "css",
            subdirectory: "Widgets"
        ) else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

struct WidgetHostView: NSViewRepresentable {
    let module: CollectorModule
    let artifact: JSONValue?
    let state: WidgetDisplayState
    var theme: AppTheme = .classic

    func makeCoordinator() -> Coordinator {
        Coordinator(module: module)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let bootstrap = try? BundledWidgetResources.bootstrapSource() {
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: bootstrap,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true,
                    in: .page
                )
            )
        }

        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        context.coordinator.attach(webView)
        applyTransparency(to: webView)

        do {
            let pageURL = try BundledWidgetResources.pageURL(for: module)
            context.coordinator.configureResourceRoot(
                pageURL.deletingLastPathComponent()
            )
            webView.loadFileURL(
                pageURL,
                allowingReadAccessTo: pageURL.deletingLastPathComponent()
            )
        } catch {
            webView.loadHTMLString(
                """
                <!doctype html><meta charset="utf-8">
                <body style="font:13px system-ui;padding:24px">
                Widget 资源不可用
                </body>
                """,
                baseURL: nil
            )
        }
        context.coordinator.update(artifact: artifact, state: state)
        context.coordinator.updateTheme(theme)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(artifact: artifact, state: state)
        context.coordinator.updateTheme(theme)
        applyTransparency(to: webView)
    }

    /// 液态玻璃 + macOS 26 时让 webView 透明, 露出下方的玻璃垫层.
    /// macOS 上 WKWebView 没有可写的 isOpaque / backgroundColor,
    /// 用 drawsBackground KVC 实现 (降级点, 文档外键值).
    private func applyTransparency(to webView: WKWebView) {
        let transparent = GlassTheme.usesGlass(theme)
        webView.setValue(!transparent, forKey: "drawsBackground")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let module: CollectorModule
        private let validator = ArtifactValidator()
        private weak var webView: WKWebView?
        private var securityPolicy: WidgetSecurityPolicy?
        private var pageLoaded = false
        private var pendingArtifact: JSONValue?
        private var pendingState: WidgetDisplayState = .loading
        /// 最近一次下发的主题, 页面加载完成后注入, 之后变化即时同步.
        private var pendingTheme: AppTheme = .classic
        private var appliedTheme: AppTheme?

        init(module: CollectorModule) {
            self.module = module
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
        }

        func configureResourceRoot(_ url: URL) {
            securityPolicy = WidgetSecurityPolicy(resourceRoot: url)
        }

        func update(
            artifact: JSONValue?,
            state: WidgetDisplayState
        ) {
            pendingArtifact = artifact
            pendingState = state
            publishIfReady()
        }

        func updateTheme(_ theme: AppTheme) {
            pendingTheme = theme
            applyThemeIfReady()
        }

        func webView(
            _ webView: WKWebView,
            didFinish navigation: WKNavigation!
        ) {
            pageLoaded = true
            publishIfReady()
            applyThemeIfReady()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationActionPolicy
            ) -> Void
        ) {
            let allowed: Bool
            if let securityPolicy {
                allowed = securityPolicy.allows(
                    navigationAction.request.url
                )
            } else {
                allowed = navigationAction.request.url?.absoluteString
                    == "about:blank"
            }
            decisionHandler(allowed ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        /// 页面加载完成后把当前主题下发到 bootstrap 的 __mdddSetTheme.
        /// 玻璃主题 CSS 文本由原生侧读入传入, 避免 loadFileURL 读取范围限制.
        private func applyThemeIfReady() {
            guard pageLoaded, let webView else { return }
            let theme = GlassTheme.resolved(pendingTheme)
            guard theme != appliedTheme else { return }
            appliedTheme = theme
            let css = theme == .liquidGlass
                ? BundledWidgetResources.glassThemeCSS() ?? ""
                : ""
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "window.__mdddSetTheme(name, cssText)",
                    arguments: [
                        "name": theme.widgetThemeName,
                        "cssText": css,
                    ],
                    in: nil,
                    contentWorld: .page
                )
            }
        }

        private func publishIfReady() {
            guard pageLoaded, let webView else { return }
            var foundationArtifact: Any = NSNull()
            var resolvedState = pendingState
            if let pendingArtifact {
                do {
                    _ = try validator.validate(
                        pendingArtifact,
                        for: module
                    )
                    let data = try JSONEncoder().encode(pendingArtifact)
                    foundationArtifact = try JSONSerialization.jsonObject(
                        with: data
                    )
                } catch {
                    resolvedState = .error
                }
            }
            Task { @MainActor in
                _ = try? await webView.callAsyncJavaScript(
                    "window.__mdddUpdate(artifact, state)",
                    arguments: [
                        "artifact": foundationArtifact,
                        "state": resolvedState.rawValue,
                    ],
                    in: nil,
                    contentWorld: .page
                )
            }
        }
    }
}
