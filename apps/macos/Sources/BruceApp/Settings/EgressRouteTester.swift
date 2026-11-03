import Foundation
import BruceOnboardingCore

/// 仅探测用户指定的回环代理端口；不携带任何订阅凭据。
enum EgressRouteTester {
    static func test(port: UInt16, expected: String) async -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        config.connectionProxyDictionary = [
            "HTTPSEnable": 1,
            "HTTPSProxy": "127.0.0.1",
            "HTTPSPort": Int(port),
        ]
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(from: URL(string: "https://cloudflare.com/cdn-cgi/trace")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count <= 4096,
                  let text = String(data: data, encoding: .utf8) else {
                return "探测失败，请检查专用代理"
            }
            return describeTrace(text, expected: expected)
        } catch {
            return "探测失败，请检查专用代理"
        }
    }

    /// 对探测响应做严格字段检查与 IP 脱敏，不返回完整地址。
    static func describeTrace(_ text: String, expected: String) -> String {
        EgressTracePresentation.describe(text, expected: expected)
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
