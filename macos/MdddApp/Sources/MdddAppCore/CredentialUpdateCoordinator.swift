import Foundation
import MdddOnboardingCore

// MARK: - Apply result

/// 单条 credentialUpdates 写回失败 (不含令牌值).
package struct CredentialUpdateFailure: Equatable, Sendable {
    package let provider: String
    package let accountId: String
    /// 截断后的错误描述; 不得包含 token 明文.
    package let reason: String

    package init(provider: String, accountId: String, reason: String) {
        self.provider = provider
        self.accountId = accountId
        self.reason = reason
    }
}

/// CredentialUpdateCoordinator.apply 的可观察结果.
package struct CredentialUpdateApplyResult: Equatable, Sendable {
    package var appliedCount: Int
    package var skippedCount: Int
    package var failed: [CredentialUpdateFailure]

    package init(
        appliedCount: Int = 0,
        skippedCount: Int = 0,
        failed: [CredentialUpdateFailure] = []
    ) {
        self.appliedCount = appliedCount
        self.skippedCount = skippedCount
        self.failed = failed
    }
}

// MARK: - Coordinator

/// 将 Bridge credentialUpdates 应用到 Keychain 的协调器.
/// 纯 apply + 可观察结果; 单条失败不阻断其他条目, 不静默吞 save 错误.
/// Codex 轮换条目明确跳过: 令牌链由 CodexTokenManager 独占持有.
package struct CredentialUpdateCoordinator: Sendable {
    private let credentialStore: CredentialStore

    /// failure.reason 最大长度; 超出截断, 避免异常信息膨胀.
    private static let maxFailureReasonLength = 200

    package init(credentialStore: CredentialStore) {
        self.credentialStore = credentialStore
    }

    /// 应用 credentialUpdates, 返回 applied/skipped/failed 计数.
    /// - Skip: 坏形状, codex, 未知 provider, merge 返回 nil
    /// - Fail: `saveCredential` 抛错 → reason 为截断后的 localizedDescription
    /// - Success: appliedCount +1
    /// 多账号 provider: 按 accountId 写回 per-account record (ProviderAccountStore);
    /// 单账号/旧格式: 写回旧 Keychain 键 (向后兼容).
    package func apply(credentialUpdates: [JSONValue]) -> CredentialUpdateApplyResult {
        var result = CredentialUpdateApplyResult()
        for value in credentialUpdates {
            guard let update = Self.rotationUpdate(from: value) else {
                result.skippedCount += 1
                continue
            }
            // codex 明确跳过 (keychainAccount 也会返回 nil; 先判 provider 语义更清晰)
            guard update.provider != "codex",
                  let providerID = SubscriptionProviderID(
                      rawValue: update.provider
                  ) ?? Self.legacyProviderID(for: update.provider) else {
                result.skippedCount += 1
                continue
            }

            if CredentialRotationMerge.supportsAccountScopedRotation(
                forProvider: update.provider
            ) {
                // 多账号路径: 写回 per-account record.
                // 仅当 index 中存在该账号时使用; 否则回退旧键 (兼容未迁移的单账号).
                let store = ProviderAccountStore(
                    provider: providerID,
                    credentialStore: credentialStore
                )
                let index = try? store.loadIndex()
                if let index, index.entry(for: update.accountId) != nil {
                    do {
                        let record = try store.loadRecord(for: update.accountId)
                        guard let merged = CredentialRotationMerge.mergedAccountJSON(
                            existingCredentialJSON: record?.credentialJSON,
                            update: update,
                            providerID: providerID
                        ) else {
                            result.skippedCount += 1
                            continue
                        }
                        var updated = record ?? ProviderAccountRecord(
                            accountID: update.accountId,
                            displayName: index.entry(for: update.accountId)?.displayName ?? update.accountId,
                            credentialJSON: merged,
                            authorizationState: .connected,
                            updatedAt: Date()
                        )
                        updated.credentialJSON = merged
                        updated.authorizationState = .connected
                        updated.updatedAt = Date()
                        try store.saveRecord(updated)
                        try store.updateAuthorizationState(.connected, for: update.accountId)
                        result.appliedCount += 1
                    } catch {
                        result.failed.append(CredentialUpdateFailure(
                            provider: update.provider,
                            accountId: update.accountId,
                            reason: Self.sanitizedFailureReason(from: error)
                        ))
                    }
                    continue
                }
                // index 无该账号: 回退旧键路径 (见下方)
            }

            // 旧格式回退: 写回旧 Keychain 键
            guard let account = CredentialRotationMerge.keychainAccount(
                forProvider: update.provider
            ) else {
                result.skippedCount += 1
                continue
            }
            let existing = try? credentialStore.loadCredential(forAccount: account)
            guard let merged = CredentialRotationMerge.mergedJSON(
                existingJSON: existing ?? nil,
                update: update
            ) else {
                result.skippedCount += 1
                continue
            }
            do {
                try credentialStore.saveCredential(merged, forAccount: account)
                result.appliedCount += 1
            } catch {
                result.failed.append(CredentialUpdateFailure(
                    provider: update.provider,
                    accountId: update.accountId,
                    reason: Self.sanitizedFailureReason(from: error)
                ))
            }
        }
        return result
    }

    /// Bridge credentialUpdates JSON -> 纯更新结构; 只接受
    /// kind=oauthTokens, operation=replace 且含有效令牌字符串的条目.
    package static func rotationUpdate(from value: JSONValue) -> CredentialRotationUpdate? {
        guard case .object(let dict) = value,
              case .string(let provider)? = dict["provider"],
              case .string(let kind)? = dict["kind"], kind == "oauthTokens",
              case .string(let operation)? = dict["operation"], operation == "replace",
              case .object(let credentials)? = dict["credentials"] else {
            return nil
        }
        var tokens: [String: String] = [:]
        for (key, child) in credentials {
            if case .string(let string) = child {
                tokens[key] = string
            }
        }
        guard !tokens.isEmpty else { return nil }
        var accountId = "default"
        if case .string(let raw)? = dict["accountId"], !raw.isEmpty {
            accountId = raw
        }
        return CredentialRotationUpdate(
            provider: provider,
            accountId: accountId,
            tokens: tokens
        )
    }

    /// 截断错误描述; 仅使用 localizedDescription, 不拼接 update 内令牌.
    private static func sanitizedFailureReason(from error: Error) -> String {
        let raw = error.localizedDescription
        guard raw.count > maxFailureReasonLength else { return raw }
        let end = raw.index(raw.startIndex, offsetBy: maxFailureReasonLength)
        return String(raw[..<end])
    }

    /// collector 侧 provider 标识 -> SubscriptionProviderID 映射.
    /// 目前无需要映射的连字符命名 provider; 保留扩展点.
    private static func legacyProviderID(
        for provider: String
    ) -> SubscriptionProviderID? {
        switch provider {
        default:
            return nil
        }
    }
}
