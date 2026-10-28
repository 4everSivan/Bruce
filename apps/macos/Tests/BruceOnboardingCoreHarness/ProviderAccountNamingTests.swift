import Foundation
@testable import BruceOnboardingCore

// MARK: - T18 多账号命名与重命名

extension BruceOnboardingCoreHarness {
    /// 默认名取最小未占用序号; 前缀/标签拆分只认精确前缀; 标签校验与重名判定.
    static func providerAccountNamingDefaultsAndValidation() throws {
        let next = ProviderAccountNaming.defaultDisplayName(
            for: .kimi,
            existingDisplayNames: ["Kimi · 账号 1", "Kimi · 工作"]
        )
        try coreExpect(next == "Kimi · 账号 2", "默认序号应跳过已占用: \(next)")

        // 恢复默认时排除自身, 不应顺延到下一个序号.
        let restored = ProviderAccountNaming.defaultDisplayName(
            for: .kimi,
            existingDisplayNames: ["Kimi · 账号 1"],
            excludingDisplayName: "Kimi · 账号 1"
        )
        try coreExpect(restored == "Kimi · 账号 1", "恢复默认应保留原序号: \(restored)")

        // StepFun 国际站使用独立站点前缀.
        let global = ProviderAccountNaming.defaultDisplayName(
            for: .stepfun,
            existingDisplayNames: ["StepFun (国际) · 账号 1"],
            stepFunGlobal: true
        )
        try coreExpect(
            global == "StepFun (国际) · 账号 2",
            "StepFun 国际站默认名错误: \(global)"
        )

        // 标签内部的 " · " 不得被当作 Provider 分隔符.
        let label = ProviderAccountNaming.label(
            from: "Kimi · 工作 · 主号",
            provider: .kimi
        )
        try coreExpect(label == "工作 · 主号", "标签拆分错误: \(label)")

        do {
            _ = try ProviderAccountNaming.validateLabel("   ")
            throw CoreTestFailure.expectation("空白标签应被拒绝")
        } catch let error as ProviderAccountNamingError {
            try coreExpect(error == .empty, "空白标签错误类型不符: \(error)")
        }
        do {
            _ = try ProviderAccountNaming.validateLabel("a\nb")
            throw CoreTestFailure.expectation("换行标签应被拒绝")
        } catch let error as ProviderAccountNamingError {
            try coreExpect(error == .controlCharacters, "换行标签错误类型不符: \(error)")
        }
        do {
            _ = try ProviderAccountNaming.validateLabel(String(repeating: "a", count: 33))
            throw CoreTestFailure.expectation("超长标签应被拒绝")
        } catch let error as ProviderAccountNamingError {
            try coreExpect(error == .tooLong, "超长标签错误类型不符: \(error)")
        }

        try coreExpect(
            ProviderAccountNaming.isDuplicate(
                "Kimi · 工作",
                provider: .kimi,
                existingDisplayNames: ["Kimi · 工作"]
            ),
            "同 Provider 重名应被识别"
        )
        try coreExpect(
            !ProviderAccountNaming.isDuplicate(
                "Kimi · 工作",
                provider: .kimi,
                existingDisplayNames: ["Kimi · 工作"],
                excludingDisplayName: "Kimi · 工作"
            ),
            "排除自身后不应判为重复"
        )

        // StepFun 换站点保留标签, 只重建前缀.
        let reconciled = ProviderAccountNaming.reconciledStepFunDisplayName(
            existingDisplayName: "StepFun · 工作",
            newDisplayName: "StepFun (国际) · 账号 9"
        )
        try coreExpect(
            reconciled == "StepFun (国际) · 工作",
            "StepFun 站点前缀重建错误: \(reconciled)"
        )

        // 站点判定只认名称开头的站点前缀, 自定义标签里的「国际」不得误判.
        try coreExpect(
            ProviderAccountNaming.isStepFunGlobalDisplayName("StepFun (国际) · 工作"),
            "国际站前缀应命中"
        )
        try coreExpect(
            ProviderAccountNaming.isStepFunGlobalDisplayName("StepFun 国际站 · 工作"),
            "历史国际站写法应命中"
        )
        try coreExpect(
            !ProviderAccountNaming.isStepFunGlobalDisplayName("StepFun · 国际备用"),
            "自定义标签中的「国际」不得改变站点"
        )
    }

    /// 重命名同时落 index/record; 重复保存不覆盖自定义名; StepFun 换站点保留标签.
    static func providerAccountStoreRenameAndUpsertPreservation() throws {
        let store = ProviderAccountStore(
            provider: .kimi,
            credentialStore: InMemoryCredentialStore()
        )
        _ = try store.addAccount(
            accountID: "acct-a",
            displayName: "Kimi · 账号 1",
            credentialJSON: "key-1"
        )
        try store.updateAuthorizationState(.connected, for: "acct-a")
        try store.renameAccount(accountID: "acct-a", displayName: "Kimi · 工作")

        var index = try store.loadIndex()
        try coreExpect(
            index.entry(for: "acct-a")?.displayName == "Kimi · 工作",
            "index 未同步重命名"
        )
        var record = try store.loadRecord(for: "acct-a")
        try coreExpect(record?.displayName == "Kimi · 工作", "record 未同步重命名")
        try coreExpect(record?.authorizationState == .connected, "重命名不得改变授权状态")
        try coreExpect(record?.credentialJSON == "key-1", "重命名不得改变凭证")

        // 重新保存同一凭证 (upsert) 必须保留自定义名, 同时更新凭证内容.
        try store.upsertAccount(
            accountID: "acct-a",
            displayName: "Kimi · 账号 2",
            credentialJSON: "key-2"
        )
        index = try store.loadIndex()
        record = try store.loadRecord(for: "acct-a")
        try coreExpect(
            index.entry(for: "acct-a")?.displayName == "Kimi · 工作",
            "重复保存覆盖了自定义名"
        )
        try coreExpect(record?.displayName == "Kimi · 工作", "record 自定义名被覆盖")
        try coreExpect(record?.credentialJSON == "key-2", "重复保存应更新凭证")

        // StepFun: 换站点只换前缀, 标签保留.
        let stepFun = ProviderAccountStore(
            provider: .stepfun,
            credentialStore: InMemoryCredentialStore()
        )
        _ = try stepFun.addAccount(
            accountID: "step-a",
            displayName: "StepFun · 账号 1",
            credentialJSON: "token-a"
        )
        try stepFun.renameAccount(accountID: "step-a", displayName: "StepFun · 工作")
        try stepFun.upsertAccount(
            accountID: "step-a",
            displayName: "StepFun (国际) · 账号 2",
            credentialJSON: "token-a"
        )
        let stepIndex = try stepFun.loadIndex()
        try coreExpect(
            stepIndex.entry(for: "step-a")?.displayName == "StepFun (国际) · 工作",
            "StepFun 换站点未保留标签: \(stepIndex.entry(for: "step-a")?.displayName ?? "nil")"
        )
    }

    /// Codex customName 优先级、index 透传与旧 v2 记录兼容.
    static func codexCustomNameOverridesAndBackwardCompatibility() throws {
        let withCustom = CodexAccountRecord(
            accountID: "codex-a",
            email: "user@example.com",
            customName: "工作",
            authorizationState: .needsReauthorization,
            credentialOrigin: .Bruce,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try coreExpect(
            withCustom.displayName == "Codex · 工作",
            "customName 应优先于邮箱: \(withCustom.displayName)"
        )

        let emailOnly = CodexAccountRecord(
            accountID: "codex-a",
            email: "user@example.com",
            authorizationState: .needsReauthorization,
            credentialOrigin: .Bruce,
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        try coreExpect(
            emailOnly.displayName == "Codex · user",
            "无自定义名时应回落邮箱前缀: \(emailOnly.displayName)"
        )

        // 旧 v2 JSON 不含 customName 时按 nil 解码, schemaVersion 保持 2.
        let legacyJSON = #"""
        {"schemaVersion":2,"accountID":"codex-a","email":"user@example.com",
         "authorizationState":"needsReauthorization","credentialOrigin":"Bruce",
         "updatedAt":0}
        """#
        let decoded = try JSONDecoder().decode(
            CodexAccountRecord.self,
            from: Data(legacyJSON.utf8)
        )
        try coreExpect(decoded.customName == nil, "旧记录 customName 应为 nil")
        try coreExpect(
            decoded.displayName == "Codex · user",
            "旧记录显示名应回落邮箱"
        )

        // index entry 透传 customName.
        let store = CodexCredentialStore(store: InMemoryCredentialStore())
        try store.saveRecord(withCustom)
        let index = try store.loadIndex()
        try coreExpect(
            index.entry(for: "codex-a")?.customName == "工作",
            "index 未透传 customName"
        )
    }
}
