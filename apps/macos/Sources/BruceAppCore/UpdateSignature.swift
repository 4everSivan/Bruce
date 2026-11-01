import CryptoKit
import Foundation

// MARK: - 更新包来源签名 (07-软件更新 §4.2 R6.2, C174)

/// 发布签名校验: CI 以 `cargo tauri signer sign` 用与 Windows updater 同一把 minisign 私钥签 `Bruce.zip`,
/// 签名随清单 `platforms.darwin-universal.signature` 下发 (base64 编码的 `.sig` 文件全文).
/// 校验口径与 tauri-plugin-updater (minisign-verify) 一致: 文件签名 + trusted comment 的全局签名都必须通过.
package enum UpdateSignature {
    /// 内置公钥, 与 `apps/win/src-tauri/tauri.conf.json` 的 `plugins.updater.pubkey` 逐字相同
    /// (base64 编码的 minisign 公钥文件); `scripts/check-release-pipeline.mjs` 断言两端一致.
    package static let trustedPublicKey =
        "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDNDODk4ODBDNjcyRDdDMzMKUldRemZDMW5ESWlKUEFTeXdGbmdjVlFzZzZKbGh6R1NObEMxQjY0TG81cU5VOE5sNDVMbVVvb3gK"

    package enum Failure: Error, Equatable, Sendable {
        case malformedPublicKey
        case malformedSignature
        case keyMismatch
        case invalidSignature
        case unreadableFile
    }

    package struct PublicKey: Sendable {
        package let keyID: Data
        package let key: Curve25519.Signing.PublicKey

        /// `encoded`: base64 编码的 minisign 公钥文件 (untrusted comment 行 + 公钥行).
        package init(encoded: String) throws {
            guard let lines = UpdateSignature.decodedLines(encoded),
                  lines.count >= 2,
                  lines[0].hasPrefix("untrusted comment:"),
                  let raw = Data(base64Encoded: lines[1]),
                  raw.count == 42,
                  raw.prefix(2) == Data("Ed".utf8),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw.suffix(32)) else {
                throw Failure.malformedPublicKey
            }
            keyID = Data(raw[2..<10])
            self.key = key
        }
    }

    package struct Signature: Sendable {
        package enum Algorithm: Sendable {
            /// `Ed`: 直接对文件全文签名 (minisign 旧格式).
            case legacy
            /// `ED`: 对 BLAKE2b-512(文件) 签名 (minisign / tauri signer 默认).
            case prehashed
        }

        package let algorithm: Algorithm
        package let keyID: Data
        package let signature: Data
        package let trustedComment: String
        package let globalSignature: Data

        /// `encoded`: base64 编码的 minisign `.sig` 文件全文.
        package init(encoded: String) throws {
            guard let lines = UpdateSignature.decodedLines(encoded),
                  lines.count >= 4,
                  lines[0].hasPrefix("untrusted comment:"),
                  let raw = Data(base64Encoded: lines[1]),
                  raw.count == 74,
                  lines[2].hasPrefix(Self.trustedCommentPrefix),
                  let global = Data(base64Encoded: lines[3]),
                  global.count == 64 else {
                throw Failure.malformedSignature
            }
            switch raw.prefix(2) {
            case Data("Ed".utf8): algorithm = .legacy
            case Data("ED".utf8): algorithm = .prehashed
            default: throw Failure.malformedSignature
            }
            keyID = Data(raw[2..<10])
            signature = Data(raw[10..<74])
            trustedComment = String(lines[2].dropFirst(Self.trustedCommentPrefix.count))
            globalSignature = global
        }

        private static let trustedCommentPrefix = "trusted comment: "
    }

    /// 以 `publicKey` 校验 `fileURL` 的签名; 任何格式问题或校验不通过都抛错, 不存在「跳过」分支.
    package static func verify(
        fileAt fileURL: URL,
        signature encodedSignature: String,
        publicKey encodedPublicKey: String = trustedPublicKey
    ) throws {
        let publicKey = try PublicKey(encoded: encodedPublicKey)
        let signature = try Signature(encoded: encodedSignature)
        guard signature.keyID == publicKey.keyID else {
            throw Failure.keyMismatch
        }
        let message: Data
        do {
            switch signature.algorithm {
            case .prehashed: message = try blake2b512(of: fileURL)
            case .legacy: message = try Data(contentsOf: fileURL)
            }
        } catch {
            throw Failure.unreadableFile
        }
        try verify(signature, signedMessage: message, publicKey: publicKey)
    }

    /// `signedMessage`: 预哈希签名为 BLAKE2b-512(文件), 旧格式为文件全文.
    package static func verify(
        _ signature: Signature,
        signedMessage: Data,
        publicKey: PublicKey
    ) throws {
        guard signature.keyID == publicKey.keyID,
              publicKey.key.isValidSignature(signature.signature, for: signedMessage),
              publicKey.key.isValidSignature(
                  signature.globalSignature,
                  for: signature.signature + Data(signature.trustedComment.utf8)
              ) else {
            throw Failure.invalidSignature
        }
    }

    package static func blake2b512(of fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = Blake2b512()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalize()
    }

    private static func decodedLines(_ encoded: String) -> [String]? {
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        // 不裁剪行内空白: trusted comment 原文参与全局签名.
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }
}
