import BruceAppCore
import BruceOnboardingCore
import SwiftUI
import WebKit

/// StepFun 站点类型
public enum StepFunSite: String, CaseIterable, Identifiable, Sendable {
    case domestic = "domestic"
    case global = "global"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .domestic: return "🇨🇳 国内站"
        case .global: return "🌐 国际站"
        }
    }

    public var domainKeyword: String {
        switch self {
        case .domestic: return "stepfun.com"
        case .global: return "stepfun.ai"
        }
    }

    /// 订阅/额度管理页面（国内为 /step-plan，国际站为 /plan-subscribe）
    public var baseURL: URL {
        switch self {
        case .domestic: return URL(string: "https://platform.stepfun.com/step-plan")!
        case .global: return URL(string: "https://platform.stepfun.ai/plan-subscribe")!
        }
    }

    /// 平台官网首页
    public var homeURL: URL {
        switch self {
        case .domestic: return URL(string: "https://platform.stepfun.com")!
        case .global: return URL(string: "https://platform.stepfun.ai")!
        }
    }
}

enum StepFunWebAction: Equatable {
    case none
    case goBack
    case goForward
    case reload
    case loadURL(URL)
}

/// StepFun (Step Plan) 网页登录自动捕获凭据的弹窗视图.
/// 内置系统原生 WKWebView, 支持国内站与国际站切换，支持自动监听与手动点击提取双轨.
struct StepFunWebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let initialSite: StepFunSite
    let onTokenCaptured: (String, StepFunSite) -> Void

    @State private var selectedSite: StepFunSite
    @State private var isLoading = true
    @State private var hasCaptured = false
    @State private var statusText: String
    @State private var manualTrigger = false
    @State private var clearSessionTrigger = false
    @State private var webAction: StepFunWebAction = .none
    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var currentURLString = ""

    init(initialSite: StepFunSite = .domestic, onTokenCaptured: @escaping (String, StepFunSite) -> Void) {
        self.initialSite = initialSite
        self.onTokenCaptured = onTokenCaptured
        _selectedSite = State(initialValue: initialSite)
        _statusText = State(initialValue: "正在加载 \(initialSite.displayName) 登录页面...")
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("登录阶跃星辰开放平台 · \(selectedSite.displayName)")
                            .font(.system(size: 14, weight: .semibold))
                        if hasCaptured {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.system(size: 13))
                        }
                    }
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(hasCaptured ? .green : .secondary)
                }
                Spacer()
                Picker("站点", selection: $selectedSite) {
                    ForEach(StepFunSite.allCases) { site in
                        Text(site.displayName).tag(site)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .disabled(hasCaptured)

                if isLoading && !hasCaptured {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("取消") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // 网页操作快捷工具栏 (后退/前进/刷新/订阅页/平台首页直达)
            HStack(spacing: 10) {
                Button {
                    webAction = .goBack
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!canGoBack || hasCaptured)
                .help("后退")

                Button {
                    webAction = .goForward
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!canGoForward || hasCaptured)
                .help("前进")

                Button {
                    webAction = .reload
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(hasCaptured)
                .help("刷新页面")

                Divider()
                    .frame(height: 12)

                Button {
                    webAction = .loadURL(selectedSite.baseURL)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "creditcard")
                        Text(selectedSite == .global ? "订阅页 (/plan-subscribe)" : "订阅页 (/step-plan)")
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(hasCaptured)
                .help("直达 Step Plan 订阅页面")

                Button {
                    webAction = .loadURL(selectedSite.homeURL)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "house")
                        Text(selectedSite == .global ? "平台首页 (stepfun.ai)" : "平台首页 (stepfun.com)")
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(hasCaptured)
                .help("直达开放平台首页")

                Spacer()

                if !currentURLString.isEmpty {
                    Text(currentURLString)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            // WebKit WebView 包装容器
            StepFunWKWebViewWrapper(
                selectedSite: $selectedSite,
                isLoading: $isLoading,
                hasCaptured: $hasCaptured,
                statusText: $statusText,
                manualTrigger: $manualTrigger,
                clearSessionTrigger: $clearSessionTrigger,
                webAction: $webAction,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                currentURLString: $currentURLString,
                onTokenCaptured: { token, site in
                    onTokenCaptured(token, site)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        dismiss()
                    }
                }
            )

            Divider()

            // 底部操作栏: 提供手动提取按钮与退出登录按钮
            HStack(spacing: 12) {
                Button(role: .destructive) {
                    clearSessionTrigger = true
                } label: {
                    Label("清除登录缓存", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .disabled(hasCaptured || isLoading)
                .help("退出当前站点的网页登录态，重新登录新账号")

                Spacer()

                Button {
                    manualTrigger = true
                } label: {
                    Label("我已登录，立即绑定", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(hasCaptured)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 640, idealHeight: 700)
    }
}

private struct StepFunWKWebViewWrapper: NSViewRepresentable {
    @Binding var selectedSite: StepFunSite
    @Binding var isLoading: Bool
    @Binding var hasCaptured: Bool
    @Binding var statusText: String
    @Binding var manualTrigger: Bool
    @Binding var clearSessionTrigger: Bool
    @Binding var webAction: StepFunWebAction
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var currentURLString: String
    let onTokenCaptured: (String, StepFunSite) -> Void

    @MainActor
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.currentWebView = webView

        let cookieStore = config.websiteDataStore.httpCookieStore
        cookieStore.add(context.coordinator)
        context.coordinator.cookieStore = cookieStore

        // 桌面 Safari User-Agent
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

        context.coordinator.currentLoadedSite = selectedSite
        webView.load(URLRequest(url: selectedSite.baseURL))
        context.coordinator.startPeriodicCheck()

        return webView
    }

    @MainActor
    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.currentLoadedSite != selectedSite {
            context.coordinator.currentLoadedSite = selectedSite
            isLoading = true
            statusText = "正在加载 \(selectedSite.displayName)..."
            nsView.load(URLRequest(url: selectedSite.baseURL))
        }
        if clearSessionTrigger {
            clearSessionTrigger = false
            context.coordinator.clearSessionAndReload()
        }
        if manualTrigger {
            manualTrigger = false
            context.coordinator.performManualExtraction()
        }
        switch webAction {
        case .goBack:
            nsView.goBack()
        case .goForward:
            nsView.goForward()
        case .reload:
            nsView.reload()
        case .loadURL(let url):
            nsView.load(URLRequest(url: url))
        case .none:
            break
        }
        if webAction != .none {
            DispatchQueue.main.async {
                webAction = .none
            }
        }
    }

    @MainActor
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        coordinator.cleanup()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let parent: StepFunWKWebViewWrapper
        weak var currentWebView: WKWebView?
        weak var cookieStore: WKHTTPCookieStore?
        var currentLoadedSite: StepFunSite = .domestic
        private var timer: Timer?

        init(parent: StepFunWKWebViewWrapper) {
            self.parent = parent
            super.init()
        }

        func startPeriodicCheck() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.checkAutoCapture()
                }
            }
        }

        func stopPeriodicCheck() {
            timer?.invalidate()
            timer = nil
        }

        func cleanup() {
            stopPeriodicCheck()
            cookieStore?.remove(self)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.currentURLString = webView.url?.absoluteString ?? ""
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.currentURLString = webView.url?.absoluteString ?? ""
            checkAutoCapture()
        }

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                self.checkAutoCapture()
            }
        }

        /// 自动捕获: 当 CookieStore 中产生有效凭据且通过远程校验时触发
        func checkAutoCapture() {
            guard !parent.hasCaptured else { return }
            guard let urlString = currentWebView?.url?.absoluteString else { return }

            if urlString.contains("_not-found") {
                return
            }

            // 严格要求当前 Web 页面属于当前目标站点域名
            let targetKeyword = parent.selectedSite.domainKeyword
            guard urlString.contains(targetKeyword) else {
                return
            }

            extractTokenAndSubmit(
                successPrompt: "检测到 \(parent.selectedSite.displayName) 登录完成，已提取 Oasis-Token",
                isManual: false
            )
        }

        /// 手动点击提取: 无论当前页面路径，只要 CookieStore 中有目标站点的 Oasis-Token 即提取并验证
        func performManualExtraction() {
            guard !parent.hasCaptured else { return }
            extractTokenAndSubmit(
                successPrompt: "已成功提取当前 \(parent.selectedSite.displayName) Oasis-Token，正在绑定...",
                isManual: true
            )
        }

        /// 清理当前站点的登录 Cookie 并重新加载
        func clearSessionAndReload() {
            guard let cookieStore = cookieStore else { return }
            let targetKeyword = parent.selectedSite.domainKeyword
            cookieStore.getAllCookies { [weak self] cookies in
                Task { @MainActor in
                    guard let self = self else { return }
                    for cookie in cookies {
                        if cookie.domain.lowercased().contains(targetKeyword) {
                            cookieStore.delete(cookie, completionHandler: nil)
                        }
                    }
                    self.parent.statusText = "已清空 \(self.parent.selectedSite.displayName) 登录缓存，正在刷新..."
                    self.parent.isLoading = true
                    self.currentWebView?.load(URLRequest(url: self.parent.selectedSite.baseURL))
                }
            }
        }

        private var isValidating = false

        private func extractTokenAndSubmit(successPrompt: String, isManual: Bool = false) {
            guard !isValidating else { return }
            let targetSite = parent.selectedSite
            let targetKeyword = targetSite.domainKeyword

            cookieStore?.getAllCookies { [weak self] cookies in
                Task { @MainActor in
                    guard let self = self, !self.parent.hasCaptured, !self.isValidating else { return }

                    for cookie in cookies {
                        guard cookie.name == "Oasis-Token" else { continue }
                        let domain = cookie.domain.lowercased()
                        // 1. 严格过滤 Cookie 域名: 国内站只提取 stepfun.com, 国际站只提取 stepfun.ai
                        guard domain.contains(targetKeyword) else { continue }

                        let val = cookie.value.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !val.isEmpty && val.count > 10 else { continue }

                        self.isValidating = true
                        self.parent.statusText = "正在连接 \(targetSite.displayName) 验证凭证有效性..."
                        self.verifyTokenWithRemote(
                            token: val,
                            site: targetSite,
                            successPrompt: successPrompt,
                            isManual: isManual
                        )
                        return
                    }

                    if isManual {
                        self.parent.statusText = "未在当前 \(targetSite.displayName) 会话中检测到有效 Oasis-Token，请确认已在网页中登录"
                    }
                }
            }
        }

        private func verifyTokenWithRemote(
            token: String,
            site: StepFunSite,
            successPrompt: String,
            isManual: Bool
        ) {
            Task {
                let isValid = await StepFunRemoteVerifier.verify(token: token, site: site)
                await MainActor.run {
                    self.isValidating = false
                    // 如果在验证等待期间用户切换了站点，则丢弃过时结果
                    guard self.parent.selectedSite == site else { return }

                    if isValid {
                        self.parent.hasCaptured = true
                        self.parent.statusText = "🎉 " + successPrompt
                        self.stopPeriodicCheck()
                        self.parent.onTokenCaptured(token, site)
                    } else {
                        if isManual {
                            self.parent.statusText = "\(site.displayName) 凭据校验未通过 (401 被拒绝)，请确保已在网页中完成登录并进入控制台"
                        } else {
                            self.parent.statusText = "等待 \(site.displayName) 登录完成中..."
                        }
                    }
                }
            }
        }
    }
}

/// StepFun Step Plan 凭证真实验证工具
enum StepFunRemoteVerifier {
    static func extractDeviceID(from token: String) -> String? {
        let parts = token.components(separatedBy: "...")
        guard let targetJWT = parts.last ?? parts.first else { return nil }
        let jwtParts = targetJWT.components(separatedBy: ".")
        guard jwtParts.count >= 2 else { return nil }
        var payloadB64 = jwtParts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payloadB64.count % 4 != 0 {
            payloadB64.append("=")
        }
        guard let data = Data(base64Encoded: payloadB64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let did = json["device_id"] as? String else {
            return nil
        }
        return did
    }

    static func verify(token: String, site: StepFunSite? = nil) async -> Bool {
        let isGlobal = (site == .global) || ProviderConnectionVerifier.isStepFunGlobalToken(token)
        let endpoint = isGlobal
            ? "https://platform.stepfun.ai/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
            : "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
        let origin = isGlobal ? "https://platform.stepfun.ai" : "https://platform.stepfun.com"
        let referer = isGlobal ? "https://platform.stepfun.ai/" : "https://platform.stepfun.com/"
        let appID = (isGlobal && ProviderConnectionVerifier.extractStepFunAppID(from: token) == 20700) ? "20700" : "10300"

        guard let url = URL(string: endpoint) else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(origin, forHTTPHeaderField: "Origin")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue(token, forHTTPHeaderField: "Oasis-Token")
        req.setValue(appID, forHTTPHeaderField: "Oasis-appID")
        req.setValue("web", forHTTPHeaderField: "Oasis-Platform")
        req.setValue(isGlobal ? "en-US" : "zh-CN", forHTTPHeaderField: "Oasis-Language")
        req.setValue("Oasis-Token=\(token)", forHTTPHeaderField: "Cookie")
        if let did = extractDeviceID(from: token) {
            req.setValue(did, forHTTPHeaderField: "Oasis-Webid")
        }
        req.httpBody = "{}".data(using: .utf8)
        req.timeoutInterval = 8

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}
