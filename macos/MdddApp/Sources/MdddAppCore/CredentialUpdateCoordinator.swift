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
    package func apply(credentialUpdates: [JSONValue]) -> CredentialUpdateApplyResult {
        var result = CredentialUpdateApplyResult()
        for value in credentialUpdates {
            guard let update = Self.rotationUpdate(from: value) else {
                result.skippedCount += 1
                continue
            }
            // codex 明确跳过 (keychainAccount 也会返回 nil; 先判 provider 语义更清晰)
            guard update.provider != "codex",
                  let account = CredentialRotationMerge.keychainAccount(
                      forProvider: update.provider
                  ) else {
                result.skippedCount += 1
                continue
            }
            // load 失败按无既有凭证起步 (与历史 try? 语义一致)
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
}
