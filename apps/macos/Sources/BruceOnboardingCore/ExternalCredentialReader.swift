import Foundation
import LocalAuthentication
import Security

/// 外部 CLI 凭证读取错误. 不携带凭证值或原始错误文本.
public enum ExternalCredentialError: Error, Equatable, Sendable {
    case notAllowed(KeychainExternalSource)
    case accessBlocked(KeychainExternalSource, OSStatus)
    case readFailed(KeychainExternalSource, OSStatus)
}

/// 外部 CLI 凭证读取边界.
/// 调用方必须先通过 `KeychainAccessController` 的来源策略.
public protocol ExternalCredentialReader: Sendable {
    func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String?
}

/// 生产外部凭证读取器.
/// Claude 优先读取 CLI Keychain, 再回退到 CLI 凭证文件; Grok 读取其 CLI 文件.
/// 两条路径都受 `externalSources` 白名单控制.
public struct SystemExternalCredentialReader: ExternalCredentialReader, Sendable {
    public static let claudeKeychainService = "Claude Code-credentials"

    private let homeURL: URL
    private let accessController: KeychainAccessController

    public init(
        homeURL: URL,
        accessController: KeychainAccessController
    ) {
        self.homeURL = homeURL
        self.accessController = accessController
    }

    public func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String? {
        switch source {
        case .claudeCLI:
            // C060 (与 cc-switch 同构): 每次读取无条件尝试 Keychain, 不再受
            // externalSources 白名单 / state 门禁约束; UISkip 保证静默,
            // 拦截时仅降级文件, 绝不唤起 SecurityAgent 弹窗。
            if let keychain = try readClaudeKeychain() {
                return keychain
            }
            return try readFile(
                source: source,
                url: homeURL.appendingPathComponent(
                    ".claude/.credentials.json"
                )
            )
        case .grokCLI:
            guard accessController.allows(
                source: .external(source),
                intent: intent
            ) else {
                throw ExternalCredentialError.notAllowed(source)
            }
            return try readFile(
                source: source,
                url: homeURL.appendingPathComponent(".grok/auth.json")
            )
        }
    }

    /// Claude CLI 外部 Keychain 项的无条件静默读取 (C060, 对照 cc-switch
    /// `security find-generic-password -s "Claude Code-credentials" -w`).
    /// - 条目不存在 / 被系统拦截 (锁定/ACL): 返回 nil 走文件回退;
    /// - 拦截时不 markBlocked — 外部条目是可选来源, 不得污染 Bruce 自有存储策略;
    /// - 强制 UISkip, 绝不唤起 SecurityAgent 弹窗 (项目红线)。
    private func readClaudeKeychain() throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.claudeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            if status == errSecInteractionNotAllowed
                || status == errSecAuthFailed
                || status == errSecUserCanceled {
                return nil
            }
            throw ExternalCredentialError.readFailed(.claudeCLI, status)
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readFile(
        source: KeychainExternalSource,
        url: URL
    ) throws -> String? {
        do {
            let data = try Data(contentsOf: url)
            return String(data: data, encoding: .utf8)
        } catch CocoaError.fileNoSuchFile {
            return nil
        }
        catch {
            // 不暴露路径或系统错误文本.
            throw ExternalCredentialError.readFailed(source, errSecIO)
        }
    }
}

/// Harness 用确定性外部读取器. 只记录来源和意图, 不打印值.
public final class InMemoryExternalCredentialReader: ExternalCredentialReader,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [KeychainExternalSource: String]
    private var requests: [(KeychainExternalSource, KeychainAccessIntent)] = []

    public init(
        values: [KeychainExternalSource: String] = [:]
    ) {
        self.storage = values
    }

    public func read(
        source: KeychainExternalSource,
        intent: KeychainAccessIntent
    ) throws -> String? {
        lock.lock()
        requests.append((source, intent))
        let value = storage[source]
        lock.unlock()
        return value
    }

    public func requestedSources() -> [KeychainExternalSource] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.0 }
    }
}
