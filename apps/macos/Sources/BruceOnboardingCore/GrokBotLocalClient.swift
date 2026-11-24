import Foundation

// MARK: - GrokBotLocalClient

/// Grok Bot 客户端本机状态的只读访问 (T39, design/02 规则 18).
///
/// mac 端只在用户点击「连接」时读取客户端当前登录账号 (`client-meta.account-slot`);
/// 周用量读数的定位、读取与解析一律由共享 Collector 完成, 本端不重复实现.
/// 不读取加密会话 `sand-secrets.json`, 不触碰钥匙串.
public enum GrokBotLocalClient {
    /// 当前账号分片键.
    public static let accountSlotSliceKey = "sand.client.slice.client-meta.account-slot"
    /// 单个分片读取上限, 与 Collector `GROK_BOT_MAX_SLICE_BYTES` 一致.
    public static let maxSliceBytes = 64 * 1024
    /// 账号标识长度上限, 与 Collector `GROK_BOT_MAX_ACCOUNT_BYTES` 一致.
    public static let maxAccountBytes = 256

    public enum ReadError: Error, Equatable, Sendable {
        case unreadable
        case tooLarge
        case formatChanged

        /// 设置页提示文案 (不含路径与账号).
        public var message: String {
            switch self {
            case .unreadable: return "Grok Bot 登录态读取失败, 请稍后重试"
            case .tooLarge: return "Grok Bot 登录态文件超过大小上限"
            case .formatChanged: return "Grok Bot 登录态格式已变化, 暂不支持连接"
            }
        }
    }

    /// macOS 默认数据目录: `~/Library/Application Support/Grok Bot`.
    public static func defaultDataDirectory(homeURL: URL) -> URL {
        homeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Grok Bot", isDirectory: true)
    }

    /// 分片文件名: 分片键的 RFC 4648 base32 (小写、无填充) + `.blob`.
    public static func sliceFileName(_ sliceKey: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var name = ""
        var buffer: UInt32 = 0
        var bits: UInt32 = 0
        for byte in sliceKey.utf8 {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                name.append(alphabet[Int((buffer >> bits) & 0x1f)])
            }
            buffer &= (1 << bits) - 1
        }
        if bits > 0 {
            name.append(alphabet[Int((buffer << (5 - bits)) & 0x1f)])
        }
        return name + ".blob"
    }

    /// 账号标识是否可接受: 非空、不超长、无控制字符 (与 Collector 同口径).
    public static func isValidAccount(_ account: String) -> Bool {
        !account.isEmpty
            && account.utf8.count <= maxAccountBytes
            && !account.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 读取客户端当前登录账号. 未安装 / 未登录返回 `.success(nil)`.
    public static func readActiveAccount(
        dataDirectory: URL
    ) -> Result<String?, ReadError> {
        let url = dataDirectory
            .appendingPathComponent("sand-client-persistence", isDirectory: true)
            .appendingPathComponent(sliceFileName(accountSlotSliceKey))
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success(nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.unreadable)
        }
        defer { try? handle.close() }
        let data: Data
        do {
            data = try handle.read(upToCount: maxSliceBytes + 1) ?? Data()
        } catch {
            return .failure(.unreadable)
        }
        if data.count > maxSliceBytes {
            return .failure(.tooLarge)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["schemaVersion"] as? NSNumber)?.intValue == 1 else {
            return .failure(.formatChanged)
        }
        switch object["value"] {
        case nil, is NSNull:
            return .success(nil)
        case let account as String where account.isEmpty:
            return .success(nil)
        case let account as String where isValidAccount(account):
            return .success(account)
        default:
            return .failure(.formatChanged)
        }
    }
}

// MARK: - GrokBotAccountIdentity

/// 账号键: `sha256(account)` 十六进制前 16 位, 与 Collector `grok_bot_account_key` 同值
/// (OnboardingCore Harness 以共享锚点对拍). 服务 ID 为 `grokbot_<账号键>`.
public enum GrokBotAccountIdentity {
    public static func accountKey(for account: String) -> String {
        ProviderAccountKeys.sha256Hex(account)
    }
}
