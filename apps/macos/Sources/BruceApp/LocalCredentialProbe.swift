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
        let url = homeURL.appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return SubscriptionCredentialEvaluator.claudeStatus(
            of: json, now: now
        ) == .valid
    }

    /// C059: 本机 Claude 登录态探测 (automatic 读取序: Keychain 静默 → 凭证文件).
    /// 返回 nil = 未读到可用形态 (无登录态 / 内容损坏); refreshPending 与 expired
    /// 均计为「检测到登录态」(与 cc-switch 一致: 过期也照常试一把查询)。
    func claudeLocalCredentialStatus(now: Date = Date()) -> SubscriptionCredentialStatus? {
        guard let raw = (try? externalCredentialReader.read(
            source: .claudeCLI,
            intent: .automatic
        )) else { return nil }
        let status = SubscriptionCredentialEvaluator.claudeStatus(of: raw, now: now)
        switch status {
        case .valid, .expired, .refreshPending:
            return status
        case .missing, .malformed:
            return nil
        }
    }

    /// C060: 「从本机导入」读取 (userInitiated: Keychain 静默优先 → 文件回退,
    /// 与 cc-switch 读取序一致; 全程 UISkip 绝不弹窗; Keychain 读取无条件尝试)。
    func claudeLocalCredentialForImport() -> Result<String, SubscriptionImportError> {
        guard let raw = (try? externalCredentialReader.read(
            source: .claudeCLI,
            intent: .userInitiated
        )) else {
            return .failure(.fileNotFound(
                "本机 Claude 登录态 (钥匙串与 ~/.claude/.credentials.json 均不可读), 请先登录 Claude CLI 或改用粘贴导入"
            ))
        }
        return ClaudePasteParser.parse(raw)
    }
}
