import Foundation
@testable import BruceAppCore

private enum RequestLogHarnessFailure: Error, CustomStringConvertible {
    case expectation(String)

    var description: String {
        switch self {
        case .expectation(let message):
            return message
        }
    }
}

private func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) throws {
    if !condition() {
        throw RequestLogHarnessFailure.expectation(message)
    }
}

@MainActor
private final class FakeProcessHandle: CollectorProcessHandling {
    func requestCancellation() {}
    func forceTerminate() {}
}

@MainActor
private final class FakeLauncher: CollectorProcessLaunching {
    var stdout = Data()
    var exitCode: Int32 = 0
    private(set) var lastInput: Data?

    func launch(
        executableURL: URL,
        arguments: [String],
        input: Data,
        completion: @escaping @MainActor (Result<CollectorProcessOutput, Error>) -> Void
    ) throws -> CollectorProcessHandling {
        lastInput = input
        let output = CollectorProcessOutput(
            stdout: stdout,
            stderr: Data(),
            exitCode: exitCode
        )
        completion(.success(output))
        return FakeProcessHandle()
    }
}

@main
struct RequestLogHarness {
    static func main() async throws {
        try await clientDecodesPage()
        try await clientMapsCollectorError()
        try await missingExecutableFailsClosed()
        try modelDecodingIsTolerantToOptionalNotice()
        print("BruceRequestLogHarness: all checks passed")
    }

    /// 客户端必须发送 module=request-log，并解析 summary/models/entries。
    @MainActor
    private static func clientDecodesPage() async throws {
        let launcher = FakeLauncher()
        launcher.stdout = Data(
            """
            {
              "schemaVersion": 1,
              "runId": "ignored",
              "generatedAt": "2026-11-19T00:00:00Z",
              "status": "success",
              "artifact": {
                "schemaVersion": 1,
                "module": "request-log",
                "generatedAt": "2026-11-19T00:00:00Z",
                "total": 1,
                "page": 0,
                "pageSize": 50,
                "summary": {"tokens": 19, "costUsd": 0.01, "avgTokens": 19},
                "models": ["claude-opus-5-5"],
                "entries": [{
                  "requestId": "abc",
                  "agentId": "claude-code",
                  "model": "claude-opus-5-5",
                  "rawModel": "claude-opus-5-5",
                  "occurredAt": 1795057200000,
                  "input": 10,
                  "output": 2,
                  "cacheRead": 3,
                  "cacheCreation": 4,
                  "costUsd": 0.01,
                  "statusCode": 200,
                  "project": "Bruce",
                  "fidelity": "exact",
                  "latencyMs": 2500,
                  "firstTokenMs": 500
                }]
              },
              "credentialUpdates": [],
              "credentialChallenges": [],
              "diagnostics": []
            }
            """.utf8
        )
        let client = RequestLogClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            launcher: launcher
        )
        let page = try await client.query(
            RequestLogQuery(
                start: 0,
                end: 2_000_000_000_000,
                agentIDs: ["claude-code"],
                page: 0,
                pageSize: 50
            )
        )
        try expect(page.total == 1, "total")
        try expect(page.entries.count == 1, "entries")
        try expect(page.entries[0].input == 10, "input")
        try expect(page.entries[0].costUsd == 0.01, "cost")
        try expect(page.entries[0].speedTokensPerSecond != nil, "speed")
        try expect(page.entries[0].speedText == "1.0/s", "speed text")
        try expect(page.effectiveSummary.tokens == 19, "summary tokens")
        try expect(page.models == ["claude-opus-5-5"], "models")

        let input = try expectUnwrap(launcher.lastInput, "request input")
        let json = try JSONSerialization.jsonObject(with: input) as? [String: Any]
        try expect(json?["module"] as? String == "request-log", "module")
        let context = json?["context"] as? [String: Any]
        try expect(context?["pageSize"] as? Int == 50, "pageSize")
        try expect(context?["agentIds"] as? [String] == ["claude-code"], "agentIds")
    }

    @MainActor
    private static func clientMapsCollectorError() async throws {
        let launcher = FakeLauncher()
        launcher.stdout = Data(
            """
            {
              "schemaVersion": 1,
              "runId": "ignored",
              "generatedAt": "2026-11-19T00:00:00Z",
              "status": "error",
              "artifact": null,
              "credentialUpdates": [],
              "credentialChallenges": [],
              "diagnostics": [{
                "code": "REQUEST_LOG_UNAVAILABLE",
                "category": "local",
                "stage": "request-log",
                "message": "请求日志库不可用",
                "retryable": true
              }]
            }
            """.utf8
        )
        let client = RequestLogClient(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            launcher: launcher
        )
        do {
            _ = try await client.query(RequestLogQuery(start: 0, end: 1_000))
            throw RequestLogHarnessFailure.expectation("error envelope should throw")
        } catch let error as RequestLogClientError {
            try expect(error == .collector("请求日志库不可用"), "collector message")
        }
    }

    @MainActor
    private static func missingExecutableFailsClosed() async throws {
        let client = RequestLogClient(executableURL: nil)
        do {
            _ = try await client.query(RequestLogQuery(start: 0, end: 1_000))
            throw RequestLogHarnessFailure.expectation("missing executable should throw")
        } catch let error as RequestLogClientError {
            try expect(error == .missingExecutable, "missing executable")
        }
    }

    /// 旧版/测试 fixture 可能没有 notice 字段；页面仍需可解码。
    private static func modelDecodingIsTolerantToOptionalNotice() throws {
        let json = Data(
            """
            {
              "total": 0,
              "page": 0,
              "pageSize": 50,
              "summary": null,
              "models": null,
              "entries": []
            }
            """.utf8
        )
        let page = try JSONDecoder().decode(RequestLogPageModel.self, from: json)
        try expect(page.total == 0, "total")
        try expect(page.notice == nil, "notice")
        try expect(page.effectiveSummary.tokens == 0, "summary")
    }

    private static func expectUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw RequestLogHarnessFailure.expectation(message)
        }
        return value
    }
}
