import Foundation
@testable import BruceAppCore

private enum DashboardStatusToneHarnessFailure: Error, CustomStringConvertible {
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
        throw DashboardStatusToneHarnessFailure.expectation(message)
    }
}

private struct ParityFixture: Decodable {
    let cases: [ParityCase]
}

private struct ParitySubscription: Decodable {
    let status: String
    let name: String
}

private struct ParityCase: Decodable {
    let name: String
    let moduleState: String
    let subscriptions: [ParitySubscription]
    let hasData: Bool
    let detail: String?
    let expectedTone: String
    let expectedRefreshing: Bool
    let expectedReason: String
}

@main
struct DashboardStatusToneHarness {
    static func main() throws {
        let repoRoot = resolveRepoRoot()
        try verifySeverityOrdering()
        try verifySharedParityFixture(repoRoot: repoRoot)
        try verifyModuleStatusConvenienceResolution()
        print("DashboardStatusTone tests passed: 3")
    }

    private static func resolveRepoRoot() -> URL {
        if CommandLine.arguments.count > 1 {
            return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DashboardStatusToneHarness.swift -> DashboardStatusToneHarness/
            .deletingLastPathComponent() // -> Harnesses/
            .deletingLastPathComponent() // -> Tests/
            .deletingLastPathComponent() // -> macos/
            .deletingLastPathComponent() // -> apps/
            .deletingLastPathComponent() // -> repoRoot
    }

    private static func verifySeverityOrdering() throws {
        try expect(DashboardStatusTone.neutral < .ok, "neutral < ok")
        try expect(DashboardStatusTone.ok < .warn, "ok < warn")
        try expect(DashboardStatusTone.warn < .error, "warn < error")
        try expect(max(DashboardStatusTone.ok, .warn) == .warn, "max(ok, warn) == warn")
        try expect(max(DashboardStatusTone.warn, .error) == .error, "max(warn, error) == error")
    }

    private static func verifySharedParityFixture(repoRoot: URL) throws {
        let fixtureURL = repoRoot.appendingPathComponent("tests/fixtures/status-tone-parity/cases.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(ParityFixture.self, from: data)
        try expect(fixture.cases.count >= 20, "共享 fixture 用例数应覆盖全部映射分支")

        for item in fixture.cases {
            let resolved = DashboardStatusToneResolver.resolve(
                moduleState: item.moduleState,
                subscriptions: item.subscriptions.map {
                    DashboardStatusSubscription(status: $0.status, name: $0.name)
                },
                hasData: item.hasData,
                detail: item.detail
            )
            try expect(
                resolved.tone.rawValue == item.expectedTone,
                "\(item.name): tone 应为 \(item.expectedTone), 实得 \(resolved.tone.rawValue)"
            )
            try expect(
                resolved.isRefreshing == item.expectedRefreshing,
                "\(item.name): isRefreshing 应为 \(item.expectedRefreshing), 实得 \(resolved.isRefreshing)"
            )
            try expect(
                resolved.reason == item.expectedReason,
                "\(item.name): reason 应为 '\(item.expectedReason)', 实得 '\(resolved.reason)'"
            )
        }
    }

    private static func verifyModuleStatusConvenienceResolution() throws {
        let emptyPanel = PanelViewModel(
            usage: nil,
            subscription: nil,
            hourly: nil,
            diagnostics: []
        )
        let notConfigured = DashboardStatusToneResolver.resolve(
            moduleStatus: .notConfigured,
            panel: emptyPanel
        )
        try expect(notConfigured.tone == .neutral, "未配置且无面板数据时应为中性灰")
        try expect(notConfigured.reason == "未配置", "未配置无详情时 reason 应为 '未配置'")

        let degradedPanel = PanelViewModel(
            usage: nil,
            subscription: SubscriptionViewModel(
                sections: [
                    SubscriptionProviderSection(
                        id: "kimi",
                        name: "Kimi",
                        plan: nil,
                        status: "ok",
                        note: nil,
                        extraText: nil,
                        windows: [],
                        balance: nil,
                        accountCountText: nil
                    ),
                    SubscriptionProviderSection(
                        id: "codex",
                        name: "Codex",
                        plan: nil,
                        status: "error",
                        note: "授权已失效",
                        extraText: nil,
                        windows: [],
                        balance: nil,
                        accountCountText: nil
                    )
                ],
                updatedText: nil
            ),
            hourly: nil,
            diagnostics: []
        )
        let elevated = DashboardStatusToneResolver.resolve(
            moduleStatus: ModuleStatus(state: .fresh, detail: nil),
            panel: degradedPanel
        )
        try expect(elevated.tone == .error, "采集 fresh 但存在 error 订阅段时应聚合为红灯")
        try expect(elevated.reason == "失败 · Codex", "订阅段提升为 error 时 reason 应点名该服务, 实得 '\(elevated.reason)'")
    }
}
