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

    // MARK: 订阅 provider 验证

    /// DeepSeek: GET api.deepseek.com/user/balance 试查.
    /// 200 -> ok, 401/403 -> failed(凭证无效), 其余一律 failed(fail-closed).
    /// 响应正文不读入诊断.
    public func verifyDeepSeek(
        apiKey: String,
        session: (any URLSessionProtocol)? = nil
    ) async -> SubscriptionVerificationStatus {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return .failed(reason: "API key 为空")
        }

        let apiURL = URL(string: "https://api.deepseek.com/user/balance")!
        var request = URLRequest(url: apiURL, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let activeSession: any URLSessionProtocol
        if let session {
            activeSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            let guardDelegate = GitLabRedirectGuard(
                trustedHost: "api.deepseek.com"
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
                return .failed(reason: "服务响应无效")
            }
            switch http.statusCode {
            case 200:
                return .ok
            case 401, 403:
                return .failed(reason: "API key 无效或已过期")
            default:
                return .failed(reason: "服务返回 HTTP \(http.statusCode)")
            }
        } catch {
            // 网络错误与取消统一 fail-closed, 保留可重试语义
            return .failed(reason: "网络不可达")
        }
    }

    /// Kimi 浏览器令牌 JSON 结构校验: access_token/refresh_token 非空.
    /// 无 refresh_token 时 access 过期后无法续期, 判定为需要重新登录.
    /// 真实额度查询由 collector 完成, 此处不发网络请求.
    public static func verifyKimiWebTokensJSON(_ json: String) -> SubscriptionVerificationStatus {
        guard let dict = jsonObject(from: json) else {
            return .failed(reason: "凭证不是有效 JSON 对象")
        }
        let access = (dict["access_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = (dict["refresh_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if access.isEmpty && refresh.isEmpty {
            return .failed(reason: "缺少 access_token 和 refresh_token")
        }
        if refresh.isEmpty {
            return .needsRelogin
        }
        return .ok
    }

    /// Codex 账号库 JSON 结构校验 (CC Switch 同构):
    /// accounts 非空, 每账号 refresh_token 与 access_token 非空
    /// (collector 刷新与展示只消费这两个字段; email/id_token 允许缺省).
    public static func verifyCodexAccountsJSON(_ json: String) -> SubscriptionVerificationStatus {
        guard let dict = jsonObject(from: json),
              let accounts = dict["accounts"] as? [String: Any],
              !accounts.isEmpty else {
            return .failed(reason: "缺少 accounts 账号表")
        }
        for (accountID, entry) in accounts {
            guard let account = entry as? [String: Any] else {
                return .failed(reason: "账号 \(accountID) 结构无效")
            }
            let refresh = (account["refresh_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let access = (account["access_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if refresh.isEmpty {
                return .failed(reason: "账号 \(accountID) 缺少 refresh_token")
            }
            if access.isEmpty {
                return .failed(reason: "账号 \(accountID) 缺少 access_token")
            }
        }
        return .ok
    }

    /// Antigravity 令牌文件同构 JSON 结构校验:
    /// token.refresh_token 非空 (access_token 可由 collector 刷新恢复).
    public static func verifyAntigravityOAuthJSON(_ json: String) -> SubscriptionVerificationStatus {
        guard let dict = jsonObject(from: json),
              let token = dict["token"] as? [String: Any] else {
            return .failed(reason: "缺少 token 节点")
        }
        let refresh = (token["refresh_token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty else {
            return .failed(reason: "缺少 refresh_token")
        }
        return .ok
    }

    /// 火山引擎 AK/SK 本地格式校验: 非空, 去首尾空白后不含空白字符.
    /// 完整的 HMAC 签名试查由 collector 运行时完成
    /// (签名实现已自包含于 collect_usage.py), 本阶段不做网络验证.
    public static func verifyVolcengineCredentials(
        accessKey: String,
        secretKey: String
    ) -> SubscriptionVerificationStatus {
        let ak = accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty else {
            return .failed(reason: "AccessKey 为空")
        }
        guard !sk.isEmpty else {
            return .failed(reason: "SecretKey 为空")
        }
        guard !ak.contains(where: { $0.isWhitespace }), ak.count >= 8 else {
            return .failed(reason: "AccessKey 格式不合理")
        }
        guard !sk.contains(where: { $0.isWhitespace }), sk.count >= 8 else {
            return .failed(reason: "SecretKey 格式不合理")
        }
        return .ok
    }

    /// 解析凭证 JSON 字符串为对象; 非对象或解析失败返回 nil.
    private static func jsonObject(from json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }
}
