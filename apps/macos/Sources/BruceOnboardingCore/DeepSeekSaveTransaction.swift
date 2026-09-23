import Foundation

// MARK: - DeepSeekSaveTransaction

/// DeepSeek API key 保存事务的非敏感配置部分.
///
/// 事务目标 (见 deepseek-monthly-consumption 设计):
/// 1. 预写携带新 usageTrackingID 的禁用配置, 阻止并发刷新用旧追踪 ID 记账.
/// 2. Keychain 写入失败时恢复完整旧配置 (含旧 usageTrackingID).
///
/// 本类型只负责 OnboardingConfigurationStore 的 load/mutate/save;
/// publish 到 AppModel 由 OnboardingCoordinator 在调用后处理,
/// 使事务核心可在 Onboarding Core Harness 直接测试.
public enum DeepSeekSaveTransaction {

    /// 预写禁用配置的结果.
    public struct PrewriteResult: Equatable, Sendable {
        /// 预写前的旧 DeepSeek 配置; nil 表示原本不存在该 provider.
        public let oldEntry: SubscriptionProviderConfiguration?
        /// 本次预写生成的随机追踪 ID.
        public let newTrackingID: String
    }

    /// 预写携带新 usageTrackingID 的禁用 DeepSeek 配置.
    /// 保存失败抛出 (调用方按 fail-closed 处理, 不得继续写 Keychain).
    public static func prewriteDisabled(
        in store: OnboardingConfigurationStore
    ) throws -> PrewriteResult {
        let config = store.load() ?? OnboardingConfiguration()
        let oldEntry = config.subscriptionProviders[
            SubscriptionProviderID.deepseek.rawValue
        ]
        let newTrackingID = UUID().uuidString
        var updated = config
        updated.subscriptionProviders[
            SubscriptionProviderID.deepseek.rawValue
        ] = SubscriptionProviderConfiguration(
            enabled: false,
            lastVerifiedAt: nil,
            verificationStatus: .none,
            usageTrackingID: newTrackingID
        )
        try store.save(updated)
        return PrewriteResult(oldEntry: oldEntry, newTrackingID: newTrackingID)
    }

    /// 恢复旧 DeepSeek 配置 (含旧 usageTrackingID).
    /// oldEntry 为 nil 表示原本不存在该 provider, 恢复为移除该键.
    /// 恢复失败抛出; 调用方按 fail-closed 保留预写的禁用配置.
    public static func restore(
        oldEntry: SubscriptionProviderConfiguration?,
        in store: OnboardingConfigurationStore
    ) throws {
        let config = store.load() ?? OnboardingConfiguration()
        var updated = config
        if let oldEntry {
            updated.subscriptionProviders[
                SubscriptionProviderID.deepseek.rawValue
            ] = oldEntry
        } else {
            updated.subscriptionProviders.removeValue(
                forKey: SubscriptionProviderID.deepseek.rawValue
            )
        }
        try store.save(updated)
    }
}
