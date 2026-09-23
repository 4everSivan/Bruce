import Foundation
import BruceOnboardingCore

// MARK: - LocalCredentialProbe

/// 本机文件与系统 Keychain 探测 (App 层 I/O 边界).
///
/// 无 AppModel 副作用; Coordinator 负责刷新 model / configured 状态.
/// Claude 外部 CLI 探测通过统一外部凭证读取器执行, 受来源白名单和非交互策略控制.
struct LocalCredentialProbe: Sendable {
    let homeURL: URL
    private let keychainAccessController: KeychainAccessController
    private let externalCredentialReader: ExternalCredentialReader

    init(
        homeURL: URL,
        accessController: KeychainAccessController = KeychainAccessController(),
        externalCredentialReader: ExternalCredentialReader? = nil
    ) {
        self.homeURL = homeURL
        self.keychainAccessController = accessController
        self.externalCredentialReader = externalCredentialReader
            ?? SystemExternalCredentialReader(
                homeURL: homeURL,
                accessController: accessController
            )
    }

    // MARK: - 本机文件存在性 (设置页条件渲染)

    func codexCLIAuthFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".codex/auth.json").path
        )
    }

    func codexCCAccountsFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(".cc-switch/codex_oauth_auth.json").path
        )
    }

    func ccSwitchDatabaseExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL.appendingPathComponent(".cc-switch/cc-switch.db").path
        )
    }

    // MARK: - Claude / Grok 本机登录态 (实时只读, 不导入不回写)

    /// 解析 ~/.grok/auth.json: OIDC/legacy 条目 key 非空且未过期视为可用
    /// (与 Rust provider credential contract / SubscriptionCredentialEvaluator 同语义).
    /// 未显式允许 Grok 来源, 或文件损坏/缺失/过期时返回 false.
    func grokLocalAuthAvailable(now: Date = Date()) -> Bool {
        guard keychainAccessController.allows(
            source: .external(.grokCLI),
            intent: .automatic
        ) else {
            return false
        }
        let url = homeURL.appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return SubscriptionCredentialEvaluator.grokStatus(
            of: json, now: now
        ) == .valid
    }

    /// 解析 ~/.claude/.credentials.json 是否为有效未过期 Claude OAuth.
    /// 未显式允许 Claude 来源时不触碰该文件.
    func claudeCredentialsFileValid(now: Date = Date()) -> Bool {
        guard keychainAccessController.allows(
            source: .external(.claudeCLI),
            intent: .automatic
        ) else {
            return false
        }
        let url = homeURL.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return SubscriptionCredentialEvaluator.claudeStatus(
            of: json, now: now
        ) == .valid
    }

    /// 探测 Claude CLI 外部登录态. 未显式允许来源时不触碰外部 Keychain.
    func claudeKeychainItemExists() -> Bool {
        guard keychainAccessController.allows(
            source: .external(.claudeCLI),
            intent: .automatic
        ) else {
            return false
        }
        return (try? externalCredentialReader.read(
            source: .claudeCLI,
            intent: .automatic
        )) != nil
    }
}
