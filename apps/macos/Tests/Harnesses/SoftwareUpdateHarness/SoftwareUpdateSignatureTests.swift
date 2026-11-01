import Foundation
@testable import BruceAppCore

// MARK: - 更新包来源签名 (C174): BLAKE2b 向量 / 真实发布签名 / 伪造拒绝 / 安装前拦截

enum SoftwareUpdateSignatureTests {
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func pattern(_ count: Int, _ byte: (Int) -> UInt8) -> [UInt8] {
        (0..<count).map(byte)
    }

    /// RFC 7693 附录 A 与跨 128 字节块边界的向量; 期望值由 Node / OpenSSL `blake2b512` 独立计算.
    static func blake2bMatchesStandardVectors() throws {
        try expectEqual(
            hex(Blake2b512.hash([UInt8]())),
            "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce",
            "BLAKE2b-512(\"\")"
        )
        try expectEqual(
            hex(Blake2b512.hash(Array("abc".utf8))),
            "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923",
            "BLAKE2b-512(\"abc\") RFC 7693"
        )
        let boundaries: [(Int, String)] = [
            (1, "2fa3f686df876995167e7c2e5d74c4c7b6e48f8068fe0e44208344d480f7904c36963e44115fe3eb2a3ac8694c28bcb4f5a0f3276f2e79487d8219057a506e4b"),
            (127, "b6292669ccd38d5f01caae96ba272c76a879a45743afa0725d83b9ebb26665b731f1848c52f11972b6644f554c064fa90780dbbbf3a89d4fc31f67df3e5857ef"),
            (128, "2319e3789c47e2daa5fe807f61bec2a1a6537fa03f19ff32e87eecbfd64b7e0e8ccff439ac333b040f19b0c4ddd11a61e24ac1fe0f10a039806c5dcc0da3d115"),
            (129, "f59711d44a031d5f97a9413c065d1e614c417ede998590325f49bad2fd444d3e4418be19aec4e11449ac1a57207898bc57d76a1bcf3566292c20c683a5c4648f"),
            (255, "fe2c02da499516b0e9fb2dd70c49eb3629039f632e20a880946fb7bc97a7ab09deb7d48774d7f0648141c9d9ede19ae6e0dbf07863a128cf4b00195f0f179f74"),
            (256, "93463ac058b6163eb43be3f5bb32b28541498f4e3366f1effe253ad44e1e076e41c3616046027c82a7124f8f4746668ad10b12e8e25a95ac8f3151df01cd5a93"),
            (257, "9ca40e2ddee9436dbbd08efc65dbaf4870059f5eb3d76efd20241ae5bf13c60f250b882ea5c564838257a3fc95c496819ace2c6490b55b268535208dfc31822c"),
        ]
        for (count, expected) in boundaries {
            try expectEqual(hex(Blake2b512.hash(pattern(count) { UInt8($0 % 251) })), expected, "BLAKE2b-512 \(count) 字节")
        }

        // 分块喂入 (含 1 字节与恰好一块的切分) 与一次性输入一致, 并与独立实现相符.
        let large = pattern(1_000_003) { UInt8(($0 * 7) % 256) }
        var hasher = Blake2b512()
        var offset = 0
        for size in [1, 127, 128, 129, 4096, 65_536] {
            hasher.update(large[offset..<(offset + size)])
            offset += size
        }
        hasher.update(large[offset...])
        let expectedLarge = "6334808fa012f92e3dab7bdfebb2dd4224df78f765ac2a2f82163b3ee52472152897906e805a9b389d982414a856de5523f0ddbc11ebdbd0c0a6b4b5124b12c6"
        try expectEqual(hex(hasher.finalize()), expectedLarge, "BLAKE2b-512 分块 1,000,003 字节")
        try expectEqual(hex(Blake2b512.hash(large)), expectedLarge, "BLAKE2b-512 一次性 1,000,003 字节")
    }

    private struct PublishedRelease: Decodable {
        let version: String
        let blake2b512: String
        let signature: String
    }

    /// 已公开发布的 v0.15.0: 真实 tauri signer 签名 + 内置公钥必须校验通过 (离线, 只用包体摘要).
    static func publishedReleaseSignatureVerifiesWithEmbeddedKey(repoRoot: URL) throws {
        let url = repoRoot.appendingPathComponent("tests/fixtures/update-signature/release-v0.15.0.json")
        let fixture = try JSONDecoder().decode(PublishedRelease.self, from: Data(contentsOf: url))
        let publicKey = try UpdateSignature.PublicKey(encoded: UpdateSignature.trustedPublicKey)
        let signature = try UpdateSignature.Signature(encoded: fixture.signature)
        try expect(signature.algorithm == .prehashed, "发布签名应为预哈希 (ED)")
        try expectEqual(signature.keyID, publicKey.keyID, "发布签名的 key id 应为内置公钥")
        try expect(signature.trustedComment.contains("file:Bruce.zip"), "trusted comment 原文保留")

        var digest = Data()
        var index = fixture.blake2b512.startIndex
        while index < fixture.blake2b512.endIndex {
            let next = fixture.blake2b512.index(index, offsetBy: 2)
            digest.append(UInt8(fixture.blake2b512[index..<next], radix: 16)!)
            index = next
        }
        try UpdateSignature.verify(signature, signedMessage: digest, publicKey: publicKey)

        var flipped = digest
        flipped[0] ^= 0x01
        try expectThrows(UpdateSignature.Failure.invalidSignature, "包体摘要改 1 位即拒绝") {
            try UpdateSignature.verify(signature, signedMessage: flipped, publicKey: publicKey)
        }
        let other = try UpdateSignature.PublicKey(encoded: TestSigningKey(keyID: publicKey.keyID).publicKey)
        try expectThrows(UpdateSignature.Failure.invalidSignature, "同 key id 的另一把公钥拒绝") {
            try UpdateSignature.verify(signature, signedMessage: digest, publicKey: other)
        }
    }

    static func verifierAcceptsValidAndRejectsForgeries() throws {
        let root = try TemporaryDirectories.make("signature")
        defer { TemporaryDirectories.remove(root) }
        let file = root.appendingPathComponent("Bruce.zip")
        try Data((0..<3000).map { UInt8($0 % 256) }).write(to: file)
        let key = TestSigningKey.shared

        try UpdateSignature.verify(fileAt: file, signature: try key.sign(file), publicKey: key.publicKey)
        try UpdateSignature.verify(
            fileAt: file,
            signature: try key.sign(file, prehashed: false),
            publicKey: key.publicKey
        )

        let valid = try key.sign(file)
        let tampered = root.appendingPathComponent("tampered.zip")
        var bytes = try Data(contentsOf: file)
        bytes[1500] ^= 0x80
        try bytes.write(to: tampered)
        try expectThrows(UpdateSignature.Failure.invalidSignature, "篡改包体") {
            try UpdateSignature.verify(fileAt: tampered, signature: valid, publicKey: key.publicKey)
        }

        let parsed = try UpdateSignature.Signature(encoded: valid)
        let forgedComment = TestSigningKey.encode(
            algorithm: "ED",
            keyID: key.keyID,
            signature: parsed.signature,
            trustedComment: "timestamp:9999999999\tfile:Bruce.zip",
            globalSignature: parsed.globalSignature
        )
        try expectThrows(UpdateSignature.Failure.invalidSignature, "篡改 trusted comment (全局签名失配)") {
            try UpdateSignature.verify(fileAt: file, signature: forgedComment, publicKey: key.publicKey)
        }
        let downgraded = TestSigningKey.encode(
            algorithm: "Ed",
            keyID: key.keyID,
            signature: parsed.signature,
            trustedComment: parsed.trustedComment,
            globalSignature: parsed.globalSignature
        )
        try expectThrows(UpdateSignature.Failure.invalidSignature, "预哈希签名改标为旧格式") {
            try UpdateSignature.verify(fileAt: file, signature: downgraded, publicKey: key.publicKey)
        }

        let stranger = TestSigningKey()
        try expectThrows(UpdateSignature.Failure.keyMismatch, "他人密钥签名 (key id 不符)") {
            try UpdateSignature.verify(fileAt: file, signature: try stranger.sign(file), publicKey: key.publicKey)
        }
        let impostor = TestSigningKey(keyID: key.keyID)
        try expectThrows(UpdateSignature.Failure.invalidSignature, "冒用 key id 的他人密钥") {
            try UpdateSignature.verify(fileAt: file, signature: try impostor.sign(file), publicKey: key.publicKey)
        }

        let unknownAlgorithm = TestSigningKey.encode(
            algorithm: "Xx",
            keyID: key.keyID,
            signature: parsed.signature,
            trustedComment: parsed.trustedComment,
            globalSignature: parsed.globalSignature
        )
        let truncated = Data(
            String(decoding: Data(base64Encoded: valid)!, as: UTF8.self)
                .split(separator: "\n").prefix(2).joined(separator: "\n").utf8
        ).base64EncodedString()
        let malformed: [(String, String)] = [
            ("空签名", ""),
            ("非 base64", "not base64 !!"),
            ("非 minisign 文本", Data("hello".utf8).base64EncodedString()),
            ("缺 trusted comment 与全局签名", truncated),
            ("未知算法", unknownAlgorithm),
            ("清单 fixture 的占位签名", "RkFLRS1NSU5JU0lHTi1EQVJXSU4tRklYVFVSRQ=="),
        ]
        for (label, signature) in malformed {
            try expectThrows(UpdateSignature.Failure.malformedSignature, label) {
                try UpdateSignature.verify(fileAt: file, signature: signature, publicKey: key.publicKey)
            }
        }
        try expectThrows(UpdateSignature.Failure.malformedPublicKey, "畸形公钥") {
            try UpdateSignature.verify(fileAt: file, signature: valid, publicKey: "c2ln")
        }
        try expectThrows(UpdateSignature.Failure.unreadableFile, "包体不存在") {
            try UpdateSignature.verify(
                fileAt: root.appendingPathComponent("missing.zip"),
                signature: valid,
                publicKey: key.publicKey
            )
        }
    }

    /// 签名缺失 / 畸形 / 他人密钥 / 签的是别的包: 一律 signatureInvalid, 且不执行 ditto 与 xattr.
    static func prepareRejectsBadSignatureBeforeExtracting() async throws {
        let root = try TemporaryDirectories.make("prepare-signature")
        defer { TemporaryDirectories.remove(root) }
        let commands = RecordingCommandRunner()
        let installer = UpdateInstaller(
            updatesRoot: root.appendingPathComponent("updates"),
            trustedPublicKey: TestSigningKey.shared.publicKey,
            commands: commands
        )
        try installer.prepareUpdatesRoot()
        let (archive, release) = try SoftwareUpdateInstallerTests.makeArchive(in: root, version: "0.13.0")
        // 同版本夹具 zip 在同一秒内逐字节相同, 「另一个包」须用确实不同的字节.
        let otherArchive = root.appendingPathComponent("other.zip")
        var otherBytes = try Data(contentsOf: archive)
        otherBytes[otherBytes.count / 2] ^= 0x01
        try otherBytes.write(to: otherArchive)
        let forged: [(String, String)] = [
            ("缺签名", ""),
            ("畸形签名", "c2ln"),
            ("他人密钥", try TestSigningKey().sign(archive)),
            ("签的是另一个包", try TestSigningKey.shared.sign(otherArchive)),
        ]
        for (label, signature) in forged {
            let candidate = UpdateRelease(
                version: release.version,
                notes: release.notes,
                downloadURL: release.downloadURL,
                sha256: release.sha256,
                signature: signature
            )
            try await expectThrows(UpdateInstallFailure.signatureInvalid, label) {
                _ = try await installer.prepare(
                    archive: archive,
                    release: candidate,
                    localVersion: SoftwareUpdateInstallerTests.local,
                    bundleIdentifier: FixtureBundle.bundleIdentifier
                )
            }
            try expect(commands.runs.isEmpty, "\(label): 签名不通过不得执行解压或 xattr, 实际: \(commands.runs)")
            try expect(
                !FileManager.default.fileExists(atPath: installer.stagingDirectory(for: release.version).path),
                "\(label): 签名不通过不得创建暂存目录"
            )
        }

        let rejectedByProductionKey = UpdateInstaller(
            updatesRoot: root.appendingPathComponent("updates"),
            commands: commands
        )
        try await expectThrows(UpdateInstallFailure.signatureInvalid, "测试密钥签名不被内置生产公钥接受") {
            _ = try await rejectedByProductionKey.prepare(
                archive: archive,
                release: release,
                localVersion: SoftwareUpdateInstallerTests.local,
                bundleIdentifier: FixtureBundle.bundleIdentifier
            )
        }
        try expect(commands.runs.isEmpty, "生产公钥拒绝时同样不解压")

        _ = try await installer.prepare(
            archive: archive,
            release: release,
            localVersion: SoftwareUpdateInstallerTests.local,
            bundleIdentifier: FixtureBundle.bundleIdentifier
        )
        try expectEqual(commands.runs, ["/usr/bin/ditto", "/usr/bin/xattr"], "签名通过后才解压并剥离 quarantine")
    }
}
