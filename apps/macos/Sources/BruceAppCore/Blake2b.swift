import Foundation

// MARK: - BLAKE2b-512 (RFC 7693)

/// 无密钥、无盐的 BLAKE2b-512 流式哈希, 只服务于 minisign 预哈希签名校验 (C174):
/// CryptoKit 不含 BLAKE2b, 发布签名为 Ed25519 over BLAKE2b-512(Bruce.zip).
/// 正确性由 RFC 7693 标准向量与跨块边界 / 分块输入向量锁定 (SoftwareUpdateHarness).
package struct Blake2b512 {
    package static let digestLength = 64
    private static let blockLength = 128

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private var state: [UInt64]
    /// 待压缩的尾块: 最后一块必须带结束标志压缩, 故满块也留到有后续输入时才压.
    private var buffer: [UInt8] = []
    private var byteCount: (low: UInt64, high: UInt64) = (0, 0)

    package init() {
        state = Self.iv
        // 参数块: digest_length = 64, key_length = 0, fanout = 1, depth = 1.
        state[0] ^= 0x0101_0000 ^ UInt64(Self.digestLength)
        buffer.reserveCapacity(Self.blockLength)
    }

    package mutating func update<Bytes: Sequence>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        for byte in bytes {
            if buffer.count == Self.blockLength {
                advanceCounter(by: UInt64(Self.blockLength))
                compress(isFinal: false)
                buffer.removeAll(keepingCapacity: true)
            }
            buffer.append(byte)
        }
    }

    package mutating func finalize() -> Data {
        advanceCounter(by: UInt64(buffer.count))
        buffer.append(contentsOf: repeatElement(0, count: Self.blockLength - buffer.count))
        compress(isFinal: true)
        var digest = Data(capacity: Self.digestLength)
        for word in state {
            withUnsafeBytes(of: word.littleEndian) { digest.append(contentsOf: $0) }
        }
        return digest
    }

    package static func hash<Bytes: Sequence>(_ bytes: Bytes) -> Data where Bytes.Element == UInt8 {
        var hasher = Blake2b512()
        hasher.update(bytes)
        return hasher.finalize()
    }

    private mutating func advanceCounter(by count: UInt64) {
        let (low, overflow) = byteCount.low.addingReportingOverflow(count)
        byteCount = (low, overflow ? byteCount.high &+ 1 : byteCount.high)
    }

    private mutating func compress(isFinal: Bool) {
        var message = [UInt64](repeating: 0, count: 16)
        for index in 0..<16 {
            var word: UInt64 = 0
            for offset in 0..<8 {
                word |= UInt64(buffer[index * 8 + offset]) << (8 * UInt64(offset))
            }
            message[index] = word
        }
        var v = state + Self.iv
        v[12] ^= byteCount.low
        v[13] ^= byteCount.high
        if isFinal {
            v[14] = ~v[14]
        }
        for round in 0..<12 {
            let s = Self.sigma[round % 10]
            Self.mix(&v, 0, 4, 8, 12, message[s[0]], message[s[1]])
            Self.mix(&v, 1, 5, 9, 13, message[s[2]], message[s[3]])
            Self.mix(&v, 2, 6, 10, 14, message[s[4]], message[s[5]])
            Self.mix(&v, 3, 7, 11, 15, message[s[6]], message[s[7]])
            Self.mix(&v, 0, 5, 10, 15, message[s[8]], message[s[9]])
            Self.mix(&v, 1, 6, 11, 12, message[s[10]], message[s[11]])
            Self.mix(&v, 2, 7, 8, 13, message[s[12]], message[s[13]])
            Self.mix(&v, 3, 4, 9, 14, message[s[14]], message[s[15]])
        }
        for index in 0..<8 {
            state[index] ^= v[index] ^ v[index + 8]
        }
    }

    private static func mix(
        _ v: inout [UInt64],
        _ a: Int, _ b: Int, _ c: Int, _ d: Int,
        _ x: UInt64, _ y: UInt64
    ) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotateRight(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotateRight(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotateRight(v[b] ^ v[c], 63)
    }

    private static func rotateRight(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }
}
