import Foundation

// MARK: - SubscriptionImportError

/// 订阅凭证导入的可诊断错误. description 面向用户, 不含凭证值.
public enum SubscriptionImportError: Error, Equatable, CustomStringConvertible {
    /// 文件不存在 (附带用途说明, 不含完整路径以外的敏感信息)
    case fileNotFound(String)
    /// 文件读取失败
    case unreadable(String)
    /// 内容不是有效 JSON 对象
    case invalidJSON
    /// 缺少必需字段
    case missingField(String)
    /// CC Switch SQLite 只读查询失败
    case sqliteQueryFailed(String)
    /// CC Switch 中不存在目标 provider 行
    case providerRowNotFound(String)

    public var description: String {
        switch self {
        case .fileNotFound(let usage):
            return "未找到\(usage)"
        case .unreadable(let detail):
            return "文件读取失败: \(detail)"
        case .invalidJSON:
            return "内容不是有效的 JSON 对象"
        case .missingField(let field):
            return "缺少必需字段 \(field)"
        case .sqliteQueryFailed(let detail):
            return "CC Switch 只读查询失败: \(detail)"
        case .providerRowNotFound(let name):
            return "CC Switch 中未找到 provider \(name)"
        }
    }
}

// MARK: - SubscriptionProviderID 显示名

extension SubscriptionProviderID {
    /// 设置页展示名.
    public var displayName: String {
        switch self {
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        case .volcengine: return "火山引擎"
        case .codex: return "Codex"
        case .antigravity: return "Antigravity"
        }
    }

    /// 该 provider 在 Keychain 中占用的全部 account 键.
    /// Codex 返回空数组: v2 分账号键不在此枚举 (由 CodexCredentialStore
    /// 管理), 旧整体库键只供迁移读取, 不得作为运行时删除/读取目标.
    public var credentialAccounts: [String] {
        switch self {
        case .kimi:
            return [SubscriptionCredentialAccount.kimiWebTokens]
        case .deepseek:
            return [SubscriptionCredentialAccount.deepseekAPIKey]
        case .volcengine:
            return [
                SubscriptionCredentialAccount.volcengineAccessKey,
                SubscriptionCredentialAccount.volcengineSecretKey,
            ]
        case .codex:
            return []
        case .antigravity:
            return [SubscriptionCredentialAccount.antigravityOAuth]
        }
    }
}

// MARK: - 验证后状态迁移

extension SubscriptionProviderConfiguration {
    /// 验证后的状态迁移: 记录状态与时间, 仅 ok 时启用 (fail-closed).
    /// failed / needsRelogin 一律保持禁用, 凭证本体是否保留由调用方决定.
    public func applyingVerification(
        _ status: SubscriptionVerificationStatus,
        verifiedAt: String
    ) -> SubscriptionProviderConfiguration {
        var copy = self
        copy.verificationStatus = status
        copy.lastVerifiedAt = verifiedAt
        copy.enabled = (status == .ok)
        return copy
    }
}

// MARK: - KimiPasteParser

/// Kimi 引导粘贴解析: 接受整段 JSON 或 access_token / refresh_token
/// 两段 token (空白或换行分隔). 输出规范的 {"access_token","refresh_token"}
/// JSON 字符串, 供 verifyKimiWebTokensJSON 校验后写入 Keychain.
public enum KimiPasteParser {
    public static func parse(_ input: String) -> Result<String, SubscriptionImportError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.missingField("access_token / refresh_token"))
        }

        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dict = object as? [String: Any] else {
                return .failure(.invalidJSON)
            }
            let access = (dict["access_token"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let refresh = (dict["refresh_token"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !access.isEmpty || !refresh.isEmpty else {
                return .failure(.missingField("access_token / refresh_token"))
            }
            return canonical(access: access, refresh: refresh)
        }

        // 纯文本: 按空白拆分, 第一段作为 access_token, 第二段作为 refresh_token
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        switch tokens.count {
        case 1:
            return canonical(access: tokens[0], refresh: "")
        default:
            return canonical(access: tokens[0], refresh: tokens[1])
        }
    }

    private static func canonical(
        access: String, refresh: String
    ) -> Result<String, SubscriptionImportError> {
        let payload: [String: String] = [
            "access_token": access,
            "refresh_token": refresh,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return .failure(.invalidJSON)
        }
        return .success(json)
    }
}

// MARK: - CodexAuthFileParser

/// `~/.codex/auth.json` 当前账号解析, 结构与 collect_usage.py:1128-1143
/// 的消费方式对齐: tokens.account_id + refresh/access/id token.
public struct CodexCLIAuthAccount: Equatable, Sendable {
    public let accountID: String
    public let email: String?
    public let refreshToken: String
    public let accessToken: String
    public let idToken: String?
    /// OAuth 响应的 `expires_in` (秒); 缺失为 nil, 由上层按 JWT exp 或 1 小时回落.
    public let expiresIn: TimeInterval?
    /// OAuth 响应收到时刻; 与 `expiresIn` 配合计算过期时间.
    public let receivedAt: Date

    public init(
        accountID: String,
        email: String?,
        refreshToken: String,
        accessToken: String,
        idToken: String?,
        expiresIn: TimeInterval? = nil,
        receivedAt: Date = Date()
    ) {
        self.accountID = accountID
        self.email = email
        self.refreshToken = refreshToken
        self.accessToken = accessToken
        self.idToken = idToken
        self.expiresIn = expiresIn
        self.receivedAt = receivedAt
    }
}

public enum CodexAuthFileParser {
    public static func parse(
        _ json: String
    ) -> Result<CodexCLIAuthAccount, SubscriptionImportError> {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        guard let tokens = dict["tokens"] as? [String: Any] else {
            return .failure(.missingField("tokens"))
        }
        let accountID = (tokens["account_id"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty else {
            return .failure(.missingField("tokens.account_id"))
        }
        let refresh = (tokens["refresh_token"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !refresh.isEmpty else {
            return .failure(.missingField("tokens.refresh_token"))
        }
        let access = (tokens["access_token"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else {
            return .failure(.missingField("tokens.access_token"))
        }
        // email 优先取 tokens 内, 兼容顶层 (collect_usage 消费时允许缺省)
        let email = (tokens["email"] as? String ?? dict["email"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let idToken = (tokens["id_token"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(CodexCLIAuthAccount(
            accountID: accountID,
            email: email.isEmpty ? nil : email,
            refreshToken: refresh,
            accessToken: access,
            idToken: idToken.isEmpty ? nil : idToken
        ))
    }
}

// MARK: - CodexAccountsLibrary

/// Codex 账号库 (CC Switch 同构 {"accounts": {id: {...}}}) 的合并,
/// 摘要与 active 选择纯逻辑.
public enum CodexAccountsLibrary {
    /// 把 CLI 当前账号合并进既有账号库 JSON, 返回新的账号库 JSON.
    /// existingJSON 为 nil 或空时创建新库; 同 id 覆盖, 其他账号保留.
    public static func merging(
        existingJSON: String?,
        account: CodexCLIAuthAccount
    ) -> Result<String, SubscriptionImportError> {
        var accounts: [String: Any] = [:]
        if let existingJSON,
           let data = existingJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any],
           let existing = dict["accounts"] as? [String: Any] {
            accounts = existing
        }
        var entry: [String: Any] = [
            "refresh_token": account.refreshToken,
            "access_token": account.accessToken,
        ]
        if let email = account.email { entry["email"] = email }
        if let idToken = account.idToken { entry["id_token"] = idToken }
        accounts[account.accountID] = entry

        guard let data = try? JSONSerialization.data(
            withJSONObject: ["accounts": accounts], options: [.sortedKeys]
        ), let json = String(data: data, encoding: .utf8) else {
            return .failure(.invalidJSON)
        }
        return .success(json)
    }

    /// 账号库的展示摘要: 账号数与邮箱前缀列表.
    /// 无 email 时回落 id 前 8 位, 与 collect_usage.py:1148 一致.
    public static func summary(of json: String) -> (count: Int, emailPrefixes: [String]) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let accounts = dict["accounts"] as? [String: Any] else {
            return (0, [])
        }
        var prefixes: [String] = []
        for (accountID, entry) in accounts.sorted(by: { $0.key < $1.key }) {
            let email = (entry as? [String: Any])?["email"] as? String ?? ""
            if !email.isEmpty {
                prefixes.append(email.split(separator: "@").first.map(String.init) ?? email)
            } else {
                prefixes.append(String(accountID.prefix(8)))
            }
        }
        return (accounts.count, prefixes)
    }

    /// 账号库中的全部账号 id (排序后, 保证确定性).
    public static func accountIDs(of json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let accounts = dict["accounts"] as? [String: Any] else {
            return []
        }
        return accounts.keys.sorted()
    }

    /// 选择 active 账号: 优先 CLI 当前账号 (通常最新), 其次保留既有 active,
    /// 最后回落排序后的第一个账号; 库为空返回 nil.
    public static func chooseActiveAccount(
        cliAccountID: String?,
        existingActive: String?,
        accountIDs: [String]
    ) -> String? {
        guard !accountIDs.isEmpty else { return nil }
        if let cliAccountID, accountIDs.contains(cliAccountID) {
            return cliAccountID
        }
        if let existingActive, accountIDs.contains(existingActive) {
            return existingActive
        }
        return accountIDs.sorted().first
    }
}

// MARK: - VolcengineSecretDecoder

/// 火山引擎 SK 解码, 与 collect_usage.py:929-939 `_volc_decode_secret`
/// 一致: 从原始值出发做最多 2 次 base64 解码尝试, 收集全部候选.
public enum VolcengineSecretDecoder {
    /// 返回 [raw, dec1?, dec2?], 解码失败 (非 base64 或非 UTF-8) 即停止.
    public static func decodeCandidates(_ raw: String) -> [String] {
        var candidates = [raw]
        var current = raw
        for _ in 0..<2 {
            guard let decodedData = Data(
                base64Encoded: current, options: [.ignoreUnknownCharacters]
            ), let decoded = String(data: decodedData, encoding: .utf8),
              !decoded.isEmpty else {
                break
            }
            candidates.append(decoded)
            current = decoded
        }
        return candidates
    }

    /// 取最深的成功解码候选. CC Switch 存储的 SK 经过 base64 编码,
    /// 导入 Keychain 时保存解码后的真实 SK; collector 运行时仍会对
    /// 注入值重做一次候选尝试 (collect_usage.py:982), 语义兼容.
    public static func fullyDecoded(_ raw: String) -> String {
        decodeCandidates(raw).last ?? raw
    }
}

// MARK: - CCSwitchVolcengineImporter

/// 从 CC Switch 数据库只读导入火山引擎 AK/SK.
/// 始终以 SQLite URI mode=ro 打开, 只执行 SELECT, 绝不写入.
/// 读取 providers 表 name='火山Codingplan' 行的
/// meta.usage_script.accessKeyId / secretAccessKey (回落 meta 顶层,
/// 与 collect_usage.py:975-977 一致).
public struct CCSwitchVolcengineImporter: Sendable {
    public static let providerName = "火山Codingplan"

    private let sqlite3Path: String
    private let timeout: TimeInterval

    public init(sqlite3Path: String = "/usr/bin/sqlite3", timeout: TimeInterval = 8) {
        self.sqlite3Path = sqlite3Path
        self.timeout = timeout
    }

    /// 只读查询并返回解码后的 AK/SK. 数据库文件不被修改.
    public func importCredentials(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) async -> Result<(accessKey: String, secretKey: String), SubscriptionImportError> {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return .failure(.fileNotFound("CC Switch 数据库"))
        }

        let probe = AsyncProcessProbe(timeout: timeout)
        let result = await probe.run(
            executablePath: sqlite3Path,
            arguments: [
                "file:\(databaseURL.path)?mode=ro",
                "SELECT meta FROM providers WHERE name='\(Self.providerName)' LIMIT 1;",
            ]
        )

        let output: String
        switch result {
        case .success(let text):
            output = text
        case .timedOut:
            return .failure(.sqliteQueryFailed("查询超时"))
        case .cancelled:
            return .failure(.sqliteQueryFailed("查询被取消"))
        case .launchFailed:
            return .failure(.sqliteQueryFailed("sqlite3 启动失败"))
        case .nonZeroExit(_, let stderrSummary):
            return .failure(.sqliteQueryFailed(stderrSummary ?? "未知错误"))
        }

        let metaJSON = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !metaJSON.isEmpty else {
            return .failure(.providerRowNotFound(Self.providerName))
        }
        guard let data = metaJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let meta = object as? [String: Any] else {
            return .failure(.invalidJSON)
        }

        let usageScript = meta["usage_script"] as? [String: Any] ?? [:]
        let ak = (
            usageScript["accessKeyId"] as? String
                ?? meta["accessKeyId"] as? String ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let rawSK = (
            usageScript["secretAccessKey"] as? String
                ?? meta["secretAccessKey"] as? String ?? ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty else {
            return .failure(.missingField("meta.usage_script.accessKeyId"))
        }
        guard !rawSK.isEmpty else {
            return .failure(.missingField("meta.usage_script.secretAccessKey"))
        }

        return .success((
            accessKey: ak,
            secretKey: VolcengineSecretDecoder.fullyDecoded(rawSK)
        ))
    }
}
