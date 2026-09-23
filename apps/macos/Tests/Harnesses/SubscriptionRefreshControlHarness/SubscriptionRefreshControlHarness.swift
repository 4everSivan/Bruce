import Foundation
@testable import BruceAppCore
import BruceOnboardingCore

/// 订阅卡 Provider 定向刷新按钮 (Stage 2 / TASK-5) 的边界测试:
/// section→Provider 解析 (fail-closed), 呈现矩阵 (契约文案与禁用规则),
/// 以及 AppModel 的 Provider 刷新状态与凭证 busy 状态的分离语义.
private enum SubscriptionRefreshControlFailure: Error, CustomStringConvertible {
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
        throw SubscriptionRefreshControlFailure.expectation(message)
    }
}

@main
@MainActor
struct SubscriptionRefreshControlHarness {
    static func main() throws {
        try providerIDResolution()
        try presentationMatrix()
        try appModelRefreshStateSeparation()
        try appModelControlComputation()
        print("SubscriptionRefreshControl tests passed: 4")
    }

    // MARK: - section ID -> Provider 解析

    /// 契约: 单账号 section ID 可能是带账号后缀的 serviceID, 多账号分组
    /// section ID 即 provider rawValue; 未知 service 一律 nil (不渲染按钮).
    private static func providerIDResolution() throws {
        let resolve = SubscriptionRefreshControlPolicy.providerID(forSectionID:)

        try expect(resolve("deepseek") == .deepseek, "单账号 plain service id 应解析为 deepseek")
        try expect(resolve("kimi_coding") == .kimi, "kimi_coding 应归一为 kimi")
        try expect(resolve("codex") == .codex, "多账号分组 id 应解析为 codex")
        try expect(
            resolve("codex_a1b2c3d4") == .codex,
            "带账号后缀的单账号 service id 应归一为 codex"
        )
        try expect(
            resolve("opencode_go_acc1") == .opencodeGo,
            "opencode_go_ 前缀应归一为 opencodeGo"
        )
        try expect(resolve("openai") == nil, "未知 provider (openai) 必须 fail-closed 为 nil")
        try expect(resolve("") == nil, "空 service id 必须 fail-closed 为 nil")
    }

    // MARK: - 呈现矩阵

    /// 契约: 目标刷新中 spinner+禁用+「正在刷新」; 全量刷新中全部禁用;
    /// 未配置/未启用/模块不可运行禁用; VoiceOver 文案为锁定措辞.
    private static func presentationMatrix() throws {
        func make(
            displayName: String,
            refreshing: Bool = false,
            fullRefresh: Bool = false,
            runnable: Bool = true
        ) -> SubscriptionRefreshControlPresentation {
            SubscriptionRefreshControlPolicy.make(
                displayName: displayName,
                isProviderRefreshing: refreshing,
                isFullRefreshRunning: fullRefresh,
                isRunnable: runnable
            )
        }

        let normal = make(displayName: "DeepSeek")
        try expect(normal.isEnabled, "可运行且无冲突时按钮应可点击")
        try expect(!normal.showsProgress, "常态不应显示进度指示")
        try expect(
            normal.accessibilityLabel == "刷新 DeepSeek 订阅额度",
            "常态 VoiceOver 标签应为契约文案"
        )
        try expect(
            normal.accessibilityHint.contains("DeepSeek"),
            "VoiceOver hint 应携带 Provider 名称"
        )

        let refreshing = make(displayName: "DeepSeek", refreshing: true)
        try expect(refreshing.showsProgress, "目标刷新中应显示进度指示")
        try expect(!refreshing.isEnabled, "目标刷新中按钮应禁用")
        try expect(
            refreshing.accessibilityLabel == "正在刷新 DeepSeek 订阅额度",
            "进行中 VoiceOver 标签应为契约文案"
        )

        let fullRefresh = make(displayName: "Kimi", fullRefresh: true)
        try expect(!fullRefresh.isEnabled, "全量刷新中 Provider 按钮应禁用 (不重复启动)")
        try expect(!fullRefresh.showsProgress, "非目标刷新不应显示 Provider 进度指示")
        try expect(
            fullRefresh.accessibilityLabel == "刷新 Kimi 订阅额度",
            "全量刷新冲突时 VoiceOver 标签保持常态"
        )

        let notRunnable = make(displayName: "Kimi", runnable: false)
        try expect(!notRunnable.isEnabled, "未配置/未启用/模块不可运行时应禁用")
        try expect(!notRunnable.showsProgress, "不可运行时不应显示进度指示")

        let allConflict = make(
            displayName: "Kimi",
            refreshing: true,
            fullRefresh: true,
            runnable: false
        )
        try expect(allConflict.showsProgress, "多状态叠加时目标刷新进度优先展示")
        try expect(!allConflict.isEnabled, "多状态叠加时必须禁用")
    }

    // MARK: - AppModel 状态分离

    /// 契约: Provider 刷新状态与 Settings 凭证操作 busy 严格分离, 互不误显.
    private static func appModelRefreshStateSeparation() throws {
        let model = AppModel()

        model.setSubscriptionRefreshing(true, for: .deepseek)
        try expect(
            model.refreshingSubscriptionProviders.contains(.deepseek),
            "started 回调归约后 provider 应进入刷新中集合"
        )
        model.setSubscriptionRefreshing(false, for: .deepseek)
        try expect(
            model.refreshingSubscriptionProviders.isEmpty,
            "finished/failed/cancelled 归约后 provider 应移出刷新中集合"
        )

        // 凭证导入 busy 不得被误显示为额度刷新.
        model.setBusySubscription(true, for: .codex)
        try expect(
            !model.refreshingSubscriptionProviders.contains(.codex),
            "凭证 busy 不得进入 Provider 刷新中集合"
        )
        let presentation = model.subscriptionRefreshControl(
            for: .codex, displayName: "ChatGPT"
        )
        try expect(
            !presentation.showsProgress,
            "凭证 busy 不得显示额度刷新进度指示"
        )
    }

    // MARK: - AppModel 呈现计算

    /// 契约: 可运行性 = 模块可运行 + provider 已配置且启用; 全量刷新中
    /// (moduleStatuses == refreshing) 所有 Provider 按钮禁用.
    private static func appModelControlComputation() throws {
        let model = AppModel()

        // 模块未就绪 (无 readiness 结果) -> 不可运行.
        let notReady = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(!notReady.isEnabled, "模块不可运行时按钮应禁用")

        // 模块就绪但 provider 未配置 -> 禁用.
        model.setModuleResult(ModuleReadinessResult(
            module: .agentUsage,
            readiness: .ready,
            localDependencies: [],
            connection: .connected
        ))
        let notConfigured = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(!notConfigured.isEnabled, "provider 未配置时按钮应禁用")

        // 配置存在但未启用 -> 禁用.
        model.setSubscriptionProviders([
            .deepseek: SubscriptionProviderConfiguration(enabled: false),
        ])
        let disabledProvider = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(!disabledProvider.isEnabled, "provider 未启用时按钮应禁用")

        // 就绪 + 启用 -> 可点击.
        model.setSubscriptionProviders([
            .deepseek: SubscriptionProviderConfiguration(enabled: true),
        ])
        let enabled = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(enabled.isEnabled, "模块就绪且 provider 启用时按钮应可点击")
        try expect(
            enabled.accessibilityLabel == "刷新 DeepSeek 订阅额度",
            "可点击时 VoiceOver 标签应为常态契约文案"
        )

        // 目标 Provider 定向刷新中 -> spinner + 禁用.
        model.setSubscriptionRefreshing(true, for: .deepseek)
        let refreshing = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(refreshing.showsProgress, "目标刷新中应显示进度指示")
        try expect(!refreshing.isEnabled, "目标刷新中应禁用")
        // 其他 provider 不受目标刷新影响.
        model.setSubscriptionProviders([
            .deepseek: SubscriptionProviderConfiguration(enabled: true),
            .kimi: SubscriptionProviderConfiguration(enabled: true),
        ])
        let other = model.subscriptionRefreshControl(
            for: .kimi, displayName: "Kimi"
        )
        try expect(other.isEnabled, "目标刷新中其他 Provider 按钮应保持可点击")
        model.setSubscriptionRefreshing(false, for: .deepseek)

        // 全量 agentUsage 刷新中 -> 所有 Provider 按钮禁用.
        model.setStatus(ModuleStatus(state: .refreshing, detail: nil), for: .agentUsage)
        let duringFull = model.subscriptionRefreshControl(
            for: .deepseek, displayName: "DeepSeek"
        )
        try expect(!duringFull.isEnabled, "全量刷新中 Provider 按钮应禁用 (不重复启动)")
        try expect(!duringFull.showsProgress, "全量刷新不得显示为 Provider 定向进度")
    }
}
