import Foundation
import BruceOnboardingCore
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
        try menuBarQuotaSummaryHonorsDashboardVerificationGate()
        try dashboardLayoutModeAndCardSelectionPersists()
        print("AppModelCache tests passed: 4")
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

    /// TD-009: 菜单栏额度摘要必须与仪表盘共用验证门禁.
    /// 未验证 Provider 的额度不得进入最低/平均剩余额度; 验证状态变化须立即重算.
    private static func menuBarQuotaSummaryHonorsDashboardVerificationGate() throws {
        let model = AppModel()
        model.setSubscriptionProviders([
            .kimi: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .ok
            ),
            .deepseek: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .none
            ),
        ])
        model.setArtifact(
            makeServiceArtifact([
                (id: "kimi_coding", usedPercent: 10),
                (id: "deepseek_coding", usedPercent: 90),
            ]),
            for: .agentUsage
        )
        let summary = model.makeMenuBarSummary()
        try expect(
            summary.minimumRemainingQuota == 90,
            "菜单栏最低剩余额度只能来自已验证 Provider (期望 90, 实际 \(String(describing: summary.minimumRemainingQuota)))"
        )
        try expect(
            summary.averageRemainingQuota == 90,
            "菜单栏平均剩余额度只能来自已验证 Provider"
        )

        // 验证状态变化后必须失效摘要缓存并重算.
        model.setSubscriptionProviders([
            .kimi: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .failed(reason: "fixture")
            ),
            .deepseek: SubscriptionProviderConfiguration(
                enabled: true,
                verificationStatus: .none
            ),
        ])
        let gated = model.makeMenuBarSummary()
        try expect(
            gated.minimumRemainingQuota == nil && gated.averageRemainingQuota == nil,
            "无已验证 Provider 时菜单栏额度摘要应为空, 不得回退到未验证 Provider"
        )
    }

    /// 构造含订阅服务的合法 agent-usage artifact.
    private static func makeServiceArtifact(
        _ services: [(id: String, usedPercent: Int)]
    ) -> JSONValue {
        .object([
            "schemaVersion": .integer(1),
            "module": .string("agent-usage"),
            "generatedAt": .string("2026-08-12T10:00:00+00:00"),
            "agents": .array([]),
            "services": .array(
                services.map { service in
                    .object([
                        "id": .string(service.id),
                        "name": .string(service.id),
                        "status": .string("ok"),
                        "kind": .string("windows"),
                        "windows": .array([
                            .object([
                                "label": .string("5h"),
                                "usedPercent": .integer(service.usedPercent),
                            ])
                        ]),
                    ])
                }
            ),
            "totalCostUsd": .double(0),
        ])
    }

    /// 验证: 仪表盘布局模式与选定卡片切换持久化到 UserDefaults 并可在实例间恢复.
    private static func dashboardLayoutModeAndCardSelectionPersists() throws {
        let suiteName = "test.bruce.dashboard.layout.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw AppModelCacheFailure.expectation("无法创建隔离测试 suite")
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        let model1 = AppModel(collapsedDefaults: suite)
        try expect(model1.layoutMode == .stack, "默认布局模式应为 .stack")
        try expect(model1.selectedCardID == .usage, "默认选中卡片应为 .usage")

        model1.setLayoutMode(.tabbed)
        model1.selectCard(.hourly)
        try expect(model1.layoutMode == .tabbed, "设置后布局应为 .tabbed")
        try expect(model1.selectedCardID == .hourly, "设置后选中卡片应为 .hourly")

        // 重新初始化测试 UserDefaults 恢复
        let model2 = AppModel(collapsedDefaults: suite)
        try expect(model2.layoutMode == .tabbed, "恢复后布局应维持 .tabbed")
        try expect(model2.selectedCardID == .hourly, "恢复后选中卡片应维持 .hourly")
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
