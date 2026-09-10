import Foundation
import BruceOnboardingCore

// MARK: - LocalCredentialProbe

/// 本机文件与系统 Keychain 探测 (App 层 I/O 边界).
///
/// 无 AppModel 副作用; Coordinator 负责刷新 model / configured 状态.
/// Claude / Grok Keychain 探测使用 `security find-generic-password` 且不带 `-w`,
/// 不读密码数据, 不触发授权弹窗.
struct LocalCredentialProbe: Sendable {
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
