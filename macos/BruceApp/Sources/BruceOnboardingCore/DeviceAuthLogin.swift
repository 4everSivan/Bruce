import Foundation

// MARK: - DeviceAuthError

/// 设备码登录的可诊断错误. description 面向用户, 不含 code 和 token 值.
public enum DeviceAuthError: Error, Equatable, CustomStringConvertible {
    /// DNS, TLS 或超时等网络错误
    case networkUnreachable
    /// 服务返回非预期 HTTP 状态码
    case httpError(statusCode: Int)
    /// 响应非 JSON 或缺少必需字段
    case invalidResponse(String)
    /// 用户在浏览器拒绝授权
    case authorizationDenied
    /// 等待授权超时 (设备码过期)
    case authorizationExpired
    /// 用户取消或调用方任务被取消
    case cancelled

    public var description: String {
        switch self {
        case .networkUnreachable:
            return "网络不可达"
        case .httpError(let statusCode):
            return "服务返回 HTTP \(statusCode)"
        case .invalidResponse(let detail):
            return "服务响应无效: \(detail)"
        case .authorizationDenied:
            return "授权被拒绝"
        case .authorizationExpired:
            return "等待授权超时"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - DeviceAuthorization

/// 设备码授权的起始信息: 用户验证码, 验证页 URL 和轮询参数.
public struct DeviceAuthorization: Equatable, Sendable {
    /// 服务端下发的设备凭证 (Codex device_auth_id).
    public let deviceCode: String
    /// 用户在验证页输入的一次性验证码.
    public let userCode: String
    public let verificationURL: URL
    /// 服务端建议的轮询间隔 (秒).
    public let interval: TimeInterval
    /// 设备码有效期 (秒), 同时作为整体等待授权的超时.
    public let expiresIn: TimeInterval

    public init(
        deviceCode: String,
        userCode: String,
        verificationURL: URL,
        interval: TimeInterval,
        expiresIn: TimeInterval
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.interval = interval
        self.expiresIn = expiresIn
    }
}

// MARK: - DeviceFlowHTTP

/// 设备码流程共享的 HTTP 工具: 表单编码, JSON 解析和默认 session.
/// 默认 session 为 ephemeral, 无 Cookie 和缓存; 请求体不含凭证头,
/// code/token 只存在于本次内存会话.
enum DeviceFlowHTTP {
    static let requestTimeout: TimeInterval = 15

    static func defaultSession() -> any URLSessionProtocol {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// 严格按 RFC 3986 unreserved 字符集编码, token 等值中的特殊字符
    /// (: / + =) 一律转义, 保证表单解析方拿到原文.
    static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// application/x-www-form-urlencoded 请求体.
    static func formBody(_ fields: [String: String]) -> Data {
        let body = fields
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    static func jsonObject(from data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// 发送请求并返回 (body, HTTP 状态码); 非 HTTP 响应视为无效响应.
    static func send(
        _ request: URLRequest,
        session: any URLSessionProtocol
    ) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DeviceAuthError.invalidResponse("非 HTTP 响应")
        }
        return (data, http.statusCode)
    }
}

// MARK: - CodexPKCE

/// RFC 7636 PKCE 生成. CC Switch 设备码流程中 code_verifier 由服务端
/// 在轮询响应下发, 本地生成仅作为服务端缺省时的回落.
public enum CodexPKCE {
    /// 生成 code_verifier: 32 随机字节做 base64url (43 字符, 无填充).
    public static func codeVerifier() -> String {
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - CodexIDTokenParser

/// Codex id_token (JWT) 的只解析不验签提取: 只取展示和账号标识所需 claim.
public enum CodexIDTokenParser {
    /// base64url 解码 JWT payload 为 JSON 对象; 非法输入返回 nil.
    public static func payload(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// chatgpt 账号 id: 优先 namespaced claim
    /// "https://api.openai.com/auth".chatgpt_account_id, 其次顶层
    /// chatgpt_account_id, 最后 organizations 第一项 id; 都没有返回 nil.
    public static func accountID(of jwt: String) -> String? {
        guard let payload = payload(of: jwt) else { return nil }
        if let auth = payload["https://api.openai.com/auth"] as? [String: Any] {
            if let id = nonEmpty(auth["chatgpt_account_id"]) {
                return id
            }
        }
        if let id = nonEmpty(payload["chatgpt_account_id"]) {
            return id
        }
        if let organizations = payload["organizations"] as? [[String: Any]],
           let first = organizations.first,
           let id = nonEmpty(first["id"]) {
            return id
        }
        return nil
    }

    /// 账号邮箱 (顶层 email claim), 允许缺省.
    public static func email(of jwt: String) -> String? {
        guard let payload = payload(of: jwt) else { return nil }
        return nonEmpty(payload["email"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        let text = (value as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - CodexDeviceFlow

/// Codex 设备码登录 (与 CC Switch 提取的事实对齐):
/// 1. POST /api/accounts/deviceauth/usercode 得 device_auth_id + user_code;
/// 2. 用户在 https://auth.openai.com/codex/device 输入 user_code;
/// 3. 轮询 POST /api/accounts/deviceauth/token 得 authorization_code + code_verifier;
/// 4. PKCE 向 /oauth/token 换 id/access/refresh token;
/// 5. 从 id_token 提取 chatgpt_account_id / email, 由调用方合并进账号库.
public struct CodexDeviceFlow: Sendable {
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let userCodeURL = URL(
        string: "https://auth.openai.com/api/accounts/deviceauth/usercode"
    )!
    public static let deviceTokenURL = URL(
        string: "https://auth.openai.com/api/accounts/deviceauth/token"
    )!
    public static let oauthTokenURL = URL(
        string: "https://auth.openai.com/oauth/token"
    )!
    public static let redirectURI = "https://auth.openai.com/deviceauth/callback"
    public static let verificationURL = URL(
        string: "https://auth.openai.com/codex/device"
    )!
    /// 服务端缺省 interval 时的回落值 (秒).
    public static let defaultInterval: TimeInterval = 5
    public static let defaultExpiresIn: TimeInterval = 900

    /// 轮询成功后拿到的授权码与 PKCE verifier.
    public struct DeviceGrant: Equatable, Sendable {
        public let authorizationCode: String
        public let codeVerifier: String

        public init(authorizationCode: String, codeVerifier: String) {
            self.authorizationCode = authorizationCode
            self.codeVerifier = codeVerifier
        }
    }

    public enum PollOutcome: Equatable, Sendable {
        case pending
        case authorized(DeviceGrant)
    }

    /// 换码得到的令牌与生命周期数据. `expiresIn` 为空时由上层按
    /// JWT exp 或 1 小时回落; `receivedAt` 由调用方在收到响应时写入.
    public struct TokenSet: Equatable, Sendable {
        public let idToken: String
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: TimeInterval?
        public let receivedAt: Date

        public init(
            idToken: String,
            accessToken: String,
            refreshToken: String,
            expiresIn: TimeInterval? = nil,
            receivedAt: Date = Date()
        ) {
            self.idToken = idToken
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
            self.receivedAt = receivedAt
        }
    }

    public init() {}

    /// 设备码申请请求: POST JSON {"client_id": ...}.
    public static func startRequest() -> URLRequest {
        var request = URLRequest(
            url: userCodeURL,
            timeoutInterval: DeviceFlowHTTP.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["client_id": clientID], options: [.sortedKeys]
        )
        return request
    }

    /// 解析设备码申请响应: 200 且含 device_auth_id / user_code 才成功.
    public static func parseStartResponse(
        _ data: Data, statusCode: Int
    ) -> Result<DeviceAuthorization, DeviceAuthError> {
        guard statusCode == 200 else {
            return .failure(.httpError(statusCode: statusCode))
        }
        guard let dict = DeviceFlowHTTP.jsonObject(from: data) else {
            return .failure(.invalidResponse("设备码响应不是 JSON 对象"))
        }
        let deviceAuthID = (dict["device_auth_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let userCode = (dict["user_code"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !deviceAuthID.isEmpty, !userCode.isEmpty else {
            return .failure(.invalidResponse("缺少 device_auth_id 或 user_code"))
        }
        let interval = (dict["interval"] as? NSNumber)?.doubleValue ?? defaultInterval
        let expiresIn = (dict["expires_in"] as? NSNumber)?.doubleValue ?? defaultExpiresIn
        return .success(DeviceAuthorization(
            deviceCode: deviceAuthID,
            userCode: userCode,
            verificationURL: verificationURL,
            interval: interval,
            expiresIn: expiresIn
        ))
    }

    /// 轮询请求: POST JSON device_auth_id + user_code.
    public static func pollRequest(
        deviceAuthID: String, userCode: String
    ) -> URLRequest {
        var request = URLRequest(
            url: deviceTokenURL,
            timeoutInterval: DeviceFlowHTTP.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let payload: [String: String] = [
            "device_auth_id": deviceAuthID,
            "user_code": userCode,
        ]
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        )
        return request
    }

    /// 解析轮询响应: 200 授权完成; 403/404 仍在等待用户输入;
    /// 其余一律 fail-closed. 服务端缺省 code_verifier 时回落本地 PKCE 生成.
    public static func parsePollResponse(
        _ data: Data, statusCode: Int
    ) -> Result<PollOutcome, DeviceAuthError> {
        if statusCode == 403 || statusCode == 404 {
            return .success(.pending)
        }
        guard statusCode == 200 else {
            return .failure(.httpError(statusCode: statusCode))
        }
        guard let dict = DeviceFlowHTTP.jsonObject(from: data) else {
            return .failure(.invalidResponse("轮询响应不是 JSON 对象"))
        }
        let code = (dict["authorization_code"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            return .failure(.invalidResponse("缺少 authorization_code"))
        }
        let verifier = (dict["code_verifier"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(.authorized(DeviceGrant(
            authorizationCode: code,
            codeVerifier: verifier.isEmpty ? CodexPKCE.codeVerifier() : verifier
        )))
    }

    /// 换码请求: POST form authorization_code + PKCE code_verifier.
    public static func exchangeRequest(_ grant: DeviceGrant) -> URLRequest {
        var request = URLRequest(
            url: oauthTokenURL,
            timeoutInterval: DeviceFlowHTTP.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = DeviceFlowHTTP.formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": grant.authorizationCode,
            "redirect_uri": redirectURI,
            "code_verifier": grant.codeVerifier,
        ])
        return request
    }

    /// 解析换码响应: 200 且 id/access/refresh 三个令牌齐备才成功.
    /// `expires_in` 与收到时刻被保留, 供上层计算过期时间 (缺失时可回落).
    public static func parseTokenResponse(
        _ data: Data,
        statusCode: Int,
        receivedAt: Date = Date()
    ) -> Result<TokenSet, DeviceAuthError> {
        guard statusCode == 200 else {
            return .failure(.httpError(statusCode: statusCode))
        }
        guard let dict = DeviceFlowHTTP.jsonObject(from: data) else {
            return .failure(.invalidResponse("换码响应不是 JSON 对象"))
        }
        func token(_ key: String) -> String {
            (dict[key] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !token("id_token").isEmpty,
              !token("access_token").isEmpty,
              !token("refresh_token").isEmpty else {
            return .failure(.invalidResponse("缺少 id/access/refresh token"))
        }
        let expiresIn = (dict["expires_in"] as? NSNumber)?.doubleValue
        return .success(TokenSet(
            idToken: token("id_token"),
            accessToken: token("access_token"),
            refreshToken: token("refresh_token"),
            expiresIn: expiresIn,
            receivedAt: receivedAt
        ))
    }

    /// 发起设备码申请 (网络只由调用方的用户点击触发).
    public func start(
        session: (any URLSessionProtocol)? = nil
    ) async -> Result<DeviceAuthorization, DeviceAuthError> {
        let activeSession = session ?? DeviceFlowHTTP.defaultSession()
        do {
            let (data, statusCode) = try await DeviceFlowHTTP.send(
                Self.startRequest(), session: activeSession
            )
            return Self.parseStartResponse(data, statusCode: statusCode)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as DeviceAuthError {
            return .failure(error)
        } catch {
            return .failure(.networkUnreachable)
        }
    }

    /// 按服务端建议间隔轮询直到授权完成; 支持任务取消与过期超时.
    public func pollUntilAuthorized(
        _ authorization: DeviceAuthorization,
        session: (any URLSessionProtocol)? = nil
    ) async -> Result<DeviceGrant, DeviceAuthError> {
        let activeSession = session ?? DeviceFlowHTTP.defaultSession()
        let interval = max(authorization.interval, 0)
        let deadline = Date().addingTimeInterval(authorization.expiresIn)
        while true {
            if Task.isCancelled { return .failure(.cancelled) }
            if Date() >= deadline { return .failure(.authorizationExpired) }
            do {
                try await Task.sleep(
                    nanoseconds: UInt64(interval * 1_000_000_000)
                )
            } catch {
                return .failure(.cancelled)
            }
            if Task.isCancelled { return .failure(.cancelled) }
            let data: Data
            let statusCode: Int
            do {
                (data, statusCode) = try await DeviceFlowHTTP.send(
                    Self.pollRequest(
                        deviceAuthID: authorization.deviceCode,
                        userCode: authorization.userCode
                    ),
                    session: activeSession
                )
            } catch is CancellationError {
                return .failure(.cancelled)
            } catch let error as DeviceAuthError {
                return .failure(error)
            } catch {
                return .failure(.networkUnreachable)
            }
            switch Self.parsePollResponse(data, statusCode: statusCode) {
            case .success(.pending):
                continue
            case .success(.authorized(let grant)):
                return .success(grant)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// 换码并从 id_token 提取账号标识, 输出可合并进账号库的账号.
    /// id_token 缺 chatgpt_account_id 时 fail-closed, 不产生半成品账号.
    public func exchange(
        _ grant: DeviceGrant,
        session: (any URLSessionProtocol)? = nil
    ) async -> Result<CodexCLIAuthAccount, DeviceAuthError> {
        let activeSession = session ?? DeviceFlowHTTP.defaultSession()
        let tokens: TokenSet
        do {
            let (data, statusCode) = try await DeviceFlowHTTP.send(
                Self.exchangeRequest(grant), session: activeSession
            )
            switch Self.parseTokenResponse(
                data, statusCode: statusCode, receivedAt: Date()
            ) {
            case .failure(let error):
                return .failure(error)
            case .success(let parsed):
                tokens = parsed
            }
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch let error as DeviceAuthError {
            return .failure(error)
        } catch {
            return .failure(.networkUnreachable)
        }
        guard let accountID = CodexIDTokenParser.accountID(of: tokens.idToken) else {
            return .failure(.invalidResponse("id_token 缺少 chatgpt_account_id"))
        }
        return .success(CodexCLIAuthAccount(
            accountID: accountID,
            email: CodexIDTokenParser.email(of: tokens.idToken),
            refreshToken: tokens.refreshToken,
            accessToken: tokens.accessToken,
            idToken: tokens.idToken,
            expiresIn: tokens.expiresIn,
            receivedAt: tokens.receivedAt
        ))
    }

    /// 完整状态机: 申请 -> onAuthorization 回调展示验证码 -> 轮询 -> 换码 -> 账号.
    public func login(
        session: (any URLSessionProtocol)? = nil,
        onAuthorization: @Sendable (DeviceAuthorization) -> Void
    ) async -> Result<CodexCLIAuthAccount, DeviceAuthError> {
        switch await start(session: session) {
        case .failure(let error):
            return .failure(error)
        case .success(let authorization):
            onAuthorization(authorization)
            switch await pollUntilAuthorized(authorization, session: session) {
            case .failure(let error):
                return .failure(error)
            case .success(let grant):
                return await exchange(grant, session: session)
            }
        }
    }
}
