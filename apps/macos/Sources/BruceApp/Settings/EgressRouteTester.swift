import Foundation
import BruceOnboardingCore

/// 仅探测用户指定的回环代理端口；不携带任何订阅凭据。
///
/// 与 Collector 对齐 (C236): 主信标 3 秒；失败后退避 400ms 改用备用信标 5 秒，
/// 两次都失败才提示，并按原因区分代理不可达、代理需认证、TLS 失败与信标异常。
enum EgressRouteTester {
    private static let primaryURL = URL(string: "https://cloudflare.com/cdn-cgi/trace")!
    private static let fallbackURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!
    private static let primaryTimeout: TimeInterval = 3
    private static let fallbackTimeout: TimeInterval = 5
    private static let retryBackoffNanoseconds: UInt64 = 400_000_000

    static func test(port: UInt16, expected: String) async -> String {
        switch await attempt(url: primaryURL, port: port, timeout: primaryTimeout) {
        case .success(let text):
            return describeTrace(text, expected: expected)
        case .failure(let failure):
            guard failure.isTransient else { return failure.finalMessage }
            try? await Task.sleep(nanoseconds: retryBackoffNanoseconds)
            switch await attempt(url: fallbackURL, port: port, timeout: fallbackTimeout) {
            case .success(let text):
                return describeTrace(text, expected: expected)
            case .failure(let fallbackFailure):
                return fallbackFailure.finalMessage
            }
        }
    }

    /// 对探测响应做严格字段检查与 IP 脱敏，不返回完整地址。
    static func describeTrace(_ text: String, expected: String) -> String {
        EgressTracePresentation.describe(text, expected: expected)
    }

    private enum AttemptFailure: Error {
        case proxyUnreachable
        case proxyAuth
        case tlsFailed
        case timedOut
        case badStatus(Int)
        case generic

        /// 代理认证错误重试也不会自愈；其余失败允许备用信标再试一次。
        var isTransient: Bool {
            if case .proxyAuth = self { return false }
            return true
        }

        var finalMessage: String {
            switch self {
            case .proxyUnreachable:
                return "专用代理不可达，请确认端口已监听"
            case .proxyAuth:
                return "专用代理需要认证，当前仅支持免认证端口"
            case .tlsFailed:
                return "专用代理 TLS 连接失败"
            case .timedOut:
                return "主备信标均探测超时，请检查专用代理"
            case .badStatus(let status):
                return "出口信标返回异常（HTTP \(status)）"
            case .generic:
                return "探测失败，请检查专用代理"
            }
        }
    }

    private static func attempt(
        url: URL,
        port: UInt16,
        timeout: TimeInterval
    ) async -> Result<String, AttemptFailure> {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.connectionProxyDictionary = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
        ]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.generic)
            }
            if http.statusCode == 407 {
                return .failure(.proxyAuth)
            }
            guard http.statusCode == 200, data.count <= 4096 else {
                return .failure(.badStatus(http.statusCode))
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure(.generic)
            }
            return .success(text)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return .failure(.proxyUnreachable)
            case .timedOut:
                return .failure(.timedOut)
            case .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return .failure(.tlsFailed)
            default:
                return .failure(.generic)
            }
        } catch {
            return .failure(.generic)
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
