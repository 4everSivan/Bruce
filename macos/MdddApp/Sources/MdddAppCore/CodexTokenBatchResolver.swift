import Foundation
import MdddOnboardingCore

/// 单账号 token 决议结果 (任务 5). 只在 Swift 内存中流转,
/// 不序列化 token 失败原因到 Bridge.
package struct CodexTokenDecision: Sendable, Equatable {
    package enum Outcome: Sendable, Equatable {
        case available(accessToken: String, expiresAt: Date)
        case needsReauthorization
        case storageBlocked
        case temporarilyUnavailable(retryAt: Date?)
        case credentialNotFound
    }

    package let index: Int
    package let accountID: String
    package let serviceID: String
    package let displayName: String
    package let outcome: Outcome

    package init(
        index: Int,
        accountID: String,
        serviceID: String,
        displayName: String,
        outcome: Outcome
    ) {
        self.index = index
        self.accountID = accountID
        self.serviceID = serviceID
        self.displayName = displayName
        self.outcome = outcome
    }
}

/// 批量 token 决议器 (任务 5): 从 v2 index 生成带 index 的有序
/// descriptor, 最多 4 账号并行决议, 完成后按 index 排序输出.
///
/// 决议结果 (`CodexTokenDecision`) 只在 Swift 内存流转; 只有 `.available`
/// 账号的 access token 写入 Bridge credentials. 失败决议交给
/// Scheduler/合并器处理, 不阻断本地统计.
package struct CodexTokenBatchResolver: Sendable {
    package static let maxConcurrency = 4

    package init() {}

    /// 对有序账号列表做批量决议, 最多 4 个并行, 输出按 index 排序.
    /// - Parameters:
    ///   - accounts: 有序账号 descriptor (index + accountID + displayName).
    ///   - resolver: 单账号 token 决议闭包 (由 token manager 提供).
    /// - Returns: 按 index 排序的决议结果数组, 长度等于 accounts.count.
    package func resolve(
        accounts: [Descriptor],
        using resolver: @Sendable @escaping (String) async -> CodexTokenDecision.Outcome
    ) async -> [CodexTokenDecision] {
        guard !accounts.isEmpty else { return [] }
        var results = [CodexTokenDecision?](repeating: nil, count: accounts.count)
        for chunk in chunked(accounts, by: Self.maxConcurrency) {
            await withTaskGroup(of: (Int, CodexTokenDecision).self) { group in
                for descriptor in chunk {
                    group.addTask {
                        let outcome = await resolver(descriptor.accountID)
                        return (descriptor.index, CodexTokenDecision(
                            index: descriptor.index,
                            accountID: descriptor.accountID,
                            serviceID: descriptor.serviceID,
                            displayName: descriptor.displayName,
                            outcome: outcome
                        ))
                    }
                }
                for await (index, decision) in group {
                    results[index] = decision
                }
            }
        }
        return results.compactMap { $0 }
    }

    private func chunked<T>(_ array: [T], by size: Int) -> [[T]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }
}

extension CodexTokenBatchResolver {
    /// 有序账号 descriptor: index 保留原始顺序, serviceID 按 SHA256 契约生成.
    package struct Descriptor: Sendable, Equatable {
        package let index: Int
        package let accountID: String
        package let serviceID: String
        package let displayName: String

        package init(index: Int, accountID: String, displayName: String) {
            self.index = index
            self.accountID = accountID
            self.serviceID = CodexAccountIdentity.serviceID(for: accountID)
            self.displayName = displayName
        }
    }
}
