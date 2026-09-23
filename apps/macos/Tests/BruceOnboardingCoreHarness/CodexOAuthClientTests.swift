import Foundation
@testable import BruceOnboardingCore

// MARK: - CodexOAuthClientTests

/// 任务 3 定向验证: OAuth 客户端与过期时间计算.
enum CodexOAuthClientTests {
    static func runAll() async throws {
        try await expiresInTakesPriorityOverJWTExp()
        try await jwtExpUsedWhenExpiresInMissing()
        try await oneHourFallbackWhenBothMissing()
        try await invalidExpiryMeansImmediatelyExpired()
        try await missingNewRefreshTokenIsDetectable()
        try await errorClassification()
        try await retryAfterParsesToAbsoluteRetryTime()
        try await tokenResponseFieldsRoundTrip()
        print("CodexOAuthClient tests passed: 8")
    }

    private static let fixedNow = Date(timeIntervalSince1970: 1_752_000_000)

    private static func makeClient(
        handler: @escaping (URLRequest) throws -> (Data, URLResponse)
    ) -> CodexOAuthClient {
        CodexOAuthClient(
            configuration: CodexOAuthClient.defaultConfiguration(),
            session: MockURLSession(handler: handler),
            clock: { fixedNow }
        )
    }

    private static func tokenRequest() -> URLRequest {
        URLRequest(url: CodexOAuthClient.defaultConfiguration().tokenURL)
    }

    private static func httpResponse(status: Int, headers: [String: String] = [:])
        -> URLResponse {
        HTTPURLResponse(
            url: CodexOAuthClient.defaultConfiguration().tokenURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // 1. expires_in 优先于 JWT exp
    private static func expiresInTakesPriorityOverJWTExp() async throws {
        let client = makeClient { _ in
            (Data(#"{"access_token":"at","expires_in":7200}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        let jwtExp = fixedNow.addingTimeInterval(3600).timeIntervalSince1970
        let expiresAt = CodexTokenExpiry.expiresAt(from: token, jwtExp: jwtExp)
        let expected = fixedNow.addingTimeInterval(7200)
        guard expiresAt == expected else {
            throw CodexTestFailure.expectation(
                "expires_in 必须优先于 JWT exp, got \(expiresAt)"
            )
        }
    }

    // 2. 缺少 expires_in 时使用 JWT exp
    private static func jwtExpUsedWhenExpiresInMissing() async throws {
        let client = makeClient { _ in
            (Data(#"{"access_token":"at","refresh_token":"rt"}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        let jwtExp = fixedNow.addingTimeInterval(3600).timeIntervalSince1970
        let expiresAt = CodexTokenExpiry.expiresAt(from: token, jwtExp: jwtExp)
        guard expiresAt == fixedNow.addingTimeInterval(3600) else {
            throw CodexTestFailure.expectation(
                "JWT exp 必须被使用, got \(expiresAt)"
            )
        }
    }

    // 3. 两者都缺失时从 receivedAt 起回落 1 小时
    private static func oneHourFallbackWhenBothMissing() async throws {
        let client = makeClient { _ in
            (Data(#"{"access_token":"at"}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        let expiresAt = CodexTokenExpiry.expiresAt(from: token, jwtExp: nil)
        guard expiresAt == fixedNow.addingTimeInterval(3600) else {
            throw CodexTestFailure.expectation(
                "两缺必须回落 1 小时, got \(expiresAt)"
            )
        }
    }

    // 4. 非正数、NaN 或无穷 expires_in 视为立即过期, 不回退掩盖错误值
    private static func invalidExpiryMeansImmediatelyExpired() async throws {
        // 负数 expires_in: 立即过期 (不回退到 1 小时)
        let negativeClient = makeClient { _ in
            (Data(#"{"access_token":"at","expires_in":-5}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await negativeClient.perform(
            tokenRequest()
        ) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        let expiresAt = CodexTokenExpiry.expiresAt(from: token, jwtExp: nil)
        guard expiresAt == token.receivedAt else {
            throw CodexTestFailure.expectation(
                "负数 expires_in 必须立即过期, got \(expiresAt)"
            )
        }
        // 零 expires_in: 立即过期
        let zeroToken = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: nil,
            expiresIn: 0, receivedAt: fixedNow
        )
        guard CodexTokenExpiry.expiresAt(from: zeroToken, jwtExp: nil) == fixedNow else {
            throw CodexTestFailure.expectation("零 expires_in 必须立即过期")
        }
        // NaN expires_in: 立即过期
        let nanToken = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: nil,
            expiresIn: .nan, receivedAt: fixedNow
        )
        guard CodexTokenExpiry.expiresAt(from: nanToken, jwtExp: nil) == fixedNow else {
            throw CodexTestFailure.expectation("NaN expires_in 必须立即过期")
        }
        // 无穷 expires_in: 立即过期
        let infToken = CodexTokenResponse(
            accessToken: "at", refreshToken: nil, idToken: nil,
            expiresIn: .infinity, receivedAt: fixedNow
        )
        guard CodexTokenExpiry.expiresAt(from: infToken, jwtExp: nil) == fixedNow else {
            throw CodexTestFailure.expectation("无穷 expires_in 必须立即过期")
        }
        // 过去 JWT exp: 按立即过期
        let past = fixedNow.addingTimeInterval(-100).timeIntervalSince1970
        let pastExpiry = CodexTokenExpiry.expiresAt(from: token, jwtExp: past)
        guard pastExpiry <= token.receivedAt else {
            throw CodexTestFailure.expectation("过去 JWT exp 必须按立即过期")
        }
    }

    // 5. refresh 响应缺少新 refresh token 时旧值保留条件可被上层识别
    private static func missingNewRefreshTokenIsDetectable() async throws {
        let client = makeClient { _ in
            (Data(#"{"access_token":"at-new","expires_in":3600}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        guard token.refreshToken == nil else {
            throw CodexTestFailure.expectation("缺失 refresh_token 必须为 nil")
        }
        guard token.accessToken == "at-new" else {
            throw CodexTestFailure.expectation("access_token 解析失败")
        }
    }

    // 6. OAuth invalid_grant、HTTP 401/403、429、5xx、超时和网络错误分类
    private static func errorClassification() async throws {
        let cases: [(Int, String, CodexOAuthClientError)] = [
            (400, #"{"error":"invalid_grant"}"#, .invalidGrant),
            (401, "{}", .invalidGrant),
            (403, "{}", .invalidGrant),
            (429, "{}", .rateLimit(retryAfter: nil)),
            (500, "{}", .serverError(500)),
            (503, "{}", .serverError(503)),
        ]
        for (status, body, expected) in cases {
            let client = makeClient { _ in
                (Data(body.utf8), httpResponse(status: status))
            }
            let result = await client.perform(tokenRequest())
            guard case .failure(let error) = result, error == expected else {
                throw CodexTestFailure.expectation(
                    "HTTP \(status) 分类不符, got \(result)"
                )
            }
        }
        // 网络错误
        let networkClient = makeClient { _ in
            throw URLError(.notConnectedToInternet)
        }
        guard case .failure(.networkUnreachable) = await networkClient.perform(
            tokenRequest()
        ) else {
            throw CodexTestFailure.expectation("网络错误分类不符")
        }
        // 超时
        let timeoutClient = makeClient { _ in
            throw URLError(.timedOut)
        }
        guard case .failure(.networkUnreachable) = await timeoutClient.perform(
            tokenRequest()
        ) else {
            throw CodexTestFailure.expectation("超时分类不符")
        }
    }

    // 7. Retry-After 可解析为绝对重试时间; 响应体和 token 不进入错误文本
    private static func retryAfterParsesToAbsoluteRetryTime() async throws {
        let client = makeClient { _ in
            (Data(#"{"error":"rate_limit"}"#.utf8),
             httpResponse(status: 429, headers: ["Retry-After": "120"]))
        }
        guard case .failure(let error) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("429 应失败")
        }
        guard case .rateLimit(let retryAfter) = error, retryAfter == 120 else {
            throw CodexTestFailure.expectation("Retry-After 秒数解析失败")
        }
        guard !error.description.contains("rate_limit"),
              !error.description.contains("{}") else {
            throw CodexTestFailure.expectation("错误文本泄露响应体")
        }
    }

    // 8. token 响应字段完整往返 (access/refresh/expiresIn/receivedAt)
    private static func tokenResponseFieldsRoundTrip() async throws {
        let client = makeClient { _ in
            (Data(#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#.utf8),
             httpResponse(status: 200))
        }
        guard case .success(let token) = await client.perform(tokenRequest()) else {
            throw CodexTestFailure.expectation("perform 应成功")
        }
        guard token.accessToken == "at",
              token.refreshToken == "rt",
              token.expiresIn == 3600,
              token.receivedAt == fixedNow else {
            throw CodexTestFailure.expectation("token 响应字段解析失败")
        }
    }
}

// MARK: - 测试工具

private enum CodexTestFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

/// 可注入 URLSession fake.
private final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    let handler: (URLRequest) throws -> (Data, URLResponse)

    init(handler: @escaping (URLRequest) throws -> (Data, URLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try handler(request)
    }
}
