import Foundation

// MARK: - CodexOAuthClientError

/// OAuth 请求的可分类错误. description 面向用户, 不含响应体或 token 值.
public enum CodexOAuthClientError: Error, Equatable, CustomStringConvertible {
    case networkUnreachable
    case httpStatus(Int)
    case invalidGrant
    case rateLimit(retryAfter: TimeInterval?)
    case serverError(Int)
    case invalidResponse(String)
    case cancelled

    public var description: String {
        switch self {
        case .networkUnreachable:
            return "网络不可达"
        case .httpStatus(let statusCode):
            return "服务返回 HTTP \(statusCode)"
        case .invalidGrant:
            return "授权已失效"
        case .rateLimit:
            return "请求过于频繁"
        case .serverError(let statusCode):
            return "服务暂时不可用 (HTTP \(statusCode))"
        case .invalidResponse(let detail):
            return "服务响应无效: \(detail)"
        case .cancelled:
            return "已取消"
        }
    }
}

// MARK: - CodexTokenResponse

/// OAuth 换码/刷新响应. `expiresIn` 为空时由调用方按 JWT exp 或 1 小时回落.
public struct CodexTokenResponse: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let expiresIn: TimeInterval?
    public let receivedAt: Date

    public init(
        accessToken: String,
        refreshToken: String?,
        idToken: String?,
        expiresIn: TimeInterval?,
        receivedAt: Date
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.receivedAt = receivedAt
    }
}

// MARK: - CodexOAuthClientProtocol

/// OAuth 客户端协议边界: 测试可注入 fake, 生产使用 `CodexOAuthClient`.
public protocol CodexOAuthClientProtocol: Sendable {
    func refreshRequest(refreshToken: String) -> URLRequest
    func perform(
        _ request: URLRequest,
        session: (any URLSessionProtocol)?
    ) async -> Result<CodexTokenResponse, CodexOAuthClientError>
}

// MARK: - CodexOAuthClient

/// Codex OAuth 请求客户端: 构建并执行换码/刷新请求, 分类错误, 计算过期时间.
/// 不持有账号状态, 不操作 Keychain. 客户端不输出响应体 (响应体可能含 token).
public struct CodexOAuthClient: CodexOAuthClientProtocol, Sendable {
    /// 换码/刷新响应的密钥字段 (OAuth 标准 + Codex 扩展).
    public enum TokenField: String {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
        case error = "error"
        case errorDescription = "error_description"
    }

    /// 客户端凭证. 与 CodexDeviceFlow.clientID 对齐, 只用于 OAuth 请求.
    public struct ClientConfiguration: Sendable, Equatable {
        public let clientID: String
        public let tokenURL: URL

        public init(clientID: String, tokenURL: URL) {
            self.clientID = clientID
            self.tokenURL = tokenURL
        }
    }

    private let configuration: ClientConfiguration
    private let session: any URLSessionProtocol
    /// 收到响应时的时钟 (测试可替换).
    private let clock: @Sendable () -> Date

    public init(
        configuration: ClientConfiguration,
        session: (any URLSessionProtocol)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.session = session ?? DeviceFlowHTTP.defaultSession()
        self.clock = clock
    }

    public static func defaultConfiguration() -> ClientConfiguration {
        ClientConfiguration(
            clientID: CodexDeviceFlow.clientID,
            tokenURL: CodexDeviceFlow.oauthTokenURL
        )
    }

    /// 生产默认客户端 (系统 URLSession, 实时时钟).
    public static func defaultClient() -> CodexOAuthClient {
        CodexOAuthClient(configuration: defaultConfiguration())
    }

    // MARK: 请求构建

    private func formRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(
            url: configuration.tokenURL,
            timeoutInterval: DeviceFlowHTTP.requestTimeout
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = DeviceFlowHTTP.formBody(fields)
        return request
    }

    public func exchangeRequest(_ grant: CodexDeviceFlow.DeviceGrant) -> URLRequest {
        formRequest([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": grant.authorizationCode,
            "redirect_uri": CodexDeviceFlow.redirectURI,
            "code_verifier": grant.codeVerifier,
        ])
    }

    public func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest([
            "grant_type": "refresh_token",
            "client_id": configuration.clientID,
            "refresh_token": refreshToken,
        ])
    }
    // MARK: 请求执行与错误分类

    /// 执行 OAuth 请求并解析为 token 响应.
    /// - 响应体只用于字段解析, 不进入任何错误文本或日志.
    /// - OAuth `invalid_grant` 与 HTTP 401/403 分类为授权失效;
    ///   429 解析 `Retry-After`; 5xx 分类为服务端错误.
    public func perform(
        _ request: URLRequest,
        session: (any URLSessionProtocol)? = nil
    ) async -> Result<CodexTokenResponse, CodexOAuthClientError> {
        let activeSession = session ?? self.session
        let data: Data
        let statusCode: Int
        let retryAfter: TimeInterval?
        do {
            let (body, response) = try await activeSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.invalidResponse("非 HTTP 响应"))
            }
            data = body
            statusCode = http.statusCode
            retryAfter = Self.retryAfterInterval(from: http)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.networkUnreachable)
        }

        guard statusCode == 200 else {
            return Self.classifyError(
                statusCode: statusCode,
                data: data,
                retryAfter: retryAfter
            )
        }
        guard let dict = DeviceFlowHTTP.jsonObject(from: data) else {
            return .failure(.invalidResponse("响应不是 JSON 对象"))
        }
        let access = (dict[TokenField.accessToken.rawValue] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else {
            return .failure(.invalidResponse("缺少 access_token"))
        }
        let refresh = (dict[TokenField.refreshToken.rawValue] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let idToken = (dict[TokenField.idToken.rawValue] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expiresIn = (dict[TokenField.expiresIn.rawValue] as? NSNumber)?
            .doubleValue
        return .success(CodexTokenResponse(
            accessToken: access,
            refreshToken: refresh.isEmpty ? nil : refresh,
            idToken: idToken.isEmpty ? nil : idToken,
            expiresIn: expiresIn,
            receivedAt: clock()
        ))
    }

    /// 从 HTTPURLResponse 解析 Retry-After (秒或 HTTP-date).
    static func retryAfterInterval(from response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        if let seconds = Double(raw), seconds >= 0 {
            return seconds
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(Date()))
    }

    private static func classifyError(
        statusCode: Int,
        data: Data,
        retryAfter: TimeInterval?
    ) -> Result<CodexTokenResponse, CodexOAuthClientError> {
        switch statusCode {
        case 400:
            if let dict = DeviceFlowHTTP.jsonObject(from: data),
               let error = dict[TokenField.error.rawValue] as? String,
               error == "invalid_grant" {
                return .failure(.invalidGrant)
            }
            return .failure(.httpStatus(statusCode))
        case 401, 403:
            return .failure(.invalidGrant)
        case 429:
            return .failure(.rateLimit(retryAfter: retryAfter))
        case 500...599:
            return .failure(.serverError(statusCode))
        default:
            return .failure(.httpStatus(statusCode))
        }
    }
}

// MARK: - 过期时间计算

/// Codex token 过期时间计算: `expires_in` 优先于 JWT `exp`, 缺失回落 1 小时.
/// 非法、负数或过去时间按立即过期处理.
public enum CodexTokenExpiry {
    /// 从 token 响应计算过期时刻.
    public static func expiresAt(
        from response: CodexTokenResponse,
        jwtExp: TimeInterval?
    ) -> Date {
        if let expiresIn = response.expiresIn, expiresIn >= 0 {
            return response.receivedAt.addingTimeInterval(expiresIn)
        }
        if let jwtExp {
            let date = Date(timeIntervalSince1970: jwtExp)
            if date > response.receivedAt {
                return date
            }
            return response.receivedAt
        }
        // 两者都缺失: 从收到时刻起回落 1 小时
        return response.receivedAt.addingTimeInterval(3600)
    }

    /// 解析 JWT payload 中的 `exp` claim (Unix 秒). 非 JWT 或缺失返回 nil.
    public static func jwtExp(of idToken: String?) -> TimeInterval? {
        guard let idToken, !idToken.isEmpty else { return nil }
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let payloadPart = String(parts[1])
        var base64 = payloadPart
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let exp = dict["exp"] as? NSNumber else {
            return nil
        }
        return exp.doubleValue
    }
}
