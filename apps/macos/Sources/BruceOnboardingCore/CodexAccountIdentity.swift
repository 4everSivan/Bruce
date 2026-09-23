import CryptoKit
import Foundation

/// Codex 账号身份契约: Swift 与 Rust 共享稳定 service ID 生成.
/// currentID = "codex_" + SHA256(accountID).hexPrefix(16)
/// legacyID  = "codex_" + accountID[:8]  (惰性迁移用)
public enum CodexAccountIdentity {
    /// 当前格式 service ID: codex_ + SHA256(accountID) 前 16 位 hex.
    public static func serviceID(for accountID: String) -> String {
        "codex_" + sha256HexPrefix16(accountID)
    }

    /// 旧格式 service ID: codex_ + accountID 前 8 位. 仅合并器惰性迁移使用.
    public static func legacyServiceID(for accountID: String) -> String {
        "codex_" + String(accountID.prefix(8))
    }

    /// SHA-256 hex 前 16 位.
    public static func sha256HexPrefix16(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
