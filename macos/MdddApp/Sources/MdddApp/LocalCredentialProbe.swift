import Foundation
import MdddOnboardingCore

// MARK: - AgyKeychainReadResult

/// Antigravity 登录 Keychain 读取结果 (区分缺失与解码失败, 供设置错误文案).
enum AgyKeychainReadResult: Equatable {
    case notFound
    case decoded(String)
    case decodeFailed
}

// MARK: - LocalCredentialProbe

/// 本机文件与系统 Keychain 探测 (App 层 I/O 边界).
///
/// 无 AppModel 副作用; Coordinator 负责刷新 model / configured 状态.
/// Claude / Grok Keychain 探测使用 `security find-generic-password` 且不带 `-w`,
/// 不读密码数据, 不触发授权弹窗; Antigravity 导入路径带 `-w` 会触发弹窗.
struct LocalCredentialProbe: Sendable {
    /// agy >= 1.1.8 登录 Keychain (go-keyring) service / account.
    static let agyKeychainService = "gemini"
    static let agyKeychainAccount = "antigravity"
    /// Claude CLI 凭证 Keychain service 名 (Claude Code-credentials, 无 account).
    static let claudeKeychainService = "Claude Code-credentials"

    let homeURL: URL
    /// 可注入; 默认执行 /usr/bin/security.
    private let securityRunner: @Sendable ([String]) -> String?

    init(
        homeURL: URL,
        securityRunner: (@Sendable ([String]) -> String?)? = nil
    ) {
        self.homeURL = homeURL
        self.securityRunner = securityRunner ?? Self.defaultRunSecurity
    }

    // MARK: - 本机文件存在性 (设置页条件渲染)

    func kimiLocalTokensFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(".config/kimi-dashboard/kimi-web-tokens.json")
                .path
        )
    }

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

    func antigravityTokenFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: homeURL
                .appendingPathComponent(
                    ".gemini/antigravity-cli/antigravity-oauth-token"
                ).path
        )
    }

    // MARK: - Claude / Grok 本机登录态 (实时只读, 不导入不回写)

    /// 解析 ~/.grok/auth.json: OIDC/legacy 条目 key 非空且未过期视为可用
    /// (与 Python read_grok_token / SubscriptionCredentialEvaluator 同语义).
    /// 损坏/缺失/过期返回 false.
    func grokLocalAuthAvailable(now: Date = Date()) -> Bool {
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

    /// 探测登录 Keychain 是否存在 Claude CLI 凭证条目
    /// (不读密码数据, 不触发授权弹窗).
    func claudeKeychainItemExists() -> Bool {
        securityRunner([
            "find-generic-password",
            "-s", Self.claudeKeychainService,
        ]) != nil
    }

    /// 探测登录 Keychain 是否存在 agy 令牌条目
    /// (不读密码数据, 不触发授权弹窗).
    func agyKeychainItemExists() -> Bool {
        securityRunner([
            "find-generic-password",
            "-s", Self.agyKeychainService,
            "-a", Self.agyKeychainAccount,
        ]) != nil
    }

    /// 读取并解码 agy Keychain 令牌 ("go-keyring-base64:" 前缀 + base64 JSON).
    /// 读取密码数据会触发系统钥匙串授权弹窗, 仅在用户点击导入时调用.
    func readAgyKeychainCredential() -> AgyKeychainReadResult {
        guard var raw = securityRunner([
            "find-generic-password",
            "-s", Self.agyKeychainService,
            "-a", Self.agyKeychainAccount,
            "-w",
        ]) else {
            return .notFound
        }
        let prefix = "go-keyring-base64:"
        guard raw.hasPrefix(prefix) else {
            return .decoded(raw)
        }
        raw = String(raw.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: raw),
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else {
            return .decodeFailed
        }
        return .decoded(text)
    }

    // MARK: - security 子进程

    /// 执行 /usr/bin/security, 退出码 0 返回 stdout (去首尾空白), 否则 nil.
    private static func defaultRunSecurity(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        return text
    }
}
