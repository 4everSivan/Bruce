import Foundation

// MARK: - URLSessionProtocol

/// 可注入的 URLSession 协议, 便于测试替换网络边界.
public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

// MARK: - GitLabRedirectPolicy

/// GitLab 重定向策略: 只允许同 host 重定向, 跨 host 重定向一律拒绝,
/// 防止 PAT 被转发到不受信任的 host.
public enum GitLabRedirectPolicy {
    public static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        guard let originalHost = original.host?.lowercased(),
              let targetHost = target.host?.lowercased(),
              !originalHost.isEmpty, !targetHost.isEmpty else {
            return false
        }
        return originalHost == targetHost
    }
}

/// URLSession delegate: 按 GitLabRedirectPolicy 拦截跨 host 重定向.
/// 拒绝时 completionHandler(nil), 请求以 3xx 响应结束, PAT 不转发.
private final class GitLabRedirectGuard: NSObject, URLSessionTaskDelegate {
    let trustedHost: String

    init(trustedHost: String) {
        self.trustedHost = trustedHost.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              let targetHost = target.host?.lowercased(),
              targetHost == trustedHost else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - ProviderConnectionVerifier

/// 外部连接验证. 与本机扫描分离, 只能由用户主动操作或既有授权触发.
/// GitHub 复用 gh 官方登录态, 不调用 gh auth token, 不使用 --show-token.
/// GitLab 使用 HTTPS base URL + PAT 验证 /api/v4/user.
/// 原始 CLI 输出, 响应正文和 header 不进入日志或诊断.
public struct ProviderConnectionVerifier: Sendable {
    private let statusProbe: AsyncProcessProbe
    private let loginProbe: AsyncProcessProbe
    private let requestTimeout: TimeInterval

    public init(
        statusTimeout: TimeInterval = 10,
        loginTimeout: TimeInterval = 300,
        requestTimeout: TimeInterval = 15
    ) {
        self.statusProbe = AsyncProcessProbe(timeout: statusTimeout)
        // 登录是交互流程, 使用独立的更长超时
        self.loginProbe = AsyncProcessProbe(timeout: loginTimeout)
        self.requestTimeout = requestTimeout
    }

    // MARK: GitHub

    /// 检查 gh 当前登录态.
    /// hasConnectedBefore 区分从未授权 (pendingAuthorization) 和授权失效 (expired).
    public func checkGitHubStatus(
        ghPath: String,
        hasConnectedBefore: Bool
    ) async -> ConnectionStatus {
        let result = await statusProbe.run(
            executablePath: ghPath,
            arguments: ["auth", "status", "--active", "--hostname", "github.com"]
        )
        switch result {
        case .success:
            return .connected
        case .cancelled:
            return .notChecked
        case .nonZeroExit, .timedOut, .launchFailed:
            return hasConnectedBefore ? .expired : .pendingAuthorization
        }
    }

    /// 通过 gh 官方 web 流程登录. 支持调用方取消, 使用独立交互超时.
    /// 一次性设备码和 CLI 原始输出只存在于本次进程会话, 不写日志.
    public func loginGitHub(ghPath: String) async -> ConnectionStatus {
        let result = await loginProbe.run(
            executablePath: ghPath,
            arguments: ["auth", "login", "--web", "--hostname", "github.com"]
        )
        switch result {
        case .success:
            return .connected
        case .cancelled, .timedOut:
            // 用户取消或交互超时: 保持未连接
            return .notChecked
        case .nonZeroExit, .launchFailed:
            return .pendingAuthorization
        }
    }

    // MARK: GitLab URL 校验

    /// 校验并规范化 GitLab base URL.
    /// 要求 HTTPS, 不允许用户名, 密码, query 和 fragment;
    /// 规范化 host 小写和尾部斜杠. 非法输入返回 nil.
    public static func normalizedGitLabBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed) else {
            return nil
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        guard components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return nil
        }
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = host
        normalized.port = components.port
        // 去掉路径尾部斜杠
        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        normalized.path = path
        return normalized.url
    }

    // MARK: GitLab PAT 验证

    /// 用 PAT 请求同 host 的 /api/v4/user.
    /// 默认创建 ephemeral, 无持久 Cookie 的 URLSession, 并拒绝跨 host 重定向.
    /// 分类: 200 -> connected, 401/403 -> expired, 网络错误 -> unreachable.
    /// 响应正文和 header 不读入诊断.
    public func verifyGitLab(
        baseURL: URL,
        pat: String,
        session: (any URLSessionProtocol)? = nil
    ) async -> ConnectionStatus {
        guard !Task.isCancelled else { return .notChecked }

        let apiURL = baseURL.appendingPathComponent("api/v4/user")
        var request = URLRequest(url: apiURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue(pat, forHTTPHeaderField: "PRIVATE-TOKEN")

        let activeSession: any URLSessionProtocol
        if let session {
            activeSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let guardDelegate = GitLabRedirectGuard(
                trustedHost: baseURL.host ?? ""
            )
            activeSession = URLSession(
                configuration: configuration,
                delegate: guardDelegate,
                delegateQueue: nil
            )
        }

        do {
            let (_, response) = try await activeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable
            }
            switch http.statusCode {
            case 200:
                return .connected
            case 401, 403:
                return .expired
            default:
                // 包括被拒绝的跨 host 重定向留下的 3xx: 不视为已连接, 保留可重试语义
                return .unreachable
            }
        } catch is CancellationError {
            return .notChecked
        } catch {
            // DNS, VPN, TLS, 超时等网络错误
            return .unreachable
        }
    }
}
