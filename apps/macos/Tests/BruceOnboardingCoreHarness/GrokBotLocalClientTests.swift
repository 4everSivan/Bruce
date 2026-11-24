import Foundation
@testable import BruceOnboardingCore

// MARK: - Grok Bot 本机客户端 (T39, design/02 规则 18)

extension BruceOnboardingCoreHarness {
    /// 分片命名与账号键必须与 Collector (`collector-provider/src/grok_bot.rs`) 同值:
    /// 锚点与 Rust 单测逐字相同, 任一端改算法都会在两端测试中同时暴露.
    static func grokBotSliceNameAndAccountKeyMatchRustContract() throws {
        try coreExpect(
            GrokBotLocalClient.sliceFileName(GrokBotLocalClient.accountSlotSliceKey)
                == "onqw4zbomnwgszlooqxhg3djmnss4y3mnfsw45bnnvsxiyjomfrwg33vnz2c243mn52a.blob",
            "account-slot 分片名应与客户端实测文件名一致"
        )
        try coreExpect(GrokBotLocalClient.sliceFileName("f") == "my.blob", "base32 单字节")
        try coreExpect(GrokBotLocalClient.sliceFileName("fo") == "mzxq.blob", "base32 双字节")
        try coreExpect(
            GrokBotLocalClient.sliceFileName("foobar") == "mzxw6ytboi.blob",
            "base32 RFC 4648 向量"
        )
        try coreExpect(
            GrokBotAccountIdentity.accountKey(for: "grok|user_01") == "f827599c055f9a8a",
            "账号键应与 Rust grok_bot_account_key 锚点一致"
        )
        try coreExpect(
            GrokBotAccountIdentity.accountKey(for: "grok|user_02")
                != GrokBotAccountIdentity.accountKey(for: "grok|user_01"),
            "不同账号应得到不同账号键"
        )
    }

    /// 当前账号读取: 未安装 / 未登录为 nil, 格式漂移与超限为失败, 不猜测.
    static func grokBotActiveAccountReaderBoundaries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Bruce-grok-bot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try coreExpect(
            GrokBotLocalClient.readActiveAccount(dataDirectory: root) == .success(nil),
            "未安装 Grok Bot 应视为未登录"
        )
        let slices = root.appendingPathComponent("sand-client-persistence", isDirectory: true)
        try FileManager.default.createDirectory(at: slices, withIntermediateDirectories: true)
        let slot = slices.appendingPathComponent(
            GrokBotLocalClient.sliceFileName(GrokBotLocalClient.accountSlotSliceKey)
        )
        func write(_ text: String) throws {
            try Data(text.utf8).write(to: slot)
        }
        try write(#"{"schemaVersion":1,"value":"grok|user_01"}"#)
        try coreExpect(
            GrokBotLocalClient.readActiveAccount(dataDirectory: root) == .success("grok|user_01"),
            "应读出当前登录账号"
        )
        for signedOut in [#"{"schemaVersion":1,"value":""}"#, #"{"schemaVersion":1,"value":null}"#] {
            try write(signedOut)
            try coreExpect(
                GrokBotLocalClient.readActiveAccount(dataDirectory: root) == .success(nil),
                "空账号应视为未登录: \(signedOut)"
            )
        }
        for drifted in [
            #"{"schemaVersion":2,"value":"grok|user_01"}"#,
            #"{"schemaVersion":1,"value":7}"#,
            "not json",
            "",
        ] {
            try write(drifted)
            try coreExpect(
                GrokBotLocalClient.readActiveAccount(dataDirectory: root) == .failure(.formatChanged),
                "格式漂移应失败: \(drifted)"
            )
        }
        try write(String(repeating: " ", count: GrokBotLocalClient.maxSliceBytes + 1))
        try coreExpect(
            GrokBotLocalClient.readActiveAccount(dataDirectory: root) == .failure(.tooLarge),
            "超限文件应失败"
        )
        try coreExpect(
            GrokBotLocalClient.defaultDataDirectory(homeURL: URL(fileURLWithPath: "/h")).path
                == "/h/Library/Application Support/Grok Bot",
            "mac 默认数据目录"
        )
        try coreExpect(
            !GrokBotLocalClient.isValidAccount("")
                && !GrokBotLocalClient.isValidAccount("a\nb")
                && !GrokBotLocalClient.isValidAccount(String(repeating: "a", count: 257))
                && GrokBotLocalClient.isValidAccount("grok|user_01"),
            "账号标识校验与 Collector 同口径"
        )

        // 瞬态半包重试: 首次为截断 JSON, 在重试 sleep 回调中恢复完整分片即成功;
        // 格式版本漂移 (有效 JSON) 则立即失败且不触发 sleep.
        try write("{")
        var sleepCount = 0
        let recovered = GrokBotLocalClient.readActiveAccount(
            dataDirectory: root,
            retryDelays: [0.001, 0.001],
            sleep: { _ in
                sleepCount += 1
                try? Data(#"{"schemaVersion":1,"value":"grok|user_01"}"#.utf8).write(to: slot)
            }
        )
        try coreExpect(recovered == .success("grok|user_01"), "瞬态半包应在重试后恢复")
        try coreExpect(sleepCount == 1, "首次恢复后不应继续无谓重试: sleepCount=\(sleepCount)")

        try write(#"{"schemaVersion":2,"value":"grok|user_01"}"#)
        var driftSleeps = 0
        let driftResult = GrokBotLocalClient.readActiveAccount(
            dataDirectory: root,
            retryDelays: [0.001, 0.001],
            sleep: { _ in driftSleeps += 1 }
        )
        try coreExpect(driftResult == .failure(.formatChanged), "格式漂移应失败")
        try coreExpect(driftSleeps == 0, "有效 JSON 的格式漂移不应重试")
    }

    /// 注册表与各 provider 分派表: Grok Bot 只存账号标识, 不参与轮换, 无旧键迁移.
    static func grokBotRegistryAndDispatch() throws {
        let descriptor = ProviderRegistry.descriptor(for: .grokBot)
        try coreExpect(descriptor.injectionKind == .grokBotQuotaAccounts, "injectionKind")
        try coreExpect(
            descriptor.credentialAccounts == [SubscriptionCredentialAccount.grokBotAccount],
            "credentialAccounts"
        )
        try coreExpect(descriptor.configuredRule == .allCredentialAccountsNonEmpty, "configuredRule")
        try coreExpect(SubscriptionProviderID.grokBot.displayName == "Grok Bot", "展示名")
        try coreExpect(SubscriptionProviderID.grokBot.rawValue == "grokBot", "rawValue 与 collector provider 同值")
        try coreExpect(ProviderAccountKeys.legacyKeys(for: .grokBot).isEmpty, "无旧单条键")
        try coreExpect(
            StoredCredentialParser.parse(provider: .grokBot, credentialJSON: "grok|user_01") == nil,
            "账号绑定不按 API key 解析"
        )
        try coreExpect(
            CredentialRotationMerge.mergedAccountJSON(
                existingCredentialJSON: "grok|user_01",
                update: CredentialRotationUpdate(
                    provider: "grokBot",
                    accountId: "f827599c055f9a8a",
                    tokens: ["access_token": "t"]
                ),
                providerID: .grokBot
            ) == nil,
            "Grok Bot 不接受令牌轮换写回"
        )
    }
}
