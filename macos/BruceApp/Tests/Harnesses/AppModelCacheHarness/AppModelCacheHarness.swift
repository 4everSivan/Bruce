import Foundation
@testable import BruceAppCore

/// 回归: 面板缓存与菜单栏摘要缓存共享同一版本计数器, 但各自持有独立缓存.
/// 当面板 view model 重建并同步版本计数器后, 菜单栏摘要可能命中陈旧缓存,
/// 返回 artifact 就绪前的空摘要 (今日 token 显示 "--").
private enum AppModelCacheFailure: Error, CustomStringConvertible {
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
        throw AppModelCacheFailure.expectation(message)
    }
}

@main
@MainActor
struct AppModelCacheHarness {
    static func main() throws {
        try menuBarSummaryDoesNotReturnStaleNilAfterArtifactArrives()
        try menuBarSummaryRebuildsAfterArtifactChange()
        print("AppModelCache tests passed: 2")
    }

    /// 回归: artifact 就绪后菜单栏摘要必须反映实际 token, 不得返回陈旧空摘要.
    private static func menuBarSummaryDoesNotReturnStaleNilAfterArtifactArrives() throws {
        let model = AppModel()
        // 1. 初始摘要 (artifact 未就绪) → 今日 token 为空
        try expect(
            model.makeMenuBarSummary().todayTokens == nil,
            "初始无 artifact 时今日 token 应为 nil"
        )
        // 2. 面板渲染: 重建面板 view model 并同步共享缓存版本计数器
        _ = model.makePanelViewModel()
        // 3. artifact 就绪 → 面板缓存失效
        model.setArtifact(makeArtifact(todayTotal: 123_456), for: .agentUsage)
        // 4. artifact 到达后面板再次渲染 (SwiftUI objectWillChange 驱动)
        _ = model.makePanelViewModel()
        // 5. 菜单栏摘要必须返回实际值, 而非步骤 1 的陈旧 nil 摘要
        try expect(
            model.makeMenuBarSummary().todayTokens == 123_456,
            "artifact 就绪后菜单栏摘要必须返回实际 token 值, 不得返回陈旧的 nil 摘要"
        )
    }

    /// 守卫: artifact 更新后摘要必须重算, 不得跨 artifact 复用缓存.
    private static func menuBarSummaryRebuildsAfterArtifactChange() throws {
        let model = AppModel()
        model.setArtifact(makeArtifact(todayTotal: 100), for: .agentUsage)
        try expect(
            model.makeMenuBarSummary().todayTokens == 100,
            "第一个 artifact 应反映到摘要"
        )
        model.setArtifact(makeArtifact(todayTotal: 200), for: .agentUsage)
        try expect(
            model.makeMenuBarSummary().todayTokens == 200,
            "artifact 更新后摘要应重算, 不得返回旧值"
        )
    }

    /// 构造通过 ArtifactValidator 的最小合法 agent-usage artifact.
    private static func makeArtifact(todayTotal: Int) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-08-12T10:00:00+00:00"),
            "agents": .array([
                .object([
                    "id": .string("test-agent"),
                    "name": .string("Test Agent"),
                    "status": .string("ok"),
                    "today": .object([
                        "input": .integer(0),
                        "output": .integer(todayTotal),
                        "cacheRead": .integer(0),
                        "cacheCreation": .integer(0),
                        "total": .integer(todayTotal),
                    ]),
                    "daily": .array([
                        .object([
                            "date": .string("2026-08-12"),
                            "input": .integer(0),
                            "output": .integer(todayTotal),
                            "total": .integer(todayTotal),
                        ])
                    ]),
                    "hours": .array(
                        (0..<24).map { _ in JSONValue.integer(0) }
                    ),
                ])
            ]),
            "services": .array([]),
            "totalCostUsd": .double(1.5),
        ])
    }
}
