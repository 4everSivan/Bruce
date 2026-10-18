import Foundation
@testable import BruceOnboardingCore

// MARK: - DeepSeek ledger / Codex identity / Expiry evaluator

extension BruceOnboardingCoreHarness {
    // MARK: - Codex account identity (任务 1)

    /// service ID 必须与 Rust Collector 的稳定 ID 规则一致.
    /// 固定向量: accountID = "acc-1" -> SHA256 前 16 位 hex.
    static func codexAccountIdentityServiceIDMatchesRustContract() throws {
        // SHA256("acc-1") 的前 16 位 hex = "cf9df9b99fc0a24b".
        let id = CodexAccountIdentity.serviceID(for: "acc-1")
        try coreExpect(id == "codex_cf9df9b99fc0a24b", "service ID 不匹配 Rust contract: \(id)")
    }

    /// legacy ID 保留旧格式供合并器惰性迁移.
    static func codexAccountIdentityLegacyID() throws {
        let legacy = CodexAccountIdentity.legacyServiceID(for: "acc-1")
        try coreExpect(legacy == "codex_acc-1", "legacy ID 错误: \(legacy)")
    }

    // MARK: - SubscriptionCredentialEvaluator (Phase 1 统一过期检测)

    /// 回归: 带过期 expires_at 的 grok auth.json 必须判定为 .expired
    /// (当前 bug: Swift 显示层只看 key 非空, 不查过期).
    static func evaluatorGrokExpiredReturnsExpired() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000) // 2026-08-04
        let json = """
        {"https://auth.x.ai::b1a00492": {"key": "some-key", "expires_at": "2026-07-28T12:17:14.147765Z"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: json, now: now) == .expired,
            "过期 grok token 应判定为 expired"
        )
    }

    /// OIDC scope 优先于 legacy; 未过期返回 valid.
    static func evaluatorGrokValidOIDCPreferredOverLegacy() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        // 1789000000 = 2026-09-08 (未来), 1785000000 = 2026-07-25 (过去)
        let json = """
        {"https://accounts.x.ai/sign-in": {"key": "legacy-key", "expires_at": 1789000000},
         "https://auth.x.ai::oidc-id": {"key": "oidc-key", "expires_at": 1789000000}}
        """
        let status = SubscriptionCredentialEvaluator.grokStatus(of: json, now: now)
        try coreExpect(status == .valid, "OIDC 优先且未过期应 valid, got \(status)")
        // legacy 过期但 OIDC 有效: 仍应 valid (OIDC 优先)
        let legacyExpired = """
        {"https://accounts.x.ai/sign-in": {"key": "legacy-key", "expires_at": 1785000000},
         "https://auth.x.ai::oidc-id": {"key": "oidc-key", "expires_at": 1789000000}}
        """
        let status2 = SubscriptionCredentialEvaluator.grokStatus(of: legacyExpired, now: now)
        try coreExpect(status2 == .valid, "OIDC 有效时 legacy 过期不影响, got \(status2)")
    }

    /// 毫秒时间戳 (>1e12 分支).
    static func evaluatorGrokMillisTimestamp() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let json = """
        {"https://auth.x.ai::a": {"key": "k", "expires_at": 1786000000000}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: json, now: now) == .valid,
            "毫秒时间戳未来应 valid"
        )
        let expired = """
        {"https://auth.x.ai::a": {"key": "k", "expires_at": 1780000000000}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: expired, now: now) == .expired,
            "毫秒时间戳过去应 expired"
        )
    }

    /// ISO 字符串时间戳.
    static func evaluatorGrokISOString() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let future = """
        {"https://auth.x.ai::a": {"key": "k", "expires_at": "2026-12-31T12:00:00Z"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: future, now: now) == .valid,
            "ISO 未来时间应 valid"
        )
    }

    /// 空 key 条目跳过; 损坏 JSON 或缺失条目 -> missing/malformed.
    static func evaluatorGrokMissingKeyAndCorrupt() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let emptyKey = """
        {"https://auth.x.ai::a": {"key": ""}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: emptyKey, now: now) == .missing,
            "空 key 应 missing"
        )
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: "not-json", now: now) == .malformed,
            "损坏 JSON 应 malformed"
        )
        let noExpiry = """
        {"https://auth.x.ai::a": {"key": "k"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.grokStatus(of: noExpiry, now: now) == .valid,
            "无 expires_at 应视为未过期"
        )
    }

    /// Claude: 过期返回 expired; 支持 claude.ai_oauth legacy 键.
    static func evaluatorClaudeExpiredAndLegacyKey() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let expired = """
        {"claudeAiOauth": {"accessToken": "tok", "expiresAt": "2026-07-01T00:00:00Z"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: expired, now: now) == .expired,
            "Claude 过期应 expired"
        )
        let legacy = """
        {"claude.ai_oauth": {"accessToken": "tok", "expiresAt": "2026-12-31T00:00:00Z"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: legacy, now: now) == .valid,
            "legacy 键且未过期应 valid"
        )
    }

    /// Claude: 空 token -> missing.
    static func evaluatorClaudeMissingToken() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let noToken = """
        {"claudeAiOauth": {"expiresAt": "2026-12-31T00:00:00Z"}}
        """
        try coreExpect(
            SubscriptionCredentialEvaluator.claudeStatus(of: noToken, now: now) == .missing,
            "Claude 无 token 应 missing"
        )
    }

    /// isExpired 与 Rust Collector expiry 语义逐条对齐: nil/不可解析 -> false.
    static func evaluatorIsExpiredSemanticsMatchRustContract() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        try coreExpect(
            !SubscriptionCredentialEvaluator.isExpired(nil, now: now),
            "nil 应视为未过期"
        )
        try coreExpect(
            !SubscriptionCredentialEvaluator.isExpired("garbage", now: now),
            "不可解析字符串应视为未过期"
        )
        try coreExpect(
            SubscriptionCredentialEvaluator.isExpired(1_785_000_000.0, now: now),
            "过去秒时间戳应过期"
        )
        try coreExpect(
            !SubscriptionCredentialEvaluator.isExpired(1_786_000_000_000.0, now: now),
            "毫秒时间戳应换算后比较 (1.786e12 ms = 未来)"
        )
    }

    /// 共享 `tests/fixtures/credential-expiry/*.json`, 锁定
    /// isExpired + claudeStatus/grokStatus 的跨实现矩阵.
    static func evaluatorSharedExpiryFixtures() throws {
        let dir = try credentialExpiryFixturesDirectory()
        let required: Set<String> = [
            "claude_valid.json",
            "claude_expired_ms.json",
            "claude_expired_s.json",
            "claude_bad_date.json",
            "grok_valid.json",
            "grok_expired.json",
        ]
        let urls = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try coreExpect(!urls.isEmpty, "credential-expiry fixtures 目录为空: \(dir.path)")
        let found = Set(urls.map(\.lastPathComponent))
        let missing = required.subtracting(found)
        try coreExpect(missing.isEmpty, "缺少共享过期 fixture: \(missing.sorted())")

        for url in urls {
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let fixture = root as? [String: Any] else {
                throw CoreTestFailure.expectation("\(url.lastPathComponent) 根节点必须是对象")
            }
            guard let nowTS = fixture["now_ts"] as? Double
                    ?? (fixture["now_ts"] as? NSNumber)?.doubleValue,
                  let expectedExpired = fixture["expected_is_expired"] as? Bool,
                  let expectedStatus = fixture["expected_status"] as? String,
                  let provider = fixture["provider"] as? String,
                  let credential = fixture["credential"] else {
                throw CoreTestFailure.expectation(
                    "\(url.lastPathComponent) 缺少 now_ts/expected_*/provider/credential"
                )
            }
            let now = Date(timeIntervalSince1970: nowTS)
            let expiredGot = SubscriptionCredentialEvaluator.isExpired(
                fixture["expires_value"], now: now
            )
            try coreExpect(
                expiredGot == expectedExpired,
                "\(url.lastPathComponent): isExpired=\(expiredGot), expected \(expectedExpired)"
            )

            let credentialData = try JSONSerialization.data(withJSONObject: credential)
            guard let credentialJSON = String(data: credentialData, encoding: .utf8) else {
                throw CoreTestFailure.expectation(
                    "\(url.lastPathComponent) credential 无法编码为 UTF-8"
                )
            }
            let status: SubscriptionCredentialStatus
            switch provider {
            case "claude":
                status = SubscriptionCredentialEvaluator.claudeStatus(
                    of: credentialJSON, now: now
                )
            case "grok":
                status = SubscriptionCredentialEvaluator.grokStatus(
                    of: credentialJSON, now: now
                )
            default:
                throw CoreTestFailure.expectation(
                    "\(url.lastPathComponent) 未知 provider: \(provider)"
                )
            }
            let statusName: String
            switch status {
            case .missing: statusName = "missing"
            case .valid: statusName = "valid"
            case .expired: statusName = "expired"
            case .malformed: statusName = "malformed"
            case .refreshPending: statusName = "refreshPending"
            }
            try coreExpect(
                statusName == expectedStatus,
                "\(url.lastPathComponent): status=\(statusName), expected \(expectedStatus)"
            )
        }
    }

    /// 定位仓库根下 `tests/fixtures/credential-expiry`.
    /// 优先从本 harness 源文件向上走; 回退 cwd (verify-local 在仓库根执行).
    static func credentialExpiryFixturesDirectory() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = url.appendingPathComponent(
                "tests/fixtures/credential-expiry", isDirectory: true
            )
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        let cwd = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ).appendingPathComponent("tests/fixtures/credential-expiry", isDirectory: true)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDir),
           isDir.boolValue {
            return cwd
        }
        throw CoreTestFailure.expectation(
            "无法定位 tests/fixtures/credential-expiry (从 #filePath 与 cwd 均未找到)"
        )
    }

}
